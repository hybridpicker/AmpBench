import CryptoKit
import XCTest
@testable import SparkCore

final class LibraryTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var trash: FakeTrash!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        let library = folder.file("Library")
        trash = FakeTrash(folder: folder.file("Trash"))
        store = LibraryStore(folder: library, trasher: trash)
        try store.load()
    }

    private func audio(_ name: String, seconds: Double = 1) throws -> URL {
        try Synthetic.writeWAV(to: store.folder.appendingPathComponent(name), seconds: seconds)
    }

    private func addRecording(_ name: String, seconds: Double = 1) throws -> Recording {
        _ = try audio(name, seconds: seconds)
        let recording = Recording(fileName: name, createdAt: Date(), duration: seconds, sampleRate: 44_100,
                                  channels: 1, fileBits: 24)
        store.add(recording)
        return store.recording(recording.id)!
    }

    private func checksum(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).description
    }

    // MARK: Persistence

    func testFreshLibraryStartsEmpty() {
        XCTAssertTrue(store.document.recordings.isEmpty)
    }

    func testSaveAndLoadRoundTrip() throws {
        var recording = try addRecording("a.wav")
        store.update(recording.id) {
            // The document stores whole seconds, which is plenty for a recording date.
            $0.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
            $0.rating = 4
            $0.favorite = true
            $0.tags = ["Blues", "Solo"]
            $0.note = "Äußerst gut – mit Umlauten"
            $0.markers = [Marker(time: 1.5, label: "Refrain")]
            $0.edit = EditList(trimStart: 0.5, gainDB: -2, autoLevelEnabled: true, autoLevelDB: 12)
            $0.source = SourceFormat(deviceName: "Spark", bits: 16, sampleRate: 44_100, channels: 1)
        }
        recording = store.recording(recording.id)!
        try store.save()

        let reloaded = LibraryStore(folder: store.folder, trasher: trash)
        XCTAssertEqual(try reloaded.load(), .loaded)
        XCTAssertEqual(reloaded.recording(recording.id), recording)
    }

    func testDocumentIsReadableJSON() throws {
        _ = try addRecording("a.wav")
        try store.save()
        let text = try String(contentsOf: store.documentURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), "formatted over several lines")
        XCTAssertTrue(text.contains("\"fileName\" : \"a.wav\""))
        XCTAssertTrue(try JSONSerialization.jsonObject(with: Data(text.utf8)) is [String: Any])
    }

    func testSaveKeepsPreviousVersionAsBackup() throws {
        _ = try addRecording("a.wav")
        try store.save()
        _ = try addRecording("b.wav")
        try store.save()
        let backup = try JSONDecoder.iso.decode(LibraryDocument.self, from: Data(contentsOf: store.backupURL))
        XCTAssertEqual(backup.recordings.map(\.fileName), ["a.wav"])
    }

    func testBackgroundSaveWritesTheState() throws {
        _ = try addRecording("a.wav")
        store.saveInBackground()
        store.flushSaves()
        let reloaded = LibraryStore(folder: store.folder)
        try reloaded.load()
        XCTAssertEqual(reloaded.document.recordings.count, 1)
    }

    func testCorruptDocumentFallsBackToBackupAndIsKept() throws {
        _ = try addRecording("a.wav")
        try store.save()
        _ = try addRecording("b.wav")
        try store.save()
        try Data("{ not json".utf8).write(to: store.documentURL)

        let reloaded = LibraryStore(folder: store.folder)
        guard case .restoredFromBackup(let keptAs) = try reloaded.load() else { return XCTFail("expected backup") }
        XCTAssertEqual(reloaded.document.recordings.map(\.fileName), ["a.wav"])
        let kept = try String(contentsOf: store.folder.appendingPathComponent(keptAs), encoding: .utf8)
        XCTAssertEqual(kept, "{ not json", "the unreadable file must not be thrown away")
    }

    func testCorruptDocumentWithoutBackupStartsOverAndScanFindsFiles() throws {
        _ = try audio("a.wav")
        try Data("garbage".utf8).write(to: store.documentURL)

        let reloaded = LibraryStore(folder: store.folder)
        guard case .startedOver = try reloaded.load() else { return XCTFail("expected a new start") }
        XCTAssertEqual(reloaded.scan().added, ["a.wav"])
    }

    func testUnknownFieldsAndMissingFieldsDoNotBreakLoading() throws {
        let json = """
        {"schemaVersion": 1, "futureThing": 5, "recordings": [
          {"id": "\(UUID().uuidString)", "fileName": "old.wav", "somethingNew": true}
        ]}
        """
        try Data(json.utf8).write(to: store.documentURL)
        let reloaded = LibraryStore(folder: store.folder)
        XCTAssertEqual(try reloaded.load(), .loaded)
        XCTAssertEqual(reloaded.document.recordings.first?.status, .kept)
        XCTAssertEqual(reloaded.document.recordings.first?.rating, 0)
    }

    func testNewerSchemaIsNeverOverwritten() throws {
        let json = #"{"schemaVersion": 99, "recordings": []}"#
        try Data(json.utf8).write(to: store.documentURL)
        let reloaded = LibraryStore(folder: store.folder)
        XCTAssertThrowsError(try reloaded.load())
        XCTAssertTrue(reloaded.isReadOnly)
        try reloaded.save()
        XCTAssertEqual(try String(contentsOf: store.documentURL, encoding: .utf8), json)
    }

    func testProcessLockAllowsOnlyOneHolder() throws {
        let other = LibraryStore(folder: store.folder)
        XCTAssertTrue(store.acquireProcessLock())
        XCTAssertFalse(other.acquireProcessLock())
    }

    // MARK: Migration and scanning

    func testScanAdoptsOldRecordingsWithoutChangingThem() throws {
        let url = try audio("Aufnahme_2026-11-01_10-00-00.wav", seconds: 2)
        let before = try checksum(url)

        let report = store.scan()

        XCTAssertEqual(report.added, ["Aufnahme_2026-11-01_10-00-00.wav"])
        XCTAssertEqual(try checksum(url), before, "adopting must not touch the audio file")
        let recording = try XCTUnwrap(store.document.recordings.first)
        XCTAssertEqual(recording.duration, 2, accuracy: 0.01)
        XCTAssertEqual(recording.sampleRate, 44_100)
        XCTAssertEqual(recording.fileBits, 24)
        XCTAssertEqual(recording.status, .kept)
        XCTAssertNil(recording.source, "what delivered an old file is unknown")
        XCTAssertFalse(recording.edit.autoLevelEnabled, "an old file may already have been raised")
    }

    func testScanIgnoresDocumentHiddenFilesAndSubfolders() throws {
        _ = try audio("a.wav")
        try store.save()
        try Data().write(to: store.folder.appendingPathComponent(".hidden.wav"))
        try Data("x".utf8).write(to: store.folder.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: store.exportFolder, withIntermediateDirectories: true)
        try Synthetic.writeWAV(to: store.exportFolder.appendingPathComponent("export.wav"))
        XCTAssertEqual(store.scan().added, ["a.wav"])
        XCTAssertEqual(store.document.recordings.count, 1)
    }

    func testScanIsStableWhenRunTwice() throws {
        _ = try audio("a.wav")
        _ = store.scan()
        let second = store.scan()
        XCTAssertEqual(second, ScanReport())
        XCTAssertEqual(store.document.recordings.count, 1)
    }

    func testScanRecognizesFileRenamedInFinderAndKeepsMetadata() throws {
        let recording = try addRecording("a.wav")
        store.update(recording.id) { $0.rating = 5 }
        try FileManager.default.moveItem(at: store.url(of: recording),
                                         to: store.folder.appendingPathComponent("Blues in A.wav"))
        let report = store.scan()
        XCTAssertEqual(report.reattached, ["Blues in A.wav"])
        XCTAssertEqual(store.document.recordings.count, 1)
        XCTAssertEqual(store.recording(recording.id)?.fileName, "Blues in A.wav")
        XCTAssertEqual(store.recording(recording.id)?.rating, 5)
    }

    func testMissingFileKeepsEntryAndComesBack() throws {
        let recording = try addRecording("a.wav")
        store.update(recording.id) { $0.note = "wichtig" }
        let url = store.url(of: recording)
        let aside = folder.file("aside.wav")
        try FileManager.default.moveItem(at: url, to: aside)

        XCTAssertEqual(store.scan().missing, ["a.wav"])
        XCTAssertEqual(store.recording(recording.id)?.health, .missing)
        XCTAssertEqual(store.recording(recording.id)?.note, "wichtig")

        try FileManager.default.moveItem(at: aside, to: url)
        _ = store.scan()
        XCTAssertEqual(store.recording(recording.id)?.health, .ok)
    }

    func testScanRepairsAdoptedFileWithBrokenHeader() throws {
        try Synthetic.rawWAV(frames: 44_100, declaredData: 0).write(to: store.folder.appendingPathComponent("crash.wav"))
        let report = store.scan()
        XCTAssertEqual(report.repaired, ["crash.wav"])
        let recording = try XCTUnwrap(store.document.recordings.first)
        XCTAssertEqual(recording.duration, 1, accuracy: 0.001)
        XCTAssertTrue(recording.recoveredAfterInterruption)
    }

    func testScanReportsUnreadableFileWithoutRemovingIt() throws {
        let url = store.folder.appendingPathComponent("kaputt.wav")
        try Data(repeating: 0x41, count: 100).write(to: url)
        XCTAssertEqual(store.scan().damaged, ["kaputt.wav"])
        XCTAssertEqual(store.document.recordings.first?.health, .damaged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testScanSkipsFileOfRunningRecording() throws {
        _ = try audio("laufend.wav")
        try store.writeJournal(RecordingJournal(fileName: "laufend.wav", startedAt: Date(), source: nil, pieceID: nil))
        XCTAssertEqual(store.scan(), ScanReport())
    }

    // MARK: Crash recovery

    func testRecoveryRepairsInterruptedRecordingWithItsMetadata() throws {
        let pieceID = UUID()
        let source = SourceFormat(deviceName: "Spark", bits: 16, sampleRate: 44_100, channels: 1)
        let marker = Marker(time: 0.5, label: "Marker 1")
        try store.writeJournal(RecordingJournal(fileName: "crash.wav", startedAt: Date(), source: source,
                                                pieceID: pieceID, markers: [marker]))
        try Synthetic.rawWAV(frames: 88_200, declaredData: 0).write(to: store.folder.appendingPathComponent("crash.wav"))

        guard case .repaired(_, let seconds) = store.recoverInterruptedRecording() else {
            return XCTFail("expected repair")
        }
        XCTAssertEqual(seconds, 2, accuracy: 0.001)
        let recording = try XCTUnwrap(store.document.recordings.first)
        XCTAssertEqual(recording.status, .open)
        XCTAssertEqual(recording.source, source)
        XCTAssertEqual(recording.pieceID, pieceID)
        XCTAssertEqual(recording.markers, [marker])
        XCTAssertTrue(recording.recoveredAfterInterruption)
        XCTAssertNil(store.readJournal(), "the journal is done")
        XCTAssertEqual(store.document.practiceLog.first?.seconds ?? 0, 2, accuracy: 0.001)
    }

    func testRecoveryWithoutJournalDoesNothing() {
        XCTAssertEqual(store.recoverInterruptedRecording(), .none)
    }

    func testRecoveryOfEmptyRecordingGoesToTrash() throws {
        try store.writeJournal(RecordingJournal(fileName: "leer.wav", startedAt: Date(), source: nil, pieceID: nil))
        let url = store.folder.appendingPathComponent("leer.wav")
        try Synthetic.rawWAV(frames: 0, declaredData: 0).write(to: url)
        XCTAssertEqual(store.recoverInterruptedRecording(), .empty(fileName: "leer.wav"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.folder.path).count, 1)
        XCTAssertTrue(store.document.recordings.isEmpty)
    }

    func testRecoveryOfUnreadableRecordingIsReported() throws {
        try store.writeJournal(RecordingJournal(fileName: "kaputt.wav", startedAt: Date(), source: nil, pieceID: nil))
        let url = store.folder.appendingPathComponent("kaputt.wav")
        try Data(repeating: 0x41, count: 100).write(to: url)
        XCTAssertEqual(store.recoverInterruptedRecording(), .failed(fileName: "kaputt.wav"))
        XCTAssertEqual(store.document.recordings.first?.health, .damaged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Renaming

    func testRenameMovesTheFile() throws {
        let recording = try addRecording("a.wav")
        try store.rename(recording.id, to: "Blues in A")
        XCTAssertEqual(store.recording(recording.id)?.fileName, "Blues in A.wav")
        XCTAssertEqual(store.recording(recording.id)?.name, "Blues in A")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("Blues in A.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("a.wav").path))
    }

    func testRenameNeverOverwrites() throws {
        let first = try addRecording("a.wav", seconds: 1)
        _ = try addRecording("b.wav", seconds: 2)
        let other = try checksum(store.folder.appendingPathComponent("b.wav"))
        XCTAssertThrowsError(try store.rename(first.id, to: "b"))
        XCTAssertEqual(store.recording(first.id)?.fileName, "a.wav")
        XCTAssertEqual(try checksum(store.folder.appendingPathComponent("b.wav")), other)
    }

    func testRenameSanitizesPathsAndRejectsEmptyNames() throws {
        XCTAssertEqual(LibraryStore.sanitizedName("../../etc/passwd"), "-..-etc-passwd")
        XCTAssertEqual(LibraryStore.sanitizedName("  .hidden: name "), "hidden- name")
        XCTAssertNil(LibraryStore.sanitizedName("   "))
        XCTAssertNil(LibraryStore.sanitizedName("..."))
        let recording = try addRecording("a.wav")
        XCTAssertThrowsError(try store.rename(recording.id, to: "..."))
    }

    func testRenameCanChangeOnlyTheCase() throws {
        let recording = try addRecording("blues.wav")
        try store.rename(recording.id, to: "Blues")
        XCTAssertEqual(store.recording(recording.id)?.fileName, "Blues.wav")
    }

    // MARK: Trash and undo

    func testTrashMovesFileAndRestoreBringsEverythingBack() throws {
        let recording = try addRecording("a.wav")
        store.update(recording.id) { $0.rating = 3; $0.note = "gut" }
        let before = try checksum(store.url(of: recording))

        let entry = try store.trash(recording.id)

        XCTAssertNil(store.recording(recording.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(of: recording).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.trashPath), "the file must still exist in the Trash")

        try store.restore(entry)

        let restored = try XCTUnwrap(store.recording(recording.id))
        XCTAssertEqual(restored.rating, 3)
        XCTAssertEqual(restored.note, "gut")
        XCTAssertEqual(try checksum(store.url(of: restored)), before)
        XCTAssertTrue(store.document.trashed.isEmpty)
    }

    func testRestoreDoesNotOverwriteANewFileWithTheSameName() throws {
        let recording = try addRecording("a.wav")
        let entry = try store.trash(recording.id)
        _ = try addRecording("a.wav", seconds: 2)
        try store.restore(entry)
        XCTAssertEqual(store.recording(recording.id)?.fileName, "a 2.wav")
        XCTAssertEqual(store.document.recordings.count, 2)
    }

    func testRestoreFailsCleanlyWhenTrashWasEmptied() throws {
        let recording = try addRecording("a.wav")
        let entry = try store.trash(recording.id)
        try FileManager.default.removeItem(atPath: entry.trashPath)
        XCTAssertThrowsError(try store.restore(entry))
        XCTAssertNil(store.recording(recording.id))
    }

    func testRealTrashMoveCanBeUndone() throws {
        // Uses the system Trash with one synthetic file and takes it straight back out.
        let realStore = LibraryStore(folder: store.folder)
        let recording = try addRecording("spark-recorder-test-\(UUID().uuidString).wav")
        try realStore.load()
        realStore.add(recording)

        let entry = try realStore.trash(recording.id)
        XCTAssertTrue(entry.trashPath.contains(".Trash"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.trashPath))

        try realStore.restore(entry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: realStore.url(of: recording).path))
    }

    func testFileRestoredThroughFinderGetsItsMetadataBack() throws {
        let recording = try addRecording("a.wav")
        store.update(recording.id) { $0.rating = 5 }
        let entry = try store.trash(recording.id)
        try FileManager.default.moveItem(atPath: entry.trashPath, toPath: store.folder.appendingPathComponent("a.wav").path)

        let report = store.scan()

        XCTAssertEqual(report.reattached, ["a.wav"])
        XCTAssertEqual(store.recording(recording.id)?.rating, 5)
        XCTAssertTrue(store.document.trashed.isEmpty)
    }

    func testLastRestorableSkipsFilesGoneFromTrash() throws {
        let first = try addRecording("a.wav")
        let second = try addRecording("b.wav")
        _ = try store.trash(first.id)
        let entry = try store.trash(second.id)
        XCTAssertEqual(store.lastRestorable?.recording.id, second.id)
        try FileManager.default.removeItem(atPath: entry.trashPath)
        XCTAssertEqual(store.lastRestorable?.recording.id, first.id)
    }

    func testUniqueNameNeverReturnsExistingFile() throws {
        _ = try audio("a.wav")
        _ = try audio("a 2.wav")
        XCTAssertEqual(store.uniqueName("a").lastPathComponent, "a 3.wav")
    }

    // MARK: Pieces and takes

    func testPieceNamesAreCaseInsensitivelyUnique() {
        let first = store.addPiece(named: "Blues in A")
        let second = store.addPiece(named: "  blues in a ")
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(store.document.pieces.count, 1)
        XCTAssertNil(store.addPiece(named: "   "))
    }

    func testTakesAreOrderedAndBestTakeIsSingular() throws {
        let piece = try XCTUnwrap(store.addPiece(named: "Etüde"))
        let first = try addRecording("1.wav")
        let second = try addRecording("2.wav")
        store.update(first.id) { $0.createdAt = Date(timeIntervalSince1970: 100) }
        store.update(second.id) { $0.createdAt = Date(timeIntervalSince1970: 200) }
        store.assign(second.id, toPiece: piece.id)
        store.assign(first.id, toPiece: piece.id)

        XCTAssertEqual(store.takes(ofPiece: piece.id).map(\.id), [first.id, second.id])

        store.toggleBestTake(first.id)
        XCTAssertTrue(store.isBestTake(store.recording(first.id)!))
        store.toggleBestTake(second.id)
        XCTAssertFalse(store.isBestTake(store.recording(first.id)!))
        XCTAssertTrue(store.isBestTake(store.recording(second.id)!))
        store.toggleBestTake(second.id)
        XCTAssertFalse(store.isBestTake(store.recording(second.id)!))
    }

    func testRecordingWithoutPieceCannotBeBestTake() throws {
        let recording = try addRecording("a.wav")
        store.toggleBestTake(recording.id)
        XCTAssertFalse(store.isBestTake(recording))
    }

    func testTrashingBestTakeClearsTheMark() throws {
        let piece = try XCTUnwrap(store.addPiece(named: "Etüde"))
        let recording = try addRecording("a.wav")
        store.assign(recording.id, toPiece: piece.id)
        store.toggleBestTake(recording.id)
        _ = try store.trash(recording.id)
        XCTAssertNil(store.document.pieces.first?.bestTakeID)
    }

    func testMovingBestTakeToOtherPieceClearsTheMark() throws {
        let first = try XCTUnwrap(store.addPiece(named: "A"))
        let second = try XCTUnwrap(store.addPiece(named: "B"))
        let recording = try addRecording("a.wav")
        store.assign(recording.id, toPiece: first.id)
        store.toggleBestTake(recording.id)
        store.assign(recording.id, toPiece: second.id)
        XCTAssertNil(store.document.pieces.first { $0.id == first.id }?.bestTakeID)
    }

    func testRemovingPieceKeepsItsTakes() throws {
        let piece = try XCTUnwrap(store.addPiece(named: "A"))
        let recording = try addRecording("a.wav")
        store.assign(recording.id, toPiece: piece.id)
        store.removePiece(piece.id)
        XCTAssertNil(store.recording(recording.id)?.pieceID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(of: recording).path))
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension LibraryTests {
    func testUndoingARemovedPieceBringsItsTakesBack() throws {
        let piece = try XCTUnwrap(store.addPiece(named: "A"))
        let member = try addRecording("a.wav")
        store.assign(member.id, toPiece: piece.id)
        store.toggleBestTake(member.id)
        let removed = try XCTUnwrap(store.removePiece(piece.id))
        XCTAssertNil(store.recording(member.id)?.pieceID)
        store.restorePiece(removed)
        XCTAssertEqual(store.recording(member.id)?.pieceID, piece.id)
        XCTAssertEqual(store.document.pieces.first { $0.id == piece.id }?.bestTakeID, member.id)
    }

    func testRestoredPieceLeavesATakeThatMovedOnAlone() throws {
        let first = try XCTUnwrap(store.addPiece(named: "A"))
        let second = try XCTUnwrap(store.addPiece(named: "B"))
        let member = try addRecording("a.wav")
        store.assign(member.id, toPiece: first.id)
        let removed = try XCTUnwrap(store.removePiece(first.id))
        store.assign(member.id, toPiece: second.id)
        store.restorePiece(removed)
        XCTAssertEqual(store.recording(member.id)?.pieceID, second.id)
    }

    func testPieceTitlesStayUnique() throws {
        let first = try XCTUnwrap(store.addPiece(named: "Blues"))
        _ = try XCTUnwrap(store.addPiece(named: "Etüde"))
        XCTAssertFalse(store.renamePiece(first.id, to: "etüde"))
        XCTAssertFalse(store.renamePiece(first.id, to: "   "))
        XCTAssertEqual(store.document.pieces.first { $0.id == first.id }?.name, "Blues")
        XCTAssertTrue(store.renamePiece(first.id, to: "BLUES"), "changing only the case of its own title is fine")
    }

    func testRecoveryKeepsBarsAndSourceOfAnInterruptedPassage() throws {
        let source = UUID()
        let url = try audio("Take Takt 5-8.wav", seconds: 1)
        let grid = BeatGrid(bpm: 100, beatsPerBar: 4, offset: 0.15, firstBar: 5)
        try store.writeJournal(RecordingJournal(
            fileName: url.lastPathComponent, startedAt: Date(), source: nil, pieceID: nil, grid: grid,
            punch: PunchInfo(sourceID: source, bars: 5...8)))
        _ = store.recoverInterruptedRecording()
        let recovered = try XCTUnwrap(store.document.recordings.first { $0.fileName == url.lastPathComponent })
        XCTAssertEqual(recovered.grid, grid)
        XCTAssertEqual(recovered.punch?.sourceID, source)
    }
}
