import Accelerate
import Foundation

/// What the tracker hears right now.
public struct PitchReading: Equatable, Sendable {
    /// The fundamental in Hz, smoothed.
    public var frequency: Double
    /// True while the last value stays on after the tone ended or a new attack began.
    public var isHeld: Bool
    /// The expected error of `frequency` in cents (one standard deviation), from the measured noise. Nil while
    /// only the coarse estimate is known.
    public var uncertainty: Double?

    public init(frequency: Double, isHeld: Bool = false, uncertainty: Double? = nil) {
        self.frequency = frequency
        self.isHeld = isHeld
        self.uncertainty = uncertainty
    }
}

/// Follows the pitch of one string from a mono stream, for the tuner. Pure logic: it takes samples, so tests feed it
/// synthetic signals without any audio hardware, and the tuner feeds it from an `AudioTap` on its own thread.
///
/// Every 5 ms it
/// 1. measures the level and opens or closes the gate, and notices a new attack, whose first 20 ms it leaves out;
/// 2. estimates the period with `PeriodDetector` (MPM). An estimate only counts once the block is long enough to have
///    seen the octave below as well, so the first value of a low string cannot be its second harmonic;
/// 3. locks onto a note after three estimates that agree. While locked, estimates an octave or a fifth away are
///    taken for overtones or undertones and ignored, until the next attack; any other pitch needs three agreeing
///    estimates to take over;
/// 4. measures the phase of the fundamental at the locked frequency (`PhaseEstimator`), which gives the fine value;
/// 5. smooths with a median of five and an exponential average that is slow while the value holds and fast when it
///    moves, and keeps the last value for a moment after the tone has ended.
public final class PitchTracker {
    public struct Settings: Sendable {
        /// The search range. The tuner's range is 30 Hz (below B0) to 1.4 kHz; the bounds leave room at both ends.
        public var lowest = 28.0
        public var highest = 1500.0
        /// The gate, in dBFS RMS, with hysteresis.
        public var gateOn = -60.0
        public var gateOff = -66.0
        /// What is left out after an attack, in seconds.
        public var attackBlank = 0.02
        /// The interval of the analysis, in seconds.
        public var hop = 0.005
        /// The least clarity (NSDF height) of an estimate that locks a note ...
        public var minClarity = 0.8
        /// ... and that keeps a locked note: a ringing string grows less periodic as its overtones drift.
        public var keepClarity = 0.5
        /// How long the last value stays, in seconds.
        public var hold = 1.5
        /// The phase is measured over this many periods, at most `maxPhaseWindow` seconds.
        public var phasePeriods = 12.0
        public var maxPhaseWindow = 0.45
        /// The line through the phases spans this many periods, within `spanRange` seconds. A frequency error in
        /// hertz is the same for every note, so in cents a low note needs the longer line.
        public var spanPeriods = 60.0
        public var spanRange = 0.6...2.0
        /// An attack raises the level at least this much over the level 25 to 80 ms before.
        public var attackRatio = 2.0

        public init() {}
    }

    public let sampleRate: Double
    public let settings: Settings
    public private(set) var reading: PitchReading?
    /// True while the level is above the gate.
    public private(set) var hasSignal = false
    /// The RMS level of the last 20 ms or two periods, in dBFS.
    public private(set) var levelDB = -120.0
    /// Samples processed so far.
    public private(set) var time: Int64 = 0
    /// Attacks noticed so far, for tests.
    public private(set) var attackCount = 0
    /// Notes locked and fine measurements started over, for tests.
    public private(set) var lockCount = 0
    public private(set) var phaseRestarts = 0
    public var phaseSpan: Double { phase.span }
    public var expectedError: Double? { lockedFrequency == nil ? nil : phase.expectedError }
    public var phasePrunes: Int { phase.prunes }
    /// The locked fundamental, before smoothing. Nil while no note is locked.
    public private(set) var lockedFrequency: Double?

    public var seconds: Double { Double(time) / sampleRate }

