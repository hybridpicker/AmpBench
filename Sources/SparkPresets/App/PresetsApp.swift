import AppKit
import SparkControl
import SwiftUI

@main
struct PresetsApp: App {
    @MainActor static let sharedModel = PresetsModel()
    @StateObject private var model = PresetsApp.sharedModel

    init() {
        if Snapshot.isActive { Snapshot.openWindowIfNeeded() }
    }

    var body: some Scene {
        Window("Spark Presets", id: "main") {
            Self.root(model)
        }
        .defaultSize(width: 1180, height: 780)
        .commands { PresetCommands(model: model) }
    }

    /// The window's content, also for the window the snapshot opens itself.
    @MainActor static func root(_ model: PresetsModel) -> some View {
        ContentView()
            .environmentObject(model)
            .environmentObject(model.link)
            .environmentObject(model.editor)
            .frame(minWidth: 900, minHeight: 600)
            .task {
                Snapshot.prepare()
                model.start(bluetooth: !Snapshot.isOffline)
                await Snapshot.run(model)
                await LiveSelfTest.run(model)
            }
    }
}

struct PresetCommands: Commands {
    @ObservedObject var model: PresetsModel

    private var editor: EditorModel { model.editor }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neues Preset") { model.newPreset() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Neues Preset aus Vorlage …") { model.showsTemplates = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Duplizieren") { model.duplicateCurrent() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(editor.preset == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Auf dem Mac sichern") { model.saveOnMac() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(editor.preset == nil || editor.showsOriginal)
            Button("Sichern unter …") { model.beginSaveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(editor.preset == nil || editor.showsOriginal)
        }
        CommandGroup(replacing: .undoRedo) {
            // Text fields keep their own undo, everything else goes to the editor.
            Button("Rückgängig") {
                if Self.textIsEditing { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { editor.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button("Wiederholen") {
                if Self.textIsEditing { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { editor.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Umbenennen …") { model.beginRename() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.selectedItem == nil)
            Button("In den Papierkorb") { model.trash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedItem == nil)
            Button("Im Finder zeigen") { model.reveal() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("Verstärker") {
            ForEach(0..<4, id: \.self) { slot in
                Button("Platz \(slot + 1) spielen") { model.select(.slot(slot)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(slot + 1)")), modifiers: .command)
                    .disabled(model.link.status != .connected)
            }
            Divider()
            ForEach(0..<4, id: \.self) { slot in
                Button("Auf Platz \(slot + 1) speichern …") { model.askToStoreEdited(in: slot) }
                    .keyboardShortcut(KeyEquivalent(Character("\(slot + 1)")), modifiers: [.command, .option])
                    .disabled(!model.canUseAmp || editor.preset == nil || editor.showsOriginal)
            }
            Divider()
            Button(editor.showsOriginal ? "Bearbeiteten Stand spielen" : "Mit gespeichertem Stand vergleichen") {
                editor.toggleComparison()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(!editor.isModified && !editor.showsOriginal)
            Toggle("Änderungen live hören", isOn: Binding(get: { editor.isLiveEnabled }, set: { editor.isLiveEnabled = $0 }))
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Verstärker neu lesen") { model.reloadAmp() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canUseAmp)
        }
        CommandMenu("Kette") {
            ForEach(ChainPlace.allCases) { place in
                Button(place.title) { editor.focus = place }
                    .keyboardShortcut(KeyEquivalent(Character("\(place.rawValue + 1)")), modifiers: .control)
                    .disabled(editor.preset == nil)
            }
            Divider()
            Button("Gewähltes Gerät an oder aus") {
                if let effect = editor.preset?.effects[safe: editor.focus.rawValue] {
                    editor.setOn(place: editor.focus.rawValue, !effect.isOn)
                }
            }
            .keyboardShortcut("0", modifiers: .control)
            .disabled(editor.isLocked)
        }
    }

    private static var textIsEditing: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
