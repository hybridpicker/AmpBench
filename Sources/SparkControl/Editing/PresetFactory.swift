import AmpText
import Foundation

/// New presets: empty, from a template, or as a copy.
public enum PresetFactory {
    public struct Template: Identifiable, Sendable {
        public var id: String { name }
        public var name: String
        public var summary: String
        public var preset: SparkPreset
    }

    /// An effect with the catalog's start values, its mirror parameter in step with `isOn`.
    public static func effect(_ id: String, on isOn: Bool, _ changes: [Int: Float] = [:]) -> SparkPreset.Effect {
        let info = ModelCatalog.info(for: id, parameterCount: 0)
        var values = info.defaults.isEmpty ? info.parameters.map { _ in Float(0.5) } : info.defaults
        for (index, value) in changes where values.indices.contains(index) { values[index] = value }
        for index in values.indices where info.parameter(index).kind == .mirror { values[index] = isOn ? 1 : 0 }
        return SparkPreset.Effect(name: id, isOn: isOn,
                                  parameters: values.enumerated().map { .init(index: UInt8($0.offset), value: $0.element) })
    }

    /// A clean amp, everything else switched off.
    public static func empty(name: String = tr("New preset")) -> SparkPreset {
        SparkPreset(name: name, effects: [
            effect("bias.noisegate", on: false), effect("BlueComp", on: false), effect("DistortionTS9", on: false),
            effect("Twin", on: true), effect("ChorusAnalog", on: false), effect("DelayMono", on: false),
            effect("bias.reverb", on: false),
        ])
    }

    /// The summaries are in the app's language; the names are the presets' names and stay.
    public static var templates: [Template] { [
        Template(name: "Clean", summary: tr("Clear amp, a little compression and a small room"), preset: SparkPreset(
            name: "Clean", bpm: 100, effects: [
                effect("bias.noisegate", on: false), effect("BlueComp", on: true), effect("DistortionTS9", on: false),
                effect("Twin", on: true, [0: 0.4]), effect("ChorusAnalog", on: false), effect("DelayMono", on: false),
                effect("bias.reverb", on: true, [0: 0.25, 6: 0]),
            ])),
        Template(name: "Crunch", summary: tr("British crunch, pushed by the overdrive"), preset: SparkPreset(
            name: "Crunch", bpm: 120, effects: [
                effect("bias.noisegate", on: true, [0: 0.15]), effect("Compressor", on: false),
                effect("DistortionTS9", on: true, [0: 0.35, 2: 0.6]), effect("Plexi", on: true),
                effect("ChorusAnalog", on: false), effect("DelayMono", on: false),
                effect("bias.reverb", on: true, [0: 0.2, 6: 0.2]),
            ])),
        Template(name: "Lead", summary: tr("Singing high gain with echo for solos"), preset: SparkPreset(
            name: "Lead", bpm: 120, effects: [
                effect("bias.noisegate", on: true, [0: 0.25]), effect("Compressor", on: false),
                effect("Booster", on: true, [0: 0.6]), effect("SLO100", on: true),
                effect("ChorusAnalog", on: false), effect("DelayMono", on: true, [0: 0.3, 4: 1]),
                effect("bias.reverb", on: true, [0: 0.25, 6: 0.4]),
            ])),
        Template(name: "Ambient", summary: tr("Wide clean with chorus, long echo and lots of reverb"), preset: SparkPreset(
            name: "Ambient", bpm: 80, effects: [
                effect("bias.noisegate", on: false), effect("BBEOpticalComp", on: true), effect("DistortionTS9", on: false),
                effect("94MatchDCV2", on: true, [0: 0.35]), effect("ChorusAnalog", on: true, [0: 0.5]),
                effect("DelayRe201", on: true, [0: 0.6, 4: 1]),
                effect("bias.reverb", on: true, [0: 0.55, 5: 0.85, 6: 0.5]),
            ])),
        Template(name: "Funk", summary: tr("Dry, snappy clean with lots of compression"), preset: SparkPreset(
            name: "Funk", bpm: 105, effects: [
                effect("bias.noisegate", on: true, [0: 0.1]), effect("LA2AComp", on: true),
                effect("DistortionTS9", on: false), effect("RolandJC120", on: true, [0: 0.35, 2: 0.6]),
                effect("Phaser", on: false), effect("DelayMono", on: false),
                effect("bias.reverb", on: true, [0: 0.12, 6: 0]),
            ])),
    ] }

    /// A copy with a new identity and a name that says so.
    public static func duplicate(_ preset: SparkPreset, name: String? = nil) -> SparkPreset {
        var copy = preset
        copy.uuid = UUID().uuidString
        copy.name = fit(name ?? tr("%@ copy", preset.name))
        return copy
    }

    /// A template as a new preset of its own.
    public static func make(_ template: Template, name: String? = nil) -> SparkPreset {
        duplicate(template.preset, name: name ?? template.name)
    }

    /// Cuts a name to the amp's limit at a character boundary.
    public static func fit(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > PresetRules.nameLimit { name.removeLast() }
        return name
    }
}

/// How fast changes may go to the amp. Parameters are cheap, model changes are not: a long series of them without
/// pauses once made a Spark MINI hang.
public enum LivePacing {
    /// Between two messages of any kind.
    public static let parameterGap: Duration = .milliseconds(40)
    /// Between two model changes.
    public static let modelGap: Duration = .seconds(1)
    /// At most this many model changes within `modelWindow`, then the queue waits.
    public static let modelBurst = 6
    public static let modelWindow: Duration = .seconds(20)

    /// How long to wait before sending `change`, given when the recent model changes went out.
    public static func wait(before change: LiveChange, now: ContinuousClock.Instant,
                            recentModelChanges: [ContinuousClock.Instant]) -> Duration {
        guard case .model = change else { return .zero }
        var wait = Duration.zero
        if let last = recentModelChanges.last { wait = max(wait, last + modelGap - now) }
        let window = recentModelChanges.filter { now - $0 < modelWindow }
        if window.count >= modelBurst, let oldest = window.first { wait = max(wait, oldest + modelWindow - now) }
        return max(wait, .zero)
    }
}