    private let hopLength: Int
    private let minLag: Int
    private let maxLag: Int
    private let coarseWindow: Int
    private let phaseWindow: Int
    private var history: [Float]
    private let mask: Int
    private var block: [Float]
    private let detector: PeriodDetector
    private let phase: PhaseEstimator

    private var nextHop: Int64
    private var hopIndex = 0
    private var levels: [Double] = []
    private var analysisStart: Int64 = 0
    private var lastAttack: Int64 = .min / 2
    private var candidates: [Double] = []
    private var foreign: [Double] = []
    private var missedEstimates = 0
    private var lastCoarse: Double?
    private var recent: [Double] = []
    private var smoothed: Double?
    private var heldSince: Int64?
    // The best precision and the loudest level of the current note, to keep its last good value while it fades.
    private var bestUncertainty = Double.infinity
    private var noteLevel = -140.0
    // A first-order high-pass at about 10 Hz: a DC offset would keep the NSDF from ever turning negative.
    private let blockerPole: Float
    private var blockerInput: Float = 0
    private var blockerOutput: Float = 0

    public init(sampleRate: Double, settings: Settings = Settings()) {
        self.sampleRate = sampleRate
        self.settings = settings
        hopLength = max(Int((settings.hop * sampleRate).rounded()), 16)
        minLag = max(Int(sampleRate / settings.highest), 2)
        maxLag = Int((sampleRate / settings.lowest).rounded(.up))
        // Two periods of the lowest note, so its octave below has been searched for every note above 2 × lowest.
        coarseWindow = 2 * maxLag + 4
        phaseWindow = Int(settings.maxPhaseWindow * sampleRate)
        var size = 1
        while size < coarseWindow + phaseWindow + 8 * hopLength { size <<= 1 }
        history = [Float](repeating: 0, count: size)
        mask = size - 1
        block = [Float](repeating: 0, count: max(coarseWindow, phaseWindow))
        detector = PeriodDetector(maxWindow: coarseWindow)
        phase = PhaseEstimator(sampleRate: sampleRate, maxLength: phaseWindow)
        nextHop = Int64(hopLength)
        blockerPole = Float(1 - 2 * Double.pi * 10 / sampleRate)
    }

    /// Forgets everything, as after a gap in the stream.
    public func reset() {
        time = 0
        nextHop = Int64(hopLength)
        hopIndex = 0
        levels.removeAll()
        hasSignal = false
        levelDB = -120
        reading = nil
        unlock()
        heldSince = nil
        lastAttack = .min / 2
        blockerInput = 0
        blockerOutput = 0
        for index in history.indices { history[index] = 0 }
    }

