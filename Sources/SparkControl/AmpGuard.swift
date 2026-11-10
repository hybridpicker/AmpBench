import AmpText
import Foundation

/// The last check before a preset goes to the amp. It lets through only what the amp has been heard to play.
///
/// On 2026-11-08 a sound that had just played fine made the amp howl painfully loud, with the guitar and music
/// volume knobs at zero,
/// once it was sent again with a 136-byte description: 540 bytes in 22 chunks, where everything that had worked so
/// far had at most 486 bytes, 20 chunks and strings under 128 bytes. Which of the two the amp could not take is not
/// known, so both stay inside what is known to work.
///
/// `prepared` makes a preset fit without touching its sound: values into 0…1, the tempo into its range, the
/// description shortened. `problems` lists what still does not fit; then nothing may be sent.
///
/// The amp's volume knobs did not help: the noise came from behind them. So no limit is raised by trying it on the
/// amp's speaker. Only power off stops such a noise.
public enum AmpGuard {
    /// The largest preset message, place bytes included, that the amp has played without trouble.
    public static let payloadLimit = 486
    /// The amp's strings are one length byte; from 128 on its top bit is set. Nothing that long has ever worked.
    public static let stringLimit = 127
    public static let uuidLimit = 36
    public static let effectCount = 7

    /// The preset with everything that can be fitted without changing the sound fitted: values within 0…1, the tempo
    /// within range, the description within `PresetRules.descriptionLimit` and short enough for `payloadLimit`.
    public static func prepared(_ preset: SparkPreset) -> SparkPreset {
        prepared(preset, for: nil)
    }

    /// The same, and on a device with `checkedText` (the NEO) the texts fitted to what it was heard playing: the name
    /// cut, the description left out, version and icon as on the device. The sound stays the same.
    public static func prepared(_ preset: SparkPreset, for profile: DeviceProfile?) -> SparkPreset {
        var source = preset
        if let text = profile?.checkedText {
            source.name = fit(source.name, bytes: text.nameBytes)
            source.description = fit(source.description, bytes: text.descriptionBytes)
            source.version = text.version
            source.icon = text.icon
        }
        return generallyPrepared(source)
    }

    static func fit(_ text: String, bytes: Int) -> String {
        var cut = text
        while cut.utf8.count > bytes { cut.removeLast() }
        return cut
    }

    private static func generallyPrepared(_ preset: SparkPreset) -> SparkPreset {
        var safe = preset
        safe.description = PresetRules.fitDescription(preset.description)
        if safe.bpm.isFinite {
            safe.bpm = min(max(safe.bpm, PresetRules.bpmRange.lowerBound), PresetRules.bpmRange.upperBound)
        }
        for effect in safe.effects.indices {
            for parameter in safe.effects[effect].parameters.indices {
                let value = safe.effects[effect].parameters[parameter].value
                if value.isFinite { safe.effects[effect].parameters[parameter].value = min(max(value, 0), 1) }
            }
        }
        while size(of: safe) > payloadLimit, !safe.description.isEmpty {
            safe.description.removeLast()
        }
        return safe
    }

    /// What keeps the prepared preset from going to the amp. Empty when it may be sent.
    public static func problems(_ preset: SparkPreset, for profile: DeviceProfile? = nil) -> [String] {
        let safe = prepared(preset, for: profile)
        var problems: [String] = []
        if safe.effects.count != effectCount {
            problems.append(tr("The preset has %d effects instead of %d.", safe.effects.count, effectCount))
        }
        if !safe.bpm.isFinite { problems.append(tr("The tempo is not a number.")) }
        for effect in safe.effects where effect.parameters.contains(where: { !$0.value.isFinite }) {
            problems.append(tr("“%@” has a value that is not a number.", effect.name))
        }
        let strings = [(tr("The name"), safe.name, PresetRules.nameLimit),
                       (tr("The version"), safe.version, PresetRules.nameLimit),
                       (tr("The icon"), safe.icon, PresetRules.nameLimit), (tr("The identifier"), safe.uuid, uuidLimit)]
            + safe.effects.map { (tr("The effect name “%@”", String($0.name.prefix(20))), $0.name, PresetRules.nameLimit) }
        for (label, text, limit) in strings where text.utf8.count > min(limit, stringLimit) {
            problems.append(tr("%@ is too long with %d bytes (at most %d).", label, text.utf8.count, min(limit, stringLimit)))
        }
        let bytes = size(of: safe)
        if bytes > payloadLimit {
            problems.append(tr("The preset has %d bytes, more than the %d the amp safely takes.", bytes, payloadLimit))
        }
        return problems
    }

    /// The preset message's size in bytes, place bytes included.
    public static func size(of preset: SparkPreset) -> Int {
        preset.encode(place: .temporary).count
    }

    /// A live parameter value as it may go to the amp: within 0…1, nil when it is no number.
    public static func value(_ value: Float) -> Float? {
        value.isFinite ? min(max(value, 0), 1) : nil
    }
}
