import AudioToolbox
import CSparkRT
import XCTest
@testable import SparkCore

/// Drives the realtime code directly with synthetic samples, so timing and contents are exact.
final class CaptureRealtimeTests: XCTestCase {
    private let rate = 44_100.0
    private var folder: TemporaryFolder!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
    }

    private func makeCapture(channels: UInt32 = 1, retroFrames: UInt64 = 0, margin: UInt64 = 0,
                             binFrames: UInt32 = 256) -> OpaquePointer {
        spark_capture_create(channels, 8192, rate, retroFrames, margin, binFrames)
    }

    private func makeFile(_ url: URL, channels: UInt32 = 1) throws -> ExtAudioFileRef {
        var format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: channels * 3, mFramesPerPacket: 1, mBytesPerFrame: channels * 3,
            mChannelsPerFrame: channels, mBitsPerChannel: 24, mReserved: 0)
        var file: ExtAudioFileRef?
        XCTAssertEqual(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &format, nil,
                                                 AudioFileFlags.eraseFile.rawValue, &file), noErr)
        var client = CaptureEngine.clientFormat(rate: rate, channels: channels)
        XCTAssertEqual(ExtAudioFileSetProperty(file!, kExtAudioFileProperty_ClientDataFormat,
                                               UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client), noErr)
        XCTAssertEqual(ExtAudioFileWriteAsync(file!, 0, nil), noErr)
        return file!
    }

    func testLevelIsPeakSinceLastReadAndResets() {
        let capture = makeCapture()
        defer { spark_capture_destroy(capture) }
        spark_capture_process(capture, [0.1, -0.5, 0.2], 3, 0)
        spark_capture_process(capture, [0.3], 1, 0)
        XCTAssertEqual(spark_capture_take_level(capture), 0.5)
        XCTAssertEqual(spark_capture_take_level(capture), 0)
    }

    func testClipFlagLatchesUntilRead() {
        let capture = makeCapture()
        defer { spark_capture_destroy(capture) }
        spark_capture_process(capture, [0.5], 1, 0)
        XCTAssertFalse(spark_capture_take_clip(capture))
        spark_capture_process(capture, [0.99997], 1, 0)
        spark_capture_process(capture, [0.1], 1, 0)
        XCTAssertTrue(spark_capture_take_clip(capture))
        XCTAssertFalse(spark_capture_take_clip(capture))
    }

    func testNothingIsWrittenWithoutFile() {
        let capture = makeCapture()
        defer { spark_capture_destroy(capture) }
        spark_capture_process(capture, [0.5, 0.5], 2, 0)
        XCTAssertEqual(spark_capture_file_frames(capture), 0)
        XCTAssertEqual(spark_capture_callback_count(capture), 1)
    }

    func testFileReceivesEveryFrameExactly() throws {
        let capture = makeCapture()
        defer { spark_capture_destroy(capture) }
        let url = folder.file("a.wav")
        let file = try makeFile(url)
        spark_capture_attach_file(capture, file, 0)
        let samples = Synthetic.sine(seconds: 0.5, amplitude: 0.25)
        var position = 0
        while position < samples.count {
            let count = min(512, samples.count - position)
            samples.withUnsafeBufferPointer {
                spark_capture_process(capture, $0.baseAddress! + position, UInt32(count), 0)
            }
            position += count
        }
        XCTAssertTrue(spark_capture_detach_file(capture))
        XCTAssertEqual(ExtAudioFileDispose(file), noErr)

        XCTAssertEqual(spark_capture_file_frames(capture), 22_050)
        XCTAssertEqual(spark_capture_file_peak(capture), 0.25, accuracy: 0.001)
        let facts = try readAudio(url)
        XCTAssertEqual(facts.frames, 22_050)
        XCTAssertEqual(facts.frequency(), 1000, accuracy: 5)
        XCTAssertEqual(facts.peak, 0.25, accuracy: 0.001)
    }

    func testFramesAfterDetachAreNotWritten() throws {
        let capture = makeCapture()
        defer { spark_capture_destroy(capture) }
        let file = try makeFile(folder.file("a.wav"))
        spark_capture_attach_file(capture, file, 0)
        spark_capture_process(capture, [0.5, 0.5], 2, 0)
        XCTAssertTrue(spark_capture_detach_file(capture))
        spark_capture_process(capture, [0.9, 0.9], 2, 0)
        XCTAssertEqual(spark_capture_file_frames(capture), 2)
        XCTAssertEqual(spark_capture_file_peak(capture), 0.5)
        ExtAudioFileDispose(file)
    }

    func testGateDiscardsAudioBeforeExactFrame() throws {
        let capture = makeCapture()
        defer { spark_capture_destroy(capture) }
        let file = try makeFile(folder.file("a.wav"))
        let ticksPerFrame = AudioGetHostClockFrequency() / rate
        let start: UInt64 = 1_000_000_000
        let gate = start + UInt64(ticksPerFrame * 700)
        spark_capture_attach_file(capture, file, gate)

        let block = [Float](repeating: 0.1, count: 512)
        spark_capture_process(capture, block, 512, start)
        XCTAssertEqual(spark_capture_file_frames(capture), 0, "the whole block lies before the gate")

        spark_capture_process(capture, block, 512, start + UInt64(ticksPerFrame * 512))
        XCTAssertEqual(spark_capture_file_frames(capture), 512 - 188, "only the part from frame 700 on is written")

        spark_capture_process(capture, block, 512, start + UInt64(ticksPerFrame * 1024))
        XCTAssertEqual(spark_capture_file_frames(capture), 512 - 188 + 512)
        XCTAssertTrue(spark_capture_detach_file(capture))
        ExtAudioFileDispose(file)
    }

    func testOverviewBinsMatchTheSignal() throws {
        let capture = makeCapture(binFrames: 100)
        defer { spark_capture_destroy(capture) }
        let file = try makeFile(folder.file("a.wav"))
        spark_capture_attach_file(capture, file, 0)
        var samples = [Float](repeating: 0.1, count: 250)
        samples[150] = -0.8
        spark_capture_process(capture, samples, 250, 0)
        XCTAssertTrue(spark_capture_detach_file(capture))
        ExtAudioFileDispose(file)

        var bins = [Float](repeating: 0, count: 20)
        let count = spark_capture_read_overview(capture, &bins, 10)
        XCTAssertEqual(count, 3, "two full bins and the rest when detaching")
        XCTAssertEqual(bins[0], 0.1)
        XCTAssertEqual(bins[2], -0.8, "bin 1 holds the dip")
        XCTAssertEqual(bins[3], 0.1)
        XCTAssertEqual(spark_capture_dropped_bins(capture), 0)
    }

    func testAttachResetsCountersForNextRecording() throws {
        let capture = makeCapture()
        defer { spark_capture_destroy(capture) }
        var file = try makeFile(folder.file("a.wav"))
        spark_capture_attach_file(capture, file, 0)
        spark_capture_process(capture, [0.9, 0.9], 2, 0)
        XCTAssertTrue(spark_capture_detach_file(capture))
        ExtAudioFileDispose(file)

        file = try makeFile(folder.file("b.wav"))
        spark_capture_attach_file(capture, file, 0)
        XCTAssertEqual(spark_capture_file_frames(capture), 0)
        XCTAssertEqual(spark_capture_file_peak(capture), 0)
        XCTAssertTrue(spark_capture_detach_file(capture))
        ExtAudioFileDispose(file)
    }

    // MARK: Retro buffer

    func testRetroIsDisabledByDefault() {
        let capture = makeCapture()
        defer { spark_capture_destroy(capture) }
        spark_capture_process(capture, [0.5], 1, 0)
        XCTAssertEqual(spark_capture_retro_available_frames(capture), 0)
    }

    func testRetroKeepsOnlyTheLatestFramesAcrossWrapAround() {
        let capture = makeCapture(retroFrames: 100, margin: 10)
        defer { spark_capture_destroy(capture) }
        var next: Float = 0
        for _ in 0..<7 {
            let block = (0..<37).map { Float($0) + next }
            next += 37
            spark_capture_process(capture, block, 37, 0)
        }
        XCTAssertEqual(spark_capture_retro_available_frames(capture), 100)

        var copy = [Float](repeating: -1, count: 100)
        XCTAssertEqual(spark_capture_retro_copy_latest(capture, &copy, 100), 100)
        XCTAssertEqual(copy, (159..<259).map { Float($0) }, "exactly the newest 100 frames, in order")
    }

    func testRetroCopiesLessThanRequestedWhenBufferIsYoung() {
        let capture = makeCapture(retroFrames: 100, margin: 10)
        defer { spark_capture_destroy(capture) }
        spark_capture_process(capture, [1, 2, 3], 3, 0)
        var copy = [Float](repeating: -1, count: 50)
        XCTAssertEqual(spark_capture_retro_copy_latest(capture, &copy, 50), 3)
        XCTAssertEqual(Array(copy[0..<3]), [1, 2, 3])
    }

    func testRetroKeepsChannelsTogether() {
        let capture = makeCapture(channels: 2, retroFrames: 10, margin: 2)
        defer { spark_capture_destroy(capture) }
        spark_capture_process(capture, [1, -1, 2, -2], 2, 0)
        var copy = [Float](repeating: 0, count: 4)
        XCTAssertEqual(spark_capture_retro_copy_latest(capture, &copy, 2), 2)
        XCTAssertEqual(copy, [1, -1, 2, -2])
    }

    func testRetroWritesNothingToDisk() throws {
        let capture = makeCapture(retroFrames: 44_100, margin: 100)
        defer { spark_capture_destroy(capture) }
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        spark_capture_process(capture, Synthetic.sine(seconds: 0.1), 4410, 0)
        XCTAssertEqual(spark_capture_file_frames(capture), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.path), before)
    }
}

