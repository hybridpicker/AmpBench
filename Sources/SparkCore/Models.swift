import Foundation

public struct Marker: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var time: Double
    public var label: String

    public init(id: UUID = UUID(), time: Double, label: String) {
        self.id = id
        self.time = time
        self.label = label
    }
}

public enum TakeStatus: String, Codable, Sendable {
    /// Recorded but not decided on yet.
    case open
    case kept
}

public enum FileHealth: String, Codable, Sendable {
    case ok
    case missing
    case damaged
}

/// What the input delivered, separate from the file format. Unknown for files recorded before this was tracked.
public struct SourceFormat: Codable, Equatable, Sendable {
    public var deviceName: String
    public var bits: Int
    public var sampleRate: Double
    public var channels: Int

    public init(deviceName: String, bits: Int, sampleRate: Double, channels: Int) {
        self.deviceName = deviceName
        self.bits = bits
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Says that a take holds new versions of bars of another take. The other take stays as it is.
public struct PunchInfo: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var firstBar: Int
    public var lastBar: Int

    public init(sourceID: UUID, bars: ClosedRange<Int>) {
        self.sourceID = sourceID
        firstBar = bars.lowerBound
        lastBar = bars.upperBound
    }

    public var bars: ClosedRange<Int> { firstBar...max(firstBar, lastBar) }
}

public struct Recording: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var fileName: String
    public var createdAt: Date
    public var duration: Double
    public var sampleRate: Double
    public var channels: Int
    public var fileBits: Int
    public var fileSize: Int64
    public var inode: UInt64
    public var source: SourceFormat?
    public var status: TakeStatus
    public var rating: Int
    public var favorite: Bool
    public var tags: [String]
    public var note: String
    public var markers: [Marker]
    public var pieceID: UUID?
    public var edit: EditList
    /// Peak of the original file in dBFS, once known.
    public var peakDB: Double?
    public var health: FileHealth
    public var recoveredAfterInterruption: Bool
    /// The bars of the take, when it was recorded with the metronome.
    public var grid: BeatGrid?
    public var punch: PunchInfo?
    /// The sound the take was recorded with, when the preset editor knew it. Its settings are in a snapshot file.
    public var preset: PresetStamp?

    public init(
        id: UUID = UUID(), fileName: String, createdAt: Date, duration: Double, sampleRate: Double, channels: Int,
        fileBits: Int, fileSize: Int64 = 0, inode: UInt64 = 0, source: SourceFormat? = nil, status: TakeStatus = .open,
        rating: Int = 0, favorite: Bool = false, tags: [String] = [], note: String = "", markers: [Marker] = [],
        pieceID: UUID? = nil, edit: EditList = EditList(), peakDB: Double? = nil, health: FileHealth = .ok,
        recoveredAfterInterruption: Bool = false, grid: BeatGrid? = nil, punch: PunchInfo? = nil,
        preset: PresetStamp? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.fileBits = fileBits
        self.fileSize = fileSize
        self.inode = inode
        self.source = source
        self.status = status
        self.rating = rating
        self.favorite = favorite
        self.tags = tags
        self.note = note
        self.markers = markers
        self.pieceID = pieceID
        self.edit = edit
        self.peakDB = peakDB
        self.health = health
        self.recoveredAfterInterruption = recoveredAfterInterruption
        self.grid = grid
        self.punch = punch
        self.preset = preset
    }

    /// Missing fields get defaults, so a file written by an older or newer version still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 0
        channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? 0
        fileBits = try c.decodeIfPresent(Int.self, forKey: .fileBits) ?? 0
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        inode = try c.decodeIfPresent(UInt64.self, forKey: .inode) ?? 0
        source = try c.decodeIfPresent(SourceFormat.self, forKey: .source)
        status = try c.decodeIfPresent(TakeStatus.self, forKey: .status) ?? .kept
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        pieceID = try c.decodeIfPresent(UUID.self, forKey: .pieceID)
        edit = try c.decodeIfPresent(EditList.self, forKey: .edit) ?? EditList()
        peakDB = try c.decodeIfPresent(Double.self, forKey: .peakDB)
        health = try c.decodeIfPresent(FileHealth.self, forKey: .health) ?? .ok
        recoveredAfterInterruption = try c.decodeIfPresent(Bool.self, forKey: .recoveredAfterInterruption) ?? false
        grid = try c.decodeIfPresent(BeatGrid.self, forKey: .grid)
        punch = try c.decodeIfPresent(PunchInfo.self, forKey: .punch)
        preset = try c.decodeIfPresent(PresetStamp.self, forKey: .preset)
    }

    public var name: String { (fileName as NSString).deletingPathExtension }

    /// The last bar that can be chosen. A re-recorded passage rings out past its last bar, which adds no bar to it.
    public var lastBar: Int? {
        guard let last = grid?.lastBar(duration: duration) else { return nil }
        return punch.map { min(last, $0.lastBar) } ?? last
    }

    // Comparable forms for sortable table columns.
    public var favoriteRank: Int { favorite ? 1 : 0 }
    public var statusRank: Int { status == .open ? 0 : 1 }
}

/// A piece or exercise that groups several takes. It is also what Spark Presets calls a song.
public struct Piece: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var bestTakeID: UUID?
    /// The sound of the whole piece, when its parts do not have their own.
    public var preset: PresetLink?
    /// Intro, verse, solo and so on, in playing order, each with its own sound if it has one.
    public var parts: [PiecePart]
    /// The key as written by the player, such as "A-Moll".
    public var key: String?

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), bestTakeID: UUID? = nil,
                preset: PresetLink? = nil, parts: [PiecePart] = [], key: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.bestTakeID = bestTakeID
        self.preset = preset
        self.parts = parts
        self.key = key
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        bestTakeID = try c.decodeIfPresent(UUID.self, forKey: .bestTakeID)
        preset = try c.decodeIfPresent(PresetLink.self, forKey: .preset)
        parts = try c.decodeIfPresent([PiecePart].self, forKey: .parts) ?? []
        key = try c.decodeIfPresent(String.self, forKey: .key)
    }
}

/// Recorded time, kept separately so discarding a take does not erase the practice it represents.
public struct PracticeEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var seconds: Double
    public var pieceID: UUID?

    public init(id: UUID = UUID(), date: Date, seconds: Double, pieceID: UUID?) {
        self.id = id
        self.date = date
        self.seconds = seconds
        self.pieceID = pieceID
    }
}

/// A recording moved to the Trash. Its metadata stays here, so restoring the file also restores ratings and notes.
public struct TrashedRecording: Codable, Equatable, Sendable {
    public var recording: Recording
    public var trashPath: String
    public var trashedAt: Date

    public init(recording: Recording, trashPath: String, trashedAt: Date) {
        self.recording = recording
        self.trashPath = trashPath
        self.trashedAt = trashedAt
    }
}

public struct LibraryDocument: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var recordings: [Recording]
    public var pieces: [Piece]
    public var practiceLog: [PracticeEntry]
    public var trashed: [TrashedRecording]

    public init() {
        schemaVersion = Self.currentSchema
        recordings = []
        pieces = []
        practiceLog = []
        trashed = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        recordings = try c.decodeIfPresent([Recording].self, forKey: .recordings) ?? []
        pieces = try c.decodeIfPresent([Piece].self, forKey: .pieces) ?? []
        practiceLog = try c.decodeIfPresent([PracticeEntry].self, forKey: .practiceLog) ?? []
        trashed = try c.decodeIfPresent([TrashedRecording].self, forKey: .trashed) ?? []
    }
}
