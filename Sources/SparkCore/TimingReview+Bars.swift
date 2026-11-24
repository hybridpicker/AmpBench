import AmpText
import Foundation

extension TimingReview {
    /// One bar of a reviewed take: where its counted onsets sit and how steadily.
    public struct Bar: Equatable, Sendable {
        /// The bar's number, as the take's bars count it.
        public var number: Int
        public var counted: Int
        /// The mean offset of the bar's counted onsets. Nil without any.
        public var placement: Double?
        /// The standard deviation of the bar's counted offsets around its placement. Nil below two of them.
        public var spread: Double?
        /// Nil for a bar without a spread: a single note says nothing about how steady it was.
        public var steadiness: Steadiness?
    }

    public enum Steadiness: Equatable, Sendable {
        case steady
        case unsteady

        /// The line between them (provisional, the owner's answer is pending): a bar is unsteady when it spreads more
        /// than 1.5 times as much as the whole take and by more than 8 ms. So a take uneven throughout has no bar
        /// of its own to point at, and a few milliseconds are never a weak spot.
        public init(spread: Double, takeSpread: Double) {
            self = spread > Self.share * takeSpread && spread > Self.least ? .unsteady : .steady
        }

        /// How many times the take's spread an unsteady bar spreads by, at least.
        public static let share = 1.5
        /// The spread an unsteady bar exceeds in any case, in seconds.
        public static let least = 0.008
    }

    /// Every bar the take's grid points reach into, with the numbers of its counted onsets.
    static func bars(of onsets: [Onset], grid: BeatGrid, resolution: Resolution, duration: Double,
                     takeSpread: Double) -> [Bar] {
        let pointsPerBar = grid.beatsPerBar * resolution.pointsPerBeat
        let spacing = grid.secondsPerBeat / Double(resolution.pointsPerBeat)
        let lastPoint = Int(((duration - grid.offset) / spacing).rounded(.down))
        guard lastPoint >= 0, pointsPerBar > 0 else { return [] }
        var offsets = [[Double]](repeating: [], count: lastPoint / pointsPerBar + 1)
        for onset in onsets where onset.isCounted {
            guard let point = onset.gridPoint, let offset = onset.offset, point / pointsPerBar < offsets.count else { continue }
            offsets[point / pointsPerBar].append(offset)
        }
        return offsets.enumerated().map { index, offsets in
            var bar = Bar(number: grid.firstBar + index, counted: offsets.count)
            guard !offsets.isEmpty else { return bar }
            let placement = offsets.reduce(0, +) / Double(offsets.count)
            let variance = offsets.reduce(0) { $0 + ($1 - placement) * ($1 - placement) } / Double(offsets.count)
            bar.placement = placement
            guard offsets.count >= 2 else { return bar }
            bar.spread = variance.squareRoot()
            bar.steadiness = Steadiness(spread: variance.squareRoot(), takeSpread: takeSpread)
            return bar
        }
    }
}
