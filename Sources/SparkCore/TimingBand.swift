import AmpText
import Foundation

/// The timing band below the waveform: a few bars of a take's timing review, each grid point magnified.
///
/// The band is a row of equal cells, one per grid point of the bars it shows. The click line of a grid point stands
/// fixed in the middle of its cell with its beat number; the onsets are strokes beside it, as far off as they were
/// played. Positions are points from the band's left edge, for the width it is drawn at. The view only draws this.
public struct TimingBand: Equatable, Sendable {
    /// A grid point of the band, its click line in the middle of its cell.
    public struct GridPoint: Equatable, Sendable {
        public var bar: Int
        /// The beat it lies in, from 1.
        public var beat: Int
        /// Its place in the beat: 0 on the beat, 1 for the next grid point, and so on.
        public var step: Int
        public var x: Double

        /// The beat number drawn above it: on a beat its number, nil between the beats.
        public var number: Int? { step == 0 ? beat : nil }
    }

    /// An onset beside the click line of its grid point.
    public struct Stroke: Equatable, Sendable {
        public var x: Double
        /// From the click line, positive later.
        public var offset: Double
        /// Counted onsets are drawn full, the others faint.
        public var isCounted: Bool
        /// The offset in milliseconds, for a counted onset. Faint strokes carry none.
        public var label: String?
        /// The same offset without its unit, as "+18", for cells too narrow for the label, as on sixteenths.
        public var shortLabel: String?
        /// Further off than the cell reaches: drawn at its edge, with its true offset.
        public var isPastTheCell: Bool
        /// The index of its grid point in `points`, whose cell it is drawn in.
        public var point: Int
    }

    /// How far each side of its click line a cell reaches: about ±60 ms, less where the grid points lie closer.
    public static let reach = 0.060

    public var bars: ClosedRange<Int>
    public var width: Double
    public var resolution: TimingReview.Resolution
    public var points: [GridPoint]
    public var strokes: [Stroke]
    /// The bars of the band from left to right, for the color of each and for pointing at it.
    public var barSpans: [BarSpan]
    /// The width of the cell around each grid point.
    public var cellWidth: Double
    /// How far each side of its click line a cell reaches here, in seconds.
    public var cellReach: Double
    /// Where the first grid point of the band lies in the file, and the time from one to the next.
    private var firstTime: Double
    private var spacing: Double

    public init(review: TimingReview, grid: BeatGrid, bars: ClosedRange<Int>, width: Double) {
        self.bars = bars
        self.width = width
        resolution = review.resolution
        let take = GridPoints(grid: grid, resolution: review.resolution)
        let pointsPerBeat = take.pointsPerBeat
        let pointsPerBar = take.pointsPerBar
        let count = bars.count * pointsPerBar
        let cellWidth = width / Double(max(count, 1))
        self.cellWidth = cellWidth
        points = (0..<count).map { index in
            let inBar = index % pointsPerBar
            return GridPoint(bar: bars.lowerBound + index / pointsPerBar, beat: inBar / pointsPerBeat + 1,
                             step: inBar % pointsPerBeat, x: (Double(index) + 0.5) * cellWidth)
        }
        barSpans = bars.enumerated().map { index, bar in
            BarSpan(bar: bar, left: Double(index * pointsPerBar) * cellWidth, width: Double(pointsPerBar) * cellWidth,
                    reviewed: review.bars.first { $0.number == bar })
        }

        let reach = min(Self.reach, take.spacing / 2)
        let firstPoint = take.first(ofBar: bars.lowerBound)
        spacing = take.spacing
        cellReach = reach
        firstTime = take.time(of: firstPoint)
        strokes = review.onsets.compactMap { onset in
            let point = onset.gridPoint ?? take.nearest(to: onset.time)
            let index = point - firstPoint
            guard index >= 0, index < count else { return nil }
            let offset = onset.offset ?? onset.time - take.time(of: point)
            let shift = min(max(offset / reach, -1), 1) * cellWidth / 2
            return Stroke(x: (Double(index) + 0.5) * cellWidth + shift, offset: offset, isCounted: onset.isCounted,
                          label: onset.isCounted ? Self.label(offset) : nil,
                          shortLabel: onset.isCounted ? Self.shortLabel(offset) : nil,
                          isPastTheCell: abs(offset) > reach, point: index)
        }
    }

    /// What the area Record shows of a take's timing below its waveform.
    public enum Showing: Equatable, Sendable {
        /// The band of this review, with the status line below the transport.
        case band(TimingReview)
        /// Only the status line, the band folded away.
        case folded
        /// One line: why there is no review, or that it is being worked out.
        case line

        /// Only a review has a band to fold.
        public var canFold: Bool { self != .line }
    }

    /// The band opens on its own for a take with a review, unless it was folded; any other take shows one line.
    public static func shows(_ outcome: TimingReview.Outcome?, folded: Bool) -> Showing {
        guard let review = outcome?.review else { return .line }
        return folded ? .folded : .band(review)
    }

    /// Where a moment of the file lies in the band, such as the playhead: only within a cell, since the band shows
    /// no time between them.
    public func x(at seconds: Double) -> Double? {
        let index = Int(((seconds - firstTime) / spacing).rounded())
        let offset = seconds - (firstTime + Double(index) * spacing)
        guard index >= 0, index < points.count, abs(offset) <= cellReach else { return nil }
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

    /// What VoiceOver reads for the band: the bars it shows, then every counted note by its place in the bar and its
    /// offset, as "Bars 1–2: bar 1 beat 2 +18 ms, bar 1 beat 2 and -7 ms".
    public var spoken: String {
        let shown = bars.count == 1 ? tr("Bar %d", bars.lowerBound) : tr("Bars %d–%d", bars.lowerBound, bars.upperBound)
        let notes = strokes.compactMap { stroke in stroke.label.map { place(of: points[stroke.point], offset: $0) } }
        guard !notes.isEmpty else { return tr("%@, no counted notes", shown) }
        return tr("%@: %@", shown, notes.joined(separator: ", "))
    }

    /// A note's place and offset, as "bar 1 beat 2 and +18 ms".
    private func place(of point: GridPoint, offset: String) -> String {
        guard point.step > 0 else { return tr("bar %d beat %d %@", point.bar, point.beat, offset) }
        switch resolution {
        case .quarters, .eighths: return tr("bar %d beat %d and %@", point.bar, point.beat, offset)
        case .triplets: return tr("bar %d beat %d triplet %d %@", point.bar, point.beat, point.step + 1, offset)
        case .sixteenths: return tr("bar %d beat %d sixteenth %d %@", point.bar, point.beat, point.step + 1, offset)
        }
    }

    /// The offset in whole milliseconds, signed, as "+18 ms".
    static func label(_ offset: Double) -> String {
        tr("%+d ms", Int((offset * 1000).rounded()))
    }

    /// The offset in whole milliseconds, signed, without the unit.
    static func shortLabel(_ offset: Double) -> String {
        String(format: "%+d", Int((offset * 1000).rounded()))
    }
}
