// Draws the app icons: a dark studio-device faceplate with a glowing record key and a waveform that peaks in a spark,
// or for Spark Presets the same faceplate with a preset knob and four lamps.
// Usage: swift Tools/make-icon.swift <output.icns> [presets]
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
    if variant == "presets" {
        drawPresetKnob(context, center: center)
        return context.makeImage()!
    }

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

    return context.makeImage()!
}

/// The preset knob: a machined ring, a knurled knob pointing at the second of four lamps, that lamp lit.
func drawPresetKnob(_ context: CGContext, center: CGPoint) {
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

    // Four lamps on the ring, at the knob's four positions. The second one is on.
    let angles: [CGFloat] = [135, 45, -45, -135].map { $0 * .pi / 180 }
    for (index, angle) in angles.enumerated() {
        let lamp = CGPoint(x: center.x + cos(angle) * 248, y: center.y + sin(angle) * 248)
        context.saveGState()
        if index == 1 {
            context.setShadow(offset: .zero, blur: 40, color: color(1, 0.62, 0.16, 1))
            context.addPath(circle(lamp, 22))
            context.setFillColor(color(1, 0.78, 0.36))
        } else {
            context.addPath(circle(lamp, 18))
            context.setFillColor(color(0.24, 0.2, 0.16))
        }
        context.fillPath()
        context.restoreGState()
    }

    // The knob, with a soft shadow and a knurled edge.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0, 0, 0, 0.7))
    context.addPath(circle(center, 196))
    context.setFillColor(color(0.12, 0.12, 0.13))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(circle(center, 196))
    context.clip()
    linear(context, [color(0.42, 0.43, 0.46), color(0.1, 0.1, 0.11)],
           from: CGPoint(x: 512, y: 708), to: CGPoint(x: 512, y: 316))
    context.setStrokeColor(color(0, 0, 0, 0.35))
    context.setLineWidth(6)
    for step in 0..<48 {
        let angle = CGFloat(step) / 48 * 2 * .pi
        context.move(to: CGPoint(x: center.x + cos(angle) * 176, y: center.y + sin(angle) * 176))
        context.addLine(to: CGPoint(x: center.x + cos(angle) * 200, y: center.y + sin(angle) * 200))
    }
    context.strokePath()
    context.restoreGState()
    context.saveGState()
    context.addPath(circle(center, 160))
    context.clip()
    linear(context, [color(0.3, 0.31, 0.34), color(0.14, 0.14, 0.15)],
           from: CGPoint(x: 512, y: 672), to: CGPoint(x: 512, y: 352))
    radial(context, [color(1, 1, 1, 0.14), color(1, 1, 1, 0)], center: CGPoint(x: 470, y: 620), radius: 200)
    context.restoreGState()

    // The pointer, glowing like the lamp it points at.
    let pointer = angles[1]
    context.saveGState()
    context.setShadow(offset: .zero, blur: 24, color: color(1, 0.7, 0.3, 0.9))
    context.setStrokeColor(color(1, 0.88, 0.62))
    context.setLineWidth(30)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: center.x + cos(pointer) * 40, y: center.y + sin(pointer) * 40))
    context.addLine(to: CGPoint(x: center.x + cos(pointer) * 134, y: center.y + sin(pointer) * 134))
    context.strokePath()
    context.restoreGState()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

guard (2...3).contains(CommandLine.arguments.count) else {
    print("usage: make-icon.swift <output.icns> [presets]")
    exit(64)
}
let variant = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "recorder"
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
