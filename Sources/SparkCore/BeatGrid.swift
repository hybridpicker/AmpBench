import Foundation

/// A place in the music. Both numbers start at 1.
public struct BarPosition: Equatable, Sendable {
    public let bar: Int
    public let beat: Int

    public init(bar: Int, beat: Int) {
        self.bar = bar
        self.beat = beat
    }
}

/// The bars of a take recorded with the metronome. Times are seconds in the file.
public struct BeatGrid: Codable, Equatable, Sendable {
    public var bpm: Double
    public var beatsPerBar: Int
    /// Where the first beat of `firstBar` lies in the file. Negative when the click started just before the file.
    public var offset: Double
    /// The number of the bar at `offset`. A re-recorded passage keeps the numbers of the bars it replaces.
    public var firstBar: Int

    /// A playhead sent to a bar line lands up to a frame before it, because file positions are whole frames. Half a
    /// millisecond covers every sample rate and is far below anything a player could hear as early.
    private static let lineTolerance = 0.0005

    public init(bpm: Double, beatsPerBar: Int, offset: Double, firstBar: Int = 1) {
        self.bpm = bpm
        self.beatsPerBar = max(beatsPerBar, 1)
        self.offset = offset
        self.firstBar = firstBar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try c.decode(Double.self, forKey: .bpm)
        beatsPerBar = max(try c.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? 4, 1)
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        firstBar = try c.decodeIfPresent(Int.self, forKey: .firstBar) ?? 1
    }

    public var secondsPerBeat: Double { 60 / bpm }
    public var secondsPerBar: Double { secondsPerBeat * Double(beatsPerBar) }

    /// How many beats have started since the first one, minus one. Nil before the first beat.
    public func beatIndex(at seconds: Double) -> Int? {
        let elapsed = seconds - offset + Self.lineTolerance
        guard elapsed >= 0 else { return nil }
        return Int((elapsed / secondsPerBeat).rounded(.down))
    }

    public func position(at seconds: Double) -> BarPosition? {
        guard let index = beatIndex(at: seconds) else { return nil }
        return BarPosition(bar: firstBar + index / beatsPerBar, beat: index % beatsPerBar + 1)
    }

    public func time(ofBar bar: Int) -> Double {
        offset + Double(bar - firstBar) * secondsPerBar
    }

    /// The bar that holds the end of the file. A bar cut off by the end still counts.
    public func lastBar(duration: Double) -> Int {
        position(at: max(duration - 2 * Self.lineTolerance, offset))?.bar ?? firstBar
    }

    /// The time span of whole bars, limited to the file. Nil when nothing of them lies in the file.
    public func loopRange(bars: ClosedRange<Int>, duration: Double) -> ClosedRange<Double>? {
        let lower = max(time(ofBar: bars.lowerBound), 0)
        let upper = min(time(ofBar: bars.upperBound + 1), duration)
        guard upper - lower >= 0.05 else { return nil }
        return lower...upper
    }

    /// The whole bars a dragged time span touches. An end exactly on a bar line does not include the next bar.
    public func snappedBars(from lower: Double, to upper: Double, duration: Double) -> ClosedRange<Int> {
        let last = lastBar(duration: duration)
        let first = min(position(at: lower)?.bar ?? firstBar, last)
        let end = min(position(at: upper - 2 * Self.lineTolerance)?.bar ?? first, last)
        return first...max(first, end)
    }
}

/// Mixes the click into playback. It is computed from the file position alone, so it stays on the grid across chunk
/// boundaries, seeks and loop jumps, and it follows the tempo control together with the audio.
public enum PlaybackClick {
    private static let decaySeconds = 0.012
    private static let endLevel = 0.001
    private static let accentFrequency = 1760.0
    private static let beatFrequency = 1175.0

    public static func mix(into samples: UnsafeMutablePointer<Float>, count: Int, firstFrame: Int64, sampleRate: Double,
                           grid: BeatGrid, volume: Float) {
        guard count > 0, sampleRate > 0, volume > 0, grid.bpm > 0 else { return }
        let tail = -log(endLevel) * decaySeconds
        let start = Double(firstFrame) / sampleRate
        var beat = max(Int(((start - tail - grid.offset) / grid.secondsPerBeat).rounded(.down)), 0)
        let endFrame = firstFrame + Int64(count)
        while true {
            let beatFrame = Int64(((grid.offset + Double(beat) * grid.secondsPerBeat) * sampleRate).rounded())
            if beatFrame >= endFrame { break }
            let isAccent = beat % grid.beatsPerBar == 0
            let frequency = isAccent ? accentFrequency : beatFrequency
            let amplitude = Double(volume) * (isAccent ? 1 : 0.7)
            let lastFrame = min(beatFrame + Int64(tail * sampleRate), endFrame - 1)
            var frame = max(beatFrame, firstFrame)
            while frame <= lastFrame {
                let elapsed = Double(frame - beatFrame) / sampleRate
                let value = sin(2 * .pi * frequency * elapsed) * exp(-elapsed / decaySeconds) * amplitude
                samples[Int(frame - firstFrame)] += Float(value)
                frame += 1
            }
            beat += 1
        }
    }
}

/// Decides which recordings a remove command means, so it never does nothing while something is marked.
public enum RemovalTargets {
    /// `menuIDs` are the rows a context menu was opened on. A click beside the rows delivers none.
    public static func resolve(menuIDs: Set<UUID>, selection: Set<UUID>, current: UUID?) -> Set<UUID> {
        if !menuIDs.isEmpty { return menuIDs }
        if !selection.isEmpty { return selection }
        return Set([current].compactMap { $0 })
    }

    /// The take that gets the focus once `removed` has left the list, so the next one is ready without a click: the
    /// first row after the last removed one, otherwise the nearest row before it. Nil when nothing is left, or when
    /// none of the removed takes is in the list.
    public static func nextFocus(in order: [UUID], removing removed: Set<UUID>) -> UUID? {
        guard let last = order.lastIndex(where: removed.contains) else { return nil }
        if let after = order[(last + 1)...].first(where: { !removed.contains($0) }) { return after }
        return order[..<last].last(where: { !removed.contains($0) })
    }
}
