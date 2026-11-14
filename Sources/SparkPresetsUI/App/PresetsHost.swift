import AmpText
#if os(macOS)
import AppKit
#endif
import Combine
import SoundStore
import SparkControl
import SwiftUI

/// What the device plays, ready to be kept with a take: name, slot (from 1, nil for the temporary place), the
/// fingerprint of the effect chain, the snapshot as a preset file, and the device. A REACTOR, which is only listened
/// to, gives what it reported instead (`listened`), with no fingerprint and no snapshot.
public struct HeardSound {
    public let name: String
    public let slot: Int?
    public let sha256: String
    public let snapshot: Data?
    public let device: String
    /// Label and value, such as ("Amp", "Crunch"), for a sound that was only listened to.
    public let listened: [(label: String, value: String)]?
}

/// Spark Presets inside another app, AmpBench: the same model, content and menus as the app, plus what Studio
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
        // `--made-up-sounds` gives the test library about a hundred invented sounds, for the library's pictures.
        if let testFolder, Snapshot.arguments["made-up-sounds"] != nil { MadeUpLibrary.fill(testFolder) }
        // A test library keeps its devices apart from the real ones; `--demo-devices` shows simulated devices only.
        let link: SparkLink? = testFolder.map { _ in
            let defaults = UserDefaults(suiteName: "local.ampbench.devices.tests") ?? .standard
            let demo = Snapshot.arguments["demo-devices"]
            if demo != nil { defaults.removePersistentDomain(forName: "local.ampbench.devices.tests") }
            return SparkLink(transport: demo.map { _ in SimulatedDevice([.mini, .neo, .reactor]) as LinkTransport },
                             memory: DeviceMemory(defaults: defaults))
        }
        // A test library also keeps its sound store apart: its own settings, key and state, never the real ones.
        model = PresetsModel(folder: testFolder ?? folder ?? PresetLibrary.defaultFolder, link: link,
                             store: testFolder.map { StoreProfile.testing(stateFolder: $0) })
        changes = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // The pieces' sounds name saved presets, so the library is read at once. Bluetooth waits.
        model.reloadLibrary()
        // The store syncs at the start, whichever area shows: sounds made elsewhere are there before one looks.
        model.store.syncIfDue()
    }

    /// Sidebar and editor: the area "Presets". It starts Bluetooth the first time it shows.
    public var content: AnyView {
        AnyView(PresetsContent.root(model))
    }

    /// True when the launch asks for the presets at once: a picture, an opened preset or the live self-test.
    public static var isRequestedAtLaunch: Bool {
        let arguments = Snapshot.arguments
        return ["snapshot", "open", "size", "live-selftest"].contains { arguments[$0] != nil }
    }

    #if os(macOS)
    /// The window that Spark Presets' snapshot sizes and draws.
    public func adopt(_ window: NSWindow) {
        Snapshot.window = window
    }
    #endif

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
        case .connected: model.link.shownName
        case .starting: model.link.wanted ? tr("Bluetooth is starting") : tr("disconnected")
        case .searching: tr("Searching for the amp")
        case .connecting: tr("Connecting")
        case .off: tr("disconnected")
        case .unauthorized: tr("no Bluetooth access")
        case .bluetoothOff: tr("Bluetooth is off")
        case .unsupported: tr("no Bluetooth LE")
        }
    }

    public func toggleConnection() {
        if model.link.wanted { model.disconnect() } else { model.start(bluetooth: true) }
    }

    // MARK: The amp's own tuner

    /// Starts the Bluetooth link as the area Presets does on its first showing, for the tuner shown first. Does
    /// nothing once started, also not after "Disconnect".
    public func startLinkOnce() {
        let model = model
        Task { await PresetsContent.startOnce(model) }
    }

    /// The connected device's name when its own tuner can be switched on from here (Spark MINI, NEO), nil otherwise.
    public var ampTunerDevice: String? { model.link.canUseAmpTuner ? model.link.profile.displayName : nil }

    public var isAmpTunerOn: Bool { model.link.isAmpTunerOn }

    /// The connected device has no USB audio (the NEO): its own tuner is the way to tune with it.
    public var ampTunerPreferred: Bool { model.link.canUseAmpTuner && !model.link.profile.can(.usbAudio) }

    /// The amp's tuner may still be on, so quitting should switch it off first.
    public var ampTunerMayBeOn: Bool { model.link.ampTunerMayBeOn }

    /// Every reading of the amp's tuner: the note from 0 (C) to 11 (H) and the cents, nil without signal.
    public var onAmpTunerReading: ((Int, Double?) -> Void)? {
        get { model.link.onTunerReading }
        set { model.link.onTunerReading = newValue }
    }

    /// Asks for the amp's tuner on or off; the link switches it when connected and keeps to it.
    public func wantAmpTuner(_ on: Bool) {
        model.link.wantAmpTuner(on)
    }

    /// Switches the amp's tuner off before the app ends, so the amp is not left silent. Waits at most 1.5 s.
    public func switchAmpTunerOff() async {
        await model.link.switchTunerOffBeforeQuitting()
    }

    // MARK: Sound and tempo

    /// What the amp plays now, from memory, or nil when not connected or not known.
    public func heardSound() -> HeardSound? {
        let link = model.link
        // The profile's name, never a REACTOR's own Bluetooth name: the stamp is kept in the library.
        let device = link.profile.id == .unknownSpark ? (link.deviceName ?? link.profile.displayName)
            : link.profile.displayName
        if link.status == .connected, !link.profile.canSend {
            let state = link.reactor
            let slot = state.slot
            let name = slot.map { "\(device) \(link.profile.slotName($0))" } ?? device
            return HeardSound(name: name, slot: slot.map { $0 + 1 }, sha256: "", snapshot: nil, device: device,
                              listened: state.lines(profile: link.profile))
        }
        guard let heard = model.heardPreset, let sha256 = try? heard.preset.sha256Hex() else { return nil }
        let origin = heard.slot.map { model.origin(slot: $0 - 1) } ?? tr("Temporary · %@", device)
        guard let snapshot = try? PresetFile.snapshotData(for: heard.preset, origin: origin) else { return nil }
        return HeardSound(name: heard.preset.name, slot: heard.slot, sha256: sha256, snapshot: snapshot,
                          device: device, listened: nil)
    }

    /// Called when the connected device dropped a sound that was not stored, because the connection ended. Gets the
    /// device's name. A take running then keeps the sound it started with.
    public func onTemporaryLost(_ handler: @escaping @MainActor (String) -> Void) {
        model.onTemporaryLost = { name in handler(name) }
    }

    /// Plays a take's sound on the temporary place 7F. Never touches a slot. `report` gets nil when it plays, or
    /// what went wrong.
    public func play(snapshot: Data, report: @escaping @MainActor (String?) -> Void) {
        guard let file = try? PresetFile.read(snapshot) else {
            report(tr("This sound’s settings cannot be read."))
            return
        }
        model.tryOut(file.preset, report: report)
    }

    /// Opens a take's sound in the editor as a new preset.
    public func open(snapshot: Data) {
        guard let file = try? PresetFile.read(snapshot) else { return }
        model.openCopy(file.preset)
    }

    /// A saved preset to choose as a sound: its stable id, its file name in the presets folder and its name.
    public struct Choice: Sendable {
        public let id: String?
        public let fileName: String
        public let name: String
    }

    /// The saved presets, backups left out, by name.
    public var choices: [Choice] {
        model.items.filter { !$0.file.isBackup }.map {
            Choice(id: $0.file.id, fileName: $0.url.lastPathComponent, name: $0.name)
        }
    }

    /// Plays a saved preset on the temporary place 7F, found by its id, or by its file name for older files.
    public func play(presetID: String?, fileName: String?, report: @escaping @MainActor (String?) -> Void) {
        let item = model.items.first { $0.file.id != nil && $0.file.id == presetID }
            ?? model.items.first { $0.url.lastPathComponent == fileName }
        guard let item else {
            report(tr("This preset is no longer on this Mac. Choose another sound."))
            return
        }
        model.tryOut(item.file.preset, report: report)
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
    /// Gets the songs of an import (a Kemper backup's performances) and says what became of them, for the message.
    public func onImportSongs(_ handler: @escaping @MainActor ([ImportedSong]) -> String?) {
        model.onImportSongs = handler
    }

    /// Tells the library which pieces use a saved preset, by its id and file name, so it can say so before the
    /// preset goes to the Trash.
    public func onPresetUses(_ handler: @escaping @MainActor (String?, String) -> [String]) {
        model.presetUses = handler
    }

    public func onPresetOpened(_ handler: @escaping @MainActor (String, Double) -> Void) {
        model.editor.onOpen = { preset in handler(preset.name, Double(preset.bpm)) }
    }
}

/// Spark Presets' menus for AmpBench, with "Connect" and "Disconnect" in the amp menu. While the other window is
/// in front, Presets' own keys rest and the keys both apps use are left to it.
public struct PresetMenus: Commands {
    private let model: PresetsModel
    private let isActive: Bool

    public init(_ host: PresetsHost, isActive: Bool) {
        model = host.model
        self.isActive = isActive
    }

    public var body: some Commands {
        PresetCommands(model: model, isActive: isActive)
    }
}
