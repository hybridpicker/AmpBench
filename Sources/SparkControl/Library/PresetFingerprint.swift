import CryptoKit
import Foundation

extension SparkPreset {
    /// The preset as compact JSON with sorted keys. The same preset always gives the same bytes.
    public func canonicalJSON() throws -> Data {
        try Self.canonicalEncoder.encode(self)
    }

    /// SHA-256 of the effect chain in lowercase hex: a fingerprint of the sound, stored with each take.
    ///
    /// It covers what is heard: every model, on or off, and every parameter value with its marker. It leaves out
    /// name, description, BPM, uuid and the trailer, so the same sound read from a slot, from the temporary place or
    /// from a file on the Mac gives the same value. The amp sends a slot with a longer trailer than the playing preset.
    public func sha256Hex() throws -> String {
        SHA256.hash(data: try Self.canonicalEncoder.encode(effects)).map { String(format: "%02x", $0) }.joined()
    }

    private static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension PresetFile {
    /// The snapshot of a take's sound, written as an ordinary preset file, so the editor and the library read it
    /// like any other. The fingerprint covers only the effect chain, not the date in this file.
    public static func snapshotData(for preset: SparkPreset, origin: String, date: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(PresetFile(savedAt: date, origin: origin, preset: preset))
    }

    /// Reads a snapshot written by `snapshotData(for:origin:date:)`, or any preset file.
    public static func read(_ data: Data) throws -> PresetFile {
        try PresetLibrary.makeDecoder().decode(PresetFile.self, from: data)
    }
}
