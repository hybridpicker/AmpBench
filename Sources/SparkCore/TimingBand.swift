import AmpText
import Foundation

/// The timing band below the waveform: a few bars of a take's timing review, each grid point magnified.
///
/// The band is a row of equal cells, one per grid point of the bars it shows. The click line of a grid point stands
/// fixed in the middle of its cell with its beat number; the onsets are strokes beside it, as far off as they were
/// played. Positions are points from the band's left edge, for the width it is drawn at. The view only draws this.
public struct TimingBand: Equatable, Sendable {
    /// A click line: a grid point in the middle of its cell.
    public struct Click: Equatable, Sendable {
        public var bar: Int
        /// The beat number on a beat, from 1. Nil on a grid point between the beats.
        public var beat: Int?
        public var x: Double
    }

    /// An onset beside the click of its grid point.
    public struct Stroke: Equatable, Sendable {
        public var x: Double
        /// From the click, positive later.
        public var offset: Double
        /// Counted onsets are drawn full, the others faint.
        public var isCounted: Bool
        /// The offset in milliseconds, for a counted onset. Faint strokes carry none.
        public var label: String?
        /// Further off than the cell reaches: drawn at its edge, with its true offset.
        public var isPastTheCell: Bool
        /// The index of its click in `clicks`, whose cell it is drawn in.
        public var click: Int
    }

    /// How far each side of its click a cell reaches: about ±60 ms, less where the grid points lie closer.
    public static let reach = 0.060

    public var bars: ClosedRange<Int>
    public var width: Double
    public var clicks: [Click]
    public var strokes: [Stroke]
    /// The width of the cell around each click.
    public var cellWidth: Double
    /// How far each side of its click a cell reaches here, in seconds.
    public var cellReach: Double
    /// Where the first click of the band lies in the file, and the time from click to click.
    private var firstClick: Double
    private var spacing: Double

    public init(review: TimingReview, grid: BeatGrid, bars: ClosedRange<Int>, width: Double) {
        self.bars = bars
        self.width = width
        let pointsPerBeat = review.resolution.pointsPerBeat
        let pointsPerBar = grid.beatsPerBar * pointsPerBeat
        let count = bars.count * pointsPerBar
        let cellWidth = width / Double(max(count, 1))
        self.cellWidth = cellWidth
        clicks = (0..<count).map { index in
            let inBar = index % pointsPerBar
            return Click(bar: bars.lowerBound + index / pointsPerBar,
                         beat: inBar % pointsPerBeat == 0 ? inBar / pointsPerBeat + 1 : nil,
                         x: (Double(index) + 0.5) * cellWidth)
        }

        let spacing = grid.secondsPerBeat / Double(pointsPerBeat)
        let reach = min(Self.reach, spacing / 2)
        let firstPoint = (bars.lowerBound - grid.firstBar) * pointsPerBar
        self.spacing = spacing
        cellReach = reach
        firstClick = grid.offset + Double(firstPoint) * spacing
        strokes = review.onsets.compactMap { onset in
            let point = onset.gridPoint ?? Int(((onset.time - grid.offset) / spacing).rounded())
            let index = point - firstPoint
            guard index >= 0, index < count else { return nil }
            let offset = onset.offset ?? onset.time - (grid.offset + Double(point) * spacing)
            let shift = min(max(offset / reach, -1), 1) * cellWidth / 2
            return Stroke(x: (Double(index) + 0.5) * cellWidth + shift, offset: offset, isCounted: onset.isCounted,
                          label: onset.isCounted ? Self.label(offset) : nil, isPastTheCell: abs(offset) > reach, click: index)
        }
    }

    /// What the area Record shows of a take's timing below its waveform.
    public enum Showing: Equatable, Sendable {
        /// The band with the status line above it.
        case band
        /// Only the status line, the band folded away.
        case folded
        /// One line: why there is no review, or that it is being worked out.
        case line

        /// Only a review has a band to fold.
        public var canFold: Bool { self != .line }
    }

    /// The band opens on its own for a take with a review, unless it was folded; any other take shows one line.
    public static func shows(_ outcome: TimingReview.Outcome?, folded: Bool) -> Showing {
        guard case .review = outcome else { return .line }
        return folded ? .folded : .band
    }

    /// Where a moment of the file lies in the band, such as the playhead: only within a cell, since the band shows
    /// no time between them.
    public func x(at seconds: Double) -> Double? {
        let index = Int(((seconds - firstClick) / spacing).rounded())
        let offset = seconds - (firstClick + Double(index) * spacing)
        guard index >= 0, index < clicks.count, abs(offset) <= cellReach else { return nil }
        return (Double(index) + 0.5 + offset / cellReach / 2) * cellWidth
    }

    /// The two bars the band shows with the playhead at `seconds`: bars go in pairs from the take's first bar, so the
    /// band stands still while a pair plays and turns over at the next. Before the first bar it shows the first pair;
    /// the last bar of an odd take comes with the bar before it.
    public static func pair(at seconds: Double, grid: BeatGrid, lastBar: Int) -> ClosedRange<Int> {
        pair(holding: grid.position(at: seconds)?.bar ?? grid.firstBar, firstBar: grid.firstBar, lastBar: lastBar)
    }

    /// The two bars the band shows for chosen bars: the pair that holds the first of them.
    public static func pair(showing selection: ClosedRange<Int>, grid: BeatGrid, lastBar: Int) -> ClosedRange<Int> {
        pair(holding: selection.lowerBound, firstBar: grid.firstBar, lastBar: lastBar)
    }

    private static func pair(holding bar: Int, firstBar: Int, lastBar: Int) -> ClosedRange<Int> {
        let last = max(lastBar, firstBar)
        let bar = min(max(bar, firstBar), last)
        let start = firstBar + (bar - firstBar) / 2 * 2
        let end = min(start + 1, last)
        return max(end - 1, firstBar)...end
    }

    /// The offset in whole milliseconds, signed, as "+18 ms".
    static func label(_ offset: Double) -> String {
        tr("%+d ms", Int((offset * 1000).rounded()))
    }
}
