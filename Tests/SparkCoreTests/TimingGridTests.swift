import AmpText
import XCTest
@testable import SparkCore

/// Which grid a take's timing review uses, and where a grid chosen for a take is kept.
final class TimingGridTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        store = LibraryStore(folder: folder.file("Library"), trasher: FakeTrash(folder: folder.file("Trash")))
        try store.load()
    }

    override func tearDown() {
        Texts.language = .english
        super.tearDown()
    }

    private func addTake(_ name: String, piece: Piece? = nil) -> Recording {
        let recording = Recording(fileName: "\(name).wav", createdAt: Date(), duration: 4, sampleRate: 48_000,
                                  channels: 1, fileBits: 24, pieceID: piece?.id,
                                  grid: BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15))
        store.add(recording)
        return recording
    }

    private func grid(_ recording: Recording) -> TimingReview.Resolution {
        store.timingGrid(of: store.recording(recording.id) ?? recording)
    }

    func testATakeOpensOnQuarters() {
        let piece = store.addPiece(named: "Blues in A")
        XCTAssertEqual(grid(addTake("Loose")), .quarters)
        XCTAssertEqual(grid(addTake("In a piece", piece: piece)), .quarters)
    }

    func testAGridChosenForATakeIsKeptByItsPieceForAllItsTakes() throws {
        let piece = try XCTUnwrap(store.addPiece(named: "Blues in A"))
        let first = addTake("Take 1", piece: piece)
        let second = addTake("Take 2", piece: piece)
        let other = addTake("Other")

        store.keepTimingGrid(.triplets, for: first.id)

        XCTAssertEqual(grid(first), .triplets)
        XCTAssertEqual(grid(second), .triplets, "the piece's other takes use it too")
        XCTAssertEqual(grid(addTake("Take 3", piece: piece)), .triplets, "and so do its later takes")
        XCTAssertEqual(grid(other), .quarters, "a take outside the piece keeps its own")
    }

    func testATakeWithoutAPieceKeepsTheGridForItself() {
        let loose = addTake("Loose")
        let other = addTake("Other")

        store.keepTimingGrid(.sixteenths, for: loose.id)

        XCTAssertEqual(grid(loose), .sixteenths)
        XCTAssertEqual(grid(other), .quarters)
    }

    func testTheChosenGridSurvivesSavingAndLoading() throws {
        let piece = try XCTUnwrap(store.addPiece(named: "Blues in A"))
        let inPiece = addTake("Take 1", piece: piece)
        let loose = addTake("Loose")
        store.keepTimingGrid(.eighths, for: inPiece.id)
        store.keepTimingGrid(.triplets, for: loose.id)
        try store.save()

        let reloaded = LibraryStore(folder: store.folder, trasher: FakeTrash(folder: folder.file("Trash")))
        try reloaded.load()
        XCTAssertEqual(reloaded.timingGrid(of: try XCTUnwrap(reloaded.recording(inPiece.id))), .eighths)
        XCTAssertEqual(reloaded.timingGrid(of: try XCTUnwrap(reloaded.recording(loose.id))), .triplets)
    }

    func testEntriesWithoutAGridOrWithAnUnknownOneOpenOnQuarters() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let take = try decoder.decode(Recording.self, from: Data(#"""
            {"id": "\#(UUID().uuidString)", "fileName": "old.wav", "timingGrid": 7}
            """#.utf8))
        XCTAssertNil(take.timingGrid)
        let piece = try decoder.decode(Piece.self, from: Data(#"""
            {"id": "\#(UUID().uuidString)", "name": "Old piece", "timingGrid": "fives"}
            """#.utf8))
        XCTAssertNil(piece.timingGrid)
        let old = try decoder.decode(Piece.self, from: Data(#"{"id": "\#(UUID().uuidString)", "name": "Old"}"#.utf8))
        XCTAssertNil(old.timingGrid)
    }

    func testTheGridsAndTheirNotesReadInEnglishAndGerman() {
        Texts.language = .english
        XCTAssertEqual(TimingReview.Resolution.allCases.map(\.name), ["Quarters", "Eighths", "Triplets", "Sixteenths"])
        XCTAssertEqual(TimingReview.Resolution.allCases.map { $0.notes(16) },
                       ["16 notes on quarters", "16 notes on eighths", "16 notes on triplets", "16 notes on sixteenths"])
        Texts.language = .german
        XCTAssertEqual(TimingReview.Resolution.allCases.map(\.name), ["Viertel", "Achtel", "Triolen", "Sechzehntel"])
        XCTAssertEqual(TimingReview.Resolution.allCases.map { $0.notes(16) },
                       ["16 Töne auf Vierteln", "16 Töne auf Achteln", "16 Töne auf Triolen", "16 Töne auf Sechzehnteln"])
    }
}
