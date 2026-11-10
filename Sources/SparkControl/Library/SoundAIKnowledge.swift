import Foundation

/// What the assistant should know beyond the catalog: typical signal chains of well-known players and genres, how a
/// song's tempo becomes a delay time, and a few complete, valid recipes to copy the form from.
///
/// Every model id here must be in the catalog; `SoundAITests` checks that, and that every example reads.
extension SoundAI {

    /// A player, band or genre and the chain that gets close to it on a Spark. Starting points, not gospel.
    public struct Archetype: Sendable, Equatable {
        public let topic: String
        /// The catalog ids, in chain order.
        public let models: [String]
        public let advice: String
    }

    public static let archetypes: [Archetype] = [
        .init(topic: "The Edge (U2)", models: ["Compressor", "AC Boost", "DelayMono", "bias.reverb"],
              advice: "gain 3–4, treble 6–7; echo as dotted eighths (bpm = song tempo × 4/3), effect 4–5, feedback 3–4; little reverb."),
        .init(topic: "David Gilmour (Pink Floyd), lead", models: ["GuitarMuff", "Twin", "DelayMono", "bias.reverb"],
              advice: "amp with headroom (gain 3–4), Muff sustain 6–7, tone 4–5; echo around 400–500 ms as eighths (bpm = song tempo × 2); Medium hall or Wide hall, level 3–4."),
        .init(topic: "Jimi Hendrix", models: ["Fuzz", "Plexi", "UniVibe", "bias.reverb"],
              advice: "Plexi gain 5–6, Fuzz fuzz 6–8 (the guitar's volume knob cleans it up); UniVibe speed 3–5; hardly any reverb (Room A)."),
        .init(topic: "Stevie Ray Vaughan, Texas blues", models: ["DistortionTS9", "Twin", "bias.reverb"],
              advice: "amp just before breakup (Twin gain 5–6 or Bassman gain 5), DistortionTS9 drive 1–3, level 7–8; Room B, level 2–3; no delay."),
        .init(topic: "John Mayer", models: ["KlonCentaurSilver", "TwoStoneSP50", "bias.reverb"],
              advice: "glassy clean (gain 4–5, middle 5–6), KlonCentaurSilver gain 3–4 for leads; Short plate or a room; delay quiet at most."),
        .init(topic: "Eddie Van Halen", models: ["EVH", "Phaser", "DelayMono", "bias.reverb"],
              advice: "“brown sound”: EVH gain 6–7 or Plexi gain 7–8, middle 6; Phaser speed 2–3 (Eruption) or Flanger (Unchained); short, quiet echo."),
        .init(topic: "AC/DC", models: ["Plexi", "bias.reverb"],
              advice: "no drive pedal, the distortion comes from the amp: Plexi gain 5–6 (rhythm) to 7 (lead), middle 6–7, bass 4; Room A, level 1.5–2; no delay, no gate."),
        .init(topic: "Slash (Guns N' Roses)", models: ["DistortionTS9", "Plexi", "DelayMono", "bias.reverb"],
              advice: "Plexi gain 7–8 or YJM100, DistortionTS9 drive 1–2 as a push, middle 7; lead echo 350–450 ms, effect 2–3; a room."),
        .init(topic: "Metallica, thrash rhythm", models: ["bias.noisegate", "DistortionTS9", "Rectifier", "bias.reverb"],
              advice: "Rectifier or AmericanHighGain gain 6–7, middle 3–4, bass 6; DistortionTS9 drive 0–1, level 8 to tighten; gate threshold 4; reverb off or minimal."),
        .init(topic: "Modern metal, djent", models: ["bias.noisegate", "DistortionTS9", "6505Plus"],
              advice: "6505Plus or BE101 gain 5–6.5 (not higher), DistortionTS9 drive 0, level 8; gate 4–5; no reverb and no delay for rhythm."),
        .init(topic: "Funk (Nile Rodgers)", models: ["Compressor", "RolandJC120", "bias.reverb"],
              advice: "Compressor sensitivity 5–6; RolandJC120 or Twin gain 2–3, treble 7, middle 6; no delay, reverb level below 1.5."),
        .init(topic: "Mark Knopfler (Dire Straits)", models: ["Compressor", "Deluxe65", "bias.reverb"],
              advice: "clean and mid-focused (gain 4, treble 6, middle 6), light compressor; a room or Natural hall. “Money for Nothing”: Plexi gain 6, middle 8, treble 3."),
        .init(topic: "The Police, 80s clean with chorus", models: ["RolandJC120", "ChorusAnalog", "DelayMono", "bias.reverb"],
              advice: "RolandJC120 gain 2–3, ChorusAnalog effect 5, rate 3; echo as eighths (bpm = song tempo × 2), effect 3, feedback 3–4."),
        .init(topic: "Nirvana, grunge", models: ["ProCoRat", "AmericanHighGain", "Cloner", "bias.reverb"],
              advice: "chorus of the song: ProCoRat distortion 6–7 into a lightly driven amp (AmericanHighGain gain 4 or Twin gain 5); verse clean with Cloner (Come as You Are); a room."),
        .init(topic: "Garage rock (The White Stripes, The Black Keys)", models: ["GuitarMuff", "Checkmate", "bias.reverb"],
              advice: "fuzz (GuitarMuff sustain 7–9 or Fuzz) into a small combo (Checkmate or BluesJrTweed gain 5–6); a room, no delay."),
        .init(topic: "Surf (Dick Dale, The Ventures)", models: ["Twin", "Tremolo", "bias.reverb"],
              advice: "Twin gain 3, treble 7; wet reverb instead of a spring: Rich plate, level 5–6, length 5–6; Tremolo speed 4–6."),
        .init(topic: "Country, chicken picking", models: ["Compressor", "Twin", "DelayMono", "bias.reverb"],
              advice: "Twin or Deluxe65 gain 3, treble 7; Compressor; slapback with DelayMono: sync Free, range “200 ms”, time 4–5, feedback 0–1, effect 3; a room."),
        .init(topic: "Jazz", models: ["RolandJC120", "bias.reverb"],
              advice: "RolandJC120 or Twin gain 2–3, treble 3–4, middle 5, bass 6; a room, level 2; no other effects."),
        .init(topic: "Santana", models: ["DistortionTS9", "ODS50CN", "DelayMono", "bias.reverb"],
              advice: "singing sustain: ODS50CN or Bogner gain 6–7, middle 7, DistortionTS9 drive 2; quiet echo; Medium hall."),
        .init(topic: "Queen (Brian May)", models: ["Booster", "AC Boost", "DelayMono", "bias.reverb"],
              advice: "Booster gain 7–9 into AC Boost (gain 6–7, treble 6, middle 7); echo as quarters or eighths, feedback 3–4; a hall."),
        .init(topic: "Blues rock (Gary Moore, Joe Bonamassa)", models: ["DistortionTS9", "Plexi", "DelayMono", "bias.reverb"],
              advice: "Plexi or OverDrivenJM45 gain 6–7, DistortionTS9 drive 2–3, level 7; quiet lead echo; Natural hall."),
        .init(topic: "Red Hot Chili Peppers (John Frusciante)", models: ["Plexi", "bias.reverb"],
              advice: "funk rhythm almost clean through Plexi gain 3–4; solo with GuitarMuff or DistortionTS9 in front; a room, hardly any delay."),
        .init(topic: "Britpop (Oasis)", models: ["Overdrive", "OrangeAD30", "Phaser", "bias.reverb"],
              advice: "OrangeAD30 or Plexi gain 6–7, Overdrive drive 3; Phaser speed 2, intensity 4; a room."),
        .init(topic: "Shoegaze, post-rock, ambient", models: ["GuitarMuff", "Twin", "DelayRe201", "bias.reverb"],
              advice: "Muff or clean; DelayRe201 sustain 5–6, level 4; Wide hall, length 8–9, level 5; DelayReverse for swells."),
    ]

