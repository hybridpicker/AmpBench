import Accelerate
import Foundation

/// One coarse estimate of the period of a block of samples.
public struct PeriodEstimate: Equatable, Sendable {
    /// The period in samples, interpolated between samples.
    public var lag: Double
    /// How periodic the block is at that lag, from 0 to 1: the height of the normalized square difference function.
    public var clarity: Double
    /// The largest lag that was searched. A lag can only be trusted when its octave below was searched too.
    public var searchedUpTo: Int
}

/// The McLeod pitch method (MPM): the normalized square difference function (NSDF) of a block, computed through an
/// FFT, and the first of its key maxima that comes close to the highest one, with parabolic interpolation.
///
/// It finds the period to about a cent. The tuner's precision comes afterwards from `PhaseEstimator`. One detector
/// owns its buffers and is used from one thread; after `init` it allocates nothing.
public final class PeriodDetector {
    public let maxWindow: Int
    /// A key maximum counts when it reaches this share of the highest one. McLeod suggests 0.8 to 0.93.
    public var keyThreshold = 0.9

    private let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var padded: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var correlation: [Float]
    private var nsdf: [Double]

    public init(maxWindow: Int) {
        self.maxWindow = max(maxWindow, 64)
        var size = 1
        var bits = 0
        while size < 2 * self.maxWindow { size <<= 1; bits += 1 }
        fftSize = size
        log2n = vDSP_Length(bits)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        padded = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        correlation = [Float](repeating: 0, count: size)
        nsdf = [Double](repeating: 0, count: self.maxWindow)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Estimates the period of `samples` between `minLag` and `maxLag` samples. Nil when the block is not periodic
    /// in that range. Only the first `maxWindow` samples are used.
    public func estimate(_ samples: UnsafeBufferPointer<Float>, minLag: Int, maxLag: Int) -> PeriodEstimate? {
        let window = min(samples.count, maxWindow)
        let upper = min(maxLag, window / 2)
        guard window >= 8, upper > minLag + 2, let source = samples.baseAddress else { return nil }

        // Autocorrelation through the FFT of the zero-padded block.
        padded.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.update(from: source, count: window)
            for index in window..<fftSize { buffer[index] = 0 }
        }
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                padded.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // The power spectrum. In the packed format the first imaginary value holds the Nyquist bin.
                let nyquist = split.imagp[0] * split.imagp[0]
                split.realp[0] = split.realp[0] * split.realp[0]
                split.imagp[0] = 0
                for bin in 1..<(fftSize / 2) {
                    split.realp[bin] = split.realp[bin] * split.realp[bin] + split.imagp[bin] * split.imagp[bin]
                    split.imagp[bin] = 0
                }
                split.imagp[0] = nyquist
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                correlation.withUnsafeMutableBufferPointer { output in
                    output.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(fftSize / 2))
                    }
                }
            }
        }

        // The FFT scales the correlation; lag 0 is the energy, which gives the scale.
        var energy = 0.0
        for index in 0..<window { energy += Double(source[index]) * Double(source[index]) }
        guard energy > 1e-12, correlation[0] > 0 else { return nil }
        let scale = energy / Double(correlation[0])

        // NSDF: n(τ) = 2 r(τ) / m(τ), with m(τ) the energy of both overlapping parts, updated lag by lag.
        var sum = 2 * energy
        nsdf[0] = 1
        for lag in 1...upper {
            let early = Double(source[lag - 1])
            let late = Double(source[window - lag])
            sum -= early * early + late * late
            nsdf[lag] = sum > 1e-12 ? 2 * Double(correlation[lag]) * scale / sum : 0
        }

        // Key maxima: the highest point of each positive lobe after the first negative stretch.
        var lag = 1
        while lag <= upper && nsdf[lag] > 0 { lag += 1 }
        var bestValue = 0.0
        var keys: [(Int, Double)] = []
        keys.reserveCapacity(64)
        while lag <= upper {
            while lag <= upper && nsdf[lag] <= 0 { lag += 1 }
            var peak = -1
            while lag <= upper && nsdf[lag] > 0 {
                if peak < 0 || nsdf[lag] > nsdf[peak] { peak = lag }
                lag += 1
            }
            if peak > minLag && peak < upper {
                keys.append((peak, nsdf[peak]))
                bestValue = max(bestValue, nsdf[peak])
            }
        }
        guard bestValue > 0, let chosen = keys.first(where: { $0.1 >= keyThreshold * bestValue }) else { return nil }

        // Parabolic interpolation through the peak and its neighbors.
        let (index, _) = chosen
        let left = nsdf[index - 1], middle = nsdf[index], right = nsdf[index + 1]
        let denominator = left - 2 * middle + right
        let offset = abs(denominator) > 1e-12 ? max(-0.5, min(0.5, 0.5 * (left - right) / denominator)) : 0
        let height = middle - 0.25 * (left - right) * offset
        return PeriodEstimate(lag: Double(index) + offset, clarity: min(height, 1), searchedUpTo: upper)
    }

    /// The NSDF value at an integer lag from the last estimate, for tests.
    func nsdfValue(at lag: Int) -> Double { nsdf[lag] }
}

