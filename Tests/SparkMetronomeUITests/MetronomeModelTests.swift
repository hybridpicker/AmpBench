import Combine
import SparkCore
import XCTest
@testable import SparkMetronomeUI

/// The area Metronome's model with a made-up tempo source: pieces, levels, and stepping aside for a recording.
/// Nothing here opens an audio output.
@MainActor
final class MetronomeModelTests: XCTestCase {
    private final class FakeTempo: MetronomeTempo {
        var settings = MetronomeSettings(bpm: 100, beatsPerBar: 4)
        let subject = PassthroughSubject<Void, Never>()
        var pieceList: [MetronomePiece] = []
        var kept: [UUID: MetronomeSettings] = [:]
        var busy = false

        func updateSettings(_ change: (inout MetronomeSettings) -> Void) {
            change(&settings)
            subject.send()
        }
        var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
        var pieces: [MetronomePiece] { pieceList }
        var currentPieceID: UUID? { pieceList.first?.id }
        func load(piece id: UUID) {
            guard let piece = pieceList.first(where: { $0.id == id }), let bpm = piece.bpm else { return }
            settings.bpm = bpm
            if let meter = piece.meter {
                settings.beatsPerBar = meter.beatsPerBar
                settings.pattern = meter.pattern
            }
        }
        func store(inPiece id: UUID) { kept[id] = settings }
        var isBusy: Bool { busy }
        #if os(macOS)
        var outputDeviceID: UInt32? { nil }
        var outputName: String { "" }
        #endif
    }

    func testABeatLampCyclesThroughTheLevels() {
        let tempo = FakeTempo()
        let model = MetronomeModel(tempo: tempo)
        model.cycleLevel(ofBeat: 2)
        XCTAssertEqual(tempo.settings.levels, [.accent, .normal, .soft, .normal])
        model.cycleLevel(ofBeat: 2)
        model.cycleLevel(ofBeat: 2)
        XCTAssertEqual(tempo.settings.levels[2], .accent)
        XCTAssertEqual(model.settings, tempo.settings, "the model follows the source")
    }

    func testAPieceBringsItsTempoBarAndPattern() {
        let tempo = FakeTempo()
        let id = UUID()
        let meter = PieceMeter(beatsPerBar: 7, pattern: MetronomePattern(levels: [.accent, .normal, .accent],
                                                                       subdivision: .eighths))
        tempo.pieceList = [MetronomePiece(id: id, name: "Money", bpm: 123, meter: meter)]
        let model = MetronomeModel(tempo: tempo)
        XCTAssertEqual(model.chosenPieceID, id)
        model.loadChosenPiece()
        XCTAssertEqual(model.settings.bpm, 123)
        XCTAssertEqual(model.settings.beatsPerBar, 7)
        XCTAssertEqual(model.settings.pattern.subdivision, .eighths)
        model.setBPM(130)
        model.storeInChosenPiece()
        XCTAssertEqual(tempo.kept[id]?.bpm, 130)
    }

    func testItDoesNotStartWhileARecordingUsesTheTempo() {
        let tempo = FakeTempo()
        tempo.busy = true
        let model = MetronomeModel(tempo: tempo)
        model.start()
        XCTAssertFalse(model.isRunning)
        XCTAssertNotNil(model.problem)
    }

    func testBeatsAreKeptInRange() {
        let tempo = FakeTempo()
        let model = MetronomeModel(tempo: tempo)
        model.setBeats(40)
        XCTAssertEqual(tempo.settings.beatsPerBar, 16)
        model.setBeats(0)
        XCTAssertEqual(tempo.settings.beatsPerBar, 1)
    }

    func testTheIPadKeepsItsOwnTempo() {
        let suite = "local.ampbench.tests.metronome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = StandaloneMetronomeTempo(defaults: defaults)
        first.updateSettings { $0.bpm = 87.4; $0.pattern.sound = .wood }
        let again = StandaloneMetronomeTempo(defaults: defaults)
        XCTAssertEqual(again.settings.bpm, 87)
        XCTAssertEqual(again.settings.pattern.sound, .wood)
        XCTAssertTrue(again.pieces.isEmpty)
    }
}
