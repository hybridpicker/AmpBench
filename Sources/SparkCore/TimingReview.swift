import AmpText
import Foundation

/// What a take remembers about its click, so its timing review can be judged later: whether the click was on for
/// the whole take, and the click latency its bars rest on. Written only by recordings made since the timing review.
public struct TimingStamp: Codable, Equatable, Sendable {
    /// False as soon as the click was switched off at any moment, or when it never ran from the start.
    public var clickOnThroughout: Bool
    /// The click latency the bars were corrected by: the parts, whether the amp's part was measured, the output's kind.
    public var latency: ClickLatency

    public init(clickOnThroughout: Bool, latency: ClickLatency) {
        self.clickOnThroughout = clickOnThroughout
        self.latency = latency
    }
}

/// The look at a finished take against its click: every onset with its offset, the placement and the spread.
///
/// One pure entry point, `review(samples:sampleRate:grid:stamp:resolution:soundHasDelay:)`, so the Linux port can
/// follow it line by line. It knows nothing of devices, files or the window. Times are seconds in the file, offsets
/// seconds with positive meaning later than the click.
public struct TimingReview: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case review(TimingReview)
        case noReview(NoReviewReason)
    }

    /// The grid points onsets are matched to, as points per beat.
    public enum Resolution: Int, Codable, CaseIterable, Sendable {
        case quarters = 1
        case eighths = 2
        case triplets = 3
        case sixteenths = 4

        public var pointsPerBeat: Int { rawValue }
    }

    public struct Onset: Equatable, Sendable {
        public enum Status: Equatable, Sendable {
            case counted
            /// A later onset in a catch window that already has one: a delay echo or a later string.
            case laterInWindow
            /// Between the catch windows, such as a fill or a passing note.
            case outsideWindows
        }

        /// Where the onset lies in the file.
        public var time: Double
        /// The number of its grid point from the first beat of the bars, 0 on, or nil outside every window.
        public var gridPoint: Int?
        /// From its grid point, positive later. Nil outside every window.
        public var offset: Double?
        public var status: Status

        public var isCounted: Bool { status == .counted }
    }

    public var resolution: Resolution
    public var onsets: [Onset]
    /// The mean offset of the counted onsets.
    public var placement: Double
    /// The standard deviation of the counted offsets around the placement: the main number.
    public var spread: Double
    public var counted: Int

    /// The share of the grid spacing a catch window reaches to each side of its grid point.
    public static let catchWindow = 0.35

    public static func review(samples: [Float], sampleRate: Double, grid: BeatGrid?, stamp: TimingStamp?,
                              resolution: Resolution = .quarters, soundHasDelay: Bool = false) -> Outcome {
        guard let grid else { return .noReview(.noBars) }
        let times = OnsetDetector.onsets(in: samples, sampleRate: sampleRate)
        let duration = Double(samples.count) / sampleRate
        let onsets = match(times, to: grid, resolution: resolution, duration: duration)
        let offsets = onsets.filter(\.isCounted).compactMap(\.offset)
        let placement = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count)
        let variance = offsets.isEmpty ? 0
            : offsets.reduce(0) { $0 + ($1 - placement) * ($1 - placement) } / Double(offsets.count)
        return .review(TimingReview(resolution: resolution, onsets: onsets, placement: placement,
                                    spread: variance.squareRoot(), counted: offsets.count))
    }

    /// Gives each onset its grid point: the nearest one, when the onset lies in its catch window and is the first there.
    static func match(_ times: [Double], to grid: BeatGrid, resolution: Resolution, duration: Double) -> [Onset] {
        let spacing = grid.secondsPerBeat / Double(resolution.pointsPerBeat)
        let reach = spacing * catchWindow
        let lastPoint = Int(((duration - grid.offset) / spacing).rounded(.down))
        var taken = Set<Int>()
        return times.sorted().map { time in
            let point = Int(((time - grid.offset) / spacing).rounded())
            let offset = time - (grid.offset + Double(point) * spacing)
            guard point >= 0, point <= lastPoint, abs(offset) <= reach else {
                return Onset(time: time, gridPoint: nil, offset: nil, status: .outsideWindows)
            }
            let first = taken.insert(point).inserted
            return Onset(time: time, gridPoint: point, offset: offset, status: first ? .counted : .laterInWindow)
        }
    }
}

/// Why a take has no timing review, checked in this order.
public enum NoReviewReason: Equatable, Sendable {
    case noBars
}

/// Finds the first attack of each note in a recorded signal.
///
/// The signal is followed in steps of a millisecond: an attack is a step at least twice as loud as the loudest of the
/// 25 ms before it, and clearly above the take's floor. Its time is then the first sample that reaches 30 % of the
/// attack's peak, the rule the click latency measurement uses for the click, so a note played exactly on the click
/// lies exactly on its grid point.
enum OnsetDetector {
    private static let stepSeconds = 0.001
    private static let lookBackSteps = 25
    private static let rise: Float = 2
    private static let holdSteps = 15
    private static let peakSeconds = 0.01
    private static let peakShare: Float = 0.3

    static func onsets(in samples: [Float], sampleRate: Double) -> [Double] {
        let step = max(Int((sampleRate * stepSeconds).rounded()), 1)
        let count = samples.count / step
        guard count > lookBackSteps else { return [] }
        var envelope = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<count {
                var peak: Float = 0
                for frame in (index * step)..<((index + 1) * step) { peak = max(peak, abs(buffer[frame])) }
                envelope[index] = peak
            }
        }
        let loudest = envelope.max() ?? 0
        let floor = max(loudest * 0.02, 0.001)
        let peakLength = Int(sampleRate * peakSeconds)

        var onsets: [Double] = []
        var index = 1
        while index < count {
            // The step just before belongs to the attack when it starts late in it, so it is not the background.
            let background = envelope[max(index - 1 - lookBackSteps, 0)..<(index - 1)].max() ?? 0
            guard envelope[index] >= floor, envelope[index] >= rise * max(background, floor / rise) else {
                index += 1
                continue
            }
            let start = (index - 1) * step
            let end = min(start + 2 * step + peakLength, samples.count)
            let peak = samples[start..<end].reduce(Float(0)) { max($0, abs($1)) }
            let threshold = max(peak * peakShare, background * 1.5)
            if let first = samples[start..<end].firstIndex(where: { abs($0) >= threshold }) {
                onsets.append(Double(first) / sampleRate)
            }
            index += holdSteps
        }
        return onsets
    }
}
