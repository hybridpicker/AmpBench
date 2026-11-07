import AppKit
import SparkCore

/// What happens before the window: the folder `~/Music/Spark Studio` made ready, the former apps' folders and settings
/// taken over at the first start. A test library (`--library`) skips all of it and touches nothing in ~/Music.
@MainActor
enum StudioLaunch {
    /// The folders in use, or nil for a test library.
    private(set) static var folders: StudioFolders?
    /// What the first start took over, for a message in the window.
    private(set) static var outcome: StudioFolders.Outcome?

    static var isTestLibrary: Bool { CommandLine.arguments.contains("--library") }

    /// Returns false when Studio cannot start now; it has then said why.
    static func prepare() -> Bool {
        guard !isTestLibrary else { return true }
        let folders = StudioFolders.standard
        do {
            let outcome = try folders.prepare(formerRecordings: StudioFolders.formerRecordings,
                                              formerPresets: StudioFolders.formerPresets)
            if outcome == .blocked {
                stop("Spark Recorder läuft noch.",
                     "Beim ersten Start übernimmt Spark Studio deine Aufnahmen aus „Spark Recorder“. Beende Spark Recorder, dann starte Spark Studio noch einmal. Es wurde nichts verändert.")
                return false
            }
            self.folders = folders
            self.outcome = outcome
        } catch {
            stop("Spark Studio konnte seinen Ordner nicht einrichten.",
                 "\(error.localizedDescription)\n\nDeine Ordner „Spark Recorder“ und „Spark Presets“ sind unverändert.")
            return false
        }
        // Input, click, measurements and the like from the former apps, where Studio has no own setting yet.
        SettingsTakeover.copy(from: ["local.sparkrecorder", "local.sparkpresets"], into: .standard,
                              markerKey: "tookOverFormerSettings")
        return true
    }

    /// The message for the window after taking over, or nil.
    static var takeoverMessage: String? {
        guard case .tookOver(let recordings, let presets) = outcome else { return nil }
        let what = [recordings ? "Aufnahmen" : nil, presets ? "Presets" : nil].compactMap { $0 }.joined(separator: " und ")
        return "Spark Studio hat deine \(what) nach „Musik/Spark Studio“ übernommen. Die alten Ordner bleiben unverändert."
    }

    private static func stop(_ message: String, _ detail: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Beenden")
        alert.runModal()
    }
}
