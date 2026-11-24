import AudioToolbox
import CSparkRT
import XCTest
@testable import SparkCore

/// The click and the input on two devices whose clocks disagree, driven by synthetic time stamps.
final class ClickSyncTests: XCTestCase {
    private let hostFrequency = AudioGetHostClockFrequency()

    func testClockMapsFramesAndHostTimesBothWays() {
        let clock = InputClock(sampleRate: 48_000)
        XCTAssertNil(clock.hostTime(ofFrame: 0), "unknown before the first block")
        clock.publish(frame: 4_800, hostTime: 1_000_000_000)
        let ticksPerFrame = hostFrequency / 48_000
        XCTAssertEqual(clock.hostTime(ofFrame: 4_800)!, 1_000_000_000, accuracy: 0.5)
        XCTAssertEqual(clock.hostTime(ofFrame: 9_600)!, 1_000_000_000 + 4_800 * ticksPerFrame, accuracy: 0.5)
        XCTAssertEqual(clock.frame(atHostTime: 1_000_000_000 + 100 * ticksPerFrame)!, 4_900, accuracy: 1e-6)
    }

    func testUnclockedClickStaysSilentUntilTheInputRuns() {
        let clock = InputClock(sampleRate: 48_000)
        let click = spark_click_create(48_000, clock.pointer)
        defer { spark_click_destroy(click) }
        spark_click_set_tempo(click, 120, 4, 1)
        var block = [Float](repeating: 1, count: 512)
        spark_click_render(click, &block, 512, 1_000_000)
        XCTAssertEqual(block.map(abs).max(), 0)
        XCTAssertEqual(spark_click_beat_count(click), 0)
        var frame = 0.0
        XCTAssertFalse(spark_click_anchor_frame(click, &frame))
    }

    /// Ten minutes with the input running 80 ppm fast and the output 120 ppm slow, a large but real disagreement
    /// between two crystals. A click counting its own frames would be 120 ms off by then; this one must stay
    /// within a fraction of a millisecond of the input frames its beats belong to.
    func testBeatsStayOnInputFramesWhenClocksDrift() {
        let inputRate = 44_100.0
        let outputRate = 48_000.0
        let inputTicks = hostFrequency / (inputRate * (1 + 80e-6))
        let outputTicks = hostFrequency / (outputRate * (1 - 120e-6))
        let block = 512
        let start = 10 * hostFrequency
        // Input stamps lag the moment of the callback, output stamps lead it, as with real devices.
        let inputLag = Double(block + 68) * inputTicks
        let outputLead = Double(block + 114) * outputTicks

        let clock = InputClock(sampleRate: inputRate)
        let click = spark_click_create(outputRate, clock.pointer)
        defer { spark_click_destroy(click) }
        let bpm = 133.0
        spark_click_set_tempo(click, bpm, 4, 1)

        var inputBlock = 0
        var outputBlock = 0
        var samples = [Float](repeating: 0, count: block)
        var quietFor = 1_000
        var onsets: [Double] = []
        let end = start + 600 * hostFrequency
        // The output starts a little after the input, as it does when recording.
        let outputStart = start + 0.05 * hostFrequency
        while true {
            let inputStamp = start + Double(inputBlock * block) * inputTicks
            let outputStamp = outputStart + Double(outputBlock * block) * outputTicks
            let inputCall = inputStamp + inputLag
            let outputCall = outputStamp - outputLead
            if min(inputCall, outputCall) > end { break }
            if inputCall <= outputCall {
                clock.publish(frame: Int64(inputBlock * block), hostTime: UInt64(inputStamp))
                inputBlock += 1
                continue
            }
            if inputBlock == 0 {
                outputBlock += 1
                continue
            }
            spark_click_render(click, &samples, UInt32(block), UInt64(outputStamp))
            for (index, sample) in samples.enumerated() {
                if sample != 0 {
                    // The sine starts at zero, so the beat began one frame before its first audible sample.
                    if quietFor >= 500 { onsets.append(outputStamp + Double(index - 1) * outputTicks) }
                    quietFor = 0
                } else {
                    quietFor += 1
                }
            }
            outputBlock += 1
        }

        var anchor = 0.0
        XCTAssertTrue(spark_click_anchor_frame(click, &anchor))
        let interval = ClickTiming.beatInterval(bpm: bpm, inputRate: inputRate)
        XCTAssertGreaterThan(onsets.count, 1_300)
        XCTAssertEqual(spark_click_late_beats(click), 0)
        var worst = 0.0
        for (beat, onset) in onsets.enumerated() {
            let inputFrame = anchor + Double(beat) * interval
            let expected = start + inputFrame * inputTicks
            worst = max(worst, abs(onset - expected) / hostFrequency)
        }
        XCTAssertLessThan(worst, 0.0001, "worst beat \(worst * 1000) ms away from its input frame")
    }

