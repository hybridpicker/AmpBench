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
              advice: "gain 3–4, treble 6–7; Echo als punktierte Achtel (bpm = Songtempo × 4/3), effect 4–5, feedback 3–4; wenig Hall."),
        .init(topic: "David Gilmour (Pink Floyd), Lead", models: ["GuitarMuff", "Twin", "DelayMono", "bias.reverb"],
              advice: "Amp mit Headroom (gain 3–4), Muff sustain 6–7, tone 4–5; Echo um 400–500 ms als Achtel (bpm = Songtempo × 2); Saal mittel oder weit, level 3–4."),
        .init(topic: "Jimi Hendrix", models: ["Fuzz", "Plexi", "UniVibe", "bias.reverb"],
              advice: "Plexi gain 5–6, Fuzz fuzz 6–8 (Lautstärkeregler der Gitarre räumt auf); UniVibe speed 3–5; kaum Hall (Raum A)."),
        .init(topic: "Stevie Ray Vaughan, Texas-Blues", models: ["DistortionTS9", "Twin", "bias.reverb"],
              advice: "Amp knapp vor dem Aufbrechen (Twin gain 5–6 oder Bassman gain 5), DistortionTS9 drive 1–3, level 7–8; Raum B, level 2–3; kein Delay."),
        .init(topic: "John Mayer", models: ["KlonCentaurSilver", "TwoStoneSP50", "bias.reverb"],
              advice: "glasiger Clean (gain 4–5, middle 5–6), KlonCentaurSilver gain 3–4 für Leads; Platte kurz oder Raum; Delay höchstens leise."),
        .init(topic: "Eddie Van Halen", models: ["EVH", "Phaser", "DelayMono", "bias.reverb"],
              advice: "„Brown Sound“: EVH gain 6–7 oder Plexi gain 7–8, middle 6; Phaser speed 2–3 (Eruption) oder Flanger (Unchained); kurzes, leises Echo."),
        .init(topic: "AC/DC", models: ["Plexi", "bias.reverb"],
              advice: "kein Verzerrer, die Zerre kommt vom Amp: Plexi gain 5–6 (Rhythmus) bis 7 (Lead), middle 6–7, bass 4; Raum A, level 1,5–2; kein Delay, kein Gate."),
        .init(topic: "Slash (Guns N' Roses)", models: ["DistortionTS9", "Plexi", "DelayMono", "bias.reverb"],
              advice: "Plexi gain 7–8 oder YJM100, DistortionTS9 drive 1–2 als Schub, middle 7; Lead-Echo 350–450 ms, effect 2–3; Raum."),
        .init(topic: "Metallica, Thrash-Rhythmus", models: ["bias.noisegate", "DistortionTS9", "Rectifier", "bias.reverb"],
              advice: "Rectifier oder AmericanHighGain gain 6–7, middle 3–4, bass 6; DistortionTS9 drive 0–1, level 8 zum Straffen; Gate threshold 4; Hall aus oder minimal."),
        .init(topic: "Moderner Metal, Djent", models: ["bias.noisegate", "DistortionTS9", "6505Plus"],
              advice: "6505Plus oder BE101 gain 5–6,5 (nicht höher), DistortionTS9 drive 0, level 8; Gate 4–5; im Rhythmus kein Hall und kein Delay."),
        .init(topic: "Funk (Nile Rodgers)", models: ["Compressor", "RolandJC120", "bias.reverb"],
              advice: "Compressor sensitivity 5–6; RolandJC120 oder Twin gain 2–3, treble 7, middle 6; kein Delay, Hall level unter 1,5."),
        .init(topic: "Mark Knopfler (Dire Straits)", models: ["Compressor", "Deluxe65", "bias.reverb"],
              advice: "clean und mittig (gain 4, treble 6, middle 6), Kompressor leicht; Raum oder Saal natürlich. „Money for Nothing“: Plexi gain 6, middle 8, treble 3."),
        .init(topic: "The Police, 80er-Clean mit Chorus", models: ["RolandJC120", "ChorusAnalog", "DelayMono", "bias.reverb"],
              advice: "RolandJC120 gain 2–3, ChorusAnalog effect 5, rate 3; Echo als Achtel (bpm = Songtempo × 2), effect 3, feedback 3–4."),
        .init(topic: "Nirvana, Grunge", models: ["ProCoRat", "AmericanHighGain", "Cloner", "bias.reverb"],
              advice: "Refrain: ProCoRat distortion 6–7 in einen leicht angezerrten Amp (AmericanHighGain gain 4 oder Twin gain 5); Strophe clean mit Cloner (Come as You Are); Raum."),
        .init(topic: "Garage-Rock (The White Stripes, The Black Keys)", models: ["GuitarMuff", "Checkmate", "bias.reverb"],
              advice: "Fuzz (GuitarMuff sustain 7–9 oder Fuzz) in einen kleinen Combo (Checkmate oder BluesJrTweed gain 5–6); Raum, kein Delay."),
        .init(topic: "Surf (Dick Dale, The Ventures)", models: ["Twin", "Tremolo", "bias.reverb"],
              advice: "Twin gain 3, treble 7; nasser Hall statt Federhall: Platte satt, level 5–6, length 5–6; Tremolo speed 4–6."),
        .init(topic: "Country, Chicken Picking", models: ["Compressor", "Twin", "DelayMono", "bias.reverb"],
              advice: "Twin oder Deluxe65 gain 3, treble 7; Compressor; Slapback mit DelayMono: sync Frei, range „200 ms“, time 4–5, feedback 0–1, effect 3; Raum."),
        .init(topic: "Jazz", models: ["RolandJC120", "bias.reverb"],
              advice: "RolandJC120 oder Twin gain 2–3, treble 3–4, middle 5, bass 6; Raum, level 2; sonst keine Effekte."),
        .init(topic: "Santana", models: ["DistortionTS9", "ODS50CN", "DelayMono", "bias.reverb"],
              advice: "singendes Sustain: ODS50CN oder Bogner gain 6–7, middle 7, DistortionTS9 drive 2; leises Echo; Saal mittel."),
        .init(topic: "Queen (Brian May)", models: ["Booster", "AC Boost", "DelayMono", "bias.reverb"],
              advice: "Booster gain 7–9 in AC Boost (gain 6–7, treble 6, middle 7); Echo als Viertel oder Achtel, feedback 3–4; Saal."),
        .init(topic: "Blues-Rock (Gary Moore, Joe Bonamassa)", models: ["DistortionTS9", "Plexi", "DelayMono", "bias.reverb"],
              advice: "Plexi oder OverDrivenJM45 gain 6–7, DistortionTS9 drive 2–3, level 7; leises Lead-Echo; Saal natürlich."),
        .init(topic: "Red Hot Chili Peppers (John Frusciante)", models: ["Plexi", "bias.reverb"],
              advice: "Funk-Rhythmus fast clean über Plexi gain 3–4; Solo mit GuitarMuff oder DistortionTS9 davor; Raum, kaum Delay."),
        .init(topic: "Britpop (Oasis)", models: ["Overdrive", "OrangeAD30", "Phaser", "bias.reverb"],
              advice: "OrangeAD30 oder Plexi gain 6–7, Overdrive drive 3; Phaser speed 2, intensity 4; Raum."),
        .init(topic: "Shoegaze, Post-Rock, Ambient", models: ["GuitarMuff", "Twin", "DelayRe201", "bias.reverb"],
              advice: "Muff oder clean; DelayRe201 sustain 5–6, level 4; Saal weit, length 8–9, level 5; für Schwellklänge DelayReverse."),
    ]

    /// A complete recipe in the exact form the assistant must answer in, with the wish it answers.
    public struct Example: Sendable, Equatable {
        public let request: String
        public let recipe: String
    }

    public static let examples: [Example] = [
        .init(request: "U2 – Where the Streets Have No Name", recipe: """
        {"format":"spark-sound-recipe","version":1,"name":"Streets Echo","description":"Glänzender britischer Clean-Sound mit punktiertem Achtel-Echo","bpm":168,"tags":["U2","Clean","Delay"],"notes":"Der Song läuft mit etwa 126 BPM; bpm steht auf 168 (126 × 4/3), damit das synchrone Echo als punktierte Achtel kommt. Zuerst delay.effect nach Gehör, dann amp.treble.","chain":{"compressor":{"model":"Compressor","settings":{"level":6,"sensitivity":4}},"amp":{"model":"AC Boost","settings":{"gain":3.5,"treble":6.5,"middle":5,"bass":4.5,"master":7}},"delay":{"model":"DelayMono","settings":{"effect":4.5,"feedback":3.5,"sync":true}},"reverb":{"model":"bias.reverb","settings":{"level":2,"length":5,"type":"Saal natürlich"}}}}
        """),
        .init(request: "AC/DC – Back in Black", recipe: """
        {"format":"spark-sound-recipe","version":1,"name":"Black Crunch","description":"Trockener Plexi-Crunch ohne Pedale","bpm":94,"tags":["AC/DC","Rock","Crunch"],"notes":"Die Verzerrung kommt nur vom Amp. Zu viel Zerre: amp.gain auf 5; zu dünn: amp.middle rauf.","chain":{"amp":{"model":"Plexi","settings":{"gain":6,"treble":6,"middle":7,"bass":4,"master":7}},"reverb":{"model":"bias.reverb","settings":{"level":1.5,"length":3.5,"type":"Raum A"}}}}
        """),
        .init(request: "Pink Floyd – Comfortably Numb, Solo", recipe: """
        {"format":"spark-sound-recipe","version":1,"name":"Numb Solo","description":"Singender Fuzz-Lead mit Echo und großem Saal","bpm":128,"tags":["Pink Floyd","Lead","Fuzz"],"notes":"Der Song läuft mit etwa 64 BPM; bpm steht auf 128, damit das Echo als Achtel (rund 470 ms) kommt. Zu matschig: drive.tone rauf; zu nass: reverb.level runter.","chain":{"compressor":{"model":"BlueComp","settings":{"level":5,"sustain":5}},"drive":{"model":"GuitarMuff","settings":{"sustain":6.5,"tone":4.5,"level":6}},"amp":{"model":"Twin","settings":{"gain":3.5,"treble":5.5,"middle":6,"bass":5,"master":7}},"delay":{"model":"DelayMono","settings":{"effect":3.5,"feedback":3.5,"sync":true}},"reverb":{"model":"bias.reverb","settings":{"level":3.5,"length":7,"type":"Saal mittel"}}}}
        """),
    ]

    static var archetypeText: String {
        archetypes.map { "- \($0.topic): \($0.models.joined(separator: " → ")) · \($0.advice)" }
            .joined(separator: "\n")
    }

    static var examplesText: String {
        examples.map { "Wunsch: „\($0.request)“\n\($0.recipe)" }.joined(separator: "\n\n")
    }

    static let tempoText = """
    - Mit sync = BPM kommt das Echo als Viertelnote auf "bpm" (60000 / bpm Millisekunden). Ein Sync-Tremolo folgt demselben bpm.
    - Für andere Notenwerte stellst du "bpm" um: Viertel → Songtempo; punktierte Achtel (The Edge) → Songtempo × 4/3; Achtel → Songtempo × 2. Bleib zwischen 40 und 250. Nenne das echte Songtempo in "notes".
    - Ohne Song: Rhythmus-Echo 300–400 ms, Lead 400–500 ms, Ambient 500–700 ms (bpm = 60000 / ms).
    - Slapback (Rockabilly, Country): DelayMono mit sync Frei, range „200 ms“, time 4–5, feedback 0–1.
    """

    static let reverbText = """
    - Rock, Blues, Crunch: Raum A/B oder Kammer, level 1,5–2,5.
    - Ballade, singende Leads: Saal natürlich oder mittel, level 3–4.
    - Clean, Pop, Funk: Platte kurz, level 2–3 (Funk unter 1,5).
    - Surf: Platte satt, level 5–6 (statt Federhall).
    - Ambient, Post-Rock: Saal weit, length 8–9, level 4–5.
    - Metal-Rhythmus: aus, oder Raum mit level unter 1.
    """
}
