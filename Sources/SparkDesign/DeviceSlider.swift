#if os(macOS)
import AppKit
#endif
import SwiftUI

/// A fader on a device front: a recessed track filled in amber up to the value, with a metal thumb.
///
///     DeviceSlider("Tempo", value: $tempo, in: 0.5...1.5, step: 0.05, valueText: "\(Int(tempo * 100)) percent")
///
/// Drag or click on the track, scroll, use the arrow keys when focused, or VoiceOver's adjust actions.
public struct DeviceSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var id = UUID()

    public init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                valueText: String) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
        self.valueText = valueText
    }

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumb: CGFloat = 14
            let x = (width - thumb) * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.device.display).frame(height: 4)
                    .overlay(Capsule().strokeBorder(Color.black, lineWidth: 0.5))
                Capsule().fill(isEnabled ? Theme.device.amber : Theme.device.amberDim)
                    .frame(width: max(x + thumb / 2, 2), height: 4)
                Circle()
                    .fill(LinearGradient(colors: [Swatch(hex: 0xDADADE).color, Swatch(hex: 0x9A9AA0).color],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
                    .overlay(Circle().strokeBorder(Theme.device.amber.color.opacity(isFocused ? 0.9 : 0), lineWidth: 1.5)
                        .padding(-2))
                    .frame(width: thumb, height: thumb)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                guard isEnabled, width > thumb else { return }
                set(range.lowerBound + Double((gesture.location.x - thumb / 2) / (width - thumb))
                    * (range.upperBound - range.lowerBound))
            })
            .onHover { inside in
                if inside, isEnabled {
                    ScrollRouter.shared.hover(id) { delta, _ in
                        if abs(delta) >= 1 { set(value + (delta > 0 ? step : -step)) }
                    }
                } else {
                    ScrollRouter.shared.leave(id)
                }
            }
        }
        .frame(height: 18)
        .opacity(isEnabled ? 1 : 0.6)
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow]) { press in
            set(value + (press.key == .upArrow || press.key == .rightArrow ? step : -step))
            return .handled
        }
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + step)
            case .decrement: set(value - step)
            @unknown default: break
            }
        }
    }

    private func set(_ newValue: Double) {
        let stepped = step > 0 ? (newValue / step).rounded() * step : newValue
        let clamped = min(max(stepped, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }
}

#Preview("Slider") {
    PreviewPair {
        Faceplate {
            HStack {
                PanelLabel("Tempo")
                DeviceSlider("Tempo", value: .constant(1), in: 0.5...1.5, step: 0.05, valueText: "100 percent")
                    .frame(width: 110)
            }
            .padding(14)
        }
    }
}
