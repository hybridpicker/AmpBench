import CryptoKit
import Foundation

/// A value in a sound recipe: a number from 0 to 10 for a knob, true or false for a switch, or a label.
public enum RecipeValue: Codable, Equatable, Sendable {
    case number(Double)
    case flag(Bool)
    case text(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .flag(let flag): try container.encode(flag)
        case .text(let text): try container.encode(text)
        }
    }

    /// For tables: "4.5", "true", "Saal weit".
    public var text: String {
        switch self {
        case .number(let number): number == number.rounded() ? String(Int(number)) : String(number)
        case .flag(let flag): String(flag)
        case .text(let text): text
        }
    }

    /// A value from 0 to 1 on the 0 to 10 scale, to one decimal.
    static func tenths(_ value: Float) -> Double { (Double(value) * 100).rounded() / 10 }

    /// How a recipe writes an amp value: a number for knobs, the label for switches and choices.
    static func display(_ value: Float, for parameter: ParameterInfo) -> RecipeValue {
        switch parameter.kind {
        case .toggle(let off, let on): .text(value < 0.5 ? off : on)
        case .selector(let options): .text(parameter.nearest(value, in: options)?.label ?? String(tenths(value)))
        default: .number(tenths(value))
        }
    }
}

/// A sound described by what it is, not by the bytes of one amp: a model and settings for each place of the chain,
/// knobs from 0 to 10. People and AI assistants write it by hand (docs/ai/SOUND-GUIDE.md). Spark Studio reads it from
/// the presets folder like a preset, and `--recipe-check` says what is wrong with one.
///
/// A place left out is switched off with its usual model. A parameter left out keeps the amp's start value.
public struct SoundRecipe: Codable, Equatable, Sendable {
    public static let formatName = "spark-sound-recipe"
    public static let currentVersion = 1

    public struct Unit: Codable, Equatable, Sendable {
        public var model: String
        public var on: Bool
        /// Parameter key (see the catalog) to value. Unknown keys are an error, so a typo is never silently ignored.
        public var settings: [String: RecipeValue]

        public init(model: String, on: Bool = true, settings: [String: RecipeValue] = [:]) {
            self.model = model
            self.on = on
            self.settings = settings
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try c.decode(String.self, forKey: .model)
            on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
            settings = try c.decodeIfPresent([String: RecipeValue].self, forKey: .settings) ?? [:]
        }
    }

    public var format: String
    public var version: Int
    public var name: String
    public var description: String
    public var bpm: Double
    public var tags: [String]
    /// Why the sound is set up this way, and what to try when it does not fit.
    public var notes: String
    /// Place key (gate, compressor, drive, amp, modulation, delay, reverb) to unit.
    public var chain: [String: Unit]

