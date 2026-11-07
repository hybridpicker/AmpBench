import SwiftUI

/// The big round record key. Idle it is a dark red disc in a black ring. While recording it glows and shows a stop
/// square; during the count-in it shows the beats left. With "Reduce motion" it does not pulse.
///
///     RecordKey(state: .recording, action: toggleRecord)
///         .accessibilityLabel("Aufnahme stoppen (R)")
public struct RecordKey: View {
    public enum State: Equatable, Sendable {
        case idle
        case countIn(Int)
        case recording
    }

    let state: State
    var size: CGFloat
    let action: () -> Void

    public init(state: State, size: CGFloat = 84, action: @escaping () -> Void) {
        self.state = state
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                switch state {
                case .recording:
                    RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: size * 0.24, height: size * 0.24)
                case .countIn(let beats):
                    Text("\(beats)")
                        .font(.system(size: size * 0.3, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                case .idle:
                    EmptyView()
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(RecordKeyStyle(isActive: state != .idle, size: size))
        .frame(width: size, height: size)
    }
}

struct RecordKeyStyle: ButtonStyle {
    let isActive: Bool
    let size: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let inner = size * 60 / 84
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Theme.device.knobTop.color, Swatch(hex: 0x121214).color],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(Theme.device.faceEdge, lineWidth: 1))
                .overlay(Circle().inset(by: 1).stroke(LinearGradient(colors: [.white.opacity(0.12), .clear],
                                                                     startPoint: .top, endPoint: .center), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 5, y: 4)
            RecordGlow(isActive: isActive, reduceMotion: reduceMotion)
                .frame(width: inner, height: inner)
                .opacity(isEnabled ? 1 : 0.5)
            configuration.label
        }
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
        .brightness(configuration.isPressed ? -0.05 : 0)
    }
}

/// The red disc. While active it glows and, unless motion is reduced, breathes slowly.
private struct RecordGlow: View {
    let isActive: Bool
    let reduceMotion: Bool
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: isActive ? [Swatch(hex: 0xFF6A5A).color, Swatch(hex: 0xC8261C).color]
                                 : [Swatch(hex: 0xB8322A).color, Swatch(hex: 0x7A1A14).color],
                center: UnitPoint(x: 0.4, y: 0.32), startRadius: 0, endRadius: 40))
            .overlay(Circle().inset(by: 0.5).stroke(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                                                   startPoint: .top, endPoint: .center), lineWidth: 1))
            .shadow(color: isActive ? Theme.device.record.color.opacity(breathe && !reduceMotion ? 0.45 : 0.85) : .clear,
                    radius: isActive ? 12 : 0)
            .onChange(of: isActive, initial: true) { _, active in
                guard active, !reduceMotion else {
                    breathe = false
                    return
                }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { breathe = true }
            }
    }
}

#Preview("Record-Taste") {
    PreviewPair {
        Faceplate {
            HStack(spacing: 18) {
                RecordKey(state: .idle) {}
                RecordKey(state: .countIn(3)) {}
                RecordKey(state: .recording) {}
            }
            .padding(14)
        }
    }
}
