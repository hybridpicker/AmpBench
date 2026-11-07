import AppKit
import SparkCore
import SwiftUI

/// Launch options. `--library` points the whole app at another folder, with its own settings, for testing.
struct LaunchOptions {
    var folder: URL = LibraryStore.defaultFolder
    var isTestLibrary = false

    static let current: LaunchOptions = {
        var options = LaunchOptions()
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
            options.folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            options.isTestLibrary = true
        }
        return options
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var model: AppModel?
    private(set) static var mainWindow: NSWindow?

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

    /// The app makes its window itself: it has to be there on every launch, and SwiftUI's own window scene did not
    /// open reliably. The content is still SwiftUI.
    func showMainWindow() {
        guard let model = Self.model else { return }
        if let window = Self.mainWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let content = RootView()
            .environmentObject(model)
            .environmentObject(model.meter)
            .environmentObject(model.playhead)
            .environmentObject(model.live)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Spark Recorder"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 1120, height: 680)
        window.contentView = NSHostingView(rootView: content)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("SparkRecorderMain")
        Self.mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A click on the Dock icon brings the window back after it was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === Self.mainWindow else { return }
        // A running recording continues, and the Dock icon shows REC. Otherwise closing the window ends the app,
        // and with it any listening.
        Self.model?.windowClosed()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(Self.model?.isRecording ?? false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.shutdown()
    }
}

struct SparkRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    private let keyRouter: KeyRouter

    @MainActor
    init() {
        let options = LaunchOptions.current
        let defaults = options.isTestLibrary
            ? (UserDefaults(suiteName: "local.sparkrecorder.tests") ?? .standard)
            : .standard
        let model = AppModel(folder: options.folder, defaults: defaults)
        AppDelegate.model = model
        _model = StateObject(wrappedValue: model)
        keyRouter = KeyRouter(model: model)
    }

    var body: some Scene {
        // The window comes from the app delegate. This scene only carries the menus.
        Settings { EmptyView() }
            .commands { AppCommands(model: model) }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DeckView()
            WavePanel()
            Divider()
            LibraryArea()
        }
        .frame(minWidth: 1120, maxWidth: .infinity, minHeight: 680, maxHeight: .infinity)
        .sheet(isPresented: $model.showShortcuts) { ShortcutsSheet() }
        .sheet(isPresented: $model.showLoopbackInfo) { LoopbackSheet() }
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
    }
}

// MARK: - Menus

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appSettings) {}
        CommandGroup(before: .windowList) {
            Button("Spark Recorder zeigen") { (NSApp.delegate as? AppDelegate)?.showMainWindow() }
                .keyboardShortcut("0", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("Tastaturkürzel") { model.showShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
        }
        CommandGroup(after: .undoRedo) {
            Divider()
            Button("In den Papierkorb legen", action: discardOrEditText)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.isRecording)
            Button("Zuletzt Verworfenes wiederherstellen", action: model.restoreLastTrashed)
                .disabled(!model.canRestoreLastTrashed)
        }
        CommandMenu("Aufnahme") {
            Button(recordTitle + "  (R)", action: model.toggleRecord)
                .disabled(!model.libraryIsUsable)
            Button("Marker setzen  (M)", action: model.addMarker)
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
        }
        CommandMenu("Wiedergabe") {
            Button("Abspielen oder anhalten  (Leertaste)", action: model.togglePlay)
            Button("Schleife A, B, aus  (L)", action: model.toggleLoop)
                .disabled(model.current == nil)
            Divider()
            Button("5 Sekunden zurück  (←)") { model.nudge(by: -5) }
            Button("5 Sekunden vor  (→)") { model.nudge(by: 5) }
            Divider()
            Button("Langsamer  (-)") { model.setTempo(model.tempo - 0.05) }
            Button("Schneller  (+)") { model.setTempo(model.tempo + 0.05) }
            Button("Tempo und Tonhöhe zurücksetzen  (0)", action: model.resetTempoAndPitch)
            Divider()
            Button("Metronom an oder aus  (N)", action: model.toggleClick)
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
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.current == nil)
            Button("Im Finder zeigen") { model.reveal() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.current == nil)
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
            Button("Ordner prüfen") { model.scanFolder() }
                .disabled(model.isRecording)
            Button("Bibliotheksordner im Finder zeigen", action: model.revealLibraryFolder)
        }
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

private struct ShortcutsSheet: View {
    @EnvironmentObject private var model: AppModel

    private let rows: [(String, String)] = [
        ("R", "Aufnahme starten oder stoppen, auch „Nochmal“"),
        ("Leertaste", "Abspielen oder anhalten"),
        ("L", "Schleife: erst A, dann B, dann aus"),
        ("M", "Marker setzen, auch während der Aufnahme"),
        ("K", "Take behalten"),
        ("⌘⌫", "Take verwerfen (Papierkorb)"),
        ("⌘Z", "Rückgängig"),
        ("←  →", "5 Sekunden springen, mit ⇧ 1 Sekunde"),
        ("-  +", "Langsamer oder schneller"),
        ("0", "Tempo und Tonhöhe zurücksetzen"),
        ("1 – 5", "Bewerten"),
        ("F", "Favorit"),
        ("B", "Beim Vergleich zum anderen Take wechseln"),
        ("N", "Metronom an oder aus"),
        ("T", "Tempo eintippen"),
        ("G", "Retro-Puffer speichern"),
        ("⌘F", "Suchen"),
        ("⌘E", "Umbenennen"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tastaturkürzel").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).font(.system(.body, design: .monospaced).weight(.semibold))
                        Text(row.1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Einzelne Tasten wirken nicht, solange du in ein Textfeld schreibst. Keine einzelne Taste kann etwas löschen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Schließen") { model.showShortcuts = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct LoopbackSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rückkopplung messen").font(.title2.weight(.semibold))
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
        .padding(20)
        .frame(width: 440)
    }
}
