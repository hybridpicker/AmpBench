import Foundation

/// A recipe as plain English, for devices that build a sound from a text description instead of reading a file,
/// such as Positive Grid's REACTOR with its "Text to Tone" (a separate product line, not compatible with Spark).
///
/// Models are named after the device they are modeled after, values on the 0 to 10 scale. It is a description to
/// start from, not a copy: the other device chooses its own models.
extension SoundRecipe {
    public func toneDescription() throws -> String {
        let conversion = try preset()
        var lines: [String] = []
        let head = [name, description].filter { !$0.isEmpty }.joined(separator: ": ")
        lines.append("Guitar tone \u{201C}\(head)\u{201D}, \(Int(conversion.preset.bpm)) BPM.")
        for (index, effect) in conversion.preset.effects.enumerated() where effect.isOn {
            let place = ChainPlace(rawValue: index)!
            guard let info = ModelCatalog.known(effect.name) else { continue }
            let unit = chain.first { ChainPlace(key: $0.key) == place }?.value
            // The amp's five knobs always, because the other device does not know the Spark's start values.
            // For effects only what the recipe sets.
            let values = info.settableParameters.compactMap { parameterIndex, parameter -> String? in
                guard parameter.key != "type", place == .amp || unit?.settings[parameter.key] != nil,
                      let value = effect.parameters.first(where: { Int($0.index) == parameterIndex })?.value
                else { return nil }
                return Self.words(parameter, value)
            }
            var what = Self.englishName(info)
            // The reverb's type is its name: "large hall reverb".
            if let (typeIndex, type) = info.settableParameters.first(where: { $0.info.key == "type" }),
               let value = effect.parameters.first(where: { Int($0.index) == typeIndex })?.value {
                what = "\(Self.labels[type.display(value)] ?? type.display(value)) reverb"
            }
            let line = values.isEmpty ? what : "\(what), " + values.joined(separator: ", ")
            lines.append("\(Self.role(place)): \(line).")
        }
        if lines.count == 1 { lines.append("Everything off.") }
        if !notes.isEmpty { lines.append("Notes: \(notes)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func role(_ place: ChainPlace) -> String {
        switch place {
        case .gate: "Noise gate"
        case .compressor: "Compressor"
        case .drive: "Drive pedal"
        case .amp: "Amp"
        case .modulation: "Modulation"
        case .delay: "Delay"
        case .reverb: "Reverb"
        }
    }

    /// Models without a real device to name, in English.
    private static let plainNames: [String: String] = [
        "bias.noisegate": "noise gate", "BassComp": "bass compressor", "Booster": "clean boost",
        "Overdrive": "classic overdrive", "SABdriver": "amp-in-a-box overdrive", "Acoustic": "neutral acoustic simulation",
        "FatAcousticV2": "full jumbo acoustic simulation", "FlatAcoustic": "flat acoustic simulation",
        "Tremolo": "vintage amp tremolo", "ChorusAnalog": "analog chorus", "Flanger": "flanger",
        "Vibrato01": "pitch vibrato", "Tremolator": "tempo-synced tremolo", "TremoloSquare": "square-wave tremolo",
        "GuitarEQ6": "6-band graphic EQ", "BassEQ6": "6-band bass EQ", "DelayEchoFilt": "filtered echo",
        "VintageDelay": "analog bucket-brigade delay", "DelayReverse": "reverse delay",
        "DelayMultiHead": "multi-head tape echo", "bias.reverb": "reverb",
    ]

    private static func englishName(_ info: ModelInfo) -> String {
        if let name = plainNames[info.id] { return name }
        guard let inspiration = info.inspiration else { return info.name }
        let kind: String = switch info.place {
        case .amp: "amp"
        case .drive: "pedal"
        case .compressor: "compressor"
        default: ""
        }
        return kind.isEmpty ? "\(inspiration) style" : "\(inspiration) style \(kind)"
    }

    /// German option labels of the catalog in English.
    private static let labels: [String: String] = [
        "Raum A": "small room", "Raum B": "room", "Kammer": "chamber", "Saal natürlich": "natural hall",
        "Saal mittel": "medium hall", "Saal weit": "large hall", "Platte kurz": "short plate",
        "Platte satt": "rich plate", "Platte lang": "long plate", "Frei": "free time", "BPM": "synced to tempo",
        "Kompr.": "compress", "Limit": "limit", "Wenig": "low", "Viel": "high", "1 Takt": "1 bar",
        "Aus": "off", "An": "on",
    ]

    private static func words(_ parameter: ParameterInfo, _ value: Float) -> String {
        let label = parameter.display(value)
        switch parameter.kind {
        case .toggle, .selector:
            let english = labels[label] ?? label
            return parameter.key == "sync" ? english : "\(spoken(parameter.key)) \(english)"
        default:
            return "\(spoken(parameter.key)) \(RecipeValue.number(RecipeValue.tenths(value)).text)/10"
        }
    }

    /// "lowCut" → "low cut", "hz1600" → "1.6 kHz", "knob3" → "knob 3".
    private static func spoken(_ key: String) -> String {
        if key.hasPrefix("hz"), let hertz = Int(key.dropFirst(2)) {
            return hertz >= 1000 ? "\(RecipeValue.number(Double(hertz) / 1000).text) kHz" : "\(hertz) Hz"
        }
        if key.hasPrefix("knob"), let number = Int(key.dropFirst(4)) { return "knob \(number)" }
        if key == "effect" { return "level" }
        return key.reduce(into: "") { text, character in
            text += character.isUppercase ? " " + character.lowercased() : String(character)
        }
    }
}
