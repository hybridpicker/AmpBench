import SparkControl
import SwiftUI

/// The body of a pedal: painted metal in the place's color, with screws and a soft bevel.
struct PedalShell<Content: View>: View {
    let place: ChainPlace
    var isOn = true
    var isSelected = false
    var cornerRadius: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(LinearGradient(colors: [Theme.pedalBody(place, lift: 0.08), Theme.pedalBody(place, lift: -0.1)],
                                             startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(RadialGradient(colors: [.white.opacity(0.1), .clear], center: .init(x: 0.3, y: 0),
                                             startRadius: 0, endRadius: 160))
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .black.opacity(0.5)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    screws
                }
                .shadow(color: .black.opacity(0.55), radius: 6, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius + 3)
                    .strokeBorder(Theme.accent(place).opacity(isSelected ? 0.95 : 0), lineWidth: 2)
                    .padding(-4)
                    .shadow(color: Theme.accent(place).opacity(isSelected ? 0.6 : 0), radius: 6)
            )
            .saturation(isOn ? 1 : 0.55)
    }

    private var screws: some View {
        VStack {
            HStack { Screw(); Spacer(); Screw() }
            Spacer()
            HStack { Screw(); Spacer(); Screw() }
        }
        .padding(5)
    }
}

/// An amp head: tolex box, a brass control panel and a grille.
struct AmpHeadShell<Content: View>: View {
    var isOn = true
    var isSelected = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.07))
                    Tolex().clipShape(RoundedRectangle(cornerRadius: 10))
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.6)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.6), radius: 7, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(Theme.accent(.amp).opacity(isSelected ? 0.95 : 0), lineWidth: 2)
                    .padding(-4)
                    .shadow(color: Theme.accent(.amp).opacity(isSelected ? 0.6 : 0), radius: 6)
            )
            .saturation(isOn ? 1 : 0.5)
    }
}

/// The brass strip of an amp's controls.
struct BrassPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.34, blue: 0.2),
                                                  Color(red: 0.22, green: 0.17, blue: 0.1)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(LinearGradient(colors: [Color(red: 0.85, green: 0.7, blue: 0.42).opacity(0.7),
                                                              .black.opacity(0.5)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1))
            )
    }
}

/// A fine cross weave, drawn once per size.
struct Tolex: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 3
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                path.move(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 0.6)
        }
        .accessibilityHidden(true)
    }
}

/// Grille cloth for the front of the amp.
struct Grille: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                         with: .color(Color(red: 0.11, green: 0.1, blue: 0.09)))
            var path = Path()
            var y: CGFloat = 1
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += 2.5
            }
            context.stroke(path, with: .color(Color(red: 0.8, green: 0.68, blue: 0.45).opacity(0.09)), lineWidth: 0.8)
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.6)))
        .accessibilityHidden(true)
    }
}
