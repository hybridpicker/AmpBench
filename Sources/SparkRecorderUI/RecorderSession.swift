import AmpText
import AppKit
import SparkCore
import SparkDesign
import SwiftUI

/// Launch options. `--library` points the whole app at another folder, with its own settings, for testing.
struct LaunchOptions {
    var folder: URL = LibraryStore.defaultFolder
    var isTestLibrary = false
    /// A real library only ever records from a Spark. A test library only ever hears virtual test devices.
    var inputPolicy = InputPolicy.sparkOnly

    static let current: LaunchOptions = {
        var options = LaunchOptions()
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
            options.folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            options.isTestLibrary = true
            options.inputPolicy = .testDevices
            if let flag = arguments.firstIndex(of: "--test-input"), flag + 1 < arguments.count {
                switch arguments[flag + 1] {
                case "none": options.inputPolicy = .nothing
                case "aggregate": options.inputPolicy = .testAggregateOnly
                default: break
                }
            }
        }
        return options
    }()
}

/// The recorder's part of an app's life: the model, the window that shows the deck, starting and ending. AmpBench
/// makes the window and hands it over with `adopt`; the self-test, the key router and "the window closed while
/// recording" refer to it.
@MainActor
final class RecorderSession: NSObject, NSWindowDelegate {
    static var model: AppModel?
    private(set) static var mainWindow: NSWindow?

    /// The model for the launch options. `folder` replaces the default library folder; a test library given with
    /// `--library` still wins.
    static func makeModel(folder: URL? = nil, inputNames: [String]? = nil) -> AppModel {
        var options = LaunchOptions.current
        // A real library records from the devices AmpBench knows; a test library keeps its test devices.
        if !options.isTestLibrary, let inputNames { options.inputPolicy = .usbDevices(named: inputNames) }
        let defaults = options.isTestLibrary
            ? (UserDefaults(suiteName: "local.sparkrecorder.tests") ?? .standard)
            : .standard
        let library = options.isTestLibrary ? options.folder : folder ?? options.folder
        let model = AppModel(folder: library, defaults: defaults, inputPolicy: options.inputPolicy)
        Self.model = model
        return model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // For looking at the dark design in tests, without touching the system setting.
        if LaunchOptions.current.isTestLibrary, CommandLine.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        guard let model = Self.model else { return }
        // Recovery of an interrupted take comes first and does not depend on a view appearing.
        model.start()
        showMainWindow()
        KeyRouter.releaseInitialFocus()
        UISelfTest.startIfRequested(model: model)
    }

    func showMainWindow() {
        Self.mainWindow?.makeKeyAndOrderFront(nil)
    }

    func adopt(_ window: NSWindow) {
        Self.mainWindow = window
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === Self.mainWindow else { return }
        // A running recording continues, and the Dock icon shows REC. Otherwise closing the window ends the app,
        // and with it any listening.
        Self.model?.windowClosed()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.shutdown()
    }
}

/// Everything below the deck: waveform, transport, library. AmpBench shows it as its area "Record".
struct RecorderWorkspace: View {
    var body: some View {
        VStack(spacing: 0) {
            WavePanel()
            Divider()
            LibraryArea()
        }
    }
}

extension View {
    /// The recorder's sheets and questions. AmpBench attaches them to its whole window, so they also appear when
    /// a menu asks for them while the other area shows.
    func recorderPresentations() -> some View { modifier(RecorderPresentations()) }
}

private struct RecorderPresentations: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: $model.showLoopbackInfo) { LoopbackSheet() }
        .sheet(isPresented: $model.showLatencyInfo) { LatencySheet() }
        .alert(tr("Rename this take"), isPresented: Binding(
            get: { model.renameTarget != nil },
            set: { if !$0 { model.renameTarget = nil } }
        )) {
            TextField(tr("Name"), text: $model.renameText)
            Button(tr("Rename"), action: model.commitRename)
            Button(tr("Cancel"), role: .cancel) {}
        } message: {
            Text(tr("The file in the folder gets the same name."))
        }
        .alert(tr("New piece"), isPresented: Binding(
            get: { model.newPieceTargets != nil },
            set: { if !$0 { model.newPieceTargets = nil } }
        )) {
            TextField(tr("Title"), text: $model.newPieceName)
            Button(tr("Create"), action: model.commitNewPiece)
            Button(tr("Cancel"), role: .cancel) {}
        } message: {
            Text(newPieceMessage)
        }
    }

    private var newPieceMessage: String {
        let count = model.newPieceTargets?.count ?? 0
        switch count {
        case 0: return tr("New takes then go into this piece.")
        case 1: return tr("The selected take goes into this piece.")
        default: return tr("The %d selected takes go into this piece.", count)
        }
    }
}

