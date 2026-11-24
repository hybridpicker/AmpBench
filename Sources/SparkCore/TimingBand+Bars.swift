import Foundation

extension TimingBand {
    /// Where a bar lies in the band: from the left edge of its first cell over all its cells.
    public struct BarSpan: Equatable, Sendable {
        public var bar: Int
        public var left: Double
        public var width: Double
    }

    /// The bars of the band from left to right, for the colour of each and for pointing at it.
    public var barSpans: [BarSpan] {
        var spans: [BarSpan] = []
        for (index, click) in clicks.enumerated() {
            if spans.last?.bar == click.bar {
                spans[spans.count - 1].width += cellWidth
            } else {
                spans.append(BarSpan(bar: click.bar, left: Double(index) * cellWidth, width: cellWidth))
            }
        }
        return spans
    }
}
