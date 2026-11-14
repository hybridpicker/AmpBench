import XCTest
@testable import SoundStore

final class SyncPlanTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_000_000)
    private let late = Date(timeIntervalSince1970: 2_000_000)
    private let now = Date(timeIntervalSince1970: 3_000_000)

    private func object(_ letter: Character) -> String { "objects/" + String(repeating: letter, count: 64) + ".age" }
    private func sound(_ letter: Character, _ date: Date? = nil) -> LocalSound {
        LocalSound(object: object(letter), modified: date ?? early, size: 10)
    }
    private func entry(_ letter: Character, _ date: Date? = nil, deleted: Date? = nil, history: [Character] = []) -> StoreManifest.Entry {
        StoreManifest.Entry(object: object(letter), modified: date ?? early, size: 10, deleted: deleted, history: history.map(object))
    }
    private func plan(local: [String: LocalSound], remote: [String: StoreManifest.Entry], base: [String: Character]) -> SyncPlan {
        SyncPlan.make(local: local, remote: StoreManifest(id: "store", entries: remote), base: base.mapValues(object), now: now)
    }

    func testNothingChanged() {
        let plan = plan(local: ["a.json": sound("a")], remote: ["a.json": entry("a")], base: ["a.json": "a"])
        XCTAssertEqual(plan.unchanged, 1)
        XCTAssertFalse(plan.changesStore)
        XCTAssertTrue(plan.uploads.isEmpty && plan.downloads.isEmpty && plan.removals.isEmpty && plan.markedDeleted.isEmpty)
        XCTAssertEqual(plan.base, ["a.json": object("a")])
        XCTAssertEqual(plan.manifest.entries, ["a.json": entry("a")])
    }

    func testNewHereIsUploaded() {
        let plan = plan(local: ["a.json": sound("a", late)], remote: [:], base: [:])
        XCTAssertEqual(plan.uploads, ["a.json"])
        XCTAssertEqual(plan.manifest.entries["a.json"], entry("a", late))
        XCTAssertEqual(plan.base, ["a.json": object("a")])
        XCTAssertEqual(plan.manifest.id, "store")
    }

    func testNewInTheStoreIsDownloaded() {
        let plan = plan(local: [:], remote: ["a.json": entry("a")], base: [:])
        XCTAssertEqual(plan.downloads, ["a.json"])
        XCTAssertFalse(plan.changesStore)
        XCTAssertEqual(plan.base, ["a.json": object("a")])
    }

    func testChangedOnlyHereIsUploadedAndTheOldContentBecomesHistory() {
        // Even with an older date: only this side changed, so there is no conflict to decide by date.
        let plan = plan(local: ["a.json": sound("b", early)], remote: ["a.json": entry("a", late, history: ["z"])], base: ["a.json": "a"])
        XCTAssertEqual(plan.uploads, ["a.json"])
        XCTAssertTrue(plan.downloads.isEmpty)
        XCTAssertEqual(plan.manifest.entries["a.json"], entry("b", early, history: ["a", "z"]))
    }

    func testChangedOnlyInTheStoreIsDownloaded() {
        let plan = plan(local: ["a.json": sound("a", late)], remote: ["a.json": entry("b", early)], base: ["a.json": "a"])
        XCTAssertEqual(plan.downloads, ["a.json"])
        XCTAssertTrue(plan.uploads.isEmpty && plan.preserved.isEmpty)
        XCTAssertEqual(plan.manifest.entries["a.json"], entry("b", early))
        XCTAssertEqual(plan.base, ["a.json": object("b")])
    }

    func testChangedOnBothSidesToTheSameContentIsNothing() {
        let plan = plan(local: ["a.json": sound("b", late)], remote: ["a.json": entry("b", early)], base: ["a.json": "a"])
        XCTAssertEqual(plan.unchanged, 1)
        XCTAssertFalse(plan.changesStore)
        XCTAssertTrue(plan.downloads.isEmpty)
        XCTAssertEqual(plan.base, ["a.json": object("b")])
    }

    func testConflictTheNewerLocalWins() {
        let plan = plan(local: ["a.json": sound("b", late)], remote: ["a.json": entry("c", early)], base: ["a.json": "a"])
        XCTAssertEqual(plan.uploads, ["a.json"])
        XCTAssertTrue(plan.downloads.isEmpty)
        XCTAssertEqual(plan.manifest.entries["a.json"], entry("b", late, history: ["c"]))
    }

    func testConflictTheNewerRemoteWinsAndTheLocalLoserIsKept() {
        let plan = plan(local: ["a.json": sound("b", early)], remote: ["a.json": entry("c", late, history: ["a"])], base: ["a.json": "a"])
        XCTAssertEqual(plan.downloads, ["a.json"])
        XCTAssertEqual(plan.preserved, ["a.json"], "the losing local content is uploaded before it is replaced")
        XCTAssertTrue(plan.uploads.isEmpty)
        XCTAssertTrue(plan.changesStore)
        XCTAssertEqual(plan.manifest.entries["a.json"], entry("c", late, history: ["b", "a"]))
        XCTAssertEqual(plan.base, ["a.json": object("c")])
    }

    func testRemovedHereAndUnchangedInTheStoreIsMarkedDeleted() {
        let plan = plan(local: [:], remote: ["a.json": entry("a")], base: ["a.json": "a"])
        XCTAssertEqual(plan.markedDeleted, ["a.json"])
        XCTAssertEqual(plan.manifest.entries["a.json"], entry("a", deleted: now), "the object stays, so it can come back")
        XCTAssertTrue(plan.base.isEmpty)
        XCTAssertTrue(plan.downloads.isEmpty)
    }

    func testRemovedHereButChangedInTheStoreComesBack() {
        let plan = plan(local: [:], remote: ["a.json": entry("b", late)], base: ["a.json": "a"])
        XCTAssertEqual(plan.downloads, ["a.json"])
        XCTAssertTrue(plan.markedDeleted.isEmpty)
        XCTAssertNil(plan.manifest.entries["a.json"]?.deleted)
    }

    func testRemovedInTheStoreAndUnchangedHereIsRemovedHere() {
        let plan = plan(local: ["a.json": sound("a")], remote: ["a.json": entry("a", deleted: late)], base: ["a.json": "a"])
        XCTAssertEqual(plan.removals, ["a.json"])
        XCTAssertFalse(plan.changesStore)
        XCTAssertTrue(plan.base.isEmpty)
        XCTAssertEqual(plan.manifest.entries["a.json"], entry("a", deleted: late))
    }

    func testRemovedInTheStoreButChangedHereLivesAgain() {
        let plan = plan(local: ["a.json": sound("b", late)], remote: ["a.json": entry("a", deleted: late)], base: ["a.json": "a"])
        XCTAssertEqual(plan.uploads, ["a.json"])
        XCTAssertTrue(plan.removals.isEmpty)
        XCTAssertEqual(plan.manifest.entries["a.json"], entry("b", late, history: ["a"]))
    }

    func testRemovedOnBothSidesStaysRemoved() {
        let plan = plan(local: [:], remote: ["a.json": entry("a", deleted: late)], base: ["a.json": "a"])
        XCTAssertFalse(plan.changesStore)
        XCTAssertTrue(plan.removals.isEmpty && plan.downloads.isEmpty && plan.markedDeleted.isEmpty)
        XCTAssertEqual(plan.manifest.entries["a.json"], entry("a", deleted: late))
        XCTAssertTrue(plan.base.isEmpty)
    }

    func testFirstRunIsTheUnionAndNeverRemoves() {
        let plan = plan(local: ["mine.json": sound("a"), "both.json": sound("b", late), "older.json": sound("c", early),
                                "same.json": sound("s"), "gone.json": sound("g")],
                        remote: ["theirs.json": entry("d"), "both.json": entry("e", early), "older.json": entry("f", late),
                                 "same.json": entry("s"), "gone.json": entry("g", deleted: late), "old.json": entry("o", deleted: late)],
                        base: [:])
        XCTAssertEqual(plan.uploads, ["both.json", "gone.json", "mine.json"])
        XCTAssertEqual(plan.downloads, ["older.json", "theirs.json"])
        XCTAssertEqual(plan.preserved, ["older.json"])
        XCTAssertTrue(plan.removals.isEmpty, "without a memory of an earlier sync nothing is removed here")
        XCTAssertTrue(plan.markedDeleted.isEmpty)
        XCTAssertEqual(plan.unchanged, 1)
        XCTAssertEqual(plan.manifest.entries["both.json"], entry("b", late, history: ["e"]))
        XCTAssertEqual(plan.manifest.entries["older.json"], entry("f", late, history: ["c"]))
        XCTAssertNil(plan.manifest.entries["gone.json"]?.deleted)
        XCTAssertNotNil(plan.manifest.entries["old.json"]?.deleted)
        XCTAssertEqual(Set(plan.base.keys), ["mine.json", "both.json", "older.json", "same.json", "gone.json", "theirs.json"])
    }

    func testHistoryKeepsTheNewestTenWithoutRepeats() {
        var entry = entry("a")
        for letter in "bcdefabcdef0123456789" { entry.replace(with: object(letter), modified: late, size: 1) }
        XCTAssertEqual(entry.object, object("9"))
        XCTAssertEqual(entry.history, "876543210f".map(object))
        entry.replace(with: object("9"), modified: now, size: 1)
        XCTAssertEqual(entry.history.count, 10, "the same content again is not history")
        entry.replace(with: object("5"), modified: now, size: 1)
        XCTAssertFalse(entry.history.contains(object("5")), "the current content is not its own history")
        XCTAssertEqual(entry.history.first, object("9"))
    }

    func testOnlyPathsInsideTheFolderAreSafe() {
        for path in ["a.json", "Folder/a.json", "a b/ü – ß.json", "a..b.json"] { XCTAssertTrue(StoreManifest.isSafe(path: path), path) }
        for path in ["", "/a.json", "../a.json", "a/../b.json", "a/./b", "a//b", "a/", ".hidden", "a/.hidden", "..", ".", "a\\b", "a\0b"] {
            XCTAssertFalse(StoreManifest.isSafe(path: path), path)
        }
    }
}
