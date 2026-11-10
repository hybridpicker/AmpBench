import AmpText
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
            XCTAssertTrue(messages.contains { $0.contains("There is no model “twin”") })
            XCTAssertTrue(messages.contains { $0.contains("belongs in the place amp") })
            XCTAssertTrue(messages.contains { $0.contains("“wah” is no place") })
            XCTAssertTrue(messages.contains { $0.contains("“Kathedrale” is no choice") })
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

    /// Recipes written when the catalog was German name switches and choices in German. Both languages read, in
    /// either language of the app, and a recipe is always written with the English labels.
    func testLabelsReadInEnglishAndGermanAndAreWrittenInEnglish() throws {
        func preset(_ type: String, _ sync: String) throws -> [SparkPreset.Effect] {
            try recipe([
                "delay": .init(model: "DelayMono", settings: ["sync": .text(sync)]),
                "reverb": .init(model: "bias.reverb", settings: ["type": .text(type)]),
            ]).preset().preset.effects
        }
        let english = try preset("Wide hall", "Free")
        XCTAssertEqual(english[6].parameters[6].value, 0.5)
        XCTAssertEqual(english[5].parameters[4].value, 0)
        XCTAssertEqual(try preset("Saal weit", "Frei"), english)
        let sound = SparkPreset(name: "Test", effects: english)
        XCTAssertEqual(try SoundRecipe(preset: sound).chain["reverb"]?.settings["type"], .text("Wide hall"))
        Texts.language = .german
        defer { Texts.language = .english }
        XCTAssertEqual(try preset("Wide hall", "Free"), english)
        XCTAssertEqual(try preset("saal weit", "frei"), english)
        let written = try SoundRecipe(preset: sound)
        XCTAssertEqual(written.chain["reverb"]?.settings["type"], .text("Wide hall"))
        XCTAssertEqual(written.chain["delay"]?.settings["sync"], .text("Free"))
        XCTAssertThrowsError(try preset("Kathedrale", "Frei")) { error in
            XCTAssertTrue(error.localizedDescription.contains("„Kathedrale“ ist keine Auswahl"), error.localizedDescription)
        }
    }

    /// The files in docs/ai are the same on every machine: English, with the German beside it.
    func testTheCatalogExportDoesNotFollowTheLanguage() throws {
        let english = CatalogReference()
        Texts.language = .german
        defer { Texts.language = .english }
        let german = CatalogReference()
        XCTAssertEqual(try german.jsonData(), try english.jsonData())
        XCTAssertEqual(german.markdown(), english.markdown())
        let reverb = try XCTUnwrap(german.models.first { $0.id == "bias.reverb" })
        XCTAssertEqual(reverb.name, "Reverb")
        XCTAssertEqual(reverb.de?.name, "Hall")
        XCTAssertEqual(reverb.de?.summary, "Raum, Kammer, Saal oder Platte")
        let type = try XCTUnwrap(reverb.parameters.first { $0.key == "type" })
        XCTAssertEqual(type.label, "Type")
        XCTAssertEqual(type.de?.label, "Typ")
        XCTAssertEqual(type.start, .text("Natural hall"))
        XCTAssertEqual(type.options?.map(\.label).prefix(2), ["Room A", "Room B"])
        XCTAssertEqual(type.options?.compactMap(\.de?.label).prefix(2), ["Raum A", "Raum B"])
        let sync = try XCTUnwrap(german.models.first { $0.id == "DelayMono" }?.parameters.first { $0.key == "sync" })
        XCTAssertEqual([sync.off, sync.on, sync.de?.off, sync.de?.on], ["Free", "BPM", "Frei", "BPM"])
        XCTAssertEqual(german.places.map(\.de?.title),
                       ["Noise Gate", "Kompressor", "Verzerrer", "Amp", "Modulation", "Delay", "Hall"])
        XCTAssertEqual(german.groups?.map(\.de?.title),
                       ["Clean", "Brillant", "Crunch", "High Gain", "Metal", "Akustik", "Bass"])
    }

    func testTheCatalogInTheDocsIsUpToDate() throws {
        let reference = CatalogReference()
        let folder = root.appendingPathComponent("docs/ai")
        let json = try Data(contentsOf: folder.appendingPathComponent("spark-catalog.json"))
        let markdown = try String(contentsOf: folder.appendingPathComponent("spark-catalog.md"), encoding: .utf8)
        let hint = "docs/ai is behind the catalog. Run: swift run AmpBench --catalog-export docs/ai"
        XCTAssertEqual(json, try reference.jsonData(), hint)
        XCTAssertEqual(markdown, reference.markdown(), hint)
        XCTAssertEqual(reference.models.count, ModelCatalog.all.count)
        XCTAssertEqual(try JSONDecoder().decode(CatalogReference.self, from: json), reference)
    }
}

/// The English description for devices that take a text prompt, such as REACTOR's Text to Tone.
final class ToneDescriptionTests: XCTestCase {
    func testTheDescriptionNamesModelsAndValues() throws {
        var recipe = SoundRecipe(name: "Blues", description: "Pushed tweed", bpm: 96, notes: "Lower the drive first.",
                                 chain: [
            "drive": .init(model: "DistortionTS9", settings: ["drive": .number(3)]),
            "amp": .init(model: "Bassman", settings: ["gain": .number(5)]),
            "delay": .init(model: "DelayMono", on: false),
            "reverb": .init(model: "bias.reverb", settings: ["type": .text("Saal weit"), "level": .number(2.5)]),
        ])
        let text = try recipe.toneDescription()
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Guitar tone \u{201C}Blues: Pushed tweed\u{201D}, 96 BPM.")
        XCTAssertTrue(lines.contains("Drive pedal: Ibanez TS9 style pedal, drive 3/10."), text)
        // All five amp knobs, because another device does not know the Spark's start values.
        XCTAssertTrue(lines.contains { $0.hasPrefix("Amp: Fender Bassman ’59 style amp, gain 5/10, treble ") && $0.contains("master ") }, text)
        XCTAssertTrue(lines.contains("Reverb: large hall reverb, level 2.5/10."), text)
        XCTAssertFalse(text.contains("Delay"), "Units that are off are left out.")
        XCTAssertEqual(lines.last, "Notes: Lower the drive first.")
        recipe.chain = ["delay": .init(model: "DelayMono", settings: ["sync": .flag(true)])]
        XCTAssertTrue(try recipe.toneDescription().contains("Delay: Boss DD-3 style, synced to tempo."))
    }

    func testABrokenRecipeHasNoDescription() {
        let recipe = SoundRecipe(name: "X", chain: ["amp": .init(model: "Nope")])
        XCTAssertThrowsError(try recipe.toneDescription())
    }
}
