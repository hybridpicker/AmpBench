import AmpText
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SparkControl
import SwiftUI

/// AmpBench's area "Presets": sidebar and editor, and what starts with them.
@MainActor
enum PresetsContent {
    static func root(_ model: PresetsModel) -> some View {
        ContentView()
            .environmentObject(model)
            .environmentObject(model.link)
            .environmentObject(model.editor)
            .environmentObject(model.browser)
            .task { await startOnce(model) }
    }

    /// The app came to the front: files may have arrived in the folder meanwhile.
    #if os(macOS)
    static let didBecomeActive = NSApplication.didBecomeActiveNotification
    #else
    static let didBecomeActive = UIApplication.didBecomeActiveNotification
    #endif

    private static var started = false

    /// Bluetooth, the snapshot and the live self-test start when the content first appears, or when the tuner first
    /// needs the amp, and only then: AmpBench shows the content again on every switch to its area, and must not
    /// reconnect after "Disconnect".
    static func startOnce(_ model: PresetsModel) async {
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
    /// False while AmpBench shows another area: Presets' own keys rest, the keys both areas use go to it, and
    /// undo goes to the responder chain.
    var isActive = true

    private var editor: EditorModel { model.editor }
    private var browser: LibraryBrowser { model.browser }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(tr("New preset")) { model.newPreset() }
                .keyboardShortcut(owned(KeyboardShortcut("n", modifiers: .command)))
                .disabled(!isActive)
            Button(tr("New preset from template …")) { model.showsTemplates = true }
                .keyboardShortcut(owned(KeyboardShortcut("n", modifiers: [.command, .shift])))
                .disabled(!isActive)
            Button(tr("AI Sound from a description …")) { model.showsAI = true }
                .keyboardShortcut(owned(KeyboardShortcut("n", modifiers: [.command, .option])))
                .disabled(!isActive)
            Button(tr("Import from Kemper …")) { model.showsKemperImport = true }
                .disabled(!isActive)
            Button(tr("Duplicate")) { model.duplicateCurrent() }
                .keyboardShortcut(owned(KeyboardShortcut("d", modifiers: .command)))
                .disabled(editor.preset == nil || !isActive)
            Divider()
            Button(browser.isOpen ? tr("Close the sound library") : tr("Sound library")) { model.toggleLibrary() }
                .keyboardShortcut(owned(KeyboardShortcut("l", modifiers: .command)))
                .disabled(!isActive)
            Button(tr("Search sounds")) { model.openLibrary() }
                .keyboardShortcut(owned(KeyboardShortcut("f", modifiers: .command)))
                .disabled(!isActive)
        }
        // This group also holds the system's Close (⌘W): replacing it would take that away, so it comes back here.
        CommandGroup(replacing: .saveItem) {
            #if os(macOS)
            Button(tr("Close")) { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
            #endif
            Button(tr("Save to this Mac")) { model.saveOnMac() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(editor.preset == nil || editor.showsOriginal)
            Button(tr("Save as …")) { model.beginSaveAs() }
                .keyboardShortcut(owned(KeyboardShortcut("s", modifiers: [.command, .shift])))
                .disabled(editor.preset == nil || editor.showsOriginal || !isActive)
            Divider()
            Button(tr("Sync the sound store now")) { model.store.sync() }
                .disabled(!model.store.isReady || model.store.state == .syncing)
            Button(tr("Sound store …")) { model.showsStore = true }
                .disabled(!isActive)
        }
        CommandGroup(replacing: .undoRedo) {
            // Text fields keep their own undo, everything else goes to the editor.
            Button(tr("Undo")) {
                if Self.textIsEditing || !isActive {
                    Self.sendToResponders("undo:")
                } else {
                    editor.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button(tr("Redo")) {
                if Self.textIsEditing || !isActive {
                    Self.sendToResponders("redo:")
                } else {
                    editor.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            // While the library is open these act on its selection, which may be several sounds.
            Button(tr("Rename …")) { if browser.isOpen { model.beginRenameInLibrary() } else { model.beginRename() } }
                .keyboardShortcut(owned(KeyboardShortcut("e", modifiers: .command)))
                .disabled((browser.isOpen ? model.librarySelection.isEmpty : model.selectedItem == nil) || !isActive)
            Button(tr("Move to Trash")) { if browser.isOpen { model.trashInLibrary() } else { model.trash() } }
                .keyboardShortcut(owned(KeyboardShortcut(.delete, modifiers: .command)))
                .disabled((browser.isOpen ? model.librarySelection.isEmpty : model.selectedItem == nil) || !isActive)
            Button(tr("Show in Finder")) { model.reveal() }
                .keyboardShortcut(owned(KeyboardShortcut("r", modifiers: [.command, .shift])))
                .disabled(!isActive)
        }
        CommandMenu(tr("Sounds")) {
            let selected = browser.isOpen ? model.librarySelection : []
            Button(tr("Hear on the amp")) { model.hearSelection() }
                .disabled(selected.isEmpty || !model.canUse(.playTemporary) || !isActive)
            Button(tr("Open in the editor")) { model.openSelectionInEditor() }
                .keyboardShortcut(owned(KeyboardShortcut(.return, modifiers: .command)))
                .disabled(selected.count != 1 || !isActive)
            Divider()
            Button(tr("Favorite on or off")) { model.toggleFavorite(selected) }
                .keyboardShortcut(owned(KeyboardShortcut("f", modifiers: [.command, .shift])))
                .disabled(selected.isEmpty || !isActive)
            Button(tr("To listen on or off")) { model.toggleListen(selected) }
                .keyboardShortcut(owned(KeyboardShortcut("k", modifiers: .command)))
                .disabled(selected.isEmpty || !isActive)
            Button(tr("Add a tag …")) { browser.focusRequest = .tags }
                .keyboardShortcut(owned(KeyboardShortcut("t", modifiers: .command)))
                .disabled(selected.isEmpty || !isActive)
            Divider()
            Button(tr("Next grouping")) { browser.grouping = browser.grouping.next }
                .keyboardShortcut(owned(KeyboardShortcut("g", modifiers: .command)))
                .disabled(!browser.isOpen || !isActive)
            Button(tr("Go to the filters")) { browser.focusRequest = .filters }
                .disabled(!browser.isOpen || !isActive)
        }
        CommandMenu(tr("Amp")) {
            // As many slots as the device has; shortcuts for at most as many as StudioKeymap holds.
            ForEach(Array(model.link.profile.slots), id: \.self) { slot in
                Button(tr("Play %@", model.link.profile.slotName(slot))) { model.select(.slot(slot)) }
                    .keyboardShortcut(slotKey(slot, [.command]))
                    .disabled(!model.link.can(.switchSlot))
            }
            Divider()
            ForEach(Array(model.link.profile.slots), id: \.self) { slot in
                Button(tr("Store on %@ …", model.link.profile.slotName(slot))) { model.askToStoreEdited(in: slot) }
                    .keyboardShortcut(isActive ? slotKey(slot, [.command, .option]) : nil)
                    .disabled(!model.canUse(.store) || editor.preset == nil || editor.showsOriginal || !isActive)
            }
            Divider()
            Button(editor.showsOriginal ? tr("Play the edited state") : tr("Compare with the saved state")) {
                editor.toggleComparison()
            }
            .keyboardShortcut(owned(KeyboardShortcut("b", modifiers: .command)))
            .disabled((!editor.isModified && !editor.showsOriginal) || !isActive)
            Toggle(tr("Hear changes live"), isOn: Binding(get: { editor.isLiveEnabled }, set: { editor.isLiveEnabled = $0 }))
                .keyboardShortcut(owned(KeyboardShortcut("l", modifiers: [.command, .shift])))
                .disabled(!isActive)
            Divider()
            Button(tr("Read the amp again")) { model.reloadAmp() }
                .keyboardShortcut(owned(KeyboardShortcut("r", modifiers: .command)))
                .disabled(!model.canUse(.read) || !isActive)
            // Studio connects only on request and can disconnect again, for the Spark app on the phone.
            Divider()
            if model.link.wanted {
                Button(tr("Disconnect from the amp")) { model.disconnect() }
            } else {
                Button(tr("Connect to the amp")) { model.start(bluetooth: true) }
            }
        }
        CommandMenu(tr("Chain")) {
            ForEach(ChainPlace.allCases) { place in
                Button(place.title) { editor.focus = place }
                    .keyboardShortcut(owned(KeyboardShortcut(KeyEquivalent(Character("\(place.rawValue + 1)")),
                                                             modifiers: .control)))
                    .disabled(editor.preset == nil || !isActive)
            }
            Divider()
            Button(tr("Selected device on or off")) {
                if let effect = editor.preset?.effects[safe: editor.focus.rawValue] {
                    editor.setOn(place: editor.focus.rawValue, !effect.isOn)
                }
            }
            .keyboardShortcut(owned(KeyboardShortcut("0", modifiers: .control)))
            .disabled(editor.isLocked || !isActive)
        }
    }

    /// ⌘ plus the slot's digit, for the first `DeviceProfile.largestSlotCount` slots.
    private func slotKey(_ slot: Int, _ modifiers: EventModifiers) -> KeyboardShortcut? {
        guard slot < min(DeviceProfile.largestSlotCount, 9) else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character("\(slot + 1)")), modifiers: modifiers)
    }

    /// A shortcut that belongs to this menu only while its window is in front.
    private func owned(_ shortcut: KeyboardShortcut) -> KeyboardShortcut? {
        isActive ? shortcut : nil
    }

    #if os(macOS)
    private static var textIsEditing: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    private static func sendToResponders(_ action: String) {
        NSApp.sendAction(Selector((action)), to: nil, from: nil)
    }
    #else
    /// On iPadOS a text field that is being edited takes ⌘Z itself, before the menu sees it.
    private static var textIsEditing: Bool { false }

    private static func sendToResponders(_ action: String) {
        UIApplication.shared.sendAction(Selector((action)), to: nil, from: nil, for: nil)
    }
    #endif
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
