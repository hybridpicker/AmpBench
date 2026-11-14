import AmpText
import SparkControl
import SparkDesign
import SwiftUI

/// The right column of the library: the selected sound with its chain, facts, tags and notes, what is close to it
/// and which pieces use it, and the keys to hear and open it. With several selected, what can be done to all of
/// them at once.
struct LibraryPreview: View {
    var focus: FocusState<LibraryBrowser.Focus?>.Binding
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var browser: LibraryBrowser

    var body: some View {
        let selected = model.librarySelection
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let item = selected.first, selected.count == 1 {
                    SoundCard(item: item)
                    SoundFacts(item: item)
                    TagEditor(items: selected, focus: focus)
                    NotesEditor(item: item)
                    CloseSounds(item: item)
                    PieceUses(items: selected)
                } else if !selected.isEmpty {
                    SelectionSummary(items: selected)
                    TagEditor(items: selected, focus: focus)
                    PieceUses(items: selected)
                } else {
                    EmptyPreview()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The sound on a small front: name, chain in miniature, and the keys to hear and to open it.
private struct SoundCard: View {
    let item: SavedPreset
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name)
                .font(Theme.Fonts.title(20))
                .foregroundStyle(Theme.device.amber)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Text(ChainSummary.text(item.file.preset))
                .font(.caption)
                .foregroundStyle(Theme.device.labelDim)
                .lineLimit(2)
            ChainMiniature(preset: item.file.preset)
            HStack(spacing: 8) {
                Lamp(tr("Favorite"), tone: .amber, isOn: item.file.favorite)
                Lamp(tr("To listen"), tone: .amber, isOn: item.file.needsListen)
            }
            .padding(.top, 2)
            HStack(spacing: 8) {
                Button(tr("Hear")) { model.hear(item) }
                    .buttonStyle(.hardwareKey(.primary, keycap: LibraryPlatform.hearKeycap, size: .small))
                    .disabled(!model.canUse(.playTemporary))
                    .help(model.canUse(.playTemporary)
                          ? tr("Plays the sound on the amp's temporary place. No slot changes.")
                          : tr("Connect the amp to hear the sound."))
                Button(tr("Open")) { model.openInEditor(item) }
                    .buttonStyle(.hardwareKey(keycap: "⌘↩", size: .small))
                    .help(tr("Opens the sound in the editor and closes the library"))
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FaceplateSurface(radius: Theme.Radius.display))
    }
}

/// Amp, effects, origin, date and tempo as a grid of facts, with the switches for favorite and listening.
private struct SoundFacts: View {
    let item: SavedPreset
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                ForEach(places, id: \.title) { place in
                    GridRow {
                        DeskCaption(place.title)
                        Text(place.model)
                            .foregroundStyle(place.isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .lineLimit(1)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    DeskCaption(tr("Origin"))
                    Text(item.file.origin.isEmpty ? SoundOrigin.of(item).title : item.file.origin)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    DeskCaption(item.file.isBackup ? tr("Backed up") : tr("Saved"))
                    Text(item.file.savedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                        .locale(Texts.locale)))
                        .font(Theme.Fonts.mono(11))
                }
                GridRow {
                    DeskCaption(tr("Tempo"))
                    Text("\(Int(item.file.preset.bpm.rounded())) BPM").font(Theme.Fonts.mono(11))
                }
            }
            .font(.system(size: 12))
            if !item.file.isBackup {
                HStack(spacing: 14) {
                    Toggle(tr("Favorite"), isOn: Binding(get: { item.file.favorite },
                                                         set: { _ in model.toggleFavorite([item]) }))
                    Toggle(tr("To listen"), isOn: Binding(get: { item.file.needsListen },
                                                          set: { _ in model.toggleListen([item]) }))
                }
                .checkboxToggleStyle()
                .font(.system(size: 12))
            }
        }
    }

    private var places: [(title: String, model: String, isOn: Bool)] {
        let effects = item.file.preset.effects
        return effects.enumerated().compactMap { index, effect in
            guard let place = ChainPlace.of(index: index, count: effects.count) else { return nil }
            let name = ModelCatalog.known(effect.name)?.name ?? effect.name
            return (place.shortTitle, effect.isOn ? name : tr("%@ (off)", name), effect.isOn)
        }
    }
}

/// The tags of the selected sounds. With several, a count says how many carry each; × takes it from all of them,
/// and a tag typed below goes to all of them.
private struct TagEditor: View {
    let items: [SavedPreset]
    var focus: FocusState<LibraryBrowser.Focus?>.Binding
    @EnvironmentObject private var model: PresetsModel
    @State private var newTags = ""

