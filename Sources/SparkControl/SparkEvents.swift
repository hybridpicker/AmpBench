import Foundation

/// Something the amp reports by itself, or the answer to a change. Built from a parsed `SparkProtocol.Message`.
public enum SparkEvent: Equatable, Sendable {
    /// A parameter changed on the amp, such as one of its knobs.
    case parameter(effect: String, index: UInt8, value: Float)
    case effectOnOff(effect: String, isOn: Bool)
    case modelChanged(from: String, to: String)
    /// The amp switched to a stored preset, 0 to 3, for example with its preset button.
    case presetSelected(slot: UInt8)
    /// A long press of the preset button, asking to store what plays in that slot.
    case storeRequested(slot: UInt8)
    /// The tuner's reading: the note from 0 (C) to 11 (B) and the offset, 0.5 is in tune. Nil without a signal.
    case tuner(note: UInt8, offset: Float?)
    case tunerOn(Bool)
    case tapTempo(bpm: Float)
    /// The amp confirms a change, `04 <sub>`.
    case acknowledged(sub: UInt8)

    /// Reads an event from a message, or nil for one that is no event, such as a preset.
    public init?(_ message: SparkProtocol.Message) {
        typealias Sub = SparkProtocol.Sub
        var reader = SparkReader(message.payload)
        if message.command == SparkProtocol.Command.acknowledge {
            self = .acknowledged(sub: message.sub)
            return
        }
        guard message.command == SparkProtocol.Command.response else { return nil }
        do {
            switch message.sub {
            case Sub.parameterChanged:
                let effect = try reader.prefixedString()
                let index = try reader.byte()
                self = .parameter(effect: effect, index: index, value: try reader.float())
            case Sub.effectOnOff:
                let effect = try reader.prefixedString()
                self = .effectOnOff(effect: effect, isOn: try reader.bool())
            case Sub.changeEffect:
                let old = try reader.prefixedString()
                self = .modelChanged(from: old, to: try reader.prefixedString())
            case Sub.hardwarePreset:
                guard let slot = SparkValues.slot(message.payload) else { return nil }
                self = .presetSelected(slot: slot)
            case Sub.storeRequest:
                guard let slot = SparkValues.slot(message.payload) else { return nil }
                self = .storeRequested(slot: slot)
            case Sub.tunerPitch:
                let note = try reader.byte()
                let offset = try reader.float()
                self = .tuner(note: note, offset: offset < 0 ? nil : offset)
            case Sub.tuner:
                self = .tunerOn(try reader.bool())
            case Sub.tapTempo:
                self = .tapTempo(bpm: try reader.float())
            default:
                return nil
            }
        } catch {
            return nil
        }
    }
}

public extension SparkPreset {
    /// Applies a change the amp reported, so a copy of the playing preset stays in step with it. Returns false when
    /// the preset has no such effect or parameter.
    @discardableResult
    mutating func apply(_ event: SparkEvent) -> Bool {
        switch event {
        case .parameter(let effect, let index, let value):
            guard let place = effectIndex(named: effect),
                  let parameter = effects[place].parameters.firstIndex(where: { $0.index == index }) else {
                return false
            }
            effects[place].parameters[parameter].value = value
        case .effectOnOff(let effect, let isOn):
            guard let place = effectIndex(named: effect) else { return false }
            effects[place].isOn = isOn
        case .modelChanged(let old, let new):
            guard let place = effectIndex(named: old) else { return false }
            effects[place].name = new
        default:
            return false
        }
        return true
    }
}
