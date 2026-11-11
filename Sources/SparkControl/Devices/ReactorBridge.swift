import AmpText
import Foundation

/// Shows a REACTOR's preset as the seven places the editor knows (gate, compressor, drive, amp, modulation, delay,
/// reverb) and takes the edited values back into the REACTOR's own bytes.
///
/// Worked out on a REACTOR 50 on 2026-11-11 with its owner: which block is which kind of effect, the model names the
/// REACTOR takes for live commands (found by setting a marked value by name and reading the playing preset back),
/// and where the amp's knobs sit. Wah, equalizer and FX loop have no place in the editor; they stay as stored.
public enum ReactorBridge {
    /// The kind of effect behind a block's identifier, for the models seen in presets so far.
    static let places: [UInt16: ChainPlace] = [
        0x0309: .gate,
        0x040A: .compressor, 0x0416: .compressor, 0x042A: .compressor, 0x042B: .compressor,
        0x0422: .drive, 0x0420: .drive, 0x0431: .drive, 0x040B: .drive,
        0x0419: .modulation, 0x0418: .modulation, 0x042E: .modulation, 0x041A: .modulation, 0x040F: .modulation,
        0x0432: .delay, 0x0410: .delay, 0x0426: .delay, 0x0425: .delay,
        0x0411: .reverb,
    ]

    /// Blocks that are no effect of the seven places: wah, the amp's place in the chain, equalizer, FX loop.
    static let others: Set<UInt16> = [0x040C, 0x040D, 0x042C, 0x0412]

    /// The name the REACTOR takes in `01 04` and `01 15` for a block. A model without one is shown and stored, but a
    /// change is not heard before it is stored.
    static let liveNames: [UInt16: String] = [
        0x0309: "bias.noisegate", 0x0416: "BBEOpticalComp", 0x0422: "DistortionTS9", 0x0431: "JH.SupaFuzz",
        0x0419: "ChorusCloner", 0x0418: "Tremolo", 0x042E: "TremoloSquare", 0x041A: "Flanger", 0x040F: "ChorusAnalog",
        0x0410: "DelayEchoFilt", 0x0411: "MonoReverb",
        // Reported by the REACTOR while its owner held the FX keys, and confirmed by marked values (2026-11-11).
        0x040A: "SustainComp", 0x042A: "RedComp", 0x042B: "4kComp", 0x0420: "KlonCentaur", 0x040B: "RCBooster",
        0x0426: "DelayDM2",
    ]

    /// The names the REACTOR has of its own, in words.
    static let ownTitles: [String: String] = [
        "ChorusCloner": "Chorus Cloner", "MonoReverb": "Reverb", "SustainComp": "Sustain Comp", "RedComp": "Red Comp",
        "4kComp": "4k Comp", "KlonCentaur": "Centaur Drive", "RCBooster": "RC Booster", "DelayDM2": "DM2 Delay",
    ]

    static let uuidPrefix = "REACTOR-"
    static let ampPrefix = "REACTOR amp: "
    static let unknownPrefix = "REACTOR model "

    /// Where the amp's five knobs sit: block, value, and the name and index of the live command.
    static let ampKnobs: [(title: String, block: UInt16, value: Int, live: String, index: UInt8)] = [
        ("Gain", 0x0502, 0, "Amp.Preamp", 0), ("Bass", 0x0503, 1, "Amp.Tonestack", 1),
        ("Middle", 0x0503, 2, "Amp.Tonestack", 2), ("Treble", 0x0503, 3, "Amp.Tonestack", 3),
        ("Master", 0x0505, 0, "Amp.Poweramp", 0),
    ]

    /// True for a preset made by `sparkPreset`, which only a REACTOR can take back.
    public static func isReactor(_ preset: SparkPreset) -> Bool { preset.uuid.hasPrefix(uuidPrefix) }

    /// The preset an edited one was made from: the one in `slot` if it is that one, otherwise the first that is.
    public static func base(for edited: SparkPreset, in presets: [ReactorPreset?], preferring slot: Int) -> ReactorPreset? {
        if presets.indices.contains(slot), let preset = presets[slot], uuid(preset) == edited.uuid { return preset }
        return presets.compactMap { $0 }.first { uuid($0) == edited.uuid }
    }

    static func uuid(_ preset: ReactorPreset) -> String {
        uuidPrefix + preset.preset.id.map { String(format: "%02X", $0) }.joined()
    }

    /// The effect block of each of the six effect places, by its position among the preset's effects. Nil when the
    /// preset holds models that cannot be told apart.
    static func effectPositions(_ preset: ReactorPreset) -> [ChainPlace: Int]? {
        var found: [ChainPlace: Int] = [:]
        var unknown: [Int] = []
        for (position, block) in preset.effects.enumerated() where !others.contains(block.id) {
            if let place = places[block.id] {
                guard found[place] == nil else { return nil }
                found[place] = position
            } else {
                unknown.append(position)
            }
        }
        let missing = ChainPlace.allCases.filter { $0 != .amp && found[$0] == nil }
        // One model never seen before can only be the one place that is still empty.
        if unknown.count == 1, missing.count == 1 { found[missing[0]] = unknown[0] }
        return found.count == 6 && (unknown.isEmpty || unknown.count == 1 && missing.count == 1) ? found : nil
    }

