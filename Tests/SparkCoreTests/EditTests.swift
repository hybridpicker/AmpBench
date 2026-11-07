import XCTest
@testable import SparkCore

final class EditTests: XCTestCase {
    func testAutoLevelReachesTargetPeak() {
        // The Spark's measured peak of about -24 dBFS.
        let peak = Float(pow(10, -24.0 / 20))
        XCTAssertEqual(AutoLevel.gainDB(forPeak: peak), 23, accuracy: 0.01)
    }

    func testAutoLevelIsLimitedForNearSilence() {
        XCTAssertEqual(AutoLevel.gainDB(forPeak: 0.00001), AutoLevel.maxGainDB)
    }

    func testAutoLevelLeavesLoudAndSilentRecordingsAlone() {
        XCTAssertEqual(AutoLevel.gainDB(forPeak: 0), 0)
        XCTAssertEqual(AutoLevel.gainDB(forPeak: 0.95), 0, "already within 0.1 dB of the target")
        XCTAssertEqual(AutoLevel.gainDB(forPeak: 1.2), 0)
    }

    func testTotalGainCombinesManualAndEnabledAutoLevel() {
        var edit = EditList(gainDB: -3, autoLevelEnabled: true, autoLevelDB: 12)
        XCTAssertEqual(edit.totalGainDB, 9)
        edit.autoLevelEnabled = false
        XCTAssertEqual(edit.totalGainDB, -3)
    }

    func testPeakAfterGainWarnsAboutClipping() {
        let edit = EditList(gainDB: 6)
        XCTAssertEqual(edit.peakAfterGain(originalPeakDB: -3), 3)
        XCTAssertNil(edit.peakAfterGain(originalPeakDB: nil))
    }

    func testRendererResolvesTrim() {
        let renderer = EditRenderer(edit: EditList(trimStart: 1, trimEnd: 3), sampleRate: 100, totalFrames: 1000)
        XCTAssertEqual(renderer.startFrame, 100)
        XCTAssertEqual(renderer.endFrame, 300)
        XCTAssertEqual(renderer.lengthFrames, 200)
    }

    func testRendererClampsTrimToFile() {
        let renderer = EditRenderer(edit: EditList(trimStart: -5, trimEnd: 99), sampleRate: 100, totalFrames: 1000)
        XCTAssertEqual(renderer.startFrame, 0)
        XCTAssertEqual(renderer.endFrame, 1000)
    }

    func testRendererOutsideWindowIsSilent() {
        let renderer = EditRenderer(edit: EditList(trimStart: 1, trimEnd: 2), sampleRate: 100, totalFrames: 1000)
        XCTAssertEqual(renderer.gain(atFrame: 99), 0)
        XCTAssertEqual(renderer.gain(atFrame: 100), 1)
        XCTAssertEqual(renderer.gain(atFrame: 199), 1)
        XCTAssertEqual(renderer.gain(atFrame: 200), 0)
    }

    func testFadesRiseAndFallMonotonically() {
        let renderer = EditRenderer(edit: EditList(fadeIn: 1, fadeOut: 1), sampleRate: 100, totalFrames: 1000)
        XCTAssertEqual(renderer.gain(atFrame: 0), 0)
        XCTAssertEqual(renderer.gain(atFrame: 50), 0.5, accuracy: 0.01)
        XCTAssertEqual(renderer.gain(atFrame: 500), 1)
        XCTAssertEqual(renderer.gain(atFrame: 949), 0.5, accuracy: 0.02)
        XCTAssertEqual(renderer.gain(atFrame: 999), 0)
        var previous: Float = -1
        for frame in Int64(0)..<100 {
            XCTAssertGreaterThanOrEqual(renderer.gain(atFrame: frame), previous)
            previous = renderer.gain(atFrame: frame)
        }
    }

    func testFadesRespectTrimWindow() {
        let renderer = EditRenderer(edit: EditList(trimStart: 2, trimEnd: 4, fadeIn: 0.5), sampleRate: 100, totalFrames: 1000)
        XCTAssertEqual(renderer.gain(atFrame: 200), 0, "the fade starts at the trim point")
        XCTAssertEqual(renderer.gain(atFrame: 250), 1)
    }