    public func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { process($0) }
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        var offset = 0
        while offset < samples.count {
            // Never more at once than the history holds beyond what the analysis looks back on.
            let chunk = min(samples.count - offset, hopLength)
            for index in 0..<chunk {
                let input = samples[offset + index]
                blockerOutput = input - blockerInput + blockerPole * blockerOutput
                blockerInput = input
                history[Int(time + Int64(index)) & mask] = blockerOutput
            }
            time += Int64(chunk)
            offset += chunk
            while time >= nextHop {
                analyze(end: nextHop)
                nextHop += Int64(hopLength)
            }
        }
    }

    // MARK: One step

    private func analyze(end: Int64) {
        hopIndex += 1
        let period = lockedFrequency.map { sampleRate / $0 } ?? 0
        let levelLength = min(max(Int(0.02 * sampleRate), Int(2 * period)), Int(0.1 * sampleRate))
        let meanSquare = sumOfSquares(end: end, count: levelLength) / Double(levelLength)
        levelDB = meanSquare > 1e-14 ? 10 * log10(meanSquare) : -140
        let rms = meanSquare.squareRoot()
        levels.append(rms)
        if levels.count > 17 { levels.removeFirst(levels.count - 17) }

        if !hasSignal {
            if levelDB > settings.gateOn {
                hasSignal = true
                attack(at: end)
            } else {
                holdOrForget(end: end)
                return
            }
        } else if levelDB < settings.gateOff {
            hasSignal = false
            unlock()
            holdOrForget(end: end)
            return
        } else if levels.count >= 17, end - lastAttack > Int64(0.05 * sampleRate) {
            // The level 25 to 80 ms ago, whose windows do not overlap the current one.
            let before = levels[0..<12].max() ?? 0
            if rms > settings.attackRatio * before { attack(at: end) }
        }

        let available = end - analysisStart
        guard available > 0 else { return }

        if lockedFrequency == nil || hopIndex % 4 == 0 {
            coarse(end: end, available: Int(available))
        }
        if let locked = lockedFrequency {
            fine(end: end, available: Int(available), locked: locked)
        } else if reading != nil {
            holdOrForget(end: end)
        }
    }

    private func attack(at end: Int64) {
        attackCount += 1
        lastAttack = end
        analysisStart = end - Int64(hopLength) + Int64(settings.attackBlank * sampleRate)
        unlock()
    }

    private func unlock() {
        lockedFrequency = nil
        candidates.removeAll()
        foreign.removeAll()
        missedEstimates = 0
        lastCoarse = nil
        phase.clear()
    }

    /// Keeps the last value for a while, then lets it go.
    private func holdOrForget(end: Int64) {
        guard var current = reading else { return }
        if !current.isHeld {
            current.isHeld = true
            reading = current
            heldSince = end
            recent.removeAll()
            smoothed = nil
        } else if let since = heldSince, Double(end - since) / sampleRate > settings.hold {
            reading = nil
            heldSince = nil
        }
    }

    // MARK: Coarse

    private func coarse(end: Int64, available: Int) {
        let length = min(available, coarseWindow)
        guard length >= 4 * minLag else { return }
        copy(end: end, count: length)
        let estimate = block.withUnsafeBufferPointer {
            detector.estimate(UnsafeBufferPointer(rebasing: $0[0..<length]), minLag: minLag, maxLag: maxLag)
        }
        guard let estimate else {
            miss(certain: length >= coarseWindow)
            return
        }
        // Not yet: the block has not seen the octave below, so this could be an overtone.
        let octaveSeen = 2 * estimate.lag <= Double(estimate.searchedUpTo) || estimate.searchedUpTo >= maxLag
        guard octaveSeen else { return }
        let needed = lockedFrequency == nil ? settings.minClarity : settings.keepClarity
        guard estimate.clarity >= needed, estimate.lag < Double(maxLag - 1) else {
            miss(certain: true)
            return
        }
        let frequency = sampleRate / estimate.lag
        lastCoarse = frequency
        missedEstimates = 0

        guard let locked = lockedFrequency else {
            candidates.append(frequency)
            if candidates.count > 3 { candidates.removeFirst(candidates.count - 3) }
            if candidates.count == 3, let median = Self.agreeingMedian(candidates, within: 30) {
                lock(median, end: end)
            }
            return
        }
        let distance = Self.cents(frequency, locked)
        if abs(distance) < 70 {
            foreign.removeAll()
        } else if Self.isHarmonic(distance) {
            // An overtone or undertone of the locked note, such as the octave while a low string rings out.
            foreign.removeAll()
        } else {
            foreign.append(frequency)
            if foreign.count >= 3, let median = Self.agreeingMedian(Array(foreign.suffix(3)), within: 30) {
                lock(median, end: end)
            }
        }
    }

    private func miss(certain: Bool) {
        guard certain else { return }
        if lockedFrequency == nil {
            candidates.removeAll()
        } else {
            missedEstimates += 1
            // About 80 ms without a pitch: the tone has ended or turned into noise.
            if missedEstimates >= 4 { unlock() }
        }
    }

    private func lock(_ frequency: Double, end: Int64) {
        lockCount += 1
        lockedFrequency = frequency
        candidates.removeAll()
        foreign.removeAll()
        missedEstimates = 0
        recent.removeAll()
        smoothed = nil
        heldSince = nil
        bestUncertainty = .infinity
        noteLevel = levelDB
        phase.maxSpan = min(max(settings.spanPeriods / frequency, settings.spanRange.lowerBound),
                            settings.spanRange.upperBound)
        phase.reset(reference: frequency, origin: analysisStart)
        emit(frequency)
    }

    // MARK: Fine

    private func fine(end: Int64, available: Int, locked: Double) {
        let period = sampleRate / locked
        let length = min(available, Int(settings.phasePeriods * period), phaseWindow)
        if length >= Int(3 * period) {
            copy(end: end, count: length)
            block.withUnsafeBufferPointer {
                phase.measure(UnsafeBufferPointer(rebasing: $0[0..<length]), start: end - Int64(length))
            }
        }
        var value = locked
        if let measured = phase.frequency, phase.span >= 0.02 {
            let fromReference = Self.cents(measured, phase.reference)
            if abs(fromReference) > 25 || measured.isNaN {
                // The line lost the tone, such as after a slip of the phase: start over from the coarse value.
                phaseRestarts += 1
                phase.reset(reference: lastCoarse ?? locked, origin: analysisStart)
                value = lastCoarse ?? locked
            } else {
                value = measured
                if abs(fromReference) > 12 {
                    // A peg being turned far: measure around the new pitch.
                    phaseRestarts += 1
                    phase.reset(reference: measured, origin: analysisStart)
                }
            }
        } else if let coarse = lastCoarse {
            value = coarse
        }
        lockedFrequency = value
        noteLevel = max(noteLevel, levelDB)
        let uncertainty = phase.frequency != nil && phase.span >= 0.02 ? phase.expectedError : nil
        if let uncertainty, uncertainty > max(0.5, 3 * bestUncertainty), levelDB < noteLevel - 20, reading?.isHeld == false {
            // The string fades into the noise: its last precise value stays rather than the noise's.
            return
        }
        if let uncertainty { bestUncertainty = min(bestUncertainty, uncertainty) }
        emit(value, uncertainty: uncertainty)
    }

    // MARK: Smoothing

    private func emit(_ frequency: Double, uncertainty: Double? = nil) {
        recent.append(frequency)
        if recent.count > 5 { recent.removeFirst(recent.count - 5) }
        let median = recent.sorted()[recent.count / 2]
        if let previous = smoothed {
            let distance = abs(Self.cents(median, previous))
            let weight = distance > 2 ? 0.7 : distance > 0.6 ? 0.35 : 0.12
            smoothed = previous + weight * (median - previous)
        } else {
            smoothed = median
        }
        heldSince = nil
        reading = PitchReading(frequency: smoothed ?? median, uncertainty: uncertainty)
    }

    // MARK: Helpers

    static func cents(_ frequency: Double, _ reference: Double) -> Double {
        1200 * log2(frequency / reference)
    }

    /// Octaves up and down, the twelfth and the fifth: what overtones and undertones of a string are mistaken for.
    static func isHarmonic(_ cents: Double) -> Bool {
        let ratios: [Double] = [2, 3, 4, 1.5, 0.5, 1 / 3.0, 0.25, 2 / 3.0]
        return ratios.contains { abs(cents - 1200 * log2($0)) < 50 }
    }

    /// The median when all values lie within `cents` of it, else nil.
    static func agreeingMedian(_ values: [Double], within cents: Double) -> Double? {
        let median = values.sorted()[values.count / 2]
        return values.allSatisfy({ abs(Self.cents($0, median)) <= cents }) ? median : nil
    }

    private func sumOfSquares(end: Int64, count: Int) -> Double {
        var total = 0.0
        var index = end - Int64(count)
        while index < end {
            let position = Int(index) & mask
            let run = min(Int(end - index), history.count - position)
            var part: Float = 0
            history.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + position, 1, &part, vDSP_Length(run)) }
            total += Double(part)
            index += Int64(run)
        }
        return total
    }

    /// Copies the `count` samples before `end` into the start of `block`.
    private func copy(end: Int64, count: Int) {
        let start = end - Int64(count)
        let position = Int(start) & mask
        let first = min(count, history.count - position)
        block.withUnsafeMutableBufferPointer { target in
            history.withUnsafeBufferPointer { source in
                target.baseAddress!.update(from: source.baseAddress! + position, count: first)
                if first < count {
                    (target.baseAddress! + first).update(from: source.baseAddress!, count: count - first)
                }
            }
        }
    }
}
