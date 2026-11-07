import Foundation
import SparkControl

/// Prints what the amp sent, in a readable form.
func report(_ message: SparkProtocol.Message) {
    typealias Sub = SparkProtocol.Sub
    let checksum = message.checksumOK ? "" : " (checksum mismatch)"
    let head = String(format: "  ← %02X %02X", message.command, message.sub) + checksum

    if message.command == SparkProtocol.Command.acknowledge {
        log("\(head) acknowledged\(message.payload.isEmpty ? "" : " \(message.payload.hex)")")
        return
    }
    if message.command == 0x05 {
        log("\(head) chunk received")
        return
    }
    if let event = SparkEvent(message) {
        log("\(head) \(describe(event))")
        return
    }
    switch message.sub {
    case Sub.firmware:
        log("\(head) firmware \(SparkValues.firmware(message.payload) ?? message.payload.hex)")
    case Sub.ampName:
        log("\(head) amp name \"\(SparkValues.string(message.payload) ?? message.payload.hex)\"")
    case Sub.presetNumber:
        log("\(head) preset number: \(slotText(message.payload))")
    case Sub.preset:
        do {
            let preset = try SparkPreset(payload: message.payload)
            let place = SparkValues.place(message.payload)
            let exact = preset.encode(place: .slot(0)).dropFirst(2) == message.payload.dropFirst(2)
            let sum = preset.hasChecksum ? (preset.checksumMatches ? "checksum ok" : "CHECKSUM WRONG") : "no checksum"
            log("\(head) preset \"\(preset.name)\", place \(place.hex), \(String(format: "%.0f", preset.bpm)) BPM, "
                + "\(message.payload.count) bytes, encodes back \(exact ? "exactly" : "DIFFERENTLY"), \(sum), "
                + "trailer \(preset.trailer.hex)")
            printEffects(preset)
        } catch {
            log("\(head) preset, not decoded (\(error)): \(message.payload.hex)")
        }
    default:
        log("\(head) \(message.payload.hex)")
    }
}

func describe(_ event: SparkEvent) -> String {
    switch event {
    case .parameter(let effect, let index, let value):
        String(format: "parameter %@ %d = %.3f", effect, index, value)
    case .effectOnOff(let effect, let isOn): "\(effect) switched \(isOn ? "on" : "off")"
    case .modelChanged(let old, let new): "model \(old) → \(new)"
    case .presetSelected(let slot): "amp switched preset: \(slot == 0x7F ? "7F" : "\(slot + 1)")"
    case .storeRequested(let slot): "store requested for preset \(slot + 1)"
    case .tuner(let note, let offset): "tuner note \(note), offset \(offset.map { String(format: "%.2f", $0) } ?? "none")"
    case .tunerOn(let on): "tuner \(on ? "on" : "off")"
    case .tapTempo(let bpm): String(format: "tap tempo %.1f BPM", bpm)
    case .acknowledged(let sub): String(format: "acknowledged %02X", sub)
    }
}

func printEffects(_ preset: SparkPreset) {
    for effect in preset.effects {
        let values = effect.parameters.map { String(format: "%d=%.3f", $0.index, $0.value) }
        log("      \(effect.isOn ? "on " : "off") \(effect.name)  \(values.joined(separator: " "))")
    }
}

/// The differences between two presets, one line each, empty when they are the same.
func differences(_ old: SparkPreset, _ new: SparkPreset) -> [String] {
    var lines: [String] = []
    if old.name != new.name { lines.append("name \"\(old.name)\" → \"\(new.name)\"") }
    if old.bpm != new.bpm { lines.append("bpm \(old.bpm) → \(new.bpm)") }
    if old.effects.count != new.effects.count { lines.append("\(old.effects.count) → \(new.effects.count) effects") }
    for (place, (a, b)) in zip(old.effects, new.effects).enumerated() {
        if a.name != b.name { lines.append("place \(place + 1): model \(a.name) → \(b.name)") }
        if a.isOn != b.isOn { lines.append("place \(place + 1) \(b.name): \(a.isOn ? "on" : "off") → \(b.isOn ? "on" : "off")") }
        let before = Dictionary(a.parameters.map { ($0.index, $0.value) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(b.parameters.map { ($0.index, $0.value) }, uniquingKeysWith: { first, _ in first })
        for index in Set(before.keys).union(after.keys).sorted() where before[index] != after[index] {
            let from = before[index].map { String(format: "%.3f", $0) } ?? "–"
            let to = after[index].map { String(format: "%.3f", $0) } ?? "–"
            lines.append("place \(place + 1) \(b.name) parameter \(index): \(from) → \(to)")
        }
    }
    if old.trailer != new.trailer { lines.append("trailer \(old.trailer.hex) → \(new.trailer.hex)") }
    return lines
}

func slotText(_ payload: [UInt8]) -> String {
    guard let slot = SparkValues.slot(payload) else { return payload.hex }
    return (0...3).contains(slot) ? "\(slot + 1) (\(payload.hex))" : "raw \(payload.hex)"
}
