import Foundation
import SQLite3
import XCTest
@testable import SparkControl

/// Kemper files built here from scratch, never real ones: rigs as SysEx frames, backups as tar archives with a
/// performance database.
enum KemperFixture {
    static func varLength(_ value: Int) -> [UInt8] {
        var bytes = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            bytes.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return bytes
    }

    static func event(_ body: [UInt8]) -> [UInt8] { [0x00, 0xF0] + varLength(body.count) + body }

    static func string(_ tag: Int, _ text: String) -> [UInt8] {
        event([0x00, 0x20, 0x33, 0x00, 0x00, 0x03, 0x00, 0x00, UInt8(tag)] + Array(text.utf8) + [0x00, 0xF7])
    }

    static func parameters(page: Int, first: Int, _ values: [Int]) -> [UInt8] {
        event([0x00, 0x20, 0x33, 0x00, 0x00, 0x02, 0x00, UInt8(page), UInt8(first)]
              + values.flatMap { [UInt8($0 >> 7 & 0x7F), UInt8($0 & 0x7F)] } + [0xF7])
    }

    /// A rig's events: names, amp gain and equalizer (−5…+5), and effect modules (page, type, on).
    static func rigEvents(name: String, amp: String? = nil, maker: String? = nil, model: String? = nil,
                          gain: Double = 5, eq: [Double] = [0, 0, 0, 0],
                          modules: [(page: Int, type: Int, on: Bool)] = [], tempo: Int? = nil) -> [UInt8] {
        var events = string(1, name)
        if let amp { events += string(16, amp) }
        if let maker { events += string(21, maker) }
        if let model { events += string(24, model) }
        events += parameters(page: 10, first: 2, [1, 8192, Int(gain / 10 * 16383)])
        events += parameters(page: 11, first: 4, eq.map { 8192 + Int($0 / 5 * 8192) })
        for module in modules {
            events += parameters(page: module.page, first: 0, [module.type, 0, 1, module.on ? 1 : 0, 8192])
        }
        if let tempo { events += parameters(page: 4, first: 0, [tempo * 64, 0, 1]) }
        return events
    }

    static func rigFile(_ events: [UInt8], header: String = "KThd") -> Data {
        var bytes = Array(header.utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
        bytes += Array("KTrk".utf8) + withUnsafeBytes(of: UInt32(events.count).bigEndian, Array.init) + events
        return Data(bytes)
    }

    /// A performance's header: its name (index 0) and slot names (1 to 5), function 07.
    static func performanceHeader(_ name: String, slots: [String] = []) -> Data {
        Data(([name] + slots).enumerated().flatMap { index, text in
            event([0x00, 0x20, 0x33, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x01, 0x00, UInt8(index)] + Array(text.utf8)
                  + [0x00, 0xF7])
        })
    }

    /// A repository.kdb with the Kemper's four tables.
    static func database(_ performances: [(name: String, slots: [[UInt8]])], slotNames: [String] = []) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).kdb")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw KemperReadError.damaged("fixture") }
        defer { sqlite3_close(db) }
        func run(_ sql: String, _ blobs: [Data] = [], _ numbers: [Int64] = []) {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            var index: Int32 = 1
            for number in numbers { sqlite3_bind_int64(statement, index, number); index += 1 }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for blob in blobs {
                _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(blob.count), transient) }
                index += 1
            }
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        run("CREATE TABLE perflist (id INTEGER PRIMARY KEY AUTOINCREMENT, perfid INTEGER)")
        run("CREATE TABLE perfs (id INTEGER PRIMARY KEY AUTOINCREMENT, perfdata BLOB)")
        run("CREATE TABLE perfslots (id INTEGER PRIMARY KEY AUTOINCREMENT, perfid INTEGER NOT NULL, slot INTEGER, trackid INTEGER NOT NULL UNIQUE)")
        run("CREATE TABLE perftracks (id INTEGER PRIMARY KEY AUTOINCREMENT, track BLOB)")
        var track: Int64 = 0
        for (position, performance) in performances.enumerated() {
            let id = Int64(position + 1)
            run("INSERT INTO perfs (id, perfdata) VALUES (?, ?)",
                [performanceHeader(performance.name, slots: slotNames)], [id])
            run("INSERT INTO perflist (perfid) VALUES (?)", [], [id])
            for (slot, events) in performance.slots.enumerated() {
                track += 1
                run("INSERT INTO perftracks (id, track) VALUES (?, ?)", [Data(events)], [track])
                run("INSERT INTO perfslots (perfid, slot, trackid) VALUES (?, ?, ?)", [], [id, Int64(slot), track])
            }
        }
        return try Data(contentsOf: url)
    }

    /// A tar archive in ustar form.
    static func tar(_ files: [(String, Data)]) -> Data {
        var archive = Data()
        for (name, content) in files {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at offset: Int) { for (i, b) in text.utf8.enumerated() { header[offset + i] = b } }
            put(name, at: 0)
            put("0000644", at: 100)
            put(String(format: "%011o", content.count), at: 124)
            header[156] = UInt8(ascii: "0")
            put("ustar", at: 257)
            put("        ", at: 148)
            put(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", at: 148)
            archive.append(contentsOf: header)
            archive.append(content)
            archive.append(Data(count: (512 - content.count % 512) % 512))
        }
        archive.append(Data(count: 1024))
        return archive
    }

    /// The Kemper's own placeholder that fills a new performance.
    static let placeholder = string(1, "Crunch") + string(16, "Crunch Amp") + string(18, "AmpCreationDateTag")
        + parameters(page: 10, first: 4, [8192])
}

