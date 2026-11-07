import SwiftUI

/// A status lamp with its word. A state is never shown by color alone: the word is always there, and a dark lamp
/// has a dim word.
///
///     Lamp("Live", tone: .on, isOn: editor.isHeard)
///     Lamp("Übersteuert", tone: .record, isOn: meter.clipped)
///
/// The dot is hidden from VoiceOver, the word stays. Give the lamp an `accessibilityLabel` when the word alone does
/// not say whether it is on.
public struct Lamp: View {
    /// What a lit lamp means. Amber is the one signal color, red belongs to recording only.
    public enum Tone: Sendable {
        case amber, hot, on, record, listening
        case custom(Swatch)

        var dot: Swatch {
            switch self {
            case .amber: Theme.device.amber
            case .hot: Theme.device.amberHot
            case .on: Theme.device.on
            case .record: Theme.device.record
            case .listening: Theme.device.listening
            case .custom(let swatch): swatch
            }
        }

        var text: Swatch {
            switch self {
            case .record: Theme.device.recordText
            default: dot
            }
        }
    }

    let text: String
    let tone: Tone
    let isOn: Bool
    var size: CGFloat
    var textSize: CGFloat

    public init(_ text: String, tone: Tone = .amber, isOn: Bool, size: CGFloat = 8, textSize: CGFloat = 9.5) {
        self.text = text
        self.tone = tone
        self.isOn = isOn
        self.size = size
        self.textSize = textSize
    }

    public var body: some View {
        HStack(spacing: 5) {
            LampDot(tone: tone, isOn: isOn, size: size)
            if !text.isEmpty {
                Text(text.uppercased())
                    .font(Theme.Fonts.lamp(textSize))
                    .tracking(textSize * 0.04)
                    .foregroundStyle(isOn ? tone.text : Theme.device.lampOffText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The dot of a lamp alone, for places where the word stands elsewhere, such as on a pedal.
public struct LampDot: View {
    let tone: Lamp.Tone
    let isOn: Bool
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tone: Lamp.Tone = .amber, isOn: Bool, size: CGFloat = 8) {
        self.tone = tone
        self.isOn = isOn
        self.size = size
    }

    public init(color: Swatch, isOn: Bool, size: CGFloat = 8) {
        self.init(tone: .custom(color), isOn: isOn, size: size)
    }

    public var body: some View {
        Circle()
            .fill(isOn ? tone.dot : Theme.device.lampOff)
            .frame(width: size, height: size)
            .shadow(color: isOn ? tone.dot.color.opacity(0.9) : .clear, radius: size * 0.6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isOn)
            .accessibilityHidden(true)
    }
}

#Preview("Lämpchen") {
    PreviewPair {
        Faceplate {
            HStack(spacing: 14) {
                Lamp("Live", tone: .on, isOn: true)
                Lamp("Rec", tone: .record, isOn: true)
                Lamp("Geändert", tone: .hot, isOn: true)
                Lamp("Klick", isOn: false)
            }
            .padding(14)
        }
    }
}
