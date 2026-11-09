import Foundation

/// The amp's own tuner, as Spark Studio's tuner sees it: a device that can switch it on, and its readings.
///
/// Spark MINI and NEO have a tuner inside. Switched on over Bluetooth they mute their output and report the note
/// and its deviation about 15 times a second. That is how a NEO, which has no USB audio, can be tuned in Studio.
/// Studio's tuner area provides it as a source next to the inputs; whoever owns the Bluetooth link implements it.
@MainActor
public protocol AmpTuner: AnyObject {
    /// The connected device's name when its tuner can be switched on from here. Nil without such a device.
    var ampTunerDevice: String? { get }
    /// True once the device confirmed that its tuner is on.
    var isAmpTunerOn: Bool { get }
    /// Every reading as it comes: the note from 0 (C) to 11 (H) and the cents from −50 to +50, nil without signal.
    var onAmpTunerReading: ((_ pitchClass: Int, _ cents: Double?) -> Void)? { get set }
    /// Asks for the tuner on or off. The link keeps to it: on after a reconnect, off before it disconnects.
    func wantAmpTuner(_ on: Bool)
}

/// Turns the amp's tuner readings into what the tuner shows.
///
/// The amp's values jump by about ±10 cents from one reading to the next, so the median of the last 0.4 s is shown,
/// in whole cents. A new note shows after three readings of it in a row, so a stray reading at the attack does not
/// flicker. The amp only says the note's name, not its octave: the tuning's string with that name gives the octave
/// when there is exactly one. The amp tunes to its own concert pitch, taken as 440 Hz; another A4 shifts the cents.
public struct AmpTunerInterpreter: Sendable {
    /// "Gestimmt" within ±3 cents, held for half a second.
    public static let tolerance = 3.0
    public static let inTuneAfter = 0.5
    /// Seconds of readings in the median.
    public static let window = 0.4
    /// Readings of a new note in a row before it shows.
    public static let switchAfter = 3
    /// Without a reading for this long, the signal is gone.
    public static let signalTimeout = 0.3
    /// The last note stays, dimmed, this long after the signal ended.
    public static let holdFor = 1.5
    /// The amp's own concert pitch.
    public static let ampA4 = 440.0

    public var tuning: Tuning
    public var a4: Double
    private var recent: [(time: Double, cents: Double)] = []
    private var shown: Int?
    private var candidate: (pitchClass: Int, count: Int)?
    private var lastSignal: Double?
    private var withinSince: Double?
    private var last: TunerReadout?
    private var previousString: Int?

    public init(tuning: Tuning = .standard, a4: Double = TunerInterpreter.defaultA4) {
        self.tuning = tuning
        self.a4 = a4
    }

    /// Forgets everything, as when the tuner goes off.
    public mutating func reset() {
        recent = []
        shown = nil
        candidate = nil
        lastSignal = nil
        withinSince = nil
        last = nil
        previousString = nil
    }

    /// One reading from the amp. `cents` nil: no signal.
    public mutating func add(pitchClass: Int, cents: Double?, time: Double) {
        guard let cents, (0..<12).contains(pitchClass), cents.isFinite else { return }
        // Relative to this tuner's A4 instead of the amp's, then back to the nearest note.
        let position = Double(pitchClass) * 100 + cents - 1200 * log2(a4 / Self.ampA4)
        let note = Int((position / 100).rounded())
        let offset = position - Double(note) * 100
        let pitch = ((note % 12) + 12) % 12
        lastSignal = time
        if pitch != shown {
            let count = candidate?.pitchClass == pitch ? candidate!.count + 1 : 1
            candidate = (pitch, count)
            guard count >= Self.switchAfter else { return }
            shown = pitch
            candidate = nil
            recent = []
            withinSince = nil
        } else {
            candidate = nil
        }
        recent.append((time, offset))
        recent.removeAll { time - $0.time > Self.window }
    }

    public var hasSignal: Bool { last.map { !$0.isHeld } ?? false }

    public mutating func readout(time: Double) -> TunerReadout? {
        guard let shown, let lastSignal else { return nil }
        if time - lastSignal > Self.signalTimeout {
            withinSince = nil
            guard time - lastSignal < Self.holdFor, var held = last else {
                last = nil
                return nil
            }
            held.isHeld = true
            held.isInTune = false
            last = held
            return held
        }
        let values = recent.map(\.cents).sorted()
        guard !values.isEmpty else { return last }
        let cents = values[values.count / 2].rounded()
        let (note, string, knowsOctave) = target(pitchClass: shown)
        if abs(cents) <= Self.tolerance {
            if withinSince == nil { withinSince = time }
        } else {
            withinSince = nil
        }
        let inTune = withinSince.map { time - $0 >= Self.inTuneAfter } ?? false
        let frequency = knowsOctave ? note.frequency(a4: a4) * pow(2, cents / 1200) : 0
        let readout = TunerReadout(frequency: frequency, note: note, string: string, cents: cents,
                                   flats: tuning.prefersFlats, isHeld: false, isInTune: inTune,
                                   isFromAmp: true, knowsOctave: knowsOctave)
        last = readout
        return readout
    }

    /// The note with its octave when the tuning has exactly one string of that name, or the string from before.
    mutating func target(pitchClass: Int) -> (Note, Int?, Bool) {
        let strings = tuning.strings
        let matching = strings.indices.filter { strings[$0].pitchClass == pitchClass }
        if matching.count == 1 {
            let index = matching[0]
            previousString = strings.count - index
            return (strings[index], strings.count - index, true)
        }
        if let string = previousString, matching.contains(strings.count - string) {
            return (strings[strings.count - string], string, true)
        }
        previousString = nil
        // The octave is unknown: a note of the guitar's middle, for its name only.
        return (Note(midi: 48 + pitchClass), nil, false)
    }
}
