import SwiftUI

/// Draws a rotary control: scale, value arc, a knurled skirt, a cap with soft light and a glowing pointer.
/// The pointer turns from -135° to +135°, 12 o'clock is the middle.
struct KnobFace: View {
    /// From 0 to 1.
    let position: Double
    let accent: Color
    /// Ticks on the scale. A selector shows one per option.
    var ticks = 11
    var isActive = false
    var isEnabled = true

    static let sweep = 270.0

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side * 0.34
            let angle = Angle.degrees(-135 + Self.sweep * min(max(position, 0), 1))

            func point(_ angle: Angle, _ distance: CGFloat) -> CGPoint {
                CGPoint(x: center.x + sin(angle.radians) * distance, y: center.y - cos(angle.radians) * distance)
            }

            // Scale ticks around the knob, lit up to the value.
            for tick in 0..<ticks {
                let fraction = ticks > 1 ? Double(tick) / Double(ticks - 1) : 0
                let tickAngle = Angle.degrees(-135 + Self.sweep * fraction)
                var path = Path()
                path.move(to: point(tickAngle, side * 0.43))
                path.addLine(to: point(tickAngle, side * 0.48))
                let lit = fraction <= position + 0.0001 && isEnabled
                context.stroke(path, with: .color(lit ? accent.opacity(0.9) : Color.white.opacity(0.22)),
                               style: StrokeStyle(lineWidth: max(1, side * 0.025), lineCap: .round))
            }

            // The value arc, glowing softly.
            var arc = Path()
            arc.addArc(center: center, radius: side * 0.405, startAngle: .degrees(-225),
                       endAngle: .degrees(-225 + Self.sweep * min(max(position, 0), 1)), clockwise: false)
            var glow = context
            glow.addFilter(.shadow(color: accent.opacity(isActive ? 0.9 : 0.55), radius: isActive ? 5 : 3))
            glow.stroke(arc, with: .color(isEnabled ? accent : Color.gray),
                        style: StrokeStyle(lineWidth: max(1.5, side * 0.035), lineCap: .round))

            // Shadow under the knob.
            var shadow = context
            shadow.addFilter(.shadow(color: .black.opacity(0.75), radius: side * 0.06, y: side * 0.04))
            shadow.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2,
                                                height: radius * 2)), with: .color(Color(white: 0.1)))

            // Knurled skirt.
            let skirt = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2,
                                               height: radius * 2))
            context.fill(skirt, with: .linearGradient(Gradient(colors: [Color(white: 0.4), Color(white: 0.09)]),
                                                      startPoint: CGPoint(x: center.x, y: center.y - radius),
                                                      endPoint: CGPoint(x: center.x, y: center.y + radius)))
            var knurl = Path()
            for step in 0..<36 {
                let knurlAngle = Angle.degrees(Double(step) * 10)
                knurl.move(to: point(knurlAngle, radius * 0.84))
                knurl.addLine(to: point(knurlAngle, radius * 0.99))
            }
            context.stroke(knurl, with: .color(.black.opacity(0.45)), lineWidth: max(0.8, side * 0.018))

            // The cap, with light from the top left.
            let capRadius = radius * 0.76
            let cap = Path(ellipseIn: CGRect(x: center.x - capRadius, y: center.y - capRadius, width: capRadius * 2,
                                             height: capRadius * 2))
            context.fill(cap, with: .linearGradient(Gradient(colors: [Color(white: 0.33), Color(white: 0.13)]),
                                                    startPoint: CGPoint(x: center.x, y: center.y - capRadius),
                                                    endPoint: CGPoint(x: center.x, y: center.y + capRadius)))
            context.fill(cap, with: .radialGradient(Gradient(colors: [Color.white.opacity(0.16), .clear]),
                                                    center: CGPoint(x: center.x - capRadius * 0.35,
                                                                    y: center.y - capRadius * 0.45),
                                                    startRadius: 0, endRadius: capRadius * 1.1))
            context.stroke(cap, with: .color(.white.opacity(0.08)), lineWidth: 0.6)

            // The pointer.
            var pointer = Path()
            pointer.move(to: point(angle, capRadius * 0.25))
            pointer.addLine(to: point(angle, capRadius * 0.92))
            var lit = context
            lit.addFilter(.shadow(color: accent.opacity(isEnabled ? 0.8 : 0), radius: 3))
            lit.stroke(pointer, with: .color(isEnabled ? Color(white: 0.96) : Color(white: 0.6)),
                       style: StrokeStyle(lineWidth: max(1.5, side * 0.05), lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}
