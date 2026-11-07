import Foundation

/// Modulation, delay and reverb: the effects behind the amp.
extension ModelCatalog {
    static let modulations: [ModelInfo] = [
        ModelInfo("Tremolo", .modulation, name: "Tremolo", summary: "Lautstärke pulsiert wie im alten Combo",
                  parameters: [.knob("Tempo"), .knob("Tiefe"), .knob("Pegel")]),
        ModelInfo("ChorusAnalog", .modulation, name: "Chorus", summary: "Schwebender, breiter Klang",
                  parameters: [.knob("Effekt"), .knob("Rate"), .knob("Tiefe"), .knob("Ton")]),
        ModelInfo("Flanger", .modulation, name: "Flanger", summary: "Düsenartiges Rauschen",
                  parameters: [.knob("Rate"), .knob("Mix"), .knob("Tiefe")]),
        ModelInfo("Phaser", .modulation, name: "Phaser", summary: "Kreisende Phasen", inspiration: "MXR Phase 90",
                  parameters: [.knob("Tempo"), .knob("Intensität"), .reserved, .reserved]),
        ModelInfo("Vibrato01", .modulation, name: "Vibrato", summary: "Tonhöhe schwankt leicht",
                  parameters: [.knob("Tempo"), .knob("Tiefe")]),
        ModelInfo("UniVibe", .modulation, name: "Rotary Vibe", summary: "Pulsierender Vibe der späten 60er",
                  inspiration: "Shin-ei Uni-Vibe",
                  parameters: [.knob("Tempo"), .toggle("Modus", off: "Vibrato", on: "Chorus"), .knob("Intensität")]),
        ModelInfo("Cloner", .modulation, name: "Clone Chorus", summary: "Einfacher, dichter Chorus",
                  inspiration: "Electro-Harmonix Small Clone",
                  parameters: [.knob("Rate"), .toggle("Tiefe", off: "Wenig", on: "Viel")]),
        ModelInfo("MiniVibe", .modulation, name: "Mini Vibe", summary: "Kompakter Vibe", inspiration: "Voodoo Lab Micro Vibe",
                  parameters: [.knob("Tempo"), .knob("Intensität")]),
        ModelInfo("Tremolator", .modulation, name: "Sync Tremolo", summary: "Tremolo, auf Wunsch im Tempo des Presets",
                  parameters: [.knob("Tiefe"), .knob("Tempo"), .bpm]),
        ModelInfo("TremoloSquare", .modulation, name: "Square Tremolo", summary: "Hartes, zerhacktes Tremolo",
                  parameters: [.knob("Tempo"), .knob("Tiefe"), .knob("Pegel")]),
        ModelInfo("GuitarEQ6", .modulation, name: "Gitarren-EQ", summary: "Grafischer EQ mit sechs Bändern",
                  parameters: [.knob("Pegel"), .knob("100 Hz"), .knob("200 Hz"), .knob("400 Hz"), .knob("800 Hz"),
                               .knob("1,6 kHz"), .knob("3,2 kHz")]),
        ModelInfo("BassEQ6", .modulation, name: "Bass-EQ", summary: "Grafischer EQ für Bass mit sechs Bändern",
                  parameters: [.knob("Pegel"), .knob("50 Hz"), .knob("120 Hz"), .knob("400 Hz"), .knob("800 Hz"),
                               .knob("4,5 kHz"), .knob("10 kHz")]),
        ModelInfo("JH.VoodooVibeJr", .modulation, name: "JH Vibe", summary: "Vibe mit Chorus-Mischung",
                  inspiration: "Roger Mayer Voodoo-Vibe", isPack: true,
                  parameters: [.knob("Tempo"), .knob("Sweep"), .knob("Intensität"), .knob("Mix")]),
    ]

    static let delays: [ModelInfo] = [
        ModelInfo("DelayMono", .delay, name: "Digital Delay", summary: "Sauberes digitales Echo", inspiration: "Boss DD-3",
                  parameters: [.knob("Effekt"), .knob("Feedback"), .knob("Zeit"),
                               .selector("Bereich", [("50 ms", 0.3), ("200 ms", 0.4), ("500 ms", 0.6), ("1 s", 0.72)]),
                               .bpm]),
        ModelInfo("DelayEchoFilt", .delay, name: "Filter Echo", summary: "Echo mit Klangfilter",
                  parameters: [.knob("Zeit"), .knob("Feedback"), .knob("Pegel"), .knob("Ton"), .bpm]),
        ModelInfo("VintageDelay", .delay, name: "Analog Delay", summary: "Warmes, dunkles Eimerketten-Echo",
                  parameters: [.knob("Zeit"), .knob("Intensität"), .knob("Echo"), .bpm]),
        ModelInfo("DelayReverse", .delay, name: "Reverse Delay", summary: "Rückwärts laufendes Echo",
                  parameters: [.knob("Mix"), .knob("Abklingen"), .knob("Filter"), .knob("Zeit"), .bpm]),
        ModelInfo("DelayMultiHead", .delay, name: "Multi Head", summary: "Bandecho mit mehreren Köpfen",
                  parameters: [.knob("Zeit"), .knob("Intensität"), .knob("Echo"),
                               .selector("Köpfe", [("1", 0), ("2", 0.35), ("3", 0.65), ("4", 0.95)]), .bpm]),
        ModelInfo("DelayRe201", .delay, name: "Tape Echo", summary: "Bandecho mit Leiern", inspiration: "Roland RE-201",
                  parameters: [.knob("Sustain"), .knob("Pegel"), .knob("Ton"), .knob("Zeit"), .bpm]),
    ]

    /// One model for every kind of reverb. The type is parameter 6, in steps of 0.1.
    static let reverbTypes: [(String, Float)] = [
        ("Raum A", 0), ("Raum B", 0.1), ("Kammer", 0.2), ("Saal natürlich", 0.3), ("Saal mittel", 0.4),
        ("Saal weit", 0.5), ("Platte kurz", 0.6), ("Platte satt", 0.7), ("Platte lang", 0.8),
    ]

    static let reverbs: [ModelInfo] = [
        ModelInfo("bias.reverb", .reverb, name: "Hall", summary: "Raum, Kammer, Saal oder Platte",
                  parameters: [.knob("Pegel"), .knob("Dämpfung"), .knob("Low Cut"), .knob("High Cut"),
                               .knob("Dichte"), .knob("Länge"), .selector("Typ", reverbTypes), .mirror],
                  defaults: [0.3, 0.4, 0.4, 0.5, 0.4, 0.5, 0.3, 1]),
    ]
}
