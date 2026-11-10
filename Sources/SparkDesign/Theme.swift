import AppKit
import SwiftUI

/// One fixed color, written down once as a hex value. It is a shape style, so it fills and colors directly, and it
/// knows its contrast to another swatch, which the tests use to check every pair of text and background.
public struct Swatch: ShapeStyle, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static func white(_ alpha: Double) -> Swatch { Swatch(hex: 0xFFFFFF, alpha: alpha) }
    public static func black(_ alpha: Double) -> Swatch { Swatch(hex: 0x000000, alpha: alpha) }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    public func opacity(_ alpha: Double) -> Swatch { Swatch(red: red, green: green, blue: blue, alpha: self.alpha * alpha) }

    public func resolve(in environment: EnvironmentValues) -> Color { color }

    /// This color laid over an opaque background, as the eye sees it.
    public func over(_ background: Swatch) -> Swatch {
        Swatch(red: red * alpha + background.red * (1 - alpha), green: green * alpha + background.green * (1 - alpha),
               blue: blue * alpha + background.blue * (1 - alpha))
    }

    /// Relative luminance as WCAG defines it.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio to an opaque background, from 1 to 21. A translucent color is laid over it first.
    public func contrast(with background: Swatch) -> Double {
        let front = alpha < 1 ? over(background) : self
        let (light, dark) = front.luminance > background.luminance
            ? (front.luminance, background.luminance) : (background.luminance, front.luminance)
        return (light + 0.05) / (dark + 0.05)
    }
}

/// A color of the desk, which follows the system: one value for light and one for dark mode.
public struct DeskSwatch: ShapeStyle, Hashable, Sendable {
    public let light: Swatch
    public let dark: Swatch

    public init(light: Swatch, dark: Swatch) {
        self.light = light
        self.dark = dark
    }

    public init(light: UInt32, dark: UInt32, alpha: Double = 1) {
        self.init(light: Swatch(hex: light, alpha: alpha), dark: Swatch(hex: dark, alpha: alpha))
    }

    /// The same value in both appearances.
    public init(_ both: Swatch) {
        self.init(light: both, dark: both)
    }

    /// A color that changes with the appearance of the view it is drawn in, also inside a `Canvas`.
    public var color: Color { Color(nsColor: nsColor) }

    public var nsColor: NSColor {
        let light = light.nsColor, dark = dark.nsColor
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    public func opacity(_ alpha: Double) -> DeskSwatch { DeskSwatch(light: light.opacity(alpha), dark: dark.opacity(alpha)) }

    public func resolve(in environment: EnvironmentValues) -> Color {
        (environment.colorScheme == .dark ? dark : light).color
    }
}

/// The values of the AmpBench design language, the one source for both apps. `docs/DESIGN.md` explains them.
///
/// `Theme.device` is the instrument: deck, waveform transport, pedals, amp, knobs and every display. It looks the
/// same in light and dark mode. `Theme.desk` is everything that follows the system, around the instrument.
public enum Theme {
    public static let device = DevicePalette()
    public static let desk = DeskPalette()

    /// Corner radii.
    public enum Radius {
        public static let key: CGFloat = 6
        public static let keycap: CGFloat = 4
        public static let display: CGFloat = 10
        public static let field: CGFloat = 10
        public static let panel: CGFloat = 14
    }

    /// Every distance is a multiple of the 4 pt grid.
    public static let grid: CGFloat = 4

    /// System fonts only, nothing is downloaded.
    public enum Fonts {
        /// SF Pro Display, for titles and preset names, 23 to 34 pt.
        public static func title(_ size: CGFloat = 23) -> Font { .system(size: size, weight: .bold) }
        /// SF Mono with even digits, for time, BPM, values, dates and durations.
        public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
        }
        /// The engraving on a device front. `PanelLabel` adds the letter spacing.
        public static func engraving(_ size: CGFloat = 9.5) -> Font { .system(size: size, weight: .bold) }
        /// The text of a lamp.
        public static func lamp(_ size: CGFloat = 9.5) -> Font { .system(size: size, weight: .bold, design: .monospaced) }
        /// Letter spacing of engravings, 0.09 em.
        public static func engravingTracking(_ size: CGFloat) -> CGFloat { size * 0.09 }
    }
}

/// The instrument's colors. The same in light and dark mode, like a real device on a light or a dark desk.
public struct DevicePalette: Sendable {
    public init() {}

