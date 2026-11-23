import AmpText
import XCTest
@testable import SparkCore

/// What the timing band below the waveform shows for a review: which bars, where the click lines and the strokes of
/// the onsets sit, and what folds. The view only draws this.
final class TimingBandTests: XCTestCase {
    /// 120 bpm in 4/4, bar 1 at 0.15 s as after a count-in: a beat every 0.5 s.
    private let grid = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15)

    override func tearDown() {
        Texts.language = .english
    }

    /// The time of beat `beat` (from 1) in bar `bar` of the grid.
    private func beat(_ beat: Int, ofBar bar: Int, in grid: BeatGrid? = nil) -> Double {
        let grid = grid ?? self.grid
        return grid.time(ofBar: bar) + Double(beat - 1) * grid.secondsPerBeat
    }

    /// A review of the given onsets, matched to the grid as the review module does.
    private func review(_ times: [Double], grid: BeatGrid? = nil, duration: Double = 20) -> TimingReview {
        let grid = grid ?? self.grid
        let onsets = TimingReview.match(times, to: grid, resolution: .quarters, duration: duration)
        let offsets = onsets.filter(\.isCounted).compactMap(\.offset)
        return TimingReview(resolution: .quarters, onsets: onsets, placement: 0, spread: 0, counted: offsets.count)
    }

    func testTheClickLinesStandInTheMiddleOfEachBeatWithTheirNumbers() {
        let band = TimingBand(review: review([]), grid: grid, bars: 1...2, width: 800)

        XCTAssertEqual(band.clicks.map(\.beat), [1, 2, 3, 4, 1, 2, 3, 4])
        XCTAssertEqual(band.clicks.map(\.bar), [1, 1, 1, 1, 2, 2, 2, 2])
        XCTAssertEqual(band.clicks.map(\.x), [50, 150, 250, 350, 450, 550, 650, 750])
    }

    func testOnsetsAreStrokesBesideTheirClickWithTheirOffsetInMilliseconds() {
        let times = [beat(2, ofBar: 1) + 0.018, beat(1, ofBar: 2) - 0.010, beat(1, ofBar: 3) + 0.005]
        let band = TimingBand(review: review(times), grid: grid, bars: 1...2, width: 800)

        // 100 points per beat for ±60 ms: 50 points for 60 ms.
        XCTAssertEqual(band.strokes.count, 2, "only the onsets of the bars shown")
        XCTAssertEqual(band.strokes[0].x, 165, accuracy: 0.01)
        XCTAssertEqual(band.strokes[0].label, "+18 ms")
        XCTAssertEqual(band.strokes[1].x, 450 - 50.0 / 6, accuracy: 0.01)
        XCTAssertEqual(band.strokes[1].label, "-10 ms")
        XCTAssertTrue(band.strokes.allSatisfy(\.isCounted))
    }
}
