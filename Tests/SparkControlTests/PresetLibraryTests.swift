import XCTest
@testable import SparkControl

final class PresetLibraryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("spark-presets-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func preset(_ name: String) throws -> SparkPreset {
        var preset = try SparkPreset(payload: Synthetic.presetPayload())
        preset.name = name
        return preset
    }

    func testSavedPresetsComeBackExactly() throws {
        let library = PresetLibrary(folder: folder)
        try library.reload()
        let original = try preset("Jazz")
        let saved = try library.save(original, origin: "Platz 1 · Test")
        XCTAssertEqual(saved.url.lastPathComponent, "Jazz.json")

        let again = PresetLibrary(folder: folder)
        try again.reload()
        XCTAssertEqual(again.items.count, 1)
        XCTAssertEqual(again.items[0].file.preset, original)
        XCTAssertEqual(again.items[0].file.preset.encode(place: .slot(0)), original.encode(place: .slot(0)))
        XCTAssertEqual(again.items[0].file.origin, "Platz 1 · Test")
        XCTAssertNotNil(again.existing(original))
    }

    func testNamesNeverOverwriteAnotherFile() throws {
        let library = PresetLibrary(folder: folder)
        try library.reload()
        try library.save(try preset("Solo"), origin: "")
        let second = try library.save(try preset("Solo"), origin: "")
        XCTAssertEqual(second.url.lastPathComponent, "Solo 2.json")
        let odd = try library.save(try preset("A/B: Test"), origin: "")
        XCTAssertEqual(odd.url.lastPathComponent, "A-B- Test.json")
        let backup = try library.save(try preset("Solo"), origin: "", isBackup: true,
                                      date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(backup.url.lastPathComponent.hasPrefix("Solo – Sicherung "))
        XCTAssertTrue(backup.file.isBackup)
        XCTAssertEqual(library.items.count, 4)
    }

    func testRenameChangesPresetAndFile() throws {
        let library = PresetLibrary(folder: folder)
        try library.reload()
        let saved = try library.save(try preset("Clean"), origin: "")
        let renamed = try library.rename(saved, to: "  Clean Funk ")
        XCTAssertEqual(renamed.name, "Clean Funk")
        XCTAssertEqual(renamed.url.lastPathComponent, "Clean Funk.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.url.path))
        XCTAssertEqual(library.items.map(\.name), ["Clean Funk"])

        XCTAssertThrowsError(try library.rename(renamed, to: "   "))
        XCTAssertThrowsError(try library.rename(renamed, to: String(repeating: "x", count: 32)))
    }

    func testUnreadableFilesAreReportedAndKept() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let broken = folder.appendingPathComponent("kaputt.json")
        try Data("{".utf8).write(to: broken)
        let library = PresetLibrary(folder: folder)
        try library.reload()
        XCTAssertEqual(library.unreadable, ["kaputt.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
    }
}