    // Front
    public let faceTop = Swatch(hex: 0x27272B)
    public let faceBottom = Swatch(hex: 0x18181B)
    public let faceEdge = Swatch(hex: 0x060607)
    public let faceHighlight = Swatch.white(0.07)
    /// An engraved line between modules is a black line with a faint light line beside it.
    public let groove = Swatch(hex: 0x000000)
    public let grooveLight = Swatch.white(0.05)
    /// The board the pedals stand on.
    public let board = Swatch(hex: 0x0F0F12)
    /// A raised panel on the board, such as the control field of a pedal.
    public let panelTop = Swatch(hex: 0x2A2A2F)
    public let panelBottom = Swatch(hex: 0x19191C)

    // Text on the front
    public let label = Swatch(hex: 0xE8E8EA)
    public let labelDim = Swatch(hex: 0xB2B2B8)
    /// The canvas has #8E8E96, which reaches only 4.4 : 1 on a pedal or panel, so it is a little lighter here.
    public let engraving = Swatch(hex: 0x96969E)

    // Display
    public let display = Swatch(hex: 0x0C0B09)
    public let displayEdge = Swatch(hex: 0x2A2824)
    public let amber = Swatch(hex: 0xF7C45C)
    public let amberDim = Swatch(hex: 0xA8906A)
    public let amberHot = Swatch(hex: 0xFFA02E)

    // Signals
    public let record = Swatch(hex: 0xE4332A)
    /// Red as text. #E4332A itself reaches only 4.0 : 1 on the front, so words in red are a little lighter.
    public let recordText = Swatch(hex: 0xFF5A50)
    public let listening = Swatch(hex: 0xF99A22)
    public let on = Swatch(hex: 0x4BD36A)
    public let lampOff = Swatch(hex: 0x3A3028)
    /// The word next to a dark lamp. The canvas has #6B6058, which reaches only 2.9 : 1, so it is lighter here.
    public let lampOffText = Swatch(hex: 0x9E9186)

    // Level meter
    public let meterGreen = Swatch(hex: 0x3FBF5A)
    public let meterAmber = Swatch(hex: 0xF2B233)
    public let meterRed = Swatch(hex: 0xE4332A)
    public let meterOff = Swatch(hex: 0x2A2824)

    // Keys
    public let keyTop = Swatch(hex: 0x333338)
    public let keyBottom = Swatch(hex: 0x28282C)
    public let keyEdge = Swatch(hex: 0x0E0E10)
    public let keyHighlight = Swatch.white(0.10)
    public let keyText = Swatch(hex: 0xE8E8EA)
    /// A key that cannot be pressed right now.
    public let keyTextDisabled = Swatch(hex: 0x76767E)
    public let primaryTop = Swatch(hex: 0xFFD36F)
    public let primaryBottom = Swatch(hex: 0xEFB64A)
    public let primaryEdge = Swatch(hex: 0x8A6420)
    public let primaryText = Swatch(hex: 0x1A1206)
    public let onTop = Swatch(hex: 0xF0A93A)
    public let onBottom = Swatch(hex: 0xD98F22)
    public let onEdge = Swatch(hex: 0x8A5A12)
    public let dangerText = Swatch(hex: 0xFF8A80)
    public let keycapText = Swatch(hex: 0x96969E)
    public let keycapBack = Swatch.black(0.35)
    public let keycapEdge = Swatch.white(0.08)
    /// The keycap on an amber key. The canvas has #5B4210, which reaches only 3 : 1 on a switched-on key, so it is
    /// darker here.
    public let keycapTextOnAmber = Swatch(hex: 0x2E2004)
    public let keycapBackOnAmber = Swatch.black(0.12)

    // Fields and switches on the front
    public let field = Swatch(hex: 0x111113)
    public let fieldEdge = Swatch(hex: 0x0A0A0C)
    public let fieldText = Swatch(hex: 0xD6D6DA)
    public let switchOff = Swatch(hex: 0x3A3A40)
    public let switchOn = Swatch(hex: 0xD98F22)
    public let switchThumb = Swatch(hex: 0xC9C9CE)

