import AppKit
import SparkControl
import SwiftUI

/// Hands the scroll wheel to the control under the pointer. SwiftUI on macOS 14 has no scroll event for views, so a
/// local event monitor takes the wheel while a control is hovered and lets it through otherwise.
@MainActor
final class ScrollRouter {
    static let shared = ScrollRouter()
    private var monitor: Any?
    private var target: ((CGFloat, Bool) -> Void)?
    private var owner: UUID?

    func hover(_ id: UUID, _ handler: @escaping (CGFloat, Bool) -> Void) {
        owner = id
        target = handler
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
    }

    func leave(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        target = nil
    }
}

/// A rotary control for a parameter: a knob from 0 to 1, or a selector with fixed steps.
///
/// Drag up or down (with ⌥ for fine steps), use the scroll wheel, the arrow keys (with ⇧ for big steps) or
/// VoiceOver's adjust actions. A double click goes back to the start value. A whole drag is one undo step.
struct RotaryControl: View {
    enum Mode {
        case continuous
        case steps([ParameterInfo.Option])
    }

    let name: String
    let value: Float
    let mode: Mode
    let accent: Color
    var size: CGFloat = 58
    var startValue: Float?
    var isEnabled = true
    let display: (Float) -> String
    let onBegin: () -> Void
    let onChange: (Float) -> Void
    let onEnd: () -> Void

    @State private var dragStart: Float?
    @State private var isHovering = false
    @State private var scrollEnd: Task<Void, Never>?
    @State private var id = UUID()
    @FocusState private var isFocused: Bool

    private var options: [ParameterInfo.Option] {
        if case .steps(let options) = mode { return options }
        return []
    }

    /// Where the pointer stands, 0 to 1.
    private var position: Double {
        guard !options.isEmpty else { return Double(value) }
        let index = nearestIndex(value)
        return options.count > 1 ? Double(index) / Double(options.count - 1) : 0
    }

    private func nearestIndex(_ value: Float) -> Int {
        options.indices.min { abs(options[$0].value - value) < abs(options[$1].value - value) } ?? 0
    }

    var body: some View {
        VStack(spacing: 4) {
            KnobFace(position: position, accent: accent, ticks: options.isEmpty ? 11 : options.count,
                     isActive: dragStart != nil || isFocused, isEnabled: isEnabled)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(accent.opacity(isFocused ? 0.9 : 0), lineWidth: 1.5).padding(-2))
                .contentShape(Circle())
                .gesture(drag)
                .onTapGesture(count: 2) { reset() }
                .onHover(perform: hover)
                .help(name)
            Text(name)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(display(value))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(dragStart != nil || isHovering ? Theme.amber : Theme.amberDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: size + 8)
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
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1, big: true)
            case .decrement: step(-1, big: true)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Startwert") { reset() }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                guard isEnabled else { return }
                if dragStart == nil {
                    dragStart = value
                    onBegin()
                }
                let fine = NSEvent.modifierFlags.contains(.option)
                let distance = Float(-gesture.translation.height)
                if options.isEmpty {
                    onChange(clamp((dragStart ?? value) + distance / (fine ? 900 : 180)))
                } else {
                    let start = nearestIndex(dragStart ?? value)
                    let index = min(max(start + Int((distance / 22).rounded()), 0), options.count - 1)
                    if options[index].value != value { onChange(options[index].value) }
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
        if options.isEmpty {
            onChange(clamp(value + Float(delta) / (fine ? 2000 : 400)))
        } else if abs(delta) >= 1 {
            let index = min(max(nearestIndex(value) + (delta > 0 ? 1 : -1), 0), options.count - 1)
            if options[index].value != value { onChange(options[index].value) }
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
        if options.isEmpty {
            onChange(clamp(value + Float(direction) * (big ? 0.1 : 0.01)))
        } else {
            let index = min(max(nearestIndex(value) + direction, 0), options.count - 1)
            onChange(options[index].value)
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
