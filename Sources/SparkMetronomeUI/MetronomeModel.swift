import AmpText
import Combine
#if os(macOS)
import CoreAudio
#endif
import Foundation
import SparkCore

/// The area Metronome's state: the shared tempo, whether it plays, and which pulse is heard right now.
///
/// What is heard is decided on the audio thread (`MetronomeEngine`). The window only shows it: every pulse comes with
/// the host time at which it leaves the speaker, and the view lights a lamp when that time has come, so the light
/// follows the sound and not a timer of its own.
@MainActor
final class MetronomeModel: ObservableObject {
    let tempo: MetronomeTempo
    private let engine = MetronomeEngine()
    private var changes: AnyCancellable?

    @Published private(set) var settings: MetronomeSettings
    @Published private(set) var isRunning = false
    @Published private(set) var problem: String?
    @Published var chosenPieceID: UUID?
    private var tapTempo = TapTempo()

    /// Pulses placed but not yet heard, and the last one heard.
    private var upcoming: [MetronomePulse] = []
    private(set) var heard: MetronomePulse?

    init(tempo: MetronomeTempo) {
        self.tempo = tempo
        settings = tempo.settings
        chosenPieceID = tempo.currentPieceID
        changes = tempo.changes.receive(on: RunLoop.main).sink { [weak self] in
            MainActor.assumeIsolated { self?.tempoChanged() }
        }
        #if os(macOS)
        let follow: () -> Void = { [weak self] in MainActor.assumeIsolated { self?.followOutput() } }
        outputListeners = [AudioDevices.observeDefaultOutput(follow), AudioDevices.observeDeviceList(follow)]
        #endif
    }

    #if os(macOS)
    private var outputListeners: [AudioObjectPropertyListenerBlock?] = []

    deinit {
        if let listener = outputListeners.first ?? nil { AudioDevices.stopObservingDefaultOutput(listener) }
        if let listener = outputListeners.last ?? nil { AudioDevices.stopObservingDeviceList(listener) }
    }

    /// The device the metronome belongs on now: the chosen output, else the system's.
    private var targetDevice: AudioDeviceID? {
        tempo.outputDeviceID.flatMap { AudioDevices.exists($0) ? $0 : nil } ?? AudioDevices.defaultOutputDevice()
    }

    /// Moves a running metronome to where the sound belongs now. Without this it kept playing on the device it started
    /// on: with headphones plugged in, the muted speakers.
    private func followOutput() {
        guard isRunning, let target = targetDevice, target != engine.device else { return }
        stop()
        start()
    }
    #endif

    private func tempoChanged() {
        let fresh = tempo.settings
        if fresh != settings {
            settings = fresh
            if isRunning { engine.update(settings: fresh) }
        }
        if isRunning, tempo.isBusy {
            stop()
            problem = tr("The metronome stopped: a recording or a take with its click took over the tempo.")
        }
        if chosenPieceID == nil { chosenPieceID = tempo.currentPieceID }
        #if os(macOS)
        followOutput()
        #endif
        objectWillChange.send()
    }

    // MARK: Playing

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        guard !tempo.isBusy else {
            problem = tr("A recording or a take is playing with its click. The metronome starts once it is over.")
            return
        }
        do {
            #if os(macOS)
            try engine.start(device: tempo.outputDeviceID, settings: settings)
            #else
            try engine.start(settings: settings)
            #endif
            problem = nil
            upcoming = []
            heard = nil
            isRunning = true
        } catch {
            problem = error.localizedDescription
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
        upcoming = []
        heard = nil
    }

    /// The pulse heard at `now` (host seconds), taking in what the audio thread placed since the last frame.
    func pulse(at now: Double) -> MetronomePulse? {
        guard isRunning else { return nil }
        upcoming.append(contentsOf: engine.drainPulses())
        while let next = upcoming.first, (next.heardAt ?? now) <= now {
            heard = next
            upcoming.removeFirst()
        }
        return heard
    }

    /// The tempo playing now, which the trainer raises bar by bar.
    var playingBPM: Double {
        (isRunning ? engine.currentBPM : nil) ?? settings.bpm
    }

    var outputLatencyMilliseconds: Double { engine.outputLatency * 1000 }

    // MARK: Changing

    func update(_ change: (inout MetronomeSettings) -> Void) {
        tempo.updateSettings(change)
        tempoChanged()
    }

    func setBPM(_ bpm: Double) {
        update { $0.bpm = bpm }
    }

    func nudge(_ delta: Double) {
        setBPM(settings.bpm + delta)
    }

    func tap() {
        if let bpm = tapTempo.tap(at: ProcessInfo.processInfo.systemUptime) { setBPM(bpm) }
    }

    func cycleLevel(ofBeat beat: Int) {
        update { settings in
            let current = settings.levels[beat]
            settings.pattern = settings.pattern.setting(current.next, at: beat, beats: settings.beatsPerBar)
        }
    }

    func setBeats(_ beats: Int) {
        update { $0.beatsPerBar = min(max(beats, 1), MetronomeSettings.beatsRange.upperBound) }
    }

    // MARK: Pieces

    var pieces: [MetronomePiece] { tempo.pieces }

    var chosenPiece: MetronomePiece? { pieces.first { $0.id == chosenPieceID } }

    func loadChosenPiece() {
        guard let id = chosenPieceID else { return }
        tempo.load(piece: id)
        tempoChanged()
    }

    func storeInChosenPiece() {
        guard let id = chosenPieceID else { return }
        tempo.store(inPiece: id)
        tempoChanged()
    }

    #if os(macOS)
    var outputName: String { tempo.outputName }
    #endif
}
