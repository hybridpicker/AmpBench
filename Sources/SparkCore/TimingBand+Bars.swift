import Foundation

extension TimingBand {
    /// Where a bar lies in the band, from the left edge of its first cell over all its cells, and what the review says
    /// of it.
    public struct BarSpan: Equatable, Sendable {
        public var bar: Int
        public var left: Double
        public var width: Double
        /// The bar's numbers in the review; nil for a bar the review does not reach.
        public var reviewed: TimingReview.Bar?

        public init(bar: Int, left: Double, width: Double, reviewed: TimingReview.Bar? = nil) {
            self.bar = bar
            self.left = left
            self.width = width
            self.reviewed = reviewed
        }

        /// Steady or unsteady, for the bar's color and word; nil for a bar not judged.
        public var steadiness: TimingReview.Steadiness? { reviewed?.steadiness }
    }
}
