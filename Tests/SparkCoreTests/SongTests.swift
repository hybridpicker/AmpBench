import XCTest
@testable import SparkCore

/// Pieces are songs too, and the library moves to schema 2 with a copy of the old file. Synthetic data only.
final class SongTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        store = LibraryStore(folder: folder.file("Library"), trasher: FakeTrash(folder: folder.file("Trash")))
    }

    private let schemaOne = """
    {"schemaVersion": 1,
     "recordings": [],
     "pieces": [{"id": "1E0A2C3D-0000-4000-8000-000000000001", "name": "Etüde", "createdAt": "2026-01-01T09:00:00Z"}],
     "practiceLog": [], "trashed": []}
    """

    private func writeLibrary(_ json: String) throws -> Data {
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let data = Data(json.utf8)
        try data.write(to: store.documentURL)
        return data
    }

    // MARK: Schema 2

    func testAnOldLibraryIsKeptAsItWasAndThenCountsAsCurrent() throws {
        let original = try writeLibrary(schemaOne)
        try store.load()
        let copy = store.folder.appendingPathComponent(LibraryStore.schemaBackupName(from: 1))
        XCTAssertEqual(try Data(contentsOf: copy), original, "the copy is the file as it was")
        XCTAssertEqual(store.document.schemaVersion, 2)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(store.document.pieces.first?.name, "Etüde")
        XCTAssertEqual(store.document.pieces.first?.artist, "")
        XCTAssertNil(store.document.pieces.first?.bpm)

        try store.save()
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.documentURL)) as? [String: Any]
        XCTAssertEqual(saved?["schemaVersion"] as? Int, 2)

        // Loading again leaves the copy alone.
        let again = LibraryStore(folder: store.folder)
        try again.load()
        XCTAssertEqual(try Data(contentsOf: copy), original)
    }

    func testANewerLibraryStaysReadOnly() throws {
        _ = try writeLibrary(schemaOne.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 3"))
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(store.isReadOnly)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.folder.appendingPathComponent(LibraryStore.schemaBackupName(from: 3)).path))
    }

    func testAFreshLibraryStartsAtTheCurrentSchema() throws {
        try store.load()
        XCTAssertEqual(store.document.schemaVersion, LibraryDocument.currentSchema)
    }

    // MARK: Songs

    func testSongFieldsSurviveSavingAndLoading() throws {
        try store.load()
        let piece = try XCTUnwrap(store.addPiece(named: "Blues in A"))
        let sound = PresetLink(presetID: "B5C1", fileName: "Crunch.json", name: "Crunch")
        store.updatePiece(piece.id) {
            $0.artist = "Eine Band"
            $0.bpm = 96
            $0.key = "A-Dur"
            $0.notes = "Solo erst ab Takt 13"
            $0.preset = sound
            $0.parts = [PiecePart(name: "Intro"), PiecePart(name: "Solo", preset: sound)]
        }
        try store.save()
        let again = LibraryStore(folder: store.folder)
        try again.load()
        let loaded = try XCTUnwrap(again.document.pieces.first)
        XCTAssertEqual(loaded.artist, "Eine Band")
        XCTAssertEqual(loaded.bpm, 96)
        XCTAssertEqual(loaded.key, "A-Dur")
        XCTAssertEqual(loaded.notes, "Solo erst ab Takt 13")
        XCTAssertEqual(loaded.preset, sound)
        XCTAssertEqual(loaded.parts.map(\.name), ["Intro", "Solo"])
        XCTAssertEqual(loaded.parts.last?.preset, sound)
    }

    func testPracticeTimeCountsDiscardedTakesToo() throws {
        try store.load()
        let piece = try XCTUnwrap(store.addPiece(named: "Etüde"))
        store.logPractice(date: Date(), seconds: 90, pieceID: piece.id)
        store.logPractice(date: Date(), seconds: 30, pieceID: piece.id)
        store.logPractice(date: Date(), seconds: 999, pieceID: nil)
        XCTAssertEqual(store.practiceSeconds(ofPiece: piece.id), 120, accuracy: 0.001)
    }
}
