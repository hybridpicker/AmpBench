import Foundation

/// How close two sounds are, for finding duplicates the import did not merge: the same chain under another name, or
/// a chain that differs by a little turn of a knob or one effect switched.
///
/// Only what is heard counts: an effect that is off in both is left out, whatever model it holds. Sounds on different
/// amp models are never close. Otherwise every place adds to the distance: the mean change of its knobs (0 to 1, the
/// amp's twice), or 0.5 for an effect that is on in only one of them or on with another model.
public enum PresetSimilarity {
    /// At most this distance counts as close: about a fifth of the amp's knobs turned by a quarter, or one effect
    /// switched with everything else alike.
    public static let closeLimit = 0.5

    public struct Comparison: Equatable, Sendable {
        /// 0 for the same sound.
        public var distance: Double
        /// The places where the two differ, in chain order.
        public var differing: [ChainPlace]
        public var isEqual: Bool { differing.isEmpty && distance == 0 }
    }

    /// Nil when the two are not comparable: other amp models or chains of another length.
    public static func compare(_ a: SparkPreset, _ b: SparkPreset) -> Comparison? {
        guard a.effects.count == b.effects.count, !a.effects.isEmpty else { return nil }
        var distance = 0.0
        var differing: [ChainPlace] = []
        for index in a.effects.indices {
            let (x, y) = (a.effects[index], b.effects[index])
            let place = ChainPlace.of(index: index, count: a.effects.count)
            if place == .amp {
                guard x.name == y.name else { return nil }
                let change = knobChange(x, y)
                distance += 2 * change
                if change > 0 { differing.append(.amp) }
                continue
            }
            switch (x.isOn, y.isOn) {
            case (false, false): continue
            case (true, true) where x.name == y.name:
                let change = knobChange(x, y)
                distance += change
                if change > 0, let place { differing.append(place) }
            default:
                distance += 0.5
                if let place { differing.append(place) }
            }
        }
        return Comparison(distance: distance, differing: differing)
    }

    /// The mean change of the knobs both have, 0 to 1.
    static func knobChange(_ x: SparkPreset.Effect, _ y: SparkPreset.Effect) -> Double {
        let pairs = zip(x.parameters, y.parameters)
        let changes = pairs.map { Double(abs($0.value - $1.value)) }
        guard !changes.isEmpty else { return 0 }
        // Rounding in the amp's floats is not a difference anyone hears.
        let mean = changes.reduce(0, +) / Double(changes.count)
        return mean < 0.0005 ? 0 : mean
    }

    /// The sounds of `items` close to `preset`, nearest first, leaving out `preset`'s own file.
    public static func neighbours(of item: SavedPreset, in items: [SavedPreset],
                                  limit: Double = closeLimit) -> [(item: SavedPreset, comparison: Comparison)] {
        items.compactMap { other in
            guard other.url != item.url, let comparison = compare(item.file.preset, other.file.preset),
                  comparison.distance <= limit else { return nil }
            return (other, comparison)
        }.sorted { $0.comparison.distance < $1.comparison.distance }
    }

    /// Groups of sounds that are close to each other, directly or through one another, each of two or more, the
    /// largest first. Slot backups are left out: being close to what they backed up is their purpose.
    public static func groups(_ items: [SavedPreset], limit: Double = closeLimit) -> [[SavedPreset]] {
        let sounds = items.filter { !$0.file.isBackup }
        var parent = Array(sounds.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        // Only sounds on the same amp can be close, so compare within those.
        let byAmp = Dictionary(grouping: sounds.indices) { sounds[$0].file.preset.ampModel ?? "" }
        for indices in byAmp.values {
            for (n, i) in indices.enumerated() {
                for j in indices[(n + 1)...] {
                    if let comparison = compare(sounds[i].file.preset, sounds[j].file.preset),
                       comparison.distance <= limit {
                        parent[root(j)] = root(i)
                    }
                }
            }
        }
        let grouped = Dictionary(grouping: sounds.indices, by: root)
        return grouped.values.filter { $0.count > 1 }
            .map { $0.map { sounds[$0] } }
            .sorted { $0.count != $1.count ? $0.count > $1.count
                : $0[0].name.localizedStandardCompare($1[0].name) == .orderedAscending }
    }
}
