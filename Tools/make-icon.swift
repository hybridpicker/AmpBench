// Draws AmpBench's icon: a dark device front with one sign on it, the glowing record key (a waveform that peaks
// in a spark) set into the ring of an amber-lit control, so recording and sound are one thing.
// Usage: swift Tools/make-icon.swift <output.icns>
import AppKit
import CoreGraphics
import Foundation

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func linear(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ context: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
}

func draw(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)

    // The standard macOS icon grid: 824 points of body inside 1024, with a soft shadow below.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0, 0, 0, 0.45))
    context.addPath(shape)
    context.setFillColor(color(0.1, 0.1, 0.11))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    linear(context, [color(0.235, 0.24, 0.26), color(0.075, 0.08, 0.09)],
           from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // A soft light from above, like a metal front panel.
    radial(context, [color(1, 1, 1, 0.12), color(1, 1, 1, 0)], center: CGPoint(x: 512, y: 980), radius: 560)
    context.restoreGState()

    let inset = shape.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 1)
    context.saveGState()
    context.addPath(inset)
    context.clip()
    linear(context, [color(1, 1, 1, 0.3), color(1, 1, 1, 0.04)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    context.restoreGState()

    let center = CGPoint(x: 512, y: 512)
    drawRingedRecordKey(context, center: center)
    return context.makeImage()!
}

/// The record key inside a control's ring: a machined bezel, an amber scale lit three quarters of the way with a glow
/// at its tip, fine ticks around it, and the key with its waveform in the middle.
func drawRingedRecordKey(_ context: CGContext, center: CGPoint) {
    // Bezel.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0, 0, 0, 0.6))
    context.addPath(circle(center, 352))
    context.setFillColor(color(0.07, 0.07, 0.08))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(circle(center, 352))
    context.clip()
    linear(context, [color(0.3, 0.31, 0.34), color(0.04, 0.04, 0.05)],
           from: CGPoint(x: 512, y: 864), to: CGPoint(x: 512, y: 160))
    context.restoreGState()
    context.saveGState()
    context.addPath(circle(center, 330))
    context.clip()
    linear(context, [color(0.03, 0.03, 0.035), color(0.13, 0.13, 0.15)],
           from: CGPoint(x: 512, y: 842), to: CGPoint(x: 512, y: 182))
    context.restoreGState()

    // The scale runs 270°, from lower left over the top to lower right, like a knob's.
    let start: CGFloat = 225 * .pi / 180
    let end: CGFloat = -45 * .pi / 180
    let lit: CGFloat = 0.74
    let tip = start + (end - start) * lit
    let ringRadius: CGFloat = 296

    // Ticks around the scale, every 13.5°, the lit ones amber.
    for step in 0...20 {
        let fraction = CGFloat(step) / 20
        let angle = start + (end - start) * fraction
        let isLit = fraction <= lit + 0.001
        context.saveGState()
        context.setStrokeColor(isLit ? color(1, 0.8, 0.42, 0.95) : color(1, 1, 1, 0.16))
        context.setLineWidth(step % 5 == 0 ? 9 : 5)
        context.setLineCap(.round)
        let inner: CGFloat = step % 5 == 0 ? 318 : 322
        context.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
        context.addLine(to: CGPoint(x: center.x + cos(angle) * 338, y: center.y + sin(angle) * 338))
        context.strokePath()
        context.restoreGState()
    }

    // The unlit track, then the lit arc with its glow.
    context.saveGState()
    context.setLineWidth(26)
    context.setLineCap(.round)
    context.setStrokeColor(color(0.18, 0.15, 0.12))
    context.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: end, clockwise: true)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.setShadow(offset: .zero, blur: 34, color: color(1, 0.62, 0.16, 0.95))
    context.setLineWidth(26)
    context.setLineCap(.round)
    context.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: tip, clockwise: true)
    context.replacePathWithStrokedPath()
    context.clip()
    linear(context, [color(0.96, 0.55, 0.12), color(1, 0.86, 0.45)],
           from: CGPoint(x: 260, y: 300), to: CGPoint(x: 760, y: 760))
    context.restoreGState()

    // A bright lamp where the arc ends, like the pointer of a knob.
    let lamp = CGPoint(x: center.x + cos(tip) * ringRadius, y: center.y + sin(tip) * ringRadius)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 40, color: color(1, 0.75, 0.3, 1))
    context.addPath(circle(lamp, 19))
    context.setFillColor(color(1, 0.97, 0.86))
    context.fillPath()
    context.restoreGState()

    // The record key with its waveform, a little smaller than in the earlier icons.
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.scaleBy(x: 0.78, y: 0.78)
    context.translateBy(x: -512, y: -512)
    drawRecordKey(context, center: CGPoint(x: 512, y: 512))
    context.restoreGState()
}