    func testTempoChangeTakesEffectFromTheNextBeat() {
        let clock = InputClock(sampleRate: 48_000)
        let click = spark_click_create(48_000, clock.pointer)
        defer { spark_click_destroy(click) }
        spark_click_set_tempo(click, 120, 4, 1)
        let ticks = hostFrequency / 48_000
        var samples = [Float](repeating: 0, count: 512)
        var onsets: [Int] = []
        var quietFor = 1_000
        for index in 0..<400 {
            let stamp = 1_000 * hostFrequency + Double(index * 512) * ticks
            clock.publish(frame: Int64(index * 512), hostTime: UInt64(stamp))
            if index == 100 { spark_click_set_tempo(click, 60, 4, 1) }
            spark_click_render(click, &samples, 512, UInt64(stamp))
            for (offset, sample) in samples.enumerated() {
                if sample != 0 {
                    if quietFor >= 500 { onsets.append(index * 512 + offset - 1) }
                    quietFor = 0
                } else {
                    quietFor += 1
                }
            }
        }
        // 120 bpm until frame 51 200, so beats at 0, 24 000 and 48 000; the next one already lay at 72 000.
        XCTAssertEqual(Array(onsets.prefix(5)), [0, 24_000, 48_000, 72_000, 120_000])
    }

    // MARK: Grid arithmetic

    func testGridOffsetAddsEveryDelay() {
        let latency = ClickLatency(output: 0.002, input: 0.0015, amp: AmpPart(seconds: 0.009, origin: .setByHand))
        XCTAssertEqual(latency.reported, 0.0035, accuracy: 1e-12)
        XCTAssertEqual(latency.total, 0.0125, accuracy: 1e-12)
        // Two beats of count-in at 120 bpm and 48 kHz end 48 000 frames after the anchor.
        let offset = ClickTiming.gridOffset(anchorFrame: 100_000.5, beatsBefore: 4, bpm: 120, inputRate: 48_000,
                                            fileFirstFrame: 148_000, latency: latency)
        XCTAssertEqual(offset, (196_000.5 - 148_000) / 48_000 + 0.0125, accuracy: 1e-9)
    }

    func testGateLiesOnePreRollBeforeBarOne() {
        let gate = ClickTiming.gateFrame(anchorFrame: 1_000, beatsBefore: 4, bpm: 120, inputRate: 48_000, preRoll: 0.15)
        XCTAssertEqual(gate, 1_000 + 96_000 - 7_200)
        let offset = ClickTiming.gridOffset(anchorFrame: 1_000, beatsBefore: 4, bpm: 120, inputRate: 48_000,
                                            fileFirstFrame: gate, latency: ClickLatency())
        XCTAssertEqual(offset, 0.15, accuracy: 1e-9)
    }

    // MARK: Latency measurement

