import SwiftUI

/// A hardware key, the one button style on a device. Its shortcut is engraved on it as a keycap.
///
///     Button("Keep", action: keep).buttonStyle(.hardwareKey(.primary, keycap: "K"))
///     Button("Discard", action: discard).buttonStyle(.hardwareKey(.danger, keycap: "⌫"))
///     Button(action: toggleLoop) { Text("Loop") }.buttonStyle(.hardwareKey(isOn ? .on : .normal, keycap: "L"))
///
/// Roles: `.normal` is dark, `.primary` is the one amber main action of a group, `.on` is a switched-on state,
/// `.danger` keeps the dark key and only turns the text red. There is never a red key.
/// The keycap is decoration and hidden from VoiceOver; say the shortcut in `.help`.
public struct HardwareKeyStyle: ButtonStyle {
    public enum Role: Sendable { case normal, primary, on, danger }
    public enum Size: Sendable {
        case regular, small

        var height: CGFloat { self == .regular ? 28 : 24 }
        var font: CGFloat { self == .regular ? 12 : 11 }
        var padding: CGFloat { self == .regular ? 10 : 8 }
    }

    var role: Role
    var keycap: String?
    var size: Size
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(role: Role = .normal, keycap: String? = nil, size: Size = .regular) {
        self.role = role
        self.keycap = keycap
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        let amber = role == .primary || role == .on
        HStack(spacing: 7) {
            configuration.label
                .font(.system(size: size.font, weight: .semibold))
                .lineLimit(1)
            if let keycap {
                Keycap(keycap, onAmber: amber)
            }
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, size.padding)
        .frame(minHeight: size.height)
        .background(KeyBody(role: role, isPressed: configuration.isPressed))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.key))
        .offset(y: configuration.isPressed && !reduceMotion ? 0.5 : 0)
    }

    private var textColor: Swatch {
        guard isEnabled else { return role == .primary || role == .on ? Theme.device.primaryText.opacity(0.55)
                                                                          : Theme.device.keyTextDisabled }
        switch role {
        case .normal: return Theme.device.keyText
        case .primary, .on: return Theme.device.primaryText
        case .danger: return Theme.device.dangerText
        }
    }
}

extension ButtonStyle where Self == HardwareKeyStyle {
    /// A hardware key. See `HardwareKeyStyle`.
    public static func hardwareKey(_ role: HardwareKeyStyle.Role = .normal, keycap: String? = nil,
                                   size: HardwareKeyStyle.Size = .regular) -> HardwareKeyStyle {
        HardwareKeyStyle(role: role, keycap: keycap, size: size)
    }
}

/// The body of a key, also for menus that look like keys.
public struct KeyBody: View {
    var role: HardwareKeyStyle.Role
    var isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(role: HardwareKeyStyle.Role = .normal, isPressed: Bool = false) {
        self.role = role
        self.isPressed = isPressed
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.key)
        let device = Theme.device
        let (top, bottom, edge): (Swatch, Swatch, Swatch) = switch role {
        case .primary: (device.primaryTop, device.primaryBottom, device.primaryEdge)
        case .on: (device.onTop, device.onBottom, device.onEdge)
        case .normal, .danger: (device.keyTop, device.keyBottom, device.keyEdge)
        }
        shape
            .fill(LinearGradient(colors: [top.color, bottom.color], startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(Color.black.opacity(isPressed ? 0.18 : 0)))
            .overlay(shape.strokeBorder(edge, lineWidth: 1))
            // The light edge along the top.
            .overlay(shape.inset(by: 1).stroke(LinearGradient(colors: [device.keyHighlight.color, .clear],
                                                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)),
                                                lineWidth: 1)
                .opacity(isPressed ? 0 : 1))
            .shadow(color: .black.opacity(0.5), radius: 0, y: 1)
            .opacity(isEnabled || role == .normal || role == .danger ? 1 : 0.7)
    }
}

/// The shortcut of a key, engraved as a small keycap: SF Mono 9.5 bold on a darker inlay.
///
///     Keycap("⌘Z")
public struct Keycap: View {
    let text: String
    var onAmber: Bool

    public init(_ text: String, onAmber: Bool = false) {
        self.text = text
        self.onAmber = onAmber
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(onAmber ? Theme.device.keycapTextOnAmber : Theme.device.keycapText)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.keycap)
                .fill(onAmber ? Theme.device.keycapBackOnAmber : Theme.device.keycapBack))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.keycap)
                .strokeBorder(onAmber ? Swatch.black(0.18) : Theme.device.keycapEdge, lineWidth: 1))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// Presses in a little, unless motion is reduced. For things that are pressed but are not keys, such as a footswitch.
public struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
    }
}

#Preview("Keys") {
    PreviewPair {
        Faceplate {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {} label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.hardwareKey(keycap: "␣"))
                    Button("Loop 00:10 – 00:17") {}.buttonStyle(.hardwareKey(.on, keycap: "L"))
                    Button("Keep") {}.buttonStyle(.hardwareKey(.primary, keycap: "K"))
                    Button("Discard") {}.buttonStyle(.hardwareKey(.danger, keycap: "⌫"))
                }
                HStack(spacing: 8) {
                    Button("Again") {}.buttonStyle(.hardwareKey(keycap: "R", size: .small))
                    Button("Disabled") {}.buttonStyle(.hardwareKey(size: .small)).disabled(true)
                    Button("Save") {}.buttonStyle(.hardwareKey(.primary, keycap: "⌘S")).disabled(true)
                }
            }
            .padding(14)
        }
    }
}
