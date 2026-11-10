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
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.contains("setting up") || $0.contains("eingerichtet") }
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
        let recordings = formerRoot.appendingPathComponent(StudioFolders.formerRecordingsName)
        try manager.createDirectory(at: recordings.appendingPathComponent(".wellenformen"), withIntermediateDirectories: true)
        try manager.createDirectory(at: formerRoot.appendingPathComponent(StudioFolders.presetsName),
                                    withIntermediateDirectories: true)
        try Synthetic.writeWAV(to: recordings.appendingPathComponent("Take 1.wav"), seconds: 0.1)
        try Data("{\"schemaVersion\": 1}".utf8).write(to: recordings.appendingPathComponent("Bibliothek.json"))
        try Data("{\"preset\": {}}".utf8).write(to: formerRoot.appendingPathComponent("Presets/Crunch.json"))
        try Data("{}".utf8).write(to: formerRoot.appendingPathComponent(StudioFolders.formerMarkerName))
    }

    /// The same files under the names `prepare` gives the recordings folder and the marker. The names inside the
    /// recordings folder are the library's matter and stay until it is opened.
    private func underCurrentNames(_ files: [String: Data]) -> [String: Data] {
        var result: [String: Data] = [:]
        for (path, data) in files {
            var path = path
            if path.hasPrefix("/Aufnahmen/") { path = "/Recordings/" + path.dropFirst("/Aufnahmen/".count) }
            if path == "/.uebernommen.json" { path = "/.adopted.json" }
            result[path] = data
        }
        return result
    }

    func testTheFolderOfTheFormerNameIsRenamed() throws {
        try makeFormerRoot()
        let before = underCurrentNames(try checksums(formerRoot))
        XCTAssertFalse(before.isEmpty)
        XCTAssertNotNil(before["/Recordings/Take 1.wav"])

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
        let before = underCurrentNames(try checksums(formerRoot))
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
        let other = LibraryStore(folder: formerRoot.appendingPathComponent(StudioFolders.formerRecordingsName))
        XCTAssertTrue(other.acquireProcessLock())
        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .blocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: formerRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: studio.root.path))
    }

    // MARK: The German names inside the folder

    private var formerRecordings: URL { studio.root.appendingPathComponent(StudioFolders.formerRecordingsName) }

    private func makeRootWithFormerNames() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: formerRecordings.appendingPathComponent(".wellenformen"), withIntermediateDirectories: true)
        try manager.createDirectory(at: formerRecordings.appendingPathComponent("Exporte"), withIntermediateDirectories: true)
        try manager.createDirectory(at: studio.presets, withIntermediateDirectories: true)
        try Synthetic.writeWAV(to: formerRecordings.appendingPathComponent("Aufnahme_2026-11-01_10-00-00.wav"), seconds: 0.1)
        try Data("{\"schemaVersion\": 1}".utf8).write(to: formerRecordings.appendingPathComponent("Bibliothek.json"))
        try Data("mix".utf8).write(to: formerRecordings.appendingPathComponent("Exporte/Mix.wav"))
        try Data("{\"preset\": {}}".utf8).write(to: studio.presets.appendingPathComponent("Crunch.json"))
        try Data("{}".utf8).write(to: studio.root.appendingPathComponent(StudioFolders.formerMarkerName))
    }

    func testTheRecordingsFolderAndTheMarkerGetTheirEnglishNames() throws {
        try makeRootWithFormerNames()
        let before = underCurrentNames(try checksums(studio.root))

        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: formerRecordings.path), "renamed, not copied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: studio.root.appendingPathComponent(".uebernommen.json").path))
        XCTAssertEqual(try checksums(studio.root), before, "every file arrived under the new folder name")

        XCTAssertEqual(try studio.adoptFormerNames(), .nothingToDo, "once")
        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .ready)
        XCTAssertEqual(try checksums(studio.root), before)
    }

    /// The whole way: the folder first, then the names inside it when the library opens.
    func testAfterTheFolderTheLibraryCarriesItsOwnNamesOver() throws {
        try makeRootWithFormerNames()
        _ = try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets)
        let store = LibraryStore(folder: studio.recordings, trasher: FakeTrash(folder: folder.file("Trash")))
        XCTAssertEqual(try store.load(), .loaded)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: studio.recordings.path))
        XCTAssertTrue(names.isSuperset(of: ["Library.json", ".waveforms", "Exports", "Aufnahme_2026-11-01_10-00-00.wav"]))
        XCTAssertTrue(names.isDisjoint(with: ["Bibliothek.json", ".wellenformen", "Exporte"]))
    }

    func testWhenBothRecordingsFoldersExistNothingIsMoved() throws {
        try makeRootWithFormerNames()
        try FileManager.default.createDirectory(at: studio.recordings, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: studio.recordings.appendingPathComponent("Neu.wav"))
        try Data("{\"new\": true}".utf8).write(to: studio.root.appendingPathComponent(StudioFolders.markerName))
        let before = try checksums(studio.root)

        XCTAssertEqual(try studio.adoptFormerNames(), .nothingToDo)
        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .ready)
        XCTAssertEqual(try checksums(studio.root), before, "both folders and both markers stay as they were")
    }

    /// Even a plain file named `Recordings` is in the way, and is never replaced.
    func testAFileNamedLikeTheRecordingsFolderIsNotReplaced() throws {
        try makeRootWithFormerNames()
        try Data("not a folder".utf8).write(to: studio.recordings)
        XCTAssertEqual(try studio.adoptFormerNames(), .nothingToDo)
        XCTAssertEqual(try Data(contentsOf: studio.recordings), Data("not a folder".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: formerRecordings.path))
    }

    /// A version of the app that still writes into `Aufnahmen` holds its lock. Nothing is renamed under it.
    func testARunningAppBlocksTheRenameOfTheRecordingsFolder() throws {
        try makeRootWithFormerNames()
        let before = try checksums(studio.root)
        let other = LibraryStore(folder: formerRecordings)
        XCTAssertTrue(other.acquireProcessLock())
        XCTAssertEqual(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets), .blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: studio.recordings.path), "no empty new folder either")
        var after = try checksums(studio.root)
        after.removeValue(forKey: "/Aufnahmen/.lock")
        XCTAssertEqual(after, before)
    }

    /// A folder that may not be changed: the rename fails, says so, and everything is as it was.
    func testAFailedRenameOfTheRecordingsFolderChangesNothing() throws {
        try makeRootWithFormerNames()
        let before = try checksums(studio.root)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: studio.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: studio.root.path) }

        XCTAssertThrowsError(try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets))
        XCTAssertFalse(FileManager.default.fileExists(atPath: studio.recordings.path))
        XCTAssertEqual(try checksums(studio.root), before)
    }

    /// The folders of the still older apps are copied with their German names inside; the new folder gets English ones.
    func testATakeoverWritesTheEnglishFolderAndMarkerNames() throws {
        try makeOldFolders()
        _ = try studio.prepare(formerRecordings: oldRecordings, formerPresets: oldPresets)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: studio.root.path))
        XCTAssertEqual(names, ["Recordings", "Presets", ".adopted.json"])
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
