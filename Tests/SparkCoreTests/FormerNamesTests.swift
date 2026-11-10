import XCTest
@testable import SparkCore

/// The German names an earlier version wrote into the recordings folder, carried over to the English ones when the
/// library opens. Synthetic folders only.
final class FormerNamesTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var library: URL!
    private var trash: FakeTrash!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        library = folder.file("Library")
        trash = FakeTrash(folder: folder.file("Trash"))
    }

    private func newStore() -> LibraryStore { LibraryStore(folder: library, trasher: trash) }
    private func file(_ name: String) -> URL { library.appendingPathComponent(name) }
    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }

    private let oldTake = "Aufnahme_2026-11-01_10-00-00.wav"
    private let oldRetake = "Aufnahme_2026-11-01_10-00-00 Takt 5-8.wav"

    /// A library as an earlier version left it: two takes, saved twice so that a backup exists, waveforms, an export,
    /// and everything under its German name. Returns the two takes.
    @discardableResult
    private func makeFormerLibrary() throws -> (take: Recording, retake: Recording) {
        let store = newStore()
        try store.load()
        try Synthetic.writeWAV(to: file(oldTake), seconds: 1)
        try Synthetic.writeWAV(to: file(oldRetake), seconds: 0.5)
        var take = Recording(fileName: oldTake, createdAt: Date(timeIntervalSince1970: 1_800_000_000), duration: 1,
                             sampleRate: 44_100, channels: 1, fileBits: 24)
        take.tags = ["Blues"]
        take.rating = 4
        var retake = Recording(fileName: oldRetake, createdAt: Date(timeIntervalSince1970: 1_800_000_100),
                               duration: 0.5, sampleRate: 44_100, channels: 1, fileBits: 24)
        retake.tags = ["Neuaufnahme"]
        retake.punch = PunchInfo(sourceID: take.id, bars: 5...8)
        store.add(take)
        try store.save()
        store.add(retake)
        try store.save()

        let manager = FileManager.default
        try manager.createDirectory(at: store.peaksFolder, withIntermediateDirectories: true)
        try Data("peaks".utf8).write(to: store.peaksURL(of: take.id))
        try manager.createDirectory(at: store.exportFolder, withIntermediateDirectories: true)
        try Data("mix".utf8).write(to: store.exportFolder.appendingPathComponent("Mix.wav"))
        for (former, current) in LibraryStore.formerNames where exists(current) {
            try manager.moveItem(at: file(current), to: file(former))
        }
        return (store.recording(take.id)!, store.recording(retake.id)!)
    }

    private func contents() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = library.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: library, includingPropertiesForKeys: [.isRegularFileKey])
        while let item = enumerator?.nextObject() as? URL {
            guard (try item.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            result[String(item.resolvingSymlinksInPath().path.dropFirst(base.count))] = try Data(contentsOf: item)
        }
        return result
    }

    // MARK: Old to new

    func testEveryFormerNameIsRenamedWhenTheLibraryOpens() throws {
        try makeFormerLibrary()
        let before = try contents()
        XCTAssertNotNil(before["/Bibliothek.json"])
        XCTAssertNotNil(before["/Bibliothek.backup.json"])

        let store = newStore()
        XCTAssertEqual(try store.load(), .loaded)

        var expected: [String: Data] = [:]
        for (path, data) in before {
            var path = path
            for (former, current) in LibraryStore.formerNames where path == "/" + former || path.hasPrefix("/\(former)/") {
                path = "/" + current + path.dropFirst(former.count + 1)
            }
            expected[path] = data
        }
        XCTAssertEqual(try contents(), expected, "the same files with the same bytes, under the new names")
        for name in ["Bibliothek.json", "Bibliothek.backup.json", ".wellenformen", "Exporte"] {
            XCTAssertFalse(exists(name), "\(name) was renamed, not copied")
        }
        for name in ["Library.json", "Library.backup.json", ".waveforms/", "Exports/Mix.wav"] {
            XCTAssertTrue(exists(name), name)
        }
    }

    func testEachFormerNameIsRenamedOnItsOwn() throws {
        for (former, current) in LibraryStore.formerNames {
            let single = folder.file("single-\(current)")
            try FileManager.default.createDirectory(at: single, withIntermediateDirectories: true)
            if former.hasSuffix(".json") {
                try Data("{\"schemaVersion\": 5}".utf8).write(to: single.appendingPathComponent(former))
            } else {
                try FileManager.default.createDirectory(at: single.appendingPathComponent(former),
                                                        withIntermediateDirectories: false)
            }
            let store = LibraryStore(folder: single, trasher: trash)
            XCTAssertEqual(try store.adoptFormerNames(), [former])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: single.path), [current])
            XCTAssertEqual(try store.adoptFormerNames(), [], "once")
        }
    }

    func testTheOldLibraryLoadsWithItsTakesTagsAndFileNames() throws {
        let (take, retake) = try makeFormerLibrary()
        let store = newStore()
        XCTAssertEqual(try store.load(), .loaded)
        XCTAssertEqual(store.document.recordings.count, 2)
        XCTAssertEqual(store.recording(take.id), take)
        XCTAssertEqual(store.recording(retake.id), retake)
        XCTAssertEqual(store.recording(retake.id)?.tags, ["Neuaufnahme"], "an old tag stays as it is")
        XCTAssertEqual(store.recording(retake.id)?.punch?.sourceID, take.id)
        XCTAssertTrue(exists(oldTake) && exists(oldRetake), "take files keep their names")

        XCTAssertEqual(store.scan(), ScanReport(), "nothing is missing, new or renamed for the scan")
        XCTAssertEqual(store.url(of: take).lastPathComponent, oldTake)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.peaksURL(of: take.id).path), "its waveform is found")

        try store.save()
        let again = newStore()
        XCTAssertEqual(try again.load(), .loaded)
        XCTAssertEqual(again.recording(retake.id), retake)
        XCTAssertFalse(exists("Bibliothek.json"), "saving writes the new name only")
    }

    /// An old library that is also of an older schema: the copy kept before the upgrade gets the new kind of name.
    func testAnOldSchemaUnderTheOldNameKeepsItsCopyUnderTheNewKindOfName() throws {
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let old = Data("{\"schemaVersion\": 1, \"recordings\": [], \"pieces\": []}".utf8)
        try old.write(to: file("Bibliothek.json"))
        try Data("old copy".utf8).write(to: file("Bibliothek.vor-Schema-2.aus-1.json"))
        try Data("old damaged".utf8).write(to: file("Bibliothek.defekt-2026-01-01_10-00-00.json"))

        let store = newStore()
        XCTAssertEqual(try store.load(), .loaded)
        let copy = LibraryStore.schemaBackupName(from: 1)
        XCTAssertTrue(copy.hasPrefix("Library.before-schema-") && copy.hasSuffix(".from-1.json"), copy)
        XCTAssertEqual(try Data(contentsOf: file(copy)), old)
        XCTAssertEqual(try Data(contentsOf: file("Bibliothek.vor-Schema-2.aus-1.json")), Data("old copy".utf8),
                       "old copies are left alone")
        XCTAssertEqual(try Data(contentsOf: file("Bibliothek.defekt-2026-01-01_10-00-00.json")), Data("old damaged".utf8))
    }

    func testADamagedOldLibraryIsKeptUnderTheNewKindOfNameAndTheBackupLoads() throws {
        let (take, _) = try makeFormerLibrary()
        try Data("no json".utf8).write(to: file("Bibliothek.json"))
        let store = newStore()
        guard case .restoredFromBackup(let keptAs) = try store.load() else { return XCTFail("expected the backup") }
        XCTAssertTrue(keptAs.hasPrefix("Library.damaged-"), keptAs)
        XCTAssertEqual(try Data(contentsOf: file(keptAs)), Data("no json".utf8))
        XCTAssertNotNil(store.recording(take.id), "the backup, renamed too, was read")
    }

    func testOnlyAnOldBackupStillLoads() throws {
        let (take, _) = try makeFormerLibrary()
        try FileManager.default.removeItem(at: file("Bibliothek.json"))
        let store = newStore()
        XCTAssertEqual(try store.load(), .loaded)
        XCTAssertNotNil(store.recording(take.id))
        XCTAssertTrue(exists("Library.backup.json"))
    }

    // MARK: Both exist

    func testWhenBothNamesExistNothingChangesAndTheNewOneCounts() throws {
        let (take, _) = try makeFormerLibrary()
        // A library under the new names next to it, with one other take.
        let other = folder.file("Other")
        let otherStore = LibraryStore(folder: other, trasher: trash)
        try otherStore.load()
        let newTake = Recording(fileName: "Take_2026-11-10_09-00-00.wav", createdAt: Date(), duration: 1,
                                sampleRate: 44_100, channels: 1, fileBits: 24)
        otherStore.add(newTake)
        try otherStore.save()
        try otherStore.save()
        try otherStore.writeJournal(RecordingJournal(fileName: "x.wav", startedAt: Date(), source: nil, pieceID: nil))
        let manager = FileManager.default
        for name in [LibraryStore.documentName, LibraryStore.backupName, LibraryStore.journalName] {
            try manager.copyItem(at: other.appendingPathComponent(name), to: file(name))
        }
        try Data("{}".utf8).write(to: file(".aufnahme-laeuft.json"))
        try manager.createDirectory(at: file(".waveforms"), withIntermediateDirectories: false)
        try manager.createDirectory(at: file("Exports"), withIntermediateDirectories: false)
        try Data("new mix".utf8).write(to: file("Exports/New.wav"))
        let before = try contents()

        let store = newStore()
        XCTAssertEqual(try store.adoptFormerNames(), [])
        XCTAssertEqual(try contents(), before, "nothing moved, overwritten or deleted")
        XCTAssertEqual(try store.load(), .loaded)
        XCTAssertEqual(try contents(), before)
        XCTAssertNotNil(store.recording(newTake.id), "the new name counts")
        XCTAssertNil(store.recording(take.id))
        XCTAssertTrue(exists("Bibliothek.json") && exists("Bibliothek.backup.json") && exists(".aufnahme-laeuft.json")
            && exists(".wellenformen") && exists("Exporte/Mix.wav"), "the old ones stay where they are")
    }

    /// Anything of the new name is in the way, also a link that points nowhere.
    func testALinkOfTheNewNameIsNotReplaced() throws {
        try makeFormerLibrary()
        try FileManager.default.createSymbolicLink(atPath: file("Library.json").path, withDestinationPath: "nowhere")
        let renamed = try newStore().adoptFormerNames()
        XCTAssertFalse(renamed.contains("Bibliothek.json"))
        XCTAssertTrue(exists("Bibliothek.json"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file("Library.json").path), "nowhere")
    }

    // MARK: Journal

    func testAJournalUnderTheOldNameStillLeadsToRecovery() throws {
        let (take, _) = try makeFormerLibrary()
        // What a crash of the earlier version leaves: its journal and a file with an unfinished header.
        let writer = LibraryStore(folder: folder.file("Writer"), trasher: trash)
        try writer.load()
        let pieceID = UUID()
        let takeID = UUID()
        let marker = Marker(time: 0.5, label: "Marker 1")
        try writer.writeJournal(RecordingJournal(fileName: "Aufnahme_2026-11-09_20-00-00.wav", startedAt: Date(),
                                                 source: nil, pieceID: pieceID, markers: [marker], takeID: takeID))
        try FileManager.default.moveItem(at: writer.journalURL, to: file(".aufnahme-laeuft.json"))
        try Synthetic.rawWAV(frames: 88_200, declaredData: 0).write(to: file("Aufnahme_2026-11-09_20-00-00.wav"))

        let store = newStore()
        XCTAssertEqual(try store.load(), .loaded)
        XCTAssertFalse(exists(".aufnahme-laeuft.json"))
        XCTAssertEqual(store.scan().added, [], "the unfinished file is the journal's, not a new file for the scan")
        guard case .repaired(let name, let seconds) = store.recoverInterruptedRecording() else {
            return XCTFail("expected repair")
        }
        XCTAssertEqual(name, "Aufnahme_2026-11-09_20-00-00.wav")
        XCTAssertEqual(seconds, 2, accuracy: 0.001)
        let recovered = try XCTUnwrap(store.recording(takeID))
        XCTAssertEqual(recovered.pieceID, pieceID)
        XCTAssertEqual(recovered.markers, [marker])
        XCTAssertTrue(recovered.recoveredAfterInterruption)
        XCTAssertNotNil(store.recording(take.id), "next to the takes that were there")
        XCTAssertNil(store.readJournal())
        XCTAssertFalse(exists(".recording-in-progress.json") || exists(".aufnahme-laeuft.json"), "the journal is done")
    }

    // MARK: A rename that fails

    func testAFailedRenameLosesNothingAndSaysWhatHappened() throws {
        try makeFormerLibrary()
        try Data("{}".utf8).write(to: file(".aufnahme-laeuft.json"))
        try Synthetic.rawWAV(frames: 100, declaredData: 0).write(to: file("crash.wav"))
        let before = try contents()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path) }

        let store = newStore()
        XCTAssertThrowsError(try store.load()) { error in
            guard case LibraryError.carryOverFailed(let from, let to, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(from, "Bibliothek.json")
            XCTAssertEqual(to, "Library.json")
            XCTAssertTrue(error.localizedDescription.contains("Bibliothek.json"))
        }
        XCTAssertTrue(store.isReadOnly)

        // What the app does next must not write an empty library next to the real one.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path)
        XCTAssertEqual(store.recoverInterruptedRecording(), .none)
        try store.save()
        store.saveInBackground()
        store.flushSaves()
        XCTAssertEqual(try contents(), before, "everything is as it was")

        // The next start, with the folder writable again, carries everything over.
        let next = newStore()
        XCTAssertEqual(try next.load(), .loaded)
        XCTAssertEqual(next.document.recordings.count, 2)
    }

    // MARK: New names

    func testNewTakesGetTheEnglishNames() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(LibraryStore.takeStem(at: date), "Take_" + LibraryStore.fileStamp(date))
        XCTAssertEqual(LibraryStore.retakeStem(of: "Take_2026-11-10_09-00-00", bars: 5...8),
                       "Take_2026-11-10_09-00-00 bars 5-8")
        XCTAssertEqual(LibraryStore.retakeStem(of: "Aufnahme_2026-11-01_10-00-00", bars: 2...3),
                       "Aufnahme_2026-11-01_10-00-00 bars 2-3", "the source's own name is not translated")
        XCTAssertEqual(LibraryStore.retakeTag, "Retake")

        let store = newStore()
        try store.load()
        XCTAssertEqual(store.uniqueName(LibraryStore.takeStem(at: date)).lastPathComponent,
                       "Take_\(LibraryStore.fileStamp(date)).wav")
    }

    func testANewLibraryWritesTheEnglishNamesOnly() throws {
        let store = newStore()
        XCTAssertEqual(try store.load(), .fresh)
        store.add(Recording(fileName: "a.wav", createdAt: Date(), duration: 1, sampleRate: 44_100, channels: 1,
                            fileBits: 24))
        try store.save()
        try store.save()
        try store.writeJournal(RecordingJournal(fileName: "b.wav", startedAt: Date(), source: nil, pieceID: nil))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: library.path)),
                       ["Library.json", "Library.backup.json", ".recording-in-progress.json"])
        XCTAssertEqual(store.peaksFolder.lastPathComponent, ".waveforms")
        XCTAssertEqual(store.exportFolder.lastPathComponent, "Exports")
    }
}
