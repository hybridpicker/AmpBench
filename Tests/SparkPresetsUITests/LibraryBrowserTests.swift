import SparkControl
import XCTest
@testable import SparkPresetsUI

/// The library overlay's state with the made-up library of the pictures: about a hundred invented sounds in a
/// temporary folder. No real preset, amp or keychain is touched.
@MainActor
final class LibraryBrowserTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ampbench-library-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func madeUpItems() throws -> [SavedPreset] {
        MadeUpLibrary.fill(folder)
        let library = PresetLibrary(folder: folder)
        try library.reload()
        return library.items
    }

    func testTheMadeUpLibraryIsRealisticAndWrittenOnce() throws {
        let items = try madeUpItems()
        XCTAssertGreaterThanOrEqual(items.count, 90)
        XCTAssertLessThanOrEqual(items.count, 120)
        XCTAssertTrue(items.contains { $0.file.needsListen })
        XCTAssertTrue(items.contains { $0.file.favorite })
        XCTAssertTrue(items.contains { $0.file.isBackup })
        XCTAssertFalse(PresetSimilarity.groups(items).isEmpty, "the pictures need close sounds")
        XCTAssertEqual(Set(items.map(\.url)).count, items.count)
        MadeUpLibrary.fill(folder)
        let again = PresetLibrary(folder: folder)
        try again.reload()
        XCTAssertEqual(again.items.count, items.count, "a second start adds nothing")
        let songs = MadeUpLibrary.songs(in: items)
        XCTAssertEqual(songs.count, MadeUpLibrary.songs.count)
        XCTAssertTrue(songs.allSatisfy { $0.parts.allSatisfy { $0.presetID != nil } })
    }

    func testFiltersMakeTheQuery() {
        let browser = LibraryBrowser()
        browser.filters = [.scope(.toListen), .tag("song"), .tag("basis"), .amp("Twin"), .origin(.kemper)]
        browser.search = "intro"
        let query = browser.query
        XCTAssertEqual(query.scope, .toListen)
        XCTAssertEqual(query.tags, ["basis", "song"])
        XCTAssertEqual(query.amps, ["Twin"])
        XCTAssertEqual(query.origins, [.kemper])
        XCTAssertEqual(query.search, "intro")
        browser.filters = []
        XCTAssertEqual(browser.query.scope, .all)
    }

    func testASoundInSeveralTagGroupsIsSelectedOnce() throws {
        let items = try madeUpItems()
        let browser = LibraryBrowser()
        browser.grouping = .tag
        defer { browser.grouping = .none }
        browser.libraryChanged(items)
        let rows = browser.rows(items).flatMap(\.rows)
        let song = try XCTUnwrap(items.first { $0.name == "Glass Harbor Intro" })
        let own = rows.filter { $0.url == song.url }
        XCTAssertEqual(own.count, 2, "the sound stands under #song and under #GlassHarbor")
        browser.selection = Set(own.map(\.id))
        XCTAssertEqual(browser.selectedItems(items).map(\.name), ["Glass Harbor Intro"])
    }

    func testCloseSoundsShowInTheirGroupsAndGoneSoundsLeaveTheSelection() throws {
        let items = try madeUpItems()
        let browser = LibraryBrowser()
        browser.libraryChanged(items)
        browser.filters = [.scope(.close)]
        let groups = browser.rows(items)
        XCTAssertFalse(groups.isEmpty)
        XCTAssertTrue(groups.allSatisfy { $0.rows.count > 1 })
        XCTAssertTrue(groups.allSatisfy { $0.group.title.hasPrefix("Close to") })

        browser.selection = Set(groups[0].rows.map(\.id))
        let kept = items.filter { $0.url != groups[0].rows[0].url }
        browser.libraryChanged(kept)
        XCTAssertEqual(browser.selection.count, groups[0].rows.count - 1)
    }
}
