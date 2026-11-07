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

    static func == (lhs: Banner, rhs: Banner) -> Bool { lhs.id == rhs.id }
}

enum LibraryTab: String, CaseIterable, Identifiable {
    case recordings = "Aufnahmen"
    case pieces = "Stücke"
    case stats = "Statistik"
    var id: String { rawValue }
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
    @Published var showShortcuts = false
    @Published var renameTarget: UUID?
    @Published var renameText = ""
    @Published var showLoopbackInfo = false
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
    private var countInEndsAt: UInt64 = 0
    private var bannerUndoAction: (@MainActor (AppModel) -> Void)?
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
    var isListening: Bool { isRecording || isMonitoring || isRetroOn }

    // MARK: Lifecycle

    init(folder: URL, defaults: UserDefaults, inputPolicy: InputPolicy) {
        store = LibraryStore(folder: folder)
        self.defaults = defaults
        self.inputPolicy = inputPolicy
        capture = CaptureEngine(inputPolicy: inputPolicy)
        retroMinutes = defaults.object(forKey: "retroMinutes") as? Double ?? 5
        autoLevelDefault = defaults.object(forKey: "autoLevel") as? Bool ?? true
        measuredClean = Set(defaults.stringArray(forKey: "measuredCleanPairs") ?? [])
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
            show(.error, "Spark Recorder läuft bereits mit dieser Bibliothek. Beende die andere Instanz.", sticky: true)
            return
        }
        do {
            switch try store.load() {
            case .fresh, .loaded:
                break
            case .restoredFromBackup(let keptAs):
                show(.warning, "Die Bibliotheksdatei war beschädigt. Die Sicherung wurde geladen, die alte Datei liegt als „\(keptAs)“ im Ordner.", sticky: true)
            case .startedOver(let keptAs):
                show(.warning, "Die Bibliotheksdatei war beschädigt und es gab keine Sicherung. Die Aufnahmen wurden neu eingelesen, die alte Datei liegt als „\(keptAs)“ im Ordner.", sticky: true)
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
            show(.warning, "Die letzte Aufnahme wurde unterbrochen und repariert: „\(name)“ (\(TimeText.clock(seconds))).", sticky: true)
        case .empty(let name):
            show(.info, "Die unterbrochene Aufnahme „\(name)“ enthielt keine Audiodaten und liegt im Papierkorb.")
        case .failed(let name):
            show(.error, "Die unterbrochene Aufnahme „\(name)“ ließ sich nicht reparieren. Die Datei bleibt unverändert im Ordner.", sticky: true)
        }
        scanFolder(announceNothing: true)
        syncFromStore()
    }

