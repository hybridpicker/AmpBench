import Foundation

/// Synthetic signals for the tuner's tests, its self-test and its window pictures. Nothing here is ever recorded:
/// every sample is computed, with a seeded generator, so the same call gives the same samples on every machine.
public enum TunerTestSignal {
    public static func sine(frequency: Double, sampleRate: Double, seconds: Double, amplitude: Double = 0.5,
                            phase: Double = 0.3) -> [Float] {
        let count = Int(seconds * sampleRate)
        let omega = 2 * Double.pi * frequency / sampleRate
        return (0..<count).map { Float(amplitude * sin(omega * Double($0) + phase)) }
    }

    /// A band-limited sawtooth: every harmonic below 0.45 × the sample rate at 1/h. With `decay` (seconds for the
    /// fundamental to fall by 1/e) it rings out like a string, the higher harmonics faster.
    public static func sawtooth(frequency: Double, sampleRate: Double, seconds: Double, amplitude: Double = 0.4,
                                decay: Double? = nil) -> [Float] {
        let count = Int(seconds * sampleRate)
        var samples = [Double](repeating: 0, count: count)
        var harmonic = 1
        while Double(harmonic) * frequency < 0.45 * sampleRate {
            let omega = 2 * Double.pi * frequency * Double(harmonic) / sampleRate
            let gain = 1 / Double(harmonic)
            let rate = decay.map { (1 + 0.35 * Double(harmonic - 1)) / ($0 * sampleRate) } ?? 0
            let phase = 0.7 * Double(harmonic)
            for index in 0..<count {
                samples[index] += gain * exp(-rate * Double(index)) * sin(omega * Double(index) + phase)
            }
            harmonic += 1
        }
        return normalized(samples, peak: amplitude)
    }

    /// A plucked string after Karplus and Strong: a burst of noise circling through a delay line with a symmetric
    /// three-point loss filter [b, 1 − 2b, b] and a first-order allpass. The loss filter delays every frequency by
    /// exactly one sample, and the allpass is tuned so the loop's phase delay at `frequency` is exactly
    /// sampleRate / frequency samples: the fundamental lies at `frequency`. The overtones fall off faster than the
    /// fundamental and are a little stretched by the allpass, as on a real string.
    ///
    /// `ringTime` is the time for the fundamental to fall by 60 dB. `damping` (b, up to 0.25) dulls the overtones.
    public static func karplusStrong(frequency: Double, sampleRate: Double, seconds: Double, amplitude: Double = 0.5,
                                     ringTime: Double = 4, damping: Double = 0.12, seed: UInt64 = 7) -> [Float] {
        let delay = sampleRate / frequency
        let omega = 2 * Double.pi * frequency / sampleRate
        // The loss filter brings one sample, the allpass the rest, between 0.1 and 1.1.
        let whole = Int((delay - 1 - 0.1).rounded(.down))
        let coefficient = allpassCoefficient(phaseDelay: delay - 1 - Double(whole), omega: omega)
        // High strings lose a lot per loop through the filter; so they still ring for `ringTime`, it dulls less.
        let perLoop = pow(10, -3 / (ringTime * frequency))
        let damping = min(damping, max((1 - perLoop / 0.99999) / (2 * (1 - cos(omega))), 0))
        let loss = (1 - 2 * damping) + 2 * damping * cos(omega)
        let loopGain = min(perLoop / loss, 0.99999)
        let count = Int(seconds * sampleRate)
        var generator = SeededGenerator(seed: seed)
        var line = [Double](repeating: 0, count: whole)
        var output = [Double](repeating: 0, count: count)
        var previous = 0.0, beforePrevious = 0.0, allpassIn = 0.0, allpassOut = 0.0
        var position = 0
        // The pluck: noise, softened like a pick that is not too sharp, without any DC.
        var burst = (0..<whole).map { _ in generator.uniform() * 2 - 1 }
        for _ in 0..<2 {
            burst = burst.indices.map { 0.25 * burst[($0 + whole - 1) % whole] + 0.5 * burst[$0] + 0.25 * burst[($0 + 1) % whole] }
        }
        let mean = burst.reduce(0, +) / Double(whole)
        burst = burst.map { $0 - mean }
        for index in 0..<count {
            let delayed = line[position]
            let filtered = damping * delayed + (1 - 2 * damping) * previous + damping * beforePrevious
            beforePrevious = previous
            previous = delayed
            let shifted = coefficient * filtered + allpassIn - coefficient * allpassOut
            allpassIn = filtered
            allpassOut = shifted
            let excitation = index < whole ? burst[index] : 0
            let value = excitation + loopGain * shifted
            output[index] = value
            line[position] = value
            position = (position + 1) % whole
        }
        return normalized(output, peak: amplitude)
    }

    /// The coefficient of the allpass (a + z⁻¹) / (1 + a z⁻¹) with the given phase delay at `omega`.
    static func allpassCoefficient(phaseDelay: Double, omega: Double) -> Double {
        func delay(_ a: Double) -> Double {
            (omega - 2 * atan2(a * sin(omega), 1 + a * cos(omega))) / omega
        }
        var low = -0.99, high = 0.99
        // The delay falls as the coefficient rises.
        for _ in 0..<100 {
            let middle = (low + high) / 2
            if delay(middle) > phaseDelay { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// Adds white noise `decibels` below the RMS of the signal's first half second, such as −30.
    public static func addingNoise(_ signal: [Float], decibels: Double, seed: UInt64 = 11) -> [Float] {
        let head = signal.prefix(max(min(signal.count, 24_000), 1))
        let rms = (head.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(head.count)).squareRoot()
        let noise = rms * pow(10, decibels / 20)
        var generator = SeededGenerator(seed: seed)
        return signal.map { $0 + Float(noise * generator.gaussian()) }
    }

    public static func silence(sampleRate: Double, seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    private static func normalized(_ samples: [Double], peak: Double) -> [Float] {
        let largest = samples.reduce(0) { max($0, abs($1)) }
        guard largest > 0 else { return samples.map { Float($0) } }
        return samples.map { Float($0 / largest * peak) }
    }
}

/// SplitMix64, so synthetic signals are the same everywhere.
public struct SeededGenerator: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Standard normal, by Box and Muller.
    public mutating func gaussian() -> Double {
        let first = max(uniform(), 1e-300)
        let second = uniform()
        return (-2 * log(first)).squareRoot() * cos(2 * .pi * second)
    }
}
