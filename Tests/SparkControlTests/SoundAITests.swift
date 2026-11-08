import XCTest
@testable import SparkControl

/// The prompt and parser for KI-Sound: pure, no network. The HTTP call in `OllamaCloud` is not tested here.
final class SoundAITests: XCTestCase {

    private func recipeJSON(_ chain: String = "\"amp\": { \"model\": \"Twin\", \"settings\": { \"gain\": 3 } }",
                            name: String = "Test") -> String {
        """
        {
          "format": "spark-sound-recipe",
          "version": 1,
          "name": "\(name)",
          "bpm": 120,
          "chain": { \(chain) }
        }
        """
    }

    func testParseReadsAValidRecipe() throws {
        let recipe = try SoundAI.parse(recipeJSON())
        XCTAssertEqual(recipe.name, "Test")
        XCTAssertEqual(recipe.chain["amp"]?.model, "Twin")
    }

    func testParseToleratesACodeFence() throws {
        let fenced = "```json\n" + recipeJSON() + "\n```"
        let recipe = try SoundAI.parse(fenced)
        XCTAssertEqual(recipe.chain["amp"]?.model, "Twin")
    }

    func testParseRejectsAnUnknownModel() {
        let json = recipeJSON("\"amp\": { \"model\": \"NichtDa\", \"settings\": {} }")
        XCTAssertThrowsError(try SoundAI.parse(json)) { error in
            guard case SoundAI.Error.invalid(let message) = error else {
                return XCTFail("expected .invalid, got \(error)")
            }
            XCTAssertTrue(message.contains("NichtDa"), message)
        }
    }

    func testParseRejectsAWrongOptionLabel() {
        let json = recipeJSON("\"reverb\": { \"model\": \"bias.reverb\", \"settings\": { \"type\": \"Falscher Raum\" } }")
        XCTAssertThrowsError(try SoundAI.parse(json)) { error in
            guard case SoundAI.Error.invalid(let message) = error else {
                return XCTFail("expected .invalid, got \(error)")
            }
            XCTAssertTrue(message.contains("Falscher Raum"), message)
            XCTAssertTrue(message.contains("keine Auswahl"), message)
        }
    }

    func testParseRejectsNonJSON() {
        XCTAssertThrowsError(try SoundAI.parse("Ich bin kein JSON.")) { error in
            guard case SoundAI.Error.noJSON = error else { return XCTFail("expected .noJSON, got \(error)") }
        }
    }

    func testCatalogTextNamesEveryModel() {
        let catalog = CatalogReference()
        let text = SoundAI.catalogText(catalog)
        for model in catalog.models {
            XCTAssertTrue(text.contains(model.id), "missing \(model.id)")
        }
    }

    func testMessagesCarryTheRequestAndTheCatalog() {
        let messages = SoundAI.messages(request: "Blues für meine Tele", catalog: CatalogReference())
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "system")
        XCTAssertTrue(messages[0].content.contains("spark-sound-recipe"))
        XCTAssertTrue(messages[0].content.contains("Twin"), "catalog should name the Twin amp")
        XCTAssertEqual(messages[1].role, "user")
        XCTAssertTrue(messages[1].content.contains("Blues für meine Tele"))
    }

    func testAddRecipeWritesAReadableRecipe() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("spark-ai-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let library = PresetLibrary(folder: folder)
        let recipe = SoundRecipe(name: "Test", bpm: 120, chain: [
            "amp": .init(model: "Twin", settings: ["gain": .number(3)]),
        ])
        let url = try library.addRecipe(recipe)
        try library.reload()
        XCTAssertEqual(library.unreadable, [])
        XCTAssertEqual(library.items.count, 1)
        let item = library.items.first { $0.url.lastPathComponent == url.lastPathComponent }
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.isRecipe, true)
        XCTAssertEqual(item?.name, "Test")
    }
}
