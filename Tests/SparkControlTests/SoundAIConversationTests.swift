import XCTest
@testable import SparkControl

/// KI-Sound beyond the parser: the prompt's knowledge, the wish check, corrections, variants that arrive one by one,
/// quick changes and the HTTP client. Every chat and every HTTP answer is faked; nothing here uses the network.
final class SoundAIConversationTests: XCTestCase {

    // MARK: Fakes

    /// Hands out prepared answers in order and records what was asked.
    private final class ScriptedChat: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String]
        private var recorded: [[OllamaChatMessage]] = []

        init(_ answers: [String]) { self.answers = answers }

        var calls: [[OllamaChatMessage]] { lock.withLock { recorded } }

        var chat: SoundAI.Chat {
            { messages, _ in
                self.lock.withLock {
                    self.recorded.append(messages)
                    return self.answers.isEmpty ? "" : self.answers.removeFirst()
                }
            }
        }
    }

    /// Answers HTTP requests from a prepared list and counts them.
    private final class ScriptedTransport: @unchecked Sendable {
        enum Step { case status(Int, String), failure(URLError) }
        private let lock = NSLock()
        private var steps: [Step]
        private var requests: [URLRequest] = []

        init(_ steps: [Step]) { self.steps = steps }

        var count: Int { lock.withLock { requests.count } }

        var transport: OllamaCloud.Transport {
            { request in
                let step: Step = self.lock.withLock {
                    self.requests.append(request)
                    return self.steps.isEmpty ? .status(500, "") : self.steps.removeFirst()
                }
                switch step {
                case .failure(let error): throw error
                case .status(let code, let body):
                    let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                    return (Data(body.utf8), response)
                }
            }
        }
    }

    private func recipe(name: String = "Test", amp: String = "Plexi", gain: Double = 6, treble: Double = 6,
                        drive: String? = nil, reverbLevel: Double? = 3) -> String {
        var chain = ["\"amp\": {\"model\": \"\(amp)\", \"settings\": {\"gain\": \(gain), \"treble\": \(treble), \"middle\": 5, \"bass\": 5, \"master\": 7}}"]
        if let drive { chain.append("\"drive\": {\"model\": \"\(drive)\"}") }
        if let reverbLevel {
            chain.append("\"reverb\": {\"model\": \"bias.reverb\", \"settings\": {\"level\": \(reverbLevel)}}")
        } else {
            chain.append("\"reverb\": {\"model\": \"bias.reverb\", \"on\": false}")
        }
        return "{\"format\": \"spark-sound-recipe\", \"version\": 1, \"name\": \"\(name)\", \"bpm\": 120, "
            + "\"chain\": {\(chain.joined(separator: ", "))}}"
    }

    private func parsed(_ json: String) throws -> SoundRecipe { try SoundAI.parse(json) }

    private func ok(_ content: String) -> ScriptedTransport.Step {
        let body = try! JSONEncoder().encode(["message": ["role": "assistant", "content": content]])
        return .status(200, String(data: body, encoding: .utf8)!)
    }

    // MARK: Knowledge in the prompt

    func testExamplesInThePromptAreValidRecipes() throws {
        XCTAssertGreaterThanOrEqual(SoundAI.examples.count, 3)
        for example in SoundAI.examples {
            let recipe = try SoundAI.parse(example.recipe)
            let conversion = try recipe.preset()
            XCTAssertEqual(conversion.warnings, [], "\(example.request): \(conversion.warnings)")
        }
    }

    func testArchetypesUseOnlyFreeCatalogModelsInChainOrder() {
        XCTAssertGreaterThanOrEqual(SoundAI.archetypes.count, 20)
        for archetype in SoundAI.archetypes {
            let infos = archetype.models.map { ModelCatalog.known($0) }
            for (id, info) in zip(archetype.models, infos) {
                XCTAssertNotNil(info, "\(archetype.topic): unknown model \(id)")
                XCTAssertEqual(info?.isPack, false, "\(archetype.topic): \(id) needs a paid pack")
            }
            let places = infos.compactMap { $0?.place.rawValue }
            XCTAssertEqual(places, places.sorted(), "\(archetype.topic): models not in chain order")
            XCTAssertEqual(Set(places).count, places.count, "\(archetype.topic): two models on one place")
        }
    }

    func testSystemPromptCarriesPlayersTempoReverbAndExamples() {
        let prompt = SoundAI.messages(request: "x", catalog: CatalogReference())[0].content
        XCTAssertTrue(prompt.contains("The Edge (U2)"))
        XCTAssertTrue(prompt.contains("punktierte Achtel"))
        XCTAssertTrue(prompt.contains("Songtempo × 4/3"))
        XCTAssertTrue(prompt.contains("Hall nach Stil"))
        XCTAssertTrue(prompt.contains("\"name\":\"Streets Echo\""))
    }

    func testVariantsHaveThreeDifferentDirections() {
        XCTAssertEqual(SoundAI.variantHints.count, 3)
        XCTAssertEqual(Set(SoundAI.variantHints).count, 3)
        XCTAssertEqual(SoundAI.variantTitles.count, SoundAI.variantHints.count)
    }

    // MARK: The wish

    func testOrdinaryWishesPass() throws {
        for wish in ["U2 – Where the Streets Have No Name", "Bryan Adams – Summer of '69",
                     "Van Halen 5150 aus 1984", "Metallica – Enter Sandman (1991), 123 BPM",
                     "Drop-D-Riff in 7/8 bei 140 bpm", "Where-the-streets-have-no-name-2"] {
            XCTAssertNoThrow(try SoundAI.checkedRequest(wish), wish)
        }
    }

    func testWishesWithPersonalDataOrSecretsAreRefused() {
        for wish in ["Sound für max.mustermann@example.com", "Ruf mich an: +43 664 1234567",
                     "Blues, Rückfrage unter 0664/1234567", "Mein Schlüssel 3f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c"] {
            XCTAssertThrowsError(try SoundAI.checkedRequest(wish), wish) { error in
                guard case SoundAI.Error.privacy = error else { return XCTFail("expected .privacy, got \(error)") }
            }
        }
    }

    func testEmptyAndOverlongWishesAreRefused() {
        XCTAssertThrowsError(try SoundAI.checkedRequest("   ")) { XCTAssertEqual($0 as? SoundAI.Error, .emptyRequest) }
        let long = String(repeating: "a", count: SoundAI.requestLimit + 1)
        XCTAssertThrowsError(try SoundAI.checkedRequest(long)) {
            XCTAssertEqual($0 as? SoundAI.Error, .tooLong(SoundAI.requestLimit))
        }
    }

    func testRefusedWishSendsNothing() async {
        let chat = ScriptedChat([recipe()])
        XCTAssertThrowsError(try SoundAI.variants(request: "an a@b.de", chat: chat.chat))
        do {
            _ = try await SoundAI.generate(request: "an a@b.de", chat: chat.chat)
            XCTFail("expected a refusal")
        } catch {}
        XCTAssertEqual(chat.calls.count, 0)
    }

    func testHistoryPutsTheNewestFirstOnceAndStaysShort() {
        var history = SoundAI.remember("Blues", in: [])
        history = SoundAI.remember("Jazz", in: history)
        history = SoundAI.remember("blues ", in: history)
        XCTAssertEqual(history, ["blues", "Jazz"])
        let full = (1...8).map { "Wunsch \($0)" }
        XCTAssertEqual(SoundAI.remember("Neu", in: full).count, 8)
        XCTAssertEqual(SoundAI.remember("Neu", in: full).first, "Neu")
        XCTAssertEqual(SoundAI.remember("  ", in: full), full)
    }

    func testKeepsakeCarriesTheWishAndTags() throws {
        var sound = try parsed(recipe())
        sound.description = "Plexi-Crunch"
        sound.tags = ["Rock"]
        let kept = SoundAI.keepsake(sound, request: "AC/DC – Back in Black", adjustments: [.warmer, .moreGain])
        XCTAssertEqual(kept.description, "KI-Sound: „AC/DC – Back in Black“. Plexi-Crunch")
        XCTAssertEqual(kept.tags, ["Rock", "KI-Sound", "wärmer", "mehr Gain"])

        sound.description = String(repeating: "ä", count: 200)
        XCTAssertLessThanOrEqual(SoundAI.keepsake(sound, request: "x").description.utf8.count,
                                 PresetRules.descriptionLimit)
    }

    /// The sound that made the amp howl on 2026-11-08: its kept description had 136 bytes.
    func testTheKeptJoshuaTreeEchoFitsWhatTheAmpTakes() throws {
        var sound = try parsed(recipe())
        sound.description = "Originalgetreuer The-Edge-Sound: glänzender Vox-Clean mit punktiertem Achtel-Echo"
        let kept = SoundAI.keepsake(sound, request: "U2 - where the streets have no name.")
        XCTAssertEqual(kept.description, "KI-Sound: „U2 - where the streets have no name.“")
        XCTAssertLessThanOrEqual(try kept.preset().preset.description.utf8.count, PresetRules.descriptionLimit)

        let long = String(repeating: "Wunsch ", count: 30)
        let cut = SoundAI.keepsake(sound, request: long).description
        XCTAssertLessThanOrEqual(cut.utf8.count, PresetRules.descriptionLimit)
        XCTAssertTrue(cut.hasPrefix("KI-Sound: „Wunsch"))
        XCTAssertTrue(cut.hasSuffix("…“"))
    }

    // MARK: Corrections

    func testAnAnswerWithoutJSONIsSentBackOnce() async throws {
        let chat = ScriptedChat(["Gern! Nimm einen Plexi mit viel Gain.", recipe()])
        let sound = try await SoundAI.generate(request: "Rock", chat: chat.chat)
        XCTAssertEqual(sound.chain["amp"]?.model, "Plexi")
        XCTAssertEqual(chat.calls.count, 2)
        XCTAssertTrue(chat.calls[1].last?.content.contains("kein JSON") ?? false)
        XCTAssertEqual(chat.calls[1].dropLast().last?.role, "assistant")
    }

    func testRepeatedProseEndsWithAHintAboutTheModel() async {
        let chat = ScriptedChat(["Text.", "Noch mehr Text.", "Immer noch Text."])
        do {
            _ = try await SoundAI.generate(request: "Rock", chat: chat.chat)
            XCTFail("expected .noJSON")
        } catch {
            XCTAssertEqual(error as? SoundAI.Error, .noJSON)
            XCTAssertTrue(SoundAI.message(for: error)?.contains("anderes Modell") ?? false)
        }
        XCTAssertEqual(chat.calls.count, 3)
    }

    func testCancellationIsNotAnErrorMessage() {
        XCTAssertNil(SoundAI.message(for: CancellationError()))
        XCTAssertNil(SoundAI.message(for: URLError(.cancelled)))
        XCTAssertNotNil(SoundAI.message(for: OllamaCloud.Error.timeout))
    }

    // MARK: Variants

    /// Answers by the variant's direction in the last user message, after a delay per variant.
    private func variantChat(delays: [String: UInt64], answer: @escaping @Sendable (String, String) -> String) -> SoundAI.Chat {
        { messages, _ in
            let first = messages[1].content
            let last = messages.last?.content ?? ""
            let key = ["Variante A", "Variante B", "Variante C"].first { first.contains($0) } ?? ""
            if let delay = delays[key] { try await Task.sleep(nanoseconds: delay) }
            return answer(key, last)
        }
    }

    func testVariantsArriveAsSoonAsEachIsDone() async throws {
        let chat = variantChat(delays: ["Variante A": 400_000_000, "Variante C": 150_000_000]) { key, _ in
            switch key {
            case "Variante A": self.recipe(name: "A", amp: "Twin", gain: 3)
            case "Variante B": self.recipe(name: "B", amp: "Plexi")
            default: self.recipe(name: "C", amp: "RolandJC120", gain: 2)
            }
        }
        var order: [Int] = []
        for await event in try SoundAI.variants(request: "Rock", chat: chat) {
            guard case .ready(let index, _) = event else { return XCTFail("unexpected \(event)") }
            order.append(index)
        }
        XCTAssertEqual(order, [1, 2, 0])
    }

    func testASoundAlikeVariantIsSentBackToBeMadeDifferent() async throws {
        let chat = variantChat(delays: ["Variante B": 100_000_000, "Variante C": 250_000_000]) { key, last in
            guard last.contains("zu ähnlich") else { return self.recipe(name: key, amp: "Twin", gain: 3) }
            return self.recipe(name: key, amp: key == "Variante B" ? "Plexi" : "RolandJC120")
        }
        var amps: [Int: String] = [:]
        for await event in try SoundAI.variants(request: "Clean", chat: chat) {
            guard case .ready(let index, let sound) = event else { return XCTFail("unexpected \(event)") }
            amps[index] = sound.chain["amp"]?.model
        }
        XCTAssertEqual(amps, [0: "Twin", 1: "Plexi", 2: "RolandJC120"])
    }

    func testOneFailingVariantDoesNotStopTheOthers() async throws {
        let chat: SoundAI.Chat = { messages, _ in
            if messages[1].content.contains("Variante C") { throw OllamaCloud.Error.rateLimited }
            return messages[1].content.contains("Variante A") ? self.recipe(amp: "Twin") : self.recipe(amp: "Plexi")
        }
        var ready: Set<Int> = []
        var failed: [Int: String] = [:]
        for await event in try SoundAI.variants(request: "Rock", chat: chat) {
            switch event {
            case .ready(let index, _): ready.insert(index)
            case .failed(let index, let error): failed[index] = SoundAI.message(for: error)
            }
        }
        XCTAssertEqual(ready, [0, 1])
        XCTAssertEqual(failed.keys.sorted(), [2])
        XCTAssertTrue(failed[2]?.contains("ausgelastet") ?? false)
    }

    func testCancellingStopsTheRequests() async throws {
        let chat: SoundAI.Chat = { _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return ""
        }
        let stream = try SoundAI.variants(request: "Rock", chat: chat)
        let started = Date()
        let consumer = Task { () -> Int in
            var events = 0
            for await _ in stream { events += 1 }
            return events
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()
        let events = await consumer.value
        XCTAssertEqual(events, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    // MARK: Quick changes

    func testRefineKeepsTheSoundAndMakesTheChange() async throws {
        let original = try parsed(recipe(name: "Crunch", treble: 6))
        let chat = ScriptedChat([recipe(name: "Anderer Name", treble: 4)])
        let result = try await SoundAI.refine(original, .warmer, request: "Rock", chat: chat.chat)
        XCTAssertEqual(result.recipe.name, "Crunch")
        XCTAssertEqual(result.recipe.chain["amp"]?.settings["treble"], .number(4))
        XCTAssertNil(result.note)
        XCTAssertEqual(chat.calls.count, 1)
        let sent = chat.calls[0]
        XCTAssertEqual(sent.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertTrue(sent[2].content.contains("\"Crunch\""), "the current recipe goes along")
        XCTAssertTrue(sent[3].content.contains("wärmer"))
    }

    func testRefineSendsBackAnAmpSwap() async throws {
        let original = try parsed(recipe(amp: "Plexi", treble: 6))
        let chat = ScriptedChat([recipe(amp: "Twin", treble: 4), recipe(amp: "Plexi", treble: 4.5)])
        let result = try await SoundAI.refine(original, .warmer, request: "Rock", chat: chat.chat)
        XCTAssertEqual(result.recipe.chain["amp"]?.model, "Plexi")
        XCTAssertEqual(chat.calls.count, 2)
        XCTAssertTrue(chat.calls[1].last?.content.contains("ersetzt") ?? false)
    }

    func testRefineTurnsTheKnobItselfWhenTheModelDoesNot() async throws {
        let original = try parsed(recipe(treble: 6))
        let unchanged = recipe(treble: 6)
        let chat = ScriptedChat([unchanged, unchanged, unchanged])
        let result = try await SoundAI.refine(original, .warmer, request: "Rock", chat: chat.chat)
        XCTAssertEqual(result.recipe.chain["amp"]?.settings["treble"], .number(4.5))
        XCTAssertNotNil(result.note)
        XCTAssertEqual(chat.calls.count, 3)
    }

    func testLessReverbIsRefusedWithoutReverbAndSendsNothing() async throws {
        let dry = try parsed(recipe(reverbLevel: nil))
        XCTAssertNotNil(SoundAI.Adjustment.lessReverb.impossibility(for: dry))
        let chat = ScriptedChat([recipe()])
        do {
            _ = try await SoundAI.refine(dry, .lessReverb, request: "Rock", chat: chat.chat)
            XCTFail("expected .notPossible")
        } catch {
            guard case SoundAI.Error.notPossible = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(chat.calls.count, 0)
    }

    func testAdjustmentDirections() throws {
        let base = try parsed(recipe(gain: 5, treble: 6, reverbLevel: 3))
        XCTAssertTrue(SoundAI.Adjustment.warmer.isApplied(from: base, to: try parsed(recipe(gain: 5, treble: 4.5))))
        XCTAssertFalse(SoundAI.Adjustment.warmer.isApplied(from: base, to: try parsed(recipe(gain: 5, treble: 7))))
        XCTAssertTrue(SoundAI.Adjustment.brighter.isApplied(from: base, to: try parsed(recipe(gain: 5, treble: 7))))
        XCTAssertTrue(SoundAI.Adjustment.moreGain.isApplied(from: base, to: try parsed(recipe(gain: 6.5))))
        XCTAssertTrue(SoundAI.Adjustment.moreGain.isApplied(
            from: base, to: try parsed(recipe(gain: 5, drive: "DistortionTS9"))))
        XCTAssertFalse(SoundAI.Adjustment.moreGain.isApplied(from: base, to: try parsed(recipe(gain: 5))))
        XCTAssertTrue(SoundAI.Adjustment.lessReverb.isApplied(from: base, to: try parsed(recipe(reverbLevel: 1.5))))
        XCTAssertTrue(SoundAI.Adjustment.lessReverb.isApplied(from: base, to: try parsed(recipe(reverbLevel: nil))))
        XCTAssertFalse(SoundAI.Adjustment.lessReverb.isApplied(from: base, to: try parsed(recipe(reverbLevel: 3))))
    }

    func testNudgedRecipesStillRead() throws {
        let base = try parsed(recipe(gain: 9.5, treble: 1, reverbLevel: 1))
        for adjustment in SoundAI.Adjustment.allCases {
            let nudged = adjustment.nudged(base)
            XCTAssertNoThrow(try nudged.preset(), adjustment.label)
            XCTAssertTrue(adjustment.isApplied(from: base, to: nudged), adjustment.label)
        }
        XCTAssertEqual(SoundAI.Adjustment.moreGain.nudged(base).chain["amp"]?.settings["gain"], .number(10))
        XCTAssertEqual(SoundAI.Adjustment.lessReverb.nudged(base).chain["reverb"]?.on, false)
    }

    // MARK: HTTP client

    func testRequestCarriesOnlyTheChatAndAGenericAgent() throws {
        let messages = [OllamaChatMessage(role: "user", content: "Blues")]
        let request = try OllamaCloud.makeRequest(model: "gpt-oss:120b", apiKey: " key ", messages: messages,
                                                  temperature: 0.3)
        XCTAssertEqual(request.url, OllamaCloud.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "SparkStudio")
        XCTAssertEqual(request.timeoutInterval, OllamaCloud.requestTimeout)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "messages", "stream", "format", "options"])
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertFalse(String(data: request.httpBody!, encoding: .utf8)!.contains("key"), "the key stays in the header")
    }

    func testMissingKeySendsNothing() async {
        let transport = ScriptedTransport([ok("x")])
        do {
            _ = try await OllamaCloud.complete(model: "m", apiKey: "  ", messages: [], transport: transport.transport)
            XCTFail("expected .missingAPIKey")
        } catch {
            XCTAssertEqual(error as? OllamaCloud.Error, .missingAPIKey)
        }
        XCTAssertEqual(transport.count, 0)
    }

    func testABusyServerIsAskedAgain() async throws {
        let transport = ScriptedTransport([.status(503, "{\"error\":\"overloaded\"}"), .status(429, ""), ok("fertig")])
        let answer = try await OllamaCloud.complete(model: "m", apiKey: "k", messages: [],
                                                    transport: transport.transport, retry: Retry(delays: [0, 0]))
        XCTAssertEqual(answer, "fertig")
        XCTAssertEqual(transport.count, 3)
    }

    func testALostConnectionIsAskedAgainThenReported() async {
        let lost = ScriptedTransport.Step.failure(URLError(.networkConnectionLost))
        let transport = ScriptedTransport([lost, lost, lost, ok("zu spät")])
        do {
            _ = try await OllamaCloud.complete(model: "m", apiKey: "k", messages: [], transport: transport.transport,
                                               retry: Retry(delays: [0, 0]))
            XCTFail("expected .transport")
        } catch {
            guard case OllamaCloud.Error.transport = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(transport.count, 3)
    }

    func testAWrongKeyOrModelIsNotRepeated() async {
        for (status, expected) in [(401, OllamaCloud.Error.unauthorized), (404, .modelNotFound("m"))] {
            let transport = ScriptedTransport([.status(status, "{\"error\":\"nope\"}"), ok("x")])
            do {
                _ = try await OllamaCloud.complete(model: "m", apiKey: "k", messages: [],
                                                   transport: transport.transport, retry: Retry(delays: [0, 0]))
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? OllamaCloud.Error, expected)
            }
            XCTAssertEqual(transport.count, 1)
        }
    }

    func testATimeoutIsReportedAsSuch() async {
        let transport = ScriptedTransport([.failure(URLError(.timedOut)), ok("x")])
        do {
            _ = try await OllamaCloud.complete(model: "m", apiKey: "k", messages: [], transport: transport.transport,
                                               retry: Retry(delays: [0, 0]))
            XCTFail("expected .timeout")
        } catch {
            XCTAssertEqual(error as? OllamaCloud.Error, .timeout)
            XCTAssertTrue(error.localizedDescription.contains("Zeitlimit"))
        }
        XCTAssertEqual(transport.count, 1)
    }

    func testACancelledRequestEndsAsCancellation() async {
        let transport = ScriptedTransport([.failure(URLError(.cancelled))])
        do {
            _ = try await OllamaCloud.complete(model: "m", apiKey: "k", messages: [], transport: transport.transport)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testAnEmptyOrBrokenAnswerIsReported() async {
        for (step, expected) in [(ok("  "), OllamaCloud.Error.noContent),
                                 (.status(200, "<html>"), .unreadableResponse)] as [(ScriptedTransport.Step, OllamaCloud.Error)] {
            let transport = ScriptedTransport([step])
            do {
                _ = try await OllamaCloud.complete(model: "m", apiKey: "k", messages: [],
                                                   transport: transport.transport, retry: .none)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? OllamaCloud.Error, expected)
            }
        }
    }
}

private typealias Retry = OllamaCloud.Retry
