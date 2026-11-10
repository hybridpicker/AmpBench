import AmpText
import SwiftUI

/// The body of a pedal. All pedals have the same dark body; the accent color of the place shows only on the
/// nameplate. A selected pedal has a 2 pt amber frame around it, a switched-off pedal is dimmed to 62 %.
///
///     PedalShell(nameplate: "Drive", accent: orange, isOn: true, isSelected: true) { controls }
public struct PedalShell<Content: View>: View {
    let nameplate: String
    let accent: Color
    var isOn: Bool
    var isSelected: Bool
    var cornerRadius: CGFloat
    @ViewBuilder let content: Content

    public init(nameplate: String, accent: Color, isOn: Bool = true, isSelected: Bool = false, cornerRadius: CGFloat = 12,
                @ViewBuilder content: () -> Content) {
        self.nameplate = nameplate
        self.accent = accent
        self.isOn = isOn
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Nameplate(text: nameplate, accent: accent)
            content
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(LinearGradient(colors: [Theme.device.pedalTop.color, Theme.device.pedalBottom.color],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.device.faceEdge, lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).inset(by: 1)
                    .stroke(LinearGradient(colors: [Swatch.white(0.10).color, .clear], startPoint: .top,
                                           endPoint: UnitPoint(x: 0.5, y: 0.15)), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 7, y: 6)
        )
        .opacity(isOn ? 1 : 0.62)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius + 3)
                .strokeBorder(Theme.device.amber.color.opacity(isSelected ? 1 : 0), lineWidth: 2)
                .padding(-3)
        )
    }
}

/// The colored plate at the top of a pedal, with the place's short name in dark capitals.
public struct Nameplate: View {
    let text: String
    let accent: Color

    public init(text: String, accent: Color) {
        self.text = text
        self.accent = accent
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.76)
            .foregroundStyle(Theme.device.nameplateText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(accent)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(LinearGradient(colors: [.white.opacity(0.35), .clear, .black.opacity(0.25)],
                                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
            )
            .accessibilityHidden(true)
    }
}

/// An amp head: tolex box with a brass strip for its name, room for controls and a grille below.
public struct AmpHeadShell<Content: View>: View {
    var isOn: Bool
    var isSelected: Bool
    @ViewBuilder let content: Content

    public init(isOn: Bool = true, isSelected: Bool = false, @ViewBuilder content: () -> Content) {
        self.isOn = isOn
        self.isSelected = isSelected
        self.content = content()
    }

    public var body: some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.device.tolex)
                    Tolex().clipShape(RoundedRectangle(cornerRadius: 10))
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.device.faceEdge, lineWidth: 1)
                    RoundedRectangle(cornerRadius: 10).inset(by: 1)
                        .stroke(LinearGradient(colors: [Swatch.white(0.12).color, .clear], startPoint: .top,
                                               endPoint: UnitPoint(x: 0.5, y: 0.15)), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.6), radius: 9, y: 8)
            )
            .opacity(isOn ? 1 : 0.62)
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(Theme.device.amber.color.opacity(isSelected ? 1 : 0), lineWidth: 2)
                    .padding(-3)
            )
    }
}

/// The brass strip of an amp, with its lamp and name.
public struct BrassPanel<Content: View>: View {
    @ViewBuilder let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Theme.device.brassTop.color, Theme.device.brassBottom.color],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Swatch(hex: 0x0A0804), lineWidth: 1))
                    .overlay(RoundedRectangle(cornerRadius: 5).inset(by: 1)
                        .stroke(LinearGradient(colors: [Swatch(hex: 0xFFDCA0, alpha: 0.35).color, .clear],
                                               startPoint: .top, endPoint: .center), lineWidth: 1))
            )
    }
}

/// A fine cross weave.
public struct Tolex: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 4
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                path.move(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// Grille cloth for the front of an amp.
public struct Grille: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            var path = Path()
            var y: CGFloat = 0
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: 2))
                y += 4
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.device.grilleBottom.color))
            context.fill(path, with: .color(Theme.device.grilleTop.color))
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Swatch(hex: 0x0A0804), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 5).fill(
            RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: 0, endRadius: 120)))
        .accessibilityHidden(true)
    }
}

/// A metal stomp switch.
///
///     Footswitch(isOn: effect.isOn, label: "Drive on or off") { toggle() }
public struct Footswitch: View {
    let isOn: Bool
    let label: String
    var size: CGFloat
    var isEnabled: Bool
    let action: () -> Void

    public init(isOn: Bool, label: String, size: CGFloat = 30, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.isOn = isOn
        self.label = label
        self.size = size
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Circle()
                .fill(RadialGradient(colors: [Theme.device.metalLight.color, Theme.device.metalDark.color],
                                     center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: size * 0.55))
                .overlay(Circle().strokeBorder(Theme.device.knobEdge, lineWidth: 2))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? tr("on") : tr("off"))
        .accessibilityHint(tr("Switches the effect on or off"))
        .help(isOn ? tr("Switch off") : tr("Switch on"))
    }
}

/// The patch cable that runs behind a row of pedals: a dark rail.
public struct CableRail: View {
    public init() {}

    public var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [Theme.device.pedalTop.color, Theme.device.fieldEdge.color],
                                 startPoint: .top, endPoint: .bottom))
            .frame(height: 5)
            .shadow(color: .black.opacity(0.7), radius: 1.5, y: 2)
            .accessibilityHidden(true)
    }
}

#Preview("Pedal and amp") {
    PreviewPair {
        ZStack {
            Theme.device.board.color
            HStack(spacing: 12) {
                PedalShell(nameplate: "Drive", accent: Swatch(hex: 0xF28A3C).color, isSelected: true) {
                    VStack(spacing: 6) {
                        Text("Overdrive 808").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.device.label)
                            .frame(height: 28)
                        HStack(spacing: 5) { MiniKnob(position: 0.7); MiniKnob(position: 0.5) }
                        LampDot(color: Swatch(hex: 0xF28A3C), isOn: true)
                        Spacer(minLength: 0)
                        Footswitch(isOn: true, label: "Drive") {}.padding(.bottom, 8)
                    }
                }
                .frame(width: 104, height: 150)
                PedalShell(nameplate: "Mod", accent: Swatch(hex: 0xB088F2).color, isOn: false) {
                    Spacer()
                }
                .frame(width: 104, height: 150)
                AmpHeadShell(isSelected: false) {
                    VStack(spacing: 8) {
                        BrassPanel { Text("Brit Plexi").italic().padding(6).frame(maxWidth: .infinity) }
                        Grille()
                    }
                    .padding(9)
                }
                .frame(width: 206, height: 160)
            }
            .padding(20)
        }
    }
}
