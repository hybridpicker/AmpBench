import Foundation

/// What a REACTOR reports about itself, read only from the messages it sends when its controls are used.
///
/// Checked listen-only on 2026-11-09 (docs/STUDIO.md, "REACTOR"). The REACTOR never sends the content of a preset by
/// itself, and Spark Studio may not ask for it, so after a slot change everything but the slot is unknown again until
/// a control is moved. Messages whose meaning is not known (such as `03 1A`) are counted, never interpreted.
public struct ReactorState: Equatable, Sendable {
    /// The six amps of the amp selector, in the order of the manual.
    public static let ampNames = ["Clean", "Warm", "Grit", "Crunch", "Hi-Gain", "Extreme"]
    /// The three positions of the Push/Smooth switch: up, middle, down.
    public static let voiceNames = ["Push", "Standard", "Smooth"]
    /// Chain places reported with `03 B3`, in Spark order. 3 is the amp, which has no FX key.
    public static let placeNames = ["Gate", "Comp", "Drive", "Amp", "Mod", "Delay", "Reverb"]

    public enum Knob: String, CaseIterable, Sendable {
        case gain, bass, middle, treble, master

        public var title: String {
            switch self {
            case .gain: "Gain"
            case .bass: "Bass"
            case .middle: "Middle"
            case .treble: "Treble"
            case .master: "Master"
            }
        }

        /// Where the REACTOR reports the knob: a block of its amp and the parameter's index.
        public var source: (block: String, index: UInt8) {
            switch self {
            case .gain: ("Amp.Preamp", 0)
            case .bass: ("Amp.Tonestack", 1)
            case .middle: ("Amp.Tonestack", 2)
            case .treble: ("Amp.Tonestack", 3)
            case .master: ("Amp.Poweramp", 0)
            }
        }

        static func of(block: String, index: UInt8) -> Knob? {
            allCases.first { $0.source.block == block && $0.source.index == index }
        }
    }

    /// One effect as reported: its model, on or off, and the parameters seen.
    public struct Effect: Equatable, Sendable {
        public var model: String
        public var isOn: Bool?
        /// The chain place, 0 to 6, once known from `03 B3` right after it was switched on.
        public var place: Int?
        public var parameters: [UInt8: Float] = [:]

        /// Parameter 0, which the FX Level knob turns.
        public var level: Float? { parameters[0] }
    }

    /// 0 to 7: Rot 1–4, then Grün 1–4.
    public var slot: Int?
    /// 0 to 5, see `ampNames`.
    public var amp: Int?
    /// 0 Push, 1 Standard, 2 Smooth.
    public var voice: Int?
    /// 0 to 4, 2 in the middle.
    public var heat: Int?
    public var knobs: [Knob: Float] = [:]
    /// Effects by model name, as they were reported since the last slot change.
    public var effects: [String: Effect] = [:]
    /// The chain place picked with an FX key, 0 to 6.
    public var selectedPlace: Int?
    /// The model whose parameter 0 the FX Level knob last turned.
    public var levelModel: String?
    public var tempo: Float?
    public var tunerOn = false
    /// The tuner's raw reading. Nil without a signal (the REACTOR sends −1). Its scale is not known.
    public var tunerReading: Float?
    /// Messages of unknown meaning, by "command sub", such as "03 1A". Counted, never read.
    public var unknown: [String: Int] = [:]

    public init() {}

    public var bank: Int? { slot.map { $0 / 4 } }

    public var ampName: String? { amp.flatMap { Self.ampNames.indices.contains($0) ? Self.ampNames[$0] : nil } }
    public var voiceName: String? { voice.flatMap { Self.voiceNames.indices.contains($0) ? Self.voiceNames[$0] : nil } }

    public var selectedEffect: Effect? {
        guard let selectedPlace else { return nil }
        return effects.values.first { $0.place == selectedPlace }
    }

    /// Effects in chain order, those of an unknown place last, by name.
    public var orderedEffects: [Effect] {
        effects.values.sorted { ($0.place ?? 99, $0.model) < ($1.place ?? 99, $1.model) }
    }

    /// True when anything but the slot was reported since the last slot change.
    public var hasReadings: Bool {
        amp != nil || voice != nil || heat != nil || !knobs.isEmpty || !effects.isEmpty || tempo != nil
    }

