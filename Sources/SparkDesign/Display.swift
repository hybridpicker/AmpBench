import SwiftUI

/// The display of a device: warm black behind glass, with an inner shadow. Text on it is amber only, in
/// `Theme.device.amber`, `.amberDim` and `.amberHot`.
///
///     Display {
///         Text("00:08,4").font(Theme.Fonts.mono(34, weight: .semibold)).foregroundStyle(Theme.device.amber)
///     }
///
/// `isAlert` gives it the red edge of a running recording.
public struct Display<Content: View>: View {
    var radius: CGFloat
    var padding: EdgeInsets
    var isAlert: Bool
    @ViewBuilder let content: Content

    public init(radius: CGFloat = Theme.Radius.display,
                padding: EdgeInsets = EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12),
                isAlert: Bool = false, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.padding = padding
        self.isAlert = isAlert
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(DisplayGlass(radius: radius, isAlert: isAlert))
    }
}

/// The glass of a display without content, for drawing on it directly.
public struct DisplayGlass: View {
    var radius: CGFloat
    var isAlert: Bool

    public init(radius: CGFloat = Theme.Radius.display, isAlert: Bool = false) {
        self.radius = radius
        self.isAlert = isAlert
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        shape
            .fill(Theme.device.display)
            // The inner shadow: darker at the top edge, as if the glass sat a little deeper than the front.
            .overlay(shape.fill(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top,
                                               endPoint: UnitPoint(x: 0.5, y: 0.25))))
            .overlay(shape.strokeBorder(isAlert ? AnyShapeStyle(Theme.device.record) : AnyShapeStyle(Theme.device.displayEdge),
                                        lineWidth: isAlert ? 2 : 1))
            .shadow(color: Theme.device.faceHighlight.color, radius: 0, y: 1)
            .accessibilityHidden(true)
    }
}

#Preview("Anzeige") {
    PreviewPair {
        Faceplate {
            HStack(spacing: 14) {
                Display {
                    VStack(alignment: .leading, spacing: 2) {
                        Lamp("Bereit", isOn: true, textSize: 13)
                        Text("00:00,0").font(Theme.Fonts.mono(26, weight: .semibold)).foregroundStyle(Theme.device.amber)
                        Text("Taste R nimmt auf").font(Theme.Fonts.mono(10)).foregroundStyle(Theme.device.amberDim)
                    }
                }
                Display(isAlert: true) {
                    Text("00:12,8").font(Theme.Fonts.mono(26, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .padding(14)
        }
    }
}
