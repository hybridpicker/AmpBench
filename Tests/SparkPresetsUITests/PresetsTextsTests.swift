import AmpText
import XCTest
@testable import SparkPresetsUI

/// The texts of the area Presets in both languages, and the API key's move to its new name in the Keychain.
@MainActor
final class PresetsTextsTests: XCTestCase {
    override func tearDown() {
        Texts.language = .english
        super.tearDown()
    }

    func testTextsAreEnglishByDefault() {
        XCTAssertEqual(DeviceChoice.word(.nearby), "nearby")
        XCTAssertEqual(LinkError.notConnected.errorDescription, "The amp is not connected.")
        XCTAssertEqual(LinkError.verifyFailed("Crunch").errorDescription,
                       "When read back, the slot did not hold “Crunch”. The backup is in the library.")
    }

    func testGermanStillWorks() {
        Texts.language = .german
        XCTAssertEqual(DeviceChoice.word(.nearby), "in der Nähe")
        XCTAssertEqual(LinkError.notConnected.errorDescription, "Der Verstärker ist nicht verbunden.")
        XCTAssertEqual(LinkError.verifyFailed("Crunch").errorDescription,
                       "Beim Zurücklesen enthielt der Platz nicht „Crunch“. Die Sicherung liegt in der Bibliothek.")
        XCTAssertEqual(LinkError.notAllowed("REACTOR 50").errorDescription,
                       "An REACTOR 50 sendet AmpBench nichts. Er wird nur mitgelesen.")
    }

    // MARK: The API key's entry

    /// A stand-in for the Keychain with made-up values.
    private final class FakeEntries: KeyEntries {
        var entries: [String: String]
        init(_ entries: [String: String]) { self.entries = entries }
        func value(service: String) -> String? { entries[service] }
        func store(_ value: String, service: String) { entries[service] = value }
    }

    func testKeyIsCarriedOverFromSparkStudioOnce() {
        let entries = FakeEntries([AIKeyStore.earlierService: " made-up-value \n"])
        XCTAssertTrue(AIKeyStore.carryOverFromSparkStudio(in: entries))
        XCTAssertEqual(entries.entries[AIKeyStore.service], "made-up-value")
        XCTAssertEqual(entries.entries[AIKeyStore.earlierService], " made-up-value \n", "the earlier entry stays")
        XCTAssertFalse(AIKeyStore.carryOverFromSparkStudio(in: entries), "only once")
    }

    func testAnExistingKeyIsNeverReplaced() {
        let entries = FakeEntries([AIKeyStore.service: "new-made-up", AIKeyStore.earlierService: "old-made-up"])
        XCTAssertFalse(AIKeyStore.carryOverFromSparkStudio(in: entries))
        XCTAssertEqual(entries.entries[AIKeyStore.service], "new-made-up")
    }

    func testNothingIsCarriedOverWithoutAnEarlierKey() {
        let none = FakeEntries([:])
        XCTAssertFalse(AIKeyStore.carryOverFromSparkStudio(in: none))
        XCTAssertNil(none.entries[AIKeyStore.service])
        let empty = FakeEntries([AIKeyStore.earlierService: "  "])
        XCTAssertFalse(AIKeyStore.carryOverFromSparkStudio(in: empty))
        XCTAssertNil(empty.entries[AIKeyStore.service])
    }

    func testTheEntryNamesStay() {
        XCTAssertEqual(AIKeyStore.service, "AmpBench Ollama API Key")
        XCTAssertEqual(AIKeyStore.earlierService, "Spark Studio Ollama API Key")
    }
}
