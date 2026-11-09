import Foundation

/// Reads an `AudioTap` on its own thread, every 5 ms, and runs the `PitchTracker` there, never on the audio thread.
/// The main thread takes the latest `Snapshot` whenever it redraws.
///
/// The engine only reads: it opens no device, sends nothing anywhere, writes nothing to disk and logs no audio.
public final class TunerEngine: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var reading: PitchReading?
        public var hasSignal = false
        public var levelDB = -120.0
        /// Seconds of audio analyzed since the stream began.
        public var time = 0.0
        public var sampleRate = 0.0
        /// True while samples arrive.
        public var isReceiving = false

        public init() {}
    }

    public let tap: AudioTap
    private let queue = DispatchQueue(label: "local.sparkstudio.tuner", qos: .userInteractive)
    private let lock = NSLock()
    private var latest = Snapshot()
    private var timer: DispatchSourceTimer?

    // Only touched on `queue`.
    private var tracker: PitchTracker?
    private var epoch: UInt32 = 0
    private var overruns: UInt64 = 0
    private var buffer = [Float](repeating: 0, count: 8192)
    private var quietSince: DispatchTime?

    public init(tap: AudioTap = AudioTap()) {
        self.tap = tap
    }

    deinit {
        timer?.cancel()
    }

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    public var isRunning: Bool { timer != nil }

    /// Starts reading. What the tap held before is dropped.
    public func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.step() }
        queue.async { [weak self] in self?.startOver() }
        timer.resume()
        self.timer = timer
    }

    /// Stops reading and forgets the pitch.
    public func stop() {
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in
            guard let self else { return }
            tracker = nil
            tap.skip()
            publish(Snapshot())
        }
    }

    private func startOver() {
        tap.skip()
        epoch = tap.epoch
        overruns = tap.overruns
        let rate = tap.sampleRate
        tracker = rate > 0 ? PitchTracker(sampleRate: rate) : nil
        quietSince = nil
    }

    private func step() {
        // A new stream, a different rate or a gap: the old pitch means nothing any more.
        if tap.epoch != epoch || tap.overruns != overruns || (tracker == nil && tap.sampleRate > 0) {
            startOver()
        }
        guard let tracker else {
            publish(Snapshot())
            return
        }
        var received = 0
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { tap.read(into: $0) }
            guard count > 0 else { break }
            buffer.withUnsafeBufferPointer { tracker.process(UnsafeBufferPointer(rebasing: $0[0..<count])) }
            received += count
            if count < buffer.count { break }
        }
        let now = DispatchTime.now()
        if received > 0 {
            quietSince = nil
        } else if quietSince == nil {
            quietSince = now
        }
        // No samples for a quarter second: the input has stopped, so nothing is heard.
        let receiving = quietSince.map { now.uptimeNanoseconds - $0.uptimeNanoseconds < 250_000_000 } ?? true
        if !receiving, tracker.time > 0 { tracker.reset() }
        var snapshot = Snapshot()
        snapshot.reading = tracker.reading
        snapshot.hasSignal = tracker.hasSignal
        snapshot.levelDB = tracker.levelDB
        snapshot.time = tracker.seconds
        snapshot.sampleRate = tracker.sampleRate
        snapshot.isReceiving = receiving && tracker.time > 0
        publish(snapshot)
    }

    private func publish(_ snapshot: Snapshot) {
        lock.lock()
        latest = snapshot
        lock.unlock()
    }
}
