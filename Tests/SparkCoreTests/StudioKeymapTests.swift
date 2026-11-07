import XCTest
@testable import SparkCore

/// The keyboard plan for Spark Studio: no two shortcuts on the same keys in the same area.
final class StudioKeymapTests: XCTestCase {
    func testNoConflicts() {
        let conflicts = StudioKeymap.conflicts()
        XCTAssertTrue(conflicts.isEmpty, conflicts.map { "\($0.0.display): \($0.0.action) / \($0.1.action)" }
            .joined(separator: "\n"))
    }

    func testConflictCheckFindsOverlaps() {
        let clash = [StudioShortcut("r", [], .everywhere, "A"), StudioShortcut("r", [], .recording, "B")]
        XCTAssertEqual(StudioKeymap.conflicts(in: clash).count, 1)
        let apart = [StudioShortcut("e", .command, .recording, "A"), StudioShortcut("e", .command, .presets, "B")]
        XCTAssertTrue(StudioKeymap.conflicts(in: apart).isEmpty)
    }

    /// Only R, Space and Esc work as single keys in the whole window. Everything else would surprise in the editor.
    func testOnlyRSpaceAndEscapeAreSingleKeysEverywhere() {
        let singles = StudioKeymap.shortcuts(in: .everywhere).filter(\.isSingleKey).map(\.key)
        XCTAssertEqual(Set(singles), ["r", "space", "escape"])
    }

    /// The knobs keep the arrow keys in the presets area, the recorder keeps them for jumping in its area.
    func testArrowsNeverWorkEverywhere() {
        let arrows: Set<String> = ["left", "right", "up", "down"]
        XCTAssertFalse(StudioKeymap.shortcuts(in: .everywhere).contains { arrows.contains($0.key) })
        XCTAssertTrue(StudioKeymap.shortcuts(in: .presets).contains { $0.key == "up" })
        XCTAssertTrue(StudioKeymap.shortcuts(in: .recording).contains { $0.key == "left" })
    }

    func testPresetsAreaHasNoLettersOrDigitsAsSingleKeys() {
        let singles = StudioKeymap.shortcuts(in: .presets).filter(\.isSingleKey)
        XCTAssertTrue(singles.allSatisfy { StudioShortcut.namedKeys[$0.key] != nil }, "\(singles.map(\.display))")
    }

    /// Every single key the recorder's KeyRouter handles today is in the plan, in the recording area or everywhere.
    func testAllRecorderSingleKeysArePlanned() {
        let today = ["r", "space", "l", "m", "k", "f", "b", "n", "t", "g", "1", "2", "3", "4", "5", "+", "-", "0",
                     "left", "right", "delete", "forwardDelete"]
        let planned = Set(StudioKeymap.all.filter { $0.isSingleKey && $0.scope != .presets }.map(\.key))
        XCTAssertEqual(Set(today).subtracting(planned), [])
    }

    func testAreaSwitchesAndSlotsWorkEverywhere() {
        for key in ["1", "2"] {
            XCTAssertEqual(StudioKeymap.all.filter { $0.key == key && $0.modifiers == [.command, .shift] }.map(\.scope),
                           [.everywhere])
        }
        let slots = StudioKeymap.all.filter { $0.modifiers == .command && ["1", "2", "3", "4"].contains($0.key) }
        XCTAssertEqual(slots.count, 4)
        XCTAssertTrue(slots.allSatisfy { $0.scope == .everywhere && $0.condition == "Bluetooth verbunden" })
    }

    func testDisplayUsesMenuOrder() {
        XCTAssertEqual(StudioShortcut("1", [.command, .option], .presets, "").display, "⌥⌘1")
        XCTAssertEqual(StudioShortcut("z", [.shift, .command], .everywhere, "").display, "⇧⌘Z")
        XCTAssertEqual(StudioShortcut("space", [], .everywhere, "").display, "Leertaste")
    }
}
