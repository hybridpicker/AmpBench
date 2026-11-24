import XCTest
@testable import SparkCore

/// Where each bar lies in the timing band, for its colour and for pointing at it.
final class TimingBandBarsTests: XCTestCase {
    func testEachBarOfTheBandHasItsShareOfTheWidth() {
        let grid = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15)
        let review = TimingReview(resolution: .quarters, onsets: [], placement: 0, spread: 0, counted: 0, hints: [],
                                  accuracy: 0.001, bars: [])

        let band = TimingBand(review: review, grid: grid, bars: 3...4, width: 800)

        XCTAssertEqual(band.barSpans, [TimingBand.BarSpan(bar: 3, left: 0, width: 400),
                                       TimingBand.BarSpan(bar: 4, left: 400, width: 400)])
    }

    func testEachBarOfTheBandKnowsWhatTheReviewSaysOfIt() {
        let grid = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15)
        let unsteady = TimingReview.Bar(number: 4, counted: 4, placement: 0.01, spread: 0.012, steadiness: .unsteady)
        let review = TimingReview(resolution: .quarters, onsets: [], placement: 0, spread: 0, counted: 0, hints: [],
                                  accuracy: 0.001, bars: [TimingReview.Bar(number: 3, counted: 0), unsteady])

        let band = TimingBand(review: review, grid: grid, bars: 3...4, width: 800)

        XCTAssertEqual(band.barSpans.map(\.reviewed), [TimingReview.Bar(number: 3, counted: 0), unsteady])
        XCTAssertEqual(band.barSpans.map(\.steadiness), [nil, .unsteady])
        XCTAssertNil(TimingBand(review: review, grid: grid, bars: 5...6, width: 800).barSpans[0].reviewed,
                     "a bar the review does not reach")
    }

    func testABandOfOneBarIsThatBarThroughout() {
        let grid = BeatGrid(bpm: 90, beatsPerBar: 3, offset: 0.15, firstBar: 5)
        let review = TimingReview(resolution: .quarters, onsets: [], placement: 0, spread: 0, counted: 0, hints: [],
                                  accuracy: 0.001, bars: [])

        let band = TimingBand(review: review, grid: grid, bars: 5...5, width: 600)

        XCTAssertEqual(band.barSpans, [TimingBand.BarSpan(bar: 5, left: 0, width: 600)])
    }
}
