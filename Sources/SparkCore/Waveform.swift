import AVFoundation
import Foundation

/// Min/max peaks of a recording at a fixed resolution, used to draw it at any width.
public struct WaveformData: Equatable, Sendable {
    public var binFrames: Int
    public var sampleRate: Double
    /// Min/max pairs.
    public var pairs: [Float]

    public init(binFrames: Int, sampleRate: Double, pairs: [Float]) {
        self.binFrames = binFrames
        self.sampleRate = sampleRate
        self.pairs = pairs
    }

    public var binCount: Int { pairs.count / 2 }
    public var duration: Double { sampleRate > 0 ? Double(binCount * binFrames) / sampleRate : 0 }

    public var peak: Float {
        var value: Float = 0
        for sample in pairs { value = max(value, abs(sample)) }
        return value
    }

    /// How much to enlarge a waveform for drawing. Limited so noise in a near-silent take stays small.
    public static func displayScale(peak: Float, maximum: Float = 100) -> Float {
        guard peak > 0 else { return 1 }
        return min(1 / peak, maximum)
    }

    /// Reduces the bins to `columns` min/max pairs covering a time range, for drawing.
    public func columns(_ columns: Int, from start: Double = 0, to end: Double? = nil) -> [(min: Float, max: Float)] {
        guard columns > 0, binCount > 0, sampleRate > 0 else { return [] }
        let binsPerSecond = sampleRate / Double(binFrames)
        let firstBin = max(0, Int(start * binsPerSecond))
        let lastBin = min(binCount, end.map { Int(($0 * binsPerSecond).rounded(.up)) } ?? binCount)
        guard lastBin > firstBin else { return [] }
        let span = Double(lastBin - firstBin)
        return (0..<columns).map { column in
            let lower = firstBin + Int(span * Double(column) / Double(columns))
            let upper = max(lower + 1, firstBin + Int(span * Double(column + 1) / Double(columns)))
            var low: Float = 1
            var high: Float = -1
            var bin = lower
            while bin < min(upper, lastBin) {
                low = min(low, pairs[bin * 2])
                high = max(high, pairs[bin * 2 + 1])
                bin += 1
            }
            return low <= high ? (low, high) : (0, 0)
        }
    }

    // MARK: Cache file

    private static let magic: UInt32 = 0x5350_4B57

    public func write(to url: URL) throws {
        var data = Data(capacity: 24 + pairs.count * 4)
        var header = [Self.magic, UInt32(binFrames), UInt32(sampleRate), UInt32(pairs.count)]
        header.withUnsafeMutableBytes { data.append(contentsOf: $0) }
        pairs.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> WaveformData? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 16 else { return nil }
        let header = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self).prefix(4)) }
        guard header[0] == magic, header[1] > 0, header[2] > 0 else { return nil }
        let count = Int(header[3])
        guard data.count == 16 + count * 4 else { return nil }
        let pairs = data.withUnsafeBytes { raw -> [Float] in
            Array(raw.bindMemory(to: Float.self)[4..<(4 + count)])
        }
        return WaveformData(binFrames: Int(header[1]), sampleRate: Double(header[2]), pairs: pairs)
    }
}

public enum AudioAnalyzer {
    public struct Analysis: Sendable {
        public let waveform: WaveformData
        public let peak: Float
        public let frames: Int64
    }

    /// Reads the whole file. `shouldPause` lets a running recording hold this back, and `isCancelled` stops it.
    public static func analyze(_ url: URL, binFrames: Int = Int(CaptureEngine.overviewBinFrames),
                               shouldPause: @Sendable () -> Bool = { false },
                               isCancelled: @Sendable () -> Bool = { false }) throws -> Analysis? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        var pairs: [Float] = []
        pairs.reserveCapacity(Int(file.length / Int64(binFrames) + 2) * 2)
        var low: Float = 1
        var high: Float = -1
        var inBin = 0
        var peak: Float = 0

        while file.framePosition < file.length {
            if isCancelled() { return nil }
            while shouldPause() {
                if isCancelled() { return nil }
                Thread.sleep(forTimeInterval: 0.25)
            }
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<channelCount {
                    let sample = channels[channel][frame]
                    low = min(low, sample)
                    high = max(high, sample)
                    peak = max(peak, abs(sample))
                }
                inBin += 1
                if inBin >= binFrames {
                    pairs.append(low)
                    pairs.append(high)
                    low = 1
                    high = -1
                    inBin = 0
                }
            }
        }
        if inBin > 0 {
            pairs.append(low)
            pairs.append(high)
        }
        return Analysis(
            waveform: WaveformData(binFrames: binFrames, sampleRate: format.sampleRate, pairs: pairs),
            peak: peak,
            frames: file.length
        )
    }
}
