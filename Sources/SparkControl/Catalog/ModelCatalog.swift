import Foundation

/// The amp and effect models of the Spark amps, with what their parameters mean.
///
/// Built from public community documentation (see the README) and written in this project's own words. Model ids
/// and parameter counts were checked on a Spark MINI. A model the catalog does not know still works, with numbered
/// knobs.
public enum ModelCatalog {
    public static let all: [ModelInfo] = (gates + compressors + drives + amps + modulations + delays + reverbs).map {
        var model = $0
        if let values = measuredDefaults[model.id] { model.defaults = values }
        model.isCheckedOnMini = measuredDefaults[model.id] != nil || [.gate, .reverb].contains(model.place)
        return model
    }

    private static let byID: [String: ModelInfo] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// The catalog entry of a model id, if there is one.
    public static func known(_ id: String) -> ModelInfo? { byID[id] }

    /// The entry of a model id, or a placeholder with `parameterCount` numbered knobs for an unknown one.
    public static func info(for id: String, place: ChainPlace? = nil, parameterCount: Int) -> ModelInfo {
        byID[id] ?? ReactorBridge.info(for: id, place: place, parameterCount: parameterCount)
            ?? .unknown(id, place: place, parameterCount: parameterCount)
    }

    /// The models for a place of the chain, without paid add-ons unless asked for.
    public static func models(for place: ChainPlace, includingPacks: Bool = false) -> [ModelInfo] {
        all.filter { $0.place == place && (includingPacks || !$0.isPack) }
    }
}
