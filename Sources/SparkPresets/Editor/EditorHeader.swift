import SparkControl
import SwiftUI

/// Name, BPM and state of the preset in the editor, with undo, A/B and saving.
struct EditorHeader: View {
    let preset: SparkPreset
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var editor: EditorModel
    @EnvironmentObject private var link: SparkLink
    @State private var name = ""
    @State private var bpm = ""
    @State private var description = ""
    @FocusState private var field: Field?

    private enum Field { case name, bpm, description }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            AmberDisplay {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("Name", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.amber)
                            .focused($field, equals: .name)
                            .onSubmit(commitName)
                            .disabled(editor.isLocked)
                            .accessibilityLabel("Name des Presets")
                        badges.fixedSize()
                    }
                    HStack(spacing: 8) {
                        Text(sourceText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.amberDim)
                            .lineLimit(1)
                            .fixedSize()
                        ZStack(alignment: .leading) {
                            if description.isEmpty && field != .description {
                                Text("Beschreibung hinzufügen")
                                    .foregroundStyle(Theme.amberDim.opacity(0.55))
                                    .lineLimit(1)
                                    .accessibilityHidden(true)
                            }
                            TextField("", text: $description)
                                .textFieldStyle(.plain)
                                .foregroundStyle(Theme.amberDim)
                                .focused($field, equals: .description)
                                .onSubmit(commitDescription)
                                .disabled(editor.isLocked)
                                .accessibilityLabel("Beschreibung")
                        }
                        .font(.system(size: 11))
                    }
                    LoadMeter(transfer: link.transfer)
                        .padding(.top, 3)
                }
            }
            .frame(minWidth: 260)
            bpmField
            Spacer(minLength: 0)
            actions
        }
        .onAppear(perform: load)
        .onChange(of: preset.name) { load() }
        .onChange(of: preset.bpm) { load() }
        .onChange(of: preset.description) { load() }
        .onChange(of: field) { old, _ in
            if old == .name { commitName() }
            if old == .bpm { commitBPM() }
            if old == .description { commitDescription() }
        }
    }

    private var badges: some View {
        HStack(spacing: 8) {
            if editor.isModified && !editor.showsOriginal {
                HStack(spacing: 4) {
                    Circle().fill(Theme.amberHot).frame(width: 6, height: 6)
                    PanelLabel("Geändert", color: Theme.amberHot)
                }
                .accessibilityElement(children: .combine)
            }
            if editor.showsOriginal {
                PanelLabel("A · Gespeichert", color: Theme.amber)
            }
            HStack(spacing: 4) {
                LED(isOn: editor.isHeard, color: Theme.on, size: 7)
                PanelLabel("Live", color: editor.isHeard ? Theme.on : Theme.labelDim)
            }
            .help(editor.isHeard ? "Der Verstärker spielt diesen Stand, Änderungen sind sofort hörbar."
                                 : "Die erste Änderung schickt das Preset zum Verstärker, ohne einen Platz zu überschreiben.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(editor.isHeard ? "Live am Verstärker" : "Nicht am Verstärker")
        }
    }

    private var bpmField: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("BPM").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            TextField("BPM", text: $bpm)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .focused($field, equals: .bpm)
                .onSubmit(commitBPM)
                .disabled(editor.isLocked)
                .accessibilityLabel("Tempo in BPM")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!editor.canUndo || editor.showsOriginal)
                    .help("Rückgängig (⌘Z)")
                    .accessibilityLabel("Rückgängig")
                Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!editor.canRedo || editor.showsOriginal)
                    .help("Wiederholen (⇧⌘Z)")
                    .accessibilityLabel("Wiederholen")
            }
            .fixedSize()
            Toggle(isOn: Binding(get: { editor.showsOriginal }, set: { _ in editor.toggleComparison() })) {
                Text(editor.showsOriginal ? "A" : "A/B").frame(minWidth: 28)
            }
            .toggleStyle(.button)
            .disabled(!editor.isModified && !editor.showsOriginal)
            .help("Vergleicht mit dem gespeicherten Stand (⌘B)")
            .accessibilityLabel("Mit dem gespeicherten Stand vergleichen")
            Menu {
                Button("Auf dem Mac sichern") { model.saveOnMac() }
                Button("Sichern unter …") { model.beginSaveAs() }
                Divider()
                ForEach(0..<4, id: \.self) { slot in
                    Button("Auf Platz \(slot + 1) speichern …\(link.slots[slot].map { " (jetzt „\($0.name)“)" } ?? "")") {
                        model.askToStoreEdited(in: slot)
                    }
                    .disabled(!model.canUseAmp)
                }
                Divider()
                Button("Änderungen verwerfen") { editor.revert() }.disabled(!editor.isModified)
                Button("Duplizieren") { model.duplicateCurrent() }
            } label: {
                Label("Sichern", systemImage: "square.and.arrow.down")
            } primaryAction: {
                model.saveOnMac()
            }
            .fixedSize()
            .disabled(editor.showsOriginal)
        }
    }

    private var sourceText: String {
        switch editor.source {
        case .slot(let slot): model.origin(slot: slot)
        case .saved: "Auf dem Mac"
        case .draft: "Neu, noch nicht gesichert"
        case nil: ""
        }
    }

    private func load() {
        if field != .name { name = preset.name }
        if field != .bpm { bpm = String(format: "%.0f", preset.bpm) }
        if field != .description { description = preset.description }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = PresetRules.problem(withName: trimmed) {
            model.show(.warning, problem)
            name = preset.name
            return
        }
        editor.setName(trimmed)
    }

    private func commitBPM() {
        guard let value = Float(bpm.replacingOccurrences(of: ",", with: ".")) else {
            bpm = String(format: "%.0f", preset.bpm)
            return
        }
        editor.setBPM(value)
        bpm = String(format: "%.0f", editor.preset?.bpm ?? value)
    }

    private func commitDescription() {
        editor.setDescription(description.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
