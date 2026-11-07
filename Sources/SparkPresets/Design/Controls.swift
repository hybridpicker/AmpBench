import SwiftUI

/// A lamp that glows when on.
struct LED: View {
    let isOn: Bool
    var color: Color = Theme.amberHot
    var size: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(isOn ? AnyShapeStyle(RadialGradient(colors: [.white.opacity(0.95), color], center: .init(x: 0.4, y: 0.35),
                                                      startRadius: 0, endRadius: size * 0.6))
                       : AnyShapeStyle(Color(white: 0.12)))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 0.8))
            .overlay(Circle().fill(color.opacity(isOn ? 0 : 0.14)))
            .shadow(color: isOn ? color.opacity(0.85) : .clear, radius: size * 0.6)
            .frame(width: size, height: size)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOn)
            .accessibilityHidden(true)
    }
}

/// A metal stomp switch. A press switches the effect.
struct Footswitch: View {
    let isOn: Bool
    let label: String
    var size: CGFloat = 30
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.18)],
                                             startPoint: .top, endPoint: .bottom))
                Circle().fill(RadialGradient(colors: [Color(white: 0.82), Color(white: 0.36)], center: .init(x: 0.42, y: 0.35),
                                             startRadius: 0, endRadius: size * 0.42))
                    .padding(size * 0.14)
                Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 0.8)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
        }
        .buttonStyle(PressStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "an" : "aus")
        .accessibilityHint("Schaltet den Effekt an oder aus")
        .help(isOn ? "Ausschalten" : "Einschalten")
    }
}

/// Presses in a little, unless motion is reduced.
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
    }
}

/// A small two-way toggle for switch parameters, with both states labeled.
struct LeverSwitch: View {
    let name: String
    let isOn: Bool
    let off: String
    let on: String
    let accent: Color
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(off).foregroundStyle(isOn ? Theme.labelDim : Theme.amber).fixedSize()
                    ZStack(alignment: isOn ? .trailing : .leading) {
                        Capsule().fill(Color.black.opacity(0.65)).frame(width: 34, height: 16)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                        Capsule()
                            .fill(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.35)], startPoint: .top,
                                                 endPoint: .bottom))
                            .frame(width: 18, height: 14)
                            .padding(.horizontal, 1)
                            .shadow(color: isOn ? accent.opacity(0.7) : .clear, radius: 3)
                    }
                    Text(on).foregroundStyle(isOn ? Theme.amber : Theme.labelDim).fixedSize()
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            Text(name)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.label)
        }
        .frame(minHeight: 66)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(isOn ? on : off)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// Amber text behind dark glass, like the display of a device.
struct AmberDisplay<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, padding + 2)
            .padding(.vertical, padding)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.display)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top,
                                             endPoint: .center)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.8), lineWidth: 1))
                    .shadow(color: .white.opacity(0.08), radius: 0, y: 1)
            )
    }
}
