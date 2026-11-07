import Foundation

/// The sound a take was recorded with: which preset, from where, when, and a fingerprint of its settings.
///
/// The settings themselves are not in the library. They are a snapshot file next to the recordings, see
/// `LibraryStore.presetSnapshotURL(of:)`, because SparkCore does not know the amp's preset format.
/// The fingerprint is the SHA-256 of the effect chain's canonical JSON (`SparkPreset.sha256Hex()` in SparkControl): the
/// same sound always gives the same value, whatever its name or where on the amp it was read, so takes with the same
/// sound can be found and matched to a saved preset.
public struct PresetStamp: Codable, Equatable, Sendable {
    /// The amp's slot from 1 to 4, or nil when the sound came from the Mac or the amp's temporary place.
    public var slot: Int?
    public var name: String
    public var stampedAt: Date
    /// Lowercase hex, 64 characters.
    public var sha256: String

    public init(slot: Int? = nil, name: String, stampedAt: Date = Date(), sha256: String) {
        self.slot = slot
        self.name = name
        self.stampedAt = stampedAt
        self.sha256 = sha256
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decodeIfPresent(Int.self, forKey: .slot)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        stampedAt = try c.decodeIfPresent(Date.self, forKey: .stampedAt) ?? Date(timeIntervalSince1970: 0)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
    }
}

/// Points at a preset saved on the Mac, for pieces and their parts.
///
/// It names the preset by its stable id (`PresetFile.id`) and, as a fallback for files without one, by its file name
/// inside the presets folder. Never by an absolute path, so the presets folder can move.
public struct PresetLink: Codable, Hashable, Sendable {
    public var presetID: String?
    /// Relative to the presets folder.
    public var fileName: String?
    /// Shown when the preset cannot be found any more.
    public var name: String

    public init(presetID: String? = nil, fileName: String? = nil, name: String) {
        self.presetID = presetID
        self.fileName = fileName
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

/// A section of a piece, such as intro, verse or solo.
public struct PiecePart: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var preset: PresetLink?

    public init(id: UUID = UUID(), name: String, preset: PresetLink? = nil) {
        self.id = id
        self.name = name
        self.preset = preset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        preset = try c.decodeIfPresent(PresetLink.self, forKey: .preset)
    }
}

// MARK: - Snapshot files

extension LibraryStore {
    /// Holds one preset snapshot per take. Hidden, so the folder scan never mistakes it for recordings.
    public static let presetsFolderName = ".presets"

    public var presetsFolder: URL { folder.appendingPathComponent(Self.presetsFolderName, isDirectory: true) }

    /// Named after the take's id, like the waveform cache, so renaming the take in the Finder keeps it.
    public func presetSnapshotURL(of id: UUID) -> URL {
        presetsFolder.appendingPathComponent("\(id.uuidString).json")
    }

    /// Writes the snapshot of the sound a take was recorded with. The bytes are stored as they are.
    public func writePresetSnapshot(_ data: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(at: presetsFolder, withIntermediateDirectories: true)
        try data.write(to: presetSnapshotURL(of: id), options: .atomic)
    }

    public func presetSnapshot(of id: UUID) -> Data? {
        try? Data(contentsOf: presetSnapshotURL(of: id))
    }
}
