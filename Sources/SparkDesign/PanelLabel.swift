import SwiftUI

/// An engraved caption on a device front: 9.5 to 10 pt bold capitals with 0.09 em letter spacing, in #8E8E96.
///
///     PanelLabel("Level")
///     PanelLabel("Drive · slot 3 of 7", color: accent)
///
/// It is decoration by default and hidden from VoiceOver, because the control next to it carries the label.
/// Pass `isAccessible: true` when the caption is the only place the information appears.
public struct PanelLabel: View {
    let text: String
    var size: CGFloat
    var color: AnyShapeStyle
    var isAccessible: Bool

    public init(_ text: String, size: CGFloat = 9.5, color: some ShapeStyle = Theme.device.engraving,
                isAccessible: Bool = false) {
        self.text = text
        self.size = size
        self.color = AnyShapeStyle(color)
        self.isAccessible = isAccessible
    }

    public var body: some View {
        Text(text.uppercased())
            .font(Theme.Fonts.engraving(size))
            .tracking(Theme.Fonts.engravingTracking(size))
            .foregroundStyle(color)
            .lineLimit(1)
            .accessibilityLabel(text)
            .accessibilityHidden(!isAccessible)
    }
}

/// A caption above a field on the desk: the same capitals as an engraving, but in the system's secondary color.
///
///     DeskCaption("Title, also the file name")
public struct DeskCaption: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}

#Preview("Engraving") {
    PreviewPair {
        VStack(alignment: .leading, spacing: 8) {
            Faceplate {
                HStack(spacing: 16) {
                    PanelLabel("Level")
                    PanelLabel("Source")
                    PanelLabel("Drive · slot 3 of 7", color: Color.orange)
                }
                .padding(14)
            }
            DeskCaption("Title, also the file name")
        }
    }
}