    static func effectName(_ id: UInt16) -> String {
        liveNames[id] ?? unknownPrefix + String(format: "%04X", id)
    }

    /// The preset as the editor's seven places. Nil when it cannot be laid out that way.
    public static func sparkPreset(_ preset: ReactorPreset) -> SparkPreset? {
        guard let positions = effectPositions(preset) else { return nil }
        var knobs: [SparkPreset.Parameter] = []
        for (index, knob) in ampKnobs.enumerated() {
            guard let block = preset.fixed.first(where: { $0.id == knob.block }), block.values.indices.contains(knob.value)
            else { return nil }
            knobs.append(SparkPreset.Parameter(index: UInt8(index), value: block.values[knob.value]))
        }
        let effects: [SparkPreset.Effect] = ChainPlace.allCases.map { place in
            if place == .amp { return SparkPreset.Effect(name: ampPrefix + preset.amp.name, isOn: true, parameters: knobs) }
            let block = preset.effects[positions[place]!]
            return SparkPreset.Effect(name: effectName(block.id), isOn: block.isOn,
                                      parameters: block.values.enumerated().map {
                                          SparkPreset.Parameter(index: UInt8($0.offset), value: $0.element)
                                      })
        }
        return SparkPreset(uuid: uuid(preset), name: preset.name, version: preset.preset.version,
                           description: preset.preset.description, icon: preset.preset.icon, bpm: preset.tempo,
                           effects: effects, trailer: [])
    }

    public struct Mismatch: LocalizedError, Equatable {
        public var text: String
        public var errorDescription: String? { text }
    }

    /// The REACTOR's bytes for `slot` with the editor's name, tempo, switches and values taken into `base`, the
    /// preset the edited one was made from.
    public static func data(for edited: SparkPreset, base: ReactorPreset, slot: Int) throws -> [UInt8] {
        guard isReactor(edited), edited.uuid == uuid(base), let positions = effectPositions(base),
              edited.effects.count == ChainPlace.allCases.count else {
            throw Mismatch(text: tr("Only a preset read from the REACTOR can be stored on it."))
        }
        var fixed = base.fixed, effects = base.effects
        for place in ChainPlace.allCases {
            let effect = edited.effects[place.rawValue]
            if place == .amp {
                for (index, knob) in ampKnobs.enumerated() {
                    guard let value = effect.parameters.first(where: { Int($0.index) == index })?.value,
                          let at = fixed.firstIndex(where: { $0.id == knob.block }) else { continue }
                    fixed[at].values[knob.value] = min(max(value, 0), 1)
                }
                continue
            }
            let at = positions[place]!
            guard effect.name == effectName(effects[at].id) else {
                throw Mismatch(text: tr("The REACTOR's models cannot be exchanged from here yet (%@).", place.title))
            }
            effects[at].isOn = effect.isOn
            for parameter in effect.parameters where effects[at].values.indices.contains(Int(parameter.index)) {
                effects[at].values[Int(parameter.index)] = parameter.value
            }
        }
        return try base.rewritten(slot: slot, name: edited.name, tempo: edited.bpm, fixed: fixed, effects: effects)
    }

    /// One live message for a change in the editor.
    public enum Live: Equatable, Sendable {
        case parameter(name: String, index: UInt8, value: Float)
        case toggle(name: String, isOn: Bool)
    }

    /// The message that lets a change be heard on the REACTOR, or nil when it has none: a model whose name is not
    /// known, or the amp's on and off.
    public static func live(_ change: LiveChange) -> Live? {
        switch change {
        case .parameter(let effect, let index, let value):
            if effect.hasPrefix(ampPrefix) {
                guard ampKnobs.indices.contains(Int(index)) else { return nil }
                return .parameter(name: ampKnobs[Int(index)].live, index: ampKnobs[Int(index)].index, value: value)
            }
            return effect.hasPrefix(unknownPrefix) ? nil : .parameter(name: effect, index: index, value: value)
        case .toggle(let effect, let isOn):
            return effect.hasPrefix(ampPrefix) || effect.hasPrefix(unknownPrefix) ? nil : .toggle(name: effect, isOn: isOn)
        case .model, .whole:
            return nil
        }
    }

    /// True when changes to this effect are heard at once.
    public static func isHeardLive(_ effect: String) -> Bool { !effect.hasPrefix(unknownPrefix) }

    /// What the editor shows for a REACTOR model the Spark catalog does not hold.
    static func info(for id: String, place: ChainPlace?, parameterCount: Int) -> ModelInfo? {
        if id.hasPrefix(ampPrefix) {
            return ModelInfo(id, .amp, name: String(id.dropFirst(ampPrefix.count)), summary: "Amp of the REACTOR",
                             parameters: ampKnobs.map { .knob($0.title) })
        }
        if id.hasPrefix(unknownPrefix) {
            var info = ModelInfo.unknown(id, place: place, parameterCount: parameterCount)
            info.englishName = "Model " + id.dropFirst(unknownPrefix.count)
            info.englishSummary = "A REACTOR model whose name is not known yet. Changes are heard after storing."
            return info
        }
        if let title = ownTitles[id] {
            var info = ModelInfo.unknown(id, place: place, parameterCount: parameterCount)
            info.englishName = title
            info.englishSummary = "Effect of the REACTOR"
            return info
        }
        return nil
    }
}
