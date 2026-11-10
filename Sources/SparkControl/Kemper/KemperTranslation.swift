import AmpText
import Foundation

/// Turns a Kemper rig into a sound recipe for the Spark. A Kemper profile is a capture of one real amp; the Spark
/// models amps. So the result is the nearest Spark amp with the rig's gain and equalizer, and the Kemper's effects
/// on the Spark's places where the Spark has something like them. The notes say what was matched and what was left
/// out, because every translated sound wants a listen before it is used.
public enum KemperTranslation {
    /// How hard the rig drives the amp, from its gain. Used as a tag and for amps no rule knows.
    public enum Character: String, CaseIterable, Sendable {
        case clean, crunch, drive

        public init(gain: Double) {
            self = gain < 3.5 ? .clean : gain < 6 ? .crunch : .drive
        }
    }

    public struct Result: Equatable, Sendable {
        public var recipe: SoundRecipe
        public var character: Character
        /// The Spark amp's id and why it was chosen, for the import's list.
        public var ampModel: String
        public var ampReason: String
        /// Kemper effects that are on but have no place on the Spark.
        public var leftOut: [String]
    }

    /// A rule: words to look for in the rig's amp and name, and the Spark amp they lead to.
    struct AmpRule {
        let words: [String]
        let model: String
        /// Only when the rig's gain is at least this, so a clean and a driven profile of one amp can differ.
        var minimumGain: Double = 0
    }

    /// First match wins. Kemper's factory rigs use made-up makers ("Mars" for Marshall, "Fan" for Fender), so both
    /// spellings are listed.
    static let ampRules: [AmpRule] = [
        AmpRule(words: ["jazz chorus", "roland jc", " jc-120", "jc120"], model: "RolandJC120"),
        AmpRule(words: ["5150iii", "5150 iii", "evh", "edvaha"], model: "EVH"),
        AmpRule(words: ["5150", "fifty-one fifty", "6505"], model: "6505Plus"),
        AmpRule(words: ["rectifier", "trip rect", "dual rect", "recto"], model: "Rectifier"),
        AmpRule(words: ["soldano", "slo100", "slo-100", "slo 100", " sold "], model: "SLO100"),
        AmpRule(words: ["bogner", "ecstasy", "engl", "blackmore"], model: "Bogner"),
        AmpRule(words: ["jvm", "jcm 2210", "2210", "friedman", "be-100", "be100"], model: "BE101"),
        AmpRule(words: ["orange", "oranje", "rockerverb", "ad30"], model: "OrangeAD30"),
        AmpRule(words: ["lonestar", "naylor", "super drive"], model: "OverDrivenLuxVerb"),
        AmpRule(words: ["mesa", "mebo", "boogie", "mark iv", "mark v"], model: "AmericanHighGain"),
        AmpRule(words: ["dream weaver", "plexi", "jmp", "jtm", "1959", "super lead", "marshall", "mars ", "trainwreck",
                        "bletchley", "grandmeister", "hughes"], model: "Plexi", minimumGain: 4),
        AmpRule(words: ["dumble", "o+d+s", " ods", "overdrive special", "dream weaver"], model: "ODS50CN"),
        AmpRule(words: ["matchless", "sc30", "dc30", "divided by 13", "/13", "ldw39", "ftr37", "ert33", "star "],
                model: "94MatchDCV2"),
        AmpRule(words: ["ac30", "ac15", "ace thirty", "vox", "voice "], model: "AC Boost"),
        AmpRule(words: ["twin"], model: "Twin"),
        AmpRule(words: ["deluxe", " lux ", "princeton", "lil king", " carr ", "headstrong"], model: "Deluxe65"),
        AmpRule(words: ["bassman", "tweed", "1955 super", "leo fender"], model: "Bassman"),
        AmpRule(words: ["davoli", "checkmate", "teisco", "silvertone"], model: "Checkmate"),
        AmpRule(words: ["marshall", "mars ", "jcm"], model: "Plexi"),
        AmpRule(words: ["am pro", "fender", "fan "], model: "Twin"),
        AmpRule(words: ["acoustic"], model: "AcousticAmpV2"),
    ]

