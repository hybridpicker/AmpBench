import Foundation

/// Edits a preset: every change returns what to send to the amp, with undo and redo, and knows whether anything
/// differs from the saved state. A whole knob turn is one undo step, between `beginGesture` and `endGesture`.
public struct PresetEditor: Sendable {
    /// What was saved or loaded, the "A" of an A/B comparison.
    public private(set) var original: SparkPreset
    public private(set) var current: SparkPreset
    private var undoStack: [SparkPreset] = []
    private var redoStack: [SparkPreset] = []
    private var gestureStart: SparkPreset?
    /// A new preset counts as changed until it is saved.
    public private(set) var isUnsaved = false
    /// Undo keeps this many steps.
    public static let historyLimit = 200

    public init(_ preset: SparkPreset) {
        original = preset
        current = preset
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// True when anything but the checksum differs from the saved state.
    public var isModified: Bool { isUnsaved || !Self.sameContent(current, original) }

    static func sameContent(_ a: SparkPreset, _ b: SparkPreset) -> Bool {
        var a = a, b = b
        if a.hasChecksum { a.trailer.removeLast() }
        if b.hasChecksum { b.trailer.removeLast() }
        return a == b
    }

    // MARK: Changes

    public mutating func setParameter(place: Int, index: UInt8, value: Float) -> [LiveChange] {
        guard current.effects.indices.contains(place),
              let slot = current.effects[place].parameters.firstIndex(where: { $0.index == index }) else { return [] }
        let value = min(max(value, 0), 1)
        guard current.effects[place].parameters[slot].value != value else { return [] }
        record()
        current.effects[place].parameters[slot].value = value
        return [.parameter(effect: current.effects[place].name, index: index, value: value)]
    }

    /// Switches an effect on or off. Its mirror parameter, if the catalog knows one, follows, like the amp does.
    public mutating func setOn(place: Int, _ isOn: Bool) -> [LiveChange] {
        guard current.effects.indices.contains(place), current.effects[place].isOn != isOn else { return [] }
        record()
        current.effects[place].isOn = isOn
        let effect = current.effects[place]
        let info = ModelCatalog.info(for: effect.name, parameterCount: effect.parameters.count)
        for (slot, parameter) in effect.parameters.enumerated() where info.parameter(Int(parameter.index)).kind == .mirror {
            current.effects[place].parameters[slot].value = isOn ? 1 : 0
        }
        return [.toggle(effect: effect.name, isOn: isOn)]
    }

    /// Changes the model of a place. Its parameters get `values`, or the catalog's start values, so the result does
    /// not depend on what the amp chooses: each value is sent after the model change.
    public mutating func setModel(place: Int, to id: String, values: [Float]? = nil) -> [LiveChange] {
        guard current.effects.indices.contains(place), current.effects[place].name != id else { return [] }
        let info = ModelCatalog.info(for: id, parameterCount: current.effects[place].parameters.count)
        let values = values ?? (info.defaults.isEmpty ? nil : info.defaults)
            ?? (0..<info.parameters.count).map { _ in Float(0.5) }
        record()
        let old = current.effects[place].name
        let marker = current.effects[place].parameters.first?.marker ?? 0x91
        current.effects[place].name = id
        current.effects[place].parameters = values.enumerated().map {
            SparkPreset.Parameter(index: UInt8($0.offset), value: $0.element, marker: marker)
        }
        var changes: [LiveChange] = [.model(from: old, to: id)]
        changes += current.effects[place].parameters.map { .parameter(effect: id, index: $0.index, value: $0.value) }
        return changes
    }

    public mutating func setName(_ name: String) {
        guard current.name != name else { return }
        record()
        current.name = name
    }

    public mutating func setDescription(_ text: String) {
        guard current.description != text else { return }
        record()
        current.description = text
    }

    /// The BPM has no message of its own, so the whole preset goes again.
    public mutating func setBPM(_ bpm: Float) -> [LiveChange] {
        let bpm = min(max(bpm.rounded(), PresetRules.bpmRange.lowerBound), PresetRules.bpmRange.upperBound)
        guard current.bpm != bpm else { return [] }
        record()
        current.bpm = bpm
        return [.whole(current)]
    }

    /// Takes over what the amp reports changed by itself, without an undo step.
    public mutating func follow(_ event: SparkEvent) {
        current.apply(event)
    }

    // MARK: Undo

    public mutating func beginGesture() {
        if gestureStart == nil { gestureStart = current }
    }

    public mutating func endGesture() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        guard start != current else { return }
        push(start)
    }

    private mutating func record() {
        guard gestureStart == nil else { return }
        push(current)
    }

    private mutating func push(_ state: SparkPreset) {
        undoStack.append(state)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public mutating func undo() -> [LiveChange] {
        endGesture()
        guard let previous = undoStack.popLast() else { return [] }
        redoStack.append(current)
        return move(to: previous)
    }

    public mutating func redo() -> [LiveChange] {
        guard let next = redoStack.popLast() else { return [] }
        undoStack.append(current)
        return move(to: next)
    }

    private mutating func move(to state: SparkPreset) -> [LiveChange] {
        let changes = LiveChange.between(current, state)
        current = state
        return changes
    }

    // MARK: Saved state

    /// Back to the saved state, as one undo step.
    public mutating func revert() -> [LiveChange] {
        guard isModified else { return [] }
        record()
        return move(to: original)
    }

    /// The current state becomes the saved one, after it was stored on the Mac or on the amp.
    public mutating func markSaved(_ preset: SparkPreset? = nil) {
        if let preset { current = preset }
        original = current
        isUnsaved = false
    }

    /// Marks a preset that exists nowhere yet, such as one made from a template.
    public mutating func markUnsaved() {
        isUnsaved = true
    }

    /// Takes over a name given to the saved preset elsewhere, without an undo step.
    public mutating func renameSaved(to name: String) {
        original.name = name
        current.name = name
    }
}

/// Limits for what a preset may hold.
public enum PresetRules {
    /// Names up to this many bytes keep the short string form the amp uses for names.
    public static let nameLimit = 31
    public static let bpmRange: ClosedRange<Float> = 40...250

    /// Nil when the name is fine, otherwise why it is not.
    public static func problem(withName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Der Name darf nicht leer sein." }
        if trimmed.utf8.count > nameLimit { return "Höchstens \(nameLimit) Zeichen (Umlaute zählen doppelt)." }
        return nil
    }
}