final class KemperReaderTests: XCTestCase {
    func testReadsARigFile() throws {
        let events = KemperFixture.rigEvents(name: "Plexi Rock", amp: "JMP 50", maker: "Marshall", model: "50w JMP",
                                             gain: 7, eq: [-1, 2, 0.5, 1], modules: [(50, 49, true), (60, 145, false)],
                                             tempo: 96)
        for header in ["KThd", "MThd"] {
            let rig = try KemperReader.rigFile(KemperFixture.rigFile(events, header: header))
            XCTAssertEqual(rig.name, "Plexi Rock")
            XCTAssertEqual(rig.ampDescription, "Marshall 50w JMP JMP 50")
            XCTAssertEqual(rig.gain, 7)
            XCTAssertEqual(rig.equalizer.bass, -1)
            XCTAssertEqual(rig.equalizer.middle, 2)
            XCTAssertEqual(rig.tempo, 96)
            XCTAssertEqual(rig.modules.map(\.typeName), ["Compressor", "Legacy Delay"])
            XCTAssertEqual(rig.modules.map(\.isOn), [true, false])
            XCTAssertFalse(rig.isPlaceholder)
        }
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try KemperReader.rigFile(Data("not a rig at all".utf8)))
        XCTAssertThrowsError(try KemperLibrary.read(URL(fileURLWithPath: "/tmp/sound.json")))
    }

    func testPlaceholderIsRecognized() {
        XCTAssertTrue(KemperReader.rigStream(Data(KemperFixture.placeholder)).isPlaceholder)
        XCTAssertTrue(KemperReader.rigStream(Data(KemperFixture.string(1, "Leer"))).isPlaceholder)
    }

    func testReadsABackupWithPerformances() throws {
        let clean = KemperFixture.rigEvents(name: "Clean", amp: "Deluxe", maker: "Fender", model: "Deluxe Reverb", gain: 2)
        let lead = KemperFixture.rigEvents(name: "Solo", amp: "Plexi", maker: "Marshall", model: "Plexi", gain: 7)
        let database = try KemperFixture.database([
            ("Wonderwall", [clean, lead, KemperFixture.placeholder, KemperFixture.placeholder, KemperFixture.placeholder]),
            ("New Performance", Array(repeating: KemperFixture.placeholder, count: 5)),
        ])
        let archive = KemperFixture.tar([
            ("./Rigs/Clean - 2020-01-01.kipr", KemperFixture.rigFile(clean)),
            ("./Stomp/Comp.kipr", KemperFixture.rigFile(clean)),
            ("./repository.kdb", database),
        ])
        let library = try KemperReader.backup(archive)
        XCTAssertEqual(library.rigs.map(\.name), ["Clean"], "only rigs from Rigs/")
        XCTAssertEqual(library.performances.map(\.name), ["Wonderwall", "New Performance"])
        XCTAssertEqual(library.performances[0].slots.map { $0?.name }, ["Clean", "Solo", nil, nil, nil])
        XCTAssertEqual(library.ownPerformances.map(\.name), ["Wonderwall"])
    }
}

final class KemperTranslationTests: XCTestCase {
    private func rig(_ name: String, amp: String, gain: Double, eq: [Double] = [0, 0, 0, 0],
                     modules: [(page: Int, type: Int, on: Bool)] = []) throws -> KemperRig {
        try KemperReader.rigFile(KemperFixture.rigFile(
            KemperFixture.rigEvents(name: name, amp: amp, gain: gain, eq: eq, modules: modules)))
    }

