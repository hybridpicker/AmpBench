import AppKit
import SparkPresetsUI
import SparkRecorderUI
import SwiftUI

struct StudioApp: App {
    @NSApplicationDelegateAdaptor(StudioDelegate.self) private var delegate
    @StateObject private var studio = Studio.shared

    var body: some Scene {
        // The window comes from Studio. This scene only carries the menus.
        Settings { EmptyView() }
            .commands { StudioCommands(studio: studio) }
    }
}

/// Observes the area itself: menus are rebuilt when an observed object of a `Commands` changes. Keys both apps use
/// (⌘E, ⌘⌫, ⇧⌘R, ⌘Z) act in the area in front; Presets' own keys rest while Aufnahme shows.
struct StudioCommands: Commands {
    @ObservedObject var studio: Studio

    var body: some Commands {
        RecorderMenus(studio.recorder, isActive: studio.area == .recording)
        PresetMenus(studio.presets, isActive: studio.area == .presets)
        CommandGroup(before: .toolbar) {
            ForEach(StudioArea.allCases) { area in
                Button(area.title) { studio.show(area) }
                    .keyboardShortcut(KeyEquivalent(Character("\(area.digit)")), modifiers: [.command, .shift])
            }
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Tastaturkürzel") {
                studio.showWindow()
                studio.showsShortcuts = true
            }
            .keyboardShortcut("/", modifiers: .command)
        }
    }
}

@MainActor
final class StudioDelegate: NSObject, NSApplicationDelegate {
    private var studio: Studio { Studio.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        studio.makeWindow()
        // Bluetooth stays off until the area Presets first shows, unless a test asks for it right away.
        if PresetsHost.isRequestedAtLaunch { studio.area = .presets }
        // First, so that a message of the recorder's start, such as a repaired take, replaces it and is not hidden.
        if let message = StudioLaunch.takeoverMessage { studio.recorder.inform(message) }
        // As in Spark Recorder: recovery of an interrupted take, then the window, then the self-test.
        studio.recorder.applicationDidFinishLaunching(notification)
        MenuDump.startIfRequested(studio)
    }

    /// A click on the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { studio.showWindow() }
        return true
    }

    /// As in Spark Recorder: a running recording continues after the window closed, and the Dock shows REC.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !studio.recorder.isRecording
    }

    func applicationWillTerminate(_ notification: Notification) {
        studio.recorder.applicationWillTerminate(notification)
    }
}
