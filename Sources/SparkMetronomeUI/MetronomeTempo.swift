import Combine
import Foundation
import SparkCore

/// A piece the metronome can take its tempo from and keep it in.
public struct MetronomePiece: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var bpm: Double?
    /// Time signature, accents and subdivision kept with the piece, if any.
    public var meter: PieceMeter?

    public init(id: UUID, name: String, bpm: Double?, meter: PieceMeter?) {
        self.id = id
        self.name = name
        self.bpm = bpm
        self.meter = meter
    }
}

/// Where the metronome's tempo lives. In AmpBench on the Mac it is the one tempo the recorder's click, the presets
/// and the pieces share; on the iPad, without a recorder, a setting of its own.
@MainActor
public protocol MetronomeTempo: AnyObject {
    var settings: MetronomeSettings { get }
    func updateSettings(_ change: (inout MetronomeSettings) -> Void)
    /// Fires after the settings, the pieces or `isBusy` changed.
    var changes: AnyPublisher<Void, Never> { get }
    var pieces: [MetronomePiece] { get }
    var currentPieceID: UUID? { get }
    /// Takes tempo, time signature and pattern from the piece.
    func load(piece id: UUID)
    /// Keeps the current tempo, time signature and pattern in the piece.
    func store(inPiece id: UUID)
    /// True while something else uses the tempo for sound, such as a recording or a take playing with its click.
    var isBusy: Bool { get }
    #if os(macOS)
    /// The output to play on, nil for the system's.
    var outputDeviceID: UInt32? { get }
    var outputName: String { get }
    #endif
}

/// The iPad's tempo: a setting of its own, no pieces.
@MainActor
public final class StandaloneMetronomeTempo: MetronomeTempo {
    private let defaults: UserDefaults
    private let subject = PassthroughSubject<Void, Never>()
    public private(set) var settings: MetronomeSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: "metronome").flatMap { try? JSONDecoder().decode(MetronomeSettings.self, from: $0) }
            ?? MetronomeSettings()
    }

    public func updateSettings(_ change: (inout MetronomeSettings) -> Void) {
        change(&settings)
        settings.bpm = min(max(settings.bpm.rounded(), MetronomeSettings.bpmRange.lowerBound),
                           MetronomeSettings.bpmRange.upperBound)
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "metronome") }
        subject.send()
    }

    public var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    public var pieces: [MetronomePiece] { [] }
    public var currentPieceID: UUID? { nil }
    public func load(piece id: UUID) {}
    public func store(inPiece id: UUID) {}
    public var isBusy: Bool { false }
    #if os(macOS)
    public var outputDeviceID: UInt32? { nil }
    public var outputName: String { "" }
    #endif
}
