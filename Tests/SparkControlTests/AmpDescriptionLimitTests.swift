import XCTest
@testable import SparkControl

/// A preset with a 136-byte description made the amp howl at full volume on 2026-11-08. Nothing longer than
/// `PresetRules.descriptionLimit` may reach it, whichever way the preset was made.
final class AmpDescriptionLimitTests: XCTestCase {
    private let long = "KI-Sound: „U2 - where the streets have no name.“. "
        + "Originalgetreuer The-Edge-Sound: glänzender Vox-Clean mit punktiertem Achtel-Echo"

    private func preset(description: String) -> SparkPreset {
        SparkPreset(name: "Joshua Tree Echo", description: description,
                    effects: ChainPlace.allCases.map { PresetFactory.effect(SoundRecipe.fallbackModels[$0]!, on: false) })
    }

    /// The description as it arrives in the payload the amp gets.
    private func sentDescription(_ preset: SparkPreset, to place: SparkPresetPlace) throws -> SparkPreset {
        let blocks = SparkProtocol.sendPreset(preset, to: place, sequence: 1, header: false)
        let parser = SparkProtocol.Parser()
        let messages = parser.feed(blocks.flatMap { $0 })
        let message = try XCTUnwrap(messages.last)
        return try SparkPreset(payload: message.payload)
    }

    func testTheHowlingDescriptionIsCutBeforeItIsSent() throws {
        XCTAssertEqual(long.utf8.count, 136)
        for place in [SparkPresetPlace.temporary, .slot(0)] {
            let sent = try sentDescription(preset(description: long), to: place)
            XCTAssertLessThanOrEqual(sent.description.utf8.count, PresetRules.descriptionLimit)
            XCTAssertTrue(long.hasPrefix(sent.description))
            let expected = PresetRules.forAmp(preset(description: long))
            XCTAssertEqual(sent.description, expected.description)
            XCTAssertEqual(sent.effects, expected.effects)
        }
    }

    func testAShortDescriptionGoesUnchanged() throws {
        XCTAssertEqual(PresetRules.fitDescription("1-Clean"), "1-Clean")
        XCTAssertEqual(try sentDescription(preset(description: "1-Clean"), to: .temporary).description, "1-Clean")
        XCTAssertEqual(try sentDescription(preset(description: ""), to: .temporary).description, "")
    }

    func testTheCutKeepsWholeCharacters() {
        let umlauts = String(repeating: "ä", count: 100)
        let fitted = PresetRules.fitDescription(umlauts)
        XCTAssertEqual(fitted.utf8.count, PresetRules.descriptionLimit)
        XCTAssertEqual(fitted, String(repeating: "ä", count: PresetRules.descriptionLimit / 2))
    }

    func testTheEditorCutsATypedDescription() {
        var editor = PresetEditor(preset(description: ""))
        editor.setDescription(long)
        XCTAssertLessThanOrEqual(editor.current.description.utf8.count, PresetRules.descriptionLimit)
    }

    func testARecipeWithALongDescriptionWarnsAndFits() throws {
        let recipe = SoundRecipe(name: "Joshua Tree Echo", description: long, bpm: 168, tags: [], notes: "",
                                 chain: ["amp": .init(model: "AC Boost", on: true, settings: ["gain": .number(4)])])
        let conversion = try recipe.preset()
        XCTAssertLessThanOrEqual(conversion.preset.description.utf8.count, PresetRules.descriptionLimit)
        XCTAssertTrue(conversion.warnings.contains { $0.contains("description") })
    }
}