    func scanFolder(announceNothing: Bool = false) {
        guard !isRecording, libraryIsUsable else { return }
        let report = store.scan()
        syncFromStore()
        var parts: [String] = []
        if !report.added.isEmpty { parts.append("\(report.added.count) neu aufgenommen") }
        if !report.reattached.isEmpty { parts.append("\(report.reattached.count) umbenannt erkannt") }
        if !report.repaired.isEmpty { parts.append("\(report.repaired.count) repariert") }
        if !report.missing.isEmpty { parts.append("\(report.missing.count) fehlen") }
        if !report.damaged.isEmpty { parts.append("\(report.damaged.count) beschädigt") }
        if parts.isEmpty {
            if !announceNothing { show(.info, "Der Ordner stimmt mit der Bibliothek überein.") }
        } else if banner == nil || !announceNothing {
            let isBad = !report.missing.isEmpty || !report.damaged.isEmpty
            show(isBad ? .warning : .info, "Ordner geprüft: \(parts.joined(separator: ", ")).", sticky: isBad)
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
                        self.show(.error, "Die Bibliothek konnte nicht gespeichert werden: \(text)", sticky: true)
                    }
                }
            }
        }
    }

    // MARK: Banner

    func show(_ kind: Banner.Kind, _ text: String, sticky: Bool = false, canUndo: Bool = false) {
        bannerTask?.cancel()
        bannerUndoAction = nil
        banner = Banner(kind: kind, text: text, canUndo: canUndo)
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
            show(.warning, "Der Eingang ist nicht mehr verfügbar. Das Mithören wurde beendet und der Puffer gelöscht.")
        }
        inputID = target?.id
    }

    private func showNoSpark() {
        show(.warning, "Kein Spark verbunden. Ohne Spark nimmt die App nichts auf.")
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
            show(.warning, "Das Ausgabegerät ist nicht mehr verfügbar. Die Wiedergabe nutzt den Systemausgang, bis es zurück ist.")
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
            show(.info, "Der Eingang wurde gewechselt. Das Mithören wurde beendet und der Puffer gelöscht.")
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
        show(.error, "Der Mikrofonzugriff fehlt. Erlaube ihn unter Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon.", sticky: true)
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
                show(.error, "Der Eingang konnte nicht geöffnet werden: \(error.localizedDescription)")
            }
        }
    }

    private func closeInputIfUnused() {
        guard !isRecording, !isMonitoring, !isRetroOn else { return }
        capture.close()
        resetMeter()
    }

    private func turnOffListening() {
        isMonitoring = false
        isRetroOn = false
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

    // MARK: Retro buffer

    func toggleRetro() {
        if isRetroOn {
            isRetroOn = false
            if isRecording {
                show(.info, "Der Puffer wird beim Ende der Aufnahme gelöscht.")
            } else {
                // Reopening or closing the input frees the buffer and overwrites it with zeros.
                capture.close()
                resetMeter()
                if isMonitoring, let device = selectedInput { try? capture.open(device: device) }
                show(.info, "Retro-Aufnahme aus. Der Puffer im Arbeitsspeicher wurde gelöscht.")
            }
            return
        }
        guard !isRecording else {
            show(.info, "Die Retro-Aufnahme lässt sich erst nach der laufenden Aufnahme einschalten.")
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
                show(.info, "Retro-Aufnahme an. Der Eingang hört mit, der Puffer bleibt im Arbeitsspeicher.")
            } catch {
                show(.error, "Der Eingang konnte nicht geöffnet werden: \(error.localizedDescription)")
            }
        }
    }

    func setRetroMinutes(_ minutes: Double) {
        retroMinutes = minutes
        defaults.set(minutes, forKey: "retroMinutes")
        // A running buffer keeps its size. Changing it would throw away what was just played.
    }

    /// Saves the buffer on explicit request: "Das eben war gut". This is the only way it reaches the disk.
    func saveRetro(seconds: Double? = nil) {
        guard isRetroOn, let copy = capture.copyRetro(seconds: seconds ?? retroMinutes * 60) else {
            if isRetroOn { show(.info, "Der Puffer ist noch leer.") }
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
                self.show(.info, "Die letzten \(TimeText.clock(seconds)) wurden als „\(recording.name)“ gespeichert.")
                if !self.isRecording { self.select(recording.id) }
            case .failure(let error):
                self.show(.error, "Der Puffer konnte nicht gespeichert werden: \(error.localizedDescription)", sticky: true)
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
            show(.error, "Auf dem Volume ist zu wenig Platz für eine Aufnahme.", sticky: true)
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
            let journal = RecordingJournal(
                fileName: url.lastPathComponent, startedAt: now, source: source,
                pieceID: punch.map(\.pieceID) ?? currentPieceID,
                punch: punch.map { PunchInfo(sourceID: $0.sourceID, bars: $0.bars) })
            try store.writeJournal(journal)

            var clickSettings = metronome
            if let punch {
                clickSettings.bpm = punch.grid.bpm
                clickSettings.beatsPerBar = punch.grid.beatsPerBar
                clickSettings.countInBars = max(metronome.countInBars, 1)
            }
            var gate: UInt64 = 0
            var beats = 0
            if clickSettings.countInBars > 0 {
                beats = clickSettings.countInBeats
                gate = await prepareCountIn(settings: clickSettings)
                if gate == 0 { beats = 0 }
                if gate == 0, punch != nil {
                    // Without a count-in nobody can come in on the right bar, so nothing gets recorded.
                    store.removeJournal()
                    if !isMonitoring && !isRetroOn { capture.close() }
                    show(.warning, "Die Takte brauchen einen Einzähler, und der Klick konnte nicht starten. Es wurde nichts aufgenommen.", sticky: true)
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

            let preRoll = UInt64(Self.countInPreRoll * AudioGetHostClockFrequency())
            try capture.startRecording(to: url, gateHostTime: gate == 0 ? 0 : gate - preRoll)
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
            countInEndsAt = gate
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
                reason: "Aufnahme läuft")
            announce(beats > 0 ? "Einzähler" : "Aufnahme läuft")
        } catch {
            store.removeJournal()
            if !isMonitoring && !isRetroOn { capture.close() }
            show(.error, "Die Aufnahme konnte nicht starten: \(error.localizedDescription)", sticky: true)
        }
    }

    /// Starts the click for a count-in and returns the moment the recording begins, or 0 when no click is possible.
    private func prepareCountIn(settings: MetronomeSettings) async -> UInt64 {
        guard let output = clickOutput else {
            show(.warning, "Kein sicherer Ausgang für den Klick gefunden. Die Aufnahme startet ohne Einzähler.")
            return 0
        }
        do {
            click.stop()
            try click.start(device: output.id, settings: settings)
            // Without the click switched on it falls silent after the count-in but keeps counting the bars.
            if !settings.clickEnabled { click.muteAfter(beats: settings.countInBeats, bpm: settings.bpm) }
            activeClickSettings = settings
            isClickRunning = true
            for _ in 0..<100 {
                let first = click.firstBeatHostTime
                if first != 0 {
                    return first + UInt64(settings.countInSeconds * AudioGetHostClockFrequency())
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        } catch {
            show(.warning, "Der Klick konnte nicht starten: \(error.localizedDescription) Die Aufnahme startet ohne Einzähler.")
        }
        click.stop()
        isClickRunning = false
        activeClickSettings = nil
        return 0
    }

    private func startClickForRecording(settings: MetronomeSettings) {
        guard let output = clickOutput else {
            show(.warning, "Kein sicherer Ausgang für den Klick gefunden. Die Aufnahme läuft ohne Klick.")
            return
        }
        do {
            try click.start(device: output.id, settings: settings)
            activeClickSettings = settings
            isClickRunning = true
        } catch {
            show(.warning, "Der Klick konnte nicht starten: \(error.localizedDescription)")
        }
    }

    /// Works out where the bars lie in the file, from the moments the click and the file really started.
    private func resolveGrid() {
        guard activeGrid == nil, click.isRunning, let settings = activeClickSettings, capture.recordedFrames > 0 else { return }
        let fileStart = capture.firstFrameHostTime
        let downbeat = countInEndsAt != 0 ? countInEndsAt : click.firstBeatHostTime
        let offset: Double
        if fileStart != 0, downbeat != 0 {
            offset = (Double(downbeat) - Double(fileStart)) / AudioGetHostClockFrequency()
        } else if countInEndsAt != 0 {
            // The device gives no valid times. The file then starts as planned, one pre-roll before the first bar.
            offset = Self.countInPreRoll
        } else {
            return
        }
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
        show(.info, "Der Einzähler wurde abgebrochen.")
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
        countInEndsAt = 0
        meter.beat = 0
        applyPlaybackClick()
        // Keep the input open only for features that still need it. A buffer turned off during the take ends here.
        if !isRetroOn {
            capture.close()
            isMonitoring = false
            resetMeter()
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
            show(.warning, note ?? "Es wurde nichts aufgenommen, weil das Gerät keine Daten geliefert hat.", sticky: note != nil)
            return
        }

        let peak = result.peak
        var edit = EditList()
        edit.autoLevelEnabled = autoLevelDefault
        edit.autoLevelDB = AutoLevel.gainDB(forPeak: peak)
        let recording = Recording(
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
            punch: journal.punch
        )
        store.add(recording)
        store.logPractice(date: start, seconds: result.seconds, pieceID: journal.pieceID)
        do {
            try store.save()
            // The journal goes only after the recording is safely in the library.
            if result.finalized { store.removeJournal() }
        } catch {
            show(.error, "Die Bibliothek konnte nicht gespeichert werden: \(error.localizedDescription)", sticky: true)
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
            show(.error, "Beim Schreiben ist ein Fehler aufgetreten (Fehler \(error)). Die Aufnahme enthält Lücken.", sticky: true)
        } else if result.droppedFrames > 0 {
            show(.warning, "Es gingen \(TimeText.clock(Double(result.droppedFrames) / max(capture.sampleRate, 44_100), tenths: true)) Audio verloren, weil die Festplatte nicht schnell genug war.", sticky: true)
        } else if result.peak == 0 {
            show(.warning, "Die Datei ist komplett still. Das Gerät hat kein Signal geliefert.", sticky: true)
        } else if result.clippedBlocks > 0 {
            show(.warning, "Gespeichert, aber das Signal hat übersteuert. Spiel leiser oder senke den Pegel am Gerät.", sticky: true)
        } else if let punch {
            show(.info, "\(Self.barsText(punch.bars)) neu aufgenommen, als eigene Aufnahme. „\(punch.sourceName)“ bleibt unverändert.")
        } else {
            announce("Aufnahme gespeichert. \(TimeText.spoken(result.seconds)).")
        }
    }

    private func inputInterrupted(_ reason: CaptureInterruption) {
        let note: String
        switch reason {
        case .deviceLost:
            note = "Die Audioverbindung wurde unterbrochen. Die Aufnahme bis dahin ist gespeichert."
        case .sampleRateChanged:
            note = "Eine andere App hat die Abtastrate des Geräts geändert. Die Aufnahme bis dahin ist gespeichert."
        }
        let wasRecording = isRecording
        if wasRecording {
            if case .countIn = phase {
                cancelCountIn()
                show(.warning, "Die Audioverbindung wurde unterbrochen.", sticky: true)
            } else {
                // The retro buffer depends on the lost input too.
                isRetroOn = false
                stopRecording(note: note)
            }
        } else if isMonitoring || isRetroOn {
            turnOffListening()
            show(.warning, "Die Audioverbindung wurde unterbrochen. Das Mithören wurde beendet und der Puffer gelöscht.", sticky: true)
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
            announce("Marker \(number)")
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
        announce("Marker bei \(TimeText.clock(time))")
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
                if !meter.clipped { announce("Übersteuerung") }
                meter.clipped = true
            }
            signalMonitor.update(level: level, callbackCount: capture.callbackCount, elapsed: elapsed)
            if meter.signal != signalMonitor.status { meter.signal = signalMonitor.status }
            if signalMonitor.status != lastBannerForSignal {
                lastBannerForSignal = signalMonitor.status
                if signalMonitor.status == .noData { announce("Der Eingang liefert keine Daten") }
                if signalMonitor.status == .silent { announce("Kein Signal") }
            }
            if isRetroOn { meter.retroSeconds = capture.retroAvailableSeconds }
            if isMonitoring, Date().timeIntervalSince(monitorStartedAt) > Self.monitorMaxSeconds {
                isMonitoring = false
                closeInputIfUnused()
                show(.info, "„Eingang prüfen“ wurde nach zwei Minuten automatisch beendet.")
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
                announce("Aufnahme läuft")
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
                stopRecording(note: "Die Aufnahme hat die Größengrenze einer WAV-Datei erreicht und wurde sicher beendet.")
            } else if freeBytes() < Self.criticalFreeBytes {
                stopRecording(note: "Die Festplatte ist fast voll. Die Aufnahme wurde sicher beendet.")
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

    /// The space bar. Nothing but "listen to the take just recorded": while a recording starts or runs, it does nothing,
    /// so it cannot start an older take or disturb the recording. The take is in focus as soon as it is stopped.
    func spaceBarPressed() {
        guard phase == .idle else { return }
        togglePlay()
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
            announce("Schleifenanfang bei \(TimeText.clock(position))")
        }
    }

    func setLoop(_ range: ClosedRange<Double>) {
        loopStart = nil
        loopRange = range
        playback.setLoop(range)
        playhead.position = playback.position
        announce("Schleife von \(TimeText.clock(range.lowerBound)) bis \(TimeText.clock(range.upperBound))")
    }

    func clearLoop() {
        loopStart = nil
        loopRange = nil
        playback.setLoop(nil)
        announce("Schleife aus")
    }

    // MARK: Bars

    static func barsText(_ bars: ClosedRange<Int>) -> String {
        bars.count == 1 ? "Takt \(bars.lowerBound)" : "Takte \(bars.lowerBound)–\(bars.upperBound)"
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
            show(.warning, "Kein sicherer Ausgang für den Klick gefunden. Ohne Einzähler lassen sich keine Takte neu aufnehmen.")
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
        announce("Behalten")
        registerUndo("Behalten") { model in
            model.store.update(target) { $0.status = previous }
            model.scheduleSave()
        }
    }

    /// Moves recordings to the Trash, reachable only with an explicit command and always undoable.
    func discard(_ ids: Set<UUID>? = nil) {
        guard !isRecording else { return }
        let targets = RemovalTargets.resolve(menuIDs: ids ?? [], selection: selection, current: currentID)
        guard !targets.isEmpty else {
            show(.info, "Markiere zuerst die Aufnahme, die in den Papierkorb soll.")
            return
        }
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
        let label = entries.count == 1 ? "„\(entries[0].recording.name)“ liegt im Papierkorb." : "\(entries.count) Aufnahmen liegen im Papierkorb."
        show(.info, label, canUndo: true)
        lastTrashed = entries
        registerUndo("In den Papierkorb legen") { model in
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
                show(.error, "„\(entry.recording.name)“: \(error.localizedDescription)", sticky: true)
            }
        }
        guard !restored.isEmpty else { return }
        scheduleSave()
        if restored.count == 1, let id = restored.first { select(id) }
        banner = nil
        announce("Wiederhergestellt")
        let ids = Set(restored)
        registerUndo("In den Papierkorb legen") { model in
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
            show(.info, "Es liegt keine verworfene Aufnahme mehr im Papierkorb.")
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
        announce("\(store.recording(target)?.rating ?? 0) Sterne")
    }

    func toggleFavorite(_ id: UUID? = nil) {
        guard let target = id ?? currentID else { return }
        store.update(target) { $0.favorite.toggle() }
        scheduleSave()
        announce(store.recording(target)?.favorite == true ? "Favorit" : "Kein Favorit")
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
            registerUndo("Umbenennen") { model in
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
            if isRecording { show(.info, "Exportiere nach dem Ende der Aufnahme.") }
            return
        }
        let panel = NSSavePanel()
        try? FileManager.default.createDirectory(at: store.exportFolder, withIntermediateDirectories: true)
        panel.directoryURL = store.exportFolder
        panel.nameFieldStringValue = "\(recording.name).\(format.fileExtension)"
        panel.title = "Exportieren (\(format.label))"
        panel.message = "Das Original bleibt unverändert. Bearbeitungen werden in die neue Datei gerechnet."
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
                    self.show(.warning, "Exportiert nach „\(result.url.lastPathComponent)“, aber der Pegel hat die Vollaussteuerung überschritten. Senke die Anhebung.", sticky: true)
                } else {
                    self.show(.info, "Exportiert nach „\(result.url.lastPathComponent)“.")
                }
            case .failure(let error):
                self.show(.error, "Der Export ist fehlgeschlagen: \(error.localizedDescription)", sticky: true)
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
            show(.info, cleaned.isEmpty ? "Ein Stück braucht einen Titel." : "Es gibt schon ein Stück mit dem Titel „\(cleaned)“.")
            return false
        }
        scheduleSave()
        registerUndo("Stück umbenennen") { model in
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
            model.announce("Stück wiederhergestellt")
        }
        show(.info, "Das Stück „\(removed.piece.name)“ ist entfernt. Seine Takes bleiben in der Liste.", canUndo: true)
        bannerUndoAction = restore
        registerUndo("Stück entfernen", restore)
    }

    func assign(_ ids: Set<UUID>, toPiece pieceID: UUID?) {
        for id in ids { store.assign(id, toPiece: pieceID) }
        scheduleSave()
    }

    func toggleBestTake(_ id: UUID? = nil) {
        guard let target = id ?? currentID else { return }
        guard store.recording(target)?.pieceID != nil else {
            show(.info, "Ordne die Aufnahme zuerst einem Stück zu, dann kannst du sie als besten Take markieren.")
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
            show(.info, "Zum Vergleichen müssen beide Aufnahmen vorhanden sein.")
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
        announce(next == 0 ? "Take A" : "Take B")
    }

    func clearCompare() {
        compareIDs = []
        compareWaveforms = [:]
        compareActive = 0
    }

    // MARK: Metronome

    func updateMetronome(_ change: (inout MetronomeSettings) -> Void) {
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
                    if !isOn { click.muteAfter(beats: settings.countInBeats, bpm: settings.bpm) }
                } else {
                    click.setMuted(!isOn)
                }
            } else if isOn {
                startClickForRecording(settings: metronome)
            }
        }
        announce(isOn ? "Klick an" : "Klick aus")
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
                    show(.warning, "Gemessen: Der Ton von „\(output.name)“ kommt am Eingang „\(input.name)“ an. Ausgabe dorthin bleibt während einer Aufnahme gesperrt.", sticky: true)
                } else {
                    measuredClean.insert(key)
                    show(.info, "Gemessen: Der Ton von „\(output.name)“ kommt am Eingang „\(input.name)“ nicht an. Wiedergabe und Klick dorthin sind jetzt auch während einer Aufnahme erlaubt.", sticky: true)
                }
                defaults.set(Array(measuredClean), forKey: "measuredCleanPairs")
                objectWillChange.send()
            } catch {
                show(.error, "Die Messung ist fehlgeschlagen: \(error.localizedDescription)", sticky: true)
            }
        }
    }

    func forgetLoopbackMeasurements() {
        measuredClean = []
        defaults.removeObject(forKey: "measuredCleanPairs")
        objectWillChange.send()
        show(.info, "Alle Messungen wurden vergessen. Ausgaben auf dasselbe Gerät sind wieder gesperrt.")
    }
}