// MARK: - Menus

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    /// False while AmpBench shows another area: the keys both areas use then belong to it.
    var isActive = true

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {}
        // After the pasteboard group: AmpBench replaces the undo group for Presets, which drops groups placed
        // after it.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(tr("Move to Trash"), action: discardOrEditText)
                .keyboardShortcut(owned(KeyboardShortcut(.delete, modifiers: .command)))
                .disabled(model.isRecording || !isActive)
            Button(tr("Restore last discarded"), action: model.restoreLastTrashed)
                .disabled(!model.canRestoreLastTrashed)
        }
        CommandMenu(tr("Record")) {
            Button(recordTitle + "  (R)", action: model.toggleRecord)
                .disabled(!model.libraryIsUsable)
            Button(tr("Add marker  (M)"), action: model.addMarker)
            Button(tr("Record selected bars again"), action: model.recordSelectedBars)
                .disabled(!model.canRecordBars)
            Button(tr("Keep  (K)")) { model.keep() }
                .disabled(model.current?.status != .open)
            Divider()
            Button(model.isMonitoring ? tr("Stop checking input") : tr("Check input"), action: model.toggleMonitor)
                .disabled(model.isRecording || model.isRetroOn)
            Button(model.isRetroOn ? tr("Turn off Retro recording") : tr("Turn on Retro recording"), action: model.toggleRetro)
                .disabled(model.isRecording)
            Menu(tr("That was good")) {
                Button(tr("Whole buffer  (G)")) { model.saveRetro() }
                Button(tr("Last 30 seconds")) { model.saveRetro(seconds: 30) }
                Button(tr("Last minute")) { model.saveRetro(seconds: 60) }
                Button(tr("Last 2 minutes")) { model.saveRetro(seconds: 120) }
            }
            .disabled(!model.isRetroOn)
            Divider()
            Toggle(tr("Raise the level of new takes automatically"), isOn: Binding(
                get: { model.autoLevelDefault },
                set: {
                    model.autoLevelDefault = $0
                    model.defaults.set($0, forKey: "autoLevel")
                }
            ))
            Picker(tr("Current piece"), selection: Binding(get: { model.currentPieceID }, set: { model.setCurrentPiece($0) })) {
                Text(tr("None")).tag(UUID?.none)
                ForEach(model.pieces) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Divider()
            Button(tr("Measure feedback …")) { model.showLoopbackInfo = true }
                .disabled(!model.canMeasureLoopback)
            Button(tr("Forget measurements"), action: model.forgetLoopbackMeasurements)
            Button(tr("Measure click latency …")) { model.showLatencyInfo = true }
                .disabled(!model.canMeasureLatency)
        }
        CommandMenu(tr("Playback")) {
            Button(tr("Play or pause  (Space)"), action: model.togglePlay)
            Button(tr("Loop A, B, off  (L)"), action: model.toggleLoop)
                .disabled(model.current == nil)
            Button(tr("Loop selected bars"), action: model.toggleBarLoop)
                .disabled(model.barSelection == nil)
            Divider()
            Button(tr("Back 5 seconds  (←)")) { model.nudge(by: -5) }
            Button(tr("Forward 5 seconds  (→)")) { model.nudge(by: 5) }
            Divider()
            Button(tr("Slower  (-)")) { model.setTempo(model.tempo - 0.05) }
            Button(tr("Faster  (+)")) { model.setTempo(model.tempo + 0.05) }
            Button(tr("Reset tempo and pitch  (0)"), action: model.resetTempoAndPitch)
            Divider()
            Button(tr("Click on or off  (N)"), action: model.toggleClick)
            Button(tr("Tap tempo  (T)"), action: model.tap)
            Divider()
            Button(tr("Compare two takes"), action: model.startCompare)
                .disabled(!model.canCompare)
            Button(tr("Switch to the other take  (B)"), action: model.switchCompare)
                .disabled(model.compareIDs.isEmpty)
        }
        CommandMenu(tr("Library")) {
            Button(tr("Search")) { model.tab = .recordings }
            Button(tr("Rename …")) { model.beginRename() }
                .keyboardShortcut(owned(KeyboardShortcut("e", modifiers: .command)))
                .disabled(model.current == nil || !isActive)
            Button(tr("Show in Finder")) { model.reveal() }
                .keyboardShortcut(owned(KeyboardShortcut("r", modifiers: [.command, .shift])))
                .disabled(model.current == nil || !isActive)
            Divider()
            Menu(tr("Export as")) {
                Button(tr("WAV, 24-bit …")) { model.export(.wav24) }
                Button(tr("AAC, 192 kbit/s …")) { model.export(.aac(bitRate: 192_000)) }
                Button(tr("AAC, 256 kbit/s …")) { model.export(.aac(bitRate: 256_000)) }
            }
            .disabled(model.current == nil || model.isRecording)
            Divider()
            Button(tr("Favorite  (F)")) { model.toggleFavorite() }
                .disabled(model.current == nil)
            Menu(tr("Rating  (1 to 5)")) {
                ForEach(1...5, id: \.self) { rating in
                    Button(String(repeating: "★", count: rating)) { model.setRating(rating) }
                }
            }
            .disabled(model.current == nil)
            Divider()
            Button(tr("New piece …")) { model.beginNewPiece() }
            Button(tr("Check folder")) { model.scanFolder() }
                .disabled(model.isRecording)
            Button(tr("Show library folder in Finder"), action: model.revealLibraryFolder)
        }
    }

    /// A shortcut both apps use belongs to this menu only while its window is in front.
    private func owned(_ shortcut: KeyboardShortcut) -> KeyboardShortcut? {
        isActive ? shortcut : nil
    }

    private var recordTitle: String {
        switch model.phase {
        case .idle, .preparing: return tr("Start recording")
        case .countIn: return tr("Cancel count-in")
        case .recording: return tr("Stop recording")
        }
    }

    /// ⌘⌫ deletes to the line start while typing. It must never trash a recording from inside a text field.
    private func discardOrEditText() {
        if KeyRouter.isEditingText {
            _ = KeyRouter.activeWindow?.firstResponder?.tryToPerform(
                #selector(NSStandardKeyBindingResponding.deleteToBeginningOfLine(_:)), with: nil)
        } else {
            model.discard()
        }
    }
}

