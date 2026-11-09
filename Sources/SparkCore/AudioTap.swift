import CSparkRT
import Foundation

/// A mono copy of an open input for a listener that only reads, such as the tuner.
///
/// The capture callback writes the average of all channels into a lock-free ring (`CSparkRT/tap.c`); the reader
/// takes it out on its own thread. The tap never opens a device itself: a `CaptureEngine` writes into it once the tap
/// is attached, so a recording and the retro buffer keep their one audio unit. Nothing is stored, and the ring is
/// zeroed when the tap goes away.
public final class AudioTap: @unchecked Sendable {
    let pointer: OpaquePointer

    /// About 1.3 seconds at 48 kHz, so a reader that wakes every few milliseconds never falls behind.
    public init(capacityFrames: UInt32 = 65_536) {
        pointer = spark_tap_create(capacityFrames)
    }

    deinit {
        spark_tap_destroy(pointer)
    }

    public var capacity: Int { Int(spark_tap_capacity(pointer)) }

    /// The rate of the stream being written, 0 before the first one.
    public var sampleRate: Double { spark_tap_sample_rate(pointer) }

    /// Changes whenever a new stream begins, such as after the input was reopened. The reader then starts over.
    public var epoch: UInt32 { spark_tap_epoch(pointer) }

    /// Frames dropped because the reader fell behind.
    public var overruns: UInt64 { spark_tap_overruns(pointer) }

    /// Called by the engine before it attaches the tap to a new capture.
    func begin(sampleRate: Double) {
        spark_tap_begin(pointer, sampleRate)
    }

    /// Reads up to `buffer.count` frames into `buffer`. Returns how many were read.
    public func read(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return 0 }
        return Int(spark_tap_read(pointer, base, UInt32(buffer.count)))
    }

    /// Drops what was written so far.
    public func skip() {
        spark_tap_skip(pointer)
    }

    /// Writes as the capture callback does, for tests and for feeding synthetic signals.
    public func write(_ interleaved: [Float], channels: Int = 1) {
        interleaved.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            spark_tap_write(pointer, base, UInt32(samples.count / max(channels, 1)), UInt32(channels))
        }
    }

    /// For tests and synthetic feeds: begins a stream without an engine.
    public func beginForTesting(sampleRate: Double) {
        begin(sampleRate: sampleRate)
    }
}
