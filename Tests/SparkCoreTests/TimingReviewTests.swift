import AmpText
import XCTest
@testable import SparkCore

/// What the timing review says about generated takes: plucks and strums at known places on known bars.
final class TimingReviewTests: XCTestCase {
    /// A click latency measured on the amp, clicks through a wired output, the click on for the whole take.
    private let measured = TimingStamp(
        clickOnThroughout: true,
        latency: ClickLatency(output: 0.004, input: 0.003,
                              amp: AmpPart(seconds: 0.0217,
                                           origin: .measured(spread: 0.0012, date: Date(timeIntervalSince1970: 1_795_435_200))),
                              outputKind: .wired))

    /// A note on a string: a plucked string after Karplus and Strong, ringing out within half a second.
    private struct Note {
        var time: Double
        var frequency: Double = 196
        var amplitude: Double = 0.5
    }

    /// A take of `seconds` with the notes in it, over a faint noise floor. Each note starts exactly at its time.
    private func take(_ notes: [Note], seconds: Double, rate: Double) -> [Float] {
        var generator = SeededGenerator(seed: 5)
        var samples = (0..<Int(seconds * rate)).map { _ in Float(generator.gaussian() * 0.0003) }
        for (number, note) in notes.enumerated() {
            let pluck = Self.pluck(frequency: note.frequency, rate: rate, seed: UInt64(number % 4 + 1))
            let start = Int((note.time * rate).rounded())
            let gain = Float(note.amplitude / 0.5)
            for (step, value) in pluck.enumerated() where start + step >= 0 && start + step < samples.count {
                samples[start + step] += gain * value
            }
        }
        return samples
    }

    /// Plucks are computed once per string, rate and seed; the tests use many of the same.
    private static var plucks: [String: [Float]] = [:]

    private static func pluck(frequency: Double, rate: Double, seed: UInt64) -> [Float] {
        let key = "\(frequency)-\(rate)-\(seed)"
        if let pluck = plucks[key] { return pluck }
        let pluck = TunerTestSignal.karplusStrong(frequency: frequency, sampleRate: rate, seconds: 0.6, amplitude: 0.5,
                                                  ringTime: 0.5, seed: seed)
        plucks[key] = pluck
        return pluck
    }

    /// Bars at `bpm` in 4/4 from 0.15 s on, as after a count-in, and one note per beat `offset` seconds off it.
    private func plucksOnBars(bpm: Double, rate: Double, bars: Int = 4, offset: (Int) -> Double)
        -> (samples: [Float], grid: BeatGrid) {
        let grid = BeatGrid(bpm: bpm, beatsPerBar: 4, offset: 0.15)
        let beats = bars * 4
        let notes = (0..<beats).map { Note(time: grid.offset + Double($0) * grid.secondsPerBeat + offset($0)) }
        let seconds = grid.offset + Double(beats) * grid.secondsPerBeat + 0.3
        return (take(notes, seconds: seconds, rate: rate), grid)
    }

    private func review(_ samples: [Float], rate: Double, grid: BeatGrid?, stamp: TimingStamp?,
                        file: StaticString = #filePath, line: UInt = #line) -> TimingReview? {
        switch TimingReview.review(samples: samples, sampleRate: rate, grid: grid, stamp: stamp) {
        case .review(let review):
            return review
        case .noReview(let reason):
            XCTFail("no review: \(reason)", file: file, line: line)
            return nil
        }
    }

    // MARK: Onsets

    func testPlucksAtKnownOffsetsComeOutWithin1Millisecond() throws {
        var worst = 0.0
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            for bpm in [72.0, 120.0, 168.0] {
                for offset in [0.0, 0.020, -0.010] {
                    let (samples, grid) = plucksOnBars(bpm: bpm, rate: rate) { _ in offset }
                    let review = try XCTUnwrap(review(samples, rate: rate, grid: grid, stamp: measured))
                    let counted = review.onsets.filter(\.isCounted)
                    XCTAssertEqual(counted.count, 16, "\(rate) Hz, \(bpm) BPM, \(offset * 1000) ms")
                    for onset in counted {
                        XCTAssertEqual(try XCTUnwrap(onset.offset), offset, accuracy: 0.001,
                                       "\(rate) Hz, \(bpm) BPM, beat \(onset.gridPoint ?? -1)")
                    }
                    XCTAssertEqual(review.placement, offset, accuracy: 0.001)
                    worst = max(worst, counted.map { abs(($0.offset ?? 0) - offset) }.max() ?? 0)
                }
            }
        }
        print("NOTE worst onset error on clean plucks: \(String(format: "%.3f", worst * 1000)) ms")
    }

    func testAStrumCountsFromItsFirstString() throws {
        let strings = [82.4, 110, 146.8, 196, 246.9, 329.6]
        let rate = 48_000.0
        let grid = BeatGrid(bpm: 100, beatsPerBar: 4, offset: 0.15)
        for strum in [0.010, 0.025, 0.040] {
            var notes: [Note] = []
            for beat in 0..<8 {
                let first = grid.offset + Double(beat) * grid.secondsPerBeat
                // Down and up strokes: the first string to sound is the low or the high one.
                let order = beat % 2 == 0 ? strings : strings.reversed()
                for (index, frequency) in order.enumerated() {
                    notes.append(Note(time: first + strum * Double(index) / 5, frequency: frequency, amplitude: 0.25))
                }
            }
            let samples = take(notes, seconds: grid.offset + 8 * grid.secondsPerBeat + 0.3, rate: rate)
            let review = try XCTUnwrap(review(samples, rate: rate, grid: grid, stamp: measured))
            XCTAssertEqual(review.counted, 8, "strum of \(strum * 1000) ms")
            for onset in review.onsets.filter(\.isCounted) {
                XCTAssertEqual(try XCTUnwrap(onset.offset), 0, accuracy: 0.001, "strum of \(strum * 1000) ms")
            }
        }
    }
}