    func testAmpsFindTheirSparkModel() throws {
        let cases: [(String, Double, String)] = [
            ("Dumble ODS", 3, "ODS50CN"), ("Marshall 50w JMP", 6, "Plexi"), ("Marshall 50w JMP", 2, "Plexi"),
            ("Divided By 13 LDW39", 2.5, "94MatchDCV2"), ("Fender Deluxe Reverb", 2, "Deluxe65"),
            ("AC30 VOX JMI", 4, "AC Boost"), ("EVH 5150III 50 watt", 7, "EVH"), ("Mesa Lonestar", 6, "OverDrivenLuxVerb"),
            ("Roland Jazz Chorus", 2, "RolandJC120"), ("Unknown Boutique", 8, "SLO100"),
            ("Unknown Boutique", 1, "94MatchDCV2"), ("3rd Power Dream Weaver Proto", 7, "Plexi"),
            ("3rd Power Dream Weaver Proto", 2, "ODS50CN"),
        ]
        for (amp, gain, model) in cases {
            let result = KemperTranslation.translate(try rig("Test", amp: amp, gain: gain))
            XCTAssertEqual(result.ampModel, model, "\(amp) at gain \(gain)")
        }
    }

    func testGainAndEqualizerCarryOver() throws {
        let result = KemperTranslation.translate(try rig("Lead", amp: "Marshall JMP", gain: 7, eq: [-2, 1, 0, 2]))
        let amp = try XCTUnwrap(result.recipe.chain["amp"])
        XCTAssertEqual(amp.settings["gain"], .number(7))
        XCTAssertEqual(amp.settings["bass"], .number(3))
        XCTAssertEqual(amp.settings["middle"], .number(6))
        XCTAssertEqual(amp.settings["treble"], .number(6), "half the presence goes to the treble")
        XCTAssertEqual(result.character, .drive)
        XCTAssertEqual(result.recipe.tags, ["kemper", "drive"])
        XCTAssertTrue(result.recipe.notes.contains("anhören"))
    }

    /// Every amp rule and every effect the translation knows must make a recipe Spark Studio reads without problems.
    func testEveryMappingMakesAValidRecipe() throws {
        for rule in KemperTranslation.ampRules {
            XCTAssertNotNil(ModelCatalog.known(rule.model), rule.model)
        }
        for type in KemperEffectType.names.keys.sorted() {
            let page = type >= 177 ? 61 : type >= 145 ? 60 : 50
            let result = KemperTranslation.translate(try rig("FX \(type)", amp: "Fender Twin", gain: 3,
                                                           modules: [(page, type, true)]))
            XCTAssertNoThrow(try result.recipe.preset(), "type \(type) \(KemperEffectType.name(type))")
        }
    }

    func testEffectsGoToTheirPlacesAndLeftOutIsNamed() throws {
        let result = KemperTranslation.translate(try rig("FX", amp: "Fender Twin", gain: 3, modules: [
            (50, 49, true), (51, 115, true), (56, 101, true), (58, 70, true), (60, 146, true), (52, 33, false),
        ]))
        XCTAssertEqual(result.recipe.chain["compressor"]?.model, "BlueComp")
        XCTAssertEqual(result.recipe.chain["drive"]?.model, "Booster")
        XCTAssertEqual(result.recipe.chain["modulation"]?.model, "Tremolo")
        XCTAssertEqual(result.recipe.chain["delay"]?.model, "DelayMono")
        XCTAssertEqual(result.leftOut, ["Stereo Widener"], "the switched-off Green Scream is not mentioned")
    }

    func testTheDelayModuleWinsOverADelayInMod() throws {
        let result = KemperTranslation.translate(try rig("FX", amp: "Fender Twin", gain: 3, modules: [
            (58, 151, true), (60, 145, true),
        ]))
        XCTAssertEqual(result.leftOut, ["Loop Pitch Delay (Platz delay schon belegt)"])
    }
}

final class KemperImportPlanTests: XCTestCase {
    private func library() throws -> KemperLibrary {
        let clean = KemperFixture.rigEvents(name: "Comping", amp: "LDW39", maker: "Divided By 13", gain: 2.5)
        let solo = KemperFixture.rigEvents(name: "Solo", amp: "JMP", maker: "Marshall", gain: 7)
        let database = try KemperFixture.database([
            ("Can't Stop", [clean, solo, KemperFixture.placeholder, KemperFixture.placeholder, KemperFixture.placeholder]),
            ("Quick Setup", [clean, solo, KemperFixture.placeholder, KemperFixture.placeholder, KemperFixture.placeholder]),
            ("Licks", [solo, KemperFixture.placeholder, KemperFixture.placeholder, KemperFixture.placeholder, KemperFixture.placeholder]),
        ])
        return try KemperReader.backup(KemperFixture.tar([
            ("Rigs/Comping.kipr", KemperFixture.rigFile(clean)), ("repository.kdb", database),
        ]))
    }

    func testKindsAreGuessedFromNames() throws {
        let plan = KemperImportPlan(try library())
        XCTAssertEqual(plan.performances.map(\.kind), [.song, .basis, .lesson])
        XCTAssertEqual(plan.rigs.map(\.isChosen), [false], "single rigs of a backup are not chosen by default")
        XCTAssertEqual(plan.performances[0].slots.map(\.translation.recipe.name), ["Can't Stop · Comping", "Can't Stop · Solo"])
        XCTAssertEqual(plan.performances[2].slots.map(\.translation.recipe.name), ["Licks"], "one sound: the performance's name")
    }

