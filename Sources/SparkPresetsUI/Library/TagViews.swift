import SparkControl
import SparkDesign
import SwiftUI

/// One tag as a small capsule: "#basis". Lit when it filters the list.
struct TagChip: View {
    let tag: String
    var count: Int?
    var isOn = false
    var isPinned = false

    var body: some View {
        HStack(spacing: 3) {
            if isPinned {
                Image(systemName: "pin.fill").font(.system(size: 7)).accessibilityHidden(true)
            }
            Text("#\(tag)")
            if let count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
        }
        .font(.system(size: 10.5, weight: isOn ? .semibold : .regular))
        .foregroundStyle(isOn ? AnyShapeStyle(Theme.device.primaryText) : AnyShapeStyle(Color.primary))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(isOn ? AnyShapeStyle(Theme.desk.amber) : AnyShapeStyle(Color.secondary.opacity(0.15))))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tag \(tag)\(count.map { ", \($0) Presets" } ?? "")\(isOn ? ", Filter an" : "")\(isPinned ? ", angeheftet" : "")")
    }
}

/// The tags of the library to filter by: a click narrows the list to presets carrying the tag, the context menu pins
/// a tag as a section of its own.
struct TagFilterBar: View {
    static let chipLimit = 8
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        let counts = model.tagCounts
        // Pinned tags, active filters and the most used ones as chips; the rest in a menu, so the list stays in view.
        let shown = counts.enumerated().filter { index, entry in
            index < Self.chipLimit || model.isPinned(entry.tag) || model.isFiltering(by: entry.tag)
        }.map(\.element)
        let more = counts.filter { entry in !shown.contains { $0.tag == entry.tag } }
        if !counts.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(shown, id: \.tag) { entry in
                    Button {
                        model.toggleFilter(entry.tag)
                    } label: {
                        TagChip(tag: entry.tag, count: entry.count, isOn: model.isFiltering(by: entry.tag),
                                isPinned: model.isPinned(entry.tag))
                    }
                    .buttonStyle(.plain)
                    .help("Nur Presets mit #\(entry.tag) zeigen. Rechtsklick: als Abschnitt anheften.")
                    .contextMenu {
                        Button(model.isPinned(entry.tag) ? "Abschnitt lösen" : "Als Abschnitt anheften") {
                            model.togglePin(entry.tag)
                        }
                    }
                }
                if !more.isEmpty {
                    Menu("+ \(more.count) weitere") {
                        ForEach(more, id: \.tag) { entry in
                            Button("#\(entry.tag) (\(entry.count))") { model.toggleFilter(entry.tag) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.system(size: 10.5))
                    .help("Weitere Tags zum Filtern")
                }
                if !model.tagFilter.isEmpty {
                    Button("Alle zeigen") { model.tagFilter = [] }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// The tags and notes of a preset saved on the Mac, below the editor's header. Tags are typed with or without "#",
/// several at once separated by blanks; a click on a tag's × removes it.
struct PresetDetailsBar: View {
    let item: SavedPreset
    @EnvironmentObject private var model: PresetsModel
    @State private var newTags = ""
    @State private var notes = ""
    @State private var showsNotes = false
    @FocusState private var notesFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "number").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                FlowLayout(spacing: 4) {
                    ForEach(item.file.tags, id: \.self) { tag in
                        HStack(spacing: 2) {
                            TagChip(tag: tag, isPinned: model.isPinned(tag))
                            Button {
                                model.removeTag(tag, from: item)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.borderless)
                            .help("#\(tag) entfernen")
                            .accessibilityLabel("Tag \(tag) entfernen")
                        }
                        .contextMenu {
                            Button(model.isPinned(tag) ? "Abschnitt lösen" : "Als Abschnitt anheften") {
                                model.togglePin(tag)
                            }
                        }
                    }
                    TextField("#tag hinzufügen", text: $newTags)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 130)
                        .onSubmit {
                            model.addTags(newTags, to: item)
                            newTags = ""
                        }
                        .accessibilityLabel("Tags hinzufügen")
                }
                Spacer(minLength: 0)
                Button(showsNotes ? "Notizen ausblenden" : (item.file.notes.isEmpty ? "Notiz …" : "Notizen")) {
                    showsNotes.toggle()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            if showsNotes {
                TextField("Notizen: woher der Sound kommt, wofür er passt, was zu probieren ist", text: $notes,
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .lineLimit(2...6)
                    .focused($notesFocused)
                    .onSubmit { model.setNotes(notes, of: item) }
                    .onChange(of: notesFocused) { _, focused in if !focused { model.setNotes(notes, of: item) } }
            }
        }
        .onAppear { notes = item.file.notes }
        .onChange(of: item.url) { notes = item.file.notes; newTags = "" }
        .onChange(of: item.file.notes) { if !notesFocused { notes = item.file.notes } }
    }
}

/// Lays chips out in lines, wrapping when the width is used up.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
