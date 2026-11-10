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
                .overlay(alignment: .bottom) { BannerView().padding(14) }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Presets suchen")
        .sheet(item: $model.renameTarget) { _ in RenameSheet() }
        .sheet(isPresented: saveAsShown) { SaveAsSheet() }
        .sheet(isPresented: $model.showsTemplates) { TemplateSheet() }
        .sheet(isPresented: Binding(get: { model.showsAI }, set: { model.showsAI = $0 })) { AISoundSheet() }
        .sheet(isPresented: Binding(get: { model.showsKemperImport }, set: { if !$0 { model.closeKemperImport() } })) {
            KemperImportSheet()
        }
        .confirmationDialog(storeTitle, isPresented: storeDialogShown, presenting: model.storeRequest) { request in
            Button("Auf \(link.profile.slotName(request.slot)) speichern") { model.store(request) }
            Button("Abbrechen", role: .cancel) { model.storeRequest = nil }
        } message: { request in
            Text("Was jetzt auf \(link.profile.slotName(request.slot)) liegt\(slotName(request.slot)), wird vorher frisch vom Verstärker gelesen und auf dem Mac gesichert. Danach wird der Platz zur Kontrolle zurückgelesen.")
        }
        .confirmationDialog("Diesen Sound am \(link.profile.displayName) einstellen?",
                            isPresented: Binding(get: { model.reactorRequest != nil },
                                                 set: { if !$0 { model.reactorRequest = nil } }),
                            presenting: model.reactorRequest) { sound in
            Button("Einstellen") { model.playOnReactor(sound) }
            Button("Abbrechen", role: .cancel) { model.reactorRequest = nil }
        } message: { sound in
            Text("\(sound.summary).\n\nDreh vorher Volume am Gerät herunter: Ein anderer Amp kann lauter sein. Der Master wird nicht verändert. Der jetzige Sound des Platzes ist danach verstellt, bis du den Platz wechselst; gespeichert wird nichts.")
        }
        .confirmationDialog(unsavedTitle, isPresented: unsavedShown) {
            Button("Auf dem Mac sichern") { model.resolvePending(save: true) }
            Button("Verwerfen", role: .destructive) { model.resolvePending(save: false) }
            Button("Abbrechen", role: .cancel) { model.pendingSelection = nil }
        } message: {
            Text("Ohne Sichern gehen die Änderungen verloren.")
        }
        .confirmationDialog(lossTitle, isPresented: lossShown) {
            Button("Als Preset sichern, dann \(model.pendingDisconnect ? "trennen" : "wechseln")") {
                model.resolveDeviceChange(save: true)
            }
            Button("Ohne Sichern \(model.pendingDisconnect ? "trennen" : "wechseln")", role: .destructive) {
                model.resolveDeviceChange(save: false)
            }
            Button("Abbrechen", role: .cancel) {
                model.pendingDevice = nil
                model.pendingDisconnect = false
            }
        } message: {
            Text("Er spielt dann wieder seinen gespeicherten Platz. Gesichert landet der Sound auf dem Mac unter „Auf dem Mac“.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reloadLibrary()
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
        "Der Sound auf dem \(link.profile.displayName) geht beim Trennen verloren. Vorher als Preset sichern?"
    }

    private var storeTitle: String {
        guard let request = model.storeRequest else { return "" }
        return "„\(request.preset.name)“ auf \(link.profile.slotName(request.slot)) speichern?"
    }

    private var unsavedTitle: String {
        "„\(model.editor.preset?.name ?? "Preset")“ hat ungesicherte Änderungen."
    }

    private func slotName(_ slot: Int) -> String {
        (link.slots[safe: slot] ?? nil).map { ", „\($0.name)“" } ?? ""
    }
}