final class ClickRealtimeTests: XCTestCase {
    private let rate = 48_000.0

    /// The frames at which a click starts.
    private func onsets(_ samples: [Float]) -> [Int] {
        var result: [Int] = []
        var quietFor = 1000
        for (index, sample) in samples.enumerated() {
            if abs(sample) > 0.0001 {
                if quietFor >= 500 { result.append(index) }
                quietFor = 0
            } else {
                quietFor += 1
            }
        }
        return result
    }

    private func render(_ click: OpaquePointer, frames: Int, block: Int = 512) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        var position = 0
        while position < frames {
            let count = min(block, frames - position)
            out.withUnsafeMutableBufferPointer {
                spark_click_render(click, $0.baseAddress! + position, UInt32(count))
            }
            position += count
        }
        return out
    }

    func testBeatsLandOnExactFrames() {
        let click = spark_click_create(rate)
        defer { spark_click_destroy(click) }
        spark_click_set_tempo(click, 120, 4, 1)
        // A sine starts at zero, so the first audible sample of a click is one frame after its start.
        XCTAssertEqual(onsets(render(click, frames: 96_000)), [1, 24_001, 48_001, 72_001])
    }

    func testBlockSizeDoesNotShiftBeats() {
        let first = spark_click_create(rate)
        let second = spark_click_create(rate)
        defer {
            spark_click_destroy(first)
            spark_click_destroy(second)
        }
        spark_click_set_tempo(first, 133, 4, 1)
        spark_click_set_tempo(second, 133, 4, 1)
        XCTAssertEqual(render(first, frames: 48_000, block: 64), render(second, frames: 48_000, block: 1024))
    }

    func testFirstBeatOfBarIsAccented() {
        let click = spark_click_create(rate)
        defer { spark_click_destroy(click) }
        spark_click_set_tempo(click, 120, 3, 1)
        let samples = render(click, frames: 96_000)
        func peak(around frame: Int) -> Float { samples[frame..<(frame + 500)].map { abs($0) }.max()! }
        XCTAssertGreaterThan(peak(around: 0), peak(around: 24_000) * 1.2)
        XCTAssertGreaterThan(peak(around: 72_000), peak(around: 48_000) * 1.2, "beat 4 starts the next 3/4 bar")
    }

    func testMuteSilencesFromFrameButBeatsKeepCounting() {
        let click = spark_click_create(rate)
        defer { spark_click_destroy(click) }
        spark_click_set_tempo(click, 120, 4, 1)
        spark_click_set_mute_from(click, 48_000)
        let samples = render(click, frames: 96_000)
        XCTAssertEqual(onsets(samples), [1, 24_001])
        XCTAssertEqual(spark_click_beat_count(click), 4)
    }

    func testVolumeScalesTheClick() {
        let click = spark_click_create(rate)
        defer { spark_click_destroy(click) }
        spark_click_set_tempo(click, 120, 4, 0.1)
        XCTAssertLessThanOrEqual(render(click, frames: 4000).map { abs($0) }.max()!, 0.1)
    }

    func testCountInLengthFollowsSettings() {
        let settings = MetronomeSettings(bpm: 120, beatsPerBar: 3, countInBars: 2)
        XCTAssertEqual(settings.countInBeats, 6)
        XCTAssertEqual(settings.countInSeconds, 3)
    }
}
