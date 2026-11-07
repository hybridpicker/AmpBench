import SparkControl
import SparkDesign
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
            Display(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)) {
                VStack(alignment: .leading, spacing: 5) {
                    // In a narrow window the lamps move below the name, so the name keeps its room.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            nameField.frame(minWidth: 150)
                            lamps.fixedSize()
                            bpmField
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 12) {
                                nameField
                                bpmField
                            }
                            lamps.fixedSize()
                        }
                    }
                    HStack(spacing: 8) {
                        Text(sourceText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.device.amberDim)
                            .lineLimit(1)
                            .fixedSize()
                        Text("·").foregroundStyle(Theme.device.amberDim).accessibilityHidden(true)
                        ZStack(alignment: .leading) {
                            if description.isEmpty && field != .description {
                                Text("Beschreibung hinzufügen")
                                    .foregroundStyle(Theme.device.lampOffText)
                                    .lineLimit(1)
                                    .accessibilityHidden(true)
                            }
                            TextField("", text: $description)
                                .textFieldStyle(.plain)
                                .foregroundStyle(Theme.device.amberDim)
                                .focused($field, equals: .description)
                                .onSubmit(commitDescription)
                                .disabled(editor.isLocked)
                                .accessibilityLabel("Beschreibung")
                        }
                        .font(.system(size: 11))
                    }
                    HStack(spacing: 8) {
                        PanelLabel("Übertragung", color: Theme.device.lampOffText)
                        LoadMeter(transfer: link.transfer, height: 4)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(minWidth: 280)
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

    private var nameField: some View {
        TextField("Name", text: $name)
            .textFieldStyle(.plain)
            .font(Theme.Fonts.title(23))
            .foregroundStyle(Theme.device.amber)
            .focused($field, equals: .name)
            .onSubmit(commitName)
            .disabled(editor.isLocked)
            .accessibilityLabel("Name des Presets")
    }

    private var lamps: some View {
        HStack(spacing: 10) {
            if editor.showsOriginal {
                Lamp("A · Gespeichert", tone: .amber, isOn: true, size: 6)
            } else {
                Lamp("Geändert", tone: .hot, isOn: editor.isModified, size: 6)
                    .accessibilityLabel(editor.isModified ? "Geändert" : "Unverändert")
            }
            Lamp("Live", tone: .on, isOn: editor.isHeard, size: 6)
                .help(editor.isHeard ? "Der Verstärker spielt diesen Stand, Änderungen sind sofort hörbar."
                                     : "Die erste Änderung schickt das Preset zum Verstärker, ohne einen Platz zu überschreiben.")
                .accessibilityLabel(editor.isHeard ? "Live am Verstärker" : "Nicht am Verstärker")
        }
    }

    /// The tempo, typed into the display.
    private var bpmField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            TextField("BPM", text: $bpm)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.mono(20, weight: .semibold))
                .foregroundStyle(Theme.device.amber)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .focused($field, equals: .bpm)
                .onSubmit(commitBPM)
                .disabled(editor.isLocked)
                .accessibilityLabel("Tempo in BPM")
            Text("BPM")
                .font(Theme.Fonts.lamp())
                .foregroundStyle(Theme.device.amberDim)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.hardwareKey(keycap: "⌘Z"))
                .fixedSize()
                .disabled(!editor.canUndo || editor.showsOriginal)
                .help("Rückgängig (⌘Z)")
                .accessibilityLabel("Rückgängig")
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.hardwareKey())
                .fixedSize()
                .disabled(!editor.canRedo || editor.showsOriginal)
                .help("Wiederholen (⇧⌘Z)")
                .accessibilityLabel("Wiederholen")
            Button(editor.showsOriginal ? "A" : "A / B") { editor.toggleComparison() }
                .buttonStyle(.hardwareKey(editor.showsOriginal ? .on : .normal, keycap: "⌘B"))
                .fixedSize()
                .disabled(!editor.isModified && !editor.showsOriginal)
                .help("Vergleicht mit dem gespeicherten Stand (⌘B)")
                .accessibilityLabel("Mit dem gespeicherten Stand vergleichen")
                .accessibilityValue(editor.showsOriginal ? "gespeicherter Stand" : "bearbeiteter Stand")
            Button("Sichern") { model.saveOnMac() }
                .buttonStyle(.hardwareKey(.primary, keycap: "⌘S"))
                .fixedSize()
                .disabled(editor.showsOriginal)
                .help("Auf dem Mac sichern (⌘S)")
            Menu {
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
                Text("⋯")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.device.keyText)
                    .frame(width: 30, height: 28)
                    .background(KeyBody())
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(editor.showsOriginal)
            .help("Sichern unter, auf einem Platz speichern, verwerfen, duplizieren")
            .accessibilityLabel("Weitere Aktionen")
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
