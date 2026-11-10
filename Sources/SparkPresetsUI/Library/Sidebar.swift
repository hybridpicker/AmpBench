import SparkControl
import SparkDesign
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

/// Connects or disconnects, next to the connection's state, so it is found where one looks for it.
private struct ConnectKey: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        Button(link.wanted ? "Trennen" : "Verbinden") {
            if link.wanted { model.disconnect() } else { model.start(bluetooth: true) }
        }
        .buttonStyle(.hardwareKey(size: .small))
        .fixedSize()
        .help(link.wanted
            ? "Trennt vom Verstärker, damit die Spark-App am Handy ihn nutzen kann."
            : "Verbindet mit dem Verstärker. Die Spark-App am Handy darf dabei nicht verbunden sein.")
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
            // The device first: the slots below are its slots.
            Section("Gerät") {
                DeviceChoice()
                    .padding(.vertical, 2)
            }
            ForEach(slotSections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.slots, id: \.self) { slot in
                        SlotRow(slot: slot).tag(Selection.slot(slot))
                    }
                }
            }
            if model.selection == .draft {
                Section("Neu") {
                    Label(model.editor.preset?.name ?? "Neues Preset", systemImage: "sparkles")
                        .tag(Selection.draft)
                }
            }
            if !model.tagCounts.isEmpty {
                Section("Tags") {
                    TagFilterBar()
                }
            }
            // Pinned tags first, each a section of its own; a preset may stand in several.
            ForEach(model.pinnedTags, id: \.self) { tag in
                let tagged = model.visibleItems(tagged: tag)
                if !tagged.isEmpty {
                    Section {
                        ForEach(tagged) { LibraryRow(item: $0).tag(Selection.saved($0.url)) }
                    } header: {
                        Text("#\(tag)")
                            .contextMenu { Button("Abschnitt lösen") { model.togglePin(tag) } }
                    }
                }
            }
            Section(model.pinnedTags.isEmpty ? "Auf dem Mac" : "Alle auf dem Mac") {
                if model.items.isEmpty {
                    Text("Noch keine Presets. Sichere einen Platz, lege ein neues an oder übernimm Sounds vom Kemper.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if presets.isEmpty {
                    Text(model.tagFilter.isEmpty ? "Nichts gefunden." : "Kein Preset hat alle gewählten Tags.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(presets) { LibraryRow(item: $0).tag(Selection.saved($0.url)) }
            }
            if !backups.isEmpty {
                Section("Sicherungen") {
                    ForEach(backups) { LibraryRow(item: $0).tag(Selection.saved($0.url)) }
                }
            }
            if !model.unreadable.isEmpty {
                Section("Nicht lesbar") {
                    ForEach(model.unreadable, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
            }
        }
        .modifier(SidebarListStyle())
        .amberSelection()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    ConnectionStatus()
                    Spacer(minLength: 4)
                    ConnectKey()
                    NewPresetMenu()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                // Only while nothing is open in the editor, whose display has its own meter.
                if model.editor.preset == nil {
                    LoadMeter(transfer: link.transfer, height: 4, showsLabel: false)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                }
                Spacer().frame(height: 8)
            }
            .background(.bar)
        }
    }
}

extension Sidebar {
    /// The device's slots, in one section, or one per bank ("Rot", "Grün" on a REACTOR).
    var slotSections: [(title: String, slots: [Int])] {
        let profile = link.profile
        let title = "Am \(profile.displayName)"
        guard let size = profile.bankSize, size > 0, !profile.bankNames.isEmpty else {
            return [(title, Array(profile.slots))]
        }
        return profile.bankNames.enumerated().map { bank, name in
            ("\(title) · \(name)", Array((bank * size)..<min((bank + 1) * size, profile.slotCount)))
        }
    }
}

