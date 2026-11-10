import AmpText
import XCTest
@testable import SparkCore

/// The keyboard plan for AmpBench: no two shortcuts on the same keys in the same area.
final class StudioKeymapTests: XCTestCase {
    override func tearDown() {
        Texts.language = .english
        super.tearDown()
    }

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

    /// Only R and Space work as single keys in the whole window. Everything else would surprise in the editor, and
    /// Esc stays with the presets' search field.
    func testOnlyRAndSpaceAreSingleKeysEverywhere() {
        let singles = StudioKeymap.shortcuts(in: .everywhere).filter(\.isSingleKey).map(\.key)
        XCTAssertEqual(Set(singles), ["r", "space"])
        XCTAssertTrue(StudioKeymap.isSingleKeyEverywhere(" "))
        XCTAssertTrue(StudioKeymap.isSingleKeyEverywhere("r"))
        for key in ["escape", "left", "n", "1", "delete"] {
            XCTAssertFalse(StudioKeymap.isSingleKeyEverywhere(key), key)
        }
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
        for key in ["1", "2", "3"] {
            XCTAssertEqual(StudioKeymap.all.filter { $0.key == key && $0.modifiers == [.command, .shift] }.map(\.scope),
                           [.everywhere])
        }
        let slots = StudioKeymap.all.filter { $0.modifiers == .command && ["1", "2", "3", "4"].contains($0.key) }
        XCTAssertEqual(slots.count, 4)
        XCTAssertTrue(slots.allSatisfy { $0.scope == .everywhere && $0.condition == "Bluetooth connected" })
    }

    /// The REACTOR has 8 slots. Every one of them gets ⌘ and ⌥⌘ with its digit, without a conflict anywhere.
    func testSlotKeysCoverTheDeviceWithTheMostSlots() {
        XCTAssertEqual(StudioKeymap.slotKeys, 8)
        let play = StudioKeymap.all.filter { $0.modifiers == .command && Int($0.key) != nil && $0.action.hasPrefix("Play slot") }
        XCTAssertEqual(play.map(\.key), (1...8).map(String.init))
        let store = StudioKeymap.all.filter { $0.modifiers == [.command, .option] && Int($0.key) != nil }
        XCTAssertEqual(store.map(\.key), (1...8).map(String.init))
        XCTAssertTrue(StudioKeymap.conflicts().isEmpty)
        // ⌘0 stays the tuner's, so a ninth slot could not get a digit.
        XCTAssertTrue(StudioKeymap.all.contains { $0.key == "0" && $0.modifiers == .command && $0.scope == .tuner })
    }

    /// The tuner listens while one plays; a stray key must not change anything there, so it has no single keys.
    func testTunerAreaHasNoSingleKeys() {
        let tuner = StudioKeymap.shortcuts(in: .tuner)
        XCTAssertFalse(tuner.isEmpty)
        XCTAssertTrue(tuner.allSatisfy { !$0.isSingleKey }, "\(tuner.filter(\.isSingleKey).map(\.display))")
        XCTAssertEqual(tuner.filter { $0.modifiers == .control }.count, Tuning.allCases.count)
    }

    func testDisplayUsesMenuOrder() {
        XCTAssertEqual(StudioShortcut("1", [.command, .option], .presets, "").display, "⌥⌘1")
        XCTAssertEqual(StudioShortcut("z", [.shift, .command], .everywhere, "").display, "⇧⌘Z")
        XCTAssertEqual(StudioShortcut("space", [], .everywhere, "").display, "Space")
    }

    /// The list is in the app's language: German reads as it did before English became the language of the code.
    func testTheListIsGermanInGerman() {
        XCTAssertEqual(StudioKeymap.shortcuts(in: .everywhere).first?.action, "Start or stop recording, also “Again”")
        Texts.language = .german
        XCTAssertEqual(StudioKeymap.shortcuts(in: .everywhere).first?.action,
                       "Aufnahme starten oder stoppen, auch „Nochmal“")
        XCTAssertEqual(StudioShortcut("space", [], .everywhere, "").display, "Leertaste")
        let third = StudioKeymap.all.first { $0.modifiers == .command && $0.key == "3" }
        XCTAssertEqual(third?.action, "Platz 3 spielen")
        XCTAssertEqual(third?.condition, "Bluetooth verbunden")
        XCTAssertTrue(StudioKeymap.shortcuts(in: .tuner).contains { $0.action == "Stimmung Halbton tiefer" })
        XCTAssertTrue(StudioKeymap.conflicts().isEmpty)
    }
}
