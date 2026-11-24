import AmpText
import XCTest
@testable import SparkCore

/// What the timing review says about each bar of a generated take: its placement, spread and counted onsets, and
/// whether it is steady or unsteady.
final class TimingReviewBarsTests: XCTestCase {
    /// A click latency measured on the amp, clicks through a wired output, the click on for the whole take.
    private let measured = TimingStamp(
        clickOnThroughout: true,
        latency: ClickLatency(output: 0.004, input: 0.003,
                              amp: AmpPart(seconds: 0.0217,
                                           origin: .measured(spread: 0.0012, date: Date(timeIntervalSince1970: 1_795_435_200))),
                              outputKind: .wired))
    private let rate = 48_000.0

    override func tearDown() {
        Texts.language = .english
        super.tearDown()
    }

    /// Plucks are computed once per seed; the tests use many of the same.
    private static var plucks: [UInt64: [Float]] = [:]

    private static func pluck(seed: UInt64, rate: Double) -> [Float] {
        if let pluck = plucks[seed] { return pluck }
        let pluck = TunerTestSignal.karplusStrong(frequency: 196, sampleRate: rate, seconds: 0.6, amplitude: 0.5,
                                                  ringTime: 0.5, seed: seed)
        plucks[seed] = pluck
        return pluck
    }

    /// Bars in 4/4 at 120 bpm from 0.15 s on, as after a count-in, with a pluck `offset(beat)` seconds off each beat
    /// from the first one, or none where it gives nil.
    private func review(bars: Int, firstBar: Int = 1, offset: (Int) -> Double?) throws -> TimingReview {
        let grid = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15, firstBar: firstBar)
        let beats = bars * 4
        var generator = SeededGenerator(seed: 5)
        let seconds = grid.offset + Double(beats) * grid.secondsPerBeat + 0.3
        var samples = (0..<Int(seconds * rate)).map { _ in Float(generator.gaussian() * 0.0003) }
        for beat in 0..<beats {
            guard let shift = offset(beat) else { continue }
            let start = Int(((grid.offset + Double(beat) * grid.secondsPerBeat + shift) * rate).rounded())
            for (step, value) in Self.pluck(seed: UInt64(beat % 4 + 1), rate: rate).enumerated()
                where start + step < samples.count {
                samples[start + step] += value
            }
        }
        let outcome = TimingReview.review(samples: samples, sampleRate: rate, grid: grid, stamp: measured)
        guard case .review(let review) = outcome else { return try XCTUnwrap(nil, "\(outcome)") }
        return review
    }

    func testEveryBarHasItsPlacementSpreadAndCountedOnsets() throws {
        // Bar 1 on the click, bar 2 laid back by 20 ms, bar 3 12 ms early and late in turn, bar 4 on the click.
        let review = try review(bars: 4) { beat in
            switch beat / 4 {
            case 1: return 0.020
            case 2: return beat % 2 == 0 ? -0.012 : 0.012
            default: return 0
            }
        }

        // The take's file ends just after the first beat of bar 5, which counts as a bar of its own, without notes.
        XCTAssertEqual(review.bars.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(review.bars.map(\.counted), [4, 4, 4, 4, 0])
        let placements = review.bars.map(\.placement)
        let spreads = review.bars.map(\.spread)
        XCTAssertEqual(try XCTUnwrap(placements[0]), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(placements[1]), 0.020, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(placements[2]), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(spreads[0]), 0, accuracy: 0.0005)
        XCTAssertEqual(try XCTUnwrap(spreads[1]), 0, accuracy: 0.0005)
        XCTAssertEqual(try XCTUnwrap(spreads[2]), 0.012, accuracy: 0.0005)
        XCTAssertNil(placements[4])
        XCTAssertNil(spreads[4])
    }
}