    var body: some View {
        let editable = items.filter { !$0.file.isBackup }
        VStack(alignment: .leading, spacing: 6) {
            DeskCaption(tr("Tags"))
            FlowLayout(spacing: 4) {
                ForEach(tags, id: \.tag) { entry in
                    HStack(spacing: 2) {
                        TagChip(tag: entry.tag, count: items.count > 1 ? entry.count : nil,
                                isPinned: model.isPinned(entry.tag))
                        Button {
                            model.removeTag(entry.tag, from: items)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .help(tr("Remove #%@", entry.tag))
                        .accessibilityLabel(tr("Remove tag %@", entry.tag))
                    }
                    .contextMenu {
                        Button(model.isPinned(entry.tag) ? tr("Unpin from the sidebar") : tr("Pin to the sidebar")) {
                            model.togglePin(entry.tag)
                        }
                    }
                }
            }
            if !editable.isEmpty {
                TextField(items.count > 1 ? tr("Add #tag to all") : tr("Add #tag"), text: $newTags)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused(focus, equals: .tags)
                    .onSubmit {
                        model.addTags(newTags, to: editable)
                        newTags = ""
                    }
                    .accessibilityLabel(tr("Add tags"))
            }
        }
    }

    /// Each tag of the selection with how many sounds carry it, most first. The listen mark has its own switch.
    private var tags: [(tag: String, count: Int)] {
        var counts: [String: (spelling: String, count: Int)] = [:]
        var order: [String] = []
        for item in items {
            for tag in item.file.tags where tag.caseInsensitiveCompare(PresetFile.listenTag) != .orderedSame {
                let key = tag.lowercased()
                if counts[key] == nil { order.append(key) }
                counts[key] = (counts[key]?.spelling ?? tag, (counts[key]?.count ?? 0) + 1)
            }
        }
        return order.compactMap { counts[$0] }.map { ($0.spelling, $0.count) }
            .sorted { $0.count > $1.count }
    }
}

private struct NotesEditor: View {
    let item: SavedPreset
    @EnvironmentObject private var model: PresetsModel
    @State private var notes = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if !item.file.isBackup {
            VStack(alignment: .leading, spacing: 6) {
                DeskCaption(tr("Notes"))
                TextField(tr("Where the sound comes from, what it suits, what to try"), text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .lineLimit(2...8)
                    .focused($isFocused)
                    .onSubmit { model.setNotes(notes, of: item) }
                    .onChange(of: isFocused) { _, focused in if !focused { model.setNotes(notes, of: item) } }
            }
            .onAppear { notes = item.file.notes }
            .onChange(of: item.url) { notes = item.file.notes }
            .onChange(of: item.file.notes) { if !isFocused { notes = item.file.notes } }
        }
    }
}

/// Sounds close to this one: the same chain under another name, or a few knobs or one effect apart. A click selects
/// one, so the two can be heard one after the other.
private struct CloseSounds: View {
    let item: SavedPreset
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        let neighbours = PresetSimilarity.neighbours(of: item, in: model.items.filter { !$0.file.isBackup })
        if !neighbours.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                DeskCaption(tr("Close sounds"))
                ForEach(neighbours.prefix(6), id: \.item.url) { neighbour in
                    Button {
                        model.selectInLibrary([neighbour.item])
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(neighbour.item.name).lineLimit(1)
                            Text(Self.difference(neighbour.comparison))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("Selects “%@”", neighbour.item.name))
                }
            }
            .font(.system(size: 12))
        }
    }

    static func difference(_ comparison: PresetSimilarity.Comparison) -> String {
        if comparison.isEqual { return tr("The same sound") }
        return tr("Differs in %@", comparison.differing.map(\.shortTitle).joined(separator: ", "))
    }
}

/// The pieces that name the sounds, so nothing a piece needs goes to the Trash unseen. Shown only where the pieces
/// are known: on the Mac, with AmpBench's recordings.
private struct PieceUses: View {
    let items: [SavedPreset]
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        if model.presetUses != nil {
            let uses = model.pieces(using: items)
            VStack(alignment: .leading, spacing: 4) {
                DeskCaption(tr("Used in pieces"))
                if uses.isEmpty {
                    Text(items.count == 1 ? tr("No piece uses this sound.") : tr("No piece uses these sounds."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(uses, id: \.self) { Text($0).lineLimit(1) }
                }
            }
            .font(.system(size: 12))
        }
    }
}

/// Several sounds: how many, and what can be done to all of them.
private struct SelectionSummary: View {
    let items: [SavedPreset]
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        let amps = Set(items.compactMap(\.file.preset.ampModel)).count
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("%d sounds selected", items.count))
                    .font(Theme.Fonts.title(20))
                    .foregroundStyle(Theme.device.amber)
                Text(amps == 1 ? tr("all on one amp") : tr("on %d amps", amps))
                    .font(.caption)
                    .foregroundStyle(Theme.device.labelDim)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FaceplateSurface(radius: Theme.Radius.display))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(items.allSatisfy(\.file.favorite) ? tr("No favorites") : tr("Favorites")) {
                        model.toggleFavorite(items)
                    }
                    .buttonStyle(.hardwareKey(keycap: "⇧⌘F", size: .small))
                    Button(items.allSatisfy(\.file.needsListen) ? tr("Listened to") : tr("To listen")) {
                        model.toggleListen(items)
                    }
                    .buttonStyle(.hardwareKey(keycap: "⌘K", size: .small))
                }
                HStack(spacing: 8) {
                    Button(tr("Rename …")) { model.beginRenameInLibrary(items) }
                        .buttonStyle(.hardwareKey(keycap: "⌘E", size: .small))
                    Button(tr("To the Trash")) { model.trashInLibrary(items) }
                        .buttonStyle(.hardwareKey(.danger, keycap: "⌘⌫", size: .small))
                }
            }
        }
    }
}

private struct EmptyPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Choose a sound to see it here."))
                .foregroundStyle(.secondary)
            Text(tr("Type to search, ↓ to go to the list. ⌘-click or ⇧-click selects several, to tag, rename or remove them together."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
