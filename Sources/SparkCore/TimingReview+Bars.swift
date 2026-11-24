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

        /// What pointing at the bar shows and VoiceOver reads: its number, how steady and its numbers.
        public var text: String {
            guard let placement else { return tr("Bar %d: no counted notes", number) }
            guard let spread, let steadiness else {
                return tr("Bar %d: placement %+.1f ms, a single note, too few to judge", number, placement * 1000)
            }
            return tr("Bar %d, %@: placement %+.1f ms, spread %.1f ms, %d notes", number, steadiness.word,
                      placement * 1000, spread * 1000, counted)
        }
    }

    public enum Steadiness: Equatable, Sendable {
        case steady
        case unsteady

        /// The word beside the bar's colour, so the colour is never alone.
        public var word: String {
            switch self {
            case .steady: return tr("steady")
            case .unsteady: return tr("unsteady")
            }
        }

        /// The line between them (provisional, the owner's answer is pending): a bar is unsteady when it spreads more
        /// than 1.5 times as much as the whole take and by more than 8 ms. So a take uneven throughout has no bar
        /// of its own to point at, and a few milliseconds are never a weak spot.
        public init(spread: Double, takeSpread: Double) {
            self = spread > Self.timesTheTake * takeSpread && spread > Self.smallestUnsteady ? .unsteady : .steady
        }

        /// How many times the take's spread an unsteady bar spreads by, at least.
        public static let timesTheTake = 1.5
        /// The spread an unsteady bar exceeds in any case, in seconds.
        public static let smallestUnsteady = 0.008
    }

    /// Every bar the take's grid points reach into, with the numbers of its counted onsets.
    static func bars(of onsets: [Onset], on points: GridPoints, takeSpread: Double) -> [Bar] {
        let pointsPerBar = points.pointsPerBar
        guard !points.range.isEmpty, pointsPerBar > 0 else { return [] }
        var offsets = [[Double]](repeating: [], count: (points.range.upperBound - 1) / pointsPerBar + 1)
        for onset in onsets where onset.isCounted {
            guard let point = onset.gridPoint, let offset = onset.offset, point / pointsPerBar < offsets.count else { continue }
            offsets[point / pointsPerBar].append(offset)
        }
        return offsets.enumerated().map { index, offsets in
            var bar = Bar(number: points.grid.firstBar + index, counted: offsets.count)
            guard let numbers = Numbers(offsets) else { return bar }
            bar.placement = numbers.placement
            guard offsets.count >= 2 else { return bar }
            bar.spread = numbers.spread
            bar.steadiness = Steadiness(spread: numbers.spread, takeSpread: takeSpread)
            return bar
        }
    }
}
