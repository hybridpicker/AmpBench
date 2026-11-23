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
    }

    /// How far each side of its click a cell reaches: about ±60 ms, less where the grid points lie closer.
    public static let reach = 0.060

    public var bars: ClosedRange<Int>
    public var width: Double
    public var clicks: [Click]
    public var strokes: [Stroke]

    public init(review: TimingReview, grid: BeatGrid, bars: ClosedRange<Int>, width: Double) {
        self.bars = bars
        self.width = width
        let pointsPerBeat = review.resolution.pointsPerBeat
        let pointsPerBar = grid.beatsPerBar * pointsPerBeat
        let count = bars.count * pointsPerBar
        let cellWidth = width / Double(max(count, 1))
        clicks = (0..<count).map { index in
            let inBar = index % pointsPerBar
            return Click(bar: bars.lowerBound + index / pointsPerBar,
                         beat: inBar % pointsPerBeat == 0 ? inBar / pointsPerBeat + 1 : nil,
                         x: (Double(index) + 0.5) * cellWidth)
        }

        let spacing = grid.secondsPerBeat / Double(pointsPerBeat)
        let reach = min(Self.reach, spacing / 2)
        let firstPoint = (bars.lowerBound - grid.firstBar) * pointsPerBar
        strokes = review.onsets.compactMap { onset in
            let point = onset.gridPoint ?? Int(((onset.time - grid.offset) / spacing).rounded())
            let index = point - firstPoint
            guard index >= 0, index < count else { return nil }
            let offset = onset.offset ?? onset.time - (grid.offset + Double(point) * spacing)
            let shift = min(max(offset / reach, -1), 1) * cellWidth / 2
            return Stroke(x: (Double(index) + 0.5) * cellWidth + shift, offset: offset, isCounted: onset.isCounted,
                          label: onset.isCounted ? Self.label(offset) : nil, isPastTheCell: abs(offset) > reach)
        }
    }

    /// The offset in whole milliseconds, signed, as "+18 ms".
    static func label(_ offset: Double) -> String {
        tr("%+d ms", Int((offset * 1000).rounded()))
    }
}
