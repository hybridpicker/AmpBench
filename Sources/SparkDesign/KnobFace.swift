import SwiftUI

/// Draws a knob: a ring for its travel from 225° over 270° in the accent color, a dark body with soft light from
/// the top left, and an amber pointer. 12 o'clock is the middle. Selectors get a dot for every position.
public struct KnobFace: View {
    /// From 0 to 1.
    let position: Double
    let accent: Color
    var ticks: Int
    var isActive: Bool
    var isEnabled: Bool

    public static let sweep = 270.0

    public init(position: Double, accent: Color, ticks: Int = 0, isActive: Bool = false, isEnabled: Bool = true) {
        self.position = position
        self.accent = accent
        self.ticks = ticks
        self.isActive = isActive
        self.isEnabled = isEnabled
    }

    public var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // The ring sits 7 pt outside a 56 pt body: the body is 80 % of the whole face.
            let ringRadius = side * 0.46
            let radius = side * 0.40
            let clamped = min(max(position, 0), 1)
            let angle = Angle.degrees(-135 + Self.sweep * clamped)

            func point(_ angle: Angle, _ distance: CGFloat) -> CGPoint {
                CGPoint(x: center.x + sin(angle.radians) * distance, y: center.y - cos(angle.radians) * distance)
            }

            // The ring: the whole travel faint, the value in the accent color.
            let ringWidth = max(2, side * 0.05)
            var track = Path()
            track.addArc(center: center, radius: ringRadius, startAngle: .degrees(-225), endAngle: .degrees(45),
                         clockwise: false)
            context.stroke(track, with: .color(Theme.device.knobTrack.color),
                           style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
            if clamped > 0 {
                var arc = Path()
                arc.addArc(center: center, radius: ringRadius, startAngle: .degrees(-225),
                           endAngle: .degrees(-225 + Self.sweep * clamped), clockwise: false)
                var glow = context
                glow.addFilter(.shadow(color: accent.opacity(isActive ? 0.8 : 0.4), radius: isActive ? 4 : 2))
                glow.stroke(arc, with: .color(isEnabled ? accent : Color.gray),
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
            }

            // A dot outside the ring for every position of a selector.
            if ticks > 1 {
                for tick in 0..<ticks {
                    let fraction = Double(tick) / Double(ticks - 1)
                    let tickPoint = point(.degrees(-135 + Self.sweep * fraction), side * 0.5 - 1.2)
                    let lit = abs(fraction - clamped) < 0.0001
                    context.fill(Path(ellipseIn: CGRect(x: tickPoint.x - 1.2, y: tickPoint.y - 1.2, width: 2.4, height: 2.4)),
                                 with: .color(lit ? Theme.device.amber.color : Color.white.opacity(0.3)))
                }
            }

            // The body with its shadow.
            let body = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2,
                                              height: radius * 2))
            var shadow = context
            shadow.addFilter(.shadow(color: .black.opacity(0.6), radius: side * 0.06, y: side * 0.04))
            shadow.fill(body, with: .color(Theme.device.knobBottom.color))
            context.fill(body, with: .radialGradient(
                Gradient(colors: [Theme.device.knobTop.color, Theme.device.knobBottom.color]),
                center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.4),
                startRadius: 0, endRadius: radius * 1.4))
            context.stroke(body, with: .color(Theme.device.knobEdge.color), lineWidth: 1)
            var highlight = Path()
            highlight.addArc(center: center, radius: radius - 1, startAngle: .degrees(-160), endAngle: .degrees(-20),
                             clockwise: false)
            context.stroke(highlight, with: .color(.white.opacity(0.12)), lineWidth: 1)

            // The pointer.
            var pointer = Path()
            pointer.move(to: point(angle, radius * 0.18))
            pointer.addLine(to: point(angle, radius * 0.86))
            var lit = context
            lit.addFilter(.shadow(color: Theme.device.amber.color.opacity(isEnabled ? 0.6 : 0), radius: 3))
            lit.stroke(pointer, with: .color(isEnabled ? Theme.device.amber.color : Color(white: 0.6)),
                       style: StrokeStyle(lineWidth: max(1.5, side * 0.045), lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

/// A small knob on a pedal or the amp, for looking only: a dark body with an amber pointer.
public struct MiniKnob: View {
    let position: Double
    var size: CGFloat
    var isEnabled: Bool

    public init(position: Double, size: CGFloat = 14, isEnabled: Bool = true) {
        self.position = position
        self.size = size
        self.isEnabled = isEnabled
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let side = min(canvasSize.width, canvasSize.height)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = side / 2 - 0.5
            let body = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2,
                                              height: radius * 2))
            context.fill(body, with: .radialGradient(
                Gradient(colors: [Theme.device.knobTop.color, Theme.device.knobBottom.color]),
                center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.3), startRadius: 0,
                endRadius: radius * 1.4))
            context.stroke(body, with: .color(Theme.device.knobEdge.color), lineWidth: 1)
            let angle = Angle.degrees(-135 + KnobFace.sweep * min(max(position, 0), 1))
            var pointer = Path()
            pointer.move(to: center)
            pointer.addLine(to: CGPoint(x: center.x + sin(angle.radians) * radius * 0.8,
                                        y: center.y - cos(angle.radians) * radius * 0.8))
            context.stroke(pointer, with: .color(isEnabled ? Theme.device.amber.color : Color(white: 0.55)),
                           style: StrokeStyle(lineWidth: max(1.5, side * 0.13), lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview("Knob face") {
    PreviewPair {
        Faceplate(radius: Theme.Radius.panel) {
            HStack(spacing: 16) {
                KnobFace(position: 0.7, accent: .orange).frame(width: 70, height: 70)
                KnobFace(position: 0.5, accent: .purple, ticks: 5).frame(width: 70, height: 70)
                MiniKnob(position: 0.3)
                MiniKnob(position: 0.8, size: 18)
            }
            .padding(20)
        }
    }
}
