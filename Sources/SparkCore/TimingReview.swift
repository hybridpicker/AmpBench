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

/// A take's samples as the timing review reads them: from the start, block by block, as often as it needs, so a
/// long take is never held in memory whole. `TakeFile` reads a file this way.
public protocol TakeAudio {
    var sampleRate: Double { get }
    /// Hands `body` the take block by block from the start, one buffer per channel, all of the same length. False
    /// when it stopped before the end, such as when cancelled.
    func read(_ body: ([UnsafeBufferPointer<Float>]) -> Void) throws -> Bool
}

/// The look at a finished take against its click: every onset with its offset, the placement and the spread.
///
/// One pure entry point, `review(samples:sampleRate:grid:stamp:resolution:soundHasDelay:lastBar:)`, so the Linux
/// port can follow it line by line; a long take comes in through `TakeAudio` instead of its samples, by the same
/// rules. It knows nothing of devices, files or the window. Times are seconds in the file, offsets seconds with
/// positive meaning later than the click.
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

        /// The grid's name, for choosing it.
        public var name: String {
            switch self {
            case .quarters: return tr("Quarters")
            case .eighths: return tr("Eighths")
            case .triplets: return tr("Triplets")
            case .sixteenths: return tr("Sixteenths")
            }
        }

        /// How many notes the review counted, on this grid: "16 notes on eighths".
        public func notes(_ count: Int) -> String {
            switch self {
            case .quarters: return tr("%d notes on quarters", count)
            case .eighths: return tr("%d notes on eighths", count)
            case .triplets: return tr("%d notes on triplets", count)
            case .sixteenths: return tr("%d notes on sixteenths", count)
            }
        }
    }

    public struct Onset: Equatable, Sendable {
        public enum Status: Equatable, Sendable {
            case counted
            /// A later onset in a catch window that already has one: a delay echo or a later string.
            case laterInWindow
            /// Between the catch windows, such as a fill or a passing note.
            case outsideWindows
            /// First in its catch window, but the detector is unsure of it: a quiet note, legato or a swell. It still
            /// takes the window, so a later onset there, maybe its echo, does not count instead.
            case unsure
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
    /// How far the offsets may be off, plus or minus, in seconds: see `accuracy(of:)`.
    public var accuracy: Double = 0
    /// Every bar of the take, each with its own placement and spread.
    public var bars: [Bar] = []

    /// The share of the grid spacing a catch window reaches to each side of its grid point.
    public static let catchWindow = 0.35
    /// The fewest counted onsets a review rests on: two bars of quarters (provisional, until the owner confirms it).
    public static let minimumCounted = 8
    /// The worst review accuracy a review is given with; above it there is none.
    public static let worstAccuracy = 0.002
    /// How far the detector may place a clear attack off its true beginning, in seconds.
    public static let detectorUncertainty = 0.0005

    /// The review accuracy a take's stamp allows: half the measurement's spread, which is the range from its
    /// earliest to its latest click, added to the detector's uncertainty. Both are bounds, not standard deviations,
    /// so they add up. Nil when the amp part was not measured.
    public static func accuracy(of stamp: TimingStamp) -> Double? {
        guard case .measured(let spread, _) = stamp.latency.amp?.origin else { return nil }
        return spread / 2 + detectorUncertainty
    }

    /// The accuracy as the status line shows it, such as "Accuracy ±1.1 ms".
    public static func accuracyText(_ accuracy: Double) -> String {
        tr("Accuracy ±%.1f ms", accuracy * 1000)
    }

    public static func review(samples: [Float], sampleRate: Double, grid: BeatGrid?, stamp: TimingStamp?,
                              resolution: Resolution = .quarters, soundHasDelay: Bool = false,
                              lastBar: Int? = nil) -> Outcome {
        if let reason = reasonBeforeListening(grid: grid, stamp: stamp) { return .noReview(reason) }
        return judge(OnsetDetector.attacks(in: samples, sampleRate: sampleRate), duration: Double(samples.count) / sampleRate,
                     grid: grid, stamp: stamp, resolution: resolution, soundHasDelay: soundHasDelay, lastBar: lastBar)
    }

    /// The same review of a take read block by block. Nil when the reading stopped before the end.
    public static func review(_ audio: some TakeAudio, grid: BeatGrid?, stamp: TimingStamp?,
                              resolution: Resolution = .quarters, soundHasDelay: Bool = false,
                              lastBar: Int? = nil) throws -> Outcome? {
        if let reason = reasonBeforeListening(grid: grid, stamp: stamp) { return .noReview(reason) }
        guard let detected = try OnsetDetector.attacks(sampleRate: audio.sampleRate, read: audio.read) else { return nil }
        return judge(detected.attacks, duration: Double(detected.frames) / audio.sampleRate, grid: grid, stamp: stamp,
                     resolution: resolution, soundHasDelay: soundHasDelay, lastBar: lastBar)
    }

    private static func judge(_ attacks: [OnsetDetector.Attack], duration: Double, grid: BeatGrid?, stamp: TimingStamp?,
                              resolution: Resolution, soundHasDelay: Bool, lastBar: Int?) -> Outcome {
        // Always there once `reasonBeforeListening` found nothing.
        guard let grid, let stamp, let accuracy = accuracy(of: stamp) else { return .noReview(.noBars) }
        let points = GridPoints(grid: grid, resolution: resolution, duration: duration, lastBar: lastBar)
        var onsets = match(attacks.map(\.time), to: points)
        // The attacks come in the order of time, as the onsets do.
        for index in onsets.indices where onsets[index].status == .counted && !attacks[index].isClear {
            onsets[index].status = .unsure
        }
        let offsets = onsets.filter(\.isCounted).compactMap(\.offset)
        guard offsets.count >= minimumCounted, let numbers = Numbers(offsets) else { return .noReview(.tooFewOnsets) }
        return .review(TimingReview(resolution: resolution, onsets: onsets, placement: numbers.placement,
                                    spread: numbers.spread, counted: offsets.count,
                                    hints: soundHasDelay ? [.delayInTheSound] : [], accuracy: accuracy,
                                    bars: bars(of: onsets, on: points, takeSpread: numbers.spread)))
    }

    /// The reason a take gets no review that is known without its samples, so a window need not read the file for it.
    public static func reasonBeforeListening(grid: BeatGrid?, stamp: TimingStamp?) -> NoReviewReason? {
        guard grid != nil else { return .noBars }
        guard let stamp else { return .recordedBeforeTheStamp }
        guard stamp.clickOnThroughout else { return .clickNotOnThroughout }
        guard case .measured = stamp.latency.amp?.origin else { return .ampPartNotMeasured }
        guard stamp.latency.outputKind == .wired else { return .clickOnBluetooth }
        // A tiny margin, so an accuracy that is 2 ms on paper is not refused for a rounding error.
        guard let accuracy = accuracy(of: stamp), accuracy <= worstAccuracy + 1e-9 else { return .accuracyNotGoodEnough }
        return nil
    }

    /// Gives each onset its grid point: the nearest one, when the onset lies in its catch window and is the first there.
    static func match(_ times: [Double], to points: GridPoints) -> [Onset] {
        let reach = points.spacing * catchWindow
        var taken = Set<Int>()
        return times.sorted().map { time in
            let point = points.nearest(to: time)
            let offset = time - points.time(of: point)
            guard points.range.contains(point), abs(offset) <= reach else {
                return Onset(time: time, gridPoint: nil, offset: nil, status: .outsideWindows)
            }
            let first = taken.insert(point).inserted
            return Onset(time: time, gridPoint: point, offset: offset, status: first ? .counted : .laterInWindow)
        }
    }

    /// The mean of some offsets and their standard deviation around it. Nil without any.
    struct Numbers {
        var placement: Double
        var spread: Double

        init?(_ offsets: [Double]) {
            guard !offsets.isEmpty else { return nil }
            let count = Double(offsets.count)
            let mean = offsets.reduce(0, +) / count
            placement = mean
            spread = (offsets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count).squareRoot()
        }
    }
}

/// The grid points of a take's bars on one grid, numbered from the first beat of its bars, 0 on: those that lie in
/// the file, and for bars recorded again only those of the bars recorded, not of what rings out after them.
struct GridPoints {
    let grid: BeatGrid
    let pointsPerBeat: Int
    /// The time from one grid point to the next.
    let spacing: Double
    /// The numbers of the take's grid points; empty when none lies in the file.
    let range: Range<Int>

    init(grid: BeatGrid, resolution: TimingReview.Resolution, duration: Double = .infinity, lastBar: Int? = nil) {
        self.grid = grid
        pointsPerBeat = resolution.pointsPerBeat
        spacing = grid.secondsPerBeat / Double(resolution.pointsPerBeat)
        let inFile = duration.isFinite ? Int(((duration - grid.offset) / spacing).rounded(.down)) + 1 : Int.max
        let inBars = lastBar.map { ($0 - grid.firstBar + 1) * grid.beatsPerBar * resolution.pointsPerBeat } ?? Int.max
        range = 0..<max(min(inFile, inBars), 0)
    }

    var pointsPerBar: Int { grid.beatsPerBar * pointsPerBeat }

    func time(of point: Int) -> Double {
        grid.offset + Double(point) * spacing
    }

    /// The grid point nearest to a moment of the file, whether the take has it or not.
    func nearest(to time: Double) -> Int {
        Int(((time - grid.offset) / spacing).rounded())
    }

    /// The first grid point of a bar.
    func first(ofBar bar: Int) -> Int {
        (bar - grid.firstBar) * pointsPerBar
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
    /// The click went to a Bluetooth output, whose delay is not steady enough to judge against.
    case clickOnBluetooth
    /// The review accuracy the measurement allows is worse than ±2 ms.
    case accuracyNotGoodEnough
    /// Fewer clear notes on the grid points than a placement and a spread can rest on.
    case tooFewOnsets

    /// The one line the window shows instead of a review.
    public var text: String {
        switch self {
        case .noBars: return tr("No timing review: recorded without the click.")
        case .clickNotOnThroughout: return tr("No timing review: the click was not on for the whole take.")
        case .recordedBeforeTheStamp: return tr("No timing review: recorded before the measurement.")
        case .ampPartNotMeasured: return tr("No timing review: click latency not measured.")
        case .clickOnBluetooth: return tr("No timing review: the click went to a Bluetooth output.")
        case .accuracyNotGoodEnough:
            return tr("No timing review: accuracy not good enough. Measure the click latency again.")
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
///
/// An attack is clear when it is not far quieter than the take's typical attack and rises fast: a picked note
/// reaches a quarter of its level within a few samples, a legato note or a swell takes many milliseconds.
///
/// A take is read twice, block by block: first for the loudness of every channel in steps, then the loudest channel
/// only around each attack. So a long take is never held whole, only its steps (4 bytes per millisecond and channel).
enum OnsetDetector {
    struct Attack: Equatable {
        /// Where the note begins, in seconds in the file.
        var time: Double
        /// The loudest sample in the attack's first 20 ms.
        var level: Float
        /// Seconds from the beginning until the attack reaches a quarter of its level.
        var rise: Double
        var isClear = true
    }

    private static let levelSeconds = 0.020
    private static let riseShare: Float = 0.25
    /// The slowest rise of a clear attack.
    private static let slowestRise = 0.002
    /// Quieter than this share of the take's median attack (18 dB below it), an attack is unsure.
    private static let quietShare: Float = 0.125

    private static let stepSeconds = 0.001
    private static let lookBackSteps = 25
    private static let rise: Float = 2
    private static let holdSteps = 15
    /// How far past the step that set it off the attack's peak is looked for: short, so the later strings of a
    /// strum, a few milliseconds behind, do not raise it.
    private static let peakSeconds = 0.001
    private static let peakShare: Float = 0.3
    /// The blocks samples held in memory are handed over in, as a file is read.
    private static let blockFrames = 65_536

    /// The attacks in samples held in memory.
    static func attacks(in samples: [Float], sampleRate: Double) -> [Attack] {
        attacks(sampleRate: sampleRate) { body in
            samples.withUnsafeBufferPointer { buffer in
                var start = 0
                while start < buffer.count {
                    let end = min(start + blockFrames, buffer.count)
                    body([UnsafeBufferPointer(rebasing: buffer[start..<end])])
                    start = end
                }
            }
            return true
        }?.attacks ?? []
    }

    /// The attacks in a take that `read` hands over block by block from the start, one buffer per channel, twice.
    /// Nil when reading stopped before the end.
    static func attacks(sampleRate: Double, read: (([UnsafeBufferPointer<Float>]) -> Void) throws -> Bool) rethrows
        -> (attacks: [Attack], frames: Int)? {
        let step = max(Int((sampleRate * stepSeconds).rounded()), 1)
        var steps = Steps(step: step)
        guard try read({ steps.add($0) }) else { return nil }
        let channel = steps.loudestChannel
        let envelope = channel.map { steps.channels[$0] } ?? []
        let loudest = envelope.max() ?? 0
        let floor = max(loudest * 0.02, 0.001)
        let triggers = Self.triggers(in: envelope, step: step, floor: floor)
        guard let channel, !triggers.isEmpty else { return ([], steps.frames) }

        var refiner = Refiner(triggers: triggers, frames: steps.frames, sampleRate: sampleRate, step: step, floor: floor)
        guard try read({ refiner.add($0[channel]) }) else { return nil }
        return (classified(refiner.attacks), steps.frames)
    }

    /// Marks the attacks too quiet against the take's typical one, or rising too slowly, as not clear.
    private static func classified(_ attacks: [Attack]) -> [Attack] {
        let levels = attacks.map(\.level).sorted()
        guard !levels.isEmpty else { return [] }
        let typical = levels[levels.count / 2]
        return attacks.map { attack in
            var attack = attack
            attack.isClear = attack.level >= typical * quietShare && attack.rise <= slowestRise
            return attack
        }
    }

    /// The loudest sample of every channel in each whole step.
    private struct Steps {
        let step: Int
        var channels: [[Float]] = []
        private var partial: [Float] = []
        private var inStep = 0
        private(set) var frames = 0

        init(step: Int) {
            self.step = step
        }

        /// The channel with the loudest sample, nil without any.
        var loudestChannel: Int? {
            let peaks = channels.indices.map { max(channels[$0].max() ?? 0, partial[$0]) }
            return peaks.indices.max { peaks[$0] < peaks[$1] }
        }

        mutating func add(_ block: [UnsafeBufferPointer<Float>]) {
            if channels.isEmpty {
                channels = Array(repeating: [], count: block.count)
                partial = Array(repeating: 0, count: block.count)
            }
            guard block.count == channels.count, let length = block.first?.count, length > 0,
                  block.allSatisfy({ $0.count == length && $0.baseAddress != nil }) else { return }
            var filled = inStep
            for channel in channels.indices {
                guard let samples = block[channel].baseAddress else { continue }
                // Taken out while it grows, so it is not copied.
                var steps = channels[channel]
                channels[channel] = []
                var peak = partial[channel]
                filled = inStep
                // A plain loop over a pointer: a range would look up generic metadata on every sample in a debug
                // build, and this runs once per sample of the take.
                var frame = 0
                while frame < length {
                    let value = abs(samples[frame])
                    if value > peak { peak = value }
                    filled += 1
                    if filled == step {
                        steps.append(peak)
                        peak = 0
                        filled = 0
                    }
                    frame += 1
                }
                channels[channel] = steps
                partial[channel] = peak
            }
            inStep = filled
            frames += length
        }
    }

    /// A step that sets off an attack: where its search starts, and the loudest of the steps before it.
    private struct Trigger {
        var start: Int
        var background: Float
    }

    private static func triggers(in envelope: [Float], step: Int, floor: Float) -> [Trigger] {
        guard envelope.count > lookBackSteps else { return [] }
        var triggers: [Trigger] = []
        var index = 1
        while index < envelope.count {
            // The step just before belongs to the attack when it starts late in it, so it is not the background.
            let background = envelope[max(index - 1 - lookBackSteps, 0)..<(index - 1)].max() ?? 0
            guard envelope[index] >= floor, envelope[index] >= rise * max(background, floor / rise) else {
                index += 1
                continue
            }
            triggers.append(Trigger(start: (index - 1) * step, background: background))
            index += holdSteps
        }
        return triggers
    }

    /// Places each attack in the samples around its trigger, keeping only those of the block read and the next
    /// trigger's.
    private struct Refiner {
        let triggers: [Trigger]
        let frames: Int
        let sampleRate: Double
        let step: Int
        let floor: Float
        private(set) var attacks: [Attack] = []
        private var next = 0
        private var buffer: [Float] = []
        private var bufferStart = 0

        init(triggers: [Trigger], frames: Int, sampleRate: Double, step: Int, floor: Float) {
            self.triggers = triggers
            self.frames = frames
            self.sampleRate = sampleRate
            self.step = step
            self.floor = floor
        }

        private var peakLength: Int { Int(sampleRate * peakSeconds) }
        private var levelLength: Int { Int(sampleRate * levelSeconds) }

        mutating func add(_ block: UnsafeBufferPointer<Float>) {
            buffer.append(contentsOf: block)
            let position = bufferStart + buffer.count
            while next < triggers.count {
                let trigger = triggers[next]
                let end = min(trigger.start + 2 * step + peakLength + levelLength, frames)
                guard end <= position else { break }
                if let attack = buffer.withUnsafeBufferPointer({ place(trigger, in: $0) }) { attacks.append(attack) }
                next += 1
            }
            let keep = next < triggers.count ? triggers[next].start : position
            let dropped = min(max(keep - bufferStart, 0), buffer.count)
            buffer.removeFirst(dropped)
            bufferStart += dropped
        }

        private func place(_ trigger: Trigger, in samples: UnsafeBufferPointer<Float>) -> Attack? {
            let base = bufferStart
            let start = trigger.start - base
            let end = min(trigger.start + 2 * step + peakLength, frames) - base
            guard start >= 0, end <= samples.count, start < end else { return nil }
            var peak: Float = 0
            for index in start..<end { peak = max(peak, abs(samples[index])) }
            let threshold = max(peak * peakShare, trigger.background * 1.5)
            guard var first = (start..<end).first(where: { abs(samples[$0]) >= threshold }) else { return nil }
            let before = max(trigger.background, floor * 0.05)
            while first > start, abs(samples[first - 1]) > before { first -= 1 }
            let levelEnd = min(first + levelLength, samples.count)
            var level: Float = 0
            for index in first..<levelEnd { level = max(level, abs(samples[index])) }
            let risen = (first..<levelEnd).first { abs(samples[$0]) >= level * riseShare } ?? first
            // The note began somewhere between the last quiet sample and the first that stands out.
            return Attack(time: (Double(first + base) - 0.5) / sampleRate, level: level,
                          rise: Double(risen - first) / sampleRate)
        }
    }
}
