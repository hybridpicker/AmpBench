import SwiftUI

/// An on/off switch on a device front: a dark slot with a light thumb, amber when on.
///
///     DeviceToggle("Retro", isOn: $retro)
///
/// The label is for VoiceOver and the tooltip; put an engraving beside it for the eye.
public struct DeviceToggle: View {
    let label: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.device.switchOn : Theme.device.switchOff)
                    .overlay(Capsule().strokeBorder(Theme.device.fieldEdge, lineWidth: 1))
                Circle()
                    .fill(isOn ? Color.white : Theme.device.switchThumb.color)
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: 30, height: 17)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "an" : "aus")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A two-way lever for switch parameters, with both states written beside it.
///
///     LeverSwitch(name: "Boost", isOn: on, off: "Aus", on: "An", accent: accent) { toggle() }
public struct LeverSwitch: View {
    let name: String
    let isOn: Bool
    let off: String
    let on: String
    let accent: Color
    var isEnabled: Bool
    let action: () -> Void

    public init(name: String, isOn: Bool, off: String, on: String, accent: Color, isEnabled: Bool = true,
                action: @escaping () -> Void) {
        self.name = name
        self.isOn = isOn
        self.off = off
        self.on = on
        self.accent = accent
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(off).foregroundStyle(isOn ? Theme.device.labelDim : Theme.device.amber).fixedSize()
                    ZStack(alignment: isOn ? .trailing : .leading) {
                        Capsule().fill(Theme.device.field).frame(width: 34, height: 16)
                            .overlay(Capsule().strokeBorder(Theme.device.fieldEdge, lineWidth: 1))
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.device.metalLight.color, Theme.device.metalDark.color],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 18, height: 14)
                            .padding(.horizontal, 1)
                            .overlay(Capsule().fill(accent.opacity(isOn ? 0.35 : 0)).frame(width: 18, height: 14)
                                .padding(.horizontal, 1))
                    }
                    Text(on).foregroundStyle(isOn ? Theme.device.amber : Theme.device.labelDim).fixedSize()
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            PanelLabel(name, color: Theme.device.labelDim)
        }
        .frame(minHeight: 66)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(isOn ? on : off)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

#Preview("Schalter") {
    PreviewPair {
        Faceplate {
            HStack(spacing: 18) {
                DeviceToggle("Retro", isOn: .constant(false))
                DeviceToggle("Retro", isOn: .constant(true))
                LeverSwitch(name: "Boost", isOn: true, off: "Aus", on: "An", accent: .orange) {}
            }
            .padding(14)
        }
    }
}
