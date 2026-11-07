import Foundation
import SparkControl

/// The building blocks of the probe's commands.
extension ProbeLink {
    /// `slot` 0 to 3 reads a stored preset, nil the one playing now.
    func readPreset(_ slot: UInt8?, label: String? = nil) async throws -> (preset: SparkPreset, payload: [UInt8]) {
        let header = header
        let text = label ?? (slot.map { "read stored preset \($0 + 1)" } ?? "read the preset playing now")
        let message = try await request(text, answer: SparkProtocol.Sub.preset,
                                        command: SparkProtocol.Command.response) {
            [SparkProtocol.getPreset(slot: slot, sequence: $0, header: header)]
        }
        do {
            return (try SparkPreset(payload: message.payload), message.payload)
        } catch {
            throw ProbeFailure("The amp sent a preset that could not be read: \(error)")
        }
    }

    func sendPreset(_ preset: SparkPreset, to place: SparkPresetPlace, label: String) async throws {
        let header = header
        _ = try await request(label, answer: SparkProtocol.Sub.preset, command: SparkProtocol.Command.acknowledge) {
            SparkProtocol.sendPreset(preset, to: place, sequence: $0, header: header)
        }
    }

    /// Switches to stored preset `slot`, or to the temporary one with 0x7F.
    func switchTo(_ slot: UInt8) async throws {
        let header = header
        let name = slot == 0x7F ? "the temporary preset" : "preset \(slot + 1)"
        _ = try await request("switch to \(name)", answer: SparkProtocol.Sub.hardwarePreset) {
            [SparkProtocol.changeHardwarePreset(slot: slot, sequence: $0, header: header)]
        }
    }

    /// Plays a preset on the temporary place without storing it, and returns what the amp then plays.
    func playTemporarily(_ preset: SparkPreset) async throws -> SparkPreset {
        try await sendPreset(preset, to: .temporary, label: "send \"\(preset.name)\" to play without storing")
        try await switchTo(0x7F)
        return try await readPreset(nil).preset
    }

    /// Stores a preset in a slot and switches to it, then reads it back.
    func store(_ preset: SparkPreset, in slot: UInt8) async throws -> (preset: SparkPreset, payload: [UInt8]) {
        try await sendPreset(preset, to: .slot(slot), label: "store \"\(preset.name)\" in slot \(slot + 1)")
        try await switchTo(slot)
        return try await readPreset(slot)
    }
}

/// Writes a preset as JSON, never over an existing file.
func writeBackup(_ preset: SparkPreset, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(preset).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    log("  backup written to \(path)")
}

/// Reads a preset written by `writeBackup`, or a preset file saved by Spark Presets.
func readBackup(_ path: String) throws -> SparkPreset {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    if let preset = try? JSONDecoder().decode(SparkPreset.self, from: data) { return preset }
    struct Saved: Decodable { var preset: SparkPreset }
    return try JSONDecoder().decode(Saved.self, from: data).preset
}

func testName(_ name: String) -> String {
    String((name + " Test").prefix(31))
}
