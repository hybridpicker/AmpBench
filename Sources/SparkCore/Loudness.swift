import Foundation

/// How loud a mono signal is to the ear, after ITU-R BS.1770: the signal goes through the K weighting (a shelf that
/// lifts the highs and a high pass), is cut into blocks of 400 ms that overlap by three quarters, and the blocks
/// that are silence or far below the rest are left out. The result is in LUFS; a full-scale 997 Hz sine reads −3.01.
///
/// It is fed in pieces, so a listener can measure while the input runs.
public struct Loudness: Sendable {
    public let sampleRate: Double
    private var shelf: Biquad
    private var highPass: Biquad
    private let blockFrames: Int
    private let hopFrames: Int
    /// The weighted squares of the last block's frames, as a ring.
    private var squares: [Double]
    private var position = 0
    private var filled = 0
    private var sinceBlock = 0
    private var running = 0.0
    private var blocks: [Double] = []
    public private(set) var peak: Float = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        shelf = .shelf(sampleRate: sampleRate)
        highPass = .highPass(sampleRate: sampleRate)
        blockFrames = max(Int((sampleRate * 0.4).rounded()), 1)
        hopFrames = max(Int((sampleRate * 0.1).rounded()), 1)
        squares = Array(repeating: 0, count: blockFrames)
    }

    public mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            peak = max(peak, abs(sample))
            let weighted = highPass.process(shelf.process(Double(sample)))
            let square = weighted * weighted
            running += square - squares[position]
            squares[position] = square
            position = (position + 1) % blockFrames
            filled = min(filled + 1, blockFrames)
            sinceBlock += 1
            if filled == blockFrames, sinceBlock >= hopFrames {
                sinceBlock = 0
                // The running sum drifts by rounding over minutes; a fresh sum every block costs little.
                running = squares.reduce(0, +)
                blocks.append(running / Double(blockFrames))
            }
        }
    }

    public mutating func add(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { add($0) }
    }

    /// Seconds of signal in the blocks measured so far.
    public var measuredSeconds: Double { blocks.isEmpty ? 0 : 0.4 + Double(blocks.count - 1) * 0.1 }

    /// The gated loudness in LUFS, or nil when nothing was above the gate of −70 LUFS.
    public var integrated: Double? {
        let audible = blocks.filter { Self.lufs($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let gate = Self.lufs(audible.reduce(0, +) / Double(audible.count)) - 10
        let kept = audible.filter { Self.lufs($0) > gate }
        guard !kept.isEmpty else { return nil }
        return Self.lufs(kept.reduce(0, +) / Double(kept.count))
    }

    /// The share of the measured blocks that passed both gates: low when the playing had long gaps.
    public var keptShare: Double {
        guard !blocks.isEmpty else { return 0 }
        let audible = blocks.filter { Self.lufs($0) > -70 }
        guard !audible.isEmpty else { return 0 }
        let gate = Self.lufs(audible.reduce(0, +) / Double(audible.count)) - 10
        return Double(audible.filter { Self.lufs($0) > gate }.count) / Double(blocks.count)
    }

    static func lufs(_ meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }

    struct Biquad: Sendable {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }

        // The standard gives coefficients for 48 kHz only. These are the analog filters behind them, so every rate
        // gets the same curve.
        static func shelf(sampleRate: Double) -> Biquad {
            let k = tan(.pi * 1681.974450955533 / sampleRate), q = 0.7071752369554196
            let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            return Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                          b2: (vh - vb * k / q + k * k) / a0, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        }

        static func highPass(sampleRate: Double) -> Biquad {
            let k = tan(.pi * 38.13547087602444 / sampleRate), q = 0.5003270373238773
            let a0 = 1 + k / q + k * k
            return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        }
    }
}
