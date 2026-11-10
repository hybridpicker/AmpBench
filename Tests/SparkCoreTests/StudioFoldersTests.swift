import XCTest
@testable import SparkCore

/// Taking over the former apps' folders and settings. Synthetic folders and settings domains only.
final class StudioFoldersTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var oldRecordings: URL!
    private var oldPresets: URL!
    private var studio: StudioFolders!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        oldRecordings = folder.file("Spark Recorder")
        oldPresets = folder.file("Spark Presets")
        studio = StudioFolders(root: folder.file("AmpBench"))
    }

    private func makeOldFolders() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: oldRecordings.appendingPathComponent(".wellenformen"), withIntermediateDirectories: true)
        try manager.createDirectory(at: oldRecordings.appendingPathComponent(".presets"), withIntermediateDirectories: true)
        try Synthetic.writeWAV(to: oldRecordings.appendingPathComponent("Take 1.wav"), seconds: 0.1)
        try Data("{\"schemaVersion\": 1}".utf8).write(to: oldRecordings.appendingPathComponent("Bibliothek.json"))
        try Data("{}".utf8).write(to: oldRecordings.appendingPathComponent(".presets/ABC.json"))
        try manager.createDirectory(at: oldPresets, withIntermediateDirectories: true)
        try Data("{\"preset\": {}}".utf8).write(to: oldPresets.appendingPathComponent("Crunch.json"))
    }

    private func checksums(_ url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        // The temporary folder sits behind a symlink (/var → /private/var), so both sides are resolved first.
        let base = url.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            result[String(file.resolvingSymlinksInPath().path.dropFirst(base.count))] = try Data(contentsOf: file)
        }
        return result
    }

    func testTheOldFoldersAreCopiedAndStayAsTheyWere() throws {
        try makeOldFolders()
        let recordingsBefore = try checksums(oldRecordings)
        let presetsBefore = try checksums(oldPresets)

        let outcome = try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets)
        XCTAssertEqual(outcome, .tookOver(recordings: true, presets: true))

        XCTAssertEqual(try checksums(oldPresets), presetsBefore, "the old presets are untouched")
        var recordingsAfter = try checksums(oldRecordings)
        recordingsAfter.removeValue(forKey: "/.lock")
        XCTAssertEqual(recordingsAfter, recordingsBefore, "the old recordings are untouched, apart from the lock file")

        var copied = try checksums(studio.recordings)
        XCTAssertNil(copied["/.lock"], "the old app's lock stays with the old folder")
        copied.removeValue(forKey: "/.lock")
        XCTAssertEqual(copied, recordingsBefore, "every file arrived, hidden ones included")
        XCTAssertEqual(try checksums(studio.presets), presetsBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: studio.root.appendingPathComponent(StudioFolders.markerName).path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.contains("eingerichtet") }
        XCTAssertEqual(leftovers, [], "no staging folder remains")
    }

    func testASecondStartChangesNothing() throws {
        try makeOldFolders()
        _ = try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets)
        try Data("new".utf8).write(to: studio.recordings.appendingPathComponent("Neu.wav"))
        try Data("old changed later".utf8).write(to: oldRecordings.appendingPathComponent("Später.wav"))
        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: studio.recordings.appendingPathComponent("Neu.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: studio.recordings.appendingPathComponent("Später.wav").path),
                       "taking over happens once, never again")
    }

    func testWithoutOldFoldersTheNewOneStartsEmpty() throws {
        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .created)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: studio.recordings.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: studio.presets.path), [])
    }

    func testOnlyRecordingsExist() throws {
        try makeOldFolders()
        try FileManager.default.removeItem(at: oldPresets)
        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets),
                       .tookOver(recordings: true, presets: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: studio.presets.path))
    }

    /// While Spark Recorder runs, it holds its library's lock. Studio waits and changes nothing.
    func testARunningRecorderBlocksTheTakeover() throws {
        try makeOldFolders()
        let other = LibraryStore(folder: oldRecordings)
        XCTAssertTrue(other.acquireProcessLock())
        // flock is per open file description, so a second open in the same process is refused like another process.
        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: studio.root.path))
    }

    // MARK: The folder of the former name

    private var formerRoot: URL { folder.file(StudioFolders.formerRootName) }

    private func makeFormerRoot() throws {
        let manager = FileManager.default
        let recordings = formerRoot.appendingPathComponent(StudioFolders.recordingsName)
        try manager.createDirectory(at: recordings.appendingPathComponent(".wellenformen"), withIntermediateDirectories: true)
        try manager.createDirectory(at: formerRoot.appendingPathComponent(StudioFolders.presetsName),
                                    withIntermediateDirectories: true)
        try Synthetic.writeWAV(to: recordings.appendingPathComponent("Take 1.wav"), seconds: 0.1)
        try Data("{\"schemaVersion\": 1}".utf8).write(to: recordings.appendingPathComponent("Bibliothek.json"))
        try Data("{\"preset\": {}}".utf8).write(to: formerRoot.appendingPathComponent("Presets/Crunch.json"))
        try Data("{}".utf8).write(to: formerRoot.appendingPathComponent(StudioFolders.markerName))
    }

    func testTheFolderOfTheFormerNameIsRenamed() throws {
        try makeFormerRoot()
        let before = try checksums(formerRoot)
        XCTAssertFalse(before.isEmpty)

        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: formerRoot.path), "moved, not copied")
        XCTAssertEqual(try checksums(studio.root), before, "every file arrived, hidden ones included")

        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .ready,
                       "the next start finds the folder under its new name")
        XCTAssertEqual(try checksums(studio.root), before)
    }

    /// The renamed folder wins over the folders of the still older apps: they were taken over into it long ago.
    func testTheRenamedFolderIsNotMixedWithTheOlderApps() throws {
        try makeFormerRoot()
        try makeOldFolders()
        let before = try checksums(formerRoot)
        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .renamed)
        XCTAssertEqual(try checksums(studio.root), before)
    }

    func testWhenBothFoldersExistNothingIsMoved() throws {
        try makeFormerRoot()
        try FileManager.default.createDirectory(at: studio.recordings, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: studio.recordings.appendingPathComponent("Neu.wav"))
        let formerBefore = try checksums(formerRoot)
        let newBefore = try checksums(studio.root)

        XCTAssertEqual(try studio.adoptFormerRoot(), .nothingToDo)
        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .ready)
        XCTAssertEqual(try checksums(formerRoot), formerBefore, "the former folder stays as it was")
        XCTAssertEqual(try checksums(studio.root), newBefore, "nothing was overwritten or added")
    }

    /// Even a plain file of the new name is in the way, and is never replaced.
    func testAFileOfTheNewNameIsNotReplaced() throws {
        try makeFormerRoot()
        try Data("not a folder".utf8).write(to: studio.root)
        XCTAssertEqual(try studio.adoptFormerRoot(), .nothingToDo)
        XCTAssertEqual(try Data(contentsOf: studio.root), Data("not a folder".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: formerRoot.path))
    }

    func testWithoutAFormerFolderNothingHappens() throws {
        XCTAssertEqual(try studio.adoptFormerRoot(), .nothingToDo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: studio.root.path))
    }

    /// While the app still runs under its former name, it holds its library's lock. Nothing is renamed under it.
    func testARunningFormerAppBlocksTheRename() throws {
        try makeFormerRoot()
        let other = LibraryStore(folder: formerRoot.appendingPathComponent(StudioFolders.recordingsName))
        XCTAssertTrue(other.acquireProcessLock())
        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .blocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: formerRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: studio.root.path))
    }

    // MARK: Settings

    func testSettingsOfTheFormerAppsAreCopiedOnce() throws {
        let domain = "local.ampbench.tests.former-\(UUID().uuidString)"
        let targetName = "local.ampbench.tests.target-\(UUID().uuidString)"
        let former = try XCTUnwrap(UserDefaults(suiteName: domain))
        former.set(96.0, forKey: "bpm")
        former.set("Spark", forKey: "input")
        former.set("x", forKey: "NSWindow Frame Main")
        let target = try XCTUnwrap(UserDefaults(suiteName: targetName))
        target.set("BlackHole", forKey: "input")
        defer {
            former.removePersistentDomain(forName: domain)
            target.removePersistentDomain(forName: targetName)
        }

        let copied = SettingsTakeover.copy(from: [domain], into: target, markerKey: "tookOver", reading: former)
        XCTAssertEqual(copied, 1)
        XCTAssertEqual(target.double(forKey: "bpm"), 96)
        XCTAssertEqual(target.string(forKey: "input"), "BlackHole", "a setting Studio already has stays")
        XCTAssertNil(target.object(forKey: "NSWindow Frame Main"), "system keys stay behind")

        former.set(120.0, forKey: "click")
        XCTAssertEqual(SettingsTakeover.copy(from: [domain], into: target, markerKey: "tookOver", reading: former), 0,
                       "only once")
    }
}
