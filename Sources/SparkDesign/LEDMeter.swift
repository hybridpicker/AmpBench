import SwiftUI

/// A level meter of LED segments behind glass, with its dB scale below. Segments are 6 pt wide with 2 pt gaps:
/// green up to −18 dB, amber up to −6 dB, red above.
///
///     LEDMeter(level: meter.level, hold: meter.peakHold)
///         .accessibilityLabel("Eingangspegel")
///         .accessibilityValue("−12 dBFS")
///
/// `level` and `hold` are linear amplitudes from 0 to 1, as audio code measures them.
public struct LEDMeter: View {
    let level: Float
    let hold: Float
    var floorDB: Float
    var height: CGFloat
    var marks: [Float]

    public init(level: Float, hold: Float = 0, floorDB: Float = -60, height: CGFloat = 12,
                marks: [Float] = [-60, -48, -36, -24, -12, -6, 0]) {
        self.level = level
        self.hold = hold
        self.floorDB = floorDB
        self.height = height
        self.marks = marks
    }

    /// Where a level sits on the scale, from 0 to 1.
    public static func position(_ level: Float, floorDB: Float = -60) -> Double {
        guard level > 0 else { return 0 }
        return Double(min(1, max(0, (20 * log10(level) - floorDB) / -floorDB)))
    }

    /// The color of the segment at a dB value.
    public static func color(atDB db: Float) -> Swatch {
        if db > -6 { return Theme.device.meterRed }
        if db > -18 { return Theme.device.meterAmber }
        return Theme.device.meterGreen
    }

    public var body: some View {
        Display(radius: 7, padding: EdgeInsets(top: 7, leading: 10, bottom: 5, trailing: 10)) {
            VStack(spacing: 4) {
                Canvas { context, size in
                    let count = LEDSegments.count(for: size.width)
                    let segment = LEDSegments.fill(size.width, count: count)
                    let lit = Self.position(level, floorDB: floorDB)
                    let held = Self.position(hold, floorDB: floorDB)
                    let holdIndex = held > 0 ? max(Int((held * Double(count)).rounded(.up)) - 1, 0) : -1
                    for index in 0..<count {
                        let fraction = (Double(index) + 0.5) / Double(count)
                        let isLit = fraction <= lit || index == holdIndex
                        let db = floorDB * Float(1 - fraction)
                        let color = isLit ? Self.color(atDB: db) : Theme.device.meterOff
                        context.fill(Path(roundedRect: LEDSegments.rect(index, height: size.height, segment: segment),
                                          cornerRadius: 1),
                                     with: .color(color.color))
                    }
                }
                .frame(height: height)
                MeterScale(marks: marks, floorDB: floorDB)
                    .frame(height: 10)
            }
        }
        .accessibilityElement()
    }
}

/// The numbers below a meter.
struct MeterScale: View {
    let marks: [Float]
    let floorDB: Float

    var body: some View {
        GeometryReader { geometry in
            ForEach(marks, id: \.self) { mark in
                Text(mark < 0 ? "−\(Int(-mark))" : "\(Int(mark))")
                    .font(Theme.Fonts.mono(8.5))
                    .foregroundStyle(Theme.device.amberDim)
                    .fixedSize()
                    .position(x: x(mark, width: geometry.size.width), y: geometry.size.height / 2)
            }
        }
        .accessibilityHidden(true)
    }

    private func x(_ mark: Float, width: CGFloat) -> CGFloat {
        let x = CGFloat((mark - floorDB) / -floorDB) * width
        return min(max(x, 8), width - 4)
    }
}

/// A row of LED segments, 6 pt wide with 2 pt gaps. `brightness` says for each segment how lit it is, from 0 to 1.
/// The level meter and the transfer meter of Spark Presets are both made of it.
///
///     LEDSegments(color: Theme.device.amberHot) { index, count in index < count / 2 ? 1 : 0 }
public struct LEDSegments: View {
    var color: Swatch
    var width: CGFloat
    var gap: CGFloat
    let brightness: (Int, Int) -> Double

    public init(color: Swatch = Theme.device.amberHot, width: CGFloat = 6, gap: CGFloat = 2,
                brightness: @escaping (_ index: Int, _ count: Int) -> Double) {
        self.color = color
        self.width = width
        self.gap = gap
        self.brightness = brightness
    }

    static func count(for width: CGFloat, segment: CGFloat = 6, gap: CGFloat = 2) -> Int {
        max(Int((width + gap) / (segment + gap)), 1)
    }

    /// The segment width that fills `width` exactly, close to the nominal 6 pt.
    static func fill(_ width: CGFloat, count: Int, gap: CGFloat = 2) -> CGFloat {
        (width - gap * CGFloat(count - 1)) / CGFloat(count)
    }

    static func rect(_ index: Int, height: CGFloat, segment: CGFloat = 6, gap: CGFloat = 2) -> CGRect {
        CGRect(x: CGFloat(index) * (segment + gap), y: 0, width: segment, height: height)
    }

    public var body: some View {
        Canvas { context, size in
            let count = Self.count(for: size.width, segment: width, gap: gap)
            let segment = Self.fill(size.width, count: count, gap: gap)
            for index in 0..<count {
                let lit = min(max(brightness(index, count), 0), 1)
                let rect = Self.rect(index, height: size.height, segment: segment, gap: gap)
                let path = Path(roundedRect: rect, cornerRadius: 1)
                if lit > 0 {
                    var glow = context
                    glow.addFilter(.shadow(color: color.color.opacity(0.6 * lit), radius: 2.5 * lit))
                    glow.fill(path, with: .color(color.color.opacity(0.35 + 0.65 * lit)))
                } else {
                    context.fill(path, with: .color(Theme.device.meterOff.color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Pegel") {
    PreviewPair {
        Faceplate {
            VStack(spacing: 12) {
                LEDMeter(level: 0.25, hold: 0.4)
                LEDMeter(level: 0.95, hold: 1)
                LEDSegments { index, count in index < count * 2 / 3 ? 1 : 0 }.frame(height: 4)
            }
            .padding(14)
            .frame(width: 320)
        }
    }
}
