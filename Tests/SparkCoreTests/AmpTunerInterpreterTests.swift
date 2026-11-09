@testable import SparkCore
import XCTest

/// The amp's own tuner readings as the tuner shows them: smoothed, whole cents, the octave from the tuning's string.
final class AmpTunerInterpreterTests: XCTestCase {
    /// Readings 1/15 s apart, as the MINI and the NEO send them.
    private func feed(_ interpreter: inout AmpTunerInterpreter, note: Int, cents: [Double?], from start: Double = 0) -> Double {
        var time = start
        for value in cents {
            interpreter.add(pitchClass: note, cents: value, time: time)
            time += 1.0 / 15
        }
        return time
    }

    func testTheMedianOfJumpingReadingsShowsInWholeCents() throws {
        var tuner = AmpTunerInterpreter()
        let end = feed(&tuner, note: 9, cents: [-8, 12, -3, 25, -1, 4, -6, 2])
        let readout = try XCTUnwrap(tuner.readout(time: end))
        XCTAssertEqual(readout.note.midi, 45, "A of standard tuning is the fifth string, A2")
        XCTAssertEqual(readout.string, 5)
        XCTAssertTrue(readout.knowsOctave)
        XCTAssertTrue(readout.isFromAmp)
        XCTAssertEqual(readout.cents, readout.cents.rounded())
        XCTAssertLessThan(abs(readout.cents), 5, "a single +25 does not pull the median")
        XCTAssertTrue(tuner.hasSignal)
    }

    func testAStrayNoteAtTheAttackDoesNotShow() throws {
        var tuner = AmpTunerInterpreter()
        var time = feed(&tuner, note: 2, cents: [3, 4, 3, 4])
        time = feed(&tuner, note: 3, cents: [-45, -44], from: time)
        XCTAssertEqual(try XCTUnwrap(tuner.readout(time: time)).note.pitchClass, 2)
        time = feed(&tuner, note: 3, cents: [-40], from: time)
        XCTAssertEqual(try XCTUnwrap(tuner.readout(time: time)).note.pitchClass, 3, "three in a row switch")
    }

    func testANoteTwoStringsShareHasNoOctave() throws {
        var tuner = AmpTunerInterpreter()
        let end = feed(&tuner, note: 4, cents: [10, 10, 10, 10])
        let readout = try XCTUnwrap(tuner.readout(time: end))
        XCTAssertEqual(readout.noteName, "E")
        XCTAssertNil(readout.string, "E is the sixth and the first string")
        XCTAssertFalse(readout.knowsOctave)
        XCTAssertEqual(readout.frequency, 0)
        XCTAssertEqual(readout.direction, .high)
    }

    func testAnotherConcertPitchShiftsTheCents() throws {
        var tuner = AmpTunerInterpreter(a4: 442)
        let end = feed(&tuner, note: 9, cents: [0, 0, 0, 0])
        // 442 Hz is 7.85 cents above 440: what the amp calls in tune is that much too low.
        XCTAssertEqual(try XCTUnwrap(tuner.readout(time: end)).cents, -8)
    }

    func testCentsBeyondTheSemitoneMoveToTheNeighbor() throws {
        var tuner = AmpTunerInterpreter(tuning: .chromatic, a4: 450)
        // 450 Hz is 38.9 cents above 440: A at −20 cents on the amp is G♯ at +41 here.
        let end = feed(&tuner, note: 9, cents: [-20, -20, -20, -20])
        let readout = try XCTUnwrap(tuner.readout(time: end))
        XCTAssertEqual(readout.note.pitchClass, 8)
        XCTAssertEqual(readout.cents, 41)
    }

    func testInTuneNeedsHalfASecondWithinThreeCents() throws {
        var tuner = AmpTunerInterpreter()
        var time = feed(&tuner, note: 7, cents: [2, -1, 1, 0])
        XCTAssertFalse(try XCTUnwrap(tuner.readout(time: time)).isInTune)
        for _ in 0..<10 {
            time = feed(&tuner, note: 7, cents: [1], from: time)
            _ = tuner.readout(time: time)
        }
        let readout = try XCTUnwrap(tuner.readout(time: time))
        XCTAssertTrue(readout.isInTune)
        XCTAssertEqual(readout.direction, .inTune)
        XCTAssertEqual(readout.string, 3)
    }

    func testTheLastNoteIsHeldBrieflyAfterTheSignalEnds() throws {
        var tuner = AmpTunerInterpreter()
        let end = feed(&tuner, note: 11, cents: [5, 5, 5, 5, nil, nil])
        _ = tuner.readout(time: end - 0.3)
        let held = try XCTUnwrap(tuner.readout(time: end + 0.2))
        XCTAssertTrue(held.isHeld)
        XCTAssertFalse(tuner.hasSignal)
        XCTAssertNil(tuner.readout(time: end + 2))
    }

    func testResetForgetsTheNote() {
        var tuner = AmpTunerInterpreter()
        let end = feed(&tuner, note: 9, cents: [0, 0, 0, 0])
        tuner.reset()
        XCTAssertNil(tuner.readout(time: end))
    }
}
