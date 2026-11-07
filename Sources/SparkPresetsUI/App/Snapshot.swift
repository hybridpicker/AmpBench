import AppKit
import SparkControl
import SparkDesign
import SwiftUI

/// Pictures of Spark Studio's own window with the area Presets, for checking the design, without screen recording
/// permission and without ever seeing anything but this window. Only runs when started with `--snapshot`:
///
///     SparkStudio --library /tmp/test --offline --appearance dark --size 1180x780 --open template:Crunch \
///                 --focus drive --snapshot /tmp/shot.png [--delay 2] [--quit]
///
/// `--offline` leaves Bluetooth off, `--library <test folder>` keeps made-up presets in its subfolder "Presets".
/// `--open` takes `template:<name>`, `empty`, `slot:<1-4>` or `saved:<file name>`.
@MainActor
enum Snapshot {
    static var arguments: [String: String] {
        var values: [String: String] = [:]
        let list = CommandLine.arguments
        for (index, argument) in list.enumerated() where argument.hasPrefix("--") {
            let next = index + 1 < list.count && !list[index + 1].hasPrefix("--") ? list[index + 1] : ""
            values[String(argument.dropFirst(2))] = next
        }
        return values
    }

    static var isOffline: Bool { arguments["offline"] != nil }
    /// The window to size and draw, set by Spark Studio.
    static weak var window: NSWindow?
    private static var target: NSWindow? { window ?? NSApp.windows.first(where: { $0.isVisible }) }
    /// A test folder for presets, so pictures never show one's own presets. A new, empty one gets the templates as
    /// made-up presets and one backup.
    static func seededTestFolder(_ folder: URL) -> URL {
        let library = PresetLibrary(folder: folder)
        try? library.reload()
        if library.items.isEmpty {
            for template in PresetFactory.templates {
                try? library.save(template.preset, origin: "Vorlage")
            }
            if let first = PresetFactory.templates.first {
                try? library.save(first.preset, origin: "Platz 2", isBackup: true)
            }
        }
        return folder
    }
    /// Window pictures skip the sidebar's translucent material, so it gets a plain background then.
    static let isActive = CommandLine.arguments.contains("--snapshot")

    static func prepare() {
        switch arguments["appearance"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    static func run(_ model: PresetsModel) async {
        let values = arguments
        guard values["snapshot"] != nil || values["open"] != nil || values["size"] != nil else { return }
        try? await Task.sleep(for: .milliseconds(600))
        if let size = values["size"], let window = target {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                window.center()
            }
        }
        open(values["open"], in: model)
        if let focus = values["focus"], let place = ChainPlace.allCases.first(where: { "\($0)" == focus }) {
            model.editor.focus = place
        }
        guard let path = values["snapshot"], !path.isEmpty else { return }
        try? await Task.sleep(for: .seconds(Double(values["delay"] ?? "") ?? 1.5))
        write(to: URL(fileURLWithPath: path))
        if values["quit"] != nil { NSApp.terminate(nil) }
    }

    private static func open(_ what: String?, in model: PresetsModel) {
        guard let what else { return }
        let parts = what.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "empty": model.newPreset()
        case "template":
            model.newPreset(from: PresetFactory.templates.first { $0.name == parts.last })
        case "slot":
            if let number = Int(parts.last ?? ""), (1...4).contains(number) { model.select(.slot(number - 1)) }
        case "saved":
            if let item = model.items.first(where: { $0.url.deletingPathExtension().lastPathComponent == parts.last }) {
                model.select(.saved(item.url))
            }
        default: break
        }
    }

    /// Draws the window's content into a PNG. Translucent materials, such as the sidebar's, are left out.
    static func write(to url: URL) {
        // The content only, like the recorder's pictures: the toolbar's translucent material would come out white.
        guard let window = target, let view = window.contentView, let data = WindowPicture.png(of: view) else {
            FileHandle.standardError.write(Data("No window to draw.\n".utf8))
            return
        }
        do {
            try data.write(to: url)
            print("Snapshot written to \(url.path)")
        } catch {
            FileHandle.standardError.write(Data("Could not write the snapshot.\n".utf8))
        }
    }
}
