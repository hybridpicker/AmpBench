import AmpText
import Foundation

/// Turns a natural-language request into a sound recipe with an AI assistant over Ollama's cloud API.
///
/// It builds a prompt that contains the exact model catalog (ids, places, parameter keys and their labels), typical
/// signal chains and a few valid examples, so the assistant writes a recipe AmpBench can read without guessing,
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
            case .emptyRequest: tr("First describe the sound you want.")
            case .tooLong(let limit): tr("Describe the sound in at most %d characters.", limit)
            case .privacy(let message): message
            case .emptyAnswer: tr("The model did not answer. Try again.")
            case .noJSON:
                tr("The model gave free text instead of a sound recipe (JSON) – even when asked again. Try again or choose another model under “Advanced”.")
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
        let tail = " " + tr("Leave that out – only the description of the sound goes to Ollama.")
        if !matches(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#).isEmpty {
            return tr("Your wish contains an e-mail address.") + tail
        }
        if matches(#"\+?\d[\d \t/().-]{6,}\d"#).contains(where: { $0.filter(\.isNumber).count >= 8 }) {
            return tr("Your wish contains something like a phone number.") + tail
        }
        // A run of 24 or more letters and digits without spaces or hyphens, mixed, is a key or token, not a song.
        let tokens = matches(#"[A-Za-z0-9_+/=]{24,}"#)
        if tokens.contains(where: { $0.filter(\.isNumber).count >= 4 && $0.filter(\.isLetter).count >= 4 }) {
            return tr("Your wish contains something that looks like a key or password.") + tail
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

    /// The tag every sound made here carries. A stored value that the library filters by, so it is the same in every
    /// language.
    public static let aiTag = "KI-Sound"

    /// The recipe as it goes into the library: the wish in the description, marked as an AI Sound, with the
    /// adjustments that were made as tags. The description fits `PresetRules.descriptionLimit`, so what is kept is
    /// what plays: the wish first, the recipe's own words only when there is room.
    public static func keepsake(_ recipe: SoundRecipe, request: String, adjustments: [Adjustment] = []) -> SoundRecipe {
        var kept = recipe
        let wish = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = recipe.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = PresetRules.descriptionLimit
        var description = own
        if !wish.isEmpty {
            let marked = tr("AI Sound: “%@”", wish)
            let both = own.isEmpty ? marked : "\(marked). \(own)"
            if both.utf8.count <= limit {
                description = both
            } else if marked.utf8.count <= limit {
                description = marked
            } else {
                var cut = wish
                while tr("AI Sound: “%@…”", cut).utf8.count > limit, !cut.isEmpty { cut.removeLast() }
                description = tr("AI Sound: “%@…”", cut)
            }
        }
        kept.description = PresetRules.fitDescription(description)
        var tags: [String] = []
        for tag in recipe.tags + [aiTag] + adjustments.map(\.label)
        where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        kept.tags = tags
        return kept
    }

    // MARK: Prompt

    /// The messages for one `/api/chat` request: a system prompt with the rules and the catalog, then the request.
    public static func messages(request: String, catalog: CatalogReference, hint: String = "") -> [OllamaChatMessage] {
        let suffix = hint.isEmpty ? "" : "\n\nDirection of this variant: \(hint)"
        return [
            OllamaChatMessage(role: "system", content: systemPrompt(catalog: catalog)),
            OllamaChatMessage(role: "user", content: "User's wish: \(request)\(suffix)"),
        ]
    }

    /// Three directions for the same wish, so the user gets sounds that differ audibly instead of three takes of one.
    public static let variantHints = [
        "Variant A – faithful: the amp, the drive and the effects the player or the genre typically uses. Give the "
            + "sound a name of its own.",
        "Variant B – more punch: one gain stage more than the obvious choice (clean → edge of breakup, crunch → lead) "
            + "and another amp model than the most obvious one; more mids and presence. Give the sound a name of its "
            + "own that says so.",
        "Variant C – reduced and open: less gain than the obvious choice, another amp model, at most two effects and "
            + "another idea of space (for example tape echo instead of digital delay, plate instead of hall). Dynamic, "
            + "responds to picking. Give the sound a name of its own that says so.",
    ]

    /// A short title for each direction, one per hint, for the cards while they are written.
    public static var variantTitles: [String] { [tr("Faithful"), tr("More punch"), tr("Reduced")] }

    /// The language the assistant writes the recipe's own words in: the user's.
    static var answerLanguage: String { Texts.language == .german ? "German" : "English" }

    /// The rules, the knowledge and the catalog. Written in English whatever the app's language is; the assistant
    /// is told to write the recipe's name, description, tags and notes in the user's language.
    static func systemPrompt(catalog: CatalogReference) -> String {
        """
        You build guitar sounds for Positive Grid Spark amps as a “sound recipe” (a JSON object). The user describes an idea, a song, a band, a player or an instruction – for example “sound for U2 – Where the streets have no name” or “blues sound for my Telecaster”. The user may write in any language.

        Answer ONLY with a single JSON object, with no text before or after it, in exactly this form:

        {
          "format": "spark-sound-recipe",
          "version": 1,
          "name": "short name, at most 31 bytes (umlauts count double)",
          "description": "one sentence saying what the sound is",
          "bpm": 120,
          "tags": ["style", "mood"],
          "notes": "what to turn first by ear, and why",
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

        Rules:
        - Write "name", "description", "tags" and "notes" in \(answerLanguage). Model ids, parameter keys and labels stay exactly as the catalog writes them.
        - There are exactly these seven places in a fixed order: gate, compressor, drive, amp, modulation, delay, reverb. A place that should not sound is left out (no entry) or gets "on": false.
        - Every place has exactly ONE "model". Use only model ids from the catalog below, written exactly like that (upper and lower case matter).
        - "settings" uses only the parameter keys of that model from the catalog. Knob: a number from 0 to 10. Switch: true/false or exactly one of the given labels. Choice: exactly one of the given labels.
        - A value left out keeps the amp's start value. Always set gain, treble, middle, bass and master of the amp explicitly.
        - The EQ is a modulation (GuitarEQ6 or BassEQ6). The modulation place holds either an EQ or a chorus/phaser/tremolo, never both.
        - The wah of the paid add-on sits in the compressor place. Avoid models marked “PACK” unless the user asks for them explicitly.
        - There is exactly one reverb model (bias.reverb); its “type” chooses room, chamber, hall or plate. There is no spring reverb.
        - Amps have five knobs: gain, treble, middle, bass, master (pack amps call it volume).
        - For a song set "bpm" to fit the song's tempo (see Tempo and delay time), otherwise 120.
        - If a “Direction of this variant” is given, follow it. Variants should differ audibly: another amp, another gain stage or another idea for the effects.

        How to choose (starting points, not law):
        - Sparkling clean, jazz, funk: Twin, RolandJC120, 94MatchDCV2 (clean)
        - Clean that breaks up when you dig in: ODS50CN, Deluxe65, BluesJrTweed
        - British chime, 60s pop, indie: AC Boost, Bassman (bright)
        - Classic rock rhythm: Plexi, OverDrivenJM45 (crunch)
        - Blues lead: Bassman or OverDrivenLuxVerb, pushed by DistortionTS9
        - Singing lead, fusion: SLO100, Bogner, ODS50CN with a drive (highGain)
        - 80s hard rock: EVH, SwitchAxeLead, YJM100
        - Modern metal: 6505Plus, Rectifier, BE101 (metal)
        - Acoustic: AcousticAmpV2, FatAcousticV2 · Bass: GK800, Sunny3000, W600, Hammer500

        Players and genres – typical signal chains (starting points, only with models from the catalog):
        \(archetypeText)

        Gain staging (knobs 0–10):
        - Clean: amp.gain 2–4 · edge of breakup: 4.5–6 · crunch: 5–7 · high-gain amps mostly 5–7, above 8 it gets fizzy and noisy.
        - master is volume, not distortion: 6–8. The sounds of a set should be about equally loud.
        - Tightening high gain: a drive in front with almost no gain and a high level (DistortionTS9 drive 0–1.5, level 7–9), or Booster.
        - Pushing crunch to lead: DistortionTS9 drive 2–4.

        EQ words (what the user says → what you turn):
        - warmer/darker: treble down 1–2 (tone down on drives)
        - brighter/more sparkle: treble up 1, reverb highCut up
        - muddy/boomy: bass down 1–2
        - thin/harsh: bass up, treble down, less gain
        - more bite/cut: middle up 1–2
        - scooped/heavy rhythm: middle at 3–4, not below 3
        - more sustain: compressor BlueComp sustain 6–7, or more gain
        - funk spank: LA2AComp or Compressor, clean amp, little reverb

        Time effects:
        - Delay: level/mix 2–3 for rhythm, 3–4 for leads; feedback 2–4 (few repeats), above 7 it runs away.
        - Modulation: chorus effect 3–5, rate low; tremolo speed 4–6 for a surf pulse.
        - Gate: threshold 1.5–3 crunch, 3–5 high gain; off for clean.

        Tempo and delay time:
        \(tempoText)

        Reverb by style:
        \(reverbText)

        Keep it simple: a few fitting effects instead of everything at once. Choose the amp first, then build around it. Write in "notes" which one or two knobs the player should turn first by ear.

        EXAMPLES – valid recipes in exactly the required form:

        \(examplesText)

        CATALOG – use only these model ids, parameter keys and labels:

        \(catalogText(catalog))
        """
    }

    /// The catalog as a compact list for the prompt: id, character and parameters with their keys and exact labels.
    static func catalogText(_ catalog: CatalogReference) -> String {
        var lines: [String] = []
        for place in catalog.places {
            lines.append("## \(place.title) (key: \(place.key))")
            for id in place.models {
                guard let model = catalog.models.first(where: { $0.id == id }) else { continue }
                var head = "- \(model.id) · \(model.name)"
                if let inspiration = model.inspiration, !inspiration.isEmpty { head += " · modeled on \(inspiration)" }
                if let group = model.group, !group.isEmpty { head += " · \(group)" }
                if model.pack { head += " · PACK (paid add-on)" }
                lines.append(head)
                let params = model.parameters.map(Self.describe).joined(separator: ", ")
                if !params.isEmpty { lines.append("    \(params)") }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ parameter: CatalogReference.Parameter) -> String {
        switch parameter.kind {
        case "switch": return "`\(parameter.key)` switch (\(parameter.off ?? "Off")/\(parameter.on ?? "On"))"
        case "choice":
            let options = (parameter.options ?? []).map(\.label).joined(separator: " · ")
            return "`\(parameter.key)` choice (\(options))"
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
                    ? "Your answer contained no JSON object. Answer without any explanation."
                    : "Your JSON could not be read. Error:\n\(error.localizedDescription)"
            }
            messages.append(OllamaChatMessage(role: "user",
                content: correction + "\n\nAnswer again ONLY with the complete, corrected JSON object."))
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
        return "same amp “\(amp)”" + (drive.map { " and same drive “\($0)”" } ?? ", both without a drive")
    }

    static func distinctness(of recipe: SoundRecipe, among others: [SoundRecipe]) -> String? {
        for other in others {
            guard let reason = resemblance(recipe, other) else { continue }
            return "This suggestion sounds too much like “\(other.name)” (\(reason)). Build an audibly different "
                + "variant: choose another amp model and fit the drive and the effects to it. Keep the direction of "
                + "this variant and give it another name."
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

        /// The button's label, also kept as a tag, in the language the sound was made in.
        public var label: String {
            switch self {
            case .warmer: tr("warmer")
            case .moreGain: tr("more gain")
            case .lessReverb: tr("less reverb")
            case .brighter: tr("brighter")
            }
        }

        /// The same in English, for the messages to the assistant.
        var englishLabel: String {
            switch self {
            case .warmer: "warmer"
            case .moreGain: "more gain"
            case .lessReverb: "less reverb"
            case .brighter: "brighter"
            }
        }

        var instruction: String {
            switch self {
            case .warmer:
                "Make the sound warmer: amp.treble down 1–2, with a drive also its tone down a little, the reverb's "
                    + "highCut down a little."
            case .moreGain:
                "Give the sound more gain: amp.gain up 1–2, or switch on a fitting drive or raise its gain. Lower "
                    + "master a little at most, so that it stays equally loud."
            case .lessReverb:
                "Make the reverb clearly less: reverb.level down 1–2, length shorter too if needed."
            case .brighter:
                "Make the sound brighter: amp.treble up 1–2, with a drive its tone up a little, the reverb's highCut "
                    + "up a little."
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
                return SoundAI.activeModel(recipe, "reverb") == nil || level <= 0 ? tr("The sound has no reverb.") : nil
            case .moreGain:
                let gain = SoundAI.value(recipe, "amp", "gain", catalog: catalog) ?? 0
                return gain >= 10 && SoundAI.activeModel(recipe, "drive") != nil ? tr("More gain is not possible.") : nil
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
                return "In the place \(place) you replaced “\(before)” or switched it off. Keep all models and "
                    + "change only the knobs that “\(englishLabel)” needs."
            }
            guard isApplied(from: old, to: new, catalog: catalog) else {
                return "The recipe did not become “\(englishLabel)”. \(instruction)"
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
            case .warmer: tr("amp treble −1.5")
            case .brighter: tr("amp treble +1.5")
            case .moreGain: tr("amp gain +1.5")
            case .lessReverb: tr("reverb level −1.5")
            }
        }
    }

    /// The adjusted sound, and a note when AmpBench had to make the change itself.
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
                Adjust exactly this recipe: \(adjustment.englishLabel). \(adjustment.instruction)
                Keep the name, the amp and all other models. Change only the knobs this needs and leave everything else as it is. Adjust "notes" in one sentence, in \(answerLanguage).
                Answer ONLY with the complete JSON object.
                """),
        ]
    }

    /// Adjusts an offered sound by a follow-up request. The answer is checked: if it changed models or did not move
    /// in the asked direction, it goes back once; if it is still wrong, AmpBench turns the obvious knob itself
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
                                note: tr("The model did not apply “%@” cleanly. AmpBench made the change itself (%@).", adjustment.label, adjustment.nudgeDescription))
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
                return path.isEmpty ? tr("Invalid JSON: %@", context.debugDescription)
                                    : tr("Invalid JSON at “%@”: %@", path, context.debugDescription)
            case .keyNotFound(let key, _):
                return tr("The field “%@” is missing in the JSON.", key.stringValue)
            case .typeMismatch(_, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return tr("Wrong type at “%@”.", path.isEmpty ? tr("root") : path)
            case .valueNotFound(_, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return tr("Missing value at “%@”.", path.isEmpty ? tr("root") : path)
            @unknown default:
                break
            }
        }
        return error.localizedDescription
    }
}
