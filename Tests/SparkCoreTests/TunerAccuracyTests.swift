import XCTest
@testable import SparkCore

/// The tuner's precision, measured with synthetic signals only: sine, sawtooth, Karplus-Strong strings and noise.
/// No test reads a recording.
final class TunerAccuracyTests: XCTestCase {
    struct Sample {
        let time: Double
        let reading: PitchReading?
    }

    /// Feeds a signal in blocks of 256 samples, as audio callbacks deliver them, and notes the reading after each.
    static func track(_ signal: [Float], sampleRate: Double, block: Int = 256) -> (PitchTracker, [Sample]) {
        let tracker = PitchTracker(sampleRate: sampleRate)
        var timeline: [Sample] = []
        var offset = 0
        while offset < signal.count {
            let end = min(offset + block, signal.count)
            signal.withUnsafeBufferPointer { tracker.process(UnsafeBufferPointer(rebasing: $0[offset..<end])) }
            timeline.append(Sample(time: tracker.seconds, reading: tracker.reading))
            offset = end
        }
        return (tracker, timeline)
    }

    static func cents(_ value: Double, _ reference: Double) -> Double { 1200 * log2(value / reference) }

    /// The deviation of every live reading in a time window from the true frequency.
    static func errors(_ timeline: [Sample], truth: Double, from start: Double, to end: Double) -> [Double] {
        timeline.filter { $0.time >= start && $0.time <= end }.compactMap { sample in
            guard let reading = sample.reading, !reading.isHeld else { return nil }
            return cents(reading.frequency, truth)
        }
    }

    // The range from H0 (B0) of a five-string bass to E6 and beyond, as notes of the scale, plus both ends.
    static let range: [Double] = [30, 30.87, 41.2, 55, 61.74, 73.42, 82.41, 98, 110, 146.83, 196, 246.94, 329.63,
                                   440, 523.25, 659.26, 880, 987.77, 1174.66, 1318.51, 1400]

    // MARK: Sine

    func testSineWithinATenthOfACentOverTheWholeRange() {
        for rate in [44_100.0, 48_000.0] {
            for frequency in Self.range {
                // Slightly off the note, so nothing rests on round numbers.
                let truth = frequency * pow(2, 3.7 / 1200)
                let signal = TunerTestSignal.sine(frequency: truth, sampleRate: rate, seconds: 1.6)
                let (_, timeline) = Self.track(signal, sampleRate: rate)
                let errors = Self.errors(timeline, truth: truth, from: 0.8, to: 1.6)
                XCTAssertFalse(errors.isEmpty, "\(frequency) Hz at \(rate): no reading")
                let worst = errors.map(abs).max() ?? .infinity
                XCTAssertLessThanOrEqual(worst, 0.1, "\(frequency) Hz at \(Int(rate)) Hz: \(worst) cents")
            }
        }
    }

    func testSineAt96Kilohertz() {
        for frequency in [30.87, 82.41, 440, 1400] {
            let signal = TunerTestSignal.sine(frequency: frequency, sampleRate: 96_000, seconds: 1.4)
            let (_, timeline) = Self.track(signal, sampleRate: 96_000, block: 512)
            let worst = Self.errors(timeline, truth: frequency, from: 0.8, to: 1.4).map(abs).max() ?? .infinity
            XCTAssertLessThanOrEqual(worst, 0.1, "\(frequency) Hz at 96 kHz: \(worst) cents")
        }
    }

    // MARK: Strings with overtones, decay and noise

    func testDecayingSawtoothInNoise() {
        for frequency in [30.87, 41.2, 82.41, 110, 196, 329.63, 659.26, 1318.51] {
            let truth = frequency * pow(2, -6.2 / 1200)
            let clean = TunerTestSignal.sawtooth(frequency: truth, sampleRate: 48_000, seconds: 3, decay: 1.6)
            let signal = TunerTestSignal.addingNoise(clean, decibels: -30)
            let (_, timeline) = Self.track(signal, sampleRate: 48_000)
            let errors = Self.errors(timeline, truth: truth, from: 0.6, to: 2.6)
            XCTAssertGreaterThan(errors.count, 100, "\(frequency) Hz: too few readings")
            let worst = errors.map(abs).max() ?? .infinity
            XCTAssertLessThanOrEqual(worst, 0.5, "sawtooth \(frequency) Hz: \(worst) cents")
        }
    }

