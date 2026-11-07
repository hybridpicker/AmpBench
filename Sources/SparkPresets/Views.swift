import SparkControl
import SwiftUI

enum Palette {
    static let display = Color(white: 0.07)
    static let displayText = Color(red: 0.98, green: 0.76, blue: 0.36)
    static let displayDim = Color(red: 0.70, green: 0.60, blue: 0.45)
    static let active = Color(red: 0.98, green: 0.62, blue: 0.16)
    static let on = Color(red: 0.25, green: 0.78, blue: 0.38)
    static let off = Color(white: 0.5)
    static let lampOff = Color(white: 0.2)
}

/// Names for the seven places of the amp's signal chain.
enum Chain {
    static let places = ["Noise Gate", "Kompressor", "Verzerrer", "Amp", "Modulation", "Delay", "Hall"]

    static func place(_ index: Int, of count: Int) -> String {
        count == places.count && index < places.count ? places[index] : "Effekt \(index + 1)"
    }

    /// The amp's model ids, made readable where that is safe: "bias.reverb" becomes "Reverb".
    static func model(_ name: String) -> String {
        guard name.hasPrefix("bias.") else { return name }
        let rest = name.dropFirst(5)
        return rest == "noisegate" ? "Noise Gate" : rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// A short line for a card: the amp and the effects that are on, gate and reverb aside.
    static func summary(_ preset: SparkPreset) -> String {
        let effects = preset.effects
        guard effects.count == places.count else { return effects.filter(\.isOn).map { model($0.name) }.joined(separator: " · ") }
        var parts = [model(effects[3].name)]
        parts += [1, 2, 4, 5].filter { effects[$0].isOn }.map { model(effects[$0].name) }
        return parts.joined(separator: " · ")
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            SlotStrip()
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            Divider()
            HSplitView {
                LibraryList()
                    .frame(minWidth: 230, idealWidth: 280, maxWidth: 380)
                DetailPane()
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) { BannerView().padding(14) }
        .sheet(item: $model.renameTarget) { _ in RenameSheet() }
        .confirmationDialog(storeTitle, isPresented: storeDialogShown, presenting: model.storeRequest) { request in
            Button("Auf Platz \(request.slot + 1) speichern") { model.store(request) }
            Button("Abbrechen", role: .cancel) { model.storeRequest = nil }
        } message: { request in
            Text("Was jetzt auf Platz \(request.slot + 1) liegt\(slotName(request.slot)), wird vorher frisch vom Verstärker gelesen und auf dem Mac gesichert.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reloadLibrary()
        }
    }

    private var storeDialogShown: Binding<Bool> {
        Binding(get: { model.storeRequest != nil }, set: { if !$0 { model.storeRequest = nil } })
    }

    private var storeTitle: String {
        guard let request = model.storeRequest else { return "" }
        return "„\(request.item.name)“ auf Platz \(request.slot + 1) speichern?"
    }

    private func slotName(_ slot: Int) -> String {
        link.slots[slot].map { ", „\($0.name)“" } ?? ""
    }
}

// MARK: Status

private struct StatusBar: View {
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(lampColor)
                .frame(width: 9, height: 9)
                .shadow(color: link.status == .connected ? Palette.on.opacity(0.8) : .clear, radius: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let activity = link.activity {
                ProgressView().controlSize(.small)
                Text(activity).font(.callout).foregroundStyle(.secondary)
            }
            if link.status == .unauthorized {
                Button("Systemeinstellungen öffnen") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var lampColor: Color {
        switch link.status {
        case .connected: Palette.on
        case .searching, .connecting, .starting: Palette.active
        default: Color.red
        }
    }

    private var title: String {
        switch link.status {
        case .starting: "Starte Bluetooth …"
        case .searching: "Suche den Verstärker …"
        case .connecting: "Verbinde mit \(link.deviceName ?? "dem Verstärker") …"
        case .connected: "Verbunden mit \(link.deviceName ?? "dem Verstärker")"
        case .unauthorized: "Kein Zugriff auf Bluetooth"
        case .bluetoothOff: "Bluetooth ist aus"
        case .unsupported: "Dieser Mac hat kein Bluetooth LE"
        }
    }

    private var detail: String? {
        switch link.status {
        case .searching, .connecting:
            "Der Verstärker muss eingeschaltet sein, und die Spark-App am Handy darf nicht verbunden sein."
        case .connected:
            link.firmware.map { "Firmware \($0)" }
        case .unauthorized:
            "Erlaube Spark Presets den Zugriff unter Datenschutz & Sicherheit → Bluetooth."
        case .bluetoothOff:
            "Schalte Bluetooth im Kontrollzentrum ein."
        default:
            nil
        }
    }
}

// MARK: Slots

private struct SlotStrip: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AM VERSTÄRKER").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let name = link.tryingOut {
                    Label("Zum Ausprobieren spielt „\(name)“", systemImage: "headphones")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.active)
                }
            }
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { slot in
                    SlotCard(slot: slot)
                }
            }
        }
    }
}

