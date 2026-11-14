import AmpText
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Hands the scroll wheel to the control under the pointer. SwiftUI on macOS 14 has no scroll event for views, so a
/// local event monitor takes the wheel while a control is hovered and lets it through otherwise.
@MainActor
public final class ScrollRouter {
    public static let shared = ScrollRouter()
    private var monitor: Any?
    private var target: ((CGFloat, Bool) -> Void)?
    private var owner: UUID?

    /// `handler` gets the vertical delta and whether ⌥ is held for fine steps.
    public func hover(_ id: UUID, _ handler: @escaping (CGFloat, Bool) -> Void) {
        owner = id
        target = handler
        #if os(macOS)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
                let fine = event.modifierFlags.contains(.option)
                // Local monitors run on the main thread.
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let target = ScrollRouter.shared.target else { return false }
                    target(delta, fine)
                    return true
                }
                return handled ? nil : event
            }
        }
        #endif
    }

    public func leave(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        target = nil
    }
}

/// A rotary control: a knob from 0 to 1, or a selector with fixed steps. The ring shows the travel in the accent
/// color, the amber pointer the position, the engraved name and the amber value below say what and how much.
///
///     Knob(name: "Gain", value: 0.7, accent: drive, display: { String(format: "%.1f", $0 * 10) },
///          onBegin: begin, onChange: set, onEnd: end)
///
/// Drag up or down (with ⌥ for fine steps), scroll (fine), the arrow keys (with ⇧ for big steps) or VoiceOver's
/// adjust actions. A double click goes back to the start value. A whole drag or scroll is one `onBegin`/`onEnd`.
public struct Knob: View {
    public enum Mode: Sendable {
        case continuous
        /// The values of a selector's positions, in order.
        case steps([Float])
    }

    let name: String
    let value: Float
    var mode: Mode
    let accent: Color
    var size: CGFloat
    var startValue: Float?
    var isEnabled: Bool
    let display: (Float) -> String
    let onBegin: () -> Void
    let onChange: (Float) -> Void
    let onEnd: () -> Void

    @State private var dragStart: Float?
    @State private var isHovering = false
    @State private var scrollEnd: Task<Void, Never>?
    @State private var id = UUID()
    @FocusState private var isFocused: Bool

    public init(name: String, value: Float, mode: Mode = .continuous, accent: Color = Theme.device.amber.color,
                size: CGFloat = 56, startValue: Float? = nil, isEnabled: Bool = true,
                display: @escaping (Float) -> String,
                onBegin: @escaping () -> Void = {}, onChange: @escaping (Float) -> Void, onEnd: @escaping () -> Void = {}) {
        self.name = name
        self.value = value
        self.mode = mode
        self.accent = accent
        self.size = size
        self.startValue = startValue
        self.isEnabled = isEnabled
        self.display = display
        self.onBegin = onBegin
        self.onChange = onChange
        self.onEnd = onEnd
    }

    private var steps: [Float] {
        if case .steps(let values) = mode { return values }
        return []
    }

    /// Where the pointer stands, 0 to 1.
    private var position: Double {
        guard !steps.isEmpty else { return Double(value) }
        return steps.count > 1 ? Double(nearestIndex(value)) / Double(steps.count - 1) : 0
    }

    private func nearestIndex(_ value: Float) -> Int {
        steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 0
    }

