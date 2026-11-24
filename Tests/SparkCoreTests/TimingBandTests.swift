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
    private func review(_ times: [Double], grid: BeatGrid? = nil, duration: Double = 20,
                        resolution: TimingReview.Resolution = .quarters) -> TimingReview {
        let grid = grid ?? self.grid
        let onsets = TimingReview.match(times, to: GridPoints(grid: grid, resolution: resolution, duration: duration))
        let offsets = onsets.filter(\.isCounted).compactMap(\.offset)
        return TimingReview(resolution: resolution, onsets: onsets, placement: 0, spread: 0, counted: offsets.count,
                            hints: [], accuracy: 0.001, bars: [])
    }

    func testTheClickLinesStandInTheMiddleOfEachBeatWithTheirNumbers() {
        let band = TimingBand(review: review([]), grid: grid, bars: 1...2, width: 800)

        XCTAssertEqual(band.points.map(\.number), [1, 2, 3, 4, 1, 2, 3, 4])
        XCTAssertEqual(band.points.map(\.bar), [1, 1, 1, 1, 2, 2, 2, 2])
        XCTAssertEqual(band.points.map(\.x), [50, 150, 250, 350, 450, 550, 650, 750])
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
        XCTAssertEqual(band.strokes.map { band.points[$0.point].bar }, [1, 2], "each stroke knows its click")
        XCTAssertEqual(band.strokes.map { band.points[$0.point].number }, [2, 1])
    }

    func testOnsetsThatDoNotCountAreFaintAndCarryNoOffset() {
        // A delay echo 30 ms after the note in the same window, and a fill 250 ms after beat 3, between the windows.
        let times = [beat(1, ofBar: 1) + 0.004, beat(1, ofBar: 1) + 0.034, beat(3, ofBar: 1) + 0.25]
        let band = TimingBand(review: review(times), grid: grid, bars: 1...2, width: 800)

        XCTAssertEqual(band.strokes.map(\.isCounted), [true, false, false])
        XCTAssertEqual(band.strokes.map(\.label), ["+4 ms", nil, nil])
        XCTAssertEqual(band.strokes[1].x, 50 + 50 * 0.034 / 0.06, accuracy: 0.01)
    }

    func testAnOnsetFurtherOffThanTheCellStaysAtItsEdgeWithItsTrueOffset() {
        // 120 ms late is still in the catch window of 175 ms, but past the ±60 ms a cell shows.
        let band = TimingBand(review: review([beat(2, ofBar: 2) + 0.120]), grid: grid, bars: 1...2, width: 800)

        XCTAssertEqual(band.strokes.count, 1)
        XCTAssertEqual(band.strokes[0].x, 600, accuracy: 0.01, "at the right edge of the cell of beat 2 in bar 2")
        XCTAssertTrue(band.strokes[0].isPastTheCell)
        XCTAssertEqual(band.strokes[0].label, "+120 ms")
    }

    func testOnEighthsTheBandShowsAClickForEveryEighthWithNumbersOnTheBeats() {
        let band = TimingBand(review: review([], resolution: .eighths), grid: grid, bars: 1...2, width: 800)

        XCTAssertEqual(band.points.count, 16)
        XCTAssertEqual(band.points.prefix(8).map(\.number), [1, nil, 2, nil, 3, nil, 4, nil])
        XCTAssertEqual(band.points.prefix(3).map(\.x), [25, 75, 125])
    }

    func testOnTripletsAnOnsetSitsInTheCellOfItsOwnTriplet() {
        // 120 bpm triplets lie 167 ms apart: the second triplet of beat 3 in bar 1, 12 ms late.
        let second = beat(3, ofBar: 1) + grid.secondsPerBeat / 3 + 0.012
        let band = TimingBand(review: review([second], resolution: .triplets), grid: grid, bars: 1...2, width: 1200)

        XCTAssertEqual(band.points.count, 24)
        XCTAssertEqual(band.strokes.count, 1)
        let click = band.points[band.strokes[0].point]
        XCTAssertEqual(click.bar, 1)
        XCTAssertNil(click.number, "between the beats")
        XCTAssertEqual(click.beat, 3)
        XCTAssertEqual(click.step, 1)
        XCTAssertEqual(band.strokes[0].point, 7, "beat 3 is the seventh triplet, its second the eighth")
        XCTAssertEqual(band.strokes[0].label, "+12 ms")
        XCTAssertEqual(band.strokes[0].x, 7.5 * 50 + 25 * 0.012 / 0.060, accuracy: 0.01)
    }

    /// VoiceOver reads the bars shown, then every counted note by its place in the bar, also between the beats.
    func testVoiceOverReadsEachCountedNoteByItsPlaceInTheBar() {
        let half = grid.secondsPerBeat / 2
        let eighths = TimingBand(review: review([beat(2, ofBar: 1) + 0.018, beat(2, ofBar: 1) + half - 0.007,
                                                 beat(4, ofBar: 2) + half + 0.003], resolution: .eighths),
                                 grid: grid, bars: 1...2, width: 800)
        let third = grid.secondsPerBeat / 3
        let triplets = TimingBand(review: review([beat(3, ofBar: 1) + third + 0.012, beat(3, ofBar: 1) + 2 * third],
                                                 resolution: .triplets), grid: grid, bars: 1...2, width: 1200)
        let sixteenths = TimingBand(review: review([beat(1, ofBar: 2) + 3 * grid.secondsPerBeat / 4 - 0.004],
                                                   resolution: .sixteenths), grid: grid, bars: 1...2, width: 1600)
        let empty = TimingBand(review: review([]), grid: grid, bars: 3...3, width: 800)

        Texts.language = .english
        XCTAssertEqual(eighths.spoken, "Bars 1–2: bar 1 beat 2 +18 ms, bar 1 beat 2 and -7 ms, bar 2 beat 4 and +3 ms")
        XCTAssertEqual(triplets.spoken, "Bars 1–2: bar 1 beat 3 triplet 2 +12 ms, bar 1 beat 3 triplet 3 +0 ms")
        XCTAssertEqual(sixteenths.spoken, "Bars 1–2: bar 2 beat 1 sixteenth 4 -4 ms")
        XCTAssertEqual(empty.spoken, "Bar 3, no counted notes")
        Texts.language = .german
        XCTAssertEqual(eighths.spoken,
                       "Takte 1–2: Takt 1 Schlag 2 +18 ms, Takt 1 Schlag 2 und -7 ms, Takt 2 Schlag 4 und +3 ms")
        XCTAssertEqual(triplets.spoken, "Takte 1–2: Takt 1 Schlag 3 Triole 2 +12 ms, Takt 1 Schlag 3 Triole 3 +0 ms")
        XCTAssertEqual(sixteenths.spoken, "Takte 1–2: Takt 2 Schlag 1 Sechzehntel 4 -4 ms")
        XCTAssertEqual(empty.spoken, "Takt 3, keine gezählten Töne")
    }

    func testEveryCountedStrokeCarriesItsOffsetAlsoWithoutTheUnitForNarrowCells() {
        let band = TimingBand(review: review([beat(2, ofBar: 1) + 0.018, beat(3, ofBar: 1) - 0.007]), grid: grid,
                              bars: 1...2, width: 800)

        XCTAssertEqual(band.strokes.map(\.shortLabel), ["+18", "-7"])
        Texts.language = .german
        XCTAssertEqual(TimingBand(review: review([beat(2, ofBar: 1) + 0.018]), grid: grid, bars: 1...2, width: 800)
            .strokes.map(\.label), ["+18 ms"])
    }

    func testTenToFortyMillisecondsStandClearOfTheClickInAThreeMinuteTake() {
        // 3 minutes at 90 bpm: 67 bars. The band shows two of them however long the take is, at the smallest window.
        let slow = BeatGrid(bpm: 90, beatsPerBar: 4, offset: 0.15)
        let times = [beat(1, ofBar: 60, in: slow) + 0.010, beat(2, ofBar: 60, in: slow) + 0.040,
                     beat(3, ofBar: 60, in: slow) - 0.010]
        let band = TimingBand(review: review(times, grid: slow, duration: 180), grid: slow, bars: 59...60, width: 700)
        let clicks = band.points.filter { $0.bar == 60 }.map(\.x)

        XCTAssertGreaterThanOrEqual(band.strokes[0].x - clicks[0], 6, "10 ms late")
        XCTAssertGreaterThanOrEqual(band.strokes[1].x - clicks[1], 24, "40 ms late")
        XCTAssertGreaterThanOrEqual(clicks[2] - band.strokes[2].x, 6, "10 ms early")
    }

    func testTheBandShowsTheTwoBarsAroundThePlayheadAPairAtATime() {
        // Eight bars: the band turns over like a page, two bars at a time, so it stands still while a pair plays.
        XCTAssertEqual(TimingBand.pair(at: 0, grid: grid, lastBar: 8), 1...2, "before bar 1, in the count-in's pre-roll")
        XCTAssertEqual(TimingBand.pair(at: beat(1, ofBar: 1), grid: grid, lastBar: 8), 1...2)
        XCTAssertEqual(TimingBand.pair(at: beat(4, ofBar: 2), grid: grid, lastBar: 8), 1...2)
        XCTAssertEqual(TimingBand.pair(at: beat(1, ofBar: 3), grid: grid, lastBar: 8), 3...4)
        XCTAssertEqual(TimingBand.pair(at: beat(2, ofBar: 8), grid: grid, lastBar: 8), 7...8)
        XCTAssertEqual(TimingBand.pair(at: 1_000, grid: grid, lastBar: 8), 7...8, "past the end")
    }

    func testTheLastBarOfAnOddTakeIsShownWithTheBarBeforeIt() {
        XCTAssertEqual(TimingBand.pair(at: beat(3, ofBar: 5), grid: grid, lastBar: 5), 4...5)
        XCTAssertEqual(TimingBand.pair(at: beat(1, ofBar: 1), grid: grid, lastBar: 1), 1...1, "a take of one bar")
    }

    func testARetakeOfSomeBarsCountsItsPairsFromItsFirstBar() {
        let retake = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15, firstBar: 7)

        XCTAssertEqual(TimingBand.pair(at: 0, grid: retake, lastBar: 9), 7...8)
        XCTAssertEqual(TimingBand.pair(at: beat(1, ofBar: 9, in: retake), grid: retake, lastBar: 9), 8...9)
    }

    func testSelectedBarsShowThePairThatHoldsTheirFirstBar() {
        XCTAssertEqual(TimingBand.pair(showing: 4...6, grid: grid, lastBar: 8), 3...4)
        XCTAssertEqual(TimingBand.pair(showing: 5...5, grid: grid, lastBar: 8), 5...6)
    }

    func testThePlayheadShowsInTheBandOnlyNearAClick() {
        let band = TimingBand(review: review([]), grid: grid, bars: 1...2, width: 800)

        XCTAssertEqual(band.x(at: beat(2, ofBar: 1) + 0.030) ?? -1, 175, accuracy: 0.01)
        XCTAssertEqual(band.x(at: beat(1, ofBar: 1) - 0.060) ?? -1, 0, accuracy: 0.01, "at the band's left edge")
        XCTAssertNil(band.x(at: beat(2, ofBar: 1) + 0.200), "between the cells the band shows no time")
        XCTAssertNil(band.x(at: beat(1, ofBar: 3)), "in a bar the band does not show")
    }

    func testATakeWithAReviewOpensTheBandWhichFolds() {
        let reviewed = review([beat(1, ofBar: 1)])
        let outcome = TimingReview.Outcome.review(reviewed)

        XCTAssertEqual(TimingBand.shows(outcome, folded: false), .band(reviewed))
        XCTAssertEqual(TimingBand.shows(outcome, folded: true), .folded)
        XCTAssertTrue(TimingBand.shows(outcome, folded: true).canFold)
        XCTAssertTrue(TimingBand.shows(outcome, folded: false).canFold)
    }

    func testATakeWithoutAReviewShowsOnlyItsReasonLine() {
        let outcome = TimingReview.Outcome.noReview(.ampPartNotMeasured)

        XCTAssertEqual(TimingBand.shows(outcome, folded: false), .line)
        XCTAssertEqual(TimingBand.shows(outcome, folded: true), .line)
        XCTAssertFalse(TimingBand.shows(outcome, folded: false).canFold)
        XCTAssertEqual(TimingBand.shows(nil, folded: false), .line, "while it is worked out, or when unreadable")
    }
}
