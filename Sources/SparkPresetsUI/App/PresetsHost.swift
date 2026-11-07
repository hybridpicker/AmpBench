import AppKit
import SparkControl
import SwiftUI

/// Spark Presets inside another app, Spark Studio: the same model, window content and menus as the app.
///
/// Bluetooth starts only when the window first shows, from the content's own start task, and `disconnect` ends the
/// connection again, so the Spark app on the phone can take the amp.
@MainActor
public final class PresetsHost {
    let model: PresetsModel
    public private(set) var window: NSWindow?
    private let title: String

    /// `--library <folder>` (the recorder's test library) keeps the presets in its subfolder "Presets", filled with
    /// made-up presets, never in `~/Music/Spark Presets`.
    public init(windowTitle: String) {
        title = windowTitle
        let folder = Snapshot.arguments["library"].flatMap { $0.isEmpty ? nil : $0 }.map {
            Snapshot.seededTestFolder(URL(fileURLWithPath: $0, isDirectory: true)
                .appendingPathComponent("Presets", isDirectory: true))
        }
        model = PresetsModel(folder: folder ?? PresetLibrary.defaultFolder)
    }

    /// True when the launch asks for the window at once: a picture, an opened preset or the live self-test.
    /// The preset open in the editor, by the uuid it carries, if any.
    public var openPresetID: String? { model.editor.preset?.uuid }

    public static var isRequestedAtLaunch: Bool {
        let arguments = Snapshot.arguments
        return ["snapshot", "open", "size", "live-selftest"].contains { arguments[$0] != nil }
    }

    public func showWindow() {
        if window == nil {
            let made = Self.makeWindow(for: model, title: title)
            made.setFrameAutosaveName("SparkStudioPresets")
            made.center()
            window = made
            Snapshot.window = made
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window of the app and of the snapshot: SwiftUI content in an AppKit window, with the toolbar bridged so the
    /// search field and the sidebar button appear.
    static func makeWindow(for model: PresetsModel, title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: PresetsApp.root(model))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = host
        window.title = title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 900, height: 600)
        return window
    }
}

/// Spark Presets' menus for Spark Studio, with "Verbinden" and "Trennen" in the amp menu. While the other window is
/// in front, Presets' own keys rest and the keys both apps use are left to it.
public struct PresetMenus: Commands {
    private let model: PresetsModel
    private let isActive: Bool

    public init(_ host: PresetsHost, isActive: Bool) {
        model = host.model
        self.isActive = isActive
    }

    public var body: some Commands {
        PresetCommands(model: model, isActive: isActive, managesConnection: true)
    }
}
