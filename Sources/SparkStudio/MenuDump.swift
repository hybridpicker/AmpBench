import AppKit

/// `--menu-dump <file>` writes every menu item, once with each area in front: area, menu, title, key (empty when it
/// has none), enabled. It checks the shortcut routing without pictures of the screen. `--quit` ends the app afterwards.
@MainActor
enum MenuDump {
    static func startIfRequested(_ studio: Studio) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--menu-dump"), index + 1 < arguments.count else { return }
        let output = URL(fileURLWithPath: arguments[index + 1])
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            var lines = ["area\tmenu\ttitle\tkey\tenabled"]
            for area in StudioArea.allCases {
                let name = area.rawValue
                studio.show(area)
                // SwiftUI rebuilds the menus after the change of the area.
                try? await Task.sleep(for: .seconds(1))
                guard let menu = NSApp.mainMenu else { continue }
                // Studio refreshes the menus when the window in front changes; this makes sure before reading.
                Studio.refreshMenus()
                lines.append("# \(name): area \(studio.area), app active \(NSApp.isActive), main window \(NSApp.mainWindow?.title ?? "none"), menu delegate \(menu.items.compactMap { $0.submenu?.delegate }.count)")
                lines += items(in: menu, path: "").map { "\(name)\t\($0)" }
            }
            // Keys go through the menus as the system sends them, without the refresh above. ⌘N belongs to Presets
            // only: it must open a new preset with the Presets window in front and do nothing with the other.
            for area in StudioArea.allCases {
                studio.show(area)
                try? await Task.sleep(for: .seconds(1))
                let before = studio.presets.openPresetID
                _ = NSApp.mainMenu?.performKeyEquivalent(with: keyDown("n", .command))
                try? await Task.sleep(for: .milliseconds(500))
                let opened = studio.presets.openPresetID != before
                let expected = area == .presets
                lines.append("# key check \(area): ⌘N opened a preset: \(opened) – \(opened == expected ? "PASS" : "FAIL")")
            }
            do {
                try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
                print("Menu dump written to \(output.path)")
            } catch {
                FileHandle.standardError.write(Data("Could not write the menu dump.\n".utf8))
            }
            if arguments.contains("--quit") { NSApp.terminate(nil) }
        }
    }

    private static func keyDown(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: NSApp.mainWindow?.windowNumber ?? 0, context: nil, characters: key,
                         charactersIgnoringModifiers: key, isARepeat: false, keyCode: 45)!
    }

    private static func items(in menu: NSMenu, path: String) -> [String] {
        return menu.items.flatMap { item -> [String] in
            if let submenu = item.submenu {
                return items(in: submenu, path: path.isEmpty ? item.title : "\(path) › \(item.title)")
            }
            guard !item.isSeparatorItem else { return [] }
            return ["\(path)\t\(item.title)\t\(display(item))\t\(item.isEnabled ? "on" : "off")"]
        }
    }

    /// The key as menus show it, such as ⇧⌘E. An uppercase letter means Shift.
    private static func display(_ item: NSMenuItem) -> String {
        var flags = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        if key.count == 1, let scalar = key.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(scalar) {
            flags.insert(.shift)
        }
        switch key {
        case "\u{8}", "\u{7F}": key = "⌫"
        case "\u{1B}": key = "Esc"
        case "a"..."z", "A"..."Z": key = key.uppercased()
        default: break
        }
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined()
        return symbols + key
    }
}