    func testOverlappingFadesAreScaledToFit() {
        let renderer = EditRenderer(edit: EditList(fadeIn: 3, fadeOut: 1), sampleRate: 100, totalFrames: 200)
        XCTAssertEqual(renderer.fadeInFrames + renderer.fadeOutFrames, 200)
        XCTAssertEqual(renderer.fadeInFrames, 150)
    }

    func testApplyMatchesGainFunction() {
        let edit = EditList(trimStart: 0.1, trimEnd: 0.9, fadeIn: 0.2, fadeOut: 0.2, gainDB: 6)
        let renderer = EditRenderer(edit: edit, sampleRate: 100, totalFrames: 100)
        var samples = [Float](repeating: 1, count: 100)
        samples.withUnsafeMutableBufferPointer { renderer.apply(to: $0.baseAddress!, count: 100, firstFrame: 0) }
        for frame in 0..<100 {
            XCTAssertEqual(samples[frame], renderer.gain(atFrame: Int64(frame)), accuracy: 0.0001)
        }
    }

    func testApplyPlainGain() {
        let renderer = EditRenderer(edit: EditList(gainDB: 20), sampleRate: 100, totalFrames: 100)
        var samples = [Float](repeating: 0.01, count: 10)
        samples.withUnsafeMutableBufferPointer { renderer.apply(to: $0.baseAddress!, count: 10, firstFrame: 5) }
        XCTAssertEqual(samples[3], 0.1, accuracy: 0.0001)
    }

    func testEditDecodesFromOlderJSONWithMissingFields() throws {
        let edit = try JSONDecoder().decode(EditList.self, from: Data(#"{"gainDB": 2}"#.utf8))
        XCTAssertEqual(edit.gainDB, 2)
        XCTAssertEqual(edit.trimStart, 0)
        XCTAssertNil(edit.trimEnd)
    }
}

final class PlaybackPlanningTests: XCTestCase {
    func testPlannerCoversWindowExactlyOnce() {
        var planner = PlaybackPlanner(start: 100, end: 350, looping: false, chunkFrames: 100, cursor: 100)
        var chunks: [PlaybackPlanner.Chunk] = []
        while let chunk = planner.next() { chunks.append(chunk) }
        XCTAssertEqual(chunks.map(\.frame), [100, 200, 300])
        XCTAssertEqual(chunks.map(\.count), [100, 100, 50])
        XCTAssertEqual(chunks.map(\.isLast), [false, false, true])
    }

    func testPlannerLoopsBackToStart() {
        var planner = PlaybackPlanner(start: 0, end: 150, looping: true, chunkFrames: 100, cursor: 100)
        XCTAssertEqual(planner.next()?.frame, 100)
        XCTAssertEqual(planner.next()?.frame, 0)
        XCTAssertEqual(planner.next()?.frame, 100)
        XCTAssertEqual(planner.next()?.isLast, false)
    }

    func testPlannerClampsCursorIntoWindow() {
        var planner = PlaybackPlanner(start: 100, end: 200, looping: false, chunkFrames: 50, cursor: 5)
        XCTAssertEqual(planner.next()?.frame, 100)
    }

    func testPlannerWithEmptyWindowProducesNothing() {
        var planner = PlaybackPlanner(start: 100, end: 100, looping: true, chunkFrames: 50, cursor: 100)
        XCTAssertNil(planner.next())
    }

    func testTimelineMapsAcrossLoopJump() {
        var timeline = PlaybackTimeline()
        timeline.append(fileStart: 500, count: 100)
        timeline.append(fileStart: 100, count: 100)
        XCTAssertEqual(timeline.fileFrame(atPlayerSample: 0), 500)
        XCTAssertEqual(timeline.fileFrame(atPlayerSample: 50), 550)
        XCTAssertEqual(timeline.fileFrame(atPlayerSample: 100), 100)
        XCTAssertEqual(timeline.fileFrame(atPlayerSample: 150), 150)
    }
}
