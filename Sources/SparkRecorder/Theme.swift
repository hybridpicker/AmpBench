import AppKit
import SwiftUI

/// The studio-device look. Colors adapt to light and dark mode, except the display, which stays dark like real hardware.
enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func gray(_ white: CGFloat) -> NSColor { NSColor(white: white, alpha: 1) }

    static let faceplateTop = dynamic(light: gray(0.88), dark: gray(0.20))
    static let faceplateBottom = dynamic(light: gray(0.80), dark: gray(0.14))
    static let faceplateLine = dynamic(light: gray(0.68), dark: gray(0.05))
    static let engraved = dynamic(light: gray(0.28), dark: gray(0.70))

    static let display = Color(white: 0.06)
    static let displayLine = Color(white: 0.24)
    static let displayText = Color(red: 0.98, green: 0.76, blue: 0.36)
    static let displayDim = Color(red: 0.70, green: 0.60, blue: 0.45)

    static let record = Color(red: 0.90, green: 0.16, blue: 0.13)
    static let recordDim = Color(red: 0.62, green: 0.15, blue: 0.12)
    static let listening = Color(red: 0.98, green: 0.60, blue: 0.14)

    static let meterGreen = Color(red: 0.25, green: 0.80, blue: 0.38)
    static let meterAmber = Color(red: 0.98, green: 0.74, blue: 0.16)
    static let meterRed = Color(red: 0.95, green: 0.22, blue: 0.16)
    static let meterOff = Color(white: 0.17)

    static let wave = dynamic(
        light: NSColor(red: 0.13, green: 0.43, blue: 0.50, alpha: 1),
        dark: NSColor(red: 0.42, green: 0.78, blue: 0.84, alpha: 1))
    static let waveDim = wave.opacity(0.28)
    static let waveBackground = dynamic(light: gray(0.97), dark: gray(0.09))
    static let loop = dynamic(
        light: NSColor(red: 0.95, green: 0.65, blue: 0.10, alpha: 0.24),
        dark: NSColor(red: 0.98, green: 0.70, blue: 0.20, alpha: 0.24))
    static let loopEdge = Color(red: 0.92, green: 0.58, blue: 0.06)
    static let marker = dynamic(
        light: NSColor(red: 0.70, green: 0.20, blue: 0.55, alpha: 1),
        dark: NSColor(red: 0.95, green: 0.55, blue: 0.85, alpha: 1))

    static let gridBar = dynamic(light: NSColor(white: 0, alpha: 0.62), dark: NSColor(white: 1, alpha: 0.62))
    static let gridBeat = dynamic(light: NSColor(white: 0, alpha: 0.20), dark: NSColor(white: 1, alpha: 0.20))
    static let gridText = dynamic(light: gray(0.15), dark: gray(0.88))

    /// Single-series chart color. Checked with the palette validator against both surfaces.
    static let chartBar = dynamic(
        light: NSColor(red: 0x0A / 255, green: 0x7F / 255, blue: 0xB0 / 255, alpha: 1),
        dark: NSColor(red: 0x21 / 255, green: 0x96 / 255, blue: 0xD3 / 255, alpha: 1))

    static let label = Font.system(size: 10, weight: .semibold).smallCaps()
    static let displayFont = Font.system(.title, design: .monospaced).weight(.semibold).monospacedDigit()
}

/// A small engraved caption, as printed on a device's front panel.
struct PanelLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.label)
            .foregroundStyle(Theme.engraved)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A status lamp with its text, so the state never depends on color alone.
struct Lamp: View {
    let text: String
    let color: Color
    let isOn: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOn ? color : Theme.meterOff)
                .frame(width: 8, height: 8)
                .shadow(color: isOn ? color.opacity(0.8) : .clear, radius: 4)
            Text(text)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? color : Theme.displayDim.opacity(0.55))
        }
    }
}

/// The big round record key.
struct RecordKeyStyle: ButtonStyle {
    let isActive: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
            Circle()
                .strokeBorder(Color.black.opacity(0.6), lineWidth: 1)
            Circle()
                .fill(isActive ? Theme.record : Theme.recordDim.opacity(0.95))
                .padding(9)
                .shadow(color: isActive ? Theme.record.opacity(0.85) : .clear, radius: 10)
            configuration.label
        }
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
    }
}

/// A hardware-style key for the transport.
struct DeckKeyStyle: ButtonStyle {
    var isOn = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .foregroundStyle(isOn ? Color.black : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? AnyShapeStyle(Theme.loopEdge) : AnyShapeStyle(.background.opacity(configuration.isPressed ? 0.45 : 0.85)))
            )
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.faceplateLine))
            .opacity(isEnabled ? 1 : 0.45)
    }
}
