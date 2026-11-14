import AppKit
import SparkCore
import SwiftUI

/// What the amp plays when a take starts: the stamp kept with the take and the preset file written next to it.
public struct TakeSound {
    public let stamp: PresetStamp
    /// The preset file, nil for a sound that was only listened to.
    public let snapshot: Data?

    public init(stamp: PresetStamp, snapshot: Data?) {
        self.stamp = stamp
        self.snapshot = snapshot
    }
}

/// What the inspector can do with a take's sound in AmpBench. Each closure gets the take's snapshot and reports
/// itself what went wrong, such as an amp that is not connected.
public struct SoundActions {
    /// Plays the sound on the amp's temporary place 7F, never in a slot.
    public var sendToAmp: @MainActor (Data) -> Void
    /// Opens the sound in the preset editor as a new, unsaved preset.
    public var openInEditor: @MainActor (Data) -> Void

    public init(sendToAmp: @escaping @MainActor (Data) -> Void, openInEditor: @escaping @MainActor (Data) -> Void) {
        self.sendToAmp = sendToAmp
        self.openInEditor = openInEditor
    }
}

/// A key in a banner.
struct BannerAction {
    let title: String
    let run: @MainActor () -> Void
}

/// Spark Recorder inside another app, AmpBench. It is built from the same parts as the app: the model from the
/// launch options, the key router, and the app delegate as an ordinary object. Studio puts the deck and the workspace
/// into its own window and hands that window over with `adopt`.
@MainActor
public final class RecorderHost {
    let model: AppModel
    private let keyRouter: KeyRouter
    private let session: RecorderSession

    /// `folder` is the recordings library; a test library given with `--library` still wins.
    /// `inputNames`: parts of the USB audio names that may be recorded from; without them only Spark devices.
    public init(folder: URL? = nil, inputNames: [String]? = nil) {
        model = RecorderSession.makeModel(folder: folder, inputNames: inputNames)
        keyRouter = KeyRouter(model: model)
        session = RecorderSession()
    }

    /// The deck: recording, level, Spark, click. Set `\.deckBluetooth` on it to show the amp's connection.
    public var deck: AnyView { AnyView(DeckView().recorderEnvironment(model)) }

    /// Waveform, transport and library: the area "Record".
    public var workspace: AnyView { AnyView(RecorderWorkspace().recorderEnvironment(model)) }

    /// The recorder's message, for showing it while the other area is in front.
    public var banner: AnyView { AnyView(RecorderBannerSlot().recorderEnvironment(model)) }

    /// Puts the recorder's sheets and questions on a view that is always there.
    public func presentations(on content: AnyView) -> AnyView {
        AnyView(content.recorderPresentations().recorderEnvironment(model))
    }

    /// The window that shows the deck. The self-test, the key router and "closed while recording" use it.
    public func adopt(_ window: NSWindow) {
        session.adopt(window)
    }

    public var window: NSWindow? { RecorderSession.mainWindow }
    public var isRecording: Bool { model.isRecording }
    public var libraryFolder: URL { model.store.folder }
    public var hasBanner: Bool { model.banner != nil }