/// Which device the presets talk to: every known or nearby device with a lamp for being there. Choosing another one
/// ends the current connection first; there is only ever one.
struct DeviceChoice: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        HStack(spacing: 8) {
            DevicePopup("Gerät", value: current) {
                if link.devices.isEmpty {
                    Text("Noch kein Gerät gefunden")
                }
                ForEach(link.devices) { device in
                    Button {
                        model.chooseDevice(device.id)
                    } label: {
                        Label("\(device.name) – \(Self.word(device.presence))",
                              systemImage: device.id == link.chosenID ? "checkmark" : Self.symbol(device.presence))
                    }
                }
                Divider()
                if link.status == .connected {
                    Button(link.isLookingAround ? "Suche in der Nähe …" : "Nach Geräten in der Nähe suchen") {
                        link.lookAround()
                    }
                    .disabled(link.isLookingAround)
                } else {
                    Button(link.wanted ? "Weiter suchen" : "Nach Geräten suchen") { model.start(bluetooth: true) }
                }
            }
            .frame(maxWidth: .infinity)
            LampDot(tone: presence == .connected ? .on : .hot, isOn: presence != .absent)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(Self.word(presence))
    }

    private var chosen: DeviceEntry? { link.devices.first { $0.id == link.chosenID } }

    private var presence: DeviceEntry.Presence { chosen?.presence ?? .absent }

    private var current: String {
        guard let chosen else { return link.devices.isEmpty ? "Kein Gerät gewählt" : "Gerät wählen …" }
        return chosen.name
    }

    static func word(_ presence: DeviceEntry.Presence) -> String {
        switch presence {
        case .connected: "verbunden"
        case .nearby: "in der Nähe"
        case .absent: "nicht da"
        }
    }

    static func symbol(_ presence: DeviceEntry.Presence) -> String {
        switch presence {
        case .connected: "circle.fill"
        case .nearby: "circle.lefthalf.filled"
        case .absent: "circle"
        }
    }
}

/// The system sidebar. Window pictures cannot capture its vibrant text, so they show it as a plain list instead.
private struct SidebarListStyle: ViewModifier {
    func body(content: Content) -> some View {
        if Snapshot.isActive {
            content
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .controlBackgroundColor))
        } else {
            content.listStyle(.sidebar)
        }
    }
}

/// The round key of a slot on the amp: dark with its number in dim amber, or lit amber with a glow while it plays.
private struct SlotKey: View {
    let number: Int
    let isPlaying: Bool

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .foregroundStyle(isPlaying ? Theme.device.primaryText : Theme.device.amberDim)
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(RadialGradient(
                        colors: isPlaying ? [Theme.device.primaryTop.color, Swatch(hex: 0xE69A1E).color]
                                          : [Theme.device.knobTop.color, Theme.device.knobBottom.color],
                        center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: 14))
                    .overlay(Circle().strokeBorder(Theme.device.knobEdge, lineWidth: 1))
                    .shadow(color: isPlaying ? Theme.device.amberHot.color.opacity(0.7) : .clear, radius: 5)
            )
            .accessibilityHidden(true)
    }
}

private struct SlotRow: View {
    let slot: Int
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var link: SparkLink

    private var preset: SparkPreset? { link.slots.indices.contains(slot) ? link.slots[slot] : nil }
    /// A REACTOR's own preset in this slot. It shows like a Spark's: its name, and amp and effects below.
    private var reactorPreset: ReactorPreset? { link.reactorPresets[safe: slot] ?? nil }
    private var shownName: String? { preset?.name ?? reactorPreset?.name }
    private var shownSummary: String? { preset.map(ChainSummary.text) ?? reactorPreset?.summary }
    private var isActive: Bool { link.activeSlot == slot && link.tryingOut == nil && !link.isEditingLive }
    private var number: Int { link.profile.bankSize.map { slot % $0 + 1 } ?? slot + 1 }

    private var emptyText: String {
        guard link.status == .connected else { return "–" }
        // A device that is only listened to never sends its presets.
        return link.profile.can(.read) || link.profile.can(.reactorPresets) ? "Wird gelesen …" : "Inhalt unbekannt"
    }

    private var helpText: String {
        guard link.profile.can(.switchSlot) else {
            return "\(link.profile.slotName(slot)) am \(link.profile.displayName). Spark Studio zeigt, was dort gespeichert ist, und schaltet nicht um."
        }
        return slot < DeviceProfile.largestSlotCount
            ? "Klicken spielt diesen Platz und öffnet ihn zum Bearbeiten (⌘\(slot + 1))"
            : "Klicken spielt diesen Platz und öffnet ihn zum Bearbeiten"
    }

