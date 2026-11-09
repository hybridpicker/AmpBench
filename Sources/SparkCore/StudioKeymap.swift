import Foundation

/// Where a shortcut works in Spark Studio, the app that joins Spark Recorder and Spark Presets.
public enum KeyScope: String, CaseIterable, Sendable {
    /// In the whole window, whichever area shows. Single keys still step aside while text is being typed.
    case everywhere
    /// Only while the area "Aufnahme" shows.
    case recording
    /// Only while the area "Presets" shows.
    case presets
    /// Only while the area "Stimmgerät" shows.
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

/// One shortcut of Spark Studio. Keys are lowercase characters or the names in `StudioShortcut.namedKeys`.
public struct StudioShortcut: Hashable, Sendable {
    public var key: String
    public var modifiers: KeyModifiers
    public var scope: KeyScope
    /// What it does, as the menu or the shortcut list says it.
    public var action: String
    /// When it works, if not always, such as "Bluetooth verbunden".
    public var condition: String?

    public init(_ key: String, _ modifiers: KeyModifiers = [], _ scope: KeyScope, _ action: String,
                when condition: String? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.scope = scope
        self.action = action
        self.condition = condition
    }

    public static let namedKeys: [String: String] = [
        "space": "Leertaste", "escape": "Esc", "left": "←", "right": "→", "up": "↑", "down": "↓",
        "delete": "⌫", "forwardDelete": "⌦",
    ]

    public var display: String {
        modifiers.symbols + (Self.namedKeys[key] ?? key.uppercased())
    }

    /// True for a key pressed without ⌘, ⌃ or ⌥. ⇧ alone still counts as a single key.
    public var isSingleKey: Bool { modifiers.isDisjoint(with: [.command, .control, .option]) }
}

/// Every shortcut of Spark Studio, taken from its areas, with the scope decided in docs/STUDIO.md.
///
/// Today's apps do not read this list yet. It is the plan that the Studio key handling will follow, and the tests
/// keep it free of conflicts.
public enum StudioKeymap {
    public static let all: [StudioShortcut] = everywhere + recording + presets + tuner

    /// Slots that get ⌘ and ⌥⌘ with their digit: as many as the device with the most slots has (REACTOR, 8), and no
    /// more than the map holds without a conflict. A device with fewer slots simply has fewer menu items. SparkControl's
    /// `DeviceProfile.largestSlotCount` must not exceed it.
    public static let slotKeys = 8

    static let everywhere: [StudioShortcut] = [
        StudioShortcut("r", [], .everywhere, "Aufnahme starten oder stoppen, auch „Nochmal“"),
        StudioShortcut("space", [], .everywhere, "Abspielen oder anhalten; während der Aufnahme stoppen und anhören"),
        StudioShortcut("1", [.command, .shift], .everywhere, "Bereich Aufnahme"),
        StudioShortcut("2", [.command, .shift], .everywhere, "Bereich Presets"),
        StudioShortcut("3", [.command, .shift], .everywhere, "Bereich Stimmgerät"),
        StudioShortcut("/", .command, .everywhere, "Tastaturkürzel"),
        StudioShortcut("z", .command, .everywhere, "Rückgängig, im aktiven Bereich"),
        StudioShortcut("z", [.command, .shift], .everywhere, "Wiederholen, im aktiven Bereich"),
        StudioShortcut("s", .command, .everywhere, "Preset im Editor auf dem Mac sichern", when: "Preset offen"),
    ] + (1...slotKeys).map {
        StudioShortcut("\($0)", .command, .everywhere, "Platz \($0) spielen",
                       when: $0 <= 4 ? "Bluetooth verbunden" : "Gerät mit \($0) Plätzen verbunden, das umschalten darf")
    }

