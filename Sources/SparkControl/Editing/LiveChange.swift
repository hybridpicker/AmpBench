import Foundation

/// One change to send to the amp while editing. The amp addresses effects by their model id, so every change names
/// the model that is in its place at the time.
public enum LiveChange: Equatable, Sendable {
    case parameter(effect: String, index: UInt8, value: Float)
    case toggle(effect: String, isOn: Bool)
    case model(from: String, to: String)
    /// Send the whole preset, for changes that have no message of their own, such as the BPM.
    case whole(SparkPreset)

    /// The changes that turn one preset into another, in an order the amp can follow: a model change first, then
    /// the values of that place, then its on or off.
    public static func between(_ old: SparkPreset, _ new: SparkPreset) -> [LiveChange] {
        guard old.effects.count == new.effects.count else { return [.whole(new)] }
        if old.bpm != new.bpm { return [.whole(new)] }
        var changes: [LiveChange] = []
        for (a, b) in zip(old.effects, new.effects) {
            let modelChanged = a.name != b.name
            if modelChanged { changes.append(.model(from: a.name, to: b.name)) }
            let before = Dictionary(a.parameters.map { ($0.index, $0.value) }, uniquingKeysWith: { first, _ in first })
            for parameter in b.parameters where modelChanged || before[parameter.index] != parameter.value {
                changes.append(.parameter(effect: b.name, index: parameter.index, value: parameter.value))
            }
            if modelChanged || a.isOn != b.isOn { changes.append(.toggle(effect: b.name, isOn: b.isOn)) }
        }
        return changes
    }
}

/// Changes waiting to go to the amp, one at a time. Only the newest value of a parameter is kept, as long as no
/// model change lies between, so turning a knob fast sends only what is needed. The order of everything else is kept.
public struct LiveQueue: Sendable {
    public private(set) var items: [LiveChange] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    public mutating func push(_ changes: [LiveChange]) {
        for change in changes { push(change) }
    }

    public mutating func push(_ change: LiveChange) {
        switch change {
        case .whole:
            // A whole preset makes everything before it moot.
            items = [change]
            return
        case .parameter(let effect, let index, _):
            if let slot = replaceable({ if case .parameter(effect, index, _) = $0 { true } else { false } }) {
                items[slot] = change
                return
            }
        case .toggle(let effect, _):
            if let slot = replaceable({ if case .toggle(effect, _) = $0 { true } else { false } }) {
                items[slot] = change
                return
            }
        case .model:
            break
        }
        items.append(change)
    }

    /// The last queued item that matches, if nothing that changes models comes after it.
    private func replaceable(_ matches: (LiveChange) -> Bool) -> Int? {
        for index in items.indices.reversed() {
            if matches(items[index]) { return index }
            switch items[index] {
            case .model, .whole: return nil
            default: continue
            }
        }
        return nil
    }

    public mutating func next() -> LiveChange? {
        items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func removeAll() { items.removeAll() }
}
