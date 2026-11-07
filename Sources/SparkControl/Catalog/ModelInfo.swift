import Foundation

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

    public var name: String
    public var kind: Kind

    public init(_ name: String, _ kind: Kind = .knob) {
        self.name = name
        self.kind = kind
    }

    public static func knob(_ name: String) -> ParameterInfo { ParameterInfo(name) }

    public static func toggle(_ name: String, off: String = "Aus", on: String = "An") -> ParameterInfo {
        ParameterInfo(name, .toggle(off: off, on: on))
    }

    /// The tempo switch of time based effects: off uses the knob's time, on follows the preset's BPM.
    public static let bpm = toggle("Tempo", off: "Frei", on: "BPM")

    public static func selector(_ name: String, _ options: [(String, Float)]) -> ParameterInfo {
        ParameterInfo(name, .selector(options.map { Option($0.0, $0.1) }))
    }

    public static let mirror = ParameterInfo("An/Aus", .mirror)
    public static let reserved = ParameterInfo("Unbekannt", .reserved)

    /// Whether the editor shows it.
    public var isVisible: Bool {
        switch kind {
        case .mirror, .reserved: false
        default: true
        }
    }

    /// The value as the editor shows it: 0 to 10 for knobs, the label for switches and selectors.
    public func display(_ value: Float) -> String {
        switch kind {
        case .knob, .mirror, .reserved:
            return String(format: "%.1f", locale: Locale(identifier: "de_DE"), Double(value) * 10)
        case .toggle(let off, let on):
            return value < 0.5 ? off : on
        case .selector(let options):
            return nearest(value, in: options)?.label ?? String(format: "%.2f", value)
        }
    }

    /// The selector's option closest to a value.
    public func nearest(_ value: Float, in options: [Option]) -> Option? {
        options.min { abs($0.value - value) < abs($1.value - value) }
    }
}

/// An amp or effect model the amp knows.
public struct ModelInfo: Equatable, Sendable, Identifiable {
    public enum Group: String, Equatable, Sendable, CaseIterable {
        case clean = "Clean", bright = "Brillant", crunch = "Crunch", highGain = "High Gain", metal = "Metal"
        case acoustic = "Akustik", bass = "Bass"
    }

    /// The model id as the amp sends it, such as "Twin". Case and spaces matter.
    public var id: String
    public var place: ChainPlace
    /// A short name for the pedal or amp, written for this app.
    public var name: String
    /// What kind of sound it is, in a few words.
    public var summary: String
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

    public init(_ id: String, _ place: ChainPlace, name: String, summary: String, inspiration: String? = nil,
                group: Group? = nil, isPack: Bool = false, parameters: [ParameterInfo], defaults: [Float] = []) {
        self.id = id
        self.place = place
        self.name = name
        self.summary = summary
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
        index < parameters.count ? parameters[index] : .knob("Regler \(index + 1)")
    }

    /// A placeholder for a model id the catalog does not know: numbered knobs, all shown.
    public static func unknown(_ id: String, place: ChainPlace?, parameterCount: Int) -> ModelInfo {
        var info = ModelInfo(id, place ?? .modulation, name: id, summary: "Unbekanntes Modell",
                             parameters: (0..<parameterCount).map { .knob("Regler \($0 + 1)") })
        info.isKnown = false
        return info
    }
}
