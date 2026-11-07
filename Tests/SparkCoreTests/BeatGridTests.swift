import CSparkRT
import XCTest
@testable import SparkCore

final class BeatGridTests: XCTestCase {
    private let grid = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15)

    func testPositionCountsBarsAndBeatsFromTheFirstBeat() {
        XCTAssertNil(grid.position(at: 0.1), "the pre-roll lies before bar 1")
        XCTAssertEqual(grid.position(at: 0.15), BarPosition(bar: 1, beat: 1))
        XCTAssertEqual(grid.position(at: 0.15 + 0.5), BarPosition(bar: 1, beat: 2))
        XCTAssertEqual(grid.position(at: 0.15 + 1.9), BarPosition(bar: 1, beat: 4))
        XCTAssertEqual(grid.position(at: 0.15 + 2), BarPosition(bar: 2, beat: 1))
        XCTAssertEqual(grid.position(at: 0.15 + 18.6), BarPosition(bar: 10, beat: 2))
    }

    func testEveryBarLineLandsOnItsOwnBarDespiteRounding() {
        let odd = BeatGrid(bpm: 97, beatsPerBar: 7, offset: 0.1234)
        for bar in 1...500 {
            XCTAssertEqual(odd.position(at: odd.time(ofBar: bar)), BarPosition(bar: bar, beat: 1))
        }
    }

    func testPlayheadSentToABarLineCountsAsThatBar() {
        // File positions are whole frames, so a seek lands up to one frame before the line.
        for rate in [44_100.0, 48_000, 192_000] {
            let barLine = grid.time(ofBar: 2)
            let landed = Double(Int64(barLine * rate)) / rate
            XCTAssertEqual(grid.position(at: landed), BarPosition(bar: 2, beat: 1), "at \(rate) Hz")
        }
    }

    func testRerecordedPassageKeepsTheNumbersOfItsBars() {
        let passage = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15, firstBar: 5)
        XCTAssertEqual(passage.position(at: 0.15), BarPosition(bar: 5, beat: 1))
        XCTAssertEqual(passage.time(ofBar: 6), 2.15, accuracy: 1e-9)
        XCTAssertEqual(passage.lastBar(duration: 4.15), 6)
    }

    func testRingingOutOfAPassageAddsNoBar() {
        var passage = Recording(fileName: "x.wav", createdAt: Date(), duration: 4.45, sampleRate: 44_100, channels: 1, fileBits: 24)
        XCTAssertNil(passage.lastBar, "a take without bars has no last bar")
        passage.grid = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15, firstBar: 2)
        XCTAssertEqual(passage.lastBar, 4, "an ordinary take counts the bar cut off by its end")
        passage.punch = PunchInfo(sourceID: UUID(), bars: 2...3)
        XCTAssertEqual(passage.lastBar, 3)
    }

    func testClickStartingBeforeTheFileStillCounts() {
        let early = BeatGrid(bpm: 120, beatsPerBar: 4, offset: -0.2)
        XCTAssertEqual(early.position(at: 0), BarPosition(bar: 1, beat: 1))
        XCTAssertEqual(early.loopRange(bars: 1...1, duration: 10)?.lowerBound, 0)
    }

    func testLastBarIncludesABarCutOffByTheEnd() {
        XCTAssertEqual(grid.lastBar(duration: 0.15 + 4), 2, "ending exactly on a bar line does not start a new bar")
        XCTAssertEqual(grid.lastBar(duration: 0.15 + 4.5), 3)
        XCTAssertEqual(grid.lastBar(duration: 0.05), 1)
    }

    func testLoopRangeCoversWholeBarsAndStaysInTheFile() throws {
        let range = try XCTUnwrap(grid.loopRange(bars: 2...3, duration: 100))
        XCTAssertEqual(range.lowerBound, 2.15, accuracy: 1e-9)
        XCTAssertEqual(range.upperBound, 6.15, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(grid.loopRange(bars: 2...3, duration: 5)).upperBound, 5)
        XCTAssertNil(grid.loopRange(bars: 50...51, duration: 5), "bars beyond the file cannot be looped")
    }

    func testDraggingSnapsToWholeBars() {
        XCTAssertEqual(grid.snappedBars(from: 2.5, to: 2.9, duration: 100), 2...2)
        XCTAssertEqual(grid.snappedBars(from: 2.5, to: 4.5, duration: 100), 2...3)
        XCTAssertEqual(grid.snappedBars(from: 2.15, to: 6.15, duration: 100), 2...3, "an end on a bar line stays out")
        XCTAssertEqual(grid.snappedBars(from: 0, to: 1, duration: 100), 1...1, "the pre-roll belongs to bar 1")
        XCTAssertEqual(grid.snappedBars(from: 3, to: 99, duration: 5), 2...3, "never past the end of the file")
    }

    func testOldLibraryEntriesWithoutGridStillLoad() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","fileName":"alt.wav"}"#
        let recording = try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
        XCTAssertNil(recording.grid)
        XCTAssertNil(recording.punch)
    }

    func testGridAndPunchSurviveSaving() throws {
        var recording = Recording(fileName: "x.wav", createdAt: Date(timeIntervalSince1970: 1), duration: 4,
                                  sampleRate: 44_100, channels: 1, fileBits: 24)
        recording.grid = BeatGrid(bpm: 90, beatsPerBar: 3, offset: 0.15, firstBar: 5)
        recording.punch = PunchInfo(sourceID: UUID(), bars: 5...8)
        let decoded = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(recording))
        XCTAssertEqual(decoded, recording)
        XCTAssertEqual(decoded.punch?.bars, 5...8)
    }

    // MARK: Metronome settings

    func testSavedSettingWithClickDuringRecordingBecomesAnEnabledClick() throws {
        let saved = #"{"bpm":100,"beatsPerBar":3,"volume":0.5,"countInBars":1,"clickWhileRecording":true}"#
        let settings = try JSONDecoder().decode(MetronomeSettings.self, from: Data(saved.utf8))
        XCTAssertTrue(settings.clickEnabled)
        XCTAssertEqual(settings.bpm, 100)
        XCTAssertEqual(settings.beatsPerBar, 3)
    }

    func testClickSettingRoundTrips() throws {
        let settings = MetronomeSettings(bpm: 80, beatsPerBar: 6, volume: 0.25, countInBars: 2, clickEnabled: true)
        XCTAssertEqual(try JSONDecoder().decode(MetronomeSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    // MARK: Click in playback

    private let rate = 44_100.0

    private func render(frames: Int, firstFrame: Int64 = 0, grid: BeatGrid? = nil, volume: Float = 1) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        samples.withUnsafeMutableBufferPointer {
            PlaybackClick.mix(into: $0.baseAddress!, count: frames, firstFrame: firstFrame, sampleRate: rate,
                              grid: grid ?? self.grid, volume: volume)
        }
        return samples
    }

    func testClickSoundsOnEveryBeatAndNotBetween() {
        let samples = render(frames: Int(rate * 2.5))
        for beat in 0..<4 {
            let start = Int((0.15 + Double(beat) * 0.5) * rate)
            let peak = samples[start..<(start + 200)].map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.3, "beat \(beat) must be audible")
            let between = samples[(start + Int(0.2 * rate))..<(start + Int(0.4 * rate))].map { abs($0) }.max() ?? 1
            XCTAssertEqual(between, 0, "the time between beats stays silent")
        }
        XCTAssertEqual(samples[0..<Int(0.14 * rate)].map { abs($0) }.max(), 0, "no click before the first beat")
    }

    func testFirstBeatOfTheBarIsAccented() {
        let samples = render(frames: Int(rate * 1))
        let first = Int(0.15 * rate)
        let second = Int(0.65 * rate)
        let accent = samples[first..<(first + 200)].map { abs($0) }.max() ?? 0
        let beat = samples[second..<(second + 200)].map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(accent, beat * 1.2)
    }

    func testClickIsTheSameHoweverPlaybackIsChunked() {
        let whole = render(frames: 40_000)
        var pieces: [Float] = []
        for start in stride(from: 0, to: 40_000, by: 1_000) {
            pieces += render(frames: 1_000, firstFrame: Int64(start))
        }
        XCTAssertEqual(whole, pieces, "a seek or a chunk boundary must not move or cut a click")
    }

    func testClickAddsToTheAudioWithoutReplacingIt() {
        var samples = [Float](repeating: 0.25, count: 1_000)
        samples.withUnsafeMutableBufferPointer {
            PlaybackClick.mix(into: $0.baseAddress!, count: 1_000, firstFrame: 0, sampleRate: rate,
                              grid: BeatGrid(bpm: 120, beatsPerBar: 4, offset: 10), volume: 1)
        }
        XCTAssertEqual(samples, [Float](repeating: 0.25, count: 1_000), "audio stays untouched away from a click")
    }

    func testZeroVolumeAddsNothing() {
        XCTAssertEqual(render(frames: 8_000, volume: 0).map { abs($0) }.max(), 0)
    }

    // MARK: Removing recordings

    func testRemoveCommandOnTheEmptyPartOfTheListUsesTheMarkedRows() {
        let marked = UUID()
        XCTAssertEqual(RemovalTargets.resolve(menuIDs: [], selection: [marked], current: UUID()), [marked])
    }

    func testRemoveCommandPrefersTheRowsTheMenuWasOpenedOn() {
        let row = UUID()
        XCTAssertEqual(RemovalTargets.resolve(menuIDs: [row], selection: [UUID()], current: UUID()), [row])
    }

    func testRemoveCommandFallsBackToTheTakeInFocus() {
        let current = UUID()
        XCTAssertEqual(RemovalTargets.resolve(menuIDs: [], selection: [], current: current), [current])
        XCTAssertTrue(RemovalTargets.resolve(menuIDs: [], selection: [], current: nil).isEmpty)
    }

    func testAfterRemovingTheNextRowGetsTheFocus() {
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertEqual(RemovalTargets.nextFocus(in: ids, removing: [ids[1]]), ids[2])
        XCTAssertEqual(RemovalTargets.nextFocus(in: ids, removing: [ids[0]]), ids[1])
    }

    func testAfterRemovingTheLastRowTheOneBeforeGetsTheFocus() {
        let ids = (0..<3).map { _ in UUID() }
        XCTAssertEqual(RemovalTargets.nextFocus(in: ids, removing: [ids[2]]), ids[1])
        XCTAssertEqual(RemovalTargets.nextFocus(in: ids, removing: [ids[1], ids[2]]), ids[0])
    }

    func testAfterRemovingSeveralRowsTheRowAfterTheLastOneGetsTheFocus() {
        let ids = (0..<5).map { _ in UUID() }
        XCTAssertEqual(RemovalTargets.nextFocus(in: ids, removing: [ids[0], ids[2]]), ids[3])
        XCTAssertEqual(RemovalTargets.nextFocus(in: ids, removing: [ids[1], ids[4]]), ids[3])
    }

    func testNothingGetsTheFocusWhenNothingIsLeft() {
        let ids = (0..<2).map { _ in UUID() }
        XCTAssertNil(RemovalTargets.nextFocus(in: ids, removing: Set(ids)))
        XCTAssertNil(RemovalTargets.nextFocus(in: [], removing: [UUID()]))
        XCTAssertNil(RemovalTargets.nextFocus(in: ids, removing: [UUID()]), "a take outside the list moves nothing")
    }

    // MARK: Recording start time

    func testFirstFrameOfTheFileIsReported() throws {
        let capture = spark_capture_create(1, 8_192, rate, 0, 0, 256, nil)
        defer { spark_capture_destroy(capture) }
        let folder = try TemporaryFolder()
        let file = try openTestFile(folder.file("start.wav"))
        defer { ExtAudioFileDispose(file) }
        let block = [Float](repeating: 0.1, count: 512)

        spark_capture_process(capture, block, 512, 1_000_000)
        spark_capture_attach_file(capture, file, Int64(SPARK_GATE_NONE))
        XCTAssertEqual(spark_capture_file_first_frame(capture), -1, "unknown until the first block")
        spark_capture_process(capture, block, 512, 2_000_000)
        spark_capture_process(capture, block, 512, 3_000_000)
        XCTAssertEqual(spark_capture_file_first_frame(capture), 512, "the file starts with the block after attaching")
        XCTAssertEqual(spark_capture_frames_received(capture), 1536)
        XCTAssertTrue(spark_capture_detach_file(capture))
    }

    func testFirstFrameHonorsTheGate() throws {
        let capture = spark_capture_create(1, 8_192, rate, 0, 0, 256, nil)
        defer { spark_capture_destroy(capture) }
        let folder = try TemporaryFolder()
        let file = try openTestFile(folder.file("gate.wav"))
        defer { ExtAudioFileDispose(file) }
        let block = [Float](repeating: 0.1, count: 512)

        spark_capture_attach_file(capture, file, 100)
        spark_capture_process(capture, block, 512, 1_000_000)
        XCTAssertEqual(spark_capture_file_frames(capture), 412, "the file starts inside the block, at the gate")
        XCTAssertEqual(spark_capture_file_first_frame(capture), 100)
        XCTAssertTrue(spark_capture_detach_file(capture))
    }

    func testAGateThatHasPassedStartsWithTheNextBlock() throws {
        let capture = spark_capture_create(1, 8_192, rate, 0, 0, 256, nil)
        defer { spark_capture_destroy(capture) }
        let folder = try TemporaryFolder()
        let file = try openTestFile(folder.file("late.wav"))
        defer { ExtAudioFileDispose(file) }
        let block = [Float](repeating: 0.1, count: 512)

        spark_capture_process(capture, block, 512, 1_000_000)
        spark_capture_attach_file(capture, file, 100)
        spark_capture_process(capture, block, 512, 2_000_000)
        XCTAssertEqual(spark_capture_file_first_frame(capture), 512, "the real start is reported, not the gate")
        XCTAssertEqual(spark_capture_file_frames(capture), 512)
        XCTAssertTrue(spark_capture_detach_file(capture))
    }

    private func openTestFile(_ url: URL) throws -> ExtAudioFileRef {
        var format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 3, mFramesPerPacket: 1, mBytesPerFrame: 3, mChannelsPerFrame: 1, mBitsPerChannel: 24,
            mReserved: 0)
        var created: ExtAudioFileRef?
        XCTAssertEqual(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &format, nil,
                                                 AudioFileFlags.eraseFile.rawValue, &created), noErr)
        let file = try XCTUnwrap(created)
        var client = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32,
            mReserved: 0)
        XCTAssertEqual(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                               UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client), noErr)
        XCTAssertEqual(ExtAudioFileWriteAsync(file, 0, nil), noErr)
        return file
    }
}
