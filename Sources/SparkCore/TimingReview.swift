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

    /// A stamp that cannot be read in full never passes for one with the click on and the amp part measured.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clickOnThroughout = (try? c.decodeIfPresent(Bool.self, forKey: .clickOnThroughout)) ?? false
        latency = (try? c.decodeIfPresent(ClickLatency.self, forKey: .latency)) ?? ClickLatency()
    }
}

/// Follows the click through a recording for the take's timing stamp. Once the click is off, even for a moment, the
/// take is no longer one with the click on throughout.
public struct ClickWatch: Equatable, Sendable {
    public private(set) var onThroughout: Bool

    public init(clickOnAtStart: Bool) {
        onThroughout = clickOnAtStart
    }

    public mutating func clickSwitched(on: Bool) {
        if !on { onThroughout = false }
    }

    public func stamp(latency: ClickLatency) -> TimingStamp {
        TimingStamp(clickOnThroughout: onThroughout, latency: latency)
    }
}

/// The look at a finished take against its click: every onset with its offset, the placement and the spread.
///
/// One pure entry point, `review(samples:sampleRate:grid:stamp:resolution:soundHasDelay:)`, so the Linux port can follow it line
/// by line. It knows nothing of devices, files or the window. What it grows (bars, accuracy, hints) comes in as
/// parameters with defaults and out as fields of the review, so callers stay as they are. Times are seconds in the file, offsets
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

    /// Something to know about a review that does not stop it.
    public enum Hint: Hashable, Sendable {
        /// The take's sound has a delay switched on: its echoes may be taken for notes.
        case delayInTheSound

        public var text: String {
            switch self {
            case .delayInTheSound:
                return tr("Delay in the sound: echoes may count as notes. For exact practice choose a dry sound.")
            }
        }
    }

    public var resolution: Resolution
    public var onsets: [Onset]
    /// The mean offset of the counted onsets.
    public var placement: Double
    /// The standard deviation of the counted offsets around the placement: the main number.
    public var spread: Double
    public var counted: Int
    public var hints: [Hint]

    /// The share of the grid spacing a catch window reaches to each side of its grid point.
    public static let catchWindow = 0.35
    /// The fewest counted onsets a review rests on: two bars of quarters (provisional, until the owner confirms it).
    public static let minimumCounted = 8

    public static func review(samples: [Float], sampleRate: Double, grid: BeatGrid?, stamp: TimingStamp?,
                              resolution: Resolution = .quarters, soundHasDelay: Bool = false) -> Outcome {
        if let reason = reasonBeforeListening(grid: grid, stamp: stamp) { return .noReview(reason) }
        guard let grid else { return .noReview(.noBars) }
        let times = OnsetDetector.onsets(in: samples, sampleRate: sampleRate)
        let duration = Double(samples.count) / sampleRate
        let onsets = match(times, to: grid, resolution: resolution, duration: duration)
        let offsets = onsets.filter(\.isCounted).compactMap(\.offset)
        guard offsets.count >= minimumCounted else { return .noReview(.tooFewOnsets) }
        let placement = offsets.reduce(0, +) / Double(offsets.count)
        let variance = offsets.reduce(0) { $0 + ($1 - placement) * ($1 - placement) } / Double(offsets.count)
        return .review(TimingReview(resolution: resolution, onsets: onsets, placement: placement,
                                    spread: variance.squareRoot(), counted: offsets.count,
                                    hints: soundHasDelay ? [.delayInTheSound] : []))
    }

    /// The reason a take gets no review that is known without its samples, so a window need not read the file for it.
    public static func reasonBeforeListening(grid: BeatGrid?, stamp: TimingStamp?) -> NoReviewReason? {
        guard grid != nil else { return .noBars }
        guard let stamp else { return .recordedBeforeTheStamp }
        guard stamp.clickOnThroughout else { return .clickNotOnThroughout }
        guard case .measured = stamp.latency.amp?.origin else { return .ampPartNotMeasured }
        return nil
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

/// Why a take has no timing review. The first that applies is the one shown, in the order of the cases.
public enum NoReviewReason: Hashable, Sendable {
    /// Recorded without the click, so the take has no bars to review against.
    case noBars
    /// The click was switched off at some moment, or started only during the take.
    case clickNotOnThroughout
    /// Recorded before takes kept a timing stamp; whether the click stayed on cannot be known.
    case recordedBeforeTheStamp
    /// The amp's part of the click latency was set by hand or is not known, so the bars may lie off.
    case ampPartNotMeasured
    /// Fewer clear notes on the grid points than a placement and a spread can rest on.
    case tooFewOnsets

    /// The one line the window shows instead of a review.
    public var text: String {
        switch self {
        case .noBars: return tr("No timing review: recorded without the click.")
        case .clickNotOnThroughout: return tr("No timing review: the click was not on for the whole take.")
        case .recordedBeforeTheStamp: return tr("No timing review: recorded before the measurement.")
        case .ampPartNotMeasured: return tr("No timing review: click latency not measured.")
        case .tooFewOnsets: return tr("No timing review: too few clear notes.")
        }
    }
}

/// Finds the first attack of each note in a recorded signal.
///
/// The signal is followed in steps of a millisecond: an attack is a step at least twice as loud as the loudest of the
/// 25 ms before it, and clearly above the take's floor. The attack is first placed where it reaches 30 % of its peak
/// in its first milliseconds, then followed back to the first sample that stands out from what sounded before, so
/// its time is where the note begins and not where it has grown loud: half a sample before that first sample, since
/// the note began between it and the last quiet one.
enum OnsetDetector {
    private static let stepSeconds = 0.001
    private static let lookBackSteps = 25
    private static let rise: Float = 2
    private static let holdSteps = 15
    /// How far past the step that set it off the attack's peak is looked for: short, so the later strings of a
    /// strum, a few milliseconds behind, do not raise it.
    private static let peakSeconds = 0.001
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
            if var first = samples[start..<end].firstIndex(where: { abs($0) >= threshold }) {
                let before = max(background, floor * 0.05)
                while first > start, abs(samples[first - 1]) > before { first -= 1 }
                // The note began somewhere between the last quiet sample and the first that stands out.
                onsets.append((Double(first) - 0.5) / sampleRate)
            }
            index += holdSteps
        }
        return onsets
    }
}
