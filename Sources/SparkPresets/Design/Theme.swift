import SparkControl
import SwiftUI

/// Colors and materials. The devices, pedals and amp stay dark in light and dark mode, like real hardware, while
/// the window around them follows the system.
enum Theme {
    static let deviceRGB = RGB(0.09, 0.09, 0.10)
    static let faceTop = Color(red: 0.19, green: 0.19, blue: 0.21)
    static let faceBottom = Color(red: 0.075, green: 0.075, blue: 0.085)
    static let board = Color(red: 0.055, green: 0.055, blue: 0.065)
    static let display = Color(red: 0.035, green: 0.03, blue: 0.025)
    /// Text on the dark devices. Both keep a contrast of at least 4.5 to `deviceRGB`.
    static let label = Color(white: 0.86)
    static let labelDim = Color(white: 0.62)
    static let amber = Color(red: 0.98, green: 0.76, blue: 0.36)
    static let amberHot = Color(red: 1, green: 0.62, blue: 0.16)
    static let amberDim = Color(red: 0.72, green: 0.6, blue: 0.42)
    static let lampOff = Color(red: 0.24, green: 0.2, blue: 0.16)
    static let on = Color(red: 0.3, green: 0.82, blue: 0.42)
    static let screw = Color(white: 0.42)

    static func accent(_ place: ChainPlace) -> Color { Color(place.accent) }

    /// The body color of a pedal: its accent sunk into the dark device color.
    static func pedalBody(_ place: ChainPlace, lift: Double = 0) -> Color {
        let accent = place.accent, base = deviceRGB, amount = 0.26 + lift
        return Color(red: base.red + (accent.red - base.red) * amount,
                     green: base.green + (accent.green - base.green) * amount,
                     blue: base.blue + (accent.blue - base.blue) * amount)
    }

    static let faceGradient = LinearGradient(colors: [faceTop, faceBottom], startPoint: .top, endPoint: .bottom)
}

extension Color {
    init(_ rgb: RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// Small caps label as printed on hardware.
struct PanelLabel: View {
    let text: String
    var color: Color = Theme.labelDim

    init(_ text: String, color: Color = Theme.labelDim) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A screw head, for the corners of pedals and panels.
struct Screw: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(white: 0.55), Color(white: 0.22)], center: .init(x: 0.35, y: 0.3),
                                 startRadius: 0, endRadius: 5))
            .overlay(Rectangle().fill(Color.black.opacity(0.55)).frame(width: 4.5, height: 1).rotationEffect(.degrees(35)))
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}
