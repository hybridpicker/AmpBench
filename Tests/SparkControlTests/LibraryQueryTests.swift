import XCTest
@testable import SparkControl

/// The library's search, filters, groups and close sounds, with made-up presets built from the templates.
final class LibraryQueryTests: XCTestCase {
    private func item(_ name: String, template: String = "Clean", origin: String = "Template", tags: [String] = [],
                      favorite: Bool = false, backup: Bool = false,
                      change: (inout SparkPreset) -> Void = { _ in }) -> SavedPreset {
        var preset = PresetFactory.templates.first { $0.name == template }!.preset
        preset.name = name
        change(&preset)
        return SavedPreset(url: URL(fileURLWithPath: "/made-up/\(name).json"),
                           file: PresetFile(origin: origin, isBackup: backup, favorite: favorite, tags: tags,
                                            preset: preset))
    }

    func testOriginsAreRecognizedInBothLanguages() {
        XCTAssertEqual(SoundOrigin.of(item("a", origin: "Kemper · Some Song · slot 2")), .kemper)
        XCTAssertEqual(SoundOrigin.of(item("b", origin: "Rezept")), .recipe)
        XCTAssertEqual(SoundOrigin.of(item("c", origin: "Platz 2 · Spark MINI")), .amp)
        XCTAssertEqual(SoundOrigin.of(item("d", origin: "Red 1 · REACTOR 50")), .amp)
        XCTAssertEqual(SoundOrigin.of(item("e", origin: "Vorlage")), .template)
        XCTAssertEqual(SoundOrigin.of(item("f", origin: "Newly created")), .made)
        XCTAssertEqual(SoundOrigin.of(item("g", origin: "Slot 1 · Spark MINI", backup: true)), .backup)
    }

    func testScopesFiltersAndSearchNarrowTogether() {
        let items = [
            item("Glass Harbor Clean", origin: "Kemper · Glass Harbor · slot 1", tags: ["song", "GlassHarbor", "listen"]),
            item("Glass Harbor Lead", template: "Lead", origin: "Kemper · Glass Harbor · slot 3", tags: ["song", "GlassHarbor"]),
            item("Lesson Crunch", template: "Crunch", tags: ["unterricht"], favorite: true),
            item("Old slot 2", template: "Crunch", origin: "Slot 2 · Spark MINI", backup: true),
        ]
        XCTAssertEqual(LibraryQuery().apply(to: items).map(\.name),
                       ["Glass Harbor Clean", "Glass Harbor Lead", "Lesson Crunch"], "backups only in their scope")
        XCTAssertEqual(LibraryQuery(scope: .backups).apply(to: items).map(\.name), ["Old slot 2"])
        XCTAssertEqual(LibraryQuery(scope: .favorites).apply(to: items).map(\.name), ["Lesson Crunch"])
        XCTAssertEqual(LibraryQuery(scope: .toListen).apply(to: items).map(\.name), ["Glass Harbor Clean"])
        XCTAssertEqual(LibraryQuery(tags: ["song"], origins: [.kemper]).apply(to: items).count, 2)
        XCTAssertEqual(LibraryQuery(amps: ["SLO100"]).apply(to: items).map(\.name), ["Glass Harbor Lead"])
        XCTAssertEqual(LibraryQuery(search: "glass lead").apply(to: items).map(\.name), ["Glass Harbor Lead"],
                       "every word must match somewhere")
        XCTAssertEqual(LibraryQuery(search: "#unter").apply(to: items).map(\.name), ["Lesson Crunch"])
        XCTAssertEqual(LibraryQuery(search: "plexi").apply(to: items).map(\.name), ["Lesson Crunch"],
                       "the search finds amp models")
    }

    func testTheListenMarkIsATagThatOlderVersionsKeep() throws {
        var file = item("x", tags: ["song"]).file
        XCTAssertFalse(file.needsListen)
        file.needsListen = true
        XCTAssertEqual(file.tags, ["song", "listen"])
        file.needsListen = true
        XCTAssertEqual(file.tags, ["song", "listen"], "marking twice adds nothing")
        // A format-2 reader without the mark knows it as an ordinary tag.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try JSONSerialization.jsonObject(with: encoder.encode(file)) as? [String: Any]
        XCTAssertEqual(json?["tags"] as? [String], ["song", "listen"])
        file.needsListen = false
        XCTAssertEqual(file.tags, ["song"])
    }

    func testGroupsByTagAmpAndOrigin() {
        let items = [
            item("A", tags: ["song", "listen"]), item("B", template: "Lead", tags: ["song", "basis"]),
            item("C", template: "Crunch", origin: "Kemper · X · slot 1"),
        ]
        let byTag = LibraryGrouping.tag.groups(items)
        XCTAssertEqual(byTag.map(\.title), ["#song", "#basis", "Without tags"], "the listen mark is no group")
        XCTAssertEqual(byTag[0].items.map(\.name), ["A", "B"])
        XCTAssertEqual(LibraryGrouping.tag.groups(items, leaving: ["SONG"]).map(\.title), ["#basis", "Without tags"],
                       "a tag filtered by is carried by all, so it makes no group")
        XCTAssertEqual(LibraryGrouping.amp.groups(items).count, 3)
        XCTAssertEqual(LibraryGrouping.origin.groups(items).map(\.title), ["Kemper import", "Template"])
        XCTAssertEqual(LibraryGrouping.none.groups(items).first?.items.count, 3)
    }

    func testCloseSoundsAreFoundAndOthersAreNot() {
        let original = item("Clean")
        let renamed = item("Clean (copy from the Kemper)")
        let turned = item("Clean brighter") { $0.effects[3].parameters[0].value += 0.1 }
        let switched = item("Clean with delay") { $0.effects[5].isOn = true }
        let otherAmp = item("Crunch", template: "Crunch")
        let far = item("Clean, all knobs turned") { preset in
            for index in preset.effects[3].parameters.indices { preset.effects[3].parameters[index].value = 1 }
            preset.effects[1].isOn = false
            preset.effects[6].isOn = false
        }

        XCTAssertEqual(PresetSimilarity.compare(original.file.preset, renamed.file.preset)?.isEqual, true)
        XCTAssertEqual(PresetSimilarity.compare(original.file.preset, turned.file.preset)?.differing, [.amp])
        XCTAssertEqual(PresetSimilarity.compare(original.file.preset, switched.file.preset)?.differing, [.delay])
        XCTAssertNil(PresetSimilarity.compare(original.file.preset, otherAmp.file.preset), "another amp is never close")

        let neighbours = PresetSimilarity.neighbours(of: original, in: [original, renamed, turned, switched, far])
        XCTAssertEqual(neighbours.map(\.item.name), ["Clean (copy from the Kemper)", "Clean brighter", "Clean with delay"])

        // Backups are close to what they backed up by design, and are left out.
        let backup = item("Clean backup", backup: true)
        let groups = PresetSimilarity.groups([original, renamed, turned, otherAmp, far, backup])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].map(\.name)), ["Clean", "Clean (copy from the Kemper)", "Clean brighter"])
    }
}