    public init(name: String, description: String = "", bpm: Double = 120, tags: [String] = [], notes: String = "",
                chain: [String: Unit]) {
        format = Self.formatName
        version = Self.currentVersion
        self.name = name
        self.description = description
        self.bpm = bpm
        self.tags = tags
        self.notes = notes
        self.chain = chain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        guard format == Self.formatName else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c,
                                                   debugDescription: "format is not \(Self.formatName)")
        }
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) ?? 120
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        chain = try c.decodeIfPresent([String: Unit].self, forKey: .chain) ?? [:]
    }

    /// What reading a recipe gave: the preset, and what was adjusted on the way.
    public struct Conversion: Equatable, Sendable {
        public var preset: SparkPreset
        public var warnings: [String]
    }

    public struct Problems: LocalizedError, Equatable {
        public var messages: [String]
        public var errorDescription: String? { messages.joined(separator: "\n") }
    }

    /// The model a place gets when the recipe leaves it out, switched off. The same as a new empty preset.
    public static let fallbackModels: [ChainPlace: String] = [
        .gate: "bias.noisegate", .compressor: "BlueComp", .drive: "DistortionTS9", .amp: "Twin",
        .modulation: "ChorusAnalog", .delay: "DelayMono", .reverb: "bias.reverb",
    ]

    /// The preset for the amp. Throws every problem at once; small things, such as a value above 10, are corrected
    /// and listed in the warnings.
    ///
    /// `identity` makes the preset's uuid: the same recipe file gives the same uuid on every reading.
    public func preset(identity: Data? = nil) throws -> Conversion {
        var problems: [String] = []
        var warnings: [String] = []
        if version > Self.currentVersion {
            warnings.append("Das Rezept hat Version \(version), Spark Studio kennt bis \(Self.currentVersion).")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { problems.append("Der Name fehlt.") }
        let fitted = PresetFactory.fit(trimmed)
        if fitted != trimmed {
            warnings.append("Der Name war länger als \(PresetRules.nameLimit) Bytes und wurde auf „\(fitted)“ gekürzt.")
        }
        for key in chain.keys where ChainPlace(key: key) == nil {
            problems.append("„\(key)“ ist kein Platz der Kette. Erlaubt: "
                            + ChainPlace.allCases.map(\.key).joined(separator: ", ") + ".")
        }

        var effects: [SparkPreset.Effect] = []
        for place in ChainPlace.allCases {
            guard let unit = chain.first(where: { ChainPlace(key: $0.key) == place })?.value else {
                effects.append(PresetFactory.effect(Self.fallbackModels[place]!, on: false))
                continue
            }
            guard let info = ModelCatalog.known(unit.model) else {
                problems.append("\(place.key): Das Modell „\(unit.model)“ gibt es nicht. Die Modell-ids stehen in "
                                + "docs/ai/spark-catalog.json, Groß- und Kleinschreibung zählen.")
                continue
            }
            if info.place != place {
                problems.append("\(place.key): „\(unit.model)“ gehört an den Platz \(info.place.key).")
                continue
            }
            if info.isPack {
                warnings.append("\(place.key): „\(unit.model)“ gehört zu einem Zusatzpaket. Ohne das Paket nimmt der "
                                + "Verstärker es nicht.")
            }
            var changes: [Int: Float] = [:]
            let settable = info.settableParameters
            for (key, value) in unit.settings.sorted(by: { $0.key < $1.key }) {
                guard let (index, parameter) = settable.first(where: { $0.info.key == key }) else {
                    let known = settable.map(\.info.key).joined(separator: ", ")
                    problems.append("\(place.key) \(unit.model): „\(key)“ gibt es nicht. Erlaubt: \(known).")
                    continue
                }
                switch Self.amp(value, for: parameter) {
                case .success(let (amp, note)):
                    changes[index] = amp
                    if let note { warnings.append("\(place.key) \(unit.model) \(key): \(note)") }
                case .failure(let problem):
                    problems.append("\(place.key) \(unit.model) \(key): \(problem.messages.joined())")
                }
            }
            effects.append(PresetFactory.effect(unit.model, on: unit.on, changes))
        }
        guard problems.isEmpty else { throw Problems(messages: problems) }

        let range = PresetRules.bpmRange
        let clampedBPM = min(max(Float(bpm.rounded()), range.lowerBound), range.upperBound)
        if Double(clampedBPM) != bpm.rounded() {
            warnings.append("Das Tempo \(RecipeValue.number(bpm).text) liegt außerhalb von "
                            + "\(Int(range.lowerBound))–\(Int(range.upperBound)) und wurde angepasst.")
        }
        let shortDescription = PresetRules.fitDescription(description)
        if shortDescription != description {
            warnings.append("Die Beschreibung war länger als \(PresetRules.descriptionLimit) Bytes und wurde gekürzt.")
        }
        let preset = SparkPreset(uuid: Self.uuid(for: identity), name: fitted, description: shortDescription,
                                 bpm: clampedBPM, effects: effects)
        return Conversion(preset: preset, warnings: warnings)
    }

    /// The amp's value from 0 to 1 for a recipe value, with a note when it had to be corrected.
    static func amp(_ value: RecipeValue, for parameter: ParameterInfo) -> Result<(Float, String?), Problems> {
        func fail(_ message: String) -> Result<(Float, String?), Problems> { .failure(Problems(messages: [message])) }
        switch (parameter.kind, value) {
        case (.knob, .number(let number)):
            let clamped = min(max(number, 0), 10)
            let note = clamped == number ? nil : "\(RecipeValue.number(number).text) liegt außerhalb von 0–10, gesetzt auf \(RecipeValue.number(clamped).text)."
            return .success((Float(clamped / 10), note))
        case (.knob, _):
            return fail("Ein Regler braucht eine Zahl von 0 bis 10.")
        case (.toggle, .flag(let flag)):
            return .success((flag ? 1 : 0, nil))
        case (.toggle(let off, let on), .text(let text)):
            if text.caseInsensitiveCompare(on) == .orderedSame { return .success((1, nil)) }
            if text.caseInsensitiveCompare(off) == .orderedSame { return .success((0, nil)) }
            return fail("Ein Schalter braucht true, false, „\(off)“ oder „\(on)“.")
        case (.toggle, .number):
            return fail("Ein Schalter braucht true oder false.")
        case (.selector(let options), .text(let text)):
            guard let option = options.first(where: { $0.label.caseInsensitiveCompare(text) == .orderedSame }) else {
                return fail("„\(text)“ ist keine Auswahl. Erlaubt: " + options.map { "„\($0.label)“" }.joined(separator: ", ") + ".")
            }
            return .success((option.value, nil))
        case (.selector, _):
            return fail("Eine Auswahl braucht einen der Namen aus dem Katalog.")
        case (.mirror, _), (.reserved, _):
            return fail("Dieser Parameter wird nicht gesetzt.")
        }
    }

    /// A stable uuid from the file's bytes, or a new one.
    static func uuid(for identity: Data?) -> String {
        guard let identity else { return UUID().uuidString }
        var bytes = Array(SHA256.hash(data: identity).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
    }
}

extension SoundRecipe {
    /// A preset described as a recipe, for sharing it or for an AI assistant to read and adjust. Every setting is
    /// written out. Models the catalog does not know and presets without the usual seven places cannot be described.
    public init(preset: SparkPreset, tags: [String] = [], notes: String = "") throws {
        guard preset.effects.count == ChainPlace.allCases.count else {
            throw Problems(messages: ["Das Preset hat \(preset.effects.count) statt 7 Plätze."])
        }
        var chain: [String: Unit] = [:]
        var problems: [String] = []
        for (index, effect) in preset.effects.enumerated() {
            let place = ChainPlace(rawValue: index)!
            guard let info = ModelCatalog.known(effect.name) else {
                problems.append("\(place.key): Das Modell „\(effect.name)“ kennt der Katalog nicht.")
                continue
            }
            var settings: [String: RecipeValue] = [:]
            for (parameterIndex, parameter) in info.settableParameters {
                guard let value = effect.parameters.first(where: { Int($0.index) == parameterIndex })?.value else { continue }
                settings[parameter.key] = RecipeValue.display(value, for: parameter)
            }
            chain[place.key] = Unit(model: effect.name, on: effect.isOn, settings: settings)
        }
        guard problems.isEmpty else { throw Problems(messages: problems) }
        self.init(name: preset.name, description: preset.description, bpm: Double(preset.bpm), tags: tags,
                  notes: notes, chain: chain)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    /// Reads a recipe file. Nil when the data is not a recipe at all, so other JSON files are left alone.
    public static func decodeIfRecipe(_ data: Data) throws -> SoundRecipe? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == formatName else { return nil }
        return try JSONDecoder().decode(SoundRecipe.self, from: data)
    }
}
