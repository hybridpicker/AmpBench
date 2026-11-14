import XCTest
@testable import SparkCore

final class LoudnessTests: XCTestCase {
    private func sine(_ frequency: Double, amplitude: Double, seconds: Double, rate: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    func testAFullScaleSineReadsAsTheStandardSays() throws {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            var meter = Loudness(sampleRate: rate)
            meter.add(sine(997, amplitude: 1, seconds: 3, rate: rate))
            XCTAssertEqual(try XCTUnwrap(meter.integrated), -3.01, accuracy: 0.1, "at \(rate) Hz")
            XCTAssertEqual(meter.peak, 1, accuracy: 0.001)
        }
    }

    func testHalfTheAmplitudeIsSixDecibelsLess() throws {
        var loud = Loudness(sampleRate: 48_000), quiet = Loudness(sampleRate: 48_000)
        loud.add(sine(440, amplitude: 0.5, seconds: 2, rate: 48_000))
        quiet.add(sine(440, amplitude: 0.25, seconds: 2, rate: 48_000))
        XCTAssertEqual(try XCTUnwrap(loud.integrated) - XCTUnwrap(quiet.integrated), 6.02, accuracy: 0.05)
    }

    func testPausesBetweenTheNotesDoNotCount() throws {
        var steady = Loudness(sampleRate: 48_000), broken = Loudness(sampleRate: 48_000)
        let tone = sine(330, amplitude: 0.3, seconds: 2, rate: 48_000)
        steady.add(tone)
        broken.add(tone)
        broken.add([Float](repeating: 0, count: 96_000))
        broken.add(tone)
        // The blocks that reach into a pause count for a little less, as the standard has it.
        XCTAssertEqual(try XCTUnwrap(broken.integrated), try XCTUnwrap(steady.integrated), accuracy: 0.5)
        XCTAssertLessThan(broken.keptShare, 0.8)
    }

    func testSilenceHasNoLoudness() {
        var meter = Loudness(sampleRate: 48_000)
        meter.add([Float](repeating: 0, count: 96_000))
        XCTAssertNil(meter.integrated)
    }

    func testPiecesGiveTheSameAsOnePiece() throws {
        let tone = sine(220, amplitude: 0.4, seconds: 2, rate: 44_100)
        var whole = Loudness(sampleRate: 44_100), pieces = Loudness(sampleRate: 44_100)
        whole.add(tone)
        for start in stride(from: 0, to: tone.count, by: 441) { pieces.add(Array(tone[start..<min(start + 441, tone.count)])) }
        XCTAssertEqual(try XCTUnwrap(pieces.integrated), try XCTUnwrap(whole.integrated), accuracy: 0.001)
    }

    func testLowRumbleCountsLessThanTheSameLevelInTheMiddle() throws {
        var low = Loudness(sampleRate: 48_000), middle = Loudness(sampleRate: 48_000)
        low.add(sine(30, amplitude: 0.5, seconds: 3, rate: 48_000))
        middle.add(sine(1_000, amplitude: 0.5, seconds: 3, rate: 48_000))
        XCTAssertLessThan(try XCTUnwrap(low.integrated), try XCTUnwrap(middle.integrated) - 5)
    }
}
