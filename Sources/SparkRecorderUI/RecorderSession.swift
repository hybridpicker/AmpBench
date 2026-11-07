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

/// The recorder's part of an app's life: the model, the window that shows the deck, starting and ending. Spark Studio
/// makes the window and hands it over with `adopt`; the self-test, the key router and "the window closed while
/// recording" refer to it.
@MainActor
final class RecorderSession: NSObject, NSWindowDelegate {
    static var model: AppModel?
    private(set) static var mainWindow: NSWindow?

    /// The model for the launch options. `folder` replaces the default library folder; a test library given with
    /// `--library` still wins.
    static func makeModel(folder: URL? = nil) -> AppModel {
        let options = LaunchOptions.current
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

/// Everything below the deck: waveform, transport, library. Spark Studio shows it as its area "Aufnahme".
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
    /// The recorder's sheets and questions. Spark Studio attaches them to its whole window, so they also appear when
    /// a menu asks for them while the other area shows.
    func recorderPresentations() -> some View { modifier(RecorderPresentations()) }
}

private struct RecorderPresentations: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: $model.showLoopbackInfo) { LoopbackSheet() }
        .sheet(isPresented: $model.showLatencyInfo) { LatencySheet() }
        .alert("Aufnahme umbenennen", isPresented: Binding(
            get: { model.renameTarget != nil },
            set: { if !$0 { model.renameTarget = nil } }
        )) {
            TextField("Name", text: $model.renameText)
            Button("Umbenennen", action: model.commitRename)
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Datei im Ordner bekommt denselben Namen.")
        }
        .alert("Neues Stück", isPresented: Binding(
            get: { model.newPieceTargets != nil },
            set: { if !$0 { model.newPieceTargets = nil } }
        )) {
            TextField("Titel", text: $model.newPieceName)
            Button("Anlegen", action: model.commitNewPiece)
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(newPieceMessage)
        }
    }

    private var newPieceMessage: String {
        let count = model.newPieceTargets?.count ?? 0
        switch count {
        case 0: return "Neue Aufnahmen landen dann in diesem Stück."
        case 1: return "Die markierte Aufnahme kommt in dieses Stück."
        default: return "Die \(count) markierten Aufnahmen kommen in dieses Stück."
        }
    }
}

