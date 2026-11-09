import XCTest
@testable import SparkDesign

/// The needle field and the strobe: what VoiceOver hears, and which way the strobe drifts.
final class TunerBlocksTests: XCTestCase {
    func testDeviationInWords() {
        XCTAssertEqual(CentReading(cents: 0.34).spoken, "plus 0,3 Cent, zu hoch")
        XCTAssertEqual(CentReading(cents: -12.04).spoken, "minus 12,0 Cent, zu tief")
        XCTAssertEqual(CentReading(cents: 0.2, isInTune: true).spoken, "plus 0,2 Cent, gestimmt")
        XCTAssertEqual(CentReading(cents: -3, isHeld: true).spoken, "minus 3,0 Cent, zu tief, gehalten")
        XCTAssertEqual(CentReading(cents: 0.02).spoken, "0,0 Cent, mittig")
    }

    func testStrobeDriftsRightWhenSharpAndStandsStillInTune() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let sharp = StrobeMotion()
        _ = sharp.advance(to: start, cents: 1)
        let moved = sharp.advance(to: start.addingTimeInterval(0.05), cents: 1)
        XCTAssertGreaterThan(moved.0, 0)
        XCTAssertEqual(moved.1, moved.0 * 4, accuracy: 1e-9, "the lower row is four times as fast")
        let flat = StrobeMotion()
        _ = flat.advance(to: start, cents: -1)
        XCTAssertLessThan(flat.advance(to: start.addingTimeInterval(0.05), cents: -1).0, 0)
        let still = StrobeMotion()
        _ = still.advance(to: start, cents: 0)
        XCTAssertEqual(still.advance(to: start.addingTimeInterval(1), cents: 0).0, 0)
    }

    /// A tenth of a cent still moves the lower row visibly: more than a point per second.
    func testATenthOfACentIsSeen() {
        XCTAssertGreaterThan(0.1 * StrobeBand.speed * 4, 2)
    }
}
