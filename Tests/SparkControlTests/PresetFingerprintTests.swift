import XCTest
@testable import SparkControl

/// The fingerprint and snapshot that a take keeps of its sound. Made-up presets only.
final class PresetFingerprintTests: XCTestCase {
    private func preset() throws -> SparkPreset {
        var preset = try SparkPreset(payload: Synthetic.presetPayload())
        preset.name = "Crunch"
        return preset
    }

    func testSameSettingsGiveTheSameFingerprint() throws {
        let first = try preset()
        let copy = try SparkPreset(payload: first.encode(place: .slot(1)))
        let hash = try first.sha256Hex()
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(try copy.sha256Hex(), hash)
        XCTAssertEqual(try first.sha256Hex(), hash, "Encoding twice gives the same bytes.")
        XCTAssertEqual(try first.canonicalJSON(), try first.canonicalJSON())
    }

    /// Renaming or a different trailer from another place on the amp is still the same sound.
    func testNameAndTrailerDoNotChangeTheFingerprint() throws {
        let original = try preset()
        var other = original
        other.name = "Crunch 2"
        other.description = "anders"
        other.bpm = 90
        other.trailer = SparkPreset.standardTrailer
        other.uuid = UUID().uuidString
        XCTAssertEqual(try other.sha256Hex(), try original.sha256Hex())
        other.effects[0].isOn.toggle()
        XCTAssertNotEqual(try other.sha256Hex(), try original.sha256Hex())
    }

    func testOneChangedKnobChangesTheFingerprint() throws {
        let original = try preset()
        var changed = original
        let place = try XCTUnwrap(changed.effects.indices.first { !changed.effects[$0].parameters.isEmpty })
        changed.effects[place].parameters[0].value = changed.effects[place].parameters[0].value == 0.5 ? 0.25 : 0.5
        XCTAssertNotEqual(try changed.sha256Hex(), try original.sha256Hex())
    }

    func testSnapshotIsAPresetFileWithTheSameSound() throws {
        let original = try preset()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try PresetFile.snapshotData(for: original, origin: "Platz 2 · Test", date: date)
        let file = try PresetFile.read(data)
        XCTAssertEqual(file.preset, original)
        XCTAssertEqual(file.origin, "Platz 2 · Test")
        XCTAssertEqual(file.savedAt, date)
        XCTAssertFalse(file.isBackup)
        XCTAssertEqual(try file.preset.sha256Hex(), try original.sha256Hex())
    }
}