// MARK: - Menus

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    /// False while Spark Studio shows another area: the keys both areas use then belong to it.
    var isActive = true

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {}
        // After the pasteboard group: Spark Studio replaces the undo group for Presets, which drops groups placed
        // after it.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("In den Papierkorb legen", action: discardOrEditText)
                .keyboardShortcut(owned(KeyboardShortcut(.delete, modifiers: .command)))
                .disabled(model.isRecording || !isActive)
            Button("Zuletzt Verworfenes wiederherstellen", action: model.restoreLastTrashed)
                .disabled(!model.canRestoreLastTrashed)
        }
        CommandMenu("Aufnahme") {
            Button(recordTitle + "  (R)", action: model.toggleRecord)
                .disabled(!model.libraryIsUsable)
            Button("Marker setzen  (M)", action: model.addMarker)
            Button("Gewählte Takte neu aufnehmen", action: model.recordSelectedBars)
                .disabled(!model.canRecordBars)
            Button("Behalten  (K)") { model.keep() }
                .disabled(model.current?.status != .open)
            Divider()
            Button(model.isMonitoring ? "Eingang prüfen beenden" : "Eingang prüfen", action: model.toggleMonitor)
                .disabled(model.isRecording || model.isRetroOn)
            Button(model.isRetroOn ? "Retro-Aufnahme ausschalten" : "Retro-Aufnahme einschalten", action: model.toggleRetro)
                .disabled(model.isRecording)
            Menu("Das eben war gut") {
                Button("Ganzer Puffer  (G)") { model.saveRetro() }
                Button("Letzte 30 Sekunden") { model.saveRetro(seconds: 30) }
                Button("Letzte Minute") { model.saveRetro(seconds: 60) }
                Button("Letzte 2 Minuten") { model.saveRetro(seconds: 120) }
            }
            .disabled(!model.isRetroOn)
            Divider()
            Toggle("Pegel neuer Aufnahmen automatisch anheben", isOn: Binding(
                get: { model.autoLevelDefault },
                set: {
                    model.autoLevelDefault = $0
                    model.defaults.set($0, forKey: "autoLevel")
                }
            ))
            Picker("Aktuelles Stück", selection: Binding(get: { model.currentPieceID }, set: { model.setCurrentPiece($0) })) {
                Text("Kein Stück").tag(UUID?.none)
                ForEach(model.pieces) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Divider()
            Button("Rückkopplung messen …") { model.showLoopbackInfo = true }
                .disabled(!model.canMeasureLoopback)
            Button("Messungen vergessen", action: model.forgetLoopbackMeasurements)
            Button("Klick-Latenz messen …") { model.showLatencyInfo = true }
                .disabled(!model.canMeasureLatency)
        }
        CommandMenu("Wiedergabe") {
            Button("Abspielen oder anhalten  (Leertaste)", action: model.togglePlay)
            Button("Schleife A, B, aus  (L)", action: model.toggleLoop)
                .disabled(model.current == nil)
            Button("Gewählte Takte loopen", action: model.toggleBarLoop)
                .disabled(model.barSelection == nil)
            Divider()
            Button("5 Sekunden zurück  (←)") { model.nudge(by: -5) }
            Button("5 Sekunden vor  (→)") { model.nudge(by: 5) }
            Divider()
            Button("Langsamer  (-)") { model.setTempo(model.tempo - 0.05) }
            Button("Schneller  (+)") { model.setTempo(model.tempo + 0.05) }
            Button("Tempo und Tonhöhe zurücksetzen  (0)", action: model.resetTempoAndPitch)
            Divider()
            Button("Klick an oder aus  (N)", action: model.toggleClick)
            Button("Tap-Tempo  (T)", action: model.tap)
            Divider()
            Button("Zwei Takes vergleichen", action: model.startCompare)
                .disabled(!model.canCompare)
            Button("Zum anderen Take wechseln  (B)", action: model.switchCompare)
                .disabled(model.compareIDs.isEmpty)
        }
        CommandMenu("Bibliothek") {
            Button("Suchen") { model.tab = .recordings }
            Button("Umbenennen …") { model.beginRename() }
                .keyboardShortcut(owned(KeyboardShortcut("e", modifiers: .command)))
                .disabled(model.current == nil || !isActive)
            Button("Im Finder zeigen") { model.reveal() }
                .keyboardShortcut(owned(KeyboardShortcut("r", modifiers: [.command, .shift])))
                .disabled(model.current == nil || !isActive)
            Divider()
            Menu("Exportieren") {
                Button("WAV, 24 Bit …") { model.export(.wav24) }
                Button("AAC, 192 kbit/s …") { model.export(.aac(bitRate: 192_000)) }
                Button("AAC, 256 kbit/s …") { model.export(.aac(bitRate: 256_000)) }
            }
            .disabled(model.current == nil || model.isRecording)
            Divider()
            Button("Favorit  (F)") { model.toggleFavorite() }
                .disabled(model.current == nil)
            Menu("Bewertung  (1 bis 5)") {
                ForEach(1...5, id: \.self) { rating in
                    Button(String(repeating: "★", count: rating)) { model.setRating(rating) }
                }
            }
            .disabled(model.current == nil)
            Divider()
            Button("Neues Stück …") { model.beginNewPiece() }
            Button("Ordner prüfen") { model.scanFolder() }
                .disabled(model.isRecording)
            Button("Bibliotheksordner im Finder zeigen", action: model.revealLibraryFolder)
        }
    }

    /// A shortcut both apps use belongs to this menu only while its window is in front.
    private func owned(_ shortcut: KeyboardShortcut) -> KeyboardShortcut? {
        isActive ? shortcut : nil
    }

    private var recordTitle: String {
        switch model.phase {
        case .idle, .preparing: return "Aufnahme starten"
        case .countIn: return "Einzähler abbrechen"
        case .recording: return "Aufnahme stoppen"
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
        SheetPanel("Klick-Latenz messen") {
            Text("Damit die Takte auf die Millisekunde stimmen, misst die App, wie lange ein Klick von „\(model.clickOutput?.name ?? "–")“ bis in die Aufnahme von „\(model.selectedInput?.name ?? "–")“ braucht. Der Amp verzögert die Gitarre intern, und das melden die Geräte nicht.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Steck dafür ein Kabel vom Kopfhörerausgang in den Gitarreneingang des Amps, mit 3,5-mm-Klinke am Mac und 6,3-mm-Klinke am Amp. Ohne Kabel geht auch ein Kopfhörer direkt auf dem Tonabnehmer, bei abgedämpften Saiten. Wähle ein Preset ohne Delay, Hall und Noise Gate und dreh den Ausgang auf mittlere Lautstärke. Die Messung dauert rund zehn Sekunden, es wird nichts gespeichert.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Das Ergebnis gilt für genau diese beiden Geräte und für Aufnahmen, die danach entstehen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { model.showLatencyInfo = false }
                    .keyboardShortcut(.cancelAction)
                Button("Messen") {
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
        SheetPanel("Rückkopplung messen") {
            Text("Die App spielt rund drei Sekunden lang leise Klicks über „\(model.effectiveOutput?.name ?? "–")“ und misst, ob sie am Eingang „\(model.selectedInput?.name ?? "–")“ ankommen. Es wird nichts gespeichert.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Dreh die Gitarre vorher leise oder steck sie aus. Das Ergebnis gilt nur für diese beiden Geräte.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { model.showLoopbackInfo = false }
                    .keyboardShortcut(.cancelAction)
                Button("Messen") {
                    model.showLoopbackInfo = false
                    model.measureLoopback()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 440)
    }
}
