import XCTest
@testable import SparkCore

/// The take knows its sound, pieces have parts and a key. Old libraries must load exactly as before.
final class PresetStampTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var trash: FakeTrash!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        trash = FakeTrash(folder: folder.file("Trash"))
        store = LibraryStore(folder: folder.file("Library"), trasher: trash)
        try store.load()
    }

    private let stamp = PresetStamp(slot: 2, name: "Crunch", stampedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                    sha256: String(repeating: "ab", count: 32))

    private func addRecording(_ name: String, preset: PresetStamp? = nil) throws -> Recording {
        try Synthetic.writeWAV(to: store.folder.appendingPathComponent(name), seconds: 0.2)
        let recording = Recording(fileName: name, createdAt: Date(), duration: 0.2, sampleRate: 44_100, channels: 1,
                                  fileBits: 24, preset: preset)
        store.add(recording)
        return recording
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: Older files

    func testLibraryWithoutTheNewFieldsLoadsUnchanged() throws {
        let json = """
        {"schemaVersion": 1,
         "recordings": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "fileName": "Take 1.wav",
                         "createdAt": "2026-01-02T10:00:00Z", "duration": 3, "rating": 4}],
         "pieces": [{"id": "1E0A2C3D-0000-4000-8000-000000000001", "name": "Etüde", "createdAt": "2026-01-01T09:00:00Z"}]}
        """
        let document = try decode(LibraryDocument.self, json)
        XCTAssertNil(document.recordings[0].preset)
        XCTAssertEqual(document.recordings[0].rating, 4)
        XCTAssertNil(document.pieces[0].preset)
        XCTAssertEqual(document.pieces[0].parts, [])
        XCTAssertNil(document.pieces[0].key)
        XCTAssertEqual(document.schemaVersion, LibraryDocument.currentSchema)
    }

    func testIncompleteStampAndPartsGetDefaults() throws {
        let part = try decode(PiecePart.self, #"{"name": "Solo"}"#)
        XCTAssertEqual(part.name, "Solo")
        XCTAssertNil(part.preset)
        let link = try decode(PresetLink.self, #"{"presetID": "X"}"#)
        XCTAssertEqual(link, PresetLink(presetID: "X", name: ""))
        let stamp = try decode(PresetStamp.self, #"{"name": "Clean"}"#)
        XCTAssertNil(stamp.slot)
        XCTAssertEqual(stamp.sha256, "")
    }

    // MARK: Round trips

    func testStampPartsAndKeySurviveSavingAndLoading() throws {
        let recording = try addRecording("Take 1.wav", preset: stamp)
        let link = PresetLink(presetID: "B5C1", fileName: "Crunch.json", name: "Crunch")
        let piece = Piece(name: "Blues in A", createdAt: Date(timeIntervalSince1970: 1_790_000_000), preset: link,
                          parts: [PiecePart(name: "Intro"), PiecePart(name: "Solo", preset: link)], key: "A-Dur")
        // The store has no setter for the new piece fields yet, so the piece is written into a saved library.
        try store.save()
        var document = try decode(LibraryDocument.self, String(decoding: Data(contentsOf: store.documentURL), as: UTF8.self))
        document.pieces = [piece]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: store.documentURL)

        let reloaded = LibraryStore(folder: store.folder, trasher: trash)
        try reloaded.load()
        XCTAssertEqual(reloaded.recording(recording.id)?.preset, stamp)
        XCTAssertEqual(reloaded.document.pieces, [piece])

        try reloaded.save()
        let again = LibraryStore(folder: store.folder, trasher: trash)
        try again.load()
        XCTAssertEqual(again.document.pieces, [piece], "Saving keeps what it does not edit.")
        XCTAssertEqual(again.recording(recording.id)?.preset, stamp)
    }

    // MARK: Snapshot files

    func testSnapshotIsStoredByTakeIDAndSurvivesARename() throws {
        let recording = try addRecording("Take 1.wav", preset: stamp)
        let bytes = Data(#"{"preset": "made up"}"#.utf8)
        try store.writePresetSnapshot(bytes, for: recording.id)
        XCTAssertEqual(store.presetSnapshotURL(of: recording.id).lastPathComponent, "\(recording.id.uuidString).json")
        XCTAssertEqual(store.presetSnapshotURL(of: recording.id).deletingLastPathComponent().lastPathComponent, ".presets")

        try store.rename(recording.id, to: "Bester Take")
        XCTAssertEqual(store.presetSnapshot(of: recording.id), bytes)
        XCTAssertEqual(store.recording(recording.id)?.preset, stamp)
    }

    func testScanIgnoresTheSnapshotFolder() throws {
        let recording = try addRecording("Take 1.wav", preset: stamp)
        try store.writePresetSnapshot(Data("{}".utf8), for: recording.id)
        let report = store.scan()
        XCTAssertEqual(report.added, [])
        XCTAssertEqual(store.document.recordings.count, 1)
    }

    func testTrashAndRestoreKeepStampAndSnapshot() throws {
        let recording = try addRecording("Take 1.wav", preset: stamp)
        let bytes = Data("{}".utf8)
        try store.writePresetSnapshot(bytes, for: recording.id)
        let entry = try store.trash(recording.id)
        XCTAssertEqual(entry.recording.preset, stamp)
        XCTAssertEqual(store.presetSnapshot(of: recording.id), bytes, "Discarding never deletes the snapshot.")
        try store.restore(entry)
        XCTAssertEqual(store.recording(recording.id)?.preset, stamp)
        XCTAssertEqual(store.presetSnapshot(of: recording.id), bytes)
    }

    func testMissingSnapshotIsNil() {
        XCTAssertNil(store.presetSnapshot(of: UUID()))
    }
}