// MARK: - Sheets

private struct LatencySheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SheetPanel(tr("Measure click latency")) {
            Text(tr("So that the bars are right to the millisecond, the app measures how long a click takes from “%@” into the recording from “%@”. The amp delays the guitar internally, and the devices do not report that.",
                    model.clickOutput?.name ?? "–", model.selectedInput?.name ?? "–"))
                .fixedSize(horizontal: false, vertical: true)
            Text(tr("For this, run a cable from the headphone output to the amp's guitar input, with a 3.5 mm plug at the Mac and a 6.3 mm plug at the amp. Without a cable, headphones held directly on the pickup work too, with the strings muted. Choose a preset without delay, reverb and noise gate and set the output to medium volume. The measurement takes about ten seconds; nothing is saved."))
                .fixedSize(horizontal: false, vertical: true)
            Text(tr("The result applies to exactly these two devices and to takes recorded afterwards."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Cancel"), role: .cancel) { model.showLatencyInfo = false }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Measure")) {
                    model.showLatencyInfo = false
                    model.measureLatency()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 460)
    }
}

private struct LoopbackSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SheetPanel(tr("Measure feedback")) {
            Text(tr("The app plays quiet clicks through “%@” for about three seconds and measures whether they arrive at the input “%@”. Nothing is saved.",
                    model.effectiveOutput?.name ?? "–", model.selectedInput?.name ?? "–"))
                .fixedSize(horizontal: false, vertical: true)
            Text(tr("Turn the guitar down or unplug it first. The result applies only to these two devices."))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Cancel"), role: .cancel) { model.showLoopbackInfo = false }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Measure")) {
                    model.showLoopbackInfo = false
                    model.measureLoopback()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 440)
    }
}
