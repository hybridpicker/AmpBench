import AppKit
import SparkPresetsUI
import SparkRecorderUI
import SwiftUI

/// The two windows of Spark Studio and which of them is in front. Menus follow the window in front, so a key both
/// apps use, such as ⌘E, acts on that window's take or preset.
@MainActor
final class Studio: ObservableObject {
    enum Area { case recording, presets }

    static let shared = Studio()

    let recorder = RecorderHost(windowTitle: "Aufnahme")
    let presets = PresetsHost(windowTitle: "Presets")
    @Published var front = Area.recording {
        didSet {
            guard front != oldValue else { return }
            // SwiftUI rebuilds a menu only when it opens, but a key goes to whatever the menus hold right now. Without
            // this, ⌘N would still open a preset just after switching to the Aufnahme window.
            // Once at the next turn of the run loop and once more after SwiftUI has surely rebuilt its menu model.
            for delay in [0.0, 0.15] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { Self.refreshMenus() } }
            }
        }
    }
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil,
                                                          queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self else { return }
                if window === self.recorder.window {
                    self.front = .recording
                } else if window === self.presets.window {
                    self.front = .presets
                }
            }
        }
    }

    /// What AppKit does right before a menu opens, for every menu at once.
    static func refreshMenus() {
        func refresh(_ menu: NSMenu) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items { if let submenu = item.submenu { refresh(submenu) } }
        }
        if let menu = NSApp.mainMenu { refresh(menu) }
    }

    func show(_ area: Area) {
        switch area {
        case .recording: recorder.showWindow()
        case .presets: presets.showWindow()
        }
        // A window started from a shell may not become main, so the menus are told directly.
        front = area
    }
}

struct StudioApp: App {
    @NSApplicationDelegateAdaptor(StudioDelegate.self) private var delegate
    @StateObject private var studio = Studio.shared

    var body: some Scene {
        // The windows come from the hosts. This scene only carries the menus.
        Settings { EmptyView() }
            .commands { StudioCommands(studio: studio) }
    }
}

/// Observes the window in front itself: menus are rebuilt when an observed object of a `Commands` changes.
struct StudioCommands: Commands {
    @ObservedObject var studio: Studio

    var body: some Commands {
        RecorderMenus(studio.recorder, isActive: studio.front == .recording)
        PresetMenus(studio.presets, isActive: studio.front == .presets)
        CommandGroup(before: .windowList) {
            Button("Aufnahme") { studio.show(.recording) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Button("Presets") { studio.show(.presets) }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            Divider()
        }
    }
}

@MainActor
final class StudioDelegate: NSObject, NSApplicationDelegate {
    private var studio: Studio { Studio.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The recorder first: recovery of an interrupted take, its window, its self-test.
        studio.recorder.applicationDidFinishLaunching(notification)
        // Bluetooth stays off until the Presets window opens, unless a test asks for that window right away.
        if PresetsHost.isRequestedAtLaunch { studio.show(.presets) }
        MenuDump.startIfRequested(studio)
    }

    /// A click on the Dock icon brings the Aufnahme window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { studio.show(.recording) }
        return true
    }

    /// As in Spark Recorder: a running recording continues after the last window closed, and the Dock shows REC.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !studio.recorder.isRecording
    }

    func applicationWillTerminate(_ notification: Notification) {
        studio.recorder.applicationWillTerminate(notification)
    }
}
