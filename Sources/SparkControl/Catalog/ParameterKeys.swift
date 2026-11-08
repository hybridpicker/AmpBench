import Foundation

/// Stable English keys for parameters and places, for files that people and AI assistants write by hand.
///
/// The catalog names parameters in German for the editor, and two parameters of one model may share a name (the
/// tempo knob and the tempo switch of the sync tremolo). A key is unique within a model and never changes, so a sound
/// recipe stays valid when a German label is reworded.
extension ParameterInfo {
    private static let keys: [String: String] = [
        "Gain": "gain", "Höhen": "treble", "Mitten": "middle", "Bässe": "bass", "Master": "master",
        "Lautstärke": "volume", "Pegel": "level", "Ton": "tone", "Drive": "drive", "Fuzz": "fuzz",
        "Distortion": "distortion", "Filter": "filter", "Sustain": "sustain", "Attack": "attack",
        "Empfindlichkeit": "sensitivity", "Kompression": "compression", "Reduktion": "reduction", "Modus": "mode",
        "Pad": "pad", "Form": "shape", "Zeit": "time", "Note": "note", "Effekt": "effect", "Rate": "rate",
        "Tiefe": "depth", "Mix": "mix", "Intensität": "intensity", "Tempo": "speed", "Feedback": "feedback",
        "Bereich": "range", "Echo": "echo", "Abklingen": "decay", "Köpfe": "heads", "Dämpfung": "damping",
        "Low Cut": "lowCut", "High Cut": "highCut", "Dichte": "density", "Länge": "length", "Typ": "type",
        "Schwelle": "threshold", "Brass": "brass", "Bass": "bass", "Sweep": "sweep", "An/Aus": "onOff",
        "Unbekannt": "unknown",
    ]

    /// The parameter's English key, such as "gain", "treble" or "sync" for the tempo switch.
    public var key: String {
        if self == .bpm { return "sync" }
        if let key = Self.keys[name] { return key }
        if name.hasPrefix("Regler "), let number = Int(name.dropFirst("Regler ".count)) { return "knob\(number)" }
        // EQ bands: "100 Hz" → "hz100", "1,6 kHz" → "hz1600".
        let band = name.replacingOccurrences(of: ",", with: ".")
        if band.hasSuffix(" kHz"), let value = Double(band.dropLast(4)) { return "hz\(Int((value * 1000).rounded()))" }
        if band.hasSuffix(" Hz"), let value = Int(band.dropLast(3)) { return "hz\(value)" }
        return name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

extension ChainPlace {
    /// The place's English key in sound recipes: gate, compressor, drive, amp, modulation, delay, reverb.
    public var key: String {
        switch self {
        case .gate: "gate"
        case .compressor: "compressor"
        case .drive: "drive"
        case .amp: "amp"
        case .modulation: "modulation"
        case .delay: "delay"
        case .reverb: "reverb"
        }
    }

    public init?(key: String) {
        guard let place = Self.allCases.first(where: { $0.key == key.lowercased() }) else { return nil }
        self = place
    }
}

extension ModelInfo {
    /// The keys of the parameters a recipe may set, with their index: no mirrors, no unknown ones.
    public var settableParameters: [(index: Int, info: ParameterInfo)] {
        (0..<parameterCount).map { ($0, parameter($0)) }.filter(\.info.isVisible)
    }
}
