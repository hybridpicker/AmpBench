import AmpText
import Foundation

/// The seven places of the amp's signal chain, in the order the presets list them.
public enum ChainPlace: Int, CaseIterable, Codable, Sendable, Identifiable {
    case gate, compressor, drive, amp, modulation, delay, reverb

    public var id: Int { rawValue }

    /// The place's name in the app's language.
    public var title: String { CatalogText.shown(englishTitle, .place) }

    public var englishTitle: String {
        switch self {
        case .gate: "Noise Gate"
        case .compressor: "Compressor"
        case .drive: "Drive"
        case .amp: "Amp"
        case .modulation: "Modulation"
        case .delay: "Delay"
        case .reverb: "Reverb"
        }
    }

    public var germanTitle: String { CatalogText.german(englishTitle, .place) }

    /// A short label for narrow places, such as a pedal.
    public var shortTitle: String {
        switch self {
        case .gate: "Gate"
        case .compressor: tr("Comp")
        case .drive: "Drive"
        case .amp: "Amp"
        case .modulation: "Mod"
        case .delay: "Delay"
        case .reverb: tr("Reverb")
        }
    }

    /// A color of its own for every place, so the chain reads at a glance. Plain RGB, the app turns it into colors.
    public var accent: RGB {
        switch self {
        case .gate: RGB(0.55, 0.66, 0.70)
        case .compressor: RGB(0.36, 0.62, 0.92)
        case .drive: RGB(0.98, 0.55, 0.20)
        case .amp: RGB(0.98, 0.76, 0.36)
        case .modulation: RGB(0.70, 0.52, 0.95)
        case .delay: RGB(0.30, 0.80, 0.66)
        case .reverb: RGB(0.55, 0.80, 0.98)
        }
    }

    /// The place of effect `index` in a preset with `count` effects, if it has the usual seven.
    public static func of(index: Int, count: Int) -> ChainPlace? {
        count == allCases.count ? ChainPlace(rawValue: index) : nil
    }
}

public struct RGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Relative luminance as WCAG defines it, for checking contrast.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio between two colors, from 1 to 21.
    public func contrast(with other: RGB) -> Double {
        let (light, dark) = luminance > other.luminance ? (luminance, other.luminance) : (other.luminance, luminance)
        return (light + 0.05) / (dark + 0.05)
    }
}
