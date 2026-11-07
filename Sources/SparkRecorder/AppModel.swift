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

    // MARK: Engines

    private let capture = CaptureEngine()
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
    private var clickStartedForRecording = false
    private var countInEndsAt: UInt64 = 0
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

    init(folder: URL, defaults: UserDefaults) {
        store = LibraryStore(folder: folder)
        self.defaults = defaults
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
        inputs = AudioDevices.inputDevices()
        outputs = AudioDevices.outputDevices()
        let sparkHasInput = inputs.contains { $0.name.lowercased().contains("spark") }
        sparkWithoutInput = !sparkHasInput && !AudioDevices.sparkDevicesWithoutInput().isEmpty

        guard !isRecording else { return }
        resolveInput()
        resolveOutput()
        if let clickOutputID, !outputs.contains(where: { $0.id == clickOutputID }) { self.clickOutputID = nil }
    }

    /// The chosen input is remembered by its stable identifier. Device numbers can change when a device returns, and
    /// a device can vanish for a moment, so the choice is looked up again each time and never overwritten by a fallback.
    private func resolveInput() {
        let preferredUID = defaults.string(forKey: "inputUID")
        if let preferred = inputs.first(where: { $0.uid == preferredUID }) {
            if inputID != preferred.id {
                if isMonitoring || isRetroOn { turnOffListening() }
                inputID = preferred.id
            }
            return
        }
        guard selectedInput == nil else { return }
        if isMonitoring || isRetroOn {
            turnOffListening()
            show(.warning, "Der Eingang ist nicht mehr verfügbar. Das Mithören wurde beendet und der Puffer gelöscht.")
        }
        let defaultInput = AudioDevices.defaultInputDevice()
        inputID = inputs.first { $0.name.lowercased().contains("spark") }?.id
            ?? inputs.first { $0.id == defaultInput }?.id
            ?? inputs.first?.id
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
        guard !isRecording, id != inputID else { return }
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
        if click.isRunning, !isRecording {
            click.stop()
            isClickRunning = false
            toggleClick()
        }
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
        guard !isRecording, let device = selectedInput else { return }
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
        guard !isRecording, let device = selectedInput else {
            if isRecording { show(.info, "Die Retro-Aufnahme lässt sich erst nach der laufenden Aufnahme einschalten.") }
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
            startRequestID += 1
            let request = startRequestID
            phase = .preparing
            Task { await startRecording(request: request) }
        case .preparing:
            break
        case .countIn:
            cancelCountIn()
        case .recording:
            stopRecording(note: nil)
        }
    }

    private func freeBytes() -> Int64 {
        let values = try? store.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    private func startRecording(request: Int) async {
        defer { if phase == .preparing { phase = .idle } }
        guard libraryIsUsable else { return }
        guard await requestMicrophone(), request == startRequestID else { return }
        refreshDevices()
        guard let device = selectedInput else {
            show(.error, "Es ist kein Audioeingang ausgewählt.")
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
            let url = store.uniqueName("Aufnahme_\(LibraryStore.fileStamp(now))")
            let source = sourceFormat(device)
            let journal = RecordingJournal(fileName: url.lastPathComponent, startedAt: now, source: source, pieceID: currentPieceID)
            try store.writeJournal(journal)

            var gate: UInt64 = 0
            var beats = 0
            if metronome.countInBars > 0 {
                beats = metronome.countInBeats
                gate = await prepareCountIn(beats: beats)
                if gate == 0 { beats = 0 }
            } else if metronome.clickWhileRecording && !click.isRunning {
                startClickForRecording()
            }
            guard request == startRequestID else {
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
            recordingFlag.set(true)
            phase = beats > 0 ? .countIn(beatsLeft: beats) : .recording
            isMonitoring = false
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
    private func prepareCountIn(beats: Int) async -> UInt64 {
        guard let output = clickOutput else {
            show(.warning, "Kein sicherer Ausgang für den Klick gefunden. Die Aufnahme startet ohne Einzähler.")
            return 0
        }
        do {
            click.stop()
            try click.start(device: output.id, settings: metronome)
            if !metronome.clickWhileRecording { click.muteAfter(beats: beats, bpm: metronome.bpm) }
            clickStartedForRecording = true
            isClickRunning = true
            for _ in 0..<100 {
                let first = click.firstBeatHostTime
                if first != 0 {
                    return first + UInt64(metronome.countInSeconds * AudioGetHostClockFrequency())
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        } catch {
            show(.warning, "Der Klick konnte nicht starten: \(error.localizedDescription) Die Aufnahme startet ohne Einzähler.")
        }
        click.stop()
        isClickRunning = false
        clickStartedForRecording = false
        return 0
    }

    private func startClickForRecording() {
        guard let output = clickOutput else {
            show(.warning, "Kein sicherer Ausgang für den Klick gefunden. Die Aufnahme läuft ohne Klick.")
            return
        }
        do {
            try click.start(device: output.id, settings: metronome)
            clickStartedForRecording = true
            isClickRunning = true
        } catch {
            show(.warning, "Der Klick konnte nicht starten: \(error.localizedDescription)")
        }
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
        if clickStartedForRecording {
            click.stop()
            isClickRunning = false
            clickStartedForRecording = false
        }
        // Keep the input open only for features that still need it. A buffer turned off during the take ends here.
        if !isRetroOn {
            capture.close()
            isMonitoring = false
            resetMeter()
        }
    }

    func stopRecording(note: String?) {
        guard let journal = activeJournal, let source = activeSource else { return }
        let start = activeStart
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
            markers: markers,
            pieceID: journal.pieceID,
            edit: edit,
            peakDB: peak > 0 ? 20 * log10(Double(peak)) : nil
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
        summarize(result, note: note)
    }

    private func summarize(_ result: RecordingResult, note: String?) {
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
        if click.isRunning {
            let beat = click.beatCount
            if meter.beat != beat { meter.beat = beat }
        }
        let playing = playback.isPlaying
        if playhead.isPlaying != playing { playhead.isPlaying = playing }
        if playing || playhead.position == 0 {
            let position = playback.position
            if abs(position - playhead.position) > 0.005 { playhead.position = position }
        }
    }

    private func recordingTick(_ elapsed: Double) {
        meter.seconds = capture.recordedSeconds
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
                let total = metronome.countInBeats
                let left = max(total - Int(click.beatCount) + 1, 1)
                if phase != .countIn(beatsLeft: left) { phase = .countIn(beatsLeft: left) }
            }
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
        let targets = ids ?? (selection.isEmpty ? Set([currentID].compactMap { $0 }) : selection)
        guard !targets.isEmpty else { return }
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
        if !lastTrashed.isEmpty {
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

    func renamePiece(_ id: UUID, to name: String) {
        store.renamePiece(id, to: name)
        scheduleSave()
    }

    func removePiece(_ id: UUID) {
        store.removePiece(id)
        if currentPieceID == id { setCurrentPiece(nil) }
        if query.piece == .piece(id) { query.piece = nil }
        scheduleSave()
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
        change(&metronome)
        metronome.bpm = min(max(metronome.bpm.rounded(), TapTempo.range.lowerBound), TapTempo.range.upperBound)
        click.update(settings: metronome)
        if let data = try? JSONEncoder().encode(metronome) { defaults.set(data, forKey: "metronome") }
    }

    func tap() {
        if let bpm = tapTempo.tap(at: ProcessInfo.processInfo.systemUptime) {
            updateMetronome { $0.bpm = bpm }
        }
    }

    func toggleClick() {
        if click.isRunning {
            click.stop()
            isClickRunning = false
            clickStartedForRecording = false
            return
        }
        guard let output = clickOutput else {
            show(.warning, "Kein sicherer Ausgang für den Klick gefunden.")
            return
        }
        do {
            try click.start(device: output.id, settings: metronome)
            isClickRunning = true
        } catch {
            show(.error, "Der Klick konnte nicht starten: \(error.localizedDescription)")
        }
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
                let result = try await LoopbackProbe.measure(input: input, output: output.id)
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