/// The fine estimate: the phase of the fundamental, measured again and again, and a straight line through it.
///
/// Each measurement demodulates a Hann-windowed block at a fixed reference frequency. For a tone at the reference plus
/// δ the phase at the block's center grows exactly by δ per sample, also while the tone decays, so a weighted
/// least-squares line through the phases over up to `maxSpan` gives the frequency to a fraction of a cent.
///
/// The span shrinks at once when the pitch moves (a peg being turned) and grows again while it holds. Whether the
/// pitch moves is judged against the measured noise: every block is also demodulated halfway between the fundamental
/// and its octave, where a string has nothing but noise, which says how much the phases scatter. A weak tone thus
/// keeps its long, calm line instead of chasing its own noise.
public final class PhaseEstimator {
    public struct Point: Sendable {
        /// The block's center, in samples since the reference was set.
        public var time: Double
        public var phase: Double
        public var weight: Double
        /// The power beside the tone relative to the tone: about the variance of `phase`.
        public var noise: Double
    }

    public let sampleRate: Double
    public private(set) var reference: Double = 0
    public private(set) var points: [Point] = []
    /// The longest span the line runs through, in seconds.
    public var maxSpan = 0.6
    /// The span of the quick line that notices a moving pitch, in seconds.
    public var shortSpan = 0.08
    /// The quick and the long line differ at least this much, in cents, when the pitch moves ...
    public var moveThreshold = 1.2
    /// ... and by this many of the quick line's standard errors.
    public var moveSigmas = 6.0
    /// How often the long line was given up for a moving pitch, for tests.
    public private(set) var prunes = 0

    private var origin: Int64 = 0
    private var cosine: [Float]
    private var sine: [Float]
    private var probeCosine: [Float]
    private var probeSine: [Float]
    private var window: [Float]
    private var windowLength = 0
    private var scratch: [Float]
    private var movingCount = 0
    private var blockLength = 0.0

    public init(sampleRate: Double, maxLength: Int) {
        self.sampleRate = sampleRate
        cosine = [Float](repeating: 0, count: maxLength)
        sine = [Float](repeating: 0, count: maxLength)
        probeCosine = [Float](repeating: 0, count: maxLength)
        probeSine = [Float](repeating: 0, count: maxLength)
        window = [Float](repeating: 0, count: maxLength + 1)
        scratch = [Float](repeating: 0, count: maxLength)
    }

    public var maxLength: Int { cosine.count }

    /// Starts over at a new reference frequency. `origin` is the absolute sample that phase 0 refers to.
    public func reset(reference: Double, origin: Int64) {
        self.reference = reference
        self.origin = origin
        points.removeAll(keepingCapacity: true)
        movingCount = 0
        let omega = 2 * Double.pi * reference / sampleRate
        for index in 0..<cosine.count {
            let angle = omega * Double(index)
            cosine[index] = Float(cos(angle))
            sine[index] = Float(sin(angle))
            probeCosine[index] = Float(cos(1.5 * angle))
            probeSine[index] = Float(sin(1.5 * angle))
        }
    }

    public func clear() {
        reference = 0
        points.removeAll(keepingCapacity: true)
        movingCount = 0
    }

    /// Measures the block `samples`, whose first sample is absolute sample `start`, and adds its phase.
    public func measure(_ samples: UnsafeBufferPointer<Float>, start: Int64) {
        let length = min(samples.count, cosine.count)
        guard reference > 0, length >= 16, let source = samples.baseAddress else { return }
        if windowLength != length {
            // vDSP's Hann window is periodic. Of one with length + 1 points, the points 1...length are symmetric
            // about the block's center (length - 1) / 2, which keeps the phase free of any window term.
            window.withUnsafeMutableBufferPointer {
                vDSP_hann_window($0.baseAddress!, vDSP_Length(length + 1), Int32(vDSP_HANN_DENORM))
            }
            windowLength = length
        }
        var inPhase: Float = 0, quadrature: Float = 0, probeIn: Float = 0, probeOut: Float = 0
        scratch.withUnsafeMutableBufferPointer { weighted in
            window.withUnsafeBufferPointer { hann in
                vDSP_vmul(source, 1, hann.baseAddress! + 1, 1, weighted.baseAddress!, 1, vDSP_Length(length))
            }
            vDSP_dotpr(weighted.baseAddress!, 1, cosine, 1, &inPhase, vDSP_Length(length))
            vDSP_dotpr(weighted.baseAddress!, 1, sine, 1, &quadrature, vDSP_Length(length))
            vDSP_dotpr(weighted.baseAddress!, 1, probeCosine, 1, &probeIn, vDSP_Length(length))
            vDSP_dotpr(weighted.baseAddress!, 1, probeSine, 1, &probeOut, vDSP_Length(length))
        }
        let magnitude = Double(inPhase) * Double(inPhase) + Double(quadrature) * Double(quadrature)
        guard magnitude > 1e-18 else { return }
        let omega = 2 * Double.pi * reference / sampleRate
        let offset = Double(start - origin)
        // The sum ran over e^{-iωk}; shifting it to absolute time adds -ω·(start - origin).
        var phase = atan2(-Double(quadrature), Double(inPhase)) - remainder(omega * offset, 2 * .pi)
        let center = offset + Double(length - 1) / 2
        if let last = points.last {
            let predicted = last.phase + (slope() ?? 0) * (center - last.time)
            phase += 2 * .pi * ((predicted - phase) / (2 * .pi)).rounded()
        }
        // A complex noise sample of power p beside a tone of power m scatters the phase by about p / (2m).
        let noise = (Double(probeIn) * Double(probeIn) + Double(probeOut) * Double(probeOut)) / (2 * magnitude)
        points.append(Point(time: center, phase: phase, weight: magnitude, noise: noise))
        prune(before: center - maxSpan * sampleRate)
        blockLength = Double(length)
        watchForMovement(now: center, blockLength: Double(length))
    }