    func testEqualSoundsAreOnePresetWithAllTags() throws {
        var plan = KemperImportPlan(try library())
        // The same rig under the same name in two performances is one preset.
        plan.performances[1].slots = plan.performances[0].slots
        let output = try plan.output()
        // "Licks" plays the same sound as "Can't Stop · Solo": one preset, named after its first use.
        XCTAssertEqual(output.sounds.count, 2)
        let solo = try XCTUnwrap(output.sounds.first { $0.preset.name == "Can't Stop · Solo" })
        XCTAssertTrue(solo.tags.contains("unterricht") && solo.tags.contains("Licks"))
        let comping = try XCTUnwrap(output.sounds.first { $0.preset.name == "Can't Stop · Comping" })
        XCTAssertEqual(comping.tags, ["kemper", "clean", "song", "CantStop", "basis", "QuickSetup"])
        XCTAssertEqual(output.songs.count, 1)
        XCTAssertEqual(output.songs[0].title, "Can't Stop")
        XCTAssertEqual(output.songs[0].parts.map(\.name), ["Comping", "Solo"])
        XCTAssertEqual(output.songs[0].parts.map { output.sounds[$0.sound].preset.name },
                       ["Can't Stop · Comping", "Can't Stop · Solo"])
    }

    func testSlotNamesComeFromThePerformanceAndRepeatedTitlesGetTheirNumber() throws {
        let rig = KemperFixture.rigEvents(name: "72 Marshall", amp: "JMP", maker: "Marshall", gain: 5)
        let other = KemperFixture.rigEvents(name: "Lead", amp: "JMP", maker: "Marshall", gain: 8)
        let database = try KemperFixture.database([
            ("Live", [rig, other, KemperFixture.placeholder, KemperFixture.placeholder, KemperFixture.placeholder]),
            ("Live", [rig, KemperFixture.placeholder, KemperFixture.placeholder, KemperFixture.placeholder, KemperFixture.placeholder]),
        ], slotNames: ["Intro", ""])
        let plan = KemperImportPlan(try KemperReader.backup(KemperFixture.tar([("repository.kdb", database)])))
        XCTAssertEqual(plan.performances.map(\.name), ["Live 1", "Live 2"])
        XCTAssertEqual(plan.performances[0].slots.map(\.name), ["Intro", "Lead"], "own name, else the rig's")
        XCTAssertEqual(plan.performances[0].slots.map(\.translation.recipe.name), ["Live 1 · Intro", "Live 1 · Lead"])
    }

    func testSkippedPerformancesAndChosenRigs() throws {
        var plan = KemperImportPlan(try library())
        for index in plan.performances.indices { plan.performances[index].kind = .skip }
        XCTAssertEqual(try plan.output().sounds.count, 0)
        plan.rigs[0].isChosen = true
        let output = try plan.output()
        XCTAssertEqual(output.sounds.map(\.preset.name), ["Comping"])
        XCTAssertEqual(output.sounds[0].origin, "Kemper · Rig")
        XCTAssertTrue(output.songs.isEmpty)
    }

    func testHashtagsAndTagText() {
        XCTAssertEqual(PresetFile.hashtag("Can't Stop"), "CantStop")
        XCTAssertEqual(PresetFile.hashtag("180er Band"), "180erBand")
        XCTAssertEqual(PresetFile.tagText("  ##basis "), "basis")
        XCTAssertEqual(PresetFile.normalized(["#Basis", "basis", " ", "clean"]), ["Basis", "clean"])
    }
}

final class PresetLibraryTagTests: XCTestCase {
    func testDetailsChangeWithoutTouchingTheSound() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = PresetLibrary(folder: folder)
        try library.reload()
        let preset = try SoundRecipe(name: "Clean", chain: ["amp": .init(model: "Twin")]).preset().preset
        let saved = try library.save(preset, origin: "Test", tags: ["#basis", "clean"], notes: "aus dem Test")
        XCTAssertEqual(saved.file.tags, ["basis", "clean"])
        let changed = try library.updateDetails(saved) { $0.tags.append("Unterricht"); $0.notes = "neu" }
        XCTAssertEqual(changed.file.tags, ["basis", "clean", "Unterricht"])
        XCTAssertEqual(changed.file.notes, "neu")
        XCTAssertEqual(changed.file.preset, preset)
        _ = try library.save(preset, origin: "Test", tags: ["basis"])
        XCTAssertEqual(library.tagCounts.map(\.tag), ["basis", "clean", "Unterricht"])
        XCTAssertEqual(library.tagCounts.map(\.count), [2, 1, 1])
    }
}
