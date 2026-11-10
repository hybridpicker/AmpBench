import AmpText
import AppKit
import SparkCore

/// What happens before the window: the folder `~/Music/AmpBench` made ready, the former apps' folders and settings
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
                stop(tr("An earlier version of the app is still running."),
                     tr("At its first start AmpBench takes over your recordings from Spark Studio or Spark Recorder. Quit that app, then start AmpBench again. Nothing was changed."))
                return false
            }
            self.folders = folders
            self.outcome = outcome
        } catch {
            stop(tr("AmpBench could not set up its folder."),
                 error.localizedDescription + "\n\n" + tr("Your folders “Spark Recorder” and “Spark Presets” are unchanged."))
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
        switch (recordings, presets) {
        case (true, true):
            return tr("AmpBench copied your recordings and presets to “Music/AmpBench”. The old folders are unchanged.")
        case (true, false):
            return tr("AmpBench copied your recordings to “Music/AmpBench”. The old folders are unchanged.")
        case (false, true):
            return tr("AmpBench copied your presets to “Music/AmpBench”. The old folders are unchanged.")
        case (false, false):
            return nil
        }
    }

    private static func stop(_ message: String, _ detail: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: tr("Quit"))
        alert.runModal()
    }
}

/// The settings of "Spark Studio", the app's name until 2026-11: the bundle identifier changed with the name, so the
/// app would start with empty settings. Carried over once; the old settings stay where they are.
enum SettingsMigration {
    static let formerDomain = "local.sparkstudio"
    static let markerKey = "MigratedFromSparkStudio"

    /// Before anything reads the settings. Not for a test library, which must not touch the user's settings.
    static func runAtLaunch() {
        guard !CommandLine.arguments.contains("--library") else { return }
        carryOver(from: UserDefaults.standard.persistentDomain(forName: formerDomain), into: .standard)
    }

    /// Copies the keys `target` does not have yet and sets the marker, so that it happens once. Without former
    /// settings nothing is marked: they may still appear, say from a backup. The system's own keys ("NS…",
    /// "Apple…") stay behind. Returns the number of keys copied. Never changes the former settings.
    @discardableResult
    static func carryOver(from former: [String: Any]?, into target: UserDefaults) -> Int {
        guard !target.bool(forKey: markerKey), let former else { return 0 }
        var copied = 0
        for (key, value) in former
        where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && target.object(forKey: key) == nil {
            target.set(value, forKey: key)
            copied += 1
        }
        target.set(true, forKey: markerKey)
        return copied
    }
}
