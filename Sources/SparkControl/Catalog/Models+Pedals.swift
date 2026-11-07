import Foundation

/// Gate, compressors and drives: the pedals in front of the amp.
extension ModelCatalog {
    static let gates: [ModelInfo] = [
        ModelInfo("bias.noisegate", .gate, name: "Noise Gate", summary: "Schneidet Rauschen in Spielpausen ab",
                  parameters: [.knob("Schwelle"), .knob("Abklingen"), .mirror], defaults: [0.2, 0.5, 1]),
    ]

    static let compressors: [ModelInfo] = [
        ModelInfo("LA2AComp", .compressor, name: "Studio-Kompressor", summary: "Optischer Studio-Kompressor, weich",
                  inspiration: "Teletronix LA-2A",
                  parameters: [.toggle("Modus", off: "Kompr.", on: "Limit"), .knob("Gain"), .knob("Reduktion")]),
        ModelInfo("BlueComp", .compressor, name: "Sustainer", summary: "Kompressor für langes Sustain",
                  inspiration: "Boss CS-3",
                  parameters: [.knob("Pegel"), .knob("Ton"), .knob("Attack"), .knob("Sustain")]),
        ModelInfo("Compressor", .compressor, name: "Kompressor", summary: "Einfacher, knackiger Kompressor",
                  inspiration: "MXR Dyna Comp", parameters: [.knob("Pegel"), .knob("Empfindlichkeit")]),
        ModelInfo("BassComp", .compressor, name: "Bass-Kompressor", summary: "Kompressor für Bass",
                  parameters: [.knob("Kompression"), .knob("Gain")]),
        ModelInfo("BBEOpticalComp", .compressor, name: "Opto-Kompressor", summary: "Optischer Kompressor, transparent",
                  inspiration: "BBE Opto Stomp",
                  parameters: [.knob("Pegel"), .knob("Kompression"), .toggle("Pad", off: "0 dB", on: "−15 dB")]),
        ModelInfo("JH.Vox846", .compressor, name: "JH Wah", summary: "Wah mit Auto-Modus", inspiration: "Vox V846",
                  isPack: true,
                  parameters: [.selector("Form", [("1", 0), ("2", 0.2), ("3", 0.4), ("4", 0.6), ("5", 0.8),
                                                  ("Auto", 1)]),
                               .bpm, .knob("Zeit"),
                               .selector("Note", [("1/8", 0), ("1/4", 0.25), ("1/2", 0.5), ("1 Takt", 0.75)]),
                               .knob("Empfindlichkeit")]),
    ]

    static let drives: [ModelInfo] = [
        ModelInfo("Booster", .drive, name: "Booster", summary: "Sauberer Lautstärke-Schub", parameters: [.knob("Gain")]),
        ModelInfo("KlonCentaurSilver", .drive, name: "Transparent Drive", summary: "Leichte, offene Verzerrung",
                  inspiration: "Klon Centaur", parameters: [.knob("Pegel"), .knob("Höhen"), .knob("Gain")]),
        ModelInfo("DistortionTS9", .drive, name: "Mid Drive", summary: "Mittiger Overdrive, der den Amp anschiebt",
                  inspiration: "Ibanez TS9",
                  parameters: [.knob("Drive"), .knob("Ton"), .knob("Pegel"), .reserved]),
        ModelInfo("Overdrive", .drive, name: "Overdrive", summary: "Klassischer Overdrive",
                  parameters: [.knob("Pegel"), .knob("Ton"), .knob("Drive")]),
        ModelInfo("Fuzz", .drive, name: "Germanium Fuzz", summary: "Runder, alter Fuzz", inspiration: "Fuzz Face",
                  parameters: [.knob("Pegel"), .knob("Fuzz")]),
        ModelInfo("ProCoRat", .drive, name: "Filter Distortion", summary: "Harte Verzerrung mit Filter",
                  inspiration: "ProCo RAT", parameters: [.knob("Distortion"), .knob("Filter"), .knob("Pegel")]),
        ModelInfo("BassBigMuff", .drive, name: "Bass Sustain Fuzz", summary: "Dichter Fuzz für Bass",
                  inspiration: "Electro-Harmonix Bass Big Muff",
                  parameters: [.knob("Pegel"), .knob("Ton"), .knob("Sustain")]),
        ModelInfo("GuitarMuff", .drive, name: "Sustain Fuzz", summary: "Dichter, singender Fuzz",
                  inspiration: "Electro-Harmonix Big Muff",
                  parameters: [.knob("Pegel"), .knob("Ton"), .knob("Sustain")]),
        ModelInfo("MaestroBassmaster", .drive, name: "Brass Bass", summary: "Bass-Fuzz mit Bläser-Charakter",
                  inspiration: "Maestro Bass Brassmaster",
                  parameters: [.knob("Brass"), .knob("Empfindlichkeit"), .knob("Bass")]),
        ModelInfo("SABdriver", .drive, name: "Amp-in-a-Box", summary: "Verzerrer wie ein kleiner Amp",
                  parameters: [.knob("Pegel"), .knob("Ton"), .knob("Drive"), .toggle("Filter", off: "LP", on: "HP")]),
        ModelInfo("JH.AxisFuzz", .drive, name: "JH Axis Fuzz", summary: "Fuzz der späten 60er",
                  inspiration: "Roger Mayer Axis Fuzz", isPack: true, parameters: [.knob("Pegel"), .knob("Drive")]),
        ModelInfo("JH.SupaFuzz", .drive, name: "JH Super Fuzz", summary: "Breiter Fuzz mit Filter",
                  inspiration: "Univox Super-Fuzz", isPack: true, parameters: [.knob("Pegel"), .knob("Filter")]),
        ModelInfo("JH.Octavia", .drive, name: "JH Octave Fuzz", summary: "Fuzz mit Oktave darüber",
                  inspiration: "Roger Mayer Octavia", isPack: true, parameters: [.knob("Pegel"), .knob("Fuzz")]),
        ModelInfo("JH.FuzzTone", .drive, name: "JH Fuzz Tone", summary: "Früher, kratziger Fuzz",
                  inspiration: "Maestro Fuzz-Tone", isPack: true, parameters: [.knob("Pegel"), .knob("Attack")]),
    ]
}
