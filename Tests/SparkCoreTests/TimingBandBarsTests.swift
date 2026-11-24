import XCTest
@testable import SparkCore

/// Where each bar lies in the timing band, for its colour and for pointing at it.
final class TimingBandBarsTests: XCTestCase {
    func testEachBarOfTheBandHasItsShareOfTheWidth() {
        let grid = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15)
        let review = TimingReview(resolution: .quarters, onsets: [], placement: 0, spread: 0, counted: 0, hints: [])

        let band = TimingBand(review: review, grid: grid, bars: 3...4, width: 800)

        XCTAssertEqual(band.barSpans, [TimingBand.BarSpan(bar: 3, left: 0, width: 400),
                                       TimingBand.BarSpan(bar: 4, left: 400, width: 400)])
    }

    func testABandOfOneBarIsThatBarThroughout() {
        let grid = BeatGrid(bpm: 90, beatsPerBar: 3, offset: 0.15, firstBar: 5)
        let review = TimingReview(resolution: .quarters, onsets: [], placement: 0, spread: 0, counted: 0, hints: [])

        let band = TimingBand(review: review, grid: grid, bars: 5...5, width: 600)

        XCTAssertEqual(band.barSpans, [TimingBand.BarSpan(bar: 5, left: 0, width: 600)])
    }
}