    // Knobs, pedals, amp
    public let knobTop = Swatch(hex: 0x3A3A40)
    public let knobBottom = Swatch(hex: 0x1B1B1F)
    public let knobEdge = Swatch(hex: 0x0A0A0C)
    public let knobTrack = Swatch.white(0.10)
    public let pedalTop = Swatch(hex: 0x2A2A2F)
    public let pedalBottom = Swatch(hex: 0x141417)
    public let nameplateText = Swatch(hex: 0x111111)
    public let metalLight = Swatch(hex: 0xD6D6DA)
    public let metalDark = Swatch(hex: 0x8A8A92)
    public let tolex = Swatch(hex: 0x141210)
    public let brassTop = Swatch(hex: 0x6B5732)
    public let brassBottom = Swatch(hex: 0x3A2D18)
    public let brassText = Swatch(hex: 0xC9A76A)
    public let grilleTop = Swatch(hex: 0x1C1816)
    public let grilleBottom = Swatch(hex: 0x0E0C0B)
    public let ampGroup = Swatch(hex: 0x9A8462)

    public var faceGradient: LinearGradient {
        LinearGradient(colors: [faceTop.color, faceBottom.color], startPoint: .top, endPoint: .bottom)
    }
}

/// The desk's colors. They follow the system; text and controls on the desk use the system's own colors.
public struct DeskPalette: Sendable {
    public init() {}

    public let wave = DeskSwatch(light: 0x1F6F7E, dark: 0x68C6D6)
    public let waveBackground = DeskSwatch(light: 0xF7F7F8, dark: 0x121214)
    public let loopFill = DeskSwatch(Swatch(hex: 0xF7C45C, alpha: 0.14))
    public let loopEdge = DeskSwatch(Swatch(hex: 0xE6A23C))
    /// The letter on a loop handle.
    public let loopHandleText = DeskSwatch(Swatch(hex: 0x1A1206))
    public let marker = DeskSwatch(light: 0xB23B8F, dark: 0xE58CD9)
    public let gridBar = DeskSwatch(light: Swatch.black(0.5), dark: Swatch.white(0.5))
    public let gridBeat = DeskSwatch(light: Swatch.black(0.18), dark: Swatch.white(0.18))
    public let playhead = DeskSwatch(light: 0x1D1D1F, dark: 0xFFFFFF)
    /// The tint of a selected row, instead of the system's blue.
    public let selection = DeskSwatch(light: Swatch(hex: 0xE6A23C, alpha: 0.18), dark: Swatch(hex: 0xF7C45C, alpha: 0.14))
    /// The 3 pt bar on the left of a selected row.
    public let selectionBar = DeskSwatch(light: 0xE6A23C, dark: 0xF7C45C)
    public let star = DeskSwatch(Swatch(hex: 0xF2B233))
    public let pillAmberText = DeskSwatch(light: 0x7E5508, dark: 0xF7C45C)
    public let pillAmberBack = DeskSwatch(Swatch(hex: 0xF7C45C, alpha: 0.16))
    public let pillAmberEdge = DeskSwatch(light: Swatch(hex: 0xE6A23C, alpha: 0.5), dark: Swatch(hex: 0xF7C45C, alpha: 0.35))
    public let pillGreenText = DeskSwatch(light: 0x17652B, dark: 0x4BD36A)
    public let pillGreenBack = DeskSwatch(Swatch(hex: 0x4BD36A, alpha: 0.14))
    public let pillGreenEdge = DeskSwatch(Swatch(hex: 0x4BD36A, alpha: 0.35))
    public let pillGrayBack = DeskSwatch(light: Swatch.black(0.05), dark: Swatch.white(0.06))
    public let pillGrayEdge = DeskSwatch(light: Swatch.black(0.12), dark: Swatch.white(0.12))
    public let segmentBack = DeskSwatch(light: Swatch.black(0.06), dark: Swatch.black(0.35))
    public let segmentSelected = DeskSwatch(light: 0xFFFFFF, dark: 0x3A3A40)
    public let segmentEdge = DeskSwatch(light: Swatch.black(0.10), dark: Swatch.white(0.08))
    /// Bars of a chart: the wave color, and amber for today.
    public let chartBar = DeskSwatch(light: 0x1F6F7E, dark: 0x68C6D6)
    public let chartToday = DeskSwatch(light: 0xB7790F, dark: 0xF2B233)
    /// Amber as a sign on the desk, such as the crown of a best take.
    public let amber = DeskSwatch(light: 0xB7790F, dark: 0xF2B233)

    /// Approximate backgrounds of the desk, only for checking contrast. The real ones are the system's.
    public let windowBackground = DeskSwatch(light: 0xECECEC, dark: 0x1E1E1E)
    public let contentBackground = DeskSwatch(light: 0xFFFFFF, dark: 0x1E1E1E)
}
