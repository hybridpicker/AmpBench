import Foundation

/// The model catalog as a reference for people and AI assistants who write sound recipes: every model with its id,
/// place, character, parameters and start values, on the same 0 to 10 scale as the editor and the recipes.
///
/// `docs/ai/spark-catalog.json` and `docs/ai/spark-catalog.md` are written from this with
/// `SparkStudio --catalog-export docs/ai`. A test fails when the files in the repository fall behind the catalog.
public struct CatalogReference: Codable, Equatable, Sendable {
    public struct Place: Codable, Equatable, Sendable {
        public var key: String
        public var index: Int
        public var title: String
        public var models: [String]
    }

    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        /// On the 0 to 10 scale.
        public var value: Double
    }

    public struct Parameter: Codable, Equatable, Sendable {
        public var index: Int
        public var key: String
        /// The label in Spark Studio's editor (German).
        public var label: String
        /// "knob" (a number from 0 to 10), "switch" (true or false, or one of `off`/`on`) or "choice" (an option label).
        public var kind: String
        /// The amp's start value: a number for knobs, a label for switches and choices. Nil when not measured.
        public var start: RecipeValue?
        public var off: String?
        public var on: String?
        public var options: [Option]?
    }

    public struct Model: Codable, Equatable, Sendable {
        public var id: String
        public var place: String
        public var name: String
        /// What it sounds like, in German as the editor shows it.
        public var summary: String
        /// The real device it is modeled after, as a neutral hint.
        public var inspiration: String?
        /// For amps: clean, bright, crunch, highGain, metal, acoustic, bass.
        public var group: String?
        /// Part of a paid add-on. The amp plays it only when the official Spark app has unlocked it.
        public var pack: Bool
        /// True when a Spark MINI accepted the model and its start values were read back. See `checkedOn` for other
        /// devices.
        public var checkedOnAmp: Bool
        public var parameters: [Parameter]
        /// How many parameters the amp gives this model, hidden ones included.
        public var parameterCount: Int
        /// The amp's start values as it stores them, 0 to 1, one per parameter. Empty when not measured.
        public var defaults: [Double]
        /// Indexes of the parameters that follow the effect's on and off by themselves (1 when on, 0 when off).
        public var mirrors: [Int]
    }

    /// A device the catalog was checked on, with what was checked there.
    public struct CheckedDevice: Codable, Equatable, Sendable {
        public var device: String
        public var firmware: String
        public var scope: String
    }

    public var format = "spark-catalog"
    public var version = 2
    /// Where the models were checked. Models that only one device knows join only after a check on that device
    /// (`spark-probe catalog-check`, eight at a time).
    public var checkedOn: [CheckedDevice] = [
        CheckedDevice(device: "Spark MINI", firmware: "1.11.2.75",
                      scope: "every model marked checkedOnAmp accepted, start values read back"),
        CheckedDevice(device: "Spark NEO", firmware: "1.16.1.60",
                      scope: "the 16 models of its factory presets; a model change to DistortionTS9 set the MINI's start values"),
    ]
    public var scale = "Knobs go from 0 to 10, like the editor. The amp stores them as 0 to 1."
    public var places: [Place]
    public var models: [Model]

    public init() {
        let all = ModelCatalog.all
        places = ChainPlace.allCases.map { place in
            Place(key: place.key, index: place.rawValue, title: place.title,
                  models: all.filter { $0.place == place }.map(\.id))
        }
        models = all.map(Self.model)
    }

    static func model(_ info: ModelInfo) -> Model {
        let parameters = info.settableParameters.map { index, parameter -> Parameter in
            let start = index < info.defaults.count ? RecipeValue.display(info.defaults[index], for: parameter) : nil
            switch parameter.kind {
            case .toggle(let off, let on):
                return Parameter(index: index, key: parameter.key, label: parameter.name, kind: "switch", start: start,
                                 off: off, on: on)
            case .selector(let options):
                return Parameter(index: index, key: parameter.key, label: parameter.name, kind: "choice", start: start,
                                 options: options.map { Option(label: $0.label, value: RecipeValue.tenths($0.value)) })
            default:
                return Parameter(index: index, key: parameter.key, label: parameter.name, kind: "knob", start: start)
            }
        }
        return Model(id: info.id, place: info.place.key, name: info.name, summary: info.summary,
                     inspiration: info.inspiration, group: info.group?.key, pack: info.isPack,
                     checkedOnAmp: info.isCheckedOnMini, parameters: parameters, parameterCount: info.parameterCount,
                     defaults: info.defaults.map { Double("\($0)") ?? Double($0) },
                     mirrors: (0..<info.parameterCount).filter { info.parameter($0).kind == .mirror })
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    /// The same as a readable Markdown page, one table per place of the chain.
    public func markdown() -> String {
        var lines = [
            "# Spark model catalog",
            "",
            "Written by `SparkStudio --catalog-export docs/ai` from `Sources/SparkControl/Catalog`. Do not edit by hand.",
            "The same data as JSON is in [spark-catalog.json](spark-catalog.json). How to build a sound from it is in",
            "[SOUND-GUIDE.md](SOUND-GUIDE.md).",
            "",
            "Checked on: " + checkedOn.map { "\($0.device), firmware \($0.firmware) (\($0.scope))" }
                .joined(separator: "; ") + ".",
            "\(scale) Values in brackets are the start values a Spark MINI sets.",
            "Models marked *pack* need a paid add-on and are refused by an amp without it.",
        ]
        for place in places {
            lines += ["", "## \(place.index + 1). \(place.title) (`\(place.key)`)", ""]
            lines += ["| Model id | Name | Character | Modeled after | Parameters |", "|---|---|---|---|---|"]
            for id in place.models {
                guard let model = models.first(where: { $0.id == id }) else { continue }
                let name = model.pack ? "\(model.name) *pack*" : model.name
                let group = model.group.map { " (\($0))" } ?? ""
                let parameters = model.parameters.map(Self.describe).joined(separator: ", ")
                lines.append("| `\(model.id)` | \(name)\(group) | \(model.summary) | \(model.inspiration ?? "–") | \(parameters) |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func describe(_ parameter: Parameter) -> String {
        let start = parameter.start.map { " [\($0.text)]" } ?? ""
        switch parameter.kind {
        case "switch": return "`\(parameter.key)` \(parameter.off ?? "")/\(parameter.on ?? "")\(start)"
        case "choice":
            let options = (parameter.options ?? []).map(\.label).joined(separator: " · ")
            return "`\(parameter.key)` (\(options))\(start)"
        default: return "`\(parameter.key)`\(start)"
        }
    }
}

extension ModelInfo.Group {
    /// The group's English key.
    public var key: String {
        switch self {
        case .clean: "clean"
        case .bright: "bright"
        case .crunch: "crunch"
        case .highGain: "highGain"
        case .metal: "metal"
        case .acoustic: "acoustic"
        case .bass: "bass"
        }
    }
}
