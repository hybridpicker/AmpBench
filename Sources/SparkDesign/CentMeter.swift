import AmpText
import SwiftUI

/// What a tuner's display shows of a deviation: cents from −50 to +50, or no tone.
public struct CentReading: Equatable, Sendable {
    public var cents: Double
    /// Within the tolerance long enough: the center lights green, as the lamp "In tune" does.
    public var isInTune: Bool
    /// The tone has ended and the last value stays: drawn dim and still.
    public var isHeld: Bool

    public init(cents: Double, isInTune: Bool = false, isHeld: Bool = false) {
        self.cents = cents
        self.isInTune = isInTune
        self.isHeld = isHeld
    }

    /// For VoiceOver: "plus 0.3 cents, too high". The decimal sign follows the language.
    public var spoken: String {
        let rounded = (cents * 10).rounded() / 10
        let amount = String(format: "%.1f", locale: Texts.locale, abs(rounded))
        let deviation = rounded == 0 ? tr("%@ cents", amount)
            : rounded < 0 ? tr("minus %@ cents", amount) : tr("plus %@ cents", amount)
        let direction = isInTune ? tr("in tune")
            : rounded < 0 ? tr("too low") : rounded > 0 ? tr("too high") : tr("centered")
        return ([deviation, direction] + (isHeld ? [tr("held")] : [])).joined(separator: ", ")
    }
}

/// The needle field of a tuner: a fine scale from −50 to +50 cents behind glass, a tick for every cent, a longer one
/// every five and a number every ten, and an amber needle. The middle lights green while the tone is in tune.
///
///     CentMeter(reading: CentReading(cents: -3.2))
///     CentMeter(reading: nil)          // no tone: no needle
///
/// The needle stops at the end of the scale and gets an arrow there. It moves only as fast as its values change,
/// never with an animation of its own. VoiceOver reads the deviation in words.
public struct CentMeter: View {
    let reading: CentReading?
    var range: Double
    var height: CGFloat

    public init(reading: CentReading?, range: Double = 50, height: CGFloat = 96) {
        self.reading = reading
        self.range = range
        self.height = height
    }

    public var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(height: height)
        .background(DisplayGlass())
        .accessibilityElement()
        .accessibilityLabel(tr("Deviation"))
        .accessibilityValue(reading?.spoken ?? tr("no tone"))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let inset: CGFloat = 22
        let width = size.width - 2 * inset
        let baseline = size.height - 26
        func x(_ cents: Double) -> CGFloat { inset + CGFloat((cents + range) / (2 * range)) * width }

        // The middle: a narrow window of ±0.5 cents, green when in tune.
        let zone = max(x(0.5) - x(-0.5), 3)
        let middle = CGRect(x: x(0) - zone / 2, y: 10, width: zone, height: baseline - 10)
        let inTune = reading?.isInTune == true && reading?.isHeld == false
        context.fill(Path(roundedRect: middle, cornerRadius: 1.5),
                     with: .color((inTune ? Theme.device.on : Theme.device.amber).color.opacity(inTune ? 0.45 : 0.12)))

        // The scale.
        let whole = Int(range)
        for tick in -whole...whole {
            let isTen = tick % 10 == 0, isFive = tick % 5 == 0
            let length: CGFloat = tick == 0 ? 30 : isTen ? 20 : isFive ? 13 : 7
            let line = Path { path in
                path.move(to: CGPoint(x: x(Double(tick)), y: baseline - length))
                path.addLine(to: CGPoint(x: x(Double(tick)), y: baseline))
            }
            let color = tick == 0 ? Theme.device.amber : isFive ? Theme.device.amberDim : Theme.device.amberDim.opacity(0.55)
            context.stroke(line, with: .color(color.color), lineWidth: tick == 0 ? 1.5 : isTen ? 1.2 : 1)
            if isTen {
                let label = tick == 0 ? "0" : tick < 0 ? "−\(-tick)" : "+\(tick)"
                context.draw(Text(label).font(Theme.Fonts.mono(9.5, weight: tick == 0 ? .bold : .regular))
                    .foregroundStyle(tick == 0 ? Theme.device.amber : Theme.device.amberDim),
                             at: CGPoint(x: x(Double(tick)), y: baseline + 12))
            }
        }

