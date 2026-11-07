import AppKit
import SparkControl
import SwiftUI

/// Spark Studio's area "Presets": sidebar and editor, and what starts with them.
@MainActor
enum PresetsContent {
    static func root(_ model: PresetsModel) -> some View {
        ContentView()
            .environmentObject(model)
            .environmentObject(model.link)
            .environmentObject(model.editor)
            .task { await startOnce(model) }
    }

    private static var started = false

    /// Bluetooth, the snapshot and the live self-test start when the content first appears, and only then: Spark
    /// Studio shows the content again on every switch to its area, and must not reconnect after "Trennen".
    private static func startOnce(_ model: PresetsModel) async {
        guard !started else { return }
        started = true
        Snapshot.prepare()
        model.start(bluetooth: !Snapshot.isOffline)
        await Snapshot.run(model)
        await LiveSelfTest.run(model)
    }
}

struct PresetCommands: Commands {
    @ObservedObject var model: PresetsModel
    /// False while Spark Studio shows another area: Presets' own keys rest, the keys both areas use go to it, and
    /// undo goes to the responder chain.
    var isActive = true

    private var editor: EditorModel { model.editor }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neues Preset") { model.newPreset() }
                .keyboardShortcut(owned(KeyboardShortcut("n", modifiers: .command)))
                .disabled(!isActive)
            Button("Neues Preset aus Vorlage …") { model.showsTemplates = true }
                .keyboardShortcut(owned(KeyboardShortcut("n", modifiers: [.command, .shift])))
                .disabled(!isActive)
            Button("Duplizieren") { model.duplicateCurrent() }
                .keyboardShortcut(owned(KeyboardShortcut("d", modifiers: .command)))
                .disabled(editor.preset == nil || !isActive)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Auf dem Mac sichern") { model.saveOnMac() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(editor.preset == nil || editor.showsOriginal)
            Button("Sichern unter …") { model.beginSaveAs() }
                .keyboardShortcut(owned(KeyboardShortcut("s", modifiers: [.command, .shift])))
                .disabled(editor.preset == nil || editor.showsOriginal || !isActive)
        }
        CommandGroup(replacing: .undoRedo) {
            // Text fields keep their own undo, everything else goes to the editor.
            Button("Rückgängig") {
                if Self.textIsEditing || !isActive {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    editor.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button("Wiederholen") {
                if Self.textIsEditing || !isActive {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                } else {
                    editor.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Umbenennen …") { model.beginRename() }
                .keyboardShortcut(owned(KeyboardShortcut("e", modifiers: .command)))
                .disabled(model.selectedItem == nil || !isActive)
            Button("In den Papierkorb") { model.trash() }
                .keyboardShortcut(owned(KeyboardShortcut(.delete, modifiers: .command)))
                .disabled(model.selectedItem == nil || !isActive)
            Button("Im Finder zeigen") { model.reveal() }
                .keyboardShortcut(owned(KeyboardShortcut("r", modifiers: [.command, .shift])))
                .disabled(!isActive)
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
                    .keyboardShortcut(owned(KeyboardShortcut(KeyEquivalent(Character("\(slot + 1)")),
                                                             modifiers: [.command, .option])))
                    .disabled(!model.canUseAmp || editor.preset == nil || editor.showsOriginal || !isActive)
            }
            Divider()
            Button(editor.showsOriginal ? "Bearbeiteten Stand spielen" : "Mit gespeichertem Stand vergleichen") {
                editor.toggleComparison()
            }
            .keyboardShortcut(owned(KeyboardShortcut("b", modifiers: .command)))
            .disabled((!editor.isModified && !editor.showsOriginal) || !isActive)
            Toggle("Änderungen live hören", isOn: Binding(get: { editor.isLiveEnabled }, set: { editor.isLiveEnabled = $0 }))
                .keyboardShortcut(owned(KeyboardShortcut("l", modifiers: [.command, .shift])))
                .disabled(!isActive)
            Divider()
            Button("Verstärker neu lesen") { model.reloadAmp() }
                .keyboardShortcut(owned(KeyboardShortcut("r", modifiers: .command)))
                .disabled(!model.canUseAmp || !isActive)
            // Studio connects only on request and can disconnect again, for the Spark app on the phone.
            Divider()
            if model.link.wanted {
                Button("Vom Verstärker trennen") { model.link.stop() }
            } else {
                Button("Mit dem Verstärker verbinden") { model.start(bluetooth: true) }
            }
        }
        CommandMenu("Kette") {
            ForEach(ChainPlace.allCases) { place in
                Button(place.title) { editor.focus = place }
                    .keyboardShortcut(owned(KeyboardShortcut(KeyEquivalent(Character("\(place.rawValue + 1)")),
                                                             modifiers: .control)))
                    .disabled(editor.preset == nil || !isActive)
            }
            Divider()
            Button("Gewähltes Gerät an oder aus") {
                if let effect = editor.preset?.effects[safe: editor.focus.rawValue] {
                    editor.setOn(place: editor.focus.rawValue, !effect.isOn)
                }
            }
            .keyboardShortcut(owned(KeyboardShortcut("0", modifiers: .control)))
            .disabled(editor.isLocked || !isActive)
        }
    }

    /// A shortcut that belongs to this menu only while its window is in front.
    private func owned(_ shortcut: KeyboardShortcut) -> KeyboardShortcut? {
        isActive ? shortcut : nil
    }

    private static var textIsEditing: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
