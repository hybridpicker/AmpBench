import AmpText
import Foundation

/// The catalog's texts in the app's language. The catalog itself holds English; the German comes from the table of
/// `AmpText` when a text is read, so a change of language shows at once and nothing is frozen in the static catalog.
///
/// The catalog's words are short ("Length", "Note", "Drive", "Bass", "Amp") and mean something else elsewhere in the
/// app. So the table holds their German under the word followed by a mark that says what it is here, and a word
/// without such an entry is the same in German.
enum CatalogText {
    enum Kind: String {
        /// A place of the chain.
        case place = " (place)"
        /// A group of amps.
        case group = " (amps)"
        /// The name of a model.
        case model = " (model)"
        /// The label of a knob, a switch or one of its positions.
        case label = " (knob)"
        /// A sentence about a model, under its own text.
        case sentence = ""
    }

    static func german(_ english: String, _ kind: Kind) -> String {
        Texts.german(english + kind.rawValue) ?? english
    }

    static func shown(_ english: String, _ kind: Kind) -> String {
        Texts.language == .german ? german(english, kind) : english
    }
}

/// What a parameter of a model is, so it can be shown and set the right way.
public struct ParameterInfo: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var label: String
        public var value: Float

        public init(_ label: String, _ value: Float) {
            self.label = label
            self.value = value
        }
    }

    public enum Kind: Equatable, Sendable {
        /// A knob from 0 to 1, shown from 0 to 10.
        case knob
        /// Two states, below 0.5 off, from 0.5 on.
        case toggle(off: String, on: String)
        /// A few fixed values.
        case selector([Option])
        /// Follows the effect's on and off by itself. Not shown, the editor keeps it in step.
        case mirror
        /// Its meaning is unknown. Not shown and never changed.
        case reserved
    }

    /// The label in English, as the catalog holds it and as recipes and the catalog export write it.
    public var englishName: String
    /// The kind with its labels in English.
    public var englishKind: Kind

    /// The label in the app's language.
    public var name: String {
        if let number = knobNumber { return tr("Knob %d", number) }
        return CatalogText.shown(englishName, .label)
    }

    /// The label in German, whatever the app's language is.
    public var germanName: String {
        if let number = knobNumber { return (Texts.german("Knob %d") ?? "Knob %d").replacingOccurrences(of: "%d", with: "\(number)") }
        return CatalogText.german(englishName, .label)
    }

    /// The kind with its labels in the app's language.
    public var kind: Kind { Texts.language == .german ? germanKind : englishKind }

    /// The kind with its labels in German, whatever the app's language is.
    public var germanKind: Kind {
        switch englishKind {
        case .toggle(let off, let on):
            .toggle(off: CatalogText.german(off, .label), on: CatalogText.german(on, .label))
        case .selector(let options):
            .selector(options.map { Option(CatalogText.german($0.label, .label), $0.value) })
        default: englishKind
        }
    }

    /// The labels are English; they are shown in the app's language.
    public init(_ name: String, _ kind: Kind = .knob) {
        englishName = name
        englishKind = kind
    }

    public static func knob(_ name: String) -> ParameterInfo { ParameterInfo(name) }

    /// A knob the catalog has no name for: "Knob 6".
    public static func numbered(_ number: Int) -> ParameterInfo { ParameterInfo("\(numberedPrefix)\(number)") }

    static let numberedPrefix = "Knob "

    /// The number of a knob without a name of its own.
    var knobNumber: Int? {
        englishName.hasPrefix(Self.numberedPrefix) ? Int(englishName.dropFirst(Self.numberedPrefix.count)) : nil
    }

    public static func toggle(_ name: String, off: String = "Off", on: String = "On") -> ParameterInfo {
        ParameterInfo(name, .toggle(off: off, on: on))
    }

    /// The tempo switch of time based effects: off uses the knob's time, on follows the preset's BPM.
    public static let bpm = toggle("Tempo", off: "Free", on: "BPM")

    public static func selector(_ name: String, _ options: [(String, Float)]) -> ParameterInfo {
        ParameterInfo(name, .selector(options.map { Option($0.0, $0.1) }))
    }

    public static let mirror = ParameterInfo("On/Off", .mirror)
    public static let reserved = ParameterInfo("Unknown", .reserved)

    /// Whether the editor shows it.
    public var isVisible: Bool {
        switch englishKind {
        case .mirror, .reserved: false
        default: true
        }
    }

    /// The value as the editor shows it: 0 to 10 for knobs, the label for switches and selectors.
    public func display(_ value: Float) -> String {
        Self.display(value, kind: kind, locale: Texts.locale)
    }

    /// The same in English with a decimal point, for texts that must not depend on the app's language.
    public func englishDisplay(_ value: Float) -> String {
        Self.display(value, kind: englishKind, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func display(_ value: Float, kind: Kind, locale: Locale) -> String {
        switch kind {
        case .knob, .mirror, .reserved:
            return String(format: "%.1f", locale: locale, Double(value) * 10)
        case .toggle(let off, let on):
            return value < 0.5 ? off : on
        case .selector(let options):
            let nearest = options.min { abs($0.value - value) < abs($1.value - value) }
            return nearest?.label ?? String(format: "%.2f", locale: locale, value)
        }
    }

    /// The selector's option closest to a value.
    public func nearest(_ value: Float, in options: [Option]) -> Option? {
        options.min { abs($0.value - value) < abs($1.value - value) }
    }
}

/// An amp or effect model the amp knows.
public struct ModelInfo: Equatable, Sendable, Identifiable {
    public enum Group: Equatable, Sendable, CaseIterable {
        case clean, bright, crunch, highGain, metal, acoustic, bass

        /// The group's name in English.
        public var englishTitle: String {
            switch self {
            case .clean: "Clean"
            case .bright: "Bright"
            case .crunch: "Crunch"
            case .highGain: "High Gain"
            case .metal: "Metal"
            case .acoustic: "Acoustic"
            case .bass: "Bass"
            }
        }

        /// The group's name in German, whatever the app's language is.
        public var germanTitle: String { CatalogText.german(englishTitle, .group) }

        /// The group's name in the app's language.
        public var title: String { CatalogText.shown(englishTitle, .group) }

        /// The same as `title`, for callers written when the group was a string.
        public var rawValue: String { title }
    }

    /// The model id as the amp sends it, such as "Twin". Case and spaces matter.
    public var id: String
    public var place: ChainPlace
    /// A short name for the pedal or amp, written for this app, in English.
    public var englishName: String
    /// What kind of sound it is, in a few words, in English.
    public var englishSummary: String
    /// The name in the app's language.
    public var name: String { CatalogText.shown(englishName, .model) }
    /// What kind of sound it is, in the app's language.
    public var summary: String { CatalogText.shown(englishSummary, .sentence) }
    public var germanName: String { CatalogText.german(englishName, .model) }
    public var germanSummary: String { CatalogText.german(englishSummary, .sentence) }
    /// The real device it is modeled after, as a neutral hint. Nil when there is none.
    public var inspiration: String?
    public var group: Group?
    /// Part of a paid add-on. The amp plays it only when the official app has unlocked it.
    public var isPack: Bool
    /// False for the placeholder of a model the catalog does not know.
    public var isKnown: Bool
    /// True when a Spark MINI accepted this model.
    public var isCheckedOnMini = false
    public var parameters: [ParameterInfo]
    /// What the amp sets when this model is chosen, as read back from a Spark MINI. Empty when not measured.
    public var defaults: [Float]

    /// `name` and `summary` are English; they are shown in the app's language.
    public init(_ id: String, _ place: ChainPlace, name: String, summary: String, inspiration: String? = nil,
                group: Group? = nil, isPack: Bool = false, parameters: [ParameterInfo], defaults: [Float] = []) {
        self.id = id
        self.place = place
        englishName = name
        englishSummary = summary
        self.inspiration = inspiration
        self.group = group
        self.isPack = isPack
        self.isKnown = true
        self.parameters = parameters
        self.defaults = defaults
    }

    /// How many parameters the amp gives this model: as measured, or as the catalog lists them.
    public var parameterCount: Int { defaults.isEmpty ? parameters.count : defaults.count }

    /// Parameter `index`, or a numbered knob beyond the known ones.
    public func parameter(_ index: Int) -> ParameterInfo {
        index < parameters.count ? parameters[index] : .numbered(index + 1)
    }

    /// A placeholder for a model id the catalog does not know: numbered knobs, all shown.
    public static func unknown(_ id: String, place: ChainPlace?, parameterCount: Int) -> ModelInfo {
        var info = ModelInfo(id, place ?? .modulation, name: id, summary: "Unknown model",
                             parameters: (0..<parameterCount).map { .numbered($0 + 1) })
        info.isKnown = false
        return info
    }
}
