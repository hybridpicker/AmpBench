import AmpText
import AVFoundation
import AppKit
import CoreAudio
import SparkCore
import SwiftUI

/// Readable from any thread, so background analysis can hold back while a recording runs.
final class RecordingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

enum RecordPhase: Equatable {
    case idle
    case preparing
    case countIn(beatsLeft: Int)
    case recording
}

struct Banner: Identifiable, Equatable {
    enum Kind { case info, warning, error }

    let id = UUID()
    let kind: Kind
    let text: String
    var canUndo = false
    /// A key in the banner, such as AmpBench's "Apply" for a tempo going into the preset.
    var action: BannerAction?

    static func == (lhs: Banner, rhs: Banner) -> Bool { lhs.id == rhs.id }
}

enum LibraryTab: String, CaseIterable, Identifiable {
    case recordings, pieces, stats
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordings: return tr("Takes")
        case .pieces: return tr("Pieces")
        case .stats: return tr("Statistics")
        }
    }
}

/// Fast-changing input values, in their own object so the meter redraws without touching the rest of the window.
@MainActor
final class MeterState: ObservableObject {
    @Published var level: Float = 0
    @Published var peakHold: Float = 0
    @Published var clipped = false
    @Published var signal = SignalMonitor.Status.ok
    @Published var seconds: Double = 0
    @Published var retroSeconds: Double = 0
    @Published var droppedFrames: Int64 = 0
    @Published var beat: UInt64 = 0
}

@MainActor
final class PlayheadState: ObservableObject {
    @Published var position: Double = 0
    @Published var isPlaying = false
}

@MainActor
final class LiveWave: ObservableObject {
    @Published var pairs: [Float] = []
    @Published var grid: BeatGrid?
    var secondsPerBin = 0.0
}

/// Bars chosen to be re-recorded, with what the recording needs from the take they belong to.
private struct PunchRequest {
    let sourceID: UUID
    let sourceName: String
    let pieceID: UUID?
    let grid: BeatGrid
    let bars: ClosedRange<Int>
}

@MainActor
final class AppModel: ObservableObject {
    static let retroChoices = [1.0, 2.0, 5.0, 10.0]
    private static let monitorMaxSeconds = 120.0
    private static let minimumFreeBytes: Int64 = 200_000_000
    private static let criticalFreeBytes: Int64 = 50_000_000
    /// Recordings stop safely below the 4 GB limit of the WAV format.
    private static let maximumFileBytes: Int64 = 3_900_000_000
    private static let countInPreRoll = 0.15
    /// Keeps recording a moment after the last bar, so its final note can ring out.
    private static let punchTailSeconds = 0.3

    // MARK: Library state

    let store: LibraryStore
    let defaults: UserDefaults
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var pieces: [Piece] = []
    @Published private(set) var practiceLog: [PracticeEntry] = []
    @Published var query = LibraryQuery()
    @Published var sortOrder = [KeyPathComparator(\Recording.createdAt, order: .reverse)]
    @Published var selection = Set<UUID>()
    @Published var tab = LibraryTab.recordings
    /// Pieces shown open in the list. Kept here, so AmpBench's switch of areas does not close them.
    @Published var expandedPieces = Set<UUID>()
    @Published private(set) var libraryIsUsable = true

    // MARK: Devices

    @Published private(set) var inputs: [InputDevice] = []
    @Published private(set) var outputs: [OutputDevice] = []
    @Published var inputID: AudioDeviceID?
    /// Nil follows the system output.
    @Published var outputID: AudioDeviceID?
    @Published var clickOutputID: AudioDeviceID?
    @Published private(set) var sparkWithoutInput = false

    // MARK: Recording

    @Published private(set) var phase = RecordPhase.idle
    @Published private(set) var isMonitoring = false
    @Published private(set) var isRetroOn = false
    /// The tuner reads along, and keeps the input open while its area shows.
    @Published private(set) var isTuning = false
    private var tunerTap: AudioTap?
    @Published var retroMinutes: Double
    @Published var autoLevelDefault: Bool
    @Published var currentPieceID: UUID?
    @Published private(set) var pendingMarkerCount = 0
    /// The bars of the running recording, once the click and the file have both started.
    @Published private(set) var activeGrid: BeatGrid?
    /// The bars being re-recorded right now.
    @Published private(set) var activePunchBars: ClosedRange<Int>?
    let meter = MeterState()
    let live = LiveWave()

    // MARK: Playback

    @Published private(set) var currentID: UUID?
    @Published private(set) var currentWaveform: WaveformData?
    @Published private(set) var isAnalyzing = false
    @Published var tempo: Double = 1
    @Published var pitch: Double = 0
    @Published private(set) var loopRange: ClosedRange<Double>?
    @Published private(set) var loopStart: Double?
    /// The bars chosen in the bar controls, for looping or re-recording.
    @Published private(set) var barSelection: ClosedRange<Int>?
    /// What the click follows during playback. Nil when no click sounds.
    @Published private(set) var playbackClickGrid: BeatGrid?
    let playhead = PlayheadState()

    // MARK: Compare

    @Published private(set) var compareIDs: [UUID] = []
    @Published private(set) var compareActive = 0
    @Published private(set) var compareWaveforms: [UUID: WaveformData] = [:]

    // MARK: Metronome

    @Published var metronome: MetronomeSettings
    @Published private(set) var isClickRunning = false
    private var tapTempo = TapTempo()

    // MARK: Messages

    @Published var banner: Banner?
    @Published private(set) var exportProgress: Double?
    /// Shows AmpBench's list of shortcuts.
    var showShortcuts: (@MainActor () -> Void)?
    @Published var renameTarget: UUID?
    @Published var renameText = ""
    @Published var showLoopbackInfo = false
    @Published var showLatencyInfo = false
    @Published private(set) var isMeasuring = false
    /// The recordings a new piece will hold while its name is being asked for. Nil when nothing is being asked.
    @Published var newPieceTargets: Set<UUID>?
    @Published var newPieceName = ""

    // MARK: Engines

    let inputPolicy: InputPolicy
    private let capture: CaptureEngine
    private let playback = PlaybackEngine()
    private let click = ClickEngine()
    private var timer: Timer?
    private var signalMonitor = SignalMonitor()
    private let recordingFlag = RecordingFlag()
    private let journalQueue = DispatchQueue(label: "local.sparkrecorder.journal", qos: .utility)
    private var measuredClean: Set<String>
    /// Seconds per pair of input and click output that the devices do not report. Measured or set by hand.
    @Published private(set) var latencyCorrections: [String: Double]
    private static let latencyCorrectionsKey = "clickLatencyCorrections"
    private var saveTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var sleepActivity: NSObjectProtocol?

    private var activeFile: URL?
    private var activeJournal: RecordingJournal?
    private var activeSource: SourceFormat?
    private var activeStart = Date()
    private var livePairs: [Float] = []
    /// The tempo and meter the running click follows. Re-recording uses those of the take, not the panel's.
    private var activeClickSettings: MetronomeSettings?
    private var pendingPunch: PunchRequest?
    private var activePunch: PunchRequest?
    private var punchStopAt: Double?
    /// Beats the running click plays before bar 1, which is the count-in.
    private var activeCountInBeats = 0
    /// The delays the bars of the running recording are corrected by.
    private var activeLatency = ClickLatency()
    private var bannerUndoAction: (@MainActor (AppModel) -> Void)?
    /// AmpBench's sound of the amp for a new take. Nil in Spark Recorder.
    var soundProvider: (@MainActor () -> TakeSound?)?
    /// AmpBench's actions for a take's sound: play it on the amp, open it in the editor. Nil in Spark Recorder.
    var soundActions: SoundActions?
    /// Called after the metronome's tempo was changed by hand, so AmpBench can offer it to the preset.
    var onTempoChanged: (@MainActor (Double) -> Void)?
    /// AmpBench's saved presets, for the sounds of pieces and their parts. Nil without the presets.
    var presetChoices: (@MainActor () -> [PresetLink])?
    /// Plays a piece's or part's sound on the amp's temporary place.
    var playPreset: (@MainActor (PresetLink) -> Void)?
    private var peakHoldAge = 0.0
    private var monitorStartedAt = Date()
    private var diskCheckAge = 0.0
    private var lastBannerForSignal: SignalMonitor.Status = .ok
    private var startRequestID = 0
    private var didStart = false

    var isRecording: Bool {
        switch phase {
        case .recording, .countIn: return true
        case .idle, .preparing: return false
        }
    }

    /// The input is open and hears the device, whichever feature caused it.
    var isListening: Bool { isRecording || isMonitoring || isRetroOn || isTuning }

    // MARK: Lifecycle

    init(folder: URL, defaults: UserDefaults, inputPolicy: InputPolicy) {
        store = LibraryStore(folder: folder)
        self.defaults = defaults
        self.inputPolicy = inputPolicy
        capture = CaptureEngine(inputPolicy: inputPolicy)
        retroMinutes = defaults.object(forKey: "retroMinutes") as? Double ?? 5
        autoLevelDefault = defaults.object(forKey: "autoLevel") as? Bool ?? true
        measuredClean = Set(defaults.stringArray(forKey: "measuredCleanPairs") ?? [])
        latencyCorrections = defaults.dictionary(forKey: Self.latencyCorrectionsKey) as? [String: Double] ?? [:]
        if let data = defaults.data(forKey: "metronome"),
           let saved = try? JSONDecoder().decode(MetronomeSettings.self, from: data) {
            metronome = saved
        } else {
            metronome = MetronomeSettings()
        }
        if let raw = defaults.string(forKey: "currentPiece") { currentPieceID = UUID(uuidString: raw) }
    }

