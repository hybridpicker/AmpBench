import AVFoundation
import AppKit
import QuartzCore
import SparkCore

/// The tuner's state on the main thread: where it listens, what it hears, and the settings.
///
/// It listens only while `setActive(true)`, that is while its area shows. The Spark is read along with the recorder's
/// own input through `SharedInput`, never through a second audio unit. Another input, such as a USB interface or the
/// Mac's microphone, gets its own engine, but only while nothing of the recorder is involved. The tuner sends nothing
/// to the amp, plays no sound, stores no audio and has no network access, with one exception the user picks: the
/// source "Stimmgerät des Verstärkers" switches the amp's own tuner on while the area shows, and off when it is left.
/// The amp is silent then; its readings come over Bluetooth, so a NEO without USB audio can be tuned too.
@MainActor
final class TunerModel: ObservableObject {
    enum Source: Hashable {
        /// The recorder's input, the one chosen in the deck.
        case deck
        /// Another input, by its stable identifier.
        case other(uid: String)
        /// The connected amp's own tuner, over Bluetooth.
        case amp
    }

    enum Status: Equatable {
        case idle
        case opening
        case listening
        case noInput
        case noPermission
        case failed(String)
        /// Synthetic tones for the window pictures of a test library.
        case demo
    }

    @Published var tuning: Tuning {
        didSet {
            interpreter.tuning = tuning
            ampInterpreter.tuning = tuning
            defaults.set(tuning.rawValue, forKey: Keys.tuning)
        }
    }
    @Published var a4: Double {
        didSet {
            let clean = Self.clampA4(a4)
            if clean != a4 { a4 = clean; return }
            interpreter.a4 = a4
            ampInterpreter.a4 = a4
            defaults.set(a4, forKey: Keys.a4)
        }
    }
    @Published var showsStrobe: Bool {
        didSet { defaults.set(showsStrobe, forKey: Keys.strobe) }
    }
    @Published private(set) var source: Source
    @Published private(set) var readout: TunerReadout?
    @Published private(set) var hasSignal = false
    /// The level from 0 to 1 over −60 to 0 dBFS.
    @Published private(set) var level = 0.0
    @Published private(set) var status = Status.idle
    @Published private(set) var otherInputs: [InputDevice] = []
    @Published private(set) var deckInputName: String?
    /// True while a recording, the retro buffer or the level check hold the same input open.
    @Published private(set) var isSharedWithRecording = false
    /// The connected amp whose own tuner can be used, by its name. Nil without one.
    @Published private(set) var ampName: String?

    /// The amp whose tuner can be a source. Set once by Studio.
    weak var amp: AmpTuner? {
        didSet {
            amp?.onAmpTunerReading = { [weak self] pitchClass, cents in
                guard let self, source == .amp, isActive else { return }
                ampInterpreter.add(pitchClass: pitchClass, cents: cents, time: CACurrentMediaTime())
            }
            ampName = amp?.ampTunerDevice
        }
    }
    private var ampInterpreter: AmpTunerInterpreter
    /// True after the amp's tuner was asked on, until it was asked off again.
    private var ampRequested = false

    let shared: SharedInput
    let defaults: UserDefaults
    let engine = TunerEngine()
    private(set) var isActive = false
    private var ownCapture: CaptureEngine?
    private var interpreter: TunerInterpreter
    private var timer: Timer?
    private var connectTask: Task<Void, Never>?
    private var nextAttempt = Date.distantPast
    private var lastDeviceRefresh = Date.distantPast
    private var lastAnnouncement: (text: String, date: Date)?
    private var demoTimer: Timer?

    enum Keys {
        static let tuning = "tunerTuning"
        static let a4 = "tunerA4"
        static let strobe = "tunerStrobe"
        static let input = "tunerInputUID"
        static let usesAmp = "tunerUsesAmp"
    }

