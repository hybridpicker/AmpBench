import Foundation

/// Stable English keys for parameters and places, for files that people and AI assistants write by hand.
///
/// The catalog's labels are for the editor and are shown in the app's language. A key is unique within a model and
/// never changes, so a sound recipe stays valid when a label is reworded.
extension ParameterInfo {
    private static let keys: [String: String] = [
        "Gain": "gain", "Treble": "treble", "Middle": "middle", "Bass": "bass", "Master": "master",
        "Volume": "volume", "Level": "level", "Tone": "tone", "Drive": "drive", "Fuzz": "fuzz",
        "Distortion": "distortion", "Filter": "filter", "Sustain": "sustain", "Attack": "attack",
        "Sensitivity": "sensitivity", "Compression": "compression", "Reduction": "reduction", "Mode": "mode",
        "Pad": "pad", "Shape": "shape", "Time": "time", "Note": "note", "Effect": "effect", "Rate": "rate",
        "Depth": "depth", "Mix": "mix", "Intensity": "intensity", "Speed": "speed", "Feedback": "feedback",
        "Range": "range", "Echo": "echo", "Decay": "decay", "Heads": "heads", "Damping": "damping",
        "Low Cut": "lowCut", "High Cut": "highCut", "Density": "density", "Length": "length", "Type": "type",
        "Threshold": "threshold", "Brass": "brass", "Sweep": "sweep", "On/Off": "onOff",
        "Unknown": "unknown",
    ]

    /// The parameter's English key, such as "gain", "treble" or "sync" for the tempo switch.
    public var key: String {
        if self == .bpm { return "sync" }
        let name = englishName
        if let key = Self.keys[name] { return key }
        if let number = knobNumber { return "knob\(number)" }
        // EQ bands: "100 Hz" → "hz100", "1.6 kHz" → "hz1600".
        let band = name
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
