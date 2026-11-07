import Foundation
import SparkControl

/// The probe's commands that read, switch and store presets.
@MainActor
enum Commands {
    static func info(_ link: ProbeLink) async throws {
        let header = link.header
        _ = try await link.request("firmware", answer: SparkProtocol.Sub.firmware) {
            [SparkProtocol.getFirmware(sequence: $0, header: header)]
        }
        _ = try await link.request("amp name", answer: SparkProtocol.Sub.ampName) {
            [SparkProtocol.getAmpName(sequence: $0, header: header)]
        }
        _ = try await currentSlot(link)
        _ = try await link.readPreset(nil)
        for slot in UInt8(0)...3 { _ = try await link.readPreset(slot) }
    }

    static func currentSlot(_ link: ProbeLink) async throws -> UInt8? {
        let header = link.header
        let message = try await link.request("current preset number", answer: SparkProtocol.Sub.presetNumber) {
            [SparkProtocol.getPresetNumber(sequence: $0, header: header)]
        }
        return SparkValues.slot(message.payload).flatMap { $0 < 4 ? $0 : nil }
    }

    static func preset(_ link: ProbeLink, slot: UInt8) async throws {
        try await link.switchTo(slot)
        _ = try await currentSlot(link)
    }

    static func watch(_ link: ProbeLink, seconds: Double) async {
        log("Listening for \(Int(seconds)) seconds. Press the preset button or turn a knob on the amp.")
        await link.listen(seconds)
    }

    /// Sends a renamed copy of a stored preset to play without storing it, then checks what plays.
    static func audition(_ link: ProbeLink, slot: UInt8) async throws {
        var copy = try await link.readPreset(slot).preset
        copy.name = testName(copy.name)
        let playing = try await link.playTemporarily(copy)
        log(playing.name == copy.name
            ? "  ✓ the amp plays the sent preset \"\(copy.name)\""
            : "  ✗ the amp plays \"\(playing.name)\", not the sent \"\(copy.name)\"")
    }

    /// Backs up a slot, stores a renamed copy there, reads it back, then puts the original back and checks it is
    /// byte for byte the same.
    static func storeTest(_ link: ProbeLink, slot: UInt8, backup path: String) async throws {
        let before = try await currentSlot(link)
        let original = try await link.readPreset(slot)
        try writeBackup(original.preset, to: path)
        var copy = original.preset
        copy.name = testName(copy.name)
        let stored = try await link.store(copy, in: slot)
        log(stored.preset.name == copy.name
            ? "  ✓ slot \(slot + 1) now holds \"\(copy.name)\""
            : "  ✗ slot \(slot + 1) holds \"\(stored.preset.name)\", not \"\(copy.name)\"")
        try await restore(link, original.preset, payload: original.payload, in: slot, backup: path)
        if let before, before != slot { try await link.switchTo(before) }
    }

    /// Stores a renamed copy of a slot and leaves it there, so it can be checked after switching the amp off.
    static func persistStore(_ link: ProbeLink, slot: UInt8, backup path: String) async throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw ProbeFailure("\(path) exists already. Choose a new file for the backup.")
        }
        let original = try await link.readPreset(slot)
        try writeBackup(original.preset, to: path)
        var copy = original.preset
        copy.name = testName(copy.name)
        let stored = try await link.store(copy, in: slot)
        guard stored.preset.name == copy.name else {
            log("  ✗ slot \(slot + 1) holds \"\(stored.preset.name)\", not \"\(copy.name)\"")
            try await restore(link, original.preset, payload: original.payload, in: slot, backup: path)
            return
        }
        log("  ✓ slot \(slot + 1) now holds \"\(copy.name)\".")
        log("\nNow switch the amp off, wait a few seconds, switch it on, then run:")
        log("  spark-probe persist-test check \(slot + 1) \(path)")
    }

    /// Reads the slot after the amp was switched off and on, reports, and puts the original back.
    static func persistCheck(_ link: ProbeLink, slot: UInt8, backup path: String) async throws {
        let original = try readBackup(path)
        let now = try await link.readPreset(slot)
        if now.preset.name == testName(original.name) {
            log("  ✓ the stored copy \"\(now.preset.name)\" survived switching the amp off and on")
        } else if now.preset == original {
            log("  ✗ slot \(slot + 1) holds the original again: the stored copy did not survive")
            return
        } else {
            throw ProbeFailure("Slot \(slot + 1) holds \"\(now.preset.name)\", neither the test copy nor the "
                               + "original. Nothing was changed. The backup is in \(path).")
        }
        try await restore(link, original, payload: original.encode(place: .slot(slot)), in: slot, backup: path)
    }

    private static func restore(_ link: ProbeLink, _ original: SparkPreset, payload: [UInt8], in slot: UInt8,
                                backup path: String) async throws {
        let back = try await link.store(original, in: slot)
        log(back.payload.dropFirst(2) == payload.dropFirst(2)
            ? "  ✓ slot \(slot + 1) is byte for byte the original again"
            : "  ✗ slot \(slot + 1) differs from the original. The backup is in \(path)")
    }
}