    var body: some View {
        HStack(spacing: 9) {
            SlotKey(number: number, isPlaying: isActive)
            VStack(alignment: .leading, spacing: 1) {
                Text(shownName ?? emptyText)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                Text(shownSummary ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isActive {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.desk.amber)
                    .help("Spielt gerade")
            }
        }
        .padding(.vertical, 2)
        .help(helpText)
        .contextMenu {
            Button("Auf dem Mac sichern") { model.backUp(slot: slot) }.disabled(preset == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(link.profile.slotName(slot)): \(shownName ?? "unbekannt")\(isActive ? ", spielt" : "")")
    }
}

private struct LibraryRow: View {
    let item: SavedPreset
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.file.isBackup ? "clock" : item.isRecipe ? "wand.and.stars" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(item.file.isBackup ? item.file.savedAt.formatted(date: .abbreviated, time: .shortened)
                                        : ChainSummary.text(item.file.preset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !item.file.isBackup, !item.file.tags.isEmpty {
                    Text(item.file.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(Theme.desk.amber)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .help("Klicken spielt das Preset zum Anhören, ohne einen Platz zu überschreiben")
        .contextMenu {
            Menu("Auf Platz speichern") {
                ForEach(Array(model.link.profile.slots), id: \.self) { slot in
                    Button(model.link.profile.slotName(slot)) { model.askToStore(item, in: slot) }
                }
            }
            .disabled(!model.canUse(.store))
            Menu("Tags") {
                ForEach(model.tagCounts, id: \.tag) { entry in
                    Toggle("#\(entry.tag)", isOn: Binding(
                        get: { item.file.tags.contains { $0.caseInsensitiveCompare(entry.tag) == .orderedSame } },
                        set: { _ in model.toggleTag(entry.tag, on: item) }))
                }
                if model.tagCounts.isEmpty { Text("Noch keine Tags. Im Editor unter dem Namen hinzufügen.") }
            }
            .disabled(item.file.isBackup)
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
            Button("KI-Sound …") { model.showsAI = true }
            Button("Vom Kemper übernehmen …") { model.showsKemperImport = true }
            Divider()
            Button("Aktuelles duplizieren") { model.duplicateCurrent() }.disabled(model.editor.preset == nil)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.device.keyText)
                .frame(width: 28, height: 24)
                .background(KeyBody())
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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
        HStack(spacing: 8) {
            LampDot(tone: tone, isOn: isLit)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2) }
            }
            if link.activity != nil { ProgressView().controlSize(.mini) }
        }
        .help(link.activity ?? hint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, detail, link.activity].compactMap { $0 }.joined(separator: ", "))
    }

    private var tone: Lamp.Tone {
        link.status == .connected ? .on : .hot
    }

    /// Green when connected, amber while looking for the amp, dark when Bluetooth cannot be used.
    private var isLit: Bool {
        switch link.status {
        case .connected, .searching, .connecting, .starting: true
        default: false
        }
    }

    private var title: String {
        switch link.status {
        case .starting: "Starte Bluetooth …"
        case .searching: link.chosenID == nil ? "Suche Geräte …" : "Suche \(link.profile.displayName) …"
        case .connecting: "Verbinde …"
        case .connected: link.shownName
        case .unauthorized: "Kein Bluetooth-Zugriff"
        case .bluetoothOff: "Bluetooth ist aus"
        case .unsupported: "Kein Bluetooth LE"
        case .off: "Getrennt"
        }
    }

    private var detail: String? {
        if let activity = link.activity { return activity }
        switch link.status {
        case .connected:
            if !link.profile.canSend {
                return link.profile.can(.liveSound) ? "verbunden · liest mit, Sound auf Wunsch"
                                                    : "verbunden · nur mitlesen, Studio sendet nichts"
            }
            return link.firmware.map { "Firmware \($0) · verbunden" } ?? "verbunden"
        case .searching, .connecting: return "Spark-App am Handy trennen"
        case .off: return "Die Spark-App am Handy kann ihn jetzt nutzen"
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
