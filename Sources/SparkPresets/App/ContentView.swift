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
        .sheet(item: $model.renameTarget) { _ in RenameSheet() }
        .sheet(isPresented: saveAsShown) { SaveAsSheet() }
        .sheet(isPresented: $model.showsTemplates) { TemplateSheet() }
        .confirmationDialog(storeTitle, isPresented: storeDialogShown, presenting: model.storeRequest) { request in
            Button("Auf Platz \(request.slot + 1) speichern") { model.store(request) }
            Button("Abbrechen", role: .cancel) { model.storeRequest = nil }
        } message: { request in
            Text("Was jetzt auf Platz \(request.slot + 1) liegt\(slotName(request.slot)), wird vorher frisch vom Verstärker gelesen und auf dem Mac gesichert. Danach wird der Platz zur Kontrolle zurückgelesen.")
        }
        .confirmationDialog(unsavedTitle, isPresented: unsavedShown) {
            Button("Auf dem Mac sichern") { model.resolvePending(save: true) }
            Button("Verwerfen", role: .destructive) { model.resolvePending(save: false) }
            Button("Abbrechen", role: .cancel) { model.pendingSelection = nil }
        } message: {
            Text("Ohne Sichern gehen die Änderungen verloren.")
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

    private var storeTitle: String {
        guard let request = model.storeRequest else { return "" }
        return "„\(request.preset.name)“ auf Platz \(request.slot + 1) speichern?"
    }

    private var unsavedTitle: String {
        "„\(model.editor.preset?.name ?? "Preset")“ hat ungesicherte Änderungen."
    }

    private func slotName(_ slot: Int) -> String {
        link.slots[slot].map { ", „\($0.name)“" } ?? ""
    }
}