private struct SlotCard: View {
    let slot: Int
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var link: SparkLink

    private var preset: SparkPreset? { link.slots[slot] }
    private var isActive: Bool { link.activeSlot == slot && link.tryingOut == nil }
    private var isSelected: Bool { model.selection == .slot(slot) }

    var body: some View {
        Button {
            model.play(slot: slot)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("\(slot + 1)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(isActive ? Color.black : Palette.displayDim)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(isActive ? Palette.active : Palette.lampOff))
                    if isActive {
                        Text("SPIELT").font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Palette.active)
                    }
                    Spacer(minLength: 0)
                }
                Text(preset?.name ?? (link.status == .connected ? "Wird gelesen …" : "–"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(preset == nil ? Palette.displayDim : Palette.displayText)
                    .lineLimit(1)
                Text(preset.map(Chain.summary) ?? " ")
                    .font(.caption)
                    .foregroundStyle(Palette.displayDim)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.display))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : (isActive ? Palette.active : Color.white.opacity(0.08)),
                                  lineWidth: isSelected || isActive ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(link.status != .connected)
        .contextMenu {
            Button("Spielen") { model.play(slot: slot) }
            Button("Auf dem Mac sichern") { model.backUp(slot: slot) }.disabled(preset == nil)
        }
        .accessibilityLabel("Platz \(slot + 1): \(preset?.name ?? "unbekannt")\(isActive ? ", spielt" : "")")
        .accessibilityHint("Schaltet auf dieses Preset")
    }
}

// MARK: Library