    /// The Spark amp for a rig, and the words that chose it.
    static func amp(for rig: KemperRig) -> (model: String, reason: String) {
        let text = " " + (rig.ampDescription + " " + rig.name).lowercased() + " "
        let gain = rig.gain ?? 5
        for rule in ampRules where gain >= rule.minimumGain {
            if let word = rule.words.first(where: { text.contains($0) }) {
                return (rule.model, tr("“%@”", word.trimmingCharacters(in: .whitespaces)))
            }
        }
        switch Character(gain: gain) {
        case .clean: return ("94MatchDCV2", tr("unknown amp, clean"))
        case .crunch: return ("Plexi", tr("unknown amp, crunch"))
        case .drive: return ("SLO100", tr("unknown amp, distorted"))
        }
    }

    public static func translate(_ rig: KemperRig, name: String? = nil) -> Result {
        let gain = rig.gain ?? 5
        let character = Character(gain: gain)
        let (ampModel, reason) = amp(for: rig)
        let eq = rig.equalizer
        func knob(_ value: Double) -> RecipeValue { .number(KemperRig.tenths(min(max(value, 0), 10))) }

        // The Kemper's equalizer goes −5 to +5 around the profile's own sound; the Spark's knobs sit at 5 for that.
        // The Spark amps have no presence knob, so half of it goes to the treble.
        var chain: [String: SoundRecipe.Unit] = [
            "amp": SoundRecipe.Unit(model: ampModel, settings: [
                "gain": knob(gain), "bass": knob(5 + eq.bass), "middle": knob(5 + eq.middle),
                "treble": knob(5 + eq.treble + eq.presence / 2), "master": .number(6),
            ]),
        ]
        var leftOut: [String] = []
        var used: [String] = []

        // The delay and reverb modules first, so a delay sitting in MOD or X does not push out the real one.
        let first = [KemperRig.Page.delay, KemperRig.Page.reverb]
        let ordered = rig.modules.filter { first.contains($0.page) } + rig.modules.filter { !first.contains($0.page) }
        for module in ordered where module.isOn {
            guard let (place, unit) = unit(for: module, rig: rig) else {
                leftOut.append(module.typeName)
                continue
            }
            if chain[place] == nil {
                chain[place] = unit
                used.append("\(module.typeName) → \(ModelCatalog.known(unit.model)?.name ?? unit.model)")
            } else {
                leftOut.append(tr("%@ (place %@ already taken)", module.typeName, place))
            }
        }
        if chain["reverb"] == nil, let old = rig.oldReverb, old.isOn {
            chain["reverb"] = SoundRecipe.Unit(model: "bias.reverb", settings: [
                "level": knob(max(old.mix * 1.5, 1.5)), "length": knob(old.time),
            ])
            used.append(tr("Reverb → Reverb"))
        }

        var notes = [tr("From the Kemper rig “%@”", rig.name)]
        if !rig.ampDescription.isEmpty { notes[0] += tr(", amp %@", rig.ampDescription) }
        if let author = rig.string(KemperRig.Tag.rigAuthor) { notes[0] += tr(", profile by %@", author) }
        notes[0] += "."
        notes.append(tr("Spark amp %@ because of %@. Gain %@ as on the Kemper; bass, middle and treble from the Kemper EQ, half of the presence in the treble.", ModelCatalog.known(ampModel)?.name ?? ampModel, reason, RecipeValue.number(gain).text))
        if !used.isEmpty { notes.append(tr("Effects: %@.", used.joined(separator: ", "))) }
        if !leftOut.isEmpty { notes.append(tr("Not imported: %@.", leftOut.joined(separator: ", "))) }
        notes.append(tr("A profile is a recording of the real amp, the Spark computes with models: listen and adjust before you use it."))

        let recipe = SoundRecipe(name: PresetFactory.fit(name ?? rig.name),
                                 description: PresetRules.fitDescription(rig.ampDescription),
                                 bpm: rig.tempo ?? 120, tags: ["kemper", character.rawValue],
                                 notes: notes.joined(separator: " "), chain: chain)
        return Result(recipe: recipe, character: character, ampModel: ampModel, ampReason: reason, leftOut: leftOut)
    }