    /// A complete recipe in the exact form the assistant must answer in, with the wish it answers.
    public struct Example: Sendable, Equatable {
        public let request: String
        public let recipe: String
    }

    public static let examples: [Example] = [
        .init(request: "U2 – Where the Streets Have No Name", recipe: """
        {"format":"spark-sound-recipe","version":1,"name":"Streets Echo","description":"Shimmering British clean with a dotted-eighth echo","bpm":168,"tags":["U2","Clean","Delay"],"notes":"The song runs at about 126 BPM; bpm is 168 (126 × 4/3) so that the synced echo comes as dotted eighths. Set delay.effect by ear first, then amp.treble.","chain":{"compressor":{"model":"Compressor","settings":{"level":6,"sensitivity":4}},"amp":{"model":"AC Boost","settings":{"gain":3.5,"treble":6.5,"middle":5,"bass":4.5,"master":7}},"delay":{"model":"DelayMono","settings":{"effect":4.5,"feedback":3.5,"sync":true}},"reverb":{"model":"bias.reverb","settings":{"level":2,"length":5,"type":"Natural hall"}}}}
        """),
        .init(request: "AC/DC – Back in Black", recipe: """
        {"format":"spark-sound-recipe","version":1,"name":"Black Crunch","description":"Dry Plexi crunch without pedals","bpm":94,"tags":["AC/DC","Rock","Crunch"],"notes":"The distortion comes from the amp alone. Too much drive: amp.gain to 5; too thin: amp.middle up.","chain":{"amp":{"model":"Plexi","settings":{"gain":6,"treble":6,"middle":7,"bass":4,"master":7}},"reverb":{"model":"bias.reverb","settings":{"level":1.5,"length":3.5,"type":"Room A"}}}}
        """),
        .init(request: "Pink Floyd – Comfortably Numb, solo", recipe: """
        {"format":"spark-sound-recipe","version":1,"name":"Numb Solo","description":"Singing fuzz lead with echo and a big hall","bpm":128,"tags":["Pink Floyd","Lead","Fuzz"],"notes":"The song runs at about 64 BPM; bpm is 128 so that the echo comes as eighths (about 470 ms). Too muddy: drive.tone up; too wet: reverb.level down.","chain":{"compressor":{"model":"BlueComp","settings":{"level":5,"sustain":5}},"drive":{"model":"GuitarMuff","settings":{"sustain":6.5,"tone":4.5,"level":6}},"amp":{"model":"Twin","settings":{"gain":3.5,"treble":5.5,"middle":6,"bass":5,"master":7}},"delay":{"model":"DelayMono","settings":{"effect":3.5,"feedback":3.5,"sync":true}},"reverb":{"model":"bias.reverb","settings":{"level":3.5,"length":7,"type":"Medium hall"}}}}
        """),
    ]

