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
        /// The standard deviation of the bar's counted offsets around its placement. Nil without any.
        public var spread: Double?
    }

    /// Every bar the take's grid points reach into, with the numbers of its counted onsets.
    static func bars(of onsets: [Onset], grid: BeatGrid, resolution: Resolution, duration: Double) -> [Bar] {
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
            bar.spread = variance.squareRoot()
            return bar
        }
    }
}
