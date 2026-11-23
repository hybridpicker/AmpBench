import XCTest
@testable import SparkCore

/// What a take remembers about its click, and that libraries from before the stamp load as they were.
final class TimingStampTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var trash: FakeTrash!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        trash = FakeTrash(folder: folder.file("Trash"))
        store = LibraryStore(folder: folder.file("Library"), trasher: trash)
        try store.load()
    }

    private let latency = ClickLatency(output: 0.004, input: 0.003,
                                       amp: AmpPart(seconds: 0.0217,
                                                    origin: .measured(spread: 0.0012,
                                                                      date: Date(timeIntervalSince1970: 1_795_435_200))),
                                       outputKind: .wired)

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: The click during a take

    func testTheClickOnFromStartToEndIsOnThroughout() {
        let watch = ClickWatch(clickOnAtStart: true)
        XCTAssertEqual(watch.stamp(latency: latency), TimingStamp(clickOnThroughout: true, latency: latency))
    }

    func testSwitchingTheClickOffAtAnyMomentClearsOnThroughout() {
        var watch = ClickWatch(clickOnAtStart: true)
        watch.clickSwitched(on: false)
        watch.clickSwitched(on: true)
        XCTAssertFalse(watch.stamp(latency: latency).clickOnThroughout, "on again does not make it whole")
    }

    func testAClickThatStartsDuringTheTakeIsNotOnThroughout() {
        var watch = ClickWatch(clickOnAtStart: false)
        watch.clickSwitched(on: true)
        XCTAssertFalse(watch.stamp(latency: latency).clickOnThroughout)
    }

    // MARK: Library entries

    func testTheStampSurvivesSavingAndLoading() throws {
        try Synthetic.writeWAV(to: store.folder.appendingPathComponent("Take 1.wav"), seconds: 0.2)
        let stamp = TimingStamp(clickOnThroughout: true, latency: latency)
        let recording = Recording(fileName: "Take 1.wav", createdAt: Date(), duration: 0.2, sampleRate: 44_100,
                                  channels: 1, fileBits: 24, timing: stamp)
        store.add(recording)
        try store.save()
        let reloaded = LibraryStore(folder: store.folder, trasher: trash)
        try reloaded.load()
        XCTAssertEqual(reloaded.recording(recording.id)?.timing, stamp)
    }

    func testAnEntryWithoutAStampLoadsAndIsRecordedBeforeTheMeasurement() throws {
        let json = """
        {"schemaVersion": 2,
         "recordings": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "fileName": "Take 1.wav",
                         "createdAt": "2026-01-02T10:00:00Z", "duration": 3, "rating": 4,
                         "grid": {"bpm": 120, "beatsPerBar": 4, "offset": 0.15, "firstBar": 1}}]}
        """
        let document = try decode(LibraryDocument.self, json)
        let take = try XCTUnwrap(document.recordings.first)
        XCTAssertNil(take.timing)
        XCTAssertEqual(take.rating, 4)
        XCTAssertEqual(TimingReview.review(samples: [Float](repeating: 0, count: 44_100), sampleRate: 44_100,
                                           grid: take.grid, stamp: take.timing),
                       .noReview(.recordedBeforeTheStamp))
    }

    func testAnIncompleteStampNeverPassesForMeasured() throws {
        let empty = try decode(TimingStamp.self, "{}")
        XCTAssertFalse(empty.clickOnThroughout)
        XCTAssertNil(empty.latency.amp)
        let broken = try decode(TimingStamp.self, #"{"clickOnThroughout": true, "latency": {"output": "x"}}"#)
        XCTAssertTrue(broken.clickOnThroughout)
        XCTAssertNil(broken.latency.amp)
    }

    func testATakeRepairedAfterACrashGetsNoStamp() throws {
        // Whether the click stayed on to the end cannot be known after a crash.
        try store.writeJournal(RecordingJournal(fileName: "crash.wav", startedAt: Date(), source: nil, pieceID: nil,
                                                grid: BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15)))
        try Synthetic.rawWAV(frames: 44_100, declaredData: 0).write(to: store.folder.appendingPathComponent("crash.wav"))
        guard case .repaired = store.recoverInterruptedRecording() else { return XCTFail("expected repair") }
        let recording = try XCTUnwrap(store.document.recordings.first)
        XCTAssertNotNil(recording.grid)
        XCTAssertNil(recording.timing)
    }
}