    public var body: some View {
        VStack(spacing: 0) {
            KnobFace(position: position, accent: accent, ticks: steps.count, isActive: dragStart != nil || isFocused,
                     isEnabled: isEnabled)
                .frame(width: size + 14, height: size + 14)
                .overlay(Circle().strokeBorder(Theme.device.amber.color.opacity(isFocused ? 0.9 : 0), lineWidth: 1.5)
                    .padding(-1))
                .contentShape(Circle())
                .gesture(drag)
                .onTapGesture(count: 2) { reset() }
                .onHover(perform: hover)
                .help(name)
            PanelLabel(name, color: Theme.device.labelDim)
                .minimumScaleFactor(0.75)
                .padding(.top, 6)
            Text(display(value))
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(dragStart != nil || isHovering ? Theme.device.amberHot : Theme.device.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 2)
        }
        .frame(minWidth: size + 20)
        .opacity(isEnabled ? 1 : 0.55)
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow]) { press in
            let up = press.key == .upArrow || press.key == .rightArrow
            step(up ? 1 : -1, big: press.modifiers.contains(.shift))
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(display(value))
        .accessibilityHint(tr("Drag, scroll or use the arrow keys. A double-click sets the default value."))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1, big: true)
            case .decrement: step(-1, big: true)
            @unknown default: break
            }
        }
        .accessibilityAction(named: tr("Default value")) { reset() }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                guard isEnabled else { return }
                if dragStart == nil {
                    dragStart = value
                    onBegin()
                }
                #if os(macOS)
                let fine = NSEvent.modifierFlags.contains(.option)
                #else
                // A finger has no ⌥: it drags at the normal speed. A hardware keyboard's arrow keys step finely.
                let fine = false
                #endif
                let distance = Float(-gesture.translation.height)
                if steps.isEmpty {
                    onChange(clamp((dragStart ?? value) + distance / (fine ? 900 : 180)))
                } else {
                    let start = nearestIndex(dragStart ?? value)
                    let index = min(max(start + Int((distance / 22).rounded()), 0), steps.count - 1)
                    if steps[index] != value { onChange(steps[index]) }
                }
            }
            .onEnded { _ in
                guard dragStart != nil else { return }
                dragStart = nil
                onEnd()
            }
    }

    private func hover(_ inside: Bool) {
        isHovering = inside
        if inside, isEnabled {
            ScrollRouter.shared.hover(id) { delta, fine in scroll(delta, fine: fine) }
        } else {
            ScrollRouter.shared.leave(id)
        }
    }

    /// Scrolling is one undo step until it pauses.
    private func scroll(_ delta: CGFloat, fine: Bool) {
        guard isEnabled, delta != 0 else { return }
        if scrollEnd == nil { onBegin() }
        scrollEnd?.cancel()
        if steps.isEmpty {
            onChange(clamp(value + Float(delta) / (fine ? 2000 : 400)))
        } else if abs(delta) >= 1 {
            let index = min(max(nearestIndex(value) + (delta > 0 ? 1 : -1), 0), steps.count - 1)
            if steps[index] != value { onChange(steps[index]) }
        }
        scrollEnd = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            scrollEnd = nil
            onEnd()
        }
    }

    private func step(_ direction: Int, big: Bool) {
        guard isEnabled else { return }
        onBegin()
        if steps.isEmpty {
            onChange(clamp(value + Float(direction) * (big ? 0.1 : 0.01)))
        } else {
            let index = min(max(nearestIndex(value) + direction, 0), steps.count - 1)
            onChange(steps[index])
        }
        onEnd()
    }

    private func reset() {
        guard isEnabled, let startValue, startValue != value else { return }
        onBegin()
        onChange(startValue)
        onEnd()
    }

    private func clamp(_ value: Float) -> Float { min(max(value, 0), 1) }
}

#Preview("Knobs") {
    PreviewPair {
        Faceplate(radius: Theme.Radius.panel) {
            HStack(spacing: 22) {
                Knob(name: "Gain", value: 0.7, accent: Swatch(hex: 0xF28A3C).color,
                     display: { String(format: "%.1f", $0 * 10) }, onChange: { _ in })
                Knob(name: "Tone", value: 0.5, display: { String(format: "%.1f", $0 * 10) }, onChange: { _ in })
                Knob(name: "Type", value: 0.5, mode: .steps([0, 0.5, 1]), display: { _ in "B" }, onChange: { _ in })
            }
            .padding(20)
        }
    }
}