    /// The frequency from the line through the phases, or nil with too few of them.
    public var frequency: Double? {
        guard let slope = slope() else { return nil }
        return reference + slope * sampleRate / (2 * .pi)
    }

    /// The expected error of `frequency` in cents, from the measured noise of the phases: their mean variance,
    /// and about one independent phase per block length over the span.
    public var expectedError: Double? {
        guard points.count >= 3, reference > 0, let last = points.last, let first = points.first else { return nil }
        let length = (last.time - first.time)
        guard length > 0 else { return nil }
        let variance = points.reduce(0) { $0 + $1.noise } / Double(points.count)
        let independent = 1 + length / max(blockLength, 1)
        let slopeError = (variance * 12 / independent).squareRoot() / length
        return 1200 / log(2) * slopeError * sampleRate / (2 * .pi) / reference
    }

    /// How long the line runs, in seconds.
    public var span: Double {
        guard let first = points.first, let last = points.last else { return 0 }
        return (last.time - first.time) / sampleRate
    }

    /// The weighted least-squares slope of the phases since `time`, in radians per sample.
    private func slope(since time: Double = -.infinity) -> Double? {
        var weightSum = 0.0, timeSum = 0.0, phaseSum = 0.0, count = 0
        for point in points where point.time >= time {
            weightSum += point.weight
            timeSum += point.weight * point.time
            phaseSum += point.weight * point.phase
            count += 1
        }
        guard count >= 3, weightSum > 0 else { return nil }
        let meanTime = timeSum / weightSum, meanPhase = phaseSum / weightSum
        var covariance = 0.0, variance = 0.0
        for point in points where point.time >= time {
            let dt = point.time - meanTime
            covariance += point.weight * dt * (point.phase - meanPhase)
            variance += point.weight * dt * dt
        }
        return variance > 0 ? covariance / variance : nil
    }

    private func prune(before time: Double) {
        if let first = points.firstIndex(where: { $0.time >= time }), first > 0 {
            points.removeFirst(first)
        }
    }

    /// When a quick line over the last moments disagrees with the long one several times in a row, by more than its
    /// own noise allows, the pitch is moving: the long line is dropped, so the reading follows at once instead of
    /// averaging old and new.
    private func watchForMovement(now: Double, blockLength: Double) {
        let shortLength = shortSpan * sampleRate
        let shortStart = now - shortLength
        let recent = points.filter { $0.time >= shortStart }
        guard span > shortSpan * 2, recent.count >= 3, let long = slope(), let short = slope(since: shortStart) else {
            movingCount = 0
            return
        }
        let longFrequency = reference + long * sampleRate / (2 * .pi)
        let shortFrequency = reference + short * sampleRate / (2 * .pi)
        guard longFrequency > 0, shortFrequency > 0 else { return }
        // The blocks overlap, so the quick line rests on about 1 + span / block independent phases.
        let phaseVariance = recent.reduce(0) { $0 + $1.noise } / Double(recent.count)
        let independent = 1 + shortLength / blockLength
        let slopeError = (phaseVariance * 12 / independent).squareRoot() / shortLength
        let errorCents = 1200 / log(2) * slopeError * sampleRate / (2 * .pi) / longFrequency
        if abs(1200 * log2(shortFrequency / longFrequency)) > max(moveThreshold, moveSigmas * errorCents) {
            movingCount += 1
            if movingCount >= 3 {
                prunes += 1
                prune(before: shortStart)
                movingCount = 0
            }
        } else {
            movingCount = 0
        }
    }
}
