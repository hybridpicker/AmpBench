import Foundation

/// Turns a natural-language request into a sound recipe with an AI assistant over Ollama's cloud API.
///
/// It builds a prompt that contains the exact model catalog (ids, places, parameter keys and their labels), typical
/// signal chains and a few valid examples, so the assistant writes a recipe Spark Studio can read without guessing,
/// then parses and checks the answer. The chat itself is passed in as a function (`Chat`): `ollama(model:apiKey:)`
/// talks to the cloud, tests pass a fake, so nothing here needs a network.
///
/// Only the wish goes out, together with the rules and the catalog, and for a follow-up the recipe being adjusted.
/// `checkedRequest` refuses a wish that contains an e-mail address, a phone number or something that looks like a key.
public enum SoundAI {

    /// One chat answer for the messages at a temperature.
    public typealias Chat = @Sendable (_ messages: [OllamaChatMessage], _ temperature: Double) async throws -> String

    /// The chat over Ollama Cloud.
    public static func ollama(model: String, apiKey: String,
                              transport: @escaping OllamaCloud.Transport = OllamaCloud.urlSession,
                              retry: OllamaCloud.Retry = .standard) -> Chat {
        { messages, temperature in
            try await OllamaCloud.complete(model: model, apiKey: apiKey, messages: messages, temperature: temperature,
                                           transport: transport, retry: retry)
        }
    }

    /// What went wrong, in words the user can read and that can be fed back to the assistant for a correction.
    public enum Error: LocalizedError, Equatable {
        case emptyRequest
        case tooLong(Int)
        case privacy(String)
        case emptyAnswer
        case noJSON
        case unreadable(String)
        case invalid(String)
        case notPossible(String)

        public var errorDescription: String? {
            switch self {
            case .emptyRequest: "Beschreibe zuerst, welchen Sound du möchtest."
            case .tooLong(let limit): "Beschreibe den Sound in höchstens \(limit) Zeichen."
            case .privacy(let message): message
            case .emptyAnswer: "Das Modell hat nichts geantwortet. Versuch es noch einmal."
            case .noJSON:
                "Das Modell hat kein Sound-Rezept (JSON) geliefert, sondern freien Text – auch nach einer Nachfrage. "
                    + "Versuch es noch einmal oder wähle unter „Erweitert“ ein anderes Modell."
            case .unreadable(let message): message
            case .invalid(let message): message
            case .notPossible(let message): message
            }
        }
    }

