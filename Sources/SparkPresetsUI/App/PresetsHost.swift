import AppKit
import Combine
import SparkControl
import SwiftUI

/// What the amp plays, ready to be kept with a take: name, slot (1 to 4, nil for the temporary place), the
/// fingerprint of the effect chain and the snapshot as a preset file.
public struct HeardSound {
    public let name: String
    public let slot: Int?
    public let sha256: String
    public let snapshot: Data
}

/// Spark Presets inside another app, Spark Studio: the same model, content and menus as the app, plus what Studio
/// needs to tie takes, tempo and the deck to the presets.
///
/// Bluetooth starts only when the content first shows, from its own start task, and `disconnect` ends the
/// connection again, so the Spark app on the phone can take the amp.
@MainActor
public final class PresetsHost: ObservableObject {
    let model: PresetsModel
    private var changes: AnyCancellable?

    /// `--library <folder>` (the recorder's test library) keeps the presets in its subfolder "Presets", filled with
    /// made-up presets, never in `~/Music/Spark Presets`. Otherwise `folder`, or the app's own folder.
    public init(folder: URL? = nil) {
        let testFolder = Snapshot.arguments["library"].flatMap { $0.isEmpty ? nil : $0 }.map {
            Snapshot.seededTestFolder(URL(fileURLWithPath: $0, isDirectory: true)
                .appendingPathComponent("Presets", isDirectory: true))
        }
        model = PresetsModel(folder: testFolder ?? folder ?? PresetLibrary.defaultFolder)
        changes = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Sidebar and editor: the area "Presets". It starts Bluetooth the first time it shows.
    public var content: AnyView {
        AnyView(PresetsApp.root(model, minimumSize: false).environment(\.managesConnection, true))
    }

    /// True when the launch asks for the presets at once: a picture, an opened preset or the live self-test.
    public static var isRequestedAtLaunch: Bool {
        let arguments = Snapshot.arguments
        return ["snapshot", "open", "size", "live-selftest"].contains { arguments[$0] != nil }
    }

    /// The window that Spark Presets' snapshot sizes and draws.
    public func adopt(_ window: NSWindow) {
        Snapshot.window = window
    }

    /// The preset open in the editor, by the uuid it carries, if any.
    public var openPresetID: String? { model.editor.preset?.uuid }

    // MARK: Connection

    public enum Connection { case connected, busy, off, unavailable }

    public var connection: Connection {
        switch model.link.status {
        case .connected: .connected
        case .starting, .searching, .connecting: model.link.wanted ? .busy : .off
        case .off: .off
        case .unauthorized, .bluetoothOff, .unsupported: .unavailable
        }
    }

    /// The state in words, for help texts and VoiceOver.
    public var connectionText: String {
        switch model.link.status {
        case .connected: model.link.deviceName ?? "verbunden"
        case .starting: model.link.wanted ? "Bluetooth startet" : "getrennt"
        case .searching: "Suche den Verstärker"
        case .connecting: "Verbinde"
        case .off: "getrennt"
        case .unauthorized: "kein Bluetooth-Zugriff"
        case .bluetoothOff: "Bluetooth ist aus"
        case .unsupported: "kein Bluetooth LE"
        }
    }

    public func toggleConnection() {
        if model.link.wanted { model.link.stop() } else { model.start(bluetooth: true) }
    }

    // MARK: Sound and tempo

    /// What the amp plays now, from memory, or nil when not connected or not known.
    public func heardSound() -> HeardSound? {
        guard let heard = model.heardPreset, let sha256 = try? heard.preset.sha256Hex() else { return nil }
        let origin = heard.slot.map { model.origin(slot: $0 - 1) } ?? "Vorübergehend · \(model.link.deviceName ?? "Spark")"
        guard let snapshot = try? PresetFile.snapshotData(for: heard.preset, origin: origin) else { return nil }
        return HeardSound(name: heard.preset.name, slot: heard.slot, sha256: sha256, snapshot: snapshot)
    }

    /// Plays a take's sound on the temporary place 7F. Never touches a slot. `report` gets nil when it plays, or
    /// what went wrong.
    public func play(snapshot: Data, report: @escaping @MainActor (String?) -> Void) {
        guard let file = try? PresetFile.read(snapshot) else {
            report("Die Einstellungen dieses Sounds sind nicht lesbar.")
            return
        }
        model.tryOut(file.preset, report: report)
    }

    /// Opens a take's sound in the editor as a new preset.
    public func open(snapshot: Data) {
        guard let file = try? PresetFile.read(snapshot) else { return }
        model.openCopy(file.preset)
    }

    /// Name and tempo of the preset in the editor.
    public var openPreset: (name: String, bpm: Double)? {
        model.editor.preset.map { ($0.name, Double($0.bpm)) }
    }

    /// Puts a tempo into the preset in the editor. It then counts as changed, until saved.
    public func setTempoOfOpenPreset(_ bpm: Double) {
        model.editor.setBPM(Float(bpm))
    }

    /// Called with name and tempo of every preset opened in the editor.
    public func onPresetOpened(_ handler: @escaping @MainActor (String, Double) -> Void) {
        model.editor.onOpen = { preset in handler(preset.name, Double(preset.bpm)) }
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