    /// The Spark place and unit for one Kemper effect, or nil when the Spark has nothing like it.
    static func unit(for module: KemperRig.Module, rig: KemperRig) -> (String, SoundRecipe.Unit)? {
        let page = module.page
        func knob(_ parameter: Int, _ fallback: Double, scale: Double = 1, range: ClosedRange<Double> = 0...10)
            -> RecipeValue {
            .number(KemperRig.tenths(min(max((rig.knob(page, parameter) ?? fallback) * scale, range.lowerBound),
                                         range.upperBound)))
        }
        // The Kemper adds a delay or reverb in its own module to the dry signal, and its mix often stands at the top.
        // The Spark's level is the effect's loudness, so the mix is scaled down and capped.
        let wet = knob(4, 5, scale: 0.4, range: 1...4.5)
        let mix = knob(4, 5)
        switch module.type {
        case 57, 58:
            return ("gate", .init(model: "bias.noisegate", settings: ["threshold": knob(18, 4)]))
        case 49:
            return ("compressor", .init(model: "BlueComp", settings: ["sustain": knob(18, 5), "level": .number(5)]))
        case 1, 116:
            return ("compressor", .init(model: "JH.Vox846"))
        case 33:
            return ("drive", .init(model: "DistortionTS9", settings: ["drive": knob(16, 4), "tone": knob(17, 5),
                                                                       "level": .number(6)]))
        case 32, 34, 35, 19:
            return ("drive", .init(model: "Overdrive", settings: ["drive": knob(16, 4), "tone": knob(17, 5),
                                                                   "level": .number(6)]))
        case 42:
            return ("drive", .init(model: "KlonCentaurSilver", settings: ["gain": knob(16, 4), "treble": knob(17, 5),
                                                                           "level": .number(6)]))
        case 36:
            return ("drive", .init(model: "GuitarMuff"))
        case 37, 39:
            return ("drive", .init(model: "ProCoRat"))
        case 38, 20, 21:
            return ("drive", .init(model: "Fuzz"))
        case 113, 114, 115:
            // The booster's volume (parameter 6) runs from 0 dB in the middle; the Spark's booster from 0.
            return ("drive", .init(model: "Booster", settings: ["gain": knob(6, 6)]))
        case 65, 66, 67:
            return ("modulation", .init(model: "ChorusAnalog", settings: ["rate": knob(20, 4), "depth": knob(21, 5)]))
        case 70:
            return ("modulation", .init(model: "Tremolo", settings: ["speed": knob(20, 5), "depth": knob(21, 5)]))
        case 81, 83:
            return ("modulation", .init(model: "Phaser", settings: ["speed": knob(20, 4), "intensity": knob(21, 5)]))
        case 82, 69:
            return ("modulation", .init(model: "UniVibe", settings: ["speed": knob(20, 4), "intensity": knob(21, 5)]))
        case 89, 91:
            return ("modulation", .init(model: "Flanger", settings: ["rate": knob(20, 4), "depth": knob(21, 5),
                                                                      "mix": mix]))
        case 68:
            return ("modulation", .init(model: "Vibrato01", settings: ["speed": knob(20, 4), "depth": knob(21, 5)]))
        case 145...166:
            // Time and feedback as the Kemper shows them on 0 to 10; "To Tempo" (80) follows the song's tempo.
            var settings: [String: RecipeValue] = ["effect": wet, "feedback": knob(93, 4), "time": knob(71, 4)]
            if rig.value(page, 80) == 1 { settings["sync"] = .flag(true) }
            return ("delay", .init(model: "DelayMono", settings: settings))
        case 177...193:
            return ("reverb", .init(model: "bias.reverb", settings: ["level": wet, "length": knob(93, 5)]))
        default:
            return nil
        }
    }
}
