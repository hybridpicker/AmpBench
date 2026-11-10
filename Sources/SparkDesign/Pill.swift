import SwiftUI

/// A state written as a small pill on the desk: amber for "Open", green for "Changed", gray for "Backup".
///
///     Pill("Open")
///     Pill("Changed", tone: .green)
public struct Pill: View {
    public enum Tone: Sendable { case amber, green, gray }

    let text: String
    var tone: Tone

    public init(_ text: String, tone: Tone = .amber) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
    }

    private var foreground: AnyShapeStyle {
        switch tone {
        case .amber: AnyShapeStyle(Theme.desk.pillAmberText)
        case .green: AnyShapeStyle(Theme.desk.pillGreenText)
        case .gray: AnyShapeStyle(.secondary)
        }
    }

    private var background: DeskSwatch {
        switch tone {
        case .amber: Theme.desk.pillAmberBack
        case .green: Theme.desk.pillGreenBack
        case .gray: Theme.desk.pillGrayBack
        }
    }

    private var edge: DeskSwatch {
        switch tone {
        case .amber: Theme.desk.pillAmberEdge
        case .green: Theme.desk.pillGreenEdge
        case .gray: Theme.desk.pillGrayEdge
        }
    }
}

#Preview("Pills") {
    PreviewPair {
        HStack(spacing: 6) {
            Pill("Open")
            Pill("Changed", tone: .green)
            Pill("Backup", tone: .gray)
        }
    }
}
