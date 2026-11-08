import XCTest
@testable import SparkControl

/// Sound recipes and the catalog reference. Made-up sounds only.
final class SoundRecipeTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func recipe(_ chain: [String: SoundRecipe.Unit], name: String = "Test") -> SoundRecipe {
        SoundRecipe(name: name, bpm: 100, chain: chain)
    }

    func testEveryParameterHasAKeyOfItsOwn() {
        for model in ModelCatalog.all {
            let keys = model.settableParameters.map(\.info.key)
            XCTAssertEqual(Set(keys).count, keys.count, "\(model.id): \(keys)")
            XCTAssertTrue(keys.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } },
                          "\(model.id): \(keys)")
        }
        XCTAssertEqual(ModelCatalog.known("Tremolator")!.settableParameters.map(\.info.key), ["depth", "speed", "sync"])
        XCTAssertEqual(ModelCatalog.known("GuitarEQ6")!.settableParameters.map(\.info.key),
                       ["level", "hz100", "hz200", "hz400", "hz800", "hz1600", "hz3200"])
        XCTAssertEqual(ModelCatalog.known("MiniVibe")!.settableParameters.map(\.info.key),
                       ["speed", "intensity", "knob3", "knob4"])
    }

    func testARecipeBecomesTheSevenPlaceChain() throws {
        let conversion = try recipe([
            "amp": .init(model: "Plexi", settings: ["gain": .number(6.5), "master": .number(7)]),
            "reverb": .init(model: "bias.reverb", settings: ["type": .text("Saal weit"), "level": .number(2)]),
            "delay": .init(model: "DelayMono", on: false),
        ]).preset()
        let preset = conversion.preset
        XCTAssertEqual(conversion.warnings, [])
        XCTAssertEqual(preset.effects.map(\.name),
                       ["bias.noisegate", "BlueComp", "DistortionTS9", "Plexi", "ChorusAnalog", "DelayMono", "bias.reverb"])
        XCTAssertEqual(preset.effects.map(\.isOn), [false, false, false, true, false, false, true])
        let amp = preset.effects[3].parameters.map(\.value)
        XCTAssertEqual(amp[0], 0.65, accuracy: 0.0001)
        XCTAssertEqual(amp[4], 0.7, accuracy: 0.0001)
        // Keys left out keep the amp's start values.
        XCTAssertEqual(Array(amp[1...3]), Array(ModelCatalog.known("Plexi")!.defaults[1...3]))
        let reverb = preset.effects[6].parameters.map(\.value)
        XCTAssertEqual(reverb[6], 0.5)
        XCTAssertEqual(reverb[7], 1, "The mirror follows on and off.")
        XCTAssertEqual(preset.bpm, 100)
        XCTAssertTrue(preset.hasChecksum)
        XCTAssertNoThrow(try SparkPreset(payload: preset.encode(place: .temporary)))
    }

    func testSwitchesTakeFlagsOrLabels() throws {
        let preset = try recipe([
            "delay": .init(model: "DelayMono", settings: ["sync": .text("Frei"), "range": .text("1 s")]),
            "compressor": .init(model: "BBEOpticalComp", settings: ["pad": .flag(true)]),
        ]).preset().preset
        XCTAssertEqual(preset.effects[5].parameters[4].value, 0)
        XCTAssertEqual(preset.effects[5].parameters[3].value, 0.72)
        XCTAssertEqual(preset.effects[1].parameters[2].value, 1)
    }

    func testEveryMistakeIsNamedAtOnce() {
        let bad = recipe([
            "amp": .init(model: "twin", settings: [:]),
            "drive": .init(model: "Plexi"),
            "delay": .init(model: "DelayMono", settings: ["gain": .number(3), "sync": .number(1)]),
            "reverb": .init(model: "bias.reverb", settings: ["type": .text("Kathedrale"), "level": .text("laut")]),
            "wah": .init(model: "JH.Vox846"),
        ], name: " ")
        XCTAssertThrowsError(try bad.preset()) { error in
            let messages = (error as? SoundRecipe.Problems)?.messages ?? []
            XCTAssertEqual(messages.count, 8, messages.joined(separator: "\n"))
            XCTAssertTrue(messages.contains { $0.contains("„twin“ gibt es nicht") })
            XCTAssertTrue(messages.contains { $0.contains("gehört an den Platz amp") })
            XCTAssertTrue(messages.contains { $0.contains("„wah“ ist kein Platz") })
            XCTAssertTrue(messages.contains { $0.contains("„Kathedrale“ ist keine Auswahl") })
        }
    }

    func testSmallThingsAreCorrectedAndSaid() throws {
        var long = recipe(["amp": .init(model: "Twin", settings: ["gain": .number(12)]),
                           "compressor": .init(model: "JH.Vox846")],
                          name: "Ein sehr langer Name für ein Preset")
        long.bpm = 300
        let conversion = try long.preset()
        XCTAssertEqual(conversion.preset.effects[3].parameters[0].value, 1)
        XCTAssertEqual(conversion.preset.bpm, 250)
        XCTAssertLessThanOrEqual(conversion.preset.name.utf8.count, PresetRules.nameLimit)
        XCTAssertEqual(conversion.warnings.count, 4, conversion.warnings.joined(separator: "\n"))
    }

    func testTheSameFileGivesTheSameUUID() throws {
        let data = Data("same bytes".utf8)
        let first = SoundRecipe.uuid(for: data)
        XCTAssertEqual(first, SoundRecipe.uuid(for: data))
        XCTAssertNotEqual(first, SoundRecipe.uuid(for: Data("other".utf8)))
        XCTAssertNotNil(UUID(uuidString: first))
    }

    func testAPresetBecomesARecipeAndBack() throws {
        let original = PresetFactory.templates.first { $0.name == "Ambient" }!.preset
        let recipe = try SoundRecipe(preset: original, tags: ["Ambient"])
        let decoded = try XCTUnwrap(SoundRecipe.decodeIfRecipe(recipe.jsonData()))
        XCTAssertEqual(decoded, recipe)
        let back = try decoded.preset().preset
        XCTAssertEqual(back.effects.map(\.name), original.effects.map(\.name))
        XCTAssertEqual(back.effects.map(\.isOn), original.effects.map(\.isOn))
        for (a, b) in zip(back.effects, original.effects) {
            for (x, y) in zip(a.parameters, b.parameters) {
                XCTAssertEqual(x.value, y.value, accuracy: 0.051, "\(a.name) \(x.index)")
            }
        }
    }

    func testOtherJSONIsNoRecipe() throws {
        XCTAssertNil(try SoundRecipe.decodeIfRecipe(Data(#"{"format": 2, "preset": {}}"#.utf8)))
        XCTAssertNil(try SoundRecipe.decodeIfRecipe(Data("not json".utf8)))
    }

    func testTheLibraryReadsRecipesAndListsBrokenOnes() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("spark-recipes-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var good = recipe(["amp": .init(model: "Plexi")], name: "Rezept")
        good.tags = ["Rock"]
        try good.jsonData().write(to: folder.appendingPathComponent("rezept.json"))
        try recipe(["amp": .init(model: "Nope")], name: "Kaputt").jsonData()
            .write(to: folder.appendingPathComponent("kaputt.json"))
        let library = PresetLibrary(folder: folder)
        try library.reload()
        XCTAssertEqual(library.items.map(\.name), ["Rezept"])
        XCTAssertTrue(library.items[0].isRecipe)
        XCTAssertEqual(library.items[0].file.tags, ["Rock"])
        XCTAssertEqual(library.unreadable, ["kaputt.json"])
        let uuid = library.items[0].file.preset.uuid
        try library.reload()
        XCTAssertEqual(library.items[0].file.preset.uuid, uuid, "Reading again keeps the identity.")
        // Saving writes an ordinary preset file in its place.
        let saved = try library.replace(library.items[0], with: library.items[0].file.preset)
        XCTAssertFalse(saved.isRecipe)
        XCTAssertNoThrow(try PresetFile.read(Data(contentsOf: saved.url)))
        try library.reload()
        XCTAssertEqual(library.items.map(\.isRecipe), [false])
        XCTAssertEqual(library.items.map(\.name), ["Rezept"])
    }

    func testTheExamplesInTheDocsAreValid() throws {
        let folder = root.appendingPathComponent("docs/ai/examples")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThanOrEqual(files.count, 4)
        for file in files {
            let data = try Data(contentsOf: file)
            let recipe = try XCTUnwrap(SoundRecipe.decodeIfRecipe(data), file.lastPathComponent)
            let conversion = try recipe.preset(identity: data)
            XCTAssertEqual(conversion.warnings, [], file.lastPathComponent)
            XCTAssertFalse(conversion.preset.effects.contains { ModelCatalog.known($0.name)?.isPack == true })
        }
    }

    func testTheCatalogInTheDocsIsUpToDate() throws {
        let reference = CatalogReference()
        let folder = root.appendingPathComponent("docs/ai")
        let json = try Data(contentsOf: folder.appendingPathComponent("spark-catalog.json"))
        let markdown = try String(contentsOf: folder.appendingPathComponent("spark-catalog.md"), encoding: .utf8)
        let hint = "docs/ai is behind the catalog. Run: swift run SparkStudio --catalog-export docs/ai"
        XCTAssertEqual(json, try reference.jsonData(), hint)
        XCTAssertEqual(markdown, reference.markdown(), hint)
        XCTAssertEqual(reference.models.count, ModelCatalog.all.count)
        XCTAssertEqual(try JSONDecoder().decode(CatalogReference.self, from: json), reference)
    }
}
