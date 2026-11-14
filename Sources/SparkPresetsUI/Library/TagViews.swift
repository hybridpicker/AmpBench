import AmpText
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
        .accessibilityLabel([tr("Tag %@", tag), count.map { $0 == 1 ? tr("1 preset") : tr("%d presets", $0) },
                             isOn ? tr("filter on") : nil, isPinned ? tr("pinned") : nil]
            .compactMap { $0 }.joined(separator: ", "))
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
                            .help(tr("Remove #%@", tag))
                            .accessibilityLabel(tr("Remove tag %@", tag))
                        }
                        .contextMenu {
                            Button(model.isPinned(tag) ? tr("Unpin from the sidebar") : tr("Pin to the sidebar")) {
                                model.togglePin(tag)
                            }
                        }
                    }
                    TextField(tr("Add #tag"), text: $newTags)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 130)
                        .onSubmit {
                            model.addTags(newTags, to: item)
                            newTags = ""
                        }
                        .accessibilityLabel(tr("Add tags"))
                }
                Spacer(minLength: 0)
                Button(showsNotes ? tr("Hide notes") : (item.file.notes.isEmpty ? tr("Note …") : tr("Notes"))) {
                    showsNotes.toggle()
                }
                .linkButtonStyle()
                .font(.system(size: 11))
            }
            if showsNotes {
                TextField(tr("Notes: where the sound comes from, what it suits, what to try"), text: $notes,
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
