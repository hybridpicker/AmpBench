import Foundation

extension ModelCatalog {
    /// Every amp has the same five parameters, in this order.
    static let ampKnobs: [ParameterInfo] = [.knob("Gain"), .knob("Treble"), .knob("Middle"), .knob("Bass"), .knob("Master")]
    static let packAmpKnobs: [ParameterInfo] = [.knob("Gain"), .knob("Treble"), .knob("Middle"), .knob("Bass"),
                                                .knob("Volume")]

    private static func amp(_ id: String, _ name: String, _ group: ModelInfo.Group, _ summary: String,
                            _ inspiration: String?) -> ModelInfo {
        ModelInfo(id, .amp, name: name, summary: summary, inspiration: inspiration, group: group, parameters: ampKnobs)
    }

    private static func packAmp(_ id: String, _ name: String, _ summary: String, _ inspiration: String) -> ModelInfo {
        ModelInfo(id, .amp, name: name, summary: summary, inspiration: inspiration, group: .crunch, isPack: true,
                  parameters: packAmpKnobs)
    }

    static let amps: [ModelInfo] = [
        amp("RolandJC120", "Solid Clean", .clean, "Solid-state clean, crystal clear and dry", "Roland JC-120"),
        amp("Twin", "US Clean", .clean, "Big clean combo with lots of headroom", "Fender Twin Reverb"),
        amp("ADClean", "Brit Clean", .clean, "British clean channel, warm and round", "Orange AD30, Clean"),
        amp("94MatchDCV2", "Boutique Clean", .clean, "Class A clean with bite", "Matchless DC-30"),
        amp("ODS50CN", "Silk Clean", .clean, "Silky clean tone that breaks up softly", "Dumble ODS 50"),
        amp("Bassman", "Tweed 4×10", .bright, "Tweed combo, crisp and open", "Fender Bassman ’59"),
        amp("AC Boost", "Brit Chime", .bright, "Chiming class A tone", "Vox AC30 Top Boost"),
        amp("Checkmate", "Vintage Combo", .bright, "Small tube combo from the 60s", "Teisco Checkmate 20"),
        amp("TwoStoneSP50", "Studio Glass", .bright, "Modern boutique tone, very clear", "Two-Rock Studio Pro 50"),
        amp("Deluxe65", "US Deluxe", .crunch, "Small US combo that breaks up early", "Fender Deluxe"),
        amp("Plexi", "Plexi Crunch", .crunch, "Classic British rock crunch", "Marshall Super Lead ’Plexi’"),
        amp("OverDrivenJM45", "Brit 45", .crunch, "Early British tube crunch", "Marshall JTM45"),
        amp("OverDrivenLuxVerb", "US Crunch", .crunch, "Cranked US combo", "Fender Deluxe Reverb"),
        amp("BluesJrTweed", "Blues Combo", .crunch, "Small blues combo, mid-focused", "Fender Blues Junior"),
        amp("Bogner", "Boutique Lead", .highGain, "Singing lead channel with depth", "Bogner Ecstasy 101"),
        amp("OrangeAD30", "Brit 30 Drive", .highGain, "British drive channel, raw and thick", "Orange AD30"),
        amp("AmericanHighGain", "US Lead", .highGain, "American high gain with punch", "Mesa/Boogie"),
        amp("SLO100", "Super Lead", .highGain, "Fluid, creamy lead", "Soldano SLO-100"),
        amp("YJM100", "Shred 100", .highGain, "British lead for fast lines", "Marshall YJM100"),
        amp("Rectifier", "Rectified", .metal, "Deep, wide modern metal tone", "Mesa/Boogie Rectifier"),
        amp("EVH", "Brown Lead", .metal, "Hot, warm hard rock tone", "EVH 5150 III"),
        amp("6505Plus", "Thrash Head", .metal, "Aggressive metal channel", "Peavey 6505+"),
        amp("SwitchAxeLead", "Switch Lead", .metal, "Mid-focused 80s lead", "Hughes & Kettner Switchblade"),
        amp("Invader", "Rock Verb", .metal, "British rock with full bass", "Orange Rockerverb 50"),
        amp("BE101", "Modern Brit", .metal, "Modern British high gain, tight", "Friedman BE-100"),
        amp("Acoustic", "Pure Acoustic", .acoustic, "Neutral acoustic sound", nil),
        amp("AcousticAmpV2", "Acoustic Combo", .acoustic, "Acoustic amp with warmth", "Fishman Loudbox"),
        amp("FatAcousticV2", "Full Acoustic", .acoustic, "Full sound like a jumbo guitar", nil),
        amp("FlatAcoustic", "Flat Acoustic", .acoustic, "Flat, unobtrusive acoustic sound", nil),
        amp("GK800", "Bass 800", .bass, "Solid-state bass, present and tight", "Gallien-Krueger 800RB"),
        amp("Sunny3000", "Bass Vintage", .bass, "70s tube bass, fat", "Sunn 300T"),
        amp("W600", "Bass Studio", .bass, "Clean, modern bass", "Eden WTP600"),
        amp("Hammer500", "Bass Modern", .bass, "Modern bass with punch", "Aguilar Tone Hammer 500"),
        packAmp("JH.JTM45", "JH 45/100", "British tube crunch of the late 60s", "Marshall JTM45/100"),
        packAmp("JH.SuperLead100", "JH Super Lead", "British 100-watt rock", "Marshall Super Lead 100"),
        packAmp("JH.DualShowman", "JH Showman", "Big US clean with lots of headroom", "Fender Dual Showman"),
        packAmp("JH.Sunn100", "JH 100S", "Loud US tube amp", "Sunn 100S"),
        packAmp("JH.Bassman50Silver", "JH Bassman", "Silverface combo, open", "Fender Bassman 50"),
        packAmp("JH.SoundCity100", "JH City 100", "British 100-watt amp, raw", "Sound City One Hundred"),
    ]
}