    static let recording: [StudioShortcut] = [
        StudioShortcut("escape", [], .recording, "Textfeld verlassen"),
        StudioShortcut("l", [], .recording, "Schleife: A, B, aus"),
        StudioShortcut("m", [], .recording, "Marker setzen, auch während der Aufnahme"),
        StudioShortcut("k", [], .recording, "Take behalten"),
        StudioShortcut("f", [], .recording, "Favorit"),
        StudioShortcut("b", [], .recording, "Beim Vergleich zum anderen Take wechseln"),
        StudioShortcut("n", [], .recording, "Klick an oder aus"),
        StudioShortcut("t", [], .recording, "Tap-Tempo"),
        StudioShortcut("g", [], .recording, "Retro-Puffer speichern", when: "Retro an"),
        StudioShortcut("g", .command, .recording, "Retro-Puffer speichern", when: "Retro an"),
        StudioShortcut("-", [], .recording, "Langsamer"),
        StudioShortcut("+", [], .recording, "Schneller"),
        StudioShortcut("0", [], .recording, "Tempo und Tonhöhe zurücksetzen"),
        StudioShortcut("left", [], .recording, "5 Sekunden zurück"),
        StudioShortcut("right", [], .recording, "5 Sekunden vor"),
        StudioShortcut("left", .shift, .recording, "1 Sekunde zurück"),
        StudioShortcut("right", .shift, .recording, "1 Sekunde vor"),
        StudioShortcut("delete", [], .recording, "Gewählte Takes verwerfen (Papierkorb)", when: "nicht während der Aufnahme"),
        StudioShortcut("forwardDelete", [], .recording, "Gewählte Takes verwerfen (Papierkorb)",
                       when: "nicht während der Aufnahme"),
        StudioShortcut("delete", .command, .recording, "Gewählte Takes verwerfen (Papierkorb)",
                       when: "nicht während der Aufnahme"),
        StudioShortcut("e", .command, .recording, "Take umbenennen"),
        StudioShortcut("r", [.command, .shift], .recording, "Take im Finder zeigen"),
        StudioShortcut("f", .command, .recording, "Aufnahmen suchen"),
    ] + (1...5).map { StudioShortcut("\($0)", [], .recording, "Mit \($0) bewerten") }

    static let presets: [StudioShortcut] = [
        StudioShortcut("n", .command, .presets, "Neues Preset"),
        StudioShortcut("n", [.command, .shift], .presets, "Neues Preset aus Vorlage …"),
        StudioShortcut("d", .command, .presets, "Preset duplizieren", when: "Preset offen"),
        StudioShortcut("s", [.command, .shift], .presets, "Preset sichern unter …", when: "Preset offen"),
        StudioShortcut("e", .command, .presets, "Preset umbenennen", when: "Preset gewählt"),
        StudioShortcut("delete", .command, .presets, "Preset in den Papierkorb", when: "Preset gewählt"),
        StudioShortcut("r", [.command, .shift], .presets, "Preset im Finder zeigen"),
        StudioShortcut("b", .command, .presets, "Mit gespeichertem Stand vergleichen (A/B)", when: "geändert"),
        StudioShortcut("l", [.command, .shift], .presets, "Änderungen live hören an oder aus"),
        StudioShortcut("r", .command, .presets, "Verstärker neu lesen", when: "Bluetooth verbunden"),
        StudioShortcut("0", .control, .presets, "Gewähltes Gerät der Kette an oder aus", when: "Preset offen"),
        StudioShortcut("left", [], .presets, "Regler kleiner", when: "Regler hat den Fokus"),
        StudioShortcut("right", [], .presets, "Regler größer", when: "Regler hat den Fokus"),
        StudioShortcut("down", [], .presets, "Regler kleiner", when: "Regler hat den Fokus"),
        StudioShortcut("up", [], .presets, "Regler größer", when: "Regler hat den Fokus"),
        StudioShortcut("left", .shift, .presets, "Regler in großen Schritten kleiner", when: "Regler hat den Fokus"),
        StudioShortcut("right", .shift, .presets, "Regler in großen Schritten größer", when: "Regler hat den Fokus"),
        StudioShortcut("down", .shift, .presets, "Regler in großen Schritten kleiner", when: "Regler hat den Fokus"),
        StudioShortcut("up", .shift, .presets, "Regler in großen Schritten größer", when: "Regler hat den Fokus"),
    ] + (1...slotKeys).map {
        StudioShortcut("\($0)", [.command, .option], .presets, "Auf Platz \($0) speichern …",
                       when: $0 <= 4 ? "Bluetooth verbunden, Preset offen"
                           : "Gerät mit \($0) Plätzen verbunden, das speichern darf, Preset offen")
    } + (1...7).map {
        StudioShortcut("\($0)", .control, .presets, "Gerät \($0) der Kette wählen", when: "Preset offen")
    }

    /// The tuner has no single keys: R and Space keep recording and playing from there, as everywhere.
    static let tuner: [StudioShortcut] = [
        StudioShortcut("t", .command, .tuner, "Zeiger oder Stroboskop"),
        StudioShortcut("up", .command, .tuner, "Kammerton 0,1 Hz höher"),
        StudioShortcut("down", .command, .tuner, "Kammerton 0,1 Hz tiefer"),
        StudioShortcut("0", .command, .tuner, "Kammerton 440 Hz"),
    ] + Tuning.allCases.enumerated().map { index, tuning in
        StudioShortcut("\(index + 1)", .control, .tuner, "Stimmung \(tuning.title)")
    }

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
