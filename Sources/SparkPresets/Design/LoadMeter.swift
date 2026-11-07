import SwiftUI

/// A row of amber segments that fills while a preset travels to or from the amp, chunk by chunk as the amp confirms
/// them. A switch between slots, which is a single message, runs a short sweep instead. When done, the row lights up
/// fully for a moment and goes dark. With "Reduce motion" the sweep and the fading are left out.
struct LoadMeter: View {
    let transfer: Transfer?
    var segments = 24
    var height: CGFloat = 5
    var showsLabel = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finishing = false
    @State private var last: Transfer?

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.animation(paused: transfer?.fraction != nil || transfer == nil || reduceMotion)) { context in
                HStack(spacing: 2) {
                    ForEach(0..<segments, id: \.self) { index in
                        segment(lit: brightness(of: index, at: context.date))
                    }
                }
            }
            .frame(height: height)
            if showsLabel {
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                    .tracking(0.6)
                    .foregroundStyle(Theme.amberDim)
                    .frame(width: 92, alignment: .trailing)
                    .lineLimit(1)
            }
        }
        .onChange(of: transfer) { old, new in
            if let new { last = new }
            guard new == nil, old != nil else { return }
            finishing = true
            Task {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 250 : 450))
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { finishing = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Übertragung")
        .accessibilityValue(accessibilityText)
        .accessibilityHidden(transfer == nil)
    }

    private func segment(lit: Double) -> some View {
        RoundedRectangle(cornerRadius: 1.2)
            .fill(lit > 0 ? Theme.amberHot.opacity(0.35 + 0.65 * lit) : Theme.lampOff.opacity(0.7))
            .shadow(color: Theme.amberHot.opacity(0.6 * lit), radius: 2.5 * lit)
    }

    /// 0 for dark, 1 for fully lit.
    private func brightness(of index: Int, at date: Date) -> Double {
        if finishing && transfer == nil { return 1 }
        guard let transfer else { return 0 }
        if let fraction = transfer.fraction {
            let filled = fraction * Double(segments)
            return min(max(filled - Double(index), 0), 1)
        }
        if reduceMotion { return 0.5 }
        // A short sweep for a switch or until the size is known.
        let position = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8
        let head = position * Double(segments + 6) - 3
        return max(0, 1 - abs(Double(index) - head) / 3)
    }

    private var label: String {
        let shown = transfer ?? (finishing ? last : nil)
        guard let shown else { return "" }
        let count = shown.total.map { " \(min(shown.done, $0))/\($0)" } ?? ""
        switch shown.kind {
        case .sending: return (transfer == nil ? "GELADEN" : "LÄDT") + (transfer == nil ? "" : count)
        case .reading: return (transfer == nil ? "GELESEN" : "LIEST") + (transfer == nil ? "" : count)
        case .switching: return transfer == nil ? "UMGESCHALTET" : "SCHALTET"
        }
    }

    private var accessibilityText: String {
        guard let transfer else { return "" }
        if let fraction = transfer.fraction { return "\(Int((fraction * 100).rounded())) Prozent" }
        return "läuft"
    }
}