    /// Runs once the window exists. Recovery comes first, so an interrupted take is back before anything else.
    func start() {
        guard !didStart else { return }
        didStart = true

        guard store.acquireProcessLock() else {
            libraryIsUsable = false
            show(.error, tr("AmpBench is already running with this library. Quit the other instance."), sticky: true)
            return
        }
        do {
            switch try store.load() {
            case .fresh, .loaded:
                break
            case .restoredFromBackup(let keptAs):
                show(.warning, tr("The library file was damaged. The backup was loaded; the old file is in the folder as “%@”.", keptAs), sticky: true)
            case .startedOver(let keptAs):
                show(.warning, tr("The library file was damaged and there was no backup. The takes were read in again; the old file is in the folder as “%@”.", keptAs), sticky: true)
            }
        } catch {
            libraryIsUsable = false
            show(.error, error.localizedDescription, sticky: true)
        }

        capture.onInterrupted = { [weak self] reason in
            MainActor.assumeIsolated { self?.inputInterrupted(reason) }
        }
        playback.onFinished = { [weak self] in
            MainActor.assumeIsolated { self?.playback(finished: ()) }
        }
        playback.onOutputChanged = { [weak self] in
            MainActor.assumeIsolated { self?.outputConfigurationChanged() }
        }
        deviceListListener = AudioDevices.observeDeviceList { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        refreshDevices()
        restoreDeviceChoices()
        recoverAndScan()
        applyTempo()

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Called when the app quits. A running recording is finalized first.
    func shutdown() {
        if isRecording { stopRecording(note: nil) }
        turnOffListening()
        playback.pause()
        click.stop()
        saveTask?.cancel()
        try? store.save()
        store.flushSaves()
    }

    /// The window closed while the app keeps running. Listening without a visible window is never right.
    func windowClosed() {
        guard !isRecording else { return }
        turnOffListening()
    }

    private func recoverAndScan() {
        let recovery = store.recoverInterruptedRecording()
        switch recovery {
        case .none:
            break
        case .repaired(let name, let seconds):
            show(.warning, tr("The last recording was interrupted and repaired: “%@” (%@).", name, TimeText.clock(seconds)), sticky: true)
        case .empty(let name):
            show(.info, tr("The interrupted recording “%@” contained no audio and is in the Trash.", name))
        case .failed(let name):
            show(.error, tr("The interrupted recording “%@” could not be repaired. The file stays unchanged in the folder.", name), sticky: true)
        }
        scanFolder(announceNothing: true)
        syncFromStore()
    }

    func scanFolder(announceNothing: Bool = false) {
        guard !isRecording, libraryIsUsable else { return }
        let report = store.scan()
        syncFromStore()
        var parts: [String] = []
        if !report.added.isEmpty { parts.append(tr("%d added", report.added.count)) }
        if !report.reattached.isEmpty { parts.append(tr("%d recognized after renaming", report.reattached.count)) }
        if !report.repaired.isEmpty { parts.append(tr("%d repaired", report.repaired.count)) }
        if !report.missing.isEmpty { parts.append(tr("%d missing", report.missing.count)) }
        if !report.damaged.isEmpty { parts.append(tr("%d damaged", report.damaged.count)) }
        if parts.isEmpty {
            if !announceNothing { show(.info, tr("The folder matches the library.")) }
        } else if banner == nil || !announceNothing {
            let isBad = !report.missing.isEmpty || !report.damaged.isEmpty
            show(isBad ? .warning : .info, tr("Folder checked: %@.", parts.joined(separator: ", ")), sticky: isBad)
        }
    }

    private func syncFromStore() {
        recordings = store.document.recordings
        pieces = store.document.pieces
        practiceLog = store.document.practiceLog
        selection = selection.intersection(Set(recordings.map(\.id)))
        if let currentPieceID, !pieces.contains(where: { $0.id == currentPieceID }) { self.currentPieceID = nil }
    }

    private func scheduleSave() {
        syncFromStore()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.store.saveInBackground { error in
                guard let error else { return }
                let text = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.show(.error, tr("The library could not be saved: %@", text), sticky: true)
                    }
                }
            }
        }
    }

    // MARK: Sound of a take (AmpBench)

    /// Writes the snapshot of what the amp plays now and returns its stamp, or nil without one. Only AmpBench
    /// provides the sound, from the editor's state in memory: no Bluetooth request, so nothing here can delay or
    /// end a recording. A snapshot that cannot be written leaves the take without a sound, never without audio.
    private func stampSound(for takeID: UUID) -> PresetStamp? {
        guard let sound = soundProvider?() else { return nil }
        // A listened-to sound has no preset to keep.
        guard let snapshot = sound.snapshot else { return sound.stamp }
        do {
            try store.writePresetSnapshot(snapshot, for: takeID)
            return sound.stamp
        } catch {
            return nil
        }
    }

    func presetSnapshot(of recording: Recording) -> Data? {
        store.presetSnapshot(of: recording.id)
    }

    // MARK: Banner

    func show(_ kind: Banner.Kind, _ text: String, sticky: Bool = false, canUndo: Bool = false,
              action: BannerAction? = nil) {
        bannerTask?.cancel()
        bannerUndoAction = nil
        banner = Banner(kind: kind, text: text, canUndo: canUndo, action: action)
        announce(text)
        guard !sticky else { return }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func announce(_ text: String) {
        guard let window = KeyRouter.activeWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: Devices

    var selectedInput: InputDevice? { inputs.first { $0.id == inputID } }

    /// The device playback really goes to, resolving "system output".
    var effectiveOutput: OutputDevice? {
        let id = outputID ?? AudioDevices.defaultOutputDevice()
        return outputs.first { $0.id == id }
    }

    var clickOutput: OutputDevice? {
        let preferred = outputs.first { $0.id == clickOutputID }
            ?? outputs.first { $0.id == AudioDevices.defaultOutputDevice() }
        return FeedbackGuard.safeOutput(for: selectedInput?.identity, among: outputs, preferred: preferred,
                                        measuredClean: measuredClean)
    }

    /// Why sound must not go to the chosen output during a recording, if so.
    var feedbackRisk: FeedbackRisk {
        FeedbackGuard.assess(input: selectedInput?.identity, output: effectiveOutput?.identity, measuredClean: measuredClean)
    }

    func refreshDevices() {
        // Everything else simply does not exist for the app, so it cannot be chosen or fallen back to.
        inputs = AudioDevices.inputDevices().filter(inputPolicy.allows)
        outputs = AudioDevices.outputDevices()
        sparkWithoutInput = inputs.isEmpty && !AudioDevices.sparkDevicesWithoutInput().isEmpty

        guard !isRecording else { return }
        resolveInput()
        resolveOutput()
        if let clickOutputID, !outputs.contains(where: { $0.id == clickOutputID }) { self.clickOutputID = nil }
    }

    /// The chosen input is remembered by its stable identifier, because device numbers can change when a device
    /// returns. Without an allowed device no input is selected, and a returning device only becomes selectable again:
    /// nothing starts listening by itself.
    private func resolveInput() {
        let preferredUID = defaults.string(forKey: "inputUID")
        let target = inputs.first { $0.uid == preferredUID } ?? selectedInput ?? inputs.first
        guard target?.id != inputID else { return }
        if isMonitoring || isRetroOn {
            turnOffListening()
            show(.warning, tr("The input is no longer available. Listening was stopped and the buffer cleared."))
        } else if isTuning {
            // The tuner reads the new input as soon as it asks again.
            turnOffListening()
        }
        inputID = target?.id
    }

    private func showNoSpark() {
        show(.warning, tr("No Spark connected. Without a Spark the app records nothing."))
    }

    private func resolveOutput() {
        guard let preferredUID = defaults.string(forKey: "outputUID") else { return }
        if let preferred = outputs.first(where: { $0.uid == preferredUID }) {
            if outputID != preferred.id {
                pausePlayhead()
                outputID = preferred.id
                try? playback.setOutput(preferred.id)
            }
        } else if outputID != nil {
            pausePlayhead()
            outputID = nil
            try? playback.setOutput(nil)
            show(.warning, tr("The output device is no longer available. Playback uses the system output until it is back."))
        }
    }

    private func restoreDeviceChoices() {
        if let uid = defaults.string(forKey: "outputUID"), let device = outputs.first(where: { $0.uid == uid }) {
            outputID = device.id
            try? playback.setOutput(device.id)
        }
        if let uid = defaults.string(forKey: "clickOutputUID"), let device = outputs.first(where: { $0.uid == uid }) {
            clickOutputID = device.id
        }
    }

    func chooseInput(_ id: AudioDeviceID?) {
        guard !isRecording, id != inputID, let id, inputs.contains(where: { $0.id == id }) else { return }
        inputID = id
        // Only an explicit choice changes what is remembered.
        defaults.set(selectedInput?.uid, forKey: "inputUID")
        if isMonitoring || isRetroOn {
            turnOffListening()
            show(.info, tr("The input was changed. Listening was stopped and the buffer cleared."))
        } else if isTuning {
            turnOffListening()
        }
    }

    func chooseOutput(_ id: AudioDeviceID?) {
        guard id != outputID else { return }
        pausePlayhead()
        outputID = id
        defaults.set(outputs.first { $0.id == id }?.uid, forKey: "outputUID")
        do {
            try playback.setOutput(id)
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func chooseClickOutput(_ id: AudioDeviceID?) {
        clickOutputID = id
        defaults.set(outputs.first { $0.id == id }?.uid, forKey: "clickOutputUID")
    }

    private func outputConfigurationChanged() {
        playhead.isPlaying = playback.isPlaying
        refreshDevices()
    }

    // MARK: Permission and level check

    private func requestMicrophone() async -> Bool {
        if await AVCaptureDevice.requestAccess(for: .audio) { return true }
        show(.error, tr("Microphone access is missing. Allow it under System Settings → Privacy & Security → Microphone."), sticky: true)
        return false
    }

    func toggleMonitor() {
        if isMonitoring {
            isMonitoring = false
            closeInputIfUnused()
            return
        }
        guard !isRecording else { return }
        guard let device = selectedInput else {
            showNoSpark()
            return
        }
        Task {
            guard await requestMicrophone() else { return }
            do {
                if !capture.isOpen { try capture.open(device: device) }
                signalMonitor.reset()
                isMonitoring = true
                monitorStartedAt = Date()
            } catch {
                show(.error, tr("The input could not be opened: %@", error.localizedDescription))
            }
        }
    }

    private func closeInputIfUnused() {
        guard !isRecording, !isMonitoring, !isRetroOn, !isTuning else { return }
        capture.close()
        resetMeter()
    }

    private func turnOffListening() {
        isMonitoring = false
        isRetroOn = false
        if let tunerTap { capture.detach(tunerTap) }
        tunerTap = nil
        isTuning = false
        if !isRecording {
            capture.close()
            resetMeter()
        }
    }

    private func resetMeter() {
        meter.level = 0
        meter.peakHold = 0
        meter.signal = .ok
        meter.retroSeconds = 0
        signalMonitor.reset()
    }

    func clearClip() {
        meter.clipped = false
    }

    // MARK: The tuner

    /// Lets the tuner read the input, opening it if it is closed. A running recording, the retro buffer and the level
    /// check keep their input exactly as it is.
    func startTuning(with tap: AudioTap) async throws {
        guard let device = selectedInput else { throw SharedInputError.noDevice }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SharedInputError.noPermission }
        // The device may have gone while permission was asked for.
        guard selectedInput?.id == device.id else { throw SharedInputError.noDevice }
        if !capture.isOpen {
            try capture.open(device: device)
            signalMonitor.reset()
        }
        capture.attach(tap)
        tunerTap = tap
        isTuning = true
    }

    func stopTuning(with tap: AudioTap) {
        guard tunerTap === tap else { return }
        capture.detach(tap)
        tunerTap = nil
        isTuning = false
        closeInputIfUnused()
    }

    func isTuning(with tap: AudioTap) -> Bool { isTuning && tunerTap === tap && capture.isAttached(tap) }

    /// True while something other than the tuner keeps the input open.
    var holdsInputForRecording: Bool { isRecording || isMonitoring || isRetroOn || phase != .idle }

    // MARK: Retro buffer

    func toggleRetro() {
        if isRetroOn {
            isRetroOn = false
            if isRecording {
                show(.info, tr("The buffer is cleared when the recording ends."))
            } else {
                // Reopening or closing the input frees the buffer and overwrites it with zeros.
                capture.close()
                resetMeter()
                // The tuner's tap stays attached to the engine and reads the reopened input.
                if isMonitoring || isTuning, let device = selectedInput { try? capture.open(device: device) }
                show(.info, tr("Retro recording off. The buffer in memory was cleared."))
            }
            return
        }
        guard !isRecording else {
            show(.info, tr("Retro recording can only be turned on after the running recording."))
            return
        }
        guard let device = selectedInput else {
            showNoSpark()
            return
        }
        Task {
            guard await requestMicrophone() else { return }
            do {
                capture.close()
                try capture.open(device: device, retroSeconds: retroMinutes * 60)
                signalMonitor.reset()
                isRetroOn = true
                show(.info, tr("Retro recording on. The input is listening; the buffer stays in memory."))
            } catch {
                show(.error, tr("The input could not be opened: %@", error.localizedDescription))
            }
        }
    }

    func setRetroMinutes(_ minutes: Double) {
        retroMinutes = minutes
        defaults.set(minutes, forKey: "retroMinutes")
        // A running buffer keeps its size. Changing it would throw away what was just played.
    }

    /// Saves the buffer on explicit request: "That was good". This is the only way it reaches the disk.
    func saveRetro(seconds: Double? = nil) {
        guard isRetroOn, let copy = capture.copyRetro(seconds: seconds ?? retroMinutes * 60) else {
            if isRetroOn { show(.info, tr("The buffer is still empty.")) }
            return
        }
        let now = Date()
        let url = store.uniqueName("Retro_\(LibraryStore.fileStamp(now))")
        let source = selectedInput.map(sourceFormat)
        let autoLevel = autoLevelDefault
        let pieceID = currentPieceID
        let binFrames = Int(CaptureEngine.overviewBinFrames)
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<AudioAnalyzer.Analysis?, Error> in
                Result {
                    try WAVWriter.write(samples: copy.samples, sampleRate: copy.sampleRate, channels: copy.channels, to: url)
                    return try AudioAnalyzer.analyze(url, binFrames: binFrames)
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let analysis):
                let seconds = Double(copy.samples.count / copy.channels) / copy.sampleRate
                let peak = analysis?.peak ?? 0
                var edit = EditList()
                edit.autoLevelEnabled = autoLevel
                edit.autoLevelDB = AutoLevel.gainDB(forPeak: peak)
                let recording = Recording(
                    fileName: url.lastPathComponent,
                    createdAt: now.addingTimeInterval(-seconds),
                    duration: seconds,
                    sampleRate: copy.sampleRate,
                    channels: copy.channels,
                    fileBits: 24,
                    source: source,
                    status: .open,
                    tags: ["Retro"],
                    pieceID: pieceID,
                    edit: edit,
                    peakDB: peak > 0 ? 20 * log10(Double(peak)) : nil
                )
                self.store.add(recording)
                self.store.logPractice(date: recording.createdAt, seconds: seconds, pieceID: pieceID)
                if let waveform = analysis?.waveform { self.saveWaveform(waveform, for: recording.id) }
                try? self.store.save()
                self.syncFromStore()
                self.show(.info, tr("The last %@ were saved as “%@”.", TimeText.clock(seconds), recording.name))
                if !self.isRecording { self.select(recording.id) }
            case .failure(let error):
                self.show(.error, tr("The buffer could not be saved: %@", error.localizedDescription), sticky: true)
            }
        }
    }

    // MARK: Recording

    private func sourceFormat(_ device: InputDevice) -> SourceFormat {
        SourceFormat(deviceName: device.name, bits: device.physicalBits, sampleRate: device.maxRate, channels: device.channels)
    }

    func toggleRecord() {
        switch phase {
        case .idle:
            pendingPunch = nil
            beginRecording()
        case .preparing:
            break
        case .countIn:
            cancelCountIn()
        case .recording:
            stopRecording(note: nil)
        }
    }

    private func beginRecording() {
        startRequestID += 1
        let request = startRequestID
        phase = .preparing
        Task { await startRecording(request: request) }
    }

    private func freeBytes() -> Int64 {
        let values = try? store.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    private func startRecording(request: Int) async {
        defer {
            if phase == .preparing { phase = .idle }
            pendingPunch = nil
        }
        guard libraryIsUsable else { return }
        refreshDevices()
        // Checked before asking for the microphone, so without a Spark the app does not even ask.
        guard selectedInput != nil else {
            showNoSpark()
            return
        }
        guard await requestMicrophone(), request == startRequestID else { return }
        refreshDevices()
        guard let device = selectedInput else {
            showNoSpark()
            return
        }
        guard freeBytes() > Self.minimumFreeBytes else {
            show(.error, tr("There is not enough space on the volume for a recording."), sticky: true)
            return
        }
        pausePlayhead()
        clearCompare()
        banner = nil

        do {
            try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
            if !capture.isOpen { try capture.open(device: device) }
            let now = Date()
            let punch = pendingPunch
            // A new file, always: re-recording bars must leave the take they come from as it is.
            let stem = punch.map { "\($0.sourceName) Takt \($0.bars.lowerBound)-\($0.bars.upperBound)" }
                ?? "Aufnahme_\(LibraryStore.fileStamp(now))"
            let url = store.uniqueName(stem)
            let source = sourceFormat(device)
            let takeID = UUID()
            let journal = RecordingJournal(
                fileName: url.lastPathComponent, startedAt: now, source: source,
                pieceID: punch.map(\.pieceID) ?? currentPieceID,
                punch: punch.map { PunchInfo(sourceID: $0.sourceID, bars: $0.bars) },
                takeID: takeID, preset: stampSound(for: takeID))
            try store.writeJournal(journal)

            var clickSettings = metronome
            if let punch {
                clickSettings.bpm = punch.grid.bpm
                clickSettings.beatsPerBar = punch.grid.beatsPerBar
                clickSettings.countInBars = max(metronome.countInBars, 1)
            }
            var gate: Int64?
            var beats = 0
            if clickSettings.countInBars > 0 {
                beats = clickSettings.countInBeats
                gate = await prepareCountIn(settings: clickSettings)
                if gate == nil { beats = 0 }
                if gate == nil, punch != nil {
                    // Without a count-in nobody can come in on the right bar, so nothing gets recorded.
                    store.removeJournal()
                    if !isMonitoring && !isRetroOn && !isTuning { capture.close() }
                    show(.warning, tr("The bars need a count-in, and the click could not start. Nothing was recorded."), sticky: true)
                    return
                }
            } else if metronome.clickEnabled && !click.isRunning {
                startClickForRecording(settings: clickSettings)
            }
            guard request == startRequestID else {
                click.stop()
                isClickRunning = false
                activeClickSettings = nil
                store.removeJournal()
                return
            }

            try capture.startRecording(to: url, gateFrame: gate)
            activeFile = url
            activeJournal = journal
            activeSource = source
            activeStart = now
            livePairs = []
            live.pairs = []
            pendingMarkerCount = 0
            meter.clipped = false
            meter.seconds = 0
            meter.droppedFrames = 0
            signalMonitor.reset()
            lastBannerForSignal = .ok
            activeCountInBeats = beats
            activePunch = punch
            activePunchBars = punch?.bars
            activeGrid = nil
            live.grid = nil
            live.secondsPerBin = Double(CaptureEngine.overviewBinFrames) / capture.sampleRate
            recordingFlag.set(true)
            phase = beats > 0 ? .countIn(beatsLeft: beats) : .recording
            isMonitoring = false
            applyPlaybackClick()
            NSApp.dockTile.badgeLabel = "REC"
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated, .latencyCritical],
                reason: tr("Recording in progress"))
            announce(beats > 0 ? tr("Count-in") : tr("Recording in progress"))
        } catch {
            store.removeJournal()
            if !isMonitoring && !isRetroOn && !isTuning { capture.close() }
            show(.error, tr("The recording could not start: %@", error.localizedDescription), sticky: true)
        }
    }

    /// Starts the click for a count-in and returns the input frame the recording begins at, or nil when no click
    /// is possible.
    private func prepareCountIn(settings: MetronomeSettings) async -> Int64? {
        guard let output = clickOutput else {
            show(.warning, tr("No safe output found for the click. The recording starts without a count-in."))
            return nil
        }
        do {
            click.stop()
            try startClick(on: output, settings: settings)
            // Without the click switched on it falls silent after the count-in but keeps counting the bars.
            if !settings.clickEnabled { click.muteAfter(beats: settings.countInBeats) }
            if let anchor = await click.waitForAnchor() {
                return ClickTiming.gateFrame(anchorFrame: anchor, beatsBefore: settings.countInBeats, bpm: settings.bpm,
                                             inputRate: capture.sampleRate, preRoll: Self.countInPreRoll)
            }
            show(.warning, tr("The click did not start. The recording starts without a count-in."))
        } catch {
            show(.warning, tr("The click could not start: %@ The recording starts without a count-in.", error.localizedDescription))
        }
        click.stop()
        isClickRunning = false
        activeClickSettings = nil
        return nil
    }

    private func startClickForRecording(settings: MetronomeSettings) {
        guard let output = clickOutput else {
            show(.warning, tr("No safe output found for the click. The recording runs without a click."))
            return
        }
        do {
            try startClick(on: output, settings: settings)
        } catch {
            show(.warning, tr("The click could not start: %@", error.localizedDescription))
        }
    }

    /// Starts the click on the input's clock, so its beats lie on input frames and cannot drift from the file.
    private func startClick(on output: OutputDevice, settings: MetronomeSettings) throws {
        guard let clock = capture.clock else { throw CaptureError.notOpen }
        try click.start(device: output.id, settings: settings, clock: clock)
        activeClickSettings = settings
        activeLatency = ClickLatency(output: click.reportedOutputLatency, input: capture.reportedInputLatency,
                                     correction: latencyCorrection(output: output))
        isClickRunning = true
    }

    /// Works out where the bars lie in the file, from the input frames the click and the file are placed on.
    private func resolveGrid() {
        guard activeGrid == nil, click.isRunning, let settings = activeClickSettings,
              let fileFirst = capture.fileFirstFrame, let anchor = click.anchorFrame else { return }
        let offset = ClickTiming.gridOffset(anchorFrame: anchor, beatsBefore: activeCountInBeats, bpm: settings.bpm,
                                            inputRate: capture.sampleRate, fileFirstFrame: fileFirst,
                                            latency: activeLatency)
        let grid = BeatGrid(bpm: settings.bpm, beatsPerBar: settings.beatsPerBar, offset: offset,
                            firstBar: activePunch?.bars.lowerBound ?? 1)
        activeGrid = grid
        live.grid = grid
        if let bars = activePunch?.bars {
            punchStopAt = grid.time(ofBar: bars.upperBound + 1) + Self.punchTailSeconds
        }
        guard var journal = activeJournal else { return }
        journal.grid = grid
        activeJournal = journal
        let snapshot = journal
        let store = store
        journalQueue.async { try? store.writeJournal(snapshot) }
    }

    private func cancelCountIn() {
        let result = capture.stopRecording()
        finishListeningAfterRecording()
        if let result, result.frames == 0 {
            try? FileManager.default.removeItem(at: result.url)
        }
        store.removeJournal()
        activeFile = nil
        activeJournal = nil
        show(.info, tr("The count-in was canceled."))
    }

    private func finishListeningAfterRecording() {
        recordingFlag.set(false)
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
        NSApp.dockTile.badgeLabel = nil
        phase = .idle
        click.stop()
        isClickRunning = false
        activeClickSettings = nil
        activeGrid = nil
        live.grid = nil
        activePunch = nil
        activePunchBars = nil
        punchStopAt = nil
        activeCountInBeats = 0
        activeLatency = ClickLatency()
        meter.beat = 0
        applyPlaybackClick()
        // Keep the input open only for features that still need it. A buffer turned off during the take ends here.
        if !isRetroOn && !isTuning {
            capture.close()
            isMonitoring = false
            resetMeter()
        } else if !isRetroOn {
            isMonitoring = false
        }
    }

    func stopRecording(note: String?) {
        resolveGrid()
        guard let journal = activeJournal, let source = activeSource else { return }
        let start = activeStart
        let punch = activePunch
        let result = capture.stopRecording()
        livePairs += capture.readOverview()
        let pairs = livePairs
        let rate = capture.sampleRate
        let channels = capture.channels
        let markers = activeJournal?.markers ?? []
        journalQueue.sync {}
        finishListeningAfterRecording()
        activeFile = nil
        activeJournal = nil
        activeSource = nil

        guard let result else {
            store.removeJournal()
            return
        }
        if result.frames == 0 {
            try? FileManager.default.removeItem(at: result.url)
            store.removeJournal()
            show(.warning, note ?? tr("Nothing was recorded because the device delivered no data."), sticky: note != nil)
            return
        }

        let peak = result.peak
        var edit = EditList()
        edit.autoLevelEnabled = autoLevelDefault
        edit.autoLevelDB = AutoLevel.gainDB(forPeak: peak)
        let recording = Recording(
            id: journal.takeID ?? UUID(),
            fileName: journal.fileName,
            createdAt: start,
            duration: result.seconds,
            sampleRate: rate,
            channels: channels,
            fileBits: 24,
            source: source,
            status: .open,
            tags: journal.punch == nil ? [] : ["Neuaufnahme"],
            markers: markers,
            pieceID: journal.pieceID,
            edit: edit,
            peakDB: peak > 0 ? 20 * log10(Double(peak)) : nil,
            grid: journal.grid,
            punch: journal.punch,
            preset: journal.preset
        )
        store.add(recording)
        store.logPractice(date: start, seconds: result.seconds, pieceID: journal.pieceID)
        do {
            try store.save()
            // The journal goes only after the recording is safely in the library.
            if result.finalized { store.removeJournal() }
        } catch {
            show(.error, tr("The library could not be saved: %@", error.localizedDescription), sticky: true)
        }
        syncFromStore()

        if result.overviewComplete {
            let waveform = WaveformData(binFrames: Int(CaptureEngine.overviewBinFrames), sampleRate: rate, pairs: pairs)
            saveWaveform(waveform, for: recording.id)
            currentWaveform = waveform
        }
        select(recording.id, waveformReady: result.overviewComplete)
        tab = .recordings
        summarize(result, note: note, punch: punch)
    }

    private func summarize(_ result: RecordingResult, note: String?, punch: PunchRequest? = nil) {
        if let note {
            show(.warning, note, sticky: true)
        } else if let error = result.writeError {
            show(.error, tr("An error occurred while writing (error %@). The take has gaps.", "\(error)"), sticky: true)
        } else if result.droppedFrames > 0 {
            show(.warning, tr("%@ of audio were lost because the disk was not fast enough.", TimeText.clock(Double(result.droppedFrames) / max(capture.sampleRate, 44_100), tenths: true)), sticky: true)
        } else if result.peak == 0 {
            show(.warning, tr("The file is completely silent. The device delivered no signal."), sticky: true)
        } else if result.clippedBlocks > 0 {
            show(.warning, tr("Saved, but the signal clipped. Play more quietly or lower the level on the device."), sticky: true)
        } else if let punch {
            show(.info, tr("%@ recorded again, as a separate take. “%@” stays unchanged.", Self.barsText(punch.bars), punch.sourceName))
        } else {
            announce(tr("Take saved. %@.", TimeText.spoken(result.seconds)))
        }
    }

    private func inputInterrupted(_ reason: CaptureInterruption) {
        let note: String
        switch reason {
        case .deviceLost:
            note = tr("The audio connection was interrupted. The recording up to that point is saved.")
        case .sampleRateChanged:
            note = tr("Another app changed the device's sample rate. The recording up to that point is saved.")
        }
        let wasRecording = isRecording
        if wasRecording {
            if case .countIn = phase {
                cancelCountIn()
                show(.warning, tr("The audio connection was interrupted."), sticky: true)
            } else {
                // The retro buffer depends on the lost input too.
                isRetroOn = false
                stopRecording(note: note)
            }
        } else if isMonitoring || isRetroOn {
            turnOffListening()
            show(.warning, tr("The audio connection was interrupted. Listening was stopped and the buffer cleared."), sticky: true)
        } else if isTuning {
            // The tuner says so itself, and reads again once the device is back.
            turnOffListening()
        }
        refreshDevices()
    }

    func addMarker() {
        if case .recording = phase {
            guard var journal = activeJournal else { return }
            let time = capture.recordedSeconds
            let number = journal.markers.count + 1
            journal.markers.append(Marker(time: time, label: "Marker \(number)"))
            activeJournal = journal
            pendingMarkerCount = journal.markers.count
            announce(tr("Marker %d", number))
            let snapshot = journal
            let store = store
            journalQueue.async { try? store.writeJournal(snapshot) }
            return
        }
        guard let id = currentID, !isRecording else { return }
        let time = playback.position
        store.update(id) {
            $0.markers.append(Marker(time: time, label: "Marker \($0.markers.count + 1)"))
            $0.markers.sort { $0.time < $1.time }
        }
        scheduleSave()
        announce(tr("Marker at %@", TimeText.clock(time)))
    }

    func removeMarker(_ marker: Marker, from id: UUID) {
        store.update(id) { $0.markers.removeAll { $0.id == marker.id } }
        scheduleSave()
    }

    func renameMarker(_ marker: Marker, in id: UUID, to label: String) {
        store.update(id) { recording in
            guard let index = recording.markers.firstIndex(where: { $0.id == marker.id }) else { return }
            recording.markers[index].label = label
        }
        scheduleSave()
    }

    // MARK: Regular updates

    private func tick() {
        let elapsed = 1.0 / 30.0
        if capture.isOpen {
            let level = capture.takeLevel()
            // Devices with large buffers deliver less often than the display refreshes, so the meter falls smoothly.
            meter.level = max(level, meter.level * 0.82)
            peakHoldAge += elapsed
            if level >= meter.peakHold || peakHoldAge > 1.5 {
                meter.peakHold = max(level, meter.level)
                peakHoldAge = 0
            }
            if capture.takeClip() {
                if !meter.clipped { announce(tr("Signal clipping")) }
                meter.clipped = true
            }
            signalMonitor.update(level: level, callbackCount: capture.callbackCount, elapsed: elapsed)
            if meter.signal != signalMonitor.status { meter.signal = signalMonitor.status }
            if signalMonitor.status != lastBannerForSignal {
                lastBannerForSignal = signalMonitor.status
                if signalMonitor.status == .noData { announce(tr("The input delivers no data")) }
                if signalMonitor.status == .silent { announce(tr("No signal")) }
            }
            if isRetroOn { meter.retroSeconds = capture.retroAvailableSeconds }
            if isMonitoring, Date().timeIntervalSince(monitorStartedAt) > Self.monitorMaxSeconds {
                isMonitoring = false
                closeInputIfUnused()
                show(.info, tr("“Check input” ended automatically after two minutes."))
            }
        }
        if isRecording { recordingTick(elapsed) }
        let playing = playback.isPlaying
        if click.isRunning {
            let beat = click.beatCount
            if meter.beat != beat { meter.beat = beat }
        } else if playing, let grid = playbackClickGrid, let index = grid.beatIndex(at: playback.position) {
            let beat = UInt64(index + 1)
            if meter.beat != beat { meter.beat = beat }
        } else if meter.beat != 0 {
            meter.beat = 0
        }
        if playhead.isPlaying != playing { playhead.isPlaying = playing }
        if playing || playhead.position == 0 {
            let position = playback.position
            if abs(position - playhead.position) > 0.005 { playhead.position = position }
        }
    }

    private func recordingTick(_ elapsed: Double) {
        meter.seconds = capture.recordedSeconds
        resolveGrid()
        if meter.droppedFrames != capture.droppedFrames { meter.droppedFrames = capture.droppedFrames }
        let bins = capture.readOverview()
        if !bins.isEmpty {
            livePairs += bins
            live.pairs = livePairs
        }
        if case .countIn = phase {
            if capture.recordedFrames > Int64(Self.countInPreRoll * capture.sampleRate) {
                phase = .recording
                announce(tr("Recording in progress"))
            } else if click.isRunning {
                let total = activeClickSettings?.countInBeats ?? metronome.countInBeats
                let left = max(total - Int(click.beatCount) + 1, 1)
                if phase != .countIn(beatsLeft: left) { phase = .countIn(beatsLeft: left) }
            }
        }
        if let punchStopAt, capture.recordedSeconds >= punchStopAt {
            stopRecording(note: nil)
            return
        }
        diskCheckAge += elapsed
        if diskCheckAge >= 5 {
            diskCheckAge = 0
            let bytes = capture.recordedFrames * Int64(capture.channels) * 3
            if bytes > Self.maximumFileBytes {
                stopRecording(note: tr("The recording reached the size limit of a WAV file and was ended safely."))
            } else if freeBytes() < Self.criticalFreeBytes {
                stopRecording(note: tr("The disk is almost full. The recording was ended safely."))
            }
        }
    }

    // MARK: Selection and loading

    var current: Recording? { currentID.flatMap { id in recordings.first { $0.id == id } } }

    var visibleRecordings: [Recording] {
        query.filter(recordings, pieces: pieces).sorted(using: sortOrder)
    }

    func select(_ id: UUID, waveformReady: Bool = false) {
        selection = [id]
        load(id, waveformReady: waveformReady)
    }

    func selectionChanged() {
        guard selection.count == 1, let id = selection.first else { return }
        guard id != currentID else { return }
        load(id)
    }

    private func load(_ id: UUID, waveformReady: Bool = false, startAt: Double? = nil, keepPlaying: Bool = false) {
        guard let recording = store.recording(id) else { return }
        // A running recording owns attention, but listening to another take stays possible.
        let wasPlaying = keepPlaying && playback.isPlaying
        if !waveformReady { currentWaveform = nil }
        currentID = id
        if !compareIDs.contains(id) { clearCompare() }
        loopRange = nil
        loopStart = nil
        barSelection = recording.grid.flatMap { grid in
            recording.lastBar.map { grid.firstBar...min(grid.firstBar + 3, $0) }
        }
        applyPlaybackClick()
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false

        guard recording.health == .ok else {
            playback.unload()
            playhead.position = 0
            return
        }
        do {
            try playback.load(url: store.url(of: recording), edit: recording.edit, startAt: startAt)
            playhead.position = playback.position
            playhead.isPlaying = false
            if wasPlaying { try playback.play() }
        } catch {
            playback.unload()
            show(.error, error.localizedDescription)
        }
        if !waveformReady { loadWaveform(for: recording) }
    }

    private func saveWaveform(_ waveform: WaveformData, for id: UUID) {
        let url = store.peaksURL(of: id)
        let folder = store.peaksFolder
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? waveform.write(to: url)
        }
    }

    /// Loads the waveform from its cache, or reads the file in the background while no recording is running.
    private func loadWaveform(for recording: Recording, into compare: Bool = false) {
        let id = recording.id
        let peaksURL = store.peaksURL(of: id)
        let fileURL = store.url(of: recording)
        let binFrames = Int(CaptureEngine.overviewBinFrames)
        let flag = recordingFlag
        isAnalyzing = !compare
        analysisTask = Task { [weak self] in
            let cached = await Task.detached(priority: .userInitiated) { WaveformData.read(from: peaksURL) }.value
            if Task.isCancelled { return }
            if let cached {
                self?.waveformLoaded(cached, for: id, compare: compare)
                return
            }
            let analysisTask = Task.detached(priority: .utility) { () -> AudioAnalyzer.Analysis? in
                try? AudioAnalyzer.analyze(fileURL, binFrames: binFrames, shouldPause: { flag.isSet },
                                           isCancelled: { Task.isCancelled })
            }
            let analysis = await withTaskCancellationHandler {
                await analysisTask.value
            } onCancel: {
                analysisTask.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            guard let analysis else {
                self.isAnalyzing = false
                return
            }
            self.saveWaveform(analysis.waveform, for: id)
            let peak = analysis.peak
            self.store.update(id) { recording in
                recording.peakDB = peak > 0 ? 20 * log10(Double(peak)) : nil
                recording.edit.autoLevelDB = AutoLevel.gainDB(forPeak: peak)
            }
            self.scheduleSave()
            self.waveformLoaded(analysis.waveform, for: id, compare: compare)
        }
    }

    private func waveformLoaded(_ waveform: WaveformData, for id: UUID, compare: Bool) {
        if compare {
            compareWaveforms[id] = waveform
        } else if currentID == id {
            currentWaveform = waveform
            isAnalyzing = false
        }
    }

    // MARK: Transport

    private func pausePlayhead() {
        playback.pause()
        playhead.isPlaying = false
    }

    /// Space plays or pauses. During a recording it stops it and plays the new take right away, so listening back
    /// is one key. During the count-in it cancels, like R.
    func spaceBarPressed() {
        switch phase {
        case .idle:
            togglePlay()
        case .preparing:
            break
        case .countIn:
            toggleRecord()
        case .recording:
            let before = currentID
            stopRecording(note: nil)
            // Plays only a take that this recording produced, never an older one when nothing was saved.
            guard phase == .idle, let id = currentID, id != before, current?.health == .ok else { return }
            if !playback.isPlaying { togglePlay() }
        }
    }

    func togglePlay() {
        if playback.isPlaying {
            pausePlayhead()
            playhead.position = playback.position
            return
        }
        if currentID == nil || current?.health != .ok {
            guard let first = visibleRecordings.first(where: { $0.health == .ok }) else { return }
            select(first.id)
        }
        if isRecording, let reason = FeedbackGuard.explanation(feedbackRisk) {
            show(.warning, reason)
            return
        }
        do {
            try playback.play()
            playhead.isPlaying = true
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func seek(to seconds: Double) {
        playback.seek(to: seconds)
        playhead.position = playback.position
    }

    func nudge(by seconds: Double) {
        guard current != nil else { return }
        let target = min(max(playback.position + seconds, 0), current?.duration ?? 0)
        seek(to: target)
    }

    private func playback(finished: Void) {
        playhead.isPlaying = false
        playhead.position = playback.position
    }

    func setTempo(_ value: Double) {
        tempo = min(max((value * 100).rounded() / 100, PlaybackEngine.tempoRange.lowerBound), PlaybackEngine.tempoRange.upperBound)
        applyTempo()
    }

    func setPitch(_ value: Double) {
        pitch = min(max(value, PlaybackEngine.pitchRange.lowerBound), PlaybackEngine.pitchRange.upperBound)
        applyTempo()
    }

    func resetTempoAndPitch() {
        tempo = 1
        pitch = 0
        applyTempo()
    }

    private func applyTempo() {
        playback.setTempo(tempo, pitchSemitones: pitch)
    }

    // MARK: Loop

    /// First press sets A, second sets B and starts the loop, third removes it.
    func toggleLoop() {
        guard current != nil else { return }
        if loopRange != nil {
            clearLoop()
            return
        }
        let position = playback.position
        if let start = loopStart {
            let lower = min(start, position)
            let upper = max(start, position)
            if upper - lower >= 0.05 {
                setLoop(lower...upper)
            }
            loopStart = nil
        } else {
            loopStart = position
            announce(tr("Loop start at %@", TimeText.clock(position)))
        }
    }

    func setLoop(_ range: ClosedRange<Double>) {
        loopStart = nil
        loopRange = range
        playback.setLoop(range)
        playhead.position = playback.position
        announce(tr("Loop from %@ to %@", TimeText.clock(range.lowerBound), TimeText.clock(range.upperBound)))
    }

    func clearLoop() {
        loopStart = nil
        loopRange = nil
        playback.setLoop(nil)
        announce(tr("Loop off"))
    }

    // MARK: Bars

    static func barsText(_ bars: ClosedRange<Int>) -> String {
        bars.count == 1 ? tr("Bar %d", bars.lowerBound) : tr("Bars %d–%d", bars.lowerBound, bars.upperBound)
    }

    /// True while the loop covers exactly the chosen bars.
    var isLoopingBars: Bool {
        guard let recording = current, let grid = recording.grid, let bars = barSelection, let loopRange,
              let range = grid.loopRange(bars: bars, duration: recording.duration) else { return false }
        return abs(range.lowerBound - loopRange.lowerBound) < 0.001 && abs(range.upperBound - loopRange.upperBound) < 0.001
    }

    /// Chooses bars. A loop on the bars chosen so far moves along.
    func setBarSelection(_ bars: ClosedRange<Int>) {
        guard let recording = current, let grid = recording.grid, let last = recording.lastBar else { return }
        let wasLooping = isLoopingBars
        let lower = min(max(bars.lowerBound, grid.firstBar), last)
        let upper = min(max(bars.upperBound, lower), last)
        barSelection = lower...upper
        if wasLooping { loopSelectedBars() }
    }

    func loopSelectedBars() {
        guard let recording = current, let grid = recording.grid, let bars = barSelection,
              let range = grid.loopRange(bars: bars, duration: recording.duration) else { return }
        setLoop(range)
        seek(to: range.lowerBound)
    }

    func toggleBarLoop() {
        if isLoopingBars {
            clearLoop()
        } else {
            loopSelectedBars()
        }
    }

    var canRecordBars: Bool {
        guard phase == .idle, libraryIsUsable, compareIDs.isEmpty, selectedInput != nil, barSelection != nil,
              let recording = current else { return false }
        return recording.grid != nil && recording.health == .ok
    }

    /// Records the chosen bars again after a count-in, at the tempo of the take, as a recording of its own. It stops by
    /// itself after the last bar. The take the bars come from is not touched.
    func recordSelectedBars() {
        guard canRecordBars, let source = current, let grid = source.grid, let bars = barSelection else { return }
        guard clickOutput != nil else {
            show(.warning, tr("No safe output found for the click. Without a count-in, bars cannot be recorded again."))
            return
        }
        pendingPunch = PunchRequest(sourceID: source.id, sourceName: source.name, pieceID: source.pieceID, grid: grid, bars: bars)
        beginRecording()
    }

    // MARK: Review decisions

    func keep(_ id: UUID? = nil) {
        guard let target = id ?? (selection.count == 1 ? selection.first : nil) ?? currentID else { return }
        guard let previous = store.recording(target)?.status, previous == .open else { return }
        store.update(target) { $0.status = .kept }
        scheduleSave()
        announce(tr("Kept"))
        registerUndo(tr("Keep")) { model in
            model.store.update(target) { $0.status = previous }
            model.scheduleSave()
        }
    }

    /// Moves recordings to the Trash, reachable only with an explicit command and always undoable.
    func discard(_ ids: Set<UUID>? = nil) {
        guard !isRecording else { return }
        let targets = RemovalTargets.resolve(menuIDs: ids ?? [], selection: selection, current: currentID)
        guard !targets.isEmpty else {
            show(.info, tr("First select the take that should go to the Trash."))
            return
        }
        // The focus moves on to the next take when the one in focus goes, or when nothing is in focus and everything
        // marked goes. A take in focus that stays keeps the focus and keeps playing.
        let losesFocus = currentID.map(targets.contains)
            ?? (!selection.isEmpty && selection.isSubset(of: targets))
        let order = visibleRecordings.map(\.id)
        if targets.contains(currentID ?? UUID()) || compareIDs.contains(where: targets.contains) {
            pausePlayhead()
            playback.unload()
            currentID = nil
            currentWaveform = nil
            clearCompare()
            playhead.position = 0
        }
        var entries: [TrashedRecording] = []
        for id in targets {
            do {
                entries.append(try store.trash(id))
            } catch {
                show(.error, error.localizedDescription, sticky: true)
            }
        }
        guard !entries.isEmpty else { return }
        scheduleSave()
        let removed = Set(entries.map(\.recording.id))
        selection.subtract(removed)
        if losesFocus {
            // Selected and loaded, never played: playback stopped with the removed take and stays stopped.
            if let next = RemovalTargets.nextFocus(in: order, removing: removed) {
                select(next)
            } else {
                selection = []
            }
        }
        let label = entries.count == 1 ? tr("“%@” is in the Trash.", entries[0].recording.name) : tr("%d takes are in the Trash.", entries.count)
        show(.info, label, canUndo: true)
        lastTrashed = entries
        registerUndo(tr("Move to Trash")) { model in
            model.restore(entries)
        }
    }

    private var lastTrashed: [TrashedRecording] = []

    private func restore(_ entries: [TrashedRecording]) {
        var restored: [UUID] = []
        for entry in entries {
            do {
                try store.restore(entry)
                restored.append(entry.recording.id)
            } catch {
                show(.error, tr("“%@”: %@", entry.recording.name, error.localizedDescription), sticky: true)
            }
        }
        guard !restored.isEmpty else { return }
        scheduleSave()
        // What comes back is in focus again, as it was before it went.
        if restored.count == 1, let id = restored.first {
            select(id)
        } else if let first = visibleRecordings.first(where: { restored.contains($0.id) }) {
            selection = Set(restored)
            load(first.id)
        }
        banner = nil
        announce(tr("Restored"))
        let ids = Set(restored)
        registerUndo(tr("Move to Trash")) { model in
            model.discard(ids)
        }
    }

    /// The banner's undo button and the menu entry that also works after a restart.
    func undoLastDiscard() {
        if let action = bannerUndoAction {
            bannerUndoAction = nil
            banner = nil
            action(self)
        } else if !lastTrashed.isEmpty {
            let entries = lastTrashed
            lastTrashed = []
            restore(entries)
        } else {
            restoreLastTrashed()
        }
    }

    func restoreLastTrashed() {
        guard let entry = store.lastRestorable else {
            show(.info, tr("There is no discarded take left in the Trash."))
            return
        }
        restore([entry])
    }

    var canRestoreLastTrashed: Bool { store.lastRestorable != nil }

    private func registerUndo(_ name: String, _ action: @escaping @MainActor (AppModel) -> Void) {
        guard let manager = (KeyRouter.activeWindow ?? NSApp.mainWindow)?.undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { action(target) }
        }
        manager.setActionName(name)
    }

    // MARK: Editing metadata

    func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<Recording, Value>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { [weak self] in self?.store.recording(id)?[keyPath: keyPath] ?? fallback },
            set: { [weak self] value in
                self?.store.update(id) { $0[keyPath: keyPath] = value }
                self?.scheduleSave()
            }
        )
    }

    func setRating(_ rating: Int, for id: UUID? = nil) {
        guard let target = id ?? currentID else { return }
        store.update(target) { $0.rating = $0.rating == rating ? 0 : rating }
        scheduleSave()
        announce(tr("%d stars", store.recording(target)?.rating ?? 0))
    }

    func toggleFavorite(_ id: UUID? = nil) {
        guard let target = id ?? currentID else { return }
        store.update(target) { $0.favorite.toggle() }
        scheduleSave()
        announce(store.recording(target)?.favorite == true ? tr("Favorite") : tr("Not a favorite"))
    }

    func setTags(_ text: String, for id: UUID) {
        let tags = LibraryQuery.parseTags(text)
        store.update(id) { $0.tags = tags }
        scheduleSave()
    }

    func beginRename(_ id: UUID? = nil) {
        guard let target = id ?? (selection.count == 1 ? selection.first : nil) ?? currentID,
              let recording = store.recording(target) else { return }
        renameText = recording.name
        renameTarget = target
    }

    func commitRename() {
        guard let target = renameTarget else { return }
        renameTarget = nil
        rename(target, to: renameText)
    }

    func rename(_ id: UUID, to name: String) {
        guard let previous = store.recording(id)?.name else { return }
        do {
            try store.rename(id, to: name)
            scheduleSave()
            if currentID == id, let recording = store.recording(id) {
                // The open file handle stays valid, but reloading keeps every later read on the new path.
                let position = playback.position
                let wasPlaying = playback.isPlaying
                try? playback.load(url: store.url(of: recording), edit: recording.edit, startAt: position)
                if wasPlaying { try? playback.play() }
                if let loopRange { playback.setLoop(loopRange) }
            }
            registerUndo(tr("Rename")) { model in
                model.rename(id, to: previous)
            }
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func reveal(_ id: UUID? = nil) {
        let targets = id.map { [$0] } ?? (selection.isEmpty ? [currentID].compactMap { $0 } : Array(selection))
        let urls = targets.compactMap { store.recording($0) }.map { store.url(of: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealLibraryFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.folder])
    }

    // MARK: Edits

    func updateEdit(_ id: UUID, _ change: (inout EditList) -> Void) {
        store.update(id) { change(&$0.edit) }
        if id == currentID, let edit = store.recording(id)?.edit { playback.setEdit(edit) }
        scheduleSave()
    }

    func resetEdits(_ id: UUID) {
        updateEdit(id) { edit in
            let enabled = edit.autoLevelEnabled
            let level = edit.autoLevelDB
            edit = EditList(autoLevelEnabled: enabled, autoLevelDB: level)
        }
    }

    func setTrimStartToPlayhead() {
        guard let id = currentID else { return }
        let position = playback.position
        updateEdit(id) { edit in
            edit.trimStart = position
            if let end = edit.trimEnd, end <= position { edit.trimEnd = nil }
        }
    }

    func setTrimEndToPlayhead() {
        guard let id = currentID else { return }
        let position = playback.position
        updateEdit(id) { edit in
            guard position > edit.trimStart else { return }
            edit.trimEnd = position
        }
    }

    // MARK: Export

    func export(_ format: ExportFormat, id: UUID? = nil) {
        guard let target = id ?? currentID, let recording = store.recording(target), !isRecording else {
            if isRecording { show(.info, tr("Export after the recording has ended.")) }
            return
        }
        let panel = NSSavePanel()
        try? FileManager.default.createDirectory(at: store.exportFolder, withIntermediateDirectories: true)
        panel.directoryURL = store.exportFolder
        panel.nameFieldStringValue = "\(recording.name).\(format.fileExtension)"
        panel.title = tr("Export (%@)", format.label)
        panel.message = tr("The original stays unchanged. Edits are rendered into the new file.")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        runExport(of: recording, format: format, to: destination)
    }

    func runExport(of recording: Recording, format: ExportFormat, to destination: URL) {
        let source = store.url(of: recording)
        let edit = recording.edit
        exportProgress = 0
        Task { [weak self] in
            let progress: @Sendable (Double) -> Void = { value in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.exportProgress = value }
                }
            }
            let outcome = await Task.detached(priority: .utility) {
                Result { try Exporter.export(source: source, edit: edit, format: format, to: destination, progress: progress) }
            }.value
            guard let self else { return }
            self.exportProgress = nil
            switch outcome {
            case .success(let result):
                if result.clipped {
                    self.show(.warning, tr("Exported to “%@”, but the level exceeded full scale. Lower the gain.", result.url.lastPathComponent), sticky: true)
                } else {
                    self.show(.info, tr("Exported to “%@”.", result.url.lastPathComponent))
                }
            case .failure(let error):
                self.show(.error, tr("The export failed: %@", error.localizedDescription), sticky: true)
            }
        }
    }

    // MARK: Pieces

    func addPiece(named name: String, makeCurrent: Bool = true) {
        guard let piece = store.addPiece(named: name) else { return }
        if makeCurrent { setCurrentPiece(piece.id) }
        scheduleSave()
    }

    func setCurrentPiece(_ id: UUID?) {
        currentPieceID = id
        defaults.set(id?.uuidString, forKey: "currentPiece")
    }

    /// Returns false when the title cannot be used, and says why.
    @discardableResult
    func renamePiece(_ id: UUID, to name: String) -> Bool {
        guard let previous = store.document.pieces.first(where: { $0.id == id })?.name else { return false }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned != previous else { return true }
        guard store.renamePiece(id, to: cleaned) else {
            show(.info, cleaned.isEmpty ? tr("A piece needs a title.") : tr("There is already a piece with the title “%@”.", cleaned))
            return false
        }
        scheduleSave()
        registerUndo(tr("Rename piece")) { model in
            model.renamePiece(id, to: previous)
        }
        return true
    }

    /// Asks for the title of a new piece. The given recordings join it.
    func beginNewPiece(assigning ids: Set<UUID> = []) {
        newPieceName = ""
        newPieceTargets = ids
    }

    func commitNewPiece() {
        guard let targets = newPieceTargets else { return }
        newPieceTargets = nil
        guard let piece = store.addPiece(named: newPieceName) else { return }
        for id in targets { store.assign(id, toPiece: piece.id) }
        // A piece made for marked takes does not change where new recordings go.
        if targets.isEmpty { setCurrentPiece(piece.id) }
        scheduleSave()
    }

    func removePiece(_ id: UUID) {
        let wasCurrent = currentPieceID == id
        guard let removed = store.removePiece(id) else { return }
        if wasCurrent { setCurrentPiece(nil) }
        if query.piece == .piece(id) { query.piece = nil }
        scheduleSave()
        let restore: @MainActor (AppModel) -> Void = { model in
            model.store.restorePiece(removed)
            if wasCurrent { model.setCurrentPiece(id) }
            model.scheduleSave()
            model.announce(tr("Piece restored"))
        }
        show(.info, tr("The piece “%@” is removed. Its takes stay in the list.", removed.piece.name), canUndo: true)
        bannerUndoAction = restore
        registerUndo(tr("Remove piece"), restore)
    }

    func assign(_ ids: Set<UUID>, toPiece pieceID: UUID?) {
        for id in ids { store.assign(id, toPiece: pieceID) }
        scheduleSave()
    }

    func toggleBestTake(_ id: UUID? = nil) {
        guard let target = id ?? currentID else { return }
        guard store.recording(target)?.pieceID != nil else {
            show(.info, tr("First assign the take to a piece, then you can mark it as the best take."))
            return
        }
        store.toggleBestTake(target)
        scheduleSave()
    }

    func isBestTake(_ recording: Recording) -> Bool {
        pieces.first { $0.id == recording.pieceID }?.bestTakeID == recording.id
    }

    func takes(of pieceID: UUID) -> [Recording] {
        recordings.filter { $0.pieceID == pieceID }.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Pieces as songs

    /// Songs from an import: new pieces with their parts and sounds. Existing titles stay as they are.
    func addImportedPieces(_ pieces: [RecorderHost.NewPiece]) -> (added: Int, kept: [String]) {
        var added = 0
        var kept: [String] = []
        for new in pieces {
            let title = new.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            if store.document.pieces.contains(where: { $0.name.caseInsensitiveCompare(title) == .orderedSame }) {
                kept.append(title)
                continue
            }
            guard let piece = store.addPiece(named: title) else { continue }
            store.updatePiece(piece.id) { piece in
                piece.notes = new.notes
                piece.parts = new.parts.map { PiecePart(name: $0.name, preset: $0.preset) }
            }
            added += 1
        }
        if added > 0 {
            objectWillChange.send()
            scheduleSave()
        }
        return (added, kept)
    }

    func updatePiece(_ id: UUID, _ change: (inout Piece) -> Void) {
        store.updatePiece(id, change)
        scheduleSave()
    }

    /// Recorded time of a piece, discarded takes included.
    func practiceSeconds(of pieceID: UUID) -> Double {
        practiceLog.filter { $0.pieceID == pieceID }.reduce(0) { $0 + $1.seconds }
    }

    /// Sets the click to the piece's tempo. Like any tempo set by hand, AmpBench offers it to the open preset.
    func useTempo(of piece: Piece) {
        guard let bpm = piece.bpm else { return }
        updateMetronome { $0.bpm = bpm }
    }

    func pieceName(_ id: UUID?) -> String {
        pieces.first { $0.id == id }?.name ?? ""
    }

    // MARK: Compare

    var canCompare: Bool { selection.count == 2 && !isRecording }

    func startCompare() {
        guard canCompare else { return }
        let ordered = recordings.filter { selection.contains($0.id) && $0.health == .ok }
            .sorted { $0.createdAt < $1.createdAt }
        guard ordered.count == 2 else {
            show(.info, tr("Both takes must exist to compare them."))
            return
        }
        compareIDs = ordered.map(\.id)
        compareActive = 0
        compareWaveforms = [:]
        for recording in ordered {
            let peaks = store.peaksURL(of: recording.id)
            if let cached = WaveformData.read(from: peaks) {
                compareWaveforms[recording.id] = cached
            } else if let analysis = try? AudioAnalyzer.analyze(store.url(of: recording)) {
                compareWaveforms[recording.id] = analysis.waveform
                saveWaveform(analysis.waveform, for: recording.id)
            }
        }
        load(ordered[0].id)
    }

    /// Switches between the takes at the same point after their start, so they can be judged directly.
    func switchCompare() {
        guard compareIDs.count == 2, let currentRecording = current else { return }
        let elapsed = max(playback.position - currentRecording.edit.trimStart, 0)
        let next = compareActive == 0 ? 1 : 0
        guard let other = store.recording(compareIDs[next]) else { return }
        let wasPlaying = playback.isPlaying
        compareActive = next
        load(other.id, startAt: other.edit.trimStart + elapsed)
        if wasPlaying {
            do {
                try playback.play()
                playhead.isPlaying = true
            } catch {
                show(.error, error.localizedDescription)
            }
        }
        announce(next == 0 ? tr("Take A") : tr("Take B"))
    }

    func clearCompare() {
        compareIDs = []
        compareWaveforms = [:]
        compareActive = 0
    }

    // MARK: Metronome

    func updateMetronome(_ change: (inout MetronomeSettings) -> Void) {
        updateMetronome(notifying: true, change)
    }

    /// The tempo of a preset opened in AmpBench. It does not ask back whether it should go into the preset.
    func setTempoFromPreset(_ bpm: Double) {
        updateMetronome(notifying: false) { $0.bpm = bpm }
    }

    private func updateMetronome(notifying: Bool, _ change: (inout MetronomeSettings) -> Void) {
        let previous = metronome
        change(&metronome)
        metronome.bpm = min(max(metronome.bpm.rounded(), TapTempo.range.lowerBound), TapTempo.range.upperBound)
        // The bars of a running recording rest on its tempo and meter, so these wait until it is over.
        if phase != .idle {
            metronome.bpm = previous.bpm
            metronome.beatsPerBar = previous.beatsPerBar
        }
        if var running = activeClickSettings {
            running.volume = metronome.volume
            activeClickSettings = running
            click.update(settings: running)
        }
        applyPlaybackClick()
        if let data = try? JSONEncoder().encode(metronome) { defaults.set(data, forKey: "metronome") }
        if notifying, metronome.bpm != previous.bpm { onTempoChanged?(metronome.bpm) }
    }

    func tap() {
        if let bpm = tapTempo.tap(at: ProcessInfo.processInfo.systemUptime) {
            updateMetronome { $0.bpm = bpm }
        }
    }

    /// Switches the click on or off. It only ever sounds while playing or recording, so this alone stays silent.
    func toggleClick() {
        updateMetronome { $0.clickEnabled.toggle() }
        let isOn = metronome.clickEnabled
        if isRecording {
            if click.isRunning, let settings = activeClickSettings {
                // The running click stays, silent or not: the bars of the recording are counted from it.
                if case .countIn = phase {
                    click.setMuted(false)
                    if !isOn { click.muteAfter(beats: settings.countInBeats) }
                } else {
                    click.setMuted(!isOn)
                }
            } else if isOn {
                startClickForRecording(settings: metronome)
            }
        }
        announce(isOn ? tr("Click on") : tr("Click off"))
    }

    /// The meter that the beat lamps show right now.
    var activeBeatsPerBar: Int {
        activeClickSettings?.beatsPerBar ?? playbackClickGrid?.beatsPerBar ?? metronome.beatsPerBar
    }

    /// During playback the click is part of what plays, so it stays exactly with the audio. A take without bars of its
    /// own gets the metronome's tempo, counted from its start.
    private func applyPlaybackClick() {
        var grid: BeatGrid?
        if metronome.clickEnabled, !isRecording, let recording = current {
            grid = recording.grid ?? BeatGrid(bpm: metronome.bpm, beatsPerBar: metronome.beatsPerBar, offset: 0)
        }
        if playbackClickGrid != grid { playbackClickGrid = grid }
        playback.setClick(grid, volume: metronome.volume)
    }

    // MARK: Loopback measurement

    var canMeasureLoopback: Bool {
        !isRecording && !isMeasuring && selectedInput != nil && effectiveOutput != nil && !isListening
    }

    /// Plays quiet clicks to the chosen output and checks whether they arrive at the chosen input.
    func measureLoopback() {
        guard canMeasureLoopback, let input = selectedInput, let output = effectiveOutput else { return }
        isMeasuring = true
        pausePlayhead()
        Task {
            defer { isMeasuring = false }
            guard await requestMicrophone() else { return }
            do {
                let result = try await LoopbackProbe.measure(input: input, output: output.id, inputPolicy: inputPolicy)
                let key = FeedbackGuard.pairKey(input: input.identity, output: output.identity)
                if result.outputReachesInput {
                    measuredClean.remove(key)
                    show(.warning, tr("Measured: The sound from “%@” arrives at the input “%@”. Output to it stays blocked during a recording.", output.name, input.name), sticky: true)
                } else {
                    measuredClean.insert(key)
                    show(.info, tr("Measured: The sound from “%@” does not arrive at the input “%@”. Playback and click to it are now allowed during a recording too.", output.name, input.name), sticky: true)
                }
                defaults.set(Array(measuredClean), forKey: "measuredCleanPairs")
                objectWillChange.send()
            } catch {
                show(.error, tr("The measurement failed: %@", error.localizedDescription), sticky: true)
            }
        }
    }

    func forgetLoopbackMeasurements() {
        measuredClean = []
        defaults.removeObject(forKey: "measuredCleanPairs")
        objectWillChange.send()
        show(.info, tr("All measurements were forgotten. Outputs on the same device are blocked again."))
    }

    // MARK: Click latency

    var canMeasureLatency: Bool {
        !isRecording && !isMeasuring && selectedInput != nil && clickOutput != nil && !isListening
    }

    private func latencyKey(output: OutputDevice) -> String? {
        guard let input = selectedInput else { return nil }
        return FeedbackGuard.pairKey(input: input.identity, output: output.identity)
    }

    func latencyCorrection(output: OutputDevice) -> Double {
        latencyKey(output: output).flatMap { latencyCorrections[$0] } ?? 0
    }

    /// The correction for the input and click output in use now, in seconds.
    var currentLatencyCorrection: Double {
        clickOutput.map(latencyCorrection(output:)) ?? 0
    }

    /// The delay the devices report for the input and click output in use now, in seconds.
    var currentReportedLatency: Double? {
        guard let input = selectedInput, let output = clickOutput else { return nil }
        let inputRate = AudioDevices.currentRate(of: input.id)
        let outputRate = AudioDevices.currentRate(of: output.id)
        guard inputRate > 0, outputRate > 0 else { return nil }
        return Double(AudioDevices.inputLatencyFrames(of: input.id)) / inputRate
            + Double(AudioDevices.outputLatencyFrames(of: output.id)) / outputRate
    }

    /// Sets the correction by hand. The bars of later recordings move by it; earlier ones stay as they are.
    func setLatencyCorrection(_ seconds: Double) {
        guard let output = clickOutput, let key = latencyKey(output: output) else { return }
        let clamped = min(max(seconds, -0.1), 0.3)
        if abs(clamped) < 0.00005 {
            latencyCorrections.removeValue(forKey: key)
        } else {
            latencyCorrections[key] = clamped
        }
        defaults.set(latencyCorrections, forKey: Self.latencyCorrectionsKey)
    }

    /// Plays clicks into the input through a cable and measures how late they arrive in a file.
    func measureLatency() {
        guard canMeasureLatency, let input = selectedInput, let output = clickOutput else { return }
        isMeasuring = true
        pausePlayhead()
        Task {
            defer { isMeasuring = false }
            guard await requestMicrophone() else { return }
            do {
                let result = try await LatencyProbe.measure(input: input, output: output.id, inputPolicy: inputPolicy)
                setLatencyCorrection(result.correction)
                let text = tr(
                    "Measured: %.1f ms from the click into the file, of which %.1f ms are not reported by the devices. Spread %.1f ms over %d clicks. The bars of new takes now rest on it. Unplug the cable again.",
                    result.measured * 1000, result.correction * 1000, result.spread * 1000, result.detected)
                show(.info, text, sticky: true)
            } catch {
                show(.error, tr("The latency measurement failed: %@", error.localizedDescription), sticky: true)
            }
        }
    }
}