/// The record key: a machined ring, the glowing red key, a waveform across it whose tallest bar ends in a spark.
func drawRecordKey(_ context: CGContext, center: CGPoint) {
    // Machined ring around the key.
    context.saveGState()
    context.addPath(circle(center, 300))
    context.clip()
    linear(context, [color(0.32, 0.33, 0.36), color(0.05, 0.05, 0.06)],
           from: CGPoint(x: 512, y: 812), to: CGPoint(x: 512, y: 212))
    context.restoreGState()
    context.saveGState()
    context.addPath(circle(center, 276))
    context.clip()
    linear(context, [color(0.05, 0.05, 0.06), color(0.2, 0.2, 0.22)],
           from: CGPoint(x: 512, y: 788), to: CGPoint(x: 512, y: 236))
    context.restoreGState()

    // Glow, then the record key itself.
    context.saveGState()
    context.addPath(circle(center, 276))
    context.clip()
    radial(context, [color(1, 0.22, 0.12, 0.75), color(1, 0.16, 0.08, 0)], center: center, radius: 276)
    context.restoreGState()

    context.saveGState()
    context.addPath(circle(center, 212))
    context.clip()
    linear(context, [color(1, 0.33, 0.24), color(0.72, 0.05, 0.05)],
           from: CGPoint(x: 512, y: 724), to: CGPoint(x: 512, y: 300))
    context.restoreGState()

    // Highlight on the upper half of the key.
    context.saveGState()
    context.addPath(circle(center, 212))
    context.clip()
    context.addEllipse(in: CGRect(x: 512 - 180, y: 540, width: 360, height: 180))
    context.clip()
    linear(context, [color(1, 1, 1, 0.34), color(1, 1, 1, 0.02)], from: CGPoint(x: 512, y: 720), to: CGPoint(x: 512, y: 540))
    context.restoreGState()

    // The waveform across the key. Its tallest bar is the spark.
    let heights: [CGFloat] = [34, 70, 48, 118, 86, 176, 120, 268, 420, 268, 136, 196, 92, 128, 56, 80, 34]
    let barWidth: CGFloat = 25
    let spacing: CGFloat = 40
    let startX = center.x - spacing * CGFloat(heights.count - 1) / 2
    context.saveGState()
    context.setShadow(offset: .zero, blur: 26, color: color(1, 0.75, 0.3, 0.9))
    for (index, height) in heights.enumerated() {
        let x = startX + CGFloat(index) * spacing - barWidth / 2
        let bar = CGPath(roundedRect: CGRect(x: x, y: center.y - height / 2, width: barWidth, height: height),
                         cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        context.addPath(bar)
        context.setFillColor(index == heights.count / 2 ? color(1, 0.98, 0.9) : color(1, 0.87, 0.62))
        context.fillPath()
    }
    context.restoreGState()

    // A small four-pointed spark on top of the tallest bar.
    let sparkCenter = CGPoint(x: center.x, y: center.y + 210 + 8)
    let reach: CGFloat = 64
    let waist: CGFloat = 11
    let spark = CGMutablePath()
    spark.move(to: CGPoint(x: sparkCenter.x, y: sparkCenter.y + reach))
    spark.addLine(to: CGPoint(x: sparkCenter.x + waist, y: sparkCenter.y + waist))
    spark.addLine(to: CGPoint(x: sparkCenter.x + reach, y: sparkCenter.y))
    spark.addLine(to: CGPoint(x: sparkCenter.x + waist, y: sparkCenter.y - waist))
    spark.addLine(to: CGPoint(x: sparkCenter.x, y: sparkCenter.y - reach))
    spark.addLine(to: CGPoint(x: sparkCenter.x - waist, y: sparkCenter.y - waist))
    spark.addLine(to: CGPoint(x: sparkCenter.x - reach, y: sparkCenter.y))
    spark.addLine(to: CGPoint(x: sparkCenter.x - waist, y: sparkCenter.y + waist))
    spark.closeSubpath()
    context.saveGState()
    context.setShadow(offset: .zero, blur: 30, color: color(1, 0.9, 0.6, 1))
    context.addPath(spark)
    context.setFillColor(color(1, 1, 0.96))
    context.fillPath()
    context.restoreGState()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    print("usage: make-icon.swift <output.icns>")
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("spark-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = workspace.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workspace) }

for points in [16, 32, 128, 256, 512] {
    try writePNG(draw(size: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(draw(size: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
// A plain preview next to the icon file, for looking at the result.
try writePNG(draw(size: 1024), to: output.deletingPathExtension().appendingPathExtension("png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
