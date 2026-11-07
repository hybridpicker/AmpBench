import SwiftUI

/// A sheet with a front panel on top: its title engraved on a dark strip. The content stays system text.
///
///     SheetPanel("Tastaturkürzel") { Text("…") }
public struct SheetPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Faceplate {
                HStack {
                    PanelLabel(title, size: 10, isAccessible: true)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: 36)
            }
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(20)
        }
    }
}

#Preview("SheetPanel") {
    SheetPanel("Tastaturkürzel") {
        Text("Einzelne Tasten wirken nicht, solange du in ein Textfeld schreibst.")
    }
    .frame(width: 420)
}
