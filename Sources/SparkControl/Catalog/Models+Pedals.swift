import Foundation

/// Gate, compressors and drives: the pedals in front of the amp.
extension ModelCatalog {
    static let gates: [ModelInfo] = [
        ModelInfo("bias.noisegate", .gate, name: "Noise Gate", summary: "Cuts noise when you are not playing",
                  parameters: [.knob("Threshold"), .knob("Decay"), .mirror], defaults: [0.2, 0.5, 1]),
    ]

    static let compressors: [ModelInfo] = [
        ModelInfo("LA2AComp", .compressor, name: "Studio Compressor", summary: "Optical studio compressor, soft",
                  inspiration: "Teletronix LA-2A",
                  parameters: [.toggle("Mode", off: "Comp.", on: "Limit"), .knob("Gain"), .knob("Reduction")]),
        ModelInfo("BlueComp", .compressor, name: "Sustainer", summary: "Compressor for long sustain",
                  inspiration: "Boss CS-3",
                  parameters: [.knob("Level"), .knob("Tone"), .knob("Attack"), .knob("Sustain")]),
        ModelInfo("Compressor", .compressor, name: "Compressor", summary: "Simple, snappy compressor",
                  inspiration: "MXR Dyna Comp", parameters: [.knob("Level"), .knob("Sensitivity")]),
        ModelInfo("BassComp", .compressor, name: "Bass Compressor", summary: "Compressor for bass",
                  parameters: [.knob("Compression"), .knob("Gain")]),
        ModelInfo("BBEOpticalComp", .compressor, name: "Opto Compressor", summary: "Optical compressor, transparent",
                  inspiration: "BBE Opto Stomp",
                  parameters: [.knob("Level"), .knob("Compression"), .toggle("Pad", off: "0 dB", on: "−15 dB")]),
        ModelInfo("JH.Vox846", .compressor, name: "JH Wah", summary: "Wah with auto mode", inspiration: "Vox V846",
                  isPack: true,
                  parameters: [.selector("Shape", [("1", 0), ("2", 0.2), ("3", 0.4), ("4", 0.6), ("5", 0.8),
                                                  ("Auto", 1)]),
                               .bpm, .knob("Time"),
                               .selector("Note", [("1/8", 0), ("1/4", 0.25), ("1/2", 0.5), ("1 bar", 0.75)]),
                               .knob("Sensitivity")]),
    ]

    static let drives: [ModelInfo] = [
        ModelInfo("Booster", .drive, name: "Booster", summary: "Clean volume boost", parameters: [.knob("Gain")]),
        ModelInfo("KlonCentaurSilver", .drive, name: "Transparent Drive", summary: "Light, open drive",
                  inspiration: "Klon Centaur", parameters: [.knob("Level"), .knob("Treble"), .knob("Gain")]),
        ModelInfo("DistortionTS9", .drive, name: "Mid Drive", summary: "Mid-focused overdrive that pushes the amp",
                  inspiration: "Ibanez TS9",
                  parameters: [.knob("Drive"), .knob("Tone"), .knob("Level"), .reserved]),
        ModelInfo("Overdrive", .drive, name: "Overdrive", summary: "Classic overdrive",
                  parameters: [.knob("Level"), .knob("Tone"), .knob("Drive")]),
        ModelInfo("Fuzz", .drive, name: "Germanium Fuzz", summary: "Round, old fuzz", inspiration: "Fuzz Face",
                  parameters: [.knob("Level"), .knob("Fuzz")]),
        ModelInfo("ProCoRat", .drive, name: "Filter Distortion", summary: "Hard distortion with a filter",
                  inspiration: "ProCo RAT", parameters: [.knob("Distortion"), .knob("Filter"), .knob("Level")]),
        ModelInfo("BassBigMuff", .drive, name: "Bass Sustain Fuzz", summary: "Thick fuzz for bass",
                  inspiration: "Electro-Harmonix Bass Big Muff",
                  parameters: [.knob("Level"), .knob("Tone"), .knob("Sustain")]),
        ModelInfo("GuitarMuff", .drive, name: "Sustain Fuzz", summary: "Thick, singing fuzz",
                  inspiration: "Electro-Harmonix Big Muff",
                  parameters: [.knob("Level"), .knob("Tone"), .knob("Sustain")]),
        ModelInfo("MaestroBassmaster", .drive, name: "Brass Bass", summary: "Bass fuzz with a brass character",
                  inspiration: "Maestro Bass Brassmaster",
                  parameters: [.knob("Brass"), .knob("Sensitivity"), .knob("Bass")]),
        ModelInfo("SABdriver", .drive, name: "Amp-in-a-Box", summary: "Drive like a small amp",
                  parameters: [.knob("Level"), .knob("Tone"), .knob("Drive"), .toggle("Filter", off: "LP", on: "HP")]),
        ModelInfo("JH.AxisFuzz", .drive, name: "JH Axis Fuzz", summary: "Fuzz of the late 60s",
                  inspiration: "Roger Mayer Axis Fuzz", isPack: true, parameters: [.knob("Level"), .knob("Drive")]),
        ModelInfo("JH.SupaFuzz", .drive, name: "JH Super Fuzz", summary: "Wide fuzz with a filter",
                  inspiration: "Univox Super-Fuzz", isPack: true, parameters: [.knob("Level"), .knob("Filter")]),
        ModelInfo("JH.Octavia", .drive, name: "JH Octave Fuzz", summary: "Fuzz with an octave above",
                  inspiration: "Roger Mayer Octavia", isPack: true, parameters: [.knob("Level"), .knob("Fuzz")]),
        ModelInfo("JH.FuzzTone", .drive, name: "JH Fuzz Tone", summary: "Early, scratchy fuzz",
                  inspiration: "Maestro Fuzz-Tone", isPack: true, parameters: [.knob("Level"), .knob("Attack")]),
    ]
}