    /// Takes one message into the state. Returns true when it was understood.
    @discardableResult
    public mutating func apply(_ message: SparkProtocol.Message) -> Bool {
        guard message.command == SparkProtocol.Command.response else {
            count(message)
            return false
        }
        var reader = SparkReader(message.payload)
        let payload = message.payload
        switch message.sub {
        case SparkProtocol.Sub.hardwarePreset:
            guard let slot = SparkValues.slot(payload), slot < 8 else { break }
            switchSlot(to: Int(slot))
            return true
        case Self.ampSelector:
            guard payload.count >= 2, payload[0] < 6, payload[1] < 15 else { break }
            amp = Int(payload[0])
            voice = Int(payload[1]) / 5
            heat = Int(payload[1]) % 5
            return true
        case Self.selectedEffect:
            guard let place = payload.first, place < 7 else { break }
            selectedPlace = Int(place)
            // An effect just switched on reports its place this way, so it is learnt here.
            if let model = lastSwitchedOn, effects[model]?.place == nil { effects[model]?.place = Int(place) }
            lastSwitchedOn = nil
            return true
        case SparkProtocol.Sub.parameterChanged:
            guard let block = try? reader.prefixedString(), let index = try? reader.byte(),
                  let value = try? reader.float(), value.isFinite else { break }
            if let knob = Knob.of(block: block, index: index) {
                knobs[knob] = value
            } else if !block.hasPrefix("Amp.") {
                effects[block, default: Effect(model: block)].parameters[index] = value
                if index == 0 { levelModel = block }
            } else {
                break
            }
            return true
        case SparkProtocol.Sub.effectOnOff:
            guard let model = try? reader.prefixedString(), let isOn = try? reader.bool() else { break }
            effects[model, default: Effect(model: model)].isOn = isOn
            lastSwitchedOn = isOn ? model : nil
            return true
        case SparkProtocol.Sub.tapTempo:
            guard let bpm = try? reader.float(), bpm.isFinite, bpm > 0 else { break }
            tempo = bpm
            return true
        case SparkProtocol.Sub.tuner:
            guard let on = try? reader.bool() else { break }
            tunerOn = on
            if !on { tunerReading = nil }
            return true
        case SparkProtocol.Sub.tunerPitch:
            guard (try? reader.byte()) != nil, let value = try? reader.float(), value.isFinite else { break }
            tunerReading = value < 0 ? nil : value
            return true
        default:
            break
        }
        count(message)
        return false
    }

    /// `03 B1 <amp> <5 × switch + heat>`: the amp selector, the Push/Smooth switch and Heat.
    public static let ampSelector: UInt8 = 0xB1
    /// `03 B3 <place> C3`: an FX key picked a place of the chain.
    public static let selectedEffect: UInt8 = 0xB3

    private var lastSwitchedOn: String?

    private mutating func switchSlot(to new: Int) {
        // The preset key reports the same slot twice; that is no change.
        if new != slot {
            amp = nil
            voice = nil
            heat = nil
            knobs = [:]
            effects = [:]
            selectedPlace = nil
            levelModel = nil
            lastSwitchedOn = nil
        }
        slot = new
    }

    private mutating func count(_ message: SparkProtocol.Message) {
        unknown[String(format: "%02X %02X", message.command, message.sub), default: 0] += 1
    }

    /// The readings in words, for a take's stamp and for VoiceOver: what was reported since the last slot change.
    public func lines(profile: DeviceProfile = .reactor50) -> [(label: String, value: String)] {
        var lines: [(String, String)] = []
        if let slot { lines.append(("Platz", profile.slotName(slot))) }
        if let ampName { lines.append(("Amp", ampName)) }
        if let voiceName { lines.append(("Push/Smooth", voiceName)) }
        if let heat { lines.append(("Heat", "\(heat + 1) von 5")) }
        for knob in Knob.allCases {
            if let value = knobs[knob] { lines.append((knob.title, Self.tenths(value))) }
        }
        for effect in orderedEffects {
            var parts: [String] = []
            if let isOn = effect.isOn { parts.append(isOn ? "an" : "aus") }
            if let level = effect.level { parts.append("Level \(Self.tenths(level))") }
            let place = effect.place.map { Self.placeNames[$0] } ?? "FX"
            lines.append(("\(place) \(effect.model)", parts.isEmpty ? "gesehen" : parts.joined(separator: ", ")))
        }
        if let tempo { lines.append(("Tempo", "\(Int(tempo.rounded())) BPM")) }
        return lines
    }

    /// 0…1 shown as 0 to 10 with one decimal, like the editor's knobs.
    public static func tenths(_ value: Float) -> String {
        String(format: "%.1f", Double(min(max(value, 0), 1)) * 10).replacingOccurrences(of: ".", with: ",")
    }
}
