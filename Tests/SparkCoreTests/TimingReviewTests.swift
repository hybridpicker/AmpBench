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

    override func tearDown() {
        Texts.language = .english
        super.tearDown()
    }

    private func reason(_ samples: [Float], rate: Double, grid: BeatGrid?, stamp: TimingStamp?) -> NoReviewReason? {
        if case .noReview(let reason) = TimingReview.review(samples: samples, sampleRate: rate, grid: grid, stamp: stamp) {
            return reason
        }
        return nil
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

    func testOnlyTheFirstOnsetInACatchWindowCounts() throws {
        let rate = 44_100.0
        let grid = BeatGrid(bpm: 90, beatsPerBar: 4, offset: 0.15)
        var notes: [Note] = []
        for beat in 0..<8 {
            let time = grid.offset + Double(beat) * grid.secondsPerBeat + 0.012
            notes.append(Note(time: time))
            // A delay echo 120 ms later, still inside the catch window of 233 ms.
            notes.append(Note(time: time + 0.120, frequency: 196, amplitude: 0.5))
        }
        let samples = take(notes, seconds: grid.offset + 8 * grid.secondsPerBeat + 0.3, rate: rate)
        let review = try XCTUnwrap(review(samples, rate: rate, grid: grid, stamp: measured))
        XCTAssertEqual(review.counted, 8)
        XCTAssertEqual(review.onsets.filter { $0.status == .laterInWindow }.count, 8)
        XCTAssertEqual(review.placement, 0.012, accuracy: 0.001)
    }

    func testAnOnsetOutsideEveryCatchWindowDoesNotCount() throws {
        let rate = 48_000.0
        let grid = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15)
        var notes = (0..<8).map { Note(time: grid.offset + Double($0) * grid.secondsPerBeat) }
        // An eighth note between beats 3 and 4: half a beat from both, outside both windows of 35 %.
        let between = grid.offset + 2.5 * grid.secondsPerBeat
        notes.append(Note(time: between, frequency: 330))
        let samples = take(notes, seconds: grid.offset + 8 * grid.secondsPerBeat + 0.3, rate: rate)
        let review = try XCTUnwrap(review(samples, rate: rate, grid: grid, stamp: measured))
        XCTAssertEqual(review.counted, 8)
        let outside = review.onsets.filter { $0.status == .outsideWindows }
        XCTAssertEqual(outside.count, 1)
        XCTAssertEqual(try XCTUnwrap(outside.first).time, between, accuracy: 0.001)
        XCTAssertNil(outside.first?.offset)
        XCTAssertEqual(review.placement, 0, accuracy: 0.001)
    }

    // MARK: Numbers

    func testPlacementIsTheMeanAndSpreadTheStandardDeviation() throws {
        // Laid back and uneven: 4 ms and 16 ms behind in turn, so 10 ms behind on average and 6 ms around it.
        let rate = 48_000.0
        let (samples, grid) = plucksOnBars(bpm: 110, rate: rate) { $0 % 2 == 0 ? 0.004 : 0.016 }
        let review = try XCTUnwrap(review(samples, rate: rate, grid: grid, stamp: measured))
        XCTAssertEqual(review.counted, 16)
        XCTAssertEqual(review.placement, 0.010, accuracy: 0.0005)
        XCTAssertEqual(review.spread, 0.006, accuracy: 0.0005)
    }

    func testSteadyLaidBackPlayingHasASpreadOfAlmostNothing() throws {
        let rate = 44_100.0
        let (samples, grid) = plucksOnBars(bpm: 80, rate: rate) { _ in 0.018 }
        let review = try XCTUnwrap(review(samples, rate: rate, grid: grid, stamp: measured))
        XCTAssertEqual(review.placement, 0.018, accuracy: 0.001)
        XCTAssertLessThan(review.spread, 0.0003)
    }

    // MARK: Hints

    func testADelayInTheSoundGivesAHintAndStillAReview() throws {
        let rate = 48_000.0
        let (samples, grid) = plucksOnBars(bpm: 100, rate: rate) { _ in 0.005 }
        let outcome = TimingReview.review(samples: samples, sampleRate: rate, grid: grid, stamp: measured,
                                          soundHasDelay: true)
        guard case .review(let review) = outcome else { return XCTFail("no review: \(outcome)") }
        XCTAssertEqual(review.hints, [.delayInTheSound])
        XCTAssertEqual(review.counted, 16)
        XCTAssertEqual(review.placement, 0.005, accuracy: 0.001)
    }

    func testASoundWithoutADelayOrNotKnownGivesNoHint() throws {
        let rate = 44_100.0
        let (samples, grid) = plucksOnBars(bpm: 100, rate: rate) { _ in 0 }
        let dry = TimingReview.review(samples: samples, sampleRate: rate, grid: grid, stamp: measured,
                                      soundHasDelay: false)
        guard case .review(let review) = dry else { return XCTFail("no review: \(dry)") }
        XCTAssertEqual(review.hints, [])
        // A caller that knows nothing of the sound, such as a take without a sound stamp, is reviewed without a hint.
        XCTAssertEqual(try XCTUnwrap(self.review(samples, rate: rate, grid: grid, stamp: measured)).hints, [])
    }

    func testTheDelayHintReadsInEnglishAndGerman() {
        Texts.language = .english
        XCTAssertEqual(TimingReview.Hint.delayInTheSound.text,
                       "Delay in the sound: echoes may count as notes. For exact practice choose a dry sound.")
        Texts.language = .german
        XCTAssertEqual(TimingReview.Hint.delayInTheSound.text,
                       "Delay im Sound: Echos können als Töne zählen. Für genaues Üben einen trockenen Sound wählen.")
    }

    // MARK: No review

    func testEachReasonForNoReviewInItsOrder() {
        let rate = 44_100.0
        let (samples, grid) = plucksOnBars(bpm: 120, rate: rate, bars: 2) { _ in 0 }
        var clickOff = measured
        clickOff.clickOnThroughout = false
        var handSet = measured
        handSet.latency.amp = AmpPart(seconds: 0.02, origin: .setByHand)
        var unknown = measured
        unknown.latency.amp = nil

        XCTAssertEqual(reason(samples, rate: rate, grid: nil, stamp: measured), .noBars)
        XCTAssertEqual(reason(samples, rate: rate, grid: nil, stamp: nil), .noBars)
        XCTAssertEqual(reason(samples, rate: rate, grid: grid, stamp: nil), .recordedBeforeTheStamp)
        XCTAssertEqual(reason(samples, rate: rate, grid: grid, stamp: clickOff), .clickNotOnThroughout)
        var both = clickOff
        both.latency.amp = nil
        XCTAssertEqual(reason(samples, rate: rate, grid: grid, stamp: both), .clickNotOnThroughout)
        XCTAssertEqual(reason(samples, rate: rate, grid: grid, stamp: handSet), .ampPartNotMeasured)
        XCTAssertEqual(reason(samples, rate: rate, grid: grid, stamp: unknown), .ampPartNotMeasured)
        var bluetooth = measured
        bluetooth.latency.outputKind = .bluetooth
        XCTAssertEqual(reason(samples, rate: rate, grid: grid, stamp: bluetooth), .clickOnBluetooth)
        var bluetoothByHand = handSet
        bluetoothByHand.latency.outputKind = .bluetooth
        XCTAssertEqual(reason(samples, rate: rate, grid: grid, stamp: bluetoothByHand), .ampPartNotMeasured)
        XCTAssertNil(reason(samples, rate: rate, grid: grid, stamp: measured))
    }

    func testATakeWithoutClearNotesHasNoReview() {
        let rate = 44_100.0
        let grid = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15)
        let quiet = take([], seconds: 3, rate: rate)
        XCTAssertEqual(reason(quiet, rate: rate, grid: grid, stamp: measured), .tooFewOnsets)
        let three = take((0..<3).map { Note(time: grid.offset + Double($0) * grid.secondsPerBeat) }, seconds: 3, rate: rate)
        XCTAssertEqual(reason(three, rate: rate, grid: grid, stamp: measured), .tooFewOnsets)
    }

    func testAReviewNeedsEightCountedOnsets() {
        // Two bars of quarters; the number waits for the owner's word and lives in one constant.
        let rate = 44_100.0
        let grid = BeatGrid(bpm: 120, beatsPerBar: 4, offset: 0.15)
        func beats(_ count: Int) -> [Float] {
            take((0..<count).map { Note(time: grid.offset + Double($0) * grid.secondsPerBeat) }, seconds: 5, rate: rate)
        }
        XCTAssertEqual(reason(beats(7), rate: rate, grid: grid, stamp: measured), .tooFewOnsets)
        XCTAssertNil(reason(beats(8), rate: rate, grid: grid, stamp: measured))
    }

    func testTheReasonsReadInEnglishAndGerman() {
        let english: [NoReviewReason: String] = [
            .noBars: "No timing review: recorded without the click.",
            .clickNotOnThroughout: "No timing review: the click was not on for the whole take.",
            .recordedBeforeTheStamp: "No timing review: recorded before the measurement.",
            .ampPartNotMeasured: "No timing review: click latency not measured.",
            .clickOnBluetooth: "No timing review: the click went to a Bluetooth output.",
            .tooFewOnsets: "No timing review: too few clear notes.",
        ]
        let german: [NoReviewReason: String] = [
            .noBars: "Keine Timing-Auswertung: ohne Klick aufgenommen.",
            .clickNotOnThroughout: "Keine Timing-Auswertung: Der Klick lief nicht während der ganzen Aufnahme.",
            .recordedBeforeTheStamp: "Keine Timing-Auswertung: vor der Messung aufgenommen.",
            .ampPartNotMeasured: "Keine Timing-Auswertung: Klick-Latenz nicht gemessen.",
            .clickOnBluetooth: "Keine Timing-Auswertung: Der Klick lief über einen Bluetooth-Ausgang.",
            .tooFewOnsets: "Keine Timing-Auswertung: zu wenige klare Töne.",
        ]
        Texts.language = .english
        for (reason, text) in english { XCTAssertEqual(reason.text, text) }
        Texts.language = .german
        for (reason, text) in german { XCTAssertEqual(reason.text, text) }
    }
}
