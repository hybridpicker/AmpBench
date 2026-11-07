import SwiftUI

/// Tabs as a segment on the desk: a recessed bar with the chosen tab raised. It follows the system's appearance.
///
///     SegmentTabs("Ansicht der Bibliothek", selection: $tab, options: [(.recordings, "Aufnahmen"), (.pieces, "Stücke")])
///
/// Each tab is a button; VoiceOver reads the chosen one as selected.
public struct SegmentTabs<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]

    public init(_ label: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.label = label
        _selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .frame(height: 20)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Theme.desk.segmentSelected)
                                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.desk.segmentBack))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.desk.segmentEdge, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

#Preview("Tabs") {
    PreviewPair {
        SegmentTabs("Ansicht", selection: .constant(0), options: [(0, "Aufnahmen"), (1, "Stücke"), (2, "Statistik")])
    }
}
