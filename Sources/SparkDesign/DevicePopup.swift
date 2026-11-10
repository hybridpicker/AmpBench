import SwiftUI

/// A choice on a device front: a dark recessed field with the current value and a chevron. Inside is a normal
/// menu, so choosing works like everywhere on the Mac, with the keyboard and VoiceOver.
///
///     DevicePopup("Input", value: input.name) {
///         Picker("Input", selection: $inputID) { ... }.pickerStyle(.inline)
///     }
///
///     DevicePopup("Time signature", selection: $beats, options: [(4, "4/4"), (3, "3/4")])
///
/// No system pop-up button sits on a front directly; this is the one way to choose there.
public struct DevicePopup<Content: View>: View {
    let label: String
    let value: String
    var height: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var isEnabled

    public init(_ label: String, value: String, height: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.label = label
        self.value = value
        self.height = height
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isEnabled ? Theme.device.fieldText : Theme.device.keyTextDisabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Chevron(color: isEnabled ? Theme.device.engraving : Theme.device.keyTextDisabled)
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(height: height)
            .background(DeviceField())
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.key))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .help(label)
    }
}

extension DevicePopup {
    /// A popup over a fixed list of choices.
    public init<Value: Hashable>(_ label: String, selection: Binding<Value>, options: [(Value, String)],
                                 height: CGFloat = 24) where Content == AnyView {
        let value = options.first { $0.0 == selection.wrappedValue }?.1 ?? ""
        self.init(label, value: value, height: height) {
            AnyView(Picker(label, selection: selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].1).tag(options[index].0)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden())
        }
    }
}

/// The recessed field of a popup or a small value on a front.
public struct DeviceField: View {
    var radius: CGFloat

    public init(radius: CGFloat = Theme.Radius.key) {
        self.radius = radius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        shape
            .fill(Theme.device.field)
            .overlay(shape.fill(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top,
                                               endPoint: UnitPoint(x: 0.5, y: 0.3))))
            .overlay(shape.strokeBorder(Theme.device.fieldEdge, lineWidth: 1))
            .shadow(color: Theme.device.grooveLight.color, radius: 0, y: 1)
    }
}

/// A small chevron pointing down, drawn, so it has the same weight everywhere.
public struct Chevron: View {
    var color: Swatch
    var size: CGFloat

    public init(color: Swatch = Theme.device.engraving, size: CGFloat = 7) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size * 0.3))
            path.addLine(to: CGPoint(x: size / 2, y: size * 0.8))
            path.addLine(to: CGPoint(x: size, y: size * 0.3))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview("Choice on the device") {
    PreviewPair {
        Faceplate {
            VStack(alignment: .leading, spacing: 8) {
                DevicePopup("Input", value: "Spark MINI USB") { Button("Spark MINI USB") {} }
                DevicePopup("Time signature", selection: .constant(4), options: [(3, "3/4"), (4, "4/4")])
                    .frame(width: 70)
                DevicePopup("Count-in", value: "No count-in") { Button("No count-in") {} }
                    .disabled(true)
            }
            .padding(14)
            .frame(width: 220)
        }
    }
}
