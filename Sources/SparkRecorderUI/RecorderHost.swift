import AppKit
import SwiftUI

/// Spark Recorder inside another app, Spark Studio. It is built from the same parts as the app: the model from the
/// launch options, the key router, and the app delegate, here as an ordinary object that makes and manages the window.
/// Everything behaves as in Spark Recorder, except that single keys act only in this window.
@MainActor
public final class RecorderHost {
    let model: AppModel
    private let keyRouter: KeyRouter
    private let delegate: AppDelegate

    public init(windowTitle: String) {
        AppDelegate.windowTitle = windowTitle
        model = SparkRecorderApp.makeModel()
        keyRouter = KeyRouter(model: model)
        delegate = AppDelegate()
        KeyRouter.ownsWindow = { $0 === AppDelegate.mainWindow }
    }

    /// The window, once it was shown.
    public var window: NSWindow? { AppDelegate.mainWindow }

    public var isRecording: Bool { model.isRecording }

    /// Recovers an interrupted take, opens the window and starts the self-test when asked to, as the app does.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        delegate.applicationDidFinishLaunching(notification)
    }

    public func showWindow() {
        delegate.showMainWindow()
    }

    /// Ends listening and finishes a running recording.
    public func applicationWillTerminate(_ notification: Notification) {
        delegate.applicationWillTerminate(notification)
    }
}

/// Spark Recorder's menus for Spark Studio. While the other window is in front, the keys both apps use are left to it.
public struct RecorderMenus: Commands {
    private let model: AppModel
    private let isActive: Bool

    public init(_ host: RecorderHost, isActive: Bool) {
        model = host.model
        self.isActive = isActive
    }

    public var body: some Commands {
        AppCommands(model: model, isActive: isActive, isStandalone: false)
    }
}