        // The needle, with a soft glow, dim while held.
        guard let reading else { return }
        let clamped = min(max(reading.cents, -range), range)
        let needleX = x(clamped)
        let color = reading.isHeld ? Theme.device.amberDim : Theme.device.amber
        let needle = Path { path in
            path.move(to: CGPoint(x: needleX, y: 6))
            path.addLine(to: CGPoint(x: needleX, y: baseline + 2))
        }
        var glow = context
        if !reading.isHeld { glow.addFilter(.shadow(color: Theme.device.amber.color.opacity(0.8), radius: 4)) }
        glow.stroke(needle, with: .color(color.color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        if abs(reading.cents) > range {
            // Off the scale: an arrow at the end points on.
            let direction: CGFloat = reading.cents > 0 ? 1 : -1
            let tip = CGPoint(x: needleX + direction * 12, y: 14)
            let arrow = Path { path in
                path.move(to: CGPoint(x: needleX + direction * 4, y: 8))
                path.addLine(to: tip)
                path.addLine(to: CGPoint(x: needleX + direction * 4, y: 20))
            }
            context.stroke(arrow, with: .color(color.color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A strobe as on a tuner of the old kind: two rows of lit segments that drift to the right when the tone is too high
/// and to the left when it is too low, faster the further off it is, and stand still when it is in tune. The lower
/// row moves four times as fast, so a tenth of a cent is still seen to move.
///
///     StrobeBand(reading: CentReading(cents: 0.4))
///
/// With "Reduce motion" the rows do not move; they stand shifted by the deviation instead, like a needle.
/// VoiceOver reads the deviation in words.
public struct StrobeBand: View {
    let reading: CentReading?
    var height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = StrobeMotion()

    public init(reading: CentReading?, height: CGFloat = 96) {
        self.reading = reading
        self.height = height
    }

    /// Points per second per cent of the upper row.
    static let speed: Double = 6
    static let period: CGFloat = 18

    public var body: some View {
        Group {
            if reduceMotion || reading == nil || reading?.isHeld == true {
                Canvas { context, size in
                    let still = reading.map { min(max($0.cents, -50), 50) / 50 * Double(Self.period) / 2 } ?? 0
                    draw(in: &context, size: size, offsets: (still, still))
                }
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        let offsets = motion.advance(to: timeline.date, cents: reading?.cents ?? 0)
                        draw(in: &context, size: size, offsets: offsets)
                    }
                }
            }
        }
        .frame(height: height)
        .background(DisplayGlass())
        .accessibilityElement()
        .accessibilityLabel(tr("Strobe"))
        .accessibilityValue(reading?.spoken ?? tr("no tone"))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, offsets: (Double, Double)) {
        let inset: CGFloat = 14
        let rowHeight = (size.height - 2 * inset - 10) / 2
        let lit = reading != nil
        let inTune = reading?.isInTune == true && reading?.isHeld == false
        let color = !lit ? Theme.device.meterOff : reading?.isHeld == true ? Theme.device.amberDim : Theme.device.amber
        for (row, offset) in [offsets.0, offsets.1].enumerated() {
            let top = inset + CGFloat(row) * (rowHeight + 10)
            var clipped = context
            clipped.clip(to: Path(roundedRect: CGRect(x: inset, y: top, width: size.width - 2 * inset, height: rowHeight),
                                  cornerRadius: 2))
            let shift = CGFloat(offset).truncatingRemainder(dividingBy: Self.period)
            var x = inset - Self.period + shift
            while x < size.width - inset {
                let rect = CGRect(x: x, y: top, width: Self.period / 2, height: rowHeight)
                if lit, !reduceMotion {
                    var glow = clipped
                    glow.addFilter(.shadow(color: color.color.opacity(0.5), radius: 2.5))
                    glow.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.color))
                } else {
                    clipped.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.color))
                }
                x += Self.period
            }
        }
        // The middle mark, green while in tune.
        let mark = Path { path in
            path.move(to: CGPoint(x: size.width / 2, y: 4))
            path.addLine(to: CGPoint(x: size.width / 2, y: size.height - 4))
        }
        context.stroke(mark, with: .color((inTune ? Theme.device.on : Theme.device.amberDim).color.opacity(inTune ? 1 : 0.6)),
                       lineWidth: inTune ? 2 : 1)
    }
}

/// The position of the strobe's rows, carried from frame to frame.
final class StrobeMotion {
    private var last: Date?
    private var upper = 0.0
    private var lower = 0.0

    /// Moves the rows on by the time since the previous frame, at the speed of `cents`.
    func advance(to date: Date, cents: Double) -> (Double, Double) {
        let elapsed = last.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        last = date
        let clamped = min(max(cents, -50), 50)
        upper += clamped * StrobeBand.speed * elapsed
        lower += clamped * StrobeBand.speed * 4 * elapsed
        let period = Double(StrobeBand.period)
        upper = upper.truncatingRemainder(dividingBy: period)
        lower = lower.truncatingRemainder(dividingBy: period)
        return (upper, lower)
    }
}

#Preview("Needle field") {
    PreviewPair {
        Faceplate(radius: Theme.Radius.panel) {
            VStack(spacing: 12) {
                CentMeter(reading: CentReading(cents: -7.4))
                CentMeter(reading: CentReading(cents: 0.2, isInTune: true))
                CentMeter(reading: CentReading(cents: 63, isHeld: true))
                CentMeter(reading: nil)
            }
            .padding(14)
            .frame(width: 520)
        }
    }
}

#Preview("Strobe") {
    PreviewPair {
        Faceplate(radius: Theme.Radius.panel) {
            VStack(spacing: 12) {
                StrobeBand(reading: CentReading(cents: 2.5))
                StrobeBand(reading: CentReading(cents: 0.1, isInTune: true))
                StrobeBand(reading: nil)
            }
            .padding(14)
            .frame(width: 520)
        }
    }
}