    static var archetypeText: String {
        archetypes.map { "- \($0.topic): \($0.models.joined(separator: " → ")) · \($0.advice)" }
            .joined(separator: "\n")
    }

    static var examplesText: String {
        examples.map { "Wish: “\($0.request)”\n\($0.recipe)" }.joined(separator: "\n\n")
    }

    static let tempoText = """
    - With sync = BPM the echo comes as a quarter note of "bpm" (60000 / bpm milliseconds). A sync tremolo follows the same bpm.
    - For other note values you change "bpm": quarters → song tempo; dotted eighths (The Edge) → song tempo × 4/3; eighths → song tempo × 2. Stay between 40 and 250. Name the real song tempo in "notes".
    - Without a song: rhythm echo 300–400 ms, lead 400–500 ms, ambient 500–700 ms (bpm = 60000 / ms).
    - Slapback (rockabilly, country): DelayMono with sync Free, range “200 ms”, time 4–5, feedback 0–1.
    """

    static let reverbText = """
    - Rock, blues, crunch: Room A, Room B or Chamber, level 1.5–2.5.
    - Ballad, singing leads: Natural hall or Medium hall, level 3–4.
    - Clean, pop, funk: Short plate, level 2–3 (funk below 1.5).
    - Surf: Rich plate, level 5–6 (instead of a spring reverb).
    - Ambient, post-rock: Wide hall, length 8–9, level 4–5.
    - Metal rhythm: off, or Room A with level below 1.
    """
}