private struct LibraryList: View {
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AUF DEM MAC").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.reveal(nil)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Ordner im Finder zeigen")
                .accessibilityLabel("Ordner im Finder zeigen")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            TextField("Suchen", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            let presets = model.visibleItems.filter { !$0.file.isBackup }
            let backups = model.visibleItems.filter(\.file.isBackup)
            List(selection: $model.selection) {
                if model.items.isEmpty {
                    Text("Noch keine Presets auf dem Mac. Wähle oben einen Platz und sichere ihn mit ⌘S.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                }
                if !presets.isEmpty {
                    Section("Presets") {
                        ForEach(presets) { LibraryRow(item: $0).tag(Selection.saved($0.url)) }
                    }
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
        }
    }
}

private struct LibraryRow: View {
    let item: SavedPreset
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).lineLimit(1)
            Text(item.file.savedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
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

// MARK: Detail

private struct DetailPane: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        Group {
            if let slot = model.selectedSlot {
                if let preset = link.slots[slot] {
                    PresetDetail(preset: preset, subtitle: model.origin(slot: slot)) {
                        Button("Spielen") { model.play(slot: slot) }
                            .disabled(!model.canUseAmp || (link.activeSlot == slot && link.tryingOut == nil))
                        Button("Auf dem Mac sichern") { model.backUp(slot: slot) }
                    }
                } else {
                    placeholder("Platz \(slot + 1) ist noch nicht gelesen.")
                }
            } else if let item = model.selectedItem {
                PresetDetail(preset: item.file.preset, subtitle: subtitle(item)) {
                    Button("Ausprobieren") { model.tryOut(item) }
                        .disabled(!model.canUseAmp)
                        .help("Spielt das Preset, ohne einen Platz zu überschreiben")
                    Menu("Auf Platz speichern") {
                        ForEach(0..<4, id: \.self) { slot in
                            Button("Platz \(slot + 1)\(link.slots[slot].map { " – \($0.name)" } ?? "")") {
                                model.askToStore(item, in: slot)
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(!model.canUseAmp)
                    Button("Umbenennen …") { model.beginRename(item) }
                    Button("In den Papierkorb") { model.trash(item) }
                }
            } else {
                placeholder("Wähle oben einen Platz am Verstärker oder links ein Preset auf dem Mac.")
            }
        }
    }

    private func subtitle(_ item: SavedPreset) -> String {
        let date = item.file.savedAt.formatted(date: .long, time: .shortened)
        return item.file.origin.isEmpty ? "Gesichert am \(date)" : "\(item.file.origin) · gesichert am \(date)"
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PresetDetail<Actions: View>: View {
    let preset: SparkPreset
    let subtitle: String
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    if !preset.description.isEmpty {
                        Text(preset.description).font(.callout).textSelection(.enabled)
                    }
                }
                HStack(spacing: 8) { actions }
                VStack(spacing: 0) {
                    ForEach(Array(preset.effects.enumerated()), id: \.offset) { index, effect in
                        EffectRow(place: Chain.place(index, of: preset.effects.count), effect: effect)
                        if index < preset.effects.count - 1 { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                Text("Die Regler sind so nummeriert, wie der Verstärker sie meldet. Ihre Namen kennt nur die Spark-App.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}

private struct EffectRow: View {
    let place: String
    let effect: SparkPreset.Effect

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(place.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(Chain.model(effect.name)).font(.body.weight(.medium))
                Text(effect.isOn ? "AN" : "AUS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundStyle(effect.isOn ? Color.black : Color.secondary)
                    .background(Capsule().fill(effect.isOn ? Palette.on : Color.secondary.opacity(0.18)))
            }
            .frame(width: 150, alignment: .leading)
            VStack(spacing: 4) {
                ForEach(effect.parameters, id: \.index) { parameter in
                    HStack(spacing: 6) {
                        Text("\(parameter.index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        ParameterBar(value: Double(parameter.value), isOn: effect.isOn)
                        Text("\(Int((parameter.value * 100).rounded()))")
                            .font(.caption.monospacedDigit())
                            .frame(width: 28, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Regler \(parameter.index + 1): \(Int((parameter.value * 100).rounded())) Prozent")
                }
            }
        }
        .padding(10)
        .opacity(effect.isOn ? 1 : 0.6)
    }
}

private struct ParameterBar: View {
    let value: Double
    let isOn: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(isOn ? Palette.active : Palette.off)
                    .frame(width: max(4, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

// MARK: Banner and sheets

private struct BannerView: View {
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        if let banner = model.banner {
            HStack(spacing: 10) {
                Image(systemName: icon(banner.kind)).foregroundStyle(color(banner.kind))
                Text(banner.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let undo = banner.undo {
                    Button("Rückgängig") { undo() }
                }
                Button {
                    model.banner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Schließen")
            }
            .padding(12)
            .frame(maxWidth: 640)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .shadow(radius: 8, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func icon(_ kind: Banner.Kind) -> String {
        switch kind {
        case .info: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(_ kind: Banner.Kind) -> Color {
        switch kind {
        case .info: Palette.on
        case .warning: Palette.active
        case .error: .red
        }
    }
}

private struct RenameSheet: View {
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preset umbenennen").font(.headline)
            TextField("Name", text: $model.renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { model.commitRename() }
            Text("Höchstens \(PresetLibrary.nameLimit) Zeichen. Der Name gilt auch auf dem Verstärker, sobald das Preset auf einem Platz gespeichert wird.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 300, alignment: .leading)
            HStack {
                Spacer()
                Button("Abbrechen") { model.renameTarget = nil }.keyboardShortcut(.cancelAction)
                Button("Umbenennen") { model.commitRename() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