    /// When a decaying signal has fallen `decibels` below the RMS of its first half second.
    static func time(_ signal: [Float], sampleRate: Double, fallenBy decibels: Double) -> Double {
        let head = Int(min(0.5 * sampleRate, Double(signal.count)))
        let reference = (signal[0..<head].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(head)).squareRoot()
        let block = Int(0.05 * sampleRate)
        var start = head
        while start + block <= signal.count {
            let rms = (signal[start..<(start + block)].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(block))
                .squareRoot()
            if 20 * log10(max(rms, 1e-12) / reference) < -decibels { return Double(start) / sampleRate }
            start += block
        }
        return Double(signal.count) / sampleRate
    }

    /// Noise 30 dB below the string's first half second. The string rings out, so the precision is checked while
    /// it is still at least 10 dB above the noise, after it has settled (1 s for the bass notes below 50 Hz).
    func testKarplusStrongStringInNoise() {
        for rate in [44_100.0, 48_000.0] {
            for frequency in [30.87, 41.2, 55, 73.42, 82.41, 110, 146.83, 196, 246.94, 329.63, 659.26, 1318.51] {
                let truth = frequency * pow(2, 4.4 / 1200)
                let ring = frequency > 600 ? 2.5 : 4.0
                let clean = TunerTestSignal.karplusStrong(frequency: truth, sampleRate: rate, seconds: 3, ringTime: ring)
                let signal = TunerTestSignal.addingNoise(clean, decibels: -30)
                let (_, timeline) = Self.track(signal, sampleRate: rate)
                let settle = frequency < 50 ? 1.0 : 0.6
                let end = Self.time(clean, sampleRate: rate, fallenBy: 20)
                let errors = Self.errors(timeline, truth: truth, from: settle, to: end)
                XCTAssertGreaterThan(errors.count, 30, "\(frequency) Hz at \(rate): too few readings until \(end) s")
                let worst = errors.map(abs).max() ?? .infinity
                XCTAssertLessThanOrEqual(worst, 0.5, "string \(frequency) Hz at \(Int(rate)): \(worst) cents")
            }
        }
    }

