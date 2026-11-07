import SwiftUI

/// A device front: a dark brushed gradient with a light edge on top and a black edge below. Modules on it are
/// separated by `EngravedDivider`.
///
///     Faceplate {
///         HStack(spacing: 0) {
///             module1
///             EngravedDivider()
///             module2
///         }
///     }
///
/// `radius` 0 is a strip across the window, such as the deck; 14 is a device or panel standing on its own.
public struct Faceplate<Content: View>: View {
    var radius: CGFloat
    var top: Swatch
    var bottom: Swatch
    @ViewBuilder let content: Content

    public init(radius: CGFloat = 0, top: Swatch = Theme.device.faceTop, bottom: Swatch = Theme.device.faceBottom,
                @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.top = top
        self.bottom = bottom
        self.content = content()
    }

    public var body: some View {
        content
            .background(FaceplateSurface(radius: radius, top: top, bottom: bottom))
    }
}

/// The surface of a front without content.
public struct FaceplateSurface: View {
    var radius: CGFloat
    var top: Swatch
    var bottom: Swatch

    public init(radius: CGFloat = 0, top: Swatch = Theme.device.faceTop, bottom: Swatch = Theme.device.faceBottom) {
        self.radius = radius
        self.top = top
        self.bottom = bottom
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        shape
            .fill(LinearGradient(colors: [top.color, bottom.color], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                if radius == 0 {
                    Rectangle().fill(Theme.device.faceHighlight).frame(height: 1)
                }
            }
            .overlay(alignment: .bottom) {
                if radius == 0 {
                    Rectangle().fill(Theme.device.faceEdge).frame(height: 1)
                }
            }
            .overlay {
                if radius > 0 {
                    shape.strokeBorder(Theme.device.faceEdge, lineWidth: 1)
                    shape.inset(by: 1).stroke(LinearGradient(colors: [Swatch.white(0.10).color, .clear],
                                                             startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.2)),
                                              lineWidth: 1)
                }
            }
            .shadow(color: radius > 0 ? .black.opacity(0.45) : .clear, radius: 10, y: 6)
            .accessibilityHidden(true)
    }
}

/// An engraved line between modules on a front: 1 pt black with 1 pt of faint light beside it.
public struct EngravedDivider: View {
    var axis: Axis
    var inset: CGFloat

    public init(_ axis: Axis = .vertical, inset: CGFloat = 2) {
        self.axis = axis
        self.inset = inset
    }

    public var body: some View {
        Group {
            if axis == .vertical {
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.device.groove).frame(width: 1)
                    Rectangle().fill(Theme.device.grooveLight).frame(width: 1)
                }
                .padding(.vertical, inset)
            } else {
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.device.groove).frame(height: 1)
                    Rectangle().fill(Theme.device.grooveLight).frame(height: 1)
                }
                .padding(.horizontal, inset)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A module on a front: an engraved title, an optional lamp or key on the right, and its controls below.
///
///     FaceplateModule("Spark") { Lamp("Verbunden", tone: .on, isOn: true) } content: { ... }
public struct FaceplateModule<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PanelLabel(title)
                Spacer(minLength: 4)
                trailing
            }
            .frame(height: 14)
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension FaceplateModule where Trailing == EmptyView {
    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, trailing: { EmptyView() }, content: content)
    }
}

#Preview("Front") {
    PreviewPair {
        VStack(spacing: 16) {
            Faceplate {
                HStack(spacing: 0) {
                    FaceplateModule("Pegel") { Lamp("Kein Signal", isOn: false) } content: {
                        Spacer().frame(height: 40)
                    }
                    .padding(.horizontal, 18)
                    EngravedDivider()
                    FaceplateModule("Spark") { Lamp("Verbunden", tone: .on, isOn: true) } content: {
                        Spacer().frame(height: 40)
                    }
                    .padding(.horizontal, 18)
                }
                .padding(.vertical, 10)
            }
            Faceplate(radius: Theme.Radius.panel) {
                PanelLabel("Panel").padding(30)
            }
        }
    }
}