    init(shared: SharedInput, defaults: UserDefaults) {
        self.shared = shared
        self.defaults = defaults
        let tuning = defaults.string(forKey: Keys.tuning).flatMap(Tuning.init(rawValue:)) ?? .standard
        let a4 = Self.clampA4(defaults.object(forKey: Keys.a4) as? Double ?? TunerInterpreter.defaultA4)
        self.tuning = tuning
        self.a4 = a4
        showsStrobe = defaults.bool(forKey: Keys.strobe)
        source = defaults.bool(forKey: Keys.usesAmp) ? .amp : defaults.string(forKey: Keys.input).map { .other(uid: $0) } ?? .deck
        interpreter = TunerInterpreter(tuning: tuning, a4: a4)
        ampInterpreter = AmpTunerInterpreter(tuning: tuning, a4: a4)
    }

    /// Tenths of a hertz within 430 to 450.
    static func clampA4(_ value: Double) -> Double {
        let range = TunerInterpreter.a4Range
        return (min(max(value, range.lowerBound), range.upperBound) * 10).rounded() / 10
    }

    // MARK: Listening only while the area shows

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            refreshDevices()
            engine.start()
            connect()
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            disconnect()
            engine.stop()
            readout = nil
            hasSignal = false
            level = 0
            if status != .demo { status = .idle }
        }
    }

    func choose(_ newSource: Source) {
        guard newSource != source else { return }
        guard isActive, status != .demo else {
            source = newSource
            remember(newSource)
            return
        }
        disconnect()
        source = newSource
        remember(newSource)
        connect()
    }

    private func remember(_ source: Source) {
        defaults.set(source == .amp, forKey: Keys.usesAmp)
        if case .other(let uid) = source {
            defaults.set(uid, forKey: Keys.input)
        } else {
            defaults.removeObject(forKey: Keys.input)
        }
    }

    var inputName: String {
        switch source {
        case .deck: return deckInputName ?? "Kein Spark"
        case .other(let uid): return otherInputs.first { $0.uid == uid }?.name ?? "Eingang fehlt"
        case .amp: return ampName.map { "Stimmgerät des \($0)" } ?? "Kein Verstärker verbunden"
        }
    }

    var usesAmp: Bool { source == .amp }

    private func refreshDevices() {
        lastDeviceRefresh = Date()
        deckInputName = shared.device?.name
        ampName = amp?.ampTunerDevice
        otherInputs = shared.allowsOtherInputs
            ? AudioDevices.inputDevices().filter { !shared.owns($0) }.sorted { $0.name < $1.name }
            : []
        if case .other = source, !shared.allowsOtherInputs { source = .deck }
    }

    private func connect() {
        guard isActive, status != .demo else { return }
        connectTask?.cancel()
        switch source {
        case .amp:
            guard let amp, ampName != nil else {
                status = .noInput
                return
            }
            ampInterpreter.reset()
            ampRequested = true
            amp.wantAmpTuner(true)
            status = amp.isAmpTunerOn ? .listening : .opening
        case .deck:
            guard shared.device != nil else {
                status = .noInput
                return
            }
            status = .opening
            let tap = engine.tap
            connectTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await shared.share(with: tap)
                    // The area may have closed while the permission was asked for.
                    if !isActive || Task.isCancelled { shared.stopSharing(with: tap) } else { status = .listening }
                } catch {
                    if isActive { status = Self.status(for: error) }
                }
            }
        case .other(let uid):
            guard let device = otherInputs.first(where: { $0.uid == uid }) else {
                status = .noInput
                return
            }
            status = .opening
            connectTask = Task { [weak self] in
                guard let self else { return }
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    if isActive { status = .noPermission }
                    return
                }
                guard isActive, !Task.isCancelled else { return }
                let capture = CaptureEngine(inputPolicy: .listenOnly)
                capture.onInterrupted = { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.closeOwnCapture()
                        if self.isActive { self.status = .noInput }
                    }
                }
                do {
                    // The tuner does not switch another app's device to a different rate.
                    try capture.open(device: device, raiseRate: false)
                    capture.attach(engine.tap)
                    ownCapture = capture
                    status = .listening
                } catch {
                    capture.close()
                    status = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        if ampRequested {
            ampRequested = false
            amp?.wantAmpTuner(false)
            ampInterpreter.reset()
        }
        shared.stopSharing(with: engine.tap)
        closeOwnCapture()
    }

    private func closeOwnCapture() {
        ownCapture?.detach(engine.tap)
        ownCapture?.close()
        ownCapture = nil
    }

    private static func status(for error: Error) -> Status {
        switch error as? SharedInputError {
        case .noPermission: .noPermission
        case .noDevice: .noInput
        case nil: .failed(error.localizedDescription)
        }
    }

    // MARK: Every frame

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastDeviceRefresh) > 2 { refreshDevices() }
        ampName = amp?.ampTunerDevice
        if status != .demo { keepConnected(now: now) }
        isSharedWithRecording = source == .deck && status == .listening && shared.isHeldOpen

        if source == .amp, status != .demo {
            readout = status == .listening ? ampInterpreter.readout(time: CACurrentMediaTime()) : nil
            hasSignal = status == .listening && ampInterpreter.hasSignal
            level = 0
            announce(now: now)
            return
        }
        let snapshot = engine.snapshot
        readout = interpreter.interpret(snapshot.reading, time: CACurrentMediaTime())
        hasSignal = snapshot.hasSignal
        let target = snapshot.isReceiving ? min(max((snapshot.levelDB + 60) / 60, 0), 1) : 0
        level = max(target, level * 0.85)
        announce(now: now)
    }

    /// Notices a lost input and tries again once a second, except when permission is missing.
    private func keepConnected(now: Date) {
        if source == .amp {
            switch status {
            case .listening, .opening:
                if ampName == nil {
                    disconnect()
                    status = .noInput
                } else if amp?.isAmpTunerOn == true {
                    status = .listening
                } else if status == .listening {
                    // The connection came back: the link switches the tuner on again.
                    status = .opening
                }
            case .noInput, .failed:
                if ampName != nil, now >= nextAttempt {
                    nextAttempt = now.addingTimeInterval(1)
                    connect()
                }
            case .idle, .noPermission, .demo:
                break
            }
            return
        }
        switch status {
        case .listening:
            let alive = source == .deck ? shared.isSharing(with: engine.tap) : ownCapture?.isOpen == true
            if !alive {
                disconnect()
                status = .noInput
                nextAttempt = now.addingTimeInterval(1)
            }
        case .noInput, .failed:
            if now >= nextAttempt {
                nextAttempt = now.addingTimeInterval(1)
                connect()
            }
        case .idle, .opening, .noPermission, .demo:
            break
        }
    }

    // MARK: VoiceOver

    /// Note, string and deviation, at most every two seconds and only when something changed that one would hear.
    private func announce(now: Date) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let readout, !readout.isHeld else { return }
        let text = Self.spoken(readout)
        if let last = lastAnnouncement, last.text == text || now.timeIntervalSince(last.date) < 2 { return }
        lastAnnouncement = (text, now)
        guard let window = NSApp.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    /// "E, 6. Saite, 2 Cent zu tief" or "E, 6. Saite, gestimmt". Whole cents above two, tenths below, so a calm
    /// reading does not change its words with every tenth.
    static func spoken(_ readout: TunerReadout) -> String {
        var parts = [readout.note.spokenName(flats: readout.flats)]
        if let string = readout.string { parts.append("\(string). Saite") }
        if readout.isInTune {
            parts.append("gestimmt")
        } else {
            let amount = abs(readout.cents)
            let text = amount >= 2 ? "\(Int(amount.rounded())) Cent" : TunerText.decimal(amount, digits: 1) + " Cent"
            parts.append(text + (readout.cents < 0 ? " zu tief" : " zu hoch"))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Pictures

    /// Plays a synthetic string into the tuner, for the window pictures of a test library. Nothing is opened.
    func startDemo(frequency: Double) {
        disconnect()
        status = .demo
        let rate = 48_000.0
        let samples = TunerTestSignal.addingNoise(
            TunerTestSignal.karplusStrong(frequency: frequency, sampleRate: rate, seconds: 6, ringTime: 12), decibels: -45)
        engine.tap.beginForTesting(sampleRate: rate)
        var offset = 0
        let chunk = Int(rate / 100)
        demoTimer?.invalidate()
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, offset < samples.count else { return timer.invalidate() }
                self.engine.tap.write(Array(samples[offset..<min(offset + chunk, samples.count)]))
                offset += chunk
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
    }

    func endDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        status = .idle
        if isActive { connect() }
    }
}
