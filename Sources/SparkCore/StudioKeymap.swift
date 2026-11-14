import AmpText
import Foundation

/// Where a shortcut works in AmpBench, the app that joins Spark Recorder and Spark Presets.
public enum KeyScope: String, CaseIterable, Sendable {
    /// In the whole window, whichever area shows. Single keys still step aside while text is being typed.
    case everywhere
    /// Only while the area "Record" shows.
    case recording
    /// Only while the area "Presets" shows.
    case presets
    /// Only while the area "Tuner" shows.
    case tuner

    public func overlaps(_ other: KeyScope) -> Bool {
        self == other || self == .everywhere || other == .everywhere
    }
}

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let shift = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)

    /// The symbols in the order macOS menus show them.
    public var symbols: String {
        [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { contains($0.0) }.map(\.1).joined()
    }
}

/// One shortcut of AmpBench. Keys are lowercase characters or the names in `StudioShortcut.namedKeys`.
public struct StudioShortcut: Hashable, Sendable {
    public var key: String
    public var modifiers: KeyModifiers
    public var scope: KeyScope
    /// What it does, as the menu or the shortcut list says it.
    public var action: String
    /// When it works, if not always, such as "Bluetooth connected".
    public var condition: String?

    public init(_ key: String, _ modifiers: KeyModifiers = [], _ scope: KeyScope, _ action: String,
                when condition: String? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.scope = scope
        self.action = action
        self.condition = condition
    }

    public static var namedKeys: [String: String] { [
        "space": tr("Space"), "escape": "Esc", "left": "←", "right": "→", "up": "↑", "down": "↓",
        "delete": "⌫", "forwardDelete": "⌦", "return": "↩",
    ] }

    public var display: String {
        modifiers.symbols + (Self.namedKeys[key] ?? key.uppercased())
    }

    /// True for a key pressed without ⌘, ⌃ or ⌥. ⇧ alone still counts as a single key.
    public var isSingleKey: Bool { modifiers.isDisjoint(with: [.command, .control, .option]) }
}

/// Every shortcut of AmpBench, taken from its areas, with the scope decided in docs/STUDIO.md. The lists are computed,
/// so their texts follow the language.
///
/// Today's apps do not read this list yet. It is the plan that the Studio key handling will follow, and the tests
/// keep it free of conflicts.
public enum StudioKeymap {
    public static var all: [StudioShortcut] { everywhere + recording + presets + tuner }

    /// Slots that get ⌘ and ⌥⌘ with their digit: as many as the device with the most slots has (REACTOR, 8), and no
    /// more than the map holds without a conflict. A device with fewer slots simply has fewer menu items. SparkControl's
    /// `DeviceProfile.largestSlotCount` must not exceed it.
    public static let slotKeys = 8

    static var everywhere: [StudioShortcut] { [
        StudioShortcut("r", [], .everywhere, tr("Start or stop recording, also “Again”")),
        StudioShortcut("space", [], .everywhere, tr("Play or pause; while recording, stop and listen")),
        StudioShortcut("1", [.command, .shift], .everywhere, tr("Record area")),
        StudioShortcut("2", [.command, .shift], .everywhere, tr("Presets area")),
        StudioShortcut("3", [.command, .shift], .everywhere, tr("Tuner area")),
        StudioShortcut("/", .command, .everywhere, tr("Keyboard shortcuts")),
        StudioShortcut("z", .command, .everywhere, tr("Undo, in the active area")),
        StudioShortcut("z", [.command, .shift], .everywhere, tr("Redo, in the active area")),
        StudioShortcut("s", .command, .everywhere, tr("Save the preset in the editor to this Mac"), when: tr("Preset open")),
    ] + (1...slotKeys).map {
        StudioShortcut("\($0)", .command, .everywhere, tr("Play slot %d", $0),
                       when: $0 <= 4 ? tr("Bluetooth connected") : tr("Device with %d slots connected that may switch", $0))
    } }

    static var recording: [StudioShortcut] { [
        StudioShortcut("escape", [], .recording, tr("Leave the text field")),
        StudioShortcut("l", [], .recording, tr("Loop: A, B, off")),
        StudioShortcut("m", [], .recording, tr("Set a marker, also while recording")),
        StudioShortcut("k", [], .recording, tr("Keep take")),
        StudioShortcut("f", [], .recording, tr("Favorite")),
        StudioShortcut("b", [], .recording, tr("Switch to the other take when comparing")),
        StudioShortcut("n", [], .recording, tr("Click on or off")),
        StudioShortcut("t", [], .recording, tr("Tap tempo")),
        StudioShortcut("g", [], .recording, tr("Save the retro buffer"), when: tr("Retro on")),
        StudioShortcut("g", .command, .recording, tr("Save the retro buffer"), when: tr("Retro on")),
        StudioShortcut("-", [], .recording, tr("Slower")),
        StudioShortcut("+", [], .recording, tr("Faster")),
        StudioShortcut("0", [], .recording, tr("Reset tempo and pitch")),
        StudioShortcut("left", [], .recording, tr("Back 5 seconds")),
        StudioShortcut("right", [], .recording, tr("Forward 5 seconds")),
        StudioShortcut("left", .shift, .recording, tr("Back 1 second")),
        StudioShortcut("right", .shift, .recording, tr("Forward 1 second")),
        StudioShortcut("delete", [], .recording, tr("Discard selected takes (Trash)"), when: tr("not while recording")),
        StudioShortcut("forwardDelete", [], .recording, tr("Discard selected takes (Trash)"),
                       when: tr("not while recording")),
        StudioShortcut("delete", .command, .recording, tr("Discard selected takes (Trash)"),
                       when: tr("not while recording")),
        StudioShortcut("e", .command, .recording, tr("Rename take")),
        StudioShortcut("r", [.command, .shift], .recording, tr("Show take in Finder")),
        StudioShortcut("f", .command, .recording, tr("Search takes")),
    ] + (1...5).map { StudioShortcut("\($0)", [], .recording, tr("Rate with %d", $0)) } }