    /// The Karplus-Strong string really sounds at its frequency: an independent check of the test signal itself.
    /// The magnitude spectrum of a decaying tone under a Hann window peaks exactly at the tone, so the peak of a long
    /// DFT, found by golden-section search, gives the fundamental without anything from the tuner.
    func testKarplusStrongFundamentalIsWhereItShouldBe() {
        let rate = 48_000.0
        for truth in [30.87, 82.41, 329.63, 1318.51] {
            let signal = TunerTestSignal.karplusStrong(frequency: truth, sampleRate: rate, seconds: 4.5)
            let start = Int(0.5 * rate), count = Int(4 * rate)
            func magnitude(_ frequency: Double) -> Double {
                var real = 0.0, imaginary = 0.0
                let omega = 2 * Double.pi * frequency / rate
                for index in 0..<count {
                    let window = 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(count - 1))
                    let value = window * Double(signal[start + index])
                    real += value * cos(omega * Double(index))
                    imaginary -= value * sin(omega * Double(index))
                }
                return (real * real + imaginary * imaginary).squareRoot()
            }
            var low = truth * 0.995, high = truth * 1.005
            let ratio = (5.0.squareRoot() - 1) / 2
            for _ in 0..<40 {
                let a = high - ratio * (high - low), b = low + ratio * (high - low)
                if magnitude(a) > magnitude(b) { high = b } else { low = a }
            }
            XCTAssertEqual(Self.cents((low + high) / 2, truth), 0, accuracy: 0.05, "string at \(truth) Hz")
        }
    }

    // MARK: Steadiness

    func testHeldToneStaysWithinTwoTenthsOfACent() {
        for frequency in [41.2, 82.41, 110, 196, 329.63, 987.77] {
            let clean = TunerTestSignal.sawtooth(frequency: frequency, sampleRate: 48_000, seconds: 3)
            let signal = TunerTestSignal.addingNoise(clean, decibels: -30, seed: 23)
            let (_, timeline) = Self.track(signal, sampleRate: 48_000)
            let errors = Self.errors(timeline, truth: frequency, from: 1, to: 3)
            let mean = errors.reduce(0, +) / Double(errors.count)
            let spread = errors.map { abs($0 - mean) }.max() ?? .infinity
            XCTAssertLessThanOrEqual(spread, 0.2, "\(frequency) Hz: ±\(spread) cents")
        }
    }

    // MARK: Octaves

    /// A low string rings out for seven seconds into the noise: the tuner never jumps to an overtone or an undertone.
    func testNoOctaveErrorWhileALowStringRingsOut() {
        for (frequency, ring) in [(82.41, 5.0), (41.2, 6.0), (30.87, 6.0), (61.74, 4.0), (110, 3.0)] {
            let clean = TunerTestSignal.karplusStrong(frequency: frequency, sampleRate: 48_000, seconds: 7,
                                                      ringTime: ring, seed: 3)
            let signal = TunerTestSignal.addingNoise(clean, decibels: -30, seed: 5)
            let (tracker, timeline) = Self.track(signal, sampleRate: 48_000)
            XCTAssertEqual(tracker.lockCount, 1, "\(frequency) Hz: locked once and never jumped to another pitch")
            XCTAssertEqual(tracker.phasePrunes, 0, "\(frequency) Hz: the fading tone was never taken for a turning peg")
            let readings = timeline.compactMap(\.reading)
            XCTAssertFalse(readings.isEmpty)
            let worst = readings.map { abs(Self.cents($0.frequency, frequency)) }.max() ?? 0
            XCTAssertLessThan(worst, 50, "\(frequency) Hz: a reading \(worst) cents away")
        }
    }

    /// A tone whose second harmonic is twice as strong as its fundamental is still read at the fundamental.
    func testWeakFundamentalIsNotReadAsItsOctave() {
        let rate = 48_000.0
        for frequency in [41.2, 82.41, 110] {
            let count = Int(2 * rate)
            var signal = [Float](repeating: 0, count: count)
            for index in 0..<count {
                let time = Double(index) / rate
                let value = 0.1 * sin(2 * .pi * frequency * time) + 0.2 * sin(2 * .pi * 2 * frequency * time + 0.4)
                    + 0.12 * sin(2 * .pi * 3 * frequency * time + 1.1) + 0.08 * sin(2 * .pi * 4 * frequency * time)
                signal[index] = Float(value * exp(-time / 1.5))
            }
            let (_, timeline) = Self.track(signal, sampleRate: rate)
            let readings = timeline.compactMap(\.reading)
            XCTAssertFalse(readings.isEmpty)
            for reading in readings {
                XCTAssertLessThan(abs(Self.cents(reading.frequency, frequency)), 50, "\(frequency) Hz read as \(reading.frequency)")
            }
        }
    }

    // MARK: Response

    /// From silence to the first value of a low E in under 120 ms, measured in samples of the stream.
    func testFirstValueOfALowEInUnder120Milliseconds() {
        for rate in [44_100.0, 48_000.0] {
            let lead = 0.5
            let silence = TunerTestSignal.silence(sampleRate: rate, seconds: lead)
            let string = TunerTestSignal.karplusStrong(frequency: 82.41, sampleRate: rate, seconds: 1)
            let (_, timeline) = Self.track(silence + TunerTestSignal.addingNoise(string, decibels: -30), sampleRate: rate,
                                           block: 128)
            guard let first = timeline.first(where: { $0.reading != nil }) else {
                return XCTFail("no reading at \(rate)")
            }
            let delay = first.time - lead
            XCTAssertLessThan(delay, 0.12, "first value after \(Int(delay * 1000)) ms at \(Int(rate))")
            XCTAssertLessThan(abs(Self.cents(first.reading!.frequency, 82.41)), 50, "first value is the right note")
        }
    }

    /// The lowest note, H0 of a bass, still answers within a sensible time.
    func testFirstValueOfALowBQuickly() {
        let rate = 48_000.0
        let string = TunerTestSignal.karplusStrong(frequency: 30.87, sampleRate: rate, seconds: 1)
        let (_, timeline) = Self.track(TunerTestSignal.silence(sampleRate: rate, seconds: 0.2) + string, sampleRate: rate)
        let first = timeline.first { $0.reading != nil }
        XCTAssertNotNil(first)
        XCTAssertLessThan((first?.time ?? 9) - 0.2, 0.16)
    }
}