    /// Clicks that arrive `lag` frames late, slightly smeared like after an amp's filters, over a noise floor.
    private func loopback(lag: Double, jitter: Double = 0, beats: Int = 12, rate: Double = 44_100,
                          level: Float = 0.4) -> (samples: [Float], expected: [Double]) {
        let interval = rate * 0.6
        let first = rate * 0.3
        var samples = [Float](repeating: 0, count: Int(first + Double(beats + 1) * interval))
        var seed: UInt64 = 42
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2000) / 1000 - 1
        }
        for index in samples.indices { samples[index] = random() * 0.0005 }
        var expected: [Double] = []
        for beat in 0..<beats {
            let beatFrame = first + Double(beat) * interval
            expected.append(beatFrame)
            let shift = jitter * (beat % 2 == 0 ? 1 : -1)
            let onset = Int((beatFrame + lag + shift).rounded())
            for step in 0..<Int(rate * 0.03) {
                let t = Double(step) / rate
                let rise = min(Double(step) / 4, 1)
                samples[onset + step] += level * Float(rise * sin(2 * .pi * 1175 * t) * exp(-t / 0.012))
            }
        }
        return (samples, expected)
    }

    func testMeasurementFindsTheDelayToAFewSamples() throws {
        let (samples, expected) = loopback(lag: 612)
        let analysis = LatencyProbe.analyze(samples: samples, sampleRate: 44_100, expected: expected)
        let result = try LatencyProbe.evaluate(analysis, sampleRate: 44_100, reported: 0.004)
        XCTAssertEqual(result.detected, 12)
        XCTAssertEqual(result.measured, 612 / 44_100, accuracy: 0.0001)
        XCTAssertEqual(result.correction, 612 / 44_100 - 0.004, accuracy: 0.0001)
        XCTAssertLessThan(result.spread, 0.0002)
    }

    /// The click as the click engine plays it, a sine from phase 0 fading over 12 ms, with 1760 Hz on every first
    /// beat of 4, `lag` frames late and through a synthetic amp: a high pass at 80 Hz, a soft drive and a cabinet's
    /// low pass at 4.5 kHz of fourth order, over a faint noise floor.
    private func clicksThroughAnAmp(lag: Double, beats: Int = 12, rate: Double) -> (samples: [Float], expected: [Double]) {
        let interval = rate * 0.6
        let first = rate * 0.3
        var dry = [Double](repeating: 0, count: Int(first + Double(beats + 1) * interval))
        var expected: [Double] = []
        for beat in 0..<beats {
            let beatFrame = first + Double(beat) * interval
            expected.append(beatFrame)
            let onset = Int((beatFrame + lag).rounded())
            let frequency = beat % 4 == 0 ? 1760.0 : 1175.0
            let amplitude = beat % 4 == 0 ? 0.5 : 0.35
            for step in 0..<Int(rate * 0.08) {
                let t = Double(step) / rate
                dry[onset + step] += amplitude * sin(2 * .pi * frequency * t) * exp(-t / 0.012)
            }
        }
        var highPass = Biquad.highPass(80, rate: rate)
        var low1 = Biquad.lowPass(4_500, rate: rate)
        var low2 = Biquad.lowPass(4_500, rate: rate)
        var generator = SeededGenerator(seed: 9)
        let samples = dry.map { value -> Float in
            let driven = tanh(3 * highPass.process(value)) / 3
            return Float(low2.process(low1.process(driven)) + generator.gaussian() * 0.0003)
        }
        return (samples, expected)
    }

    /// A second-order filter after the Audio EQ Cookbook, Q of 0.707.
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        static func lowPass(_ frequency: Double, rate: Double) -> Biquad { make(frequency, rate: rate, high: false) }
        static func highPass(_ frequency: Double, rate: Double) -> Biquad { make(frequency, rate: rate, high: true) }

        private static func make(_ frequency: Double, rate: Double, high: Bool) -> Biquad {
            let omega = 2 * Double.pi * frequency / rate
            let alpha = sin(omega) / (2 * 0.707)
            let a0 = 1 + alpha
            let c = cos(omega)
            let b0 = (high ? (1 + c) : (1 - c)) / 2
            let b1 = high ? -(1 + c) : (1 - c)
            return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b0 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            (x2, x1, y2, y1) = (x1, x, y1, y)
            return y
        }
    }

    func testTheMeasurementPlacesAClickWhereTheReviewPlacesANote() throws {
        // A note played exactly on the click must review as on it, so both find the same moment in the same sound.
        let stamp = TimingStamp(clickOnThroughout: true, latency: ClickLatency(
            amp: AmpPart(seconds: 0, origin: .measured(spread: 0, date: Date(timeIntervalSince1970: 1_795_435_200)))))
        for rate in [44_100.0, 48_000.0] {
            let lag = 0.0137 * rate
            let (samples, expected) = clicksThroughAnAmp(lag: lag, rate: rate)
            let analysis = LatencyProbe.analyze(samples: samples, sampleRate: rate, expected: expected)
            XCTAssertEqual(analysis.lags.count, expected.count)
            let grid = BeatGrid(bpm: 100, beatsPerBar: 4, offset: expected[0] / rate)
            guard case .review(let review) = TimingReview.review(samples: samples, sampleRate: rate, grid: grid,
                                                                 stamp: stamp) else {
                return XCTFail("the clicks must have a review")
            }
            let onsets = review.onsets.filter(\.isCounted)
            XCTAssertEqual(onsets.count, expected.count)
            for (lag, onset) in zip(analysis.lags, onsets) {
                XCTAssertEqual(lag / rate, try XCTUnwrap(onset.offset), accuracy: 0.0001,
                               "\(rate) Hz, click \(onset.gridPoint ?? -1)")
            }
            let mean = analysis.lags.reduce(0, +) / Double(analysis.lags.count)
            print("NOTE click through the amp at \(rate) Hz: measured \(String(format: "%.3f", (mean - lag) / rate * 1000)) ms after it begins")
        }
    }

    func testMeasurementWithoutSignalIsRefused() {
        let (samples, expected) = loopback(lag: 600, level: 0)
        let analysis = LatencyProbe.analyze(samples: samples, sampleRate: 44_100, expected: expected)
        XCTAssertThrowsError(try LatencyProbe.evaluate(analysis, sampleRate: 44_100, reported: 0)) {
            XCTAssertEqual($0 as? LatencyProbeError, .noSignal)
        }
    }

    func testUnevenMeasurementIsRefused() {
        // Every other click a millisecond and a half early or late: 3 ms spread, too much to trust.
        let (samples, expected) = loopback(lag: 600, jitter: 66)
        let analysis = LatencyProbe.analyze(samples: samples, sampleRate: 44_100, expected: expected)
        XCTAssertThrowsError(try LatencyProbe.evaluate(analysis, sampleRate: 44_100, reported: 0)) {
            guard case .unstable = $0 as? LatencyProbeError else { return XCTFail("expected unstable, got \($0)") }
        }
    }
}