    static var presets: [StudioShortcut] { [
        StudioShortcut("n", .command, .presets, tr("New preset")),
        StudioShortcut("n", [.command, .shift], .presets, tr("New preset from template…")),
        StudioShortcut("d", .command, .presets, tr("Duplicate preset"), when: tr("Preset open")),
        StudioShortcut("s", [.command, .shift], .presets, tr("Save preset as…"), when: tr("Preset open")),
        StudioShortcut("e", .command, .presets, tr("Rename preset"), when: tr("Preset selected")),
        StudioShortcut("delete", .command, .presets, tr("Move preset to Trash"), when: tr("Preset selected")),
        StudioShortcut("r", [.command, .shift], .presets, tr("Show preset in Finder")),
        StudioShortcut("b", .command, .presets, tr("Compare with the saved state (A/B)"), when: tr("changed")),
        StudioShortcut("l", [.command, .shift], .presets, tr("Hear changes live on or off")),
        StudioShortcut("r", .command, .presets, tr("Read the amp again"), when: tr("Bluetooth connected")),
        StudioShortcut("0", .control, .presets, tr("Selected device of the chain on or off"), when: tr("Preset open")),
        StudioShortcut("l", .command, .presets, tr("Library: open or close")),
        StudioShortcut("f", .command, .presets, tr("Search the library")),
        StudioShortcut("escape", [], .presets, tr("Close the library"), when: tr("Library open")),
        StudioShortcut("return", [], .presets, tr("Hear the selected sound on the amp"), when: tr("Library open")),
        StudioShortcut("return", .command, .presets, tr("Open the selected sound in the editor"),
                       when: tr("Library open")),
        StudioShortcut("k", .command, .presets, tr("Mark to listen to, or as listened to"), when: tr("Library open")),
        StudioShortcut("f", [.command, .shift], .presets, tr("Favorite on or off"), when: tr("Library open")),
        StudioShortcut("t", .command, .presets, tr("Add a tag to the selected sounds"), when: tr("Library open")),
        StudioShortcut("g", .command, .presets, tr("Next grouping: A–Z, tag, amp, origin"), when: tr("Library open")),
        StudioShortcut("left", [], .presets, tr("Decrease control"), when: tr("Control has the focus")),
        StudioShortcut("right", [], .presets, tr("Increase control"), when: tr("Control has the focus")),
        StudioShortcut("down", [], .presets, tr("Decrease control"), when: tr("Control has the focus")),
        StudioShortcut("up", [], .presets, tr("Increase control"), when: tr("Control has the focus")),
        StudioShortcut("left", .shift, .presets, tr("Decrease control in large steps"), when: tr("Control has the focus")),
        StudioShortcut("right", .shift, .presets, tr("Increase control in large steps"), when: tr("Control has the focus")),
        StudioShortcut("down", .shift, .presets, tr("Decrease control in large steps"), when: tr("Control has the focus")),
        StudioShortcut("up", .shift, .presets, tr("Increase control in large steps"), when: tr("Control has the focus")),
    ] + (1...slotKeys).map {
        StudioShortcut("\($0)", [.command, .option], .presets, tr("Save to slot %d…", $0),
                       when: $0 <= 4 ? tr("Bluetooth connected, preset open")
                           : tr("Device with %d slots connected that may save, preset open", $0))
    } + (1...7).map {
        StudioShortcut("\($0)", .control, .presets, tr("Select device %d of the chain", $0), when: tr("Preset open"))
    } }

    /// The tuner has no single keys: R and Space keep recording and playing from there, as everywhere.
    static var tuner: [StudioShortcut] { [
        StudioShortcut("t", .command, .tuner, tr("Needle or strobe")),
        StudioShortcut("up", .command, .tuner, tr("Reference pitch 0.1 Hz higher")),
        StudioShortcut("down", .command, .tuner, tr("Reference pitch 0.1 Hz lower")),
        StudioShortcut("0", .command, .tuner, tr("Reference pitch 440 Hz")),
    ] + Tuning.allCases.enumerated().map { index, tuning in
        StudioShortcut("\(index + 1)", .control, .tuner, tr("Tuning %@", tuning.title))
    } }

    /// Pairs of shortcuts that would fire on the same keys in the same area. Empty when the map is sound.
    public static func conflicts(in shortcuts: [StudioShortcut] = all) -> [(StudioShortcut, StudioShortcut)] {
        var found: [(StudioShortcut, StudioShortcut)] = []
        for (index, first) in shortcuts.enumerated() {
            for second in shortcuts[(index + 1)...]
            where first.key == second.key && first.modifiers == second.modifiers && first.scope.overlaps(second.scope) {
                found.append((first, second))
            }
        }
        return found
    }

    public static func shortcuts(in scope: KeyScope) -> [StudioShortcut] {
        all.filter { $0.scope == scope }
    }

    /// True when a single key, named as typed (" " counts as "space"), works in every area.
    public static func isSingleKeyEverywhere(_ key: String) -> Bool {
        let name = key == " " ? "space" : key
        return all.contains { $0.scope == .everywhere && $0.isSingleKey && $0.key == name }
    }
}
