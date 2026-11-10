import AmpText
import Foundation

/// A sound for the REACTOR, as the few live commands it was heard taking on 2026-11-10: the amp selector with
/// Push/Smooth and Heat (`01 B1`), the amp's knobs (`01 04` on Amp.Preamp and Amp.Tonestack), effects on and off
/// (`01 15`) and the reverb's level. Not a preset: the REACTOR keeps presets in a format of its own that AmpBench
/// does not write. The sound plays until the slot changes; storing it is done on the device.
///
/// The master is never set from here: loudness stays in the player's hand.
public struct ReactorSound: Equatable, Sendable {
    /// 0 to 5: Clean, Warm, Grit, Crunch, Hi-Gain, Extreme (`ReactorState.ampNames`).
    public var amp: Int
    /// 0 Push, 1 Standard, 2 Smooth.
    public var voice = 1
    /// 0 to 4, 2 in the middle.
    public var heat = 2
    /// 0 to 1.
    public var gain: Float
    public var bass: Float
    public var middle: Float
    public var treble: Float
    /// Chain place to on or off, for the places the REACTOR's factory effects are known by name.
    public var effects: [ChainPlace: Bool]
    /// 0 to 1, sent only while the reverb is on.
    public var reverbLevel: Float?

    /// The effect names heard in the REACTOR's factory presets. A slot with other effects ignores the switch.
    public static let effectNames: [ChainPlace: String] = [
        .gate: "bias.noisegate", .compressor: "BBEOpticalComp", .drive: "DistortionTS9",
        .modulation: "ChorusCloner", .delay: "DelayEchoFilt", .reverb: "MonoReverb",
    ]

    /// The REACTOR amp nearest to a Spark amp model.
    static let ampForModel: [String: Int] = [
        "RolandJC120": 0, "Twin": 0, "ADClean": 0, "94MatchDCV2": 0, "ODS50CN": 0, "JH.DualShowman": 0,
        "Acoustic": 0, "AcousticAmpV2": 0, "FatAcousticV2": 0, "FlatAcoustic": 0,
        "Bassman": 1, "Checkmate": 1, "TwoStoneSP50": 1, "Deluxe65": 1, "BluesJrTweed": 1, "AC Boost": 1,
        "OverDrivenLuxVerb": 2, "OverDrivenJM45": 2, "JH.JTM45": 2, "JH.Bassman50Silver": 2,
        "Plexi": 3, "OrangeAD30": 3, "JH.SuperLead100": 3, "JH.SoundCity100": 3, "JH.Sunn100": 3,
        "Bogner": 4, "AmericanHighGain": 4, "SLO100": 4, "YJM100": 4, "EVH": 4, "BE101": 4, "SwitchAxeLead": 4,
        "Invader": 4, "Rectifier": 5, "6505Plus": 5,
    ]

    public struct Problem: LocalizedError, Equatable {
        public var text: String
        public var errorDescription: String? { text }
    }

    public var ampName: String { ReactorState.ampNames[min(max(amp, 0), ReactorState.ampNames.count - 1)] }

    /// The nearest REACTOR sound for a Spark preset: the amp by its model (an unknown one by its gain), the amp's
    /// gain and tone knobs, and which effects are on.
    public init(preset: SparkPreset) throws {
        guard preset.effects.count == ChainPlace.allCases.count else {
            throw Problem(text: tr("The preset has %d places instead of 7.", preset.effects.count))
        }
        func value(_ place: ChainPlace, _ key: String) -> Float? {
            let effect = preset.effects[place.rawValue]
            guard let index = ModelCatalog.known(effect.name)?.settableParameters.first(where: { $0.info.key == key })?.index
            else { return nil }
            return effect.parameters.first { Int($0.index) == index }.flatMap { AmpGuard.value($0.value) }
        }
        let ampEffect = preset.effects[ChainPlace.amp.rawValue]
        gain = value(.amp, "gain") ?? 0.5
        bass = value(.amp, "bass") ?? 0.5
        middle = value(.amp, "middle") ?? 0.5
        treble = value(.amp, "treble") ?? 0.5
        amp = Self.ampForModel[ampEffect.name] ?? (gain < 0.3 ? 0 : gain < 0.45 ? 1 : gain < 0.6 ? 2 : gain < 0.75 ? 3 : 4)
        effects = [:]
        for place in Self.effectNames.keys { effects[place] = preset.effects[place.rawValue].isOn }
        reverbLevel = effects[.reverb] == true ? value(.reverb, "level") : nil
    }

    /// One message with what it does, for the log and for tests.
    public struct Step: Equatable, Sendable {
        public var text: String
        public var bytes: [UInt8]
    }

    /// The messages in sending order, one at a time with a pause between them: tone and gain first, then the amp, so
    /// a hotter amp never meets the old gain; then the effects.
    public func steps(firstSequence: UInt8 = 1, header: Bool = true) -> [Step] {
        var sequence = firstSequence
        var steps: [Step] = []
        func next() -> UInt8 {
            defer { sequence = (sequence + 1) & 0x7F }
            return sequence
        }
        func knob(_ block: String, _ index: UInt8, _ value: Float, _ name: String) {
            let safe = min(max(value, 0), 1)
            steps.append(Step(text: "\(name) \(String(format: "%.2f", safe))",
                              bytes: SparkProtocol.setParameter(effect: block, index: index, value: safe,
                                                                sequence: next(), header: header)))
        }
        knob("Amp.Tonestack", 1, bass, "Bass")
        knob("Amp.Tonestack", 2, middle, "Middle")
        knob("Amp.Tonestack", 3, treble, "Treble")
        knob("Amp.Preamp", 0, gain, "Gain")
        let selector = [UInt8(min(max(amp, 0), 5)), UInt8(5 * min(max(voice, 0), 2) + min(max(heat, 0), 4))]
        steps.append(Step(text: "Amp \(ampName)",
                          bytes: SparkProtocol.frame(command: SparkProtocol.Command.set, sub: ReactorState.ampSelector,
                                                     payload: selector, sequence: next(), header: header)))
        for place in ChainPlace.allCases {
            guard let name = Self.effectNames[place], let isOn = effects[place] else { continue }
            steps.append(Step(text: "\(ReactorState.placeNames[place.rawValue]) \(isOn ? tr("on") : tr("off"))",
                              bytes: SparkProtocol.setEffect(name, on: isOn, sequence: next(), header: header)))
        }
        if let reverbLevel, let name = Self.effectNames[.reverb] {
            knob(name, 0, reverbLevel, tr("Reverb level"))
        }
        return steps
    }

    /// What will be set, in one line for the question before sending.
    public var summary: String {
        let on = ChainPlace.allCases.filter { effects[$0] == true }.map { ReactorState.placeNames[$0.rawValue] }
        func ten(_ value: Float) -> String { String(format: "%.1f", locale: Texts.locale, value * 10) }
        return tr("Amp %@, gain %@, bass %@, middle %@, treble %@; %@", ampName, ten(gain), ten(bass), ten(middle), ten(treble),
                  on.isEmpty ? tr("all effects off") : tr("on: %@", on.joined(separator: ", ")))
    }
}
