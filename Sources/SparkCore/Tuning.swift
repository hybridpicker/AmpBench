import Foundation

/// A note of the equal-tempered scale, as a MIDI number: 69 is A4, 40 the low E of a guitar (E2), 23 the low B of a
/// five-string bass (H0 in German).
public struct Note: Hashable, Sendable {
    public let midi: Int

    public init(midi: Int) {
        self.midi = midi
    }

    private static let sharps = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "H"]
    private static let flats = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B", "H"]
    private static let spokenSharps = ["C", "Cis", "D", "Dis", "E", "F", "Fis", "G", "Gis", "A", "Ais", "H"]
    private static let spokenFlats = ["C", "Des", "D", "Es", "E", "F", "Ges", "G", "As", "A", "B", "H"]

    /// The German name: H for B, B for B♭.
    public func name(flats: Bool = false) -> String {
        (flats ? Self.flats : Self.sharps)[pitchClass]
    }

    /// How VoiceOver says it: "Fis", "Es".
    public func spokenName(flats: Bool = false) -> String {
        (flats ? Self.spokenFlats : Self.spokenSharps)[pitchClass]
    }

    public var pitchClass: Int { ((midi % 12) + 12) % 12 }
    /// The octave in scientific numbering: E2, A4.
    public var octave: Int { Int((Double(midi) / 12).rounded(.down)) - 1 }

    public func frequency(a4: Double) -> Double {
        a4 * pow(2, Double(midi - 69) / 12)
    }

    /// The note nearest to a frequency.
    public static func nearest(to frequency: Double, a4: Double) -> Note {
        Note(midi: Int((69 + 12 * log2(frequency / a4)).rounded()))
    }

    /// How far a frequency lies from this note, in cents.
    public func cents(of frequency: Double, a4: Double) -> Double {
        1200 * log2(frequency / self.frequency(a4: a4))
    }
}

/// The tunings the tuner knows. Strings go from the lowest, the sixth, to the highest, the first.
public enum Tuning: String, CaseIterable, Identifiable, Sendable {
    case standard
    case dropD
    case dadgad
    case openG
    case halfStepDown
    case chromatic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .dropD: "Drop D"
        case .dadgad: "DADGAD"
        case .openG: "Open G"
        case .halfStepDown: "Halbton tiefer"
        case .chromatic: "Chromatisch"
        }
    }

    /// The strings from the sixth to the first. Empty for the chromatic tuner.
    public var strings: [Note] {
        let midi: [Int] = switch self {
        case .standard: [40, 45, 50, 55, 59, 64]
        case .dropD: [38, 45, 50, 55, 59, 64]
        case .dadgad: [38, 45, 50, 55, 57, 62]
        case .openG: [38, 43, 50, 55, 59, 62]
        case .halfStepDown: [39, 44, 49, 54, 58, 63]
        case .chromatic: []
        }
        return midi.map(Note.init)
    }

    /// Names with flats, as a tuning half a step down is written.
    public var prefersFlats: Bool { self == .halfStepDown }

    /// The strings as a short line, such as "E A D G H E".
    public var summary: String {
        strings.isEmpty ? "Alle Töne" : strings.map { $0.name(flats: prefersFlats) }.joined(separator: " ")
    }
}

/// What the tuner shows for a reading.
public struct TunerReadout: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case low, inTune, high }

    public var frequency: Double
    public var note: Note
    /// The string number, 6 for the lowest, when the tuning has strings and the tone is near one.
    public var string: Int?
    public var cents: Double
    public var flats: Bool
    public var isHeld: Bool
    /// The deviation has stayed within the tolerance long enough.
    public var isInTune: Bool
    /// From the amp's own tuner: whole cents, about ±10 cents exact, and a wider tolerance.
    public var isFromAmp: Bool
    /// False when only the note's name is known, not its octave, as from the amp for a note two strings share.
    /// `frequency` and `note.octave` mean nothing then.
    public var knowsOctave: Bool

    public init(frequency: Double, note: Note, string: Int?, cents: Double, flats: Bool, isHeld: Bool, isInTune: Bool,
                isFromAmp: Bool = false, knowsOctave: Bool = true) {
        self.frequency = frequency
        self.note = note
        self.string = string
        self.cents = cents
        self.flats = flats
        self.isHeld = isHeld
        self.isInTune = isInTune
        self.isFromAmp = isFromAmp
        self.knowsOctave = knowsOctave
    }

    public var direction: Direction {
        if abs(cents) <= (isFromAmp ? AmpTunerInterpreter.tolerance : TunerInterpreter.tolerance) { return .inTune }
        return cents < 0 ? .low : .high
    }

    public var noteName: String { note.name(flats: flats) }
}

