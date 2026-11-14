import AmpText
import SparkControl
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            EditorView()
                // The editor is drawn for the Mac's smallest window; a narrower iPad shows it scaled, not cut.
                .fittedOnPad(designWidth: 900)
                .overlay(alignment: .bottom) { BannerView().padding(14) }
                .withoutNavigationBarOnPad()
        }
        .searchable(text: $model.search, placement: .splitViewSearch, prompt: tr("Search presets"))
        .sheet(isPresented: $model.showsStore) { StoreSheet().fittedSheetOnPad() }
        .sheet(item: $model.renameTarget) { _ in RenameSheet().fittedSheetOnPad() }
        .sheet(isPresented: saveAsShown) { SaveAsSheet().fittedSheetOnPad() }
        .sheet(isPresented: $model.showsTemplates) { TemplateSheet().fittedSheetOnPad() }
        .sheet(isPresented: Binding(get: { model.showsAI }, set: { model.showsAI = $0 })) { AISoundSheet().fittedSheetOnPad() }
        .sheet(isPresented: Binding(get: { model.showsKemperImport }, set: { if !$0 { model.closeKemperImport() } })) {
            KemperImportSheet().fittedSheetOnPad()
        }
        .confirmationDialog(storeTitle, isPresented: storeDialogShown, presenting: model.storeRequest) { request in
            Button(tr("Store on %@", link.profile.slotName(request.slot))) { model.store(request) }
            Button(tr("Cancel"), role: .cancel) { model.storeRequest = nil }
        } message: { request in
            Text(storeMessage(request.slot))
        }
        .confirmationDialog(tr("Set this sound on the %@?", link.profile.displayName),
                            isPresented: Binding(get: { model.reactorRequest != nil },
                                                 set: { if !$0 { model.reactorRequest = nil } }),
                            presenting: model.reactorRequest) { sound in
            Button(tr("Set")) { model.playOnReactor(sound) }
            Button(tr("Cancel"), role: .cancel) { model.reactorRequest = nil }
        } message: { sound in
            Text(tr("%@.\n\nTurn Volume down on the device first: another amp can be louder. The master is not changed. The slot’s current sound is then altered until you change the slot; nothing is stored.", sound.summary))
        }
        .confirmationDialog(unsavedTitle, isPresented: unsavedShown) {
            Button(tr("Save to this Mac")) { model.resolvePending(save: true) }
            Button(tr("Discard"), role: .destructive) { model.resolvePending(save: false) }
            Button(tr("Cancel"), role: .cancel) { model.pendingSelection = nil }
        } message: {
            Text(tr("Without saving, the changes are lost."))
        }
        .confirmationDialog(lossTitle, isPresented: lossShown) {
            Button(model.pendingDisconnect ? tr("Save as a preset, then disconnect") : tr("Save as a preset, then switch")) {
                model.resolveDeviceChange(save: true)
            }
            Button(model.pendingDisconnect ? tr("Disconnect without saving") : tr("Switch without saving"), role: .destructive) {
                model.resolveDeviceChange(save: false)
            }
            Button(tr("Cancel"), role: .cancel) {
                model.pendingDevice = nil
                model.pendingDisconnect = false
            }
        } message: {
            Text(tr("It then plays its stored slot again. When saved, the sound goes to this Mac under “On this Mac”."))
        }
        .onReceive(NotificationCenter.default.publisher(for: PresetsContent.didBecomeActive)) { _ in
            model.reloadLibrary()
            model.store.syncIfDue()
        }
    }

    private var saveAsShown: Binding<Bool> {
        Binding(get: { model.saveAsName != nil }, set: { if !$0 { model.saveAsName = nil } })
    }

    private var storeDialogShown: Binding<Bool> {
        Binding(get: { model.storeRequest != nil }, set: { if !$0 { model.storeRequest = nil } })
    }

    private var unsavedShown: Binding<Bool> {
        Binding(get: { model.pendingSelection != nil }, set: { if !$0 { model.pendingSelection = nil } })
    }

    private var lossShown: Binding<Bool> {
        Binding(get: { model.pendingDevice != nil || model.pendingDisconnect },
                set: { if !$0 { model.pendingDevice = nil; model.pendingDisconnect = false } })
    }

    private var lossTitle: String {
        tr("The sound on the %@ is lost when it disconnects. Save it as a preset first?", link.profile.displayName)
    }

    private var storeTitle: String {
        guard let request = model.storeRequest else { return "" }
        return tr("Store “%@” on %@?", request.preset.name, link.profile.slotName(request.slot))
    }

    private var unsavedTitle: String {
        tr("“%@” has unsaved changes.", model.editor.preset?.name ?? "Preset")
    }

    private func storeMessage(_ slot: Int) -> String {
        let place = link.profile.slotName(slot)
        if let preset = link.slots[safe: slot] ?? nil {
            return tr("What is on %@ now, “%@”, is first read fresh from the amp and saved to this Mac. Then the slot is read back as a check.", place, preset.name)
        }
        return tr("What is on %@ now is first read fresh from the amp and saved to this Mac. Then the slot is read back as a check.", place)
    }
}
