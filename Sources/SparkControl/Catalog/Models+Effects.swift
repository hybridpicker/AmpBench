import Foundation

/// Modulation, delay and reverb: the effects behind the amp.
extension ModelCatalog {
    static let modulations: [ModelInfo] = [
        ModelInfo("Tremolo", .modulation, name: "Tremolo", summary: "Volume pulses as in an old combo",
                  parameters: [.knob("Speed"), .knob("Depth"), .knob("Level")]),
        ModelInfo("ChorusAnalog", .modulation, name: "Chorus", summary: "Shimmering, wide sound",
                  parameters: [.knob("Effect"), .knob("Rate"), .knob("Depth"), .knob("Tone")]),
        ModelInfo("Flanger", .modulation, name: "Flanger", summary: "Jet-like whoosh",
                  parameters: [.knob("Rate"), .knob("Mix"), .knob("Depth")]),
        ModelInfo("Phaser", .modulation, name: "Phaser", summary: "Swirling phases", inspiration: "MXR Phase 90",
                  parameters: [.knob("Speed"), .knob("Intensity"), .reserved, .reserved]),
        ModelInfo("Vibrato01", .modulation, name: "Vibrato", summary: "Pitch wavers slightly",
                  parameters: [.knob("Speed"), .knob("Depth")]),
        ModelInfo("UniVibe", .modulation, name: "Rotary Vibe", summary: "Pulsing vibe of the late 60s",
                  inspiration: "Shin-ei Uni-Vibe",
                  parameters: [.knob("Speed"), .toggle("Mode", off: "Vibrato", on: "Chorus"), .knob("Intensity")]),
        ModelInfo("Cloner", .modulation, name: "Clone Chorus", summary: "Simple, thick chorus",
                  inspiration: "Electro-Harmonix Small Clone",
                  parameters: [.knob("Rate"), .toggle("Depth", off: "Low", on: "High")]),
        ModelInfo("MiniVibe", .modulation, name: "Mini Vibe", summary: "Compact vibe", inspiration: "Voodoo Lab Micro Vibe",
                  parameters: [.knob("Speed"), .knob("Intensity")]),
        ModelInfo("Tremolator", .modulation, name: "Sync Tremolo", summary: "Tremolo, in the preset's tempo if you like",
                  parameters: [.knob("Depth"), .knob("Speed"), .bpm]),
        ModelInfo("TremoloSquare", .modulation, name: "Square Tremolo", summary: "Hard, choppy tremolo",
                  parameters: [.knob("Speed"), .knob("Depth"), .knob("Level")]),
        ModelInfo("GuitarEQ6", .modulation, name: "Guitar EQ", summary: "Graphic EQ with six bands",
                  parameters: [.knob("Level"), .knob("100 Hz"), .knob("200 Hz"), .knob("400 Hz"), .knob("800 Hz"),
                               .knob("1.6 kHz"), .knob("3.2 kHz")]),
        ModelInfo("BassEQ6", .modulation, name: "Bass EQ", summary: "Graphic EQ for bass with six bands",
                  parameters: [.knob("Level"), .knob("50 Hz"), .knob("120 Hz"), .knob("400 Hz"), .knob("800 Hz"),
                               .knob("4.5 kHz"), .knob("10 kHz")]),
        ModelInfo("JH.VoodooVibeJr", .modulation, name: "JH Vibe", summary: "Vibe with a chorus blend",
                  inspiration: "Roger Mayer Voodoo-Vibe", isPack: true,
                  parameters: [.knob("Speed"), .knob("Sweep"), .knob("Intensity"), .knob("Mix")]),
    ]

    static let delays: [ModelInfo] = [
        ModelInfo("DelayMono", .delay, name: "Digital Delay", summary: "Clean digital echo", inspiration: "Boss DD-3",
                  parameters: [.knob("Effect"), .knob("Feedback"), .knob("Time"),
                               .selector("Range", [("50 ms", 0.3), ("200 ms", 0.4), ("500 ms", 0.6), ("1 s", 0.72)]),
                               .bpm]),
        ModelInfo("DelayEchoFilt", .delay, name: "Filter Echo", summary: "Echo with a tone filter",
                  parameters: [.knob("Time"), .knob("Feedback"), .knob("Level"), .knob("Tone"), .bpm]),
        ModelInfo("VintageDelay", .delay, name: "Analog Delay", summary: "Warm, dark bucket-brigade echo",
                  parameters: [.knob("Time"), .knob("Intensity"), .knob("Echo"), .bpm]),
        ModelInfo("DelayReverse", .delay, name: "Reverse Delay", summary: "Echo that runs backwards",
                  parameters: [.knob("Mix"), .knob("Decay"), .knob("Filter"), .knob("Time"), .bpm]),
        ModelInfo("DelayMultiHead", .delay, name: "Multi Head", summary: "Tape echo with several heads",
                  parameters: [.knob("Time"), .knob("Intensity"), .knob("Echo"),
                               .selector("Heads", [("1", 0), ("2", 0.35), ("3", 0.65), ("4", 0.95)]), .bpm]),
        ModelInfo("DelayRe201", .delay, name: "Tape Echo", summary: "Tape echo with wow and flutter", inspiration: "Roland RE-201",
                  parameters: [.knob("Sustain"), .knob("Level"), .knob("Tone"), .knob("Time"), .bpm]),
    ]

    /// One model for every kind of reverb. The type is parameter 6, in steps of 0.1.
    static let reverbTypes: [(String, Float)] = [
        ("Room A", 0), ("Room B", 0.1), ("Chamber", 0.2), ("Natural hall", 0.3), ("Medium hall", 0.4),
        ("Wide hall", 0.5), ("Short plate", 0.6), ("Rich plate", 0.7), ("Long plate", 0.8),
    ]

    static let reverbs: [ModelInfo] = [
        ModelInfo("bias.reverb", .reverb, name: "Reverb", summary: "Room, chamber, hall or plate",
                  parameters: [.knob("Level"), .knob("Damping"), .knob("Low Cut"), .knob("High Cut"),
                               .knob("Density"), .knob("Length"), .selector("Type", reverbTypes), .mirror],
                  defaults: [0.3, 0.4, 0.4, 0.5, 0.4, 0.5, 0.3, 1]),
    ]
}
