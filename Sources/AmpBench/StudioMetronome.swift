import Combine
import Foundation
import SparkCore
import SparkMetronomeUI
import SparkRecorderUI

/// The area Metronome's tempo on the Mac: the recorder's, the one tempo of AmpBench. The metronome, the deck's click,
/// a preset's tempo and a piece's tempo are then always the same, and a change in one shows in all.
@MainActor
final class RecorderMetronomeTempo: MetronomeTempo {
    private let recorder: RecorderHost

    init(recorder: RecorderHost) {
        self.recorder = recorder
    }

    var settings: MetronomeSettings { recorder.metronome }
    func updateSettings(_ change: (inout MetronomeSettings) -> Void) { recorder.updateMetronome(change) }
    var changes: AnyPublisher<Void, Never> { recorder.changes }

    var pieces: [MetronomePiece] {
        recorder.pieces.map { MetronomePiece(id: $0.id, name: $0.name, bpm: $0.bpm, meter: $0.meter) }
    }

    var currentPieceID: UUID? { recorder.currentPieceID }
    func load(piece id: UUID) { recorder.useTempo(ofPiece: id) }
    func store(inPiece id: UUID) { recorder.keepTempo(inPiece: id) }
    var isBusy: Bool { recorder.usesTempo }
    var outputDeviceID: UInt32? { recorder.outputID }
    var outputName: String { recorder.outputName }
}
