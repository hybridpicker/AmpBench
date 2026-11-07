import SparkControl
import SwiftUI

/// A short line for a preset: the amp and the effects that are on, gate and reverb aside.
enum ChainSummary {
    static func text(_ preset: SparkPreset) -> String {
        let names = preset.effects.enumerated().map { index, effect in
            (ChainPlace.of(index: index, count: preset.effects.count),
             ModelCatalog.known(effect.name)?.name ?? effect.name, effect.isOn)
        }
        let amp = names.first { $0.0 == .amp }.map { [$0.1] } ?? []
        let effects = names.filter { $0.2 && [.compressor, .drive, .modulation, .delay].contains($0.0) }.map(\.1)
        return (amp + effects).joined(separator: " · ")
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        let selection = Binding(get: { model.selection }, set: { model.select($0) })
        let presets = model.visibleItems.filter { !$0.file.isBackup }
        let backups = model.visibleItems.filter(\.file.isBackup)
        List(selection: selection) {
            Section("Am Verstärker") {
                ForEach(0..<4, id: \.self) { slot in
                    SlotRow(slot: slot).tag(Selection.slot(slot))
                }
            }
            if model.selection == .draft {
                Section("Neu") {
                    Label(model.editor.preset?.name ?? "Neues Preset", systemImage: "sparkles")
                        .tag(Selection.draft)
                }
            }
            Section("Auf dem Mac") {
                if model.items.isEmpty {
                    Text("Noch keine Presets. Sichere einen Platz oder lege ein neues an.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(presets) { LibraryRow(item: $0).tag(Selection.saved($0.url)) }
            }
            if !backups.isEmpty {
                Section("Sicherungen vor dem Überschreiben") {
                    ForEach(backups) { LibraryRow(item: $0).tag(Selection.saved($0.url)) }
                }
            }
            if !model.unreadable.isEmpty {
                Section("Nicht lesbar") {
                    ForEach(model.unreadable, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(Snapshot.isActive ? .hidden : .automatic)
        .background(Snapshot.isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .searchable(text: $model.search, placement: .sidebar, prompt: "Presets suchen")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    ConnectionStatus()
                    Spacer(minLength: 4)
                    NewPresetMenu()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}

private struct SlotRow: View {
    let slot: Int
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var link: SparkLink

    private var preset: SparkPreset? { link.slots[slot] }
    private var isActive: Bool { link.activeSlot == slot && link.tryingOut == nil && !link.isEditingLive }

    var body: some View {
        HStack(spacing: 9) {
            Text("\(slot + 1)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(isActive ? Color.black : Theme.amberDim)
                .frame(width: 20, height: 20)
                .background(Circle().fill(isActive ? Theme.amberHot : Theme.lampOff))
                .shadow(color: isActive ? Theme.amberHot.opacity(0.7) : .clear, radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset?.name ?? (link.status == .connected ? "Wird gelesen …" : "–"))
                    .lineLimit(1)
                Text(preset.map(ChainSummary.text) ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                model.play(slot: slot)
            } label: {
                Image(systemName: isActive ? "speaker.wave.2.fill" : "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isActive ? Theme.amberHot : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canUseAmp || isActive)
            .help(isActive ? "Spielt gerade" : "Diesen Platz spielen (⌘\(slot + 1))")
            .accessibilityLabel(isActive ? "Spielt gerade" : "Platz \(slot + 1) spielen")
        }
        .contextMenu {
            Button("Spielen") { model.play(slot: slot) }.disabled(!model.canUseAmp)
            Button("Auf dem Mac sichern") { model.backUp(slot: slot) }.disabled(preset == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Platz \(slot + 1): \(preset?.name ?? "unbekannt")\(isActive ? ", spielt" : "")")
    }
}

private struct LibraryRow: View {
    let item: SavedPreset
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.name).lineLimit(1)
            Text(ChainSummary.text(item.file.preset))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contextMenu {
            Button("Ausprobieren") { model.tryOut(item) }.disabled(!model.canUseAmp)
            Menu("Auf Platz speichern") {
                ForEach(0..<4, id: \.self) { slot in
                    Button("Platz \(slot + 1)") { model.askToStore(item, in: slot) }
                }
            }
            .disabled(!model.canUseAmp)
            Divider()
            Button("Umbenennen …") { model.beginRename(item) }
            Button("Im Finder zeigen") { model.reveal(item) }
            Button("In den Papierkorb") { model.trash(item) }
        }
    }
}

private struct NewPresetMenu: View {
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        Menu {
            Button("Leeres Preset") { model.newPreset() }
            Button("Aus Vorlage …") { model.showsTemplates = true }
            Divider()
            Button("Aktuelles duplizieren") { model.duplicateCurrent() }.disabled(model.editor.preset == nil)
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Neues Preset")
        .accessibilityLabel("Neues Preset")
    }
}

/// The connection's lamp and state, at the foot of the sidebar.
struct ConnectionStatus: View {
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(lamp)
                .frame(width: 8, height: 8)
                .shadow(color: link.status == .connected ? Theme.on.opacity(0.8) : .clear, radius: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            }
            if link.activity != nil { ProgressView().controlSize(.mini) }
        }
        .help(link.activity ?? hint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, detail, link.activity].compactMap { $0 }.joined(separator: ", "))
    }

    private var lamp: Color {
        switch link.status {
        case .connected: Theme.on
        case .searching, .connecting, .starting: Theme.amberHot
        default: .red
        }
    }

    private var title: String {
        switch link.status {
        case .starting: "Starte Bluetooth …"
        case .searching: "Suche den Verstärker …"
        case .connecting: "Verbinde …"
        case .connected: link.deviceName ?? "Verbunden"
        case .unauthorized: "Kein Bluetooth-Zugriff"
        case .bluetoothOff: "Bluetooth ist aus"
        case .unsupported: "Kein Bluetooth LE"
        }
    }

    private var detail: String? {
        if let activity = link.activity { return activity }
        switch link.status {
        case .connected: return link.firmware.map { "Firmware \($0)" }
        case .searching, .connecting: return "Spark-App am Handy trennen"
        default: return nil
        }
    }

    private var hint: String {
        switch link.status {
        case .searching, .connecting:
            "Der Verstärker muss eingeschaltet sein, und die Spark-App am Handy darf nicht verbunden sein."
        case .unauthorized: "Erlaube den Zugriff unter Systemeinstellungen → Datenschutz & Sicherheit → Bluetooth."
        default: ""
        }
    }
}