/// Turns readings into notes, strings and cents for a tuning and a concert pitch, with a little hysteresis so the
/// note does not flicker between two neighbors, and with the timer behind "Gestimmt".
public struct TunerInterpreter: Sendable {
    /// "Gestimmt" within ±0.5 cents.
    public static let tolerance = 0.5
    /// ... held for this long, in seconds ...
    public static let inTuneAfter = 0.4
    /// ... measured precisely enough to tell: the expected error is at most this many cents.
    public static let inTunePrecision = 0.2
    /// Concert pitch A4, settable in tenths of a hertz.
    public static let a4Range = 430.0...450.0
    public static let defaultA4 = 440.0

    public var tuning: Tuning
    public var a4: Double
    private var previous: (note: Note, string: Int?)?
    private var withinSince: Double?
    private var lastInTune = false

    public init(tuning: Tuning = .standard, a4: Double = TunerInterpreter.defaultA4) {
        self.tuning = tuning
        self.a4 = a4
    }

    /// `time` is in seconds, from any steady clock.
    public mutating func interpret(_ reading: PitchReading?, time: Double) -> TunerReadout? {
        guard let reading else {
            previous = nil
            withinSince = nil
            lastInTune = false
            return nil
        }
        let (note, string) = target(for: reading.frequency)
        previous = (note, string)
        let cents = note.cents(of: reading.frequency, a4: a4)
        var inTune = lastInTune
        if !reading.isHeld {
            if abs(cents) <= Self.tolerance, let precision = reading.uncertainty, precision <= Self.inTunePrecision {
                if withinSince == nil { withinSince = time }
                inTune = time - (withinSince ?? time) >= Self.inTuneAfter
            } else {
                withinSince = nil
                inTune = false
            }
            lastInTune = inTune
        }
        return TunerReadout(frequency: reading.frequency, note: note, string: string, cents: cents,
                            flats: tuning.prefersFlats, isHeld: reading.isHeld, isInTune: inTune)
    }

    /// The string or note a frequency is tuned towards.
    public func target(for frequency: Double) -> (Note, Int?) {
        let strings = tuning.strings
        if !strings.isEmpty {
            let distances = strings.map { abs($0.cents(of: frequency, a4: a4)) }
            if let best = distances.indices.min(by: { distances[$0] < distances[$1] }), distances[best] <= 300 {
                // Stay on the string from before unless the new one is clearly nearer.
                if let string = previous?.string, let index = Optional(strings.count - string),
                   strings.indices.contains(index), index != best, distances[index] <= 300,
                   distances[index] - distances[best] < 30 {
                    return (strings[index], string)
                }
                return (strings[best], strings.count - best)
            }
        }
        let nearest = Note.nearest(to: frequency, a4: a4)
        if let note = previous?.note, previous?.string == nil, note != nearest, abs(note.cents(of: frequency, a4: a4)) < 60 {
            return (note, nil)
        }
        return (nearest, nil)
    }
}

/// The tuner's numbers as text, with a decimal comma and a real minus sign.
public enum TunerText {
    /// "+0,3", "−12,0", "±0,0".
    public static func cents(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "±0,0" }
        return (rounded < 0 ? "−" : "+") + decimal(abs(rounded), digits: 1)
    }

    /// "+3", "−12", "±0": whole cents, for the amp's coarser tuner.
    public static func wholeCents(_ value: Double) -> String {
        let rounded = value.rounded()
        if rounded == 0 { return "±0" }
        return (rounded < 0 ? "−" : "+") + String(Int(abs(rounded)))
    }

    /// "82,41".
    public static func hertz(_ value: Double, digits: Int = 2) -> String {
        decimal(value, digits: digits)
    }

    /// "plus 0,3 Cent", for VoiceOver.
    public static func spokenCents(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "0 Cent" }
        return (rounded < 0 ? "minus " : "plus ") + decimal(abs(rounded), digits: 1) + " Cent"
    }

    public static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }
}
