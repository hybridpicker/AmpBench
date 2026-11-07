import SwiftUI

/// A number in a small display with two engraved arrows to step it, such as the BPM of the click.
///
///     DisplayStepper("Tempo", value: $bpm, in: 40...240, step: 1, text: "\(Int(bpm))", unit: "BPM",
///                    spokenValue: "\(Int(bpm)) Schläge pro Minute")
///
/// The arrows, the arrow keys when focused, the scroll wheel and VoiceOver's adjust actions step the value.
public struct DisplayStepper<Accessory: View>: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String
    var unit: String?
    var size: CGFloat
    let spokenValue: String
    @ViewBuilder let accessory: Accessory
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var id = UUID()

    public init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, text: String,
                unit: String? = nil, size: CGFloat = 24, spokenValue: String? = nil,
                @ViewBuilder accessory: () -> Accessory) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
        self.text = text
        self.unit = unit
        self.size = size
        self.spokenValue = spokenValue ?? text
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(text)
                .font(Theme.Fonts.mono(size, weight: .semibold))
                .foregroundStyle(isEnabled ? Theme.device.amber : Theme.device.amberDim)
                .lineLimit(1)
                .fixedSize()
            if let unit {
                Text(unit)
                    .font(Theme.Fonts.lamp())
                    .foregroundStyle(Theme.device.amberDim)
                    .fixedSize()
            }
            accessory
            VStack(spacing: 1) {
                arrow(up: true)
                arrow(up: false)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(DisplayGlass(radius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.device.amber.color.opacity(isFocused ? 0.8 : 0)))
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            change(press.key == .upArrow ? step : -step)
            return .handled
        }
        .onHover { inside in
            if inside, isEnabled {
                ScrollRouter.shared.hover(id) { delta, _ in
                    if abs(delta) >= 1 { change(delta > 0 ? step : -step) }
                }
            } else {
                ScrollRouter.shared.leave(id)
            }
        }
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(step)
            case .decrement: change(-step)
            @unknown default: break
            }
        }
    }

    private func arrow(up: Bool) -> some View {
        Button {
            change(up ? step : -step)
        } label: {
            Path { path in
                path.move(to: CGPoint(x: 0, y: up ? 4 : 0))
                path.addLine(to: CGPoint(x: 3.5, y: up ? 0 : 4))
                path.addLine(to: CGPoint(x: 7, y: up ? 4 : 0))
            }
            .stroke(isEnabled ? Theme.device.amberDim : Theme.device.lampOffText,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(width: 7, height: 4)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!isEnabled || (up ? value >= range.upperBound : value <= range.lowerBound))
        .accessibilityHidden(true)
    }

    private func change(_ delta: Double) {
        let next = min(max(value + delta, range.lowerBound), range.upperBound)
        if next != value { value = next }
    }
}

extension DisplayStepper where Accessory == EmptyView {
    public init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, text: String,
                unit: String? = nil, size: CGFloat = 24, spokenValue: String? = nil) {
        self.init(label, value: value, in: range, step: step, text: text, unit: unit, size: size,
                  spokenValue: spokenValue) { EmptyView() }
    }
}

#Preview("Zahl mit Pfeilen") {
    PreviewPair {
        Faceplate {
            HStack(spacing: 10) {
                DisplayStepper("Tempo", value: .constant(120), in: 40...240, step: 1, text: "120", unit: "BPM")
                DisplayStepper("Ton", value: .constant(0), in: -12...12, step: 1, text: "+2", size: 12)
            }
            .padding(14)
        }
    }
}
