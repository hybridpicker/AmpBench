import AmpText
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
                                Text(tr("Add a description"))
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
                                .accessibilityLabel(tr("Description"))
                        }
                        .font(.system(size: 11))
                    }
                    HStack(spacing: 8) {
                        PanelLabel(tr("Transfer"), color: Theme.device.lampOffText)
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
        TextField(tr("Name"), text: $name)
            .textFieldStyle(.plain)
            .font(Theme.Fonts.title(23))
            .foregroundStyle(Theme.device.amber)
            .focused($field, equals: .name)
            .onSubmit(commitName)
            .disabled(editor.isLocked)
            .accessibilityLabel(tr("Preset name"))
    }

    private var lamps: some View {
        HStack(spacing: 10) {
            if editor.showsOriginal {
                Lamp(tr("A · Saved"), tone: .amber, isOn: true, size: 6)
            } else {
                Lamp(tr("Changed"), tone: .hot, isOn: editor.isModified, size: 6)
                    .accessibilityLabel(editor.isModified ? tr("Changed") : tr("Unchanged"))
            }
            Lamp("Live", tone: .on, isOn: editor.isHeard, size: 6)
                .help(editor.isHeard ? tr("The amp plays this state, changes can be heard at once.")
                                     : tr("The first change sends the preset to the amp, without overwriting a slot."))
                .accessibilityLabel(editor.isHeard ? tr("Live on the amp") : tr("Not on the amp"))
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
                .help(tr("Undo (⌘Z)"))
                .accessibilityLabel(tr("Undo"))
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.hardwareKey())
                .fixedSize()
                .disabled(!editor.canRedo || editor.showsOriginal)
                .help(tr("Redo (⇧⌘Z)"))
                .accessibilityLabel(tr("Redo"))
            Button(editor.showsOriginal ? "A" : "A / B") { editor.toggleComparison() }
                .buttonStyle(.hardwareKey(editor.showsOriginal ? .on : .normal, keycap: "⌘B"))
                .fixedSize()
                .disabled(!editor.isModified && !editor.showsOriginal)
                .help(tr("Compares with the saved state (⌘B)"))
                .accessibilityLabel(tr("Compare with the saved state"))
                .accessibilityValue(editor.showsOriginal ? tr("saved state") : tr("edited state"))
            Button(tr("Save")) { model.saveOnMac() }
                .buttonStyle(.hardwareKey(.primary, keycap: "⌘S"))
                .fixedSize()
                .disabled(editor.showsOriginal)
                .help(tr("Save to this Mac (⌘S)"))
            Menu {
                Button(tr("Save as …")) { model.beginSaveAs() }
                Divider()
                ForEach(Array(link.profile.slots), id: \.self) { slot in
                    Button(storeTitle(slot)) {
                        model.askToStoreEdited(in: slot)
                    }
                    .disabled(!model.canUse(.store))
                }
                Divider()
                Button(tr("Play on the REACTOR …")) { model.askToPlayOnReactor() }
                    .disabled(!model.canPlayOnReactor)
                    .help(tr("Sets the closest amp, gain, tone controls and effects on the connected REACTOR. No preset is transferred, nothing is stored."))
                Button(tr("Copy text for REACTOR")) { model.copyToneText() }
                    .help(tr("Describes the sound in English for “Text to Tone” in the REACTOR app. The REACTOR interprets the text itself."))
                Divider()
                Button(tr("Discard changes")) { editor.revert() }.disabled(!editor.isModified)
                Button(tr("Duplicate")) { model.duplicateCurrent() }
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
            .help(tr("Save as, store on a slot, text for REACTOR, discard, duplicate"))
            .accessibilityLabel(tr("More actions"))
        }
    }

    private var sourceText: String {
        switch editor.source {
        case .slot(let slot): model.origin(slot: slot)
        case .saved: tr("On this Mac")
        case .draft: tr("New, not saved yet")
        case nil: ""
        }
    }

    private func storeTitle(_ slot: Int) -> String {
        let place = link.profile.slotName(slot)
        if let current = link.slots[safe: slot] ?? nil {
            return tr("Store on %@ … (now “%@”)", place, current.name)
        }
        return tr("Store on %@ …", place)
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
