import AmpText
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
        Button(link.wanted ? tr("Disconnect") : tr("Connect")) {
            if link.wanted { model.disconnect() } else { model.start(bluetooth: true) }
        }
        .buttonStyle(.hardwareKey(size: .small))
        .fixedSize()
        .help(link.wanted
            ? tr("Disconnects from the amp, so the Spark app on the phone can use it.")
            : tr("Connects to the amp. The Spark app on the phone must not be connected then."))
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        let selection = Binding(get: { model.selection }, set: { model.select($0) })
        let favorites = model.favoriteItems
        let recent = model.recentItems
        List(selection: selection) {
            // Where the search used to be: the way into the library, always in view.
            if !model.items.isEmpty {
                LibrarySearchEntry(count: soundCount)
            }
            // The device first: the slots below are its slots.
            Section(tr("Device")) {
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
                Section(tr("New")) {
                    Label(model.editor.preset?.name ?? tr("New preset"), systemImage: "sparkles")
                        .tag(Selection.draft)
                }
            }
            // A few sounds at hand; everything else is in the library, which opens over the window.
            if !favorites.isEmpty {
                Section(tr("Favorites")) {
                    ForEach(favorites.prefix(Self.favoriteLimit)) { SoundRow(item: $0).tag(Selection.saved($0.url)) }
                    if favorites.count > Self.favoriteLimit {
                        LibraryEntry(title: tr("%d more favorites", favorites.count - Self.favoriteLimit),
                                     symbol: "star", count: nil, filter: .scope(.favorites))
                    }
                }
            }
            if !recent.isEmpty {
                Section(tr("Recently used")) {
                    ForEach(recent) { SoundRow(item: $0).tag(Selection.saved($0.url)) }
                }
            }
            Section(tr("Library")) {
                if model.items.isEmpty {
                    Text(tr("No presets yet. Save a slot, create a new one or import sounds from the Kemper."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LibraryEntry(title: tr("All sounds"), symbol: "square.grid.2x2", count: soundCount, filter: nil)
                    ForEach(model.pinnedTags, id: \.self) { tag in
                        let count = model.items.filter { item in
                            !item.file.isBackup && item.file.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                        }.count
                        if count > 0 {
                            LibraryEntry(title: "#\(tag)", symbol: "number", count: count, filter: .tag(tag))
                                .contextMenu { Button(tr("Unpin from the sidebar")) { model.togglePin(tag) } }
                        }
                    }
                    let toListen = model.items.filter { !$0.file.isBackup && $0.file.needsListen }.count
                    if toListen > 0 {
                        LibraryEntry(title: tr("To listen"), symbol: "ear", count: toListen, filter: .scope(.toListen))
                    }
                    let backups = model.items.filter(\.file.isBackup).count
                    if backups > 0 {
                        LibraryEntry(title: tr("Slot backups"), symbol: "clock", count: backups,
                                     filter: .scope(.backups))
                    }
                }
                if !model.unreadable.isEmpty {
                    LibraryEntry(title: model.unreadable.count == 1 ? tr("1 file unreadable")
                                     : tr("%d files unreadable", model.unreadable.count),
                                 symbol: "exclamationmark.triangle", count: nil, filter: nil)
                }
            }
        }
        .modifier(SidebarListStyle())
        .amberSelection()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Group {
                    #if os(macOS)
                    HStack(spacing: 8) {
                        ConnectionStatus()
                        Spacer(minLength: 4)
                        ConnectKey()
                        NewPresetMenu()
                    }
                    #else
                    // The iPad's sidebar is narrower inside: the state gets its own line, the keys the next.
                    VStack(alignment: .leading, spacing: 8) {
                        ConnectionStatus()
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            ConnectKey()
                            NewPresetMenu()
                        }
                    }
                    #endif
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                // The sound store, under the connection: the two places a sound can go to from here.
                StoreStatus()
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
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
    /// Favorites shown in the sidebar; more of them are a click away, in the library.
    static let favoriteLimit = 8

    private var soundCount: Int { model.items.filter { !$0.file.isBackup }.count }

    /// The device's slots, in one section, or one per bank ("Red", "Green" on a REACTOR).
    var slotSections: [(title: String, slots: [Int])] {
        let profile = link.profile
        let title = tr("On the %@", profile.displayName)
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
            DevicePopup(tr("Device"), value: current) {
                if link.devices.isEmpty {
                    Text(tr("No device found yet"))
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
                    Button(link.isLookingAround ? tr("Searching nearby …") : tr("Search for devices nearby")) {
                        link.lookAround()
                    }
                    .disabled(link.isLookingAround)
                } else {
                    Button(link.wanted ? tr("Keep searching") : tr("Search for devices")) { model.start(bluetooth: true) }
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
        guard let chosen else { return link.devices.isEmpty ? tr("No device chosen") : tr("Choose device …") }
        return chosen.name
    }

    static func word(_ presence: DeviceEntry.Presence) -> String {
        switch presence {
        case .connected: tr("connected")
        case .nearby: tr("nearby")
        case .absent: tr("not there")
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

/// The system sidebar, also for the library's filters. Window pictures cannot capture its vibrant text, so they show
/// it as a plain list instead.
struct SidebarListStyle: ViewModifier {
    func body(content: Content) -> some View {
        if Snapshot.isActive {
            content
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color.systemControlBackground)
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
        return link.profile.can(.read) || link.profile.can(.reactorPresets) ? tr("Reading …") : tr("Content unknown")
    }

    private var helpText: String {
        guard link.profile.can(.switchSlot) else {
            return tr("%1$@ on the %2$@. AmpBench shows what is stored there and does not switch.", link.profile.slotName(slot), link.profile.displayName)
        }
        return slot < DeviceProfile.largestSlotCount
            ? tr("Clicking plays this slot and opens it for editing (⌘%d)", slot + 1)
            : tr("Clicking plays this slot and opens it for editing")
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
                    .help(tr("Playing now"))
            }
        }
        .padding(.vertical, 2)
        .help(helpText)
        .contextMenu {
            Button(tr("Save to this Mac")) { model.backUp(slot: slot) }.disabled(preset == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isActive ? tr("%@: %@, playing", link.profile.slotName(slot), shownName ?? tr("unknown"))
                                     : tr("%@: %@", link.profile.slotName(slot), shownName ?? tr("unknown")))
    }
}

private struct SoundRow: View {
    let item: SavedPreset
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.file.isBackup ? "clock" : item.isRecipe ? "wand.and.stars" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(Color.systemSecondaryLabel)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(item.file.isBackup ? item.file.savedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Texts.locale))
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
        .help(tr("Clicking plays the preset for listening, without overwriting a slot"))
        .contextMenu {
            RowMenu(items: [item])
            Divider()
            Button(tr("Show in the library")) {
                model.openLibrary()
                model.selectInLibrary([item])
            }
        }
    }
}

/// A field-like key at the top of the sidebar that opens the library with its search in focus.
private struct LibrarySearchEntry: View {
    let count: Int
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        Button {
            model.openLibrary(nil)
            model.browser.filters = []
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(tr("Search %d sounds", count)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                // On the desk, not a keycap: keycaps belong to the device and fade on the light desk.
                Text("⌘L").font(Theme.Fonts.mono(10.5)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("Library"))
        .accessibilityHint(tr("Opens the library"))
        .accessibilityIdentifier("library-entry")
        .help(tr("Opens the library, to find, hear and look after every sound (⌘L)"))
    }
}

/// A way into the library from the sidebar: all sounds, a pinned tag, the sounds to listen to, the backups.
private struct LibraryEntry: View {
    let title: String
    let symbol: String
    let count: Int?
    let filter: LibraryFilter?
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        Button {
            model.openLibrary(filter)
            if filter == nil { model.browser.filters = [] }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.systemSecondaryLabel)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)").font(Theme.Fonts.mono(11)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-entry-\(title)")
        .help(tr("Opens the library"))
        .accessibilityHint(tr("Opens the library"))
    }
}

private struct NewPresetMenu: View {
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        Menu {
            Button(tr("Empty preset")) { model.newPreset() }
            Button(tr("From template …")) { model.showsTemplates = true }
            Divider()
            Button(tr("AI Sound …")) { model.showsAI = true }
            Button(tr("Import from Kemper …")) { model.showsKemperImport = true }
            Divider()
            Button(tr("Duplicate current")) { model.duplicateCurrent() }.disabled(model.editor.preset == nil)
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
        .help(tr("New preset"))
        .accessibilityLabel(tr("New preset"))
        .accessibilityIdentifier("new-preset-menu")
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
        case .starting: tr("Starting Bluetooth …")
        case .searching: link.chosenID == nil ? tr("Searching for devices …") : tr("Searching for %@ …", link.profile.displayName)
        case .connecting: tr("Connecting …")
        case .connected: link.shownName
        case .unauthorized: tr("No Bluetooth access")
        case .bluetoothOff: tr("Bluetooth is off")
        case .unsupported: tr("No Bluetooth LE")
        case .off: tr("Disconnected")
        }
    }

    private var detail: String? {
        if let activity = link.activity { return activity }
        switch link.status {
        case .connected:
            if !link.profile.canSend {
                if link.profile.can(.store) { return tr("connected") }
                return link.profile.can(.liveSound) ? tr("connected · reading along, sound on request")
                                                    : tr("connected · read only, AmpBench sends nothing")
            }
            return link.firmware.map { tr("Firmware %@ · connected", $0) } ?? tr("connected")
        case .searching, .connecting: return tr("Disconnect the Spark app on the phone")
        case .off: return tr("The Spark app on the phone can use it now")
        default: return nil
        }
    }

    private var hint: String {
        switch link.status {
        case .searching, .connecting:
            tr("The amp must be switched on, and the Spark app on the phone must not be connected.")
        case .unauthorized: tr("Allow access in System Settings → Privacy & Security → Bluetooth.")
        default: ""
        }
    }
}