    /// Recovers an interrupted take, shows the window and starts the self-test when asked to, as the app does.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        session.applicationDidFinishLaunching(notification)
    }

    public func showWindow() { session.showMainWindow() }

    /// Ends listening and finishes a running recording.
    public func applicationWillTerminate(_ notification: Notification) {
        session.applicationWillTerminate(notification)
    }

    /// Given a key as typed ("r", " ", "left", "escape" …), true when single keys may act on it now.
    public func routeKeys(when allows: @escaping @MainActor (String) -> Bool) {
        KeyRouter.allowsKey = allows
    }

    // MARK: Sound and tempo, for AmpBench

    /// Asked at the start of every take for what the amp plays.
    public func provideSound(_ provider: @escaping @MainActor () -> TakeSound?) {
        model.soundProvider = provider
    }

    public func handleSounds(_ actions: SoundActions) {
        model.soundActions = actions
    }

    /// The saved presets to choose a piece's or part's sound from, and how to play one on the amp.
    public func offerPresets(_ choices: @escaping @MainActor () -> [PresetLink],
                             play: @escaping @MainActor (PresetLink) -> Void) {
        model.presetChoices = choices
        model.playPreset = play
    }

    /// Called after the metronome's tempo was changed by hand.
    public func onTempoChanged(_ handler: @escaping @MainActor (Double) -> Void) {
        model.onTempoChanged = handler
    }

    public var tempo: Double { model.metronome.bpm }

    /// What "⌘/ Keyboard shortcuts" in the library's status line does.
    public func onShowShortcuts(_ handler: @escaping @MainActor () -> Void) {
        model.showShortcuts = handler
    }

    /// Sets the metronome from a preset, unless a recording is running (its bars rest on the tempo).
    public func setTempoFromPreset(_ bpm: Double) {
        model.setTempoFromPreset(bpm)
    }

    /// A message with one key, such as "Apply".
    public func ask(_ text: String, action title: String, run: @escaping @MainActor () -> Void) {
        model.show(.info, text, action: BannerAction(title: title, run: run))
    }

    /// Further pictures for the `pictures` self-test, such as another area: each step shows something, then the
    /// window is drawn in dark and light and at its smallest size; `done` puts things back.
    public func addPictures(steps: [(name: String, show: @MainActor () -> Void)], done: @escaping @MainActor () -> Void) {
        UISelfTest.extraPictures = (steps, done)
    }

    // MARK: The input, for the tuner

    /// The recorder's input, for reading along with it. The tuner uses it instead of opening a second audio unit.
    public lazy var sharedInput: SharedInput = RecorderInput(model: model)

    /// A song from an import, such as a Kemper performance: its title, notes and parts, each with its sound.
    public struct NewPiece: Sendable {
        public var title: String
        public var notes: String
        public var parts: [(name: String, preset: PresetLink)]

        public init(title: String, notes: String, parts: [(name: String, preset: PresetLink)]) {
            self.title = title
            self.notes = notes
            self.parts = parts
        }
    }

    /// Adds songs from an import. A title that is already a piece is left alone, so nothing the player wrote is
    /// overwritten; those titles come back.
    @discardableResult
    public func addPieces(_ pieces: [NewPiece]) -> (added: Int, kept: [String]) {
        model.addImportedPieces(pieces)
    }

    /// The pieces that name a saved preset, for the piece itself or one of its parts, as "Piece" or "Piece · Part".
    /// A preset is known by its id, or by its file name in the presets folder when the link has no id.
    public func pieces(usingPresetID id: String?, fileName: String) -> [String] {
        func names(_ link: PresetLink?) -> Bool {
            guard let link else { return false }
            if let linked = link.presetID, let id { return linked == id }
            return link.fileName == fileName
        }
        return model.pieces.flatMap { piece -> [String] in
            (names(piece.preset) ? [piece.name] : []) + piece.parts.filter { names($0.preset) }.map { "\(piece.name) · \($0.name)" }
        }
    }

    public func inform(_ text: String) { model.show(.info, text) }
    public func warn(_ text: String) { model.show(.warning, text) }
}

/// The recorder's input as the tuner sees it.
@MainActor
private final class RecorderInput: SharedInput {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var device: InputDevice? { model.selectedInput }
    var isHeldOpen: Bool { model.holdsInputForRecording }
    var allowsOtherInputs: Bool { !LaunchOptions.current.isTestLibrary }
    func share(with tap: AudioTap) async throws { try await model.startTuning(with: tap) }
    func stopSharing(with tap: AudioTap) { model.stopTuning(with: tap) }
    func isSharing(with tap: AudioTap) -> Bool { model.isTuning(with: tap) }
    func owns(_ device: InputDevice) -> Bool { LaunchOptions.current.inputPolicy.allows(device) || device.name.localizedCaseInsensitiveContains("spark") }
}

extension View {
    func recorderEnvironment(_ model: AppModel) -> some View {
        environmentObject(model)
            .environmentObject(model.meter)
            .environmentObject(model.playhead)
            .environmentObject(model.live)
    }
}

/// The recorder's banner on its own, for the other area.
private struct RecorderBannerSlot: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let banner = model.banner { BannerView(banner: banner) }
    }
}

/// Spark Recorder's menus for AmpBench. While the other window is in front, the keys both apps use are left to it.
public struct RecorderMenus: Commands {
    private let model: AppModel
    private let isActive: Bool

    public init(_ host: RecorderHost, isActive: Bool) {
        model = host.model
        self.isActive = isActive
    }

    public var body: some Commands {
        AppCommands(model: model, isActive: isActive)
    }
}
