import Foundation

/// The one tempo of AmpBench and how the metronome plays it. The recorder's click uses tempo, bar, volume and
/// count-in; the area Metronome adds the pattern (accents, subdivision, sound) and the tempo trainer.
public struct MetronomeSettings: Codable, Equatable, Sendable {
    public var bpm: Double
    public var beatsPerBar: Int
    public var volume: Float
    public var countInBars: Int
    /// The click sounds while playing or recording, and never in between.
    public var clickEnabled: Bool
    public var pattern: MetronomePattern
    public var trainer: TempoTrainer

    public static let bpmRange: ClosedRange<Double> = 20...400
    public static let beatsRange: ClosedRange<Int> = 1...16

    public init(bpm: Double = 90, beatsPerBar: Int = 4, volume: Float = 0.6, countInBars: Int = 0,
                clickEnabled: Bool = false, pattern: MetronomePattern = MetronomePattern(),
                trainer: TempoTrainer = TempoTrainer()) {
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.volume = volume
        self.countInBars = countInBars
        self.clickEnabled = clickEnabled
        self.pattern = pattern
        self.trainer = trainer
    }

    private enum CodingKeys: String, CodingKey {
        case bpm, beatsPerBar, volume, countInBars, clickEnabled, pattern, trainer
    }

    private enum LegacyKeys: String, CodingKey {
        case clickWhileRecording
    }

    /// Someone who chose the click during recordings in an earlier version finds it switched on. Settings from before
    /// the area Metronome get its default pattern and no trainer.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) ?? 90
        beatsPerBar = try c.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? 4
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0.6
        countInBars = try c.decodeIfPresent(Int.self, forKey: .countInBars) ?? 0
        clickEnabled = try c.decodeIfPresent(Bool.self, forKey: .clickEnabled)
            ?? legacy.decodeIfPresent(Bool.self, forKey: .clickWhileRecording)
            ?? false
        pattern = (try? c.decodeIfPresent(MetronomePattern.self, forKey: .pattern)) ?? MetronomePattern()
        trainer = (try? c.decodeIfPresent(TempoTrainer.self, forKey: .trainer)) ?? TempoTrainer()
    }

    public var countInBeats: Int { countInBars * beatsPerBar }
    public var countInSeconds: Double { Double(countInBeats) * 60 / bpm }

    /// The level of each beat of the bar, as many as `beatsPerBar`.
    public var levels: [MetronomePattern.Level] { pattern.levels(for: beatsPerBar) }
}

/// Which beats sound how, what lies between them, and with which sound.
public struct MetronomePattern: Codable, Equatable, Sendable {
    public enum Level: Int, Codable, CaseIterable, Sendable {
        case mute, soft, normal, accent

        /// Click on a beat lamp: accent → normal → soft → mute → accent.
        public var next: Level {
            switch self {
            case .accent: .normal
            case .normal: .soft
            case .soft: .mute
            case .mute: .accent
            }
        }
    }

    /// Pulses per beat.
    public enum Subdivision: Int, Codable, CaseIterable, Sendable {
        case quarters = 1, eighths = 2, triplets = 3, sixteenths = 4
    }

    public enum Sound: Int, Codable, CaseIterable, Sendable {
        case classic, wood, beep
    }

    /// Per beat from the first. Beats beyond the list are normal, the first is an accent when the list is empty.
    public var levels: [Level]
    public var subdivision: Subdivision
    /// The subdivisions' loudness against a normal beat, 0 to 1.
    public var subdivisionLevel: Float
    public var sound: Sound

    public init(levels: [Level] = [], subdivision: Subdivision = .quarters, subdivisionLevel: Float = 0.6,
                sound: Sound = .classic) {
        self.levels = levels
        self.subdivision = subdivision
        self.subdivisionLevel = subdivisionLevel
        self.sound = sound
    }

    public func levels(for beats: Int) -> [Level] {
        (0..<max(beats, 1)).map { index in
            index < levels.count ? levels[index] : (index == 0 ? .accent : .normal)
        }
    }

    /// The pattern with one beat's level changed, the others kept as they sound now.
    public func setting(_ level: Level, at beat: Int, beats: Int) -> MetronomePattern {
        var copy = self
        var all = levels(for: max(beats, beat + 1))
        all[beat] = level
        copy.levels = all
        return copy
    }
}

/// Raises (or lowers) the tempo by a step after a number of bars, until a target. Off by default.
public struct TempoTrainer: Codable, Equatable, Sendable {
    public var isOn: Bool
    public var stepBPM: Double
    public var everyBars: Int
    public var targetBPM: Double

    public init(isOn: Bool = false, stepBPM: Double = 2, everyBars: Int = 4, targetBPM: Double = 140) {
        self.isOn = isOn
        self.stepBPM = stepBPM
        self.everyBars = everyBars
        self.targetBPM = targetBPM
    }

    /// The tempo after `bars` whole bars from `start`: what the audio thread does, for the window and for tests.
    public func tempo(afterBars bars: Int, from start: Double) -> Double {
        guard isOn, stepBPM != 0, everyBars > 0 else { return start }
        let steps = Double(bars / everyBars)
        let raw = start + steps * (targetBPM >= start ? abs(stepBPM) : -abs(stepBPM))
        return targetBPM >= start ? min(raw, targetBPM) : max(raw, targetBPM)
    }
}
