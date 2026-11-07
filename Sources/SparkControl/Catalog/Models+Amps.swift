import Foundation

extension ModelCatalog {
    /// Every amp has the same five parameters, in this order.
    static let ampKnobs: [ParameterInfo] = [.knob("Gain"), .knob("Höhen"), .knob("Mitten"), .knob("Bässe"), .knob("Master")]
    static let packAmpKnobs: [ParameterInfo] = [.knob("Gain"), .knob("Höhen"), .knob("Mitten"), .knob("Bässe"),
                                                .knob("Lautstärke")]

    private static func amp(_ id: String, _ name: String, _ group: ModelInfo.Group, _ summary: String,
                            _ inspiration: String?) -> ModelInfo {
        ModelInfo(id, .amp, name: name, summary: summary, inspiration: inspiration, group: group, parameters: ampKnobs)
    }

    private static func packAmp(_ id: String, _ name: String, _ summary: String, _ inspiration: String) -> ModelInfo {
        ModelInfo(id, .amp, name: name, summary: summary, inspiration: inspiration, group: .crunch, isPack: true,
                  parameters: packAmpKnobs)
    }

    static let amps: [ModelInfo] = [
        amp("RolandJC120", "Solid Clean", .clean, "Transistor-Clean, glasklar und trocken", "Roland JC-120"),
        amp("Twin", "US Clean", .clean, "Großer Clean-Combo mit viel Headroom", "Fender Twin Reverb"),
        amp("ADClean", "Brit Clean", .clean, "Britischer Clean-Kanal, warm und rund", "Orange AD30, Clean"),
        amp("94MatchDCV2", "Boutique Clean", .clean, "Class-A-Clean mit Biss", "Matchless DC-30"),
        amp("ODS50CN", "Silk Clean", .clean, "Seidiger Clean-Ton, der weich anzerrt", "Dumble ODS 50"),
        amp("Bassman", "Tweed 4×10", .bright, "Tweed-Combo, knackig und offen", "Fender Bassman ’59"),
        amp("AC Boost", "Brit Chime", .bright, "Glockiger Class-A-Ton", "Vox AC30 Top Boost"),
        amp("Checkmate", "Vintage Combo", .bright, "Kleiner Röhren-Combo aus den 60ern", "Teisco Checkmate 20"),
        amp("TwoStoneSP50", "Studio Glass", .bright, "Moderner Boutique-Ton, sehr klar", "Two-Rock Studio Pro 50"),
        amp("Deluxe65", "US Deluxe", .crunch, "Kleiner US-Combo, der früh bricht", "Fender Deluxe"),
        amp("Plexi", "Plexi Crunch", .crunch, "Klassischer britischer Rock-Crunch", "Marshall Super Lead ’Plexi’"),
        amp("OverDrivenJM45", "Brit 45", .crunch, "Früher britischer Röhren-Crunch", "Marshall JTM45"),
        amp("OverDrivenLuxVerb", "US Crunch", .crunch, "Aufgerissener US-Combo", "Fender Deluxe Reverb"),
        amp("BluesJrTweed", "Blues Combo", .crunch, "Kleiner Blues-Combo, mittig", "Fender Blues Junior"),
        amp("Bogner", "Boutique Lead", .highGain, "Singender Lead-Kanal mit Tiefe", "Bogner Ecstasy 101"),
        amp("OrangeAD30", "Brit 30 Drive", .highGain, "Britischer Zerrkanal, rau und dicht", "Orange AD30"),
        amp("AmericanHighGain", "US Lead", .highGain, "Amerikanischer High Gain mit Druck", "Mesa/Boogie"),
        amp("SLO100", "Super Lead", .highGain, "Flüssiger, cremiger Lead", "Soldano SLO-100"),
        amp("YJM100", "Shred 100", .highGain, "Britischer Lead für schnelle Linien", "Marshall YJM100"),
        amp("Rectifier", "Rectified", .metal, "Tiefer, breiter Modern-Metal-Ton", "Mesa/Boogie Rectifier"),
        amp("EVH", "Brown Lead", .metal, "Heißer, warmer Hard-Rock-Ton", "EVH 5150 III"),
        amp("6505Plus", "Thrash Head", .metal, "Aggressiver Metal-Kanal", "Peavey 6505+"),
        amp("SwitchAxeLead", "Switch Lead", .metal, "Mittiger 80er-Lead", "Hughes & Kettner Switchblade"),
        amp("Invader", "Rock Verb", .metal, "Britischer Rock mit vollen Bässen", "Orange Rockerverb 50"),
        amp("BE101", "Modern Brit", .metal, "Moderner britischer High Gain, straff", "Friedman BE-100"),
        amp("Acoustic", "Akustik pur", .acoustic, "Neutraler Akustik-Klang", nil),
        amp("AcousticAmpV2", "Akustik-Combo", .acoustic, "Akustik-Verstärker mit Wärme", "Fishman Loudbox"),
        amp("FatAcousticV2", "Akustik voll", .acoustic, "Voller Klang wie eine Jumbo-Gitarre", nil),
        amp("FlatAcoustic", "Akustik flach", .acoustic, "Flacher, unauffälliger Akustik-Klang", nil),
        amp("GK800", "Bass 800", .bass, "Transistor-Bass, präsent und straff", "Gallien-Krueger 800RB"),
        amp("Sunny3000", "Bass Vintage", .bass, "Röhren-Bass der 70er, fett", "Sunn 300T"),
        amp("W600", "Bass Studio", .bass, "Sauberer, moderner Bass", "Eden WTP600"),
        amp("Hammer500", "Bass Modern", .bass, "Moderner Bass mit Punch", "Aguilar Tone Hammer 500"),
        packAmp("JH.JTM45", "JH 45/100", "Britischer Röhren-Crunch der späten 60er", "Marshall JTM45/100"),
        packAmp("JH.SuperLead100", "JH Super Lead", "Britischer 100-Watt-Rock", "Marshall Super Lead 100"),
        packAmp("JH.DualShowman", "JH Showman", "Großer US-Clean mit viel Headroom", "Fender Dual Showman"),
        packAmp("JH.Sunn100", "JH 100S", "Lauter US-Röhren-Amp", "Sunn 100S"),
        packAmp("JH.Bassman50Silver", "JH Bassman", "Silverface-Combo, offen", "Fender Bassman 50"),
        packAmp("JH.SoundCity100", "JH City 100", "Britischer 100-Watt-Amp, rau", "Sound City One Hundred"),
    ]
}