    /// A message for the window, or nil when the user cancelled and nothing needs saying.
    public static func message(for error: Swift.Error) -> String? {
        if error is CancellationError { return nil }
        if let url = error as? URLError, url.code == .cancelled { return nil }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: The wish

    /// The longest wish that is sent. A sound is described in a sentence; a long text is more likely pasted by mistake.
    public static let requestLimit = 200

    /// The wish as it is sent, or why it is not sent.
    public static func checkedRequest(_ request: String) throws -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.emptyRequest }
        guard trimmed.count <= requestLimit else { throw Error.tooLong(requestLimit) }
        if let problem = privacyProblem(in: trimmed) { throw Error.privacy(problem) }
        return trimmed
    }

    /// Why a wish should not leave the Mac: it contains something personal or secret. Deterministic patterns only.
    public static func privacyProblem(in text: String) -> String? {
        func matches(_ pattern: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        }
        let tail = " Lass das weg – an Ollama geht nur die Beschreibung des Sounds."
        if !matches(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#).isEmpty {
            return "Dein Wunsch enthält eine E-Mail-Adresse." + tail
        }
        if matches(#"\+?\d[\d \t/().-]{6,}\d"#).contains(where: { $0.filter(\.isNumber).count >= 8 }) {
            return "Dein Wunsch enthält etwas wie eine Telefonnummer." + tail
        }
        // A run of 24 or more letters and digits without spaces or hyphens, mixed, is a key or token, not a song.
        let tokens = matches(#"[A-Za-z0-9_+/=]{24,}"#)
        if tokens.contains(where: { $0.filter(\.isNumber).count >= 4 && $0.filter(\.isLetter).count >= 4 }) {
            return "Dein Wunsch enthält etwas, das wie ein Schlüssel oder Passwort aussieht." + tail
        }
        return nil
    }

    /// The history with this wish in front, without a second copy of it, at most `limit` long.
    public static func remember(_ request: String, in history: [String], limit: Int = 8) -> [String] {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history }
        let rest = history.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        return Array(([trimmed] + rest).prefix(limit))
    }

    /// The recipe as it goes into the library: the wish in the description, marked as a KI-Sound, with the
    /// adjustments that were made as tags. The description fits `PresetRules.descriptionLimit`, so what is kept is
    /// what plays: the wish first, the recipe's own words only when there is room.
    public static func keepsake(_ recipe: SoundRecipe, request: String, adjustments: [Adjustment] = []) -> SoundRecipe {
        var kept = recipe
        let wish = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = recipe.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = PresetRules.descriptionLimit
        var description = own
        if !wish.isEmpty {
            let marked = "KI-Sound: „\(wish)“"
            let both = own.isEmpty ? marked : "\(marked). \(own)"
            if both.utf8.count <= limit {
                description = both
            } else if marked.utf8.count <= limit {
                description = marked
            } else {
                var cut = wish
                while "KI-Sound: „\(cut)…“".utf8.count > limit { cut.removeLast() }
                description = "KI-Sound: „\(cut)…“"
            }
        }
        kept.description = PresetRules.fitDescription(description)
        var tags: [String] = []
        for tag in recipe.tags + ["KI-Sound"] + adjustments.map(\.label)
        where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        kept.tags = tags
        return kept
    }

    // MARK: Prompt

    /// The messages for one `/api/chat` request: a system prompt with the rules and the catalog, then the request.
    public static func messages(request: String, catalog: CatalogReference, hint: String = "") -> [OllamaChatMessage] {
        let suffix = hint.isEmpty ? "" : "\n\nAusrichtung dieser Variante: \(hint)"
        return [
            OllamaChatMessage(role: "system", content: systemPrompt(catalog: catalog)),
            OllamaChatMessage(role: "user", content: "Nutzerwunsch: \(request)\(suffix)"),
        ]
    }

    /// Three directions for the same wish, so the user gets sounds that differ audibly instead of three takes of one.
    public static let variantHints = [
        "Variante A – originalgetreu: der Verstärker, der Verzerrer und die Effekte, die das Vorbild oder das Genre "
            + "typischerweise nutzt. Gib dem Sound einen eigenen Namen.",
        "Variante B – druckvoller: eine Gain-Stufe mehr als die naheliegende Wahl (clean → angezerrt, Crunch → Lead) "
            + "und ein anderes Verstärker-Modell als das naheliegendste; mehr Mitten und Präsenz. Gib dem Sound einen "
            + "eigenen Namen, der das ausdrückt.",
        "Variante C – reduziert und offen: weniger Gain als die naheliegende Wahl, ein anderes Verstärker-Modell, "
            + "höchstens zwei Effekte und eine andere Raum-Idee (zum Beispiel Bandecho statt Digital-Delay, Platte statt "
            + "Saal). Dynamisch, reagiert auf den Anschlag. Gib dem Sound einen eigenen Namen, der das ausdrückt.",
    ]

    /// A short title for each direction, one per hint, for the cards while they are written.
    public static let variantTitles = ["Originalgetreu", "Druckvoller", "Reduziert"]

    static func systemPrompt(catalog: CatalogReference) -> String {
        """
        Du erstellst Gitarren-Sounds für Positive-Grid-Spark-Verstärker als „Sound-Rezept“ (ein JSON-Objekt). Der Nutzer beschreibt eine Idee, einen Song, eine Band, ein Vorbild oder eine Anweisung – zum Beispiel „Sound für U2 – Where the streets have no name“ oder „Blues-Sound für meine Telecaster“.

        Antworte NUR mit einem einzigen JSON-Objekt, ohne Text davor oder danach, in genau diesem Aufbau:

        {
          "format": "spark-sound-recipe",
          "version": 1,
          "name": "kurzer Name, höchstens 31 Bytes (Umlaute zählen doppelt)",
          "description": "ein Satz, was der Sound ist",
          "bpm": 120,
          "tags": ["Stil", "Stimmung"],
          "notes": "was man zuerst nach Gehör drehen sollte und warum",
          "chain": {
            "gate":       { "model": "<id>", "on": true, "settings": { } },
            "compressor": { "model": "<id>", "on": true, "settings": { } },
            "drive":      { "model": "<id>", "on": true, "settings": { } },
            "amp":        { "model": "<id>", "settings": { } },
            "modulation": { "model": "<id>", "on": true, "settings": { } },
            "delay":      { "model": "<id>", "on": true, "settings": { } },
            "reverb":     { "model": "<id>", "settings": { } }
          }
        }

        Regeln:
        - Es gibt genau diese sieben Plätze in fester Reihenfolge: gate, compressor, drive, amp, modulation, delay, reverb. Einen Platz, der nicht klingen soll, lässt du weg (kein Eintrag) oder setzt "on": false.
        - Jeder Platz hat genau EIN "model". Nutze ausschließlich Modell-IDs aus dem Katalog unten, exakt so geschrieben (Groß-/Kleinschreibung zählt).
        - "settings" nutzt ausschließlich die Parameter-Schlüssel dieses Modells aus dem Katalog. Regler: Zahl von 0 bis 10. Schalter: true/false oder genau die angegebenen Labels. Auswahl: genau ein angegebenes Label (deutsch).
        - Ein weggelassener Wert behält den Startwert des Verstärkers. Setze gain, treble, middle, bass und master beim Amp immer ausdrücklich.
        - Der EQ ist eine Modulation (GuitarEQ6 oder BassEQ6). Am Modulations-Platz steht entweder ein EQ oder ein Chorus/Phaser/Tremolo, nie beides.
        - Das Wah des kostenpflichtigen Zusatzpakets sitzt am compressor-Platz. Vermeide Modelle mit „PACK“, außer der Nutzer verlangt sie ausdrücklich.
        - Es gibt genau ein Hall-Modell (bias.reverb); sein „type“ wählt Raum, Kammer, Saal oder Platte. Einen Federhall gibt es nicht.
        - Verstärker haben fünf Regler: gain, treble, middle, bass, master (Paket-Amps nennen ihn volume).
        - Bei einem Song setze "bpm" passend zum Tempo des Songs (siehe Tempo und Delay-Zeit), sonst 120.
        - Wenn eine „Ausrichtung dieser Variante“ dasteht, halte dich daran. Varianten sollen hörbar verschieden sein: anderer Verstärker, andere Gain-Stufe oder andere Effekt-Idee.

        So wählst du (Ausgangspunkte, kein Gesetz):
        - Strahlend clean, Jazz, Funk: Twin, RolandJC120, 94MatchDCV2 (clean)
        - Clean, das beim Anschlag aufbricht: ODS50CN, Deluxe65, BluesJrTweed
        - Britischer Glanz, 60er-Pop, Indie: AC Boost, Bassman (bright)
        - Classic-Rock-Rhythmus: Plexi, OverDrivenJM45 (crunch)
        - Blues-Lead: Bassman oder OverDrivenLuxVerb, angetrieben von DistortionTS9
        - Singendes Lead, Fusion: SLO100, Bogner, ODS50CN mit Drive (highGain)
        - 80er-Hardrock: EVH, SwitchAxeLead, YJM100
        - Modern Metal: 6505Plus, Rectifier, BE101 (metal)
        - Akustik: AcousticAmpV2, FatAcousticV2 · Bass: GK800, Sunny3000, W600, Hammer500

        Vorbilder – typische Signalketten (Ausgangspunkte, nur mit Modellen aus dem Katalog):
        \(archetypeText)

        Gain-Staging (Regler 0–10):
        - Clean: amp.gain 2–4 · am Rand des Aufbrechens: 4,5–6 · Crunch: 5–7 · High-Gain-Verstärker meist 5–7, über 8 wird es fizzelig und rauschig.
        - master ist Lautstärke, nicht Verzerrung: 6–8. Ein Set soll ähnlich laut sein.
        - High-Gain straffen: Drive davor fast ohne Gain, hoher Level (DistortionTS9 drive 0–1,5, level 7–9), oder Booster.
        - Crunch zu Lead pushen: DistortionTS9 drive 2–4.

        EQ-Wörter (was der Nutzer sagt → was du drehst):
        - wärmer/dunkler: treble 1–2 runter (bei Drives tone runter)
        - heller/mehr Glanz: treble 1 rauf, Hall highCut rauf
        - matschig/wummernd: bass 1–2 runter
        - dünn/scharf: bass rauf, treble runter, weniger gain
        - mehr Biss/Durchsetzung: middle 1–2 rauf
        - scooped/schwerer Rhythmus: middle auf 3–4, nicht unter 3
        - mehr Sustain: Kompressor BlueComp sustain 6–7, oder mehr gain
        - Funk-Spank: LA2AComp oder Compressor, cleaner Amp, wenig Hall

        Zeit-Effekte:
        - Delay: level/mix 2–3 für Rhythmus, 3–4 für Leads; feedback 2–4 (wenige Wiederholungen), über 7 läuft es weg.
        - Modulation: Chorus effect 3–5, rate niedrig; Tremolo speed 4–6 für Surf-Puls.
        - Gate: threshold 1,5–3 Crunch, 3–5 High-Gain; für clean aus.

        Tempo und Delay-Zeit:
        \(tempoText)

        Hall nach Stil:
        \(reverbText)

        Halte es einfach: wenige, passende Effekte statt alles auf einmal. Wähle zuerst den Verstärker, dann baue darum herum. Schreibe in "notes", welche ein bis zwei Regler der Spieler zuerst nach Gehör drehen soll.

        BEISPIELE – gültige Rezepte in genau der verlangten Form:

        \(examplesText)

        KATALOG – nutze nur diese Modell-IDs, Parameter-Schlüssel und Labels:

        \(catalogText(catalog))
        """
    }

    /// The catalog as a compact list for the prompt: id, character and parameters with their keys and exact labels.
    static func catalogText(_ catalog: CatalogReference) -> String {
        var lines: [String] = []
        for place in catalog.places {
            lines.append("## \(place.title) (Schlüssel: \(place.key))")
            for id in place.models {
                guard let model = catalog.models.first(where: { $0.id == id }) else { continue }
                var head = "- \(model.id) · \(model.name)"
                if let inspiration = model.inspiration, !inspiration.isEmpty { head += " · nach \(inspiration)" }
                if let group = model.group, !group.isEmpty { head += " · \(group)" }
                if model.pack { head += " · PACK (kostenpflichtig)" }
                lines.append(head)
                let params = model.parameters.map(Self.describe).joined(separator: ", ")
                if !params.isEmpty { lines.append("    \(params)") }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ parameter: CatalogReference.Parameter) -> String {
        switch parameter.kind {
        case "switch": return "`\(parameter.key)` Schalter (\(parameter.off ?? "aus")/\(parameter.on ?? "an"))"
        case "choice":
            let options = (parameter.options ?? []).map(\.label).joined(separator: " · ")
            return "`\(parameter.key)` Auswahl (\(options))"
        default: return "`\(parameter.key)` (0–10)"
        }
    }

    // MARK: Conversation

    /// A recipe the assistant wrote, and what it still did not get right after the corrections.
    struct Answer {
        var recipe: SoundRecipe
        var unresolved: String?
    }

    /// Asks until the answer reads as a recipe and `check` has nothing to complain about, at most `rounds` times.
    /// Each correction goes back with the error in hand. Network errors are not answered here; `OllamaCloud`
    /// repeats those.
    static func converse(_ start: [OllamaChatMessage], chat: Chat, temperature: Double, rounds: Int = 3,
                         check: (SoundRecipe) async -> String? = { _ in nil }) async throws -> Answer {
        var messages = start
        var lastValid: Answer?
        var lastError: Error = .emptyAnswer
        for _ in 0..<rounds {
            try Task.checkCancellation()
            let answer = try await chat(messages, temperature)
            messages.append(OllamaChatMessage(role: "assistant", content: answer))
            let correction: String
            do {
                let recipe = try parse(answer)
                guard let complaint = await check(recipe) else { return Answer(recipe: recipe) }
                lastValid = Answer(recipe: recipe, unresolved: complaint)
                correction = complaint
            } catch let error as Error {
                lastError = error
                correction = error == .noJSON
                    ? "Deine Antwort enthielt kein JSON-Objekt. Antworte ohne jede Erklärung."
                    : "Dein JSON war nicht lesbar. Fehler:\n\(error.localizedDescription)"
            }
            messages.append(OllamaChatMessage(role: "user",
                content: correction + "\n\nAntworte erneut NUR mit dem vollständigen, korrigierten JSON-Objekt."))
        }
        if let lastValid { return lastValid }
        throw lastError
    }

    // MARK: Generation

    /// Asks the assistant for a recipe and parses it. Corrective rounds with the error in hand if an answer does not
    /// read, so a wrong option label or model id does not end the request. `avoid` lists sounds already on offer:
    /// an answer with the same amp and drive is sent back once to be made different.
    public static func generate(request: String, chat: Chat, catalog: CatalogReference = CatalogReference(),
                                hint: String = "", temperature: Double = 0.4,
                                avoid: [SoundRecipe] = []) async throws -> SoundRecipe {
        let wish = try checkedRequest(request)
        var complained = false
        let answer = try await converse(messages(request: wish, catalog: catalog, hint: hint), chat: chat,
                                        temperature: temperature) { recipe in
            guard !complained, let complaint = distinctness(of: recipe, among: avoid) else { return nil }
            complained = true
            return complaint
        }
        return answer.recipe
    }

    /// Asks the cloud for one recipe.
    public static func generate(request: String, model: String, apiKey: String,
                                catalog: CatalogReference = CatalogReference(),
                                hint: String = "", temperature: Double = 0.4) async throws -> SoundRecipe {
        try await generate(request: request, chat: ollama(model: model, apiKey: apiKey), catalog: catalog,
                           hint: hint, temperature: temperature)
    }

    /// What arrives while the variants are written: one event per variant, in the order they finish.
    public enum VariantEvent: Sendable {
        case ready(Int, SoundRecipe)
        case failed(Int, Swift.Error)
    }

    /// Writes one recipe per hint at the same time and hands each over as soon as it is done, so the first sound can
    /// be heard while the others are still being written. Cancelling the consuming task, or dropping the stream,
    /// cancels the requests. A variant too close to one that is already done is sent back once to be made different.
    /// Throws before anything is sent when the wish is empty, too long or contains personal data.
    public static func variants(request: String, chat: @escaping Chat,
                                catalog: CatalogReference = CatalogReference(),
                                hints: [String] = variantHints) throws -> AsyncStream<VariantEvent> {
        let wish = try checkedRequest(request)
        let offered = Offered()
        return AsyncStream { continuation in
            let work = Task {
                await withTaskGroup(of: Void.self) { group in
                    for (index, hint) in hints.enumerated() {
                        group.addTask {
                            do {
                                var complained = false
                                let answer = try await converse(messages(request: wish, catalog: catalog, hint: hint),
                                                                chat: chat, temperature: 0.6) { recipe in
                                    guard let complaint = await offered.claim(index, recipe), !complained else {
                                        return nil
                                    }
                                    complained = true
                                    return complaint
                                }
                                await offered.keep(index, answer.recipe)
                                continuation.yield(.ready(index, answer.recipe))
                            } catch {
                                if !Task.isCancelled, message(for: error) != nil {
                                    continuation.yield(.failed(index, error))
                                }
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// The variants that are done, so a later one can be told it sounds the same.
    private actor Offered {
        private var recipes: [Int: SoundRecipe] = [:]

        /// A complaint when the recipe is too close to another finished variant; otherwise it is taken.
        func claim(_ index: Int, _ recipe: SoundRecipe) -> String? {
            let others = recipes.filter { $0.key != index }.sorted { $0.key < $1.key }.map(\.value)
            if let complaint = SoundAI.distinctness(of: recipe, among: others) { return complaint }
            recipes[index] = recipe
            return nil
        }

        func keep(_ index: Int, _ recipe: SoundRecipe) { recipes[index] = recipe }
    }

    /// What makes two sounds hard to tell apart: the same amp model and the same drive (or none in both).
    static func resemblance(_ a: SoundRecipe, _ b: SoundRecipe) -> String? {
        guard let amp = a.chain["amp"]?.model, amp == b.chain["amp"]?.model else { return nil }
        let drive = activeModel(a, "drive")
        guard drive == activeModel(b, "drive") else { return nil }
        return "gleicher Verstärker „\(amp)“" + (drive.map { " und gleicher Verzerrer „\($0)“" } ?? ", beide ohne Verzerrer")
    }

    static func distinctness(of recipe: SoundRecipe, among others: [SoundRecipe]) -> String? {
        for other in others {
            guard let reason = resemblance(recipe, other) else { continue }
            return "Dieser Vorschlag klingt zu ähnlich wie „\(other.name)“ (\(reason)). Baue eine hörbar andere "
                + "Variante: wähle ein anderes Verstärker-Modell und passe Verzerrer und Effekte dazu an. Behalte die "
                + "Ausrichtung dieser Variante und gib ihr einen anderen Namen."
        }
        return nil
    }

    static func activeModel(_ recipe: SoundRecipe, _ place: String) -> String? {
        guard let unit = recipe.chain[place], unit.on else { return nil }
        return unit.model
    }

    // MARK: Refinement

    /// A quick change to an offered sound, made by a follow-up request instead of a new one.
    public enum Adjustment: String, CaseIterable, Sendable, Identifiable {
        case warmer, moreGain, lessReverb, brighter

        public var id: String { rawValue }

        /// The button's label, also kept as a tag.
        public var label: String {
            switch self {
            case .warmer: "wärmer"
            case .moreGain: "mehr Gain"
            case .lessReverb: "weniger Hall"
            case .brighter: "heller"
            }
        }

        var instruction: String {
            switch self {
            case .warmer:
                "Mach den Sound wärmer: amp.treble 1–2 runter, bei einem Verzerrer auch dessen tone etwas runter, "
                    + "beim Hall highCut etwas runter."
            case .moreGain:
                "Gib dem Sound mehr Gain: amp.gain um 1–2 rauf, oder einen passenden Verzerrer einschalten bzw. dessen "
                    + "Gain erhöhen. master höchstens etwas senken, damit es gleich laut bleibt."
            case .lessReverb:
                "Mach den Hall deutlich weniger: reverb.level um 1–2 runter, bei Bedarf auch length kürzer."
            case .brighter:
                "Mach den Sound heller: amp.treble 1–2 rauf, bei einem Verzerrer dessen tone etwas rauf, beim Hall "
                    + "highCut etwas rauf."
            }
        }

        /// Places whose model may change for this adjustment; every other place keeps its model.
        var openPlaces: Set<String> {
            self == .moreGain ? ["drive", "gate"] : []
        }

        /// Why the adjustment makes no sense for this sound, if it does not.
        public func impossibility(for recipe: SoundRecipe, catalog: CatalogReference = CatalogReference()) -> String? {
            switch self {
            case .lessReverb:
                let level = SoundAI.value(recipe, "reverb", "level", catalog: catalog) ?? 0
                return SoundAI.activeModel(recipe, "reverb") == nil || level <= 0 ? "Der Sound hat keinen Hall." : nil
            case .moreGain:
                let gain = SoundAI.value(recipe, "amp", "gain", catalog: catalog) ?? 0
                return gain >= 10 && SoundAI.activeModel(recipe, "drive") != nil ? "Mehr Gain geht nicht." : nil
            case .warmer, .brighter:
                return nil
            }
        }

        /// Whether `new` went in this direction from `old`.
        public func isApplied(from old: SoundRecipe, to new: SoundRecipe,
                              catalog: CatalogReference = CatalogReference()) -> Bool {
            func change(_ place: String, _ key: String) -> Double {
                guard SoundAI.activeModel(old, place) != nil, SoundAI.activeModel(new, place) != nil,
                      let before = SoundAI.value(old, place, key, catalog: catalog),
                      let after = SoundAI.value(new, place, key, catalog: catalog) else { return 0 }
                return after - before
            }
            let step = 0.5
            switch self {
            case .warmer:
                return change("amp", "treble") <= -step || change("drive", "tone") <= -step
                    || change("reverb", "highCut") <= -step
            case .brighter:
                return change("amp", "treble") >= step || change("drive", "tone") >= step
                    || change("drive", "treble") >= step || change("reverb", "highCut") >= step
            case .moreGain:
                if SoundAI.activeModel(old, "drive") == nil, SoundAI.activeModel(new, "drive") != nil { return true }
                if let a = SoundAI.activeModel(old, "drive"), let b = SoundAI.activeModel(new, "drive"), a != b {
                    return true
                }
                return change("amp", "gain") >= step
                    || ["drive", "gain", "fuzz", "sustain", "distortion"].contains { change("drive", $0) >= step }
            case .lessReverb:
                if SoundAI.activeModel(old, "reverb") != nil, SoundAI.activeModel(new, "reverb") == nil { return true }
                return change("reverb", "level") <= -step || change("reverb", "length") <= -step
            }
        }

        /// What is wrong with `new` as this adjustment of `old`, for sending it back; nil when it is right.
        func complaint(from old: SoundRecipe, to new: SoundRecipe, catalog: CatalogReference) -> String? {
            for place in ChainPlace.allCases.map(\.key) where !openPlaces.contains(place) {
                guard let before = SoundAI.activeModel(old, place) else { continue }
                if self == .lessReverb, place == "reverb", SoundAI.activeModel(new, place) == nil { continue }
                guard SoundAI.activeModel(new, place) != before else { continue }
                return "Du hast am Platz \(place) „\(before)“ ersetzt oder ausgeschaltet. Behalte alle Modelle und "
                    + "ändere nur die Regler, die für „\(label)“ nötig sind."
            }
            guard isApplied(from: old, to: new, catalog: catalog) else {
                return "Das Rezept ist nicht „\(label)“ geworden. \(instruction)"
            }
            return nil
        }

        /// The same change made locally, when the assistant does not make it: a step on the obvious knob.
        public func nudged(_ recipe: SoundRecipe, catalog: CatalogReference = CatalogReference()) -> SoundRecipe {
            var result = recipe
            func shift(_ place: String, _ key: String, by amount: Double) {
                guard SoundAI.activeModel(result, place) != nil,
                      let value = SoundAI.value(result, place, key, catalog: catalog) else { return }
                let next = ((min(max(value + amount, 0), 10)) * 10).rounded() / 10
                result.chain[place]?.settings[key] = .number(next)
            }
            switch self {
            case .warmer:
                shift("amp", "treble", by: -1.5)
                shift("drive", "tone", by: -1)
            case .brighter:
                shift("amp", "treble", by: 1.5)
            case .moreGain:
                shift("amp", "gain", by: 1.5)
            case .lessReverb:
                shift("reverb", "level", by: -1.5)
                if (SoundAI.value(result, "reverb", "level", catalog: catalog) ?? 0) < 0.5 {
                    result.chain["reverb"]?.on = false
                }
            }
            return result
        }

        /// What `nudged` turns, for telling the user.
        var nudgeDescription: String {
            switch self {
            case .warmer: "Höhen am Amp −1,5"
            case .brighter: "Höhen am Amp +1,5"
            case .moreGain: "Gain am Amp +1,5"
            case .lessReverb: "Hall-Pegel −1,5"
            }
        }
    }

    /// The adjusted sound, and a note when Spark Studio had to make the change itself.
    public struct Refinement: Sendable {
        public var recipe: SoundRecipe
        public var note: String?
    }

    /// The messages for a follow-up: the original wish, the recipe as the assistant's last answer, then the change.
    static func refineMessages(_ recipe: SoundRecipe, _ adjustment: Adjustment, request: String,
                               catalog: CatalogReference) -> [OllamaChatMessage] {
        let json = (try? recipe.jsonData()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return messages(request: request, catalog: catalog) + [
            OllamaChatMessage(role: "assistant", content: json),
            OllamaChatMessage(role: "user", content: """
                Passe genau dieses Rezept an: \(adjustment.label). \(adjustment.instruction)
                Behalte den Namen, den Verstärker und alle anderen Modelle. Ändere nur die Regler, die dafür nötig sind, und lass alles andere unverändert. Passe "notes" in einem Satz an.
                Antworte NUR mit dem vollständigen JSON-Objekt.
                """),
        ]
    }

    /// Adjusts an offered sound by a follow-up request. The answer is checked: if it changed models or did not move
    /// in the asked direction, it goes back once; if it is still wrong, Spark Studio turns the obvious knob itself
    /// and says so in the note. The name and tags stay.
    public static func refine(_ recipe: SoundRecipe, _ adjustment: Adjustment, request: String, chat: Chat,
                              catalog: CatalogReference = CatalogReference()) async throws -> Refinement {
        if let reason = adjustment.impossibility(for: recipe, catalog: catalog) { throw Error.notPossible(reason) }
        let wish = try checkedRequest(request)
        let answer = try await converse(refineMessages(recipe, adjustment, request: wish, catalog: catalog),
                                        chat: chat, temperature: 0.2) { new in
            adjustment.complaint(from: recipe, to: new, catalog: catalog)
        }
        var result: Refinement
        if answer.unresolved == nil {
            result = Refinement(recipe: answer.recipe)
        } else {
            result = Refinement(recipe: adjustment.nudged(recipe, catalog: catalog),
                                note: "Das Modell hat „\(adjustment.label)“ nicht sauber umgesetzt. Spark Studio hat "
                                    + "selbst nachgestellt (\(adjustment.nudgeDescription)).")
        }
        result.recipe.name = recipe.name
        result.recipe.tags = recipe.tags
        return result
    }

    /// A knob's value in a recipe: the one it sets, or the amp's start value from the catalog.
    static func value(_ recipe: SoundRecipe, _ place: String, _ key: String, catalog: CatalogReference) -> Double? {
        guard let unit = recipe.chain[place] else { return nil }
        if case .number(let number) = unit.settings[key] { return number }
        guard let start = catalog.models.first(where: { $0.id == unit.model })?
            .parameters.first(where: { $0.key == key })?.start,
            case .number(let number) = start else { return nil }
        return number
    }

    // MARK: Parsing

    /// Reads a recipe from the assistant's answer and checks it. Throws every problem at once.
    public static func parse(_ answer: String) throws -> SoundRecipe {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.emptyAnswer }
        guard let object = extractJSONObject(from: trimmed) else { throw Error.noJSON }
        guard let data = object.data(using: .utf8) else { throw Error.noJSON }
        let recipe: SoundRecipe
        do {
            recipe = try JSONDecoder().decode(SoundRecipe.self, from: data)
        } catch {
            throw Error.unreadable(describeDecoding(error, data: data))
        }
        do {
            _ = try recipe.preset()
        } catch let problems as SoundRecipe.Problems {
            throw Error.invalid(problems.messages.joined(separator: "\n"))
        }
        return recipe
    }

    /// The first balanced `{ ... }` in the answer, so a code fence or a word around the JSON does not break it.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }

    private static func describeDecoding(_ error: Swift.Error, data: Data) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .dataCorrupted(let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return "Ungültiges JSON\(path.isEmpty ? "" : " bei „\(path)“"): \(context.debugDescription)"
            case .keyNotFound(let key, _):
                return "Das Feld „\(key.stringValue)“ fehlt im JSON."
            case .typeMismatch(_, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return "Falscher Typ bei „\(path.isEmpty ? "Wurzel" : path)“."
            case .valueNotFound(_, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return "Fehlender Wert bei „\(path.isEmpty ? "Wurzel" : path)“."
            @unknown default:
                break
            }
        }
        return error.localizedDescription
    }
}
