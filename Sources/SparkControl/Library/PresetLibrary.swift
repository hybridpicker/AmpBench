import Foundation

/// A preset saved on the Mac, with where it came from.
public struct PresetFile: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var savedAt: Date
    /// Where it came from, such as "Platz 2 · Spark MINI".
    public var origin: String
    /// True for the copy made automatically before a slot was overwritten.
    public var isBackup: Bool
    public var preset: SparkPreset

    public init(savedAt: Date = Date(), origin: String, isBackup: Bool = false, preset: SparkPreset) {
        format = Self.currentFormat
        self.savedAt = savedAt
        self.origin = origin
        self.isBackup = isBackup
        self.preset = preset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? Self.currentFormat
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date(timeIntervalSince1970: 0)
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        isBackup = try c.decodeIfPresent(Bool.self, forKey: .isBackup) ?? false
        preset = try c.decode(SparkPreset.self, forKey: .preset)
    }
}

public struct SavedPreset: Identifiable, Equatable, Sendable {
    public var url: URL
    public var file: PresetFile
    public var id: URL { url }
    public var name: String { file.preset.name }
}

public enum PresetLibraryError: LocalizedError {
    case emptyName
    case nameTooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Der Name darf nicht leer sein."
        case .nameTooLong(let limit): "Der Name ist zu lang. Der Verstärker nimmt höchstens \(limit) Zeichen."
        }
    }
}

/// A folder of presets, one readable JSON file each. Files placed in the folder show up on the next reload. Removing
/// moves a file to the Trash, never deletes it.
public final class PresetLibrary {
    /// Names up to this length keep the short string form the amp uses for names.
    public static let nameLimit = 31

    public let folder: URL
    public private(set) var items: [SavedPreset] = []
    /// Files in the folder that could not be read, by file name.
    public private(set) var unreadable: [String] = []
    private let fileManager = FileManager.default

    public init(folder: URL) {
        self.folder = folder
    }

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("Spark Presets", isDirectory: true)
    }

    public func reload() throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
        var items: [SavedPreset] = []
        var unreadable: [String] = []
        let decoder = Self.makeDecoder()
        for url in urls {
            if let data = try? Data(contentsOf: url), let file = try? decoder.decode(PresetFile.self, from: data) {
                items.append(SavedPreset(url: url, file: file))
            } else {
                unreadable.append(url.lastPathComponent)
            }
        }
        self.items = items.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
                || ($0.name == $1.name && $0.file.savedAt < $1.file.savedAt)
        }
        self.unreadable = unreadable.sorted()
    }

    /// A saved preset with exactly these settings, if there is one.
    public func existing(_ preset: SparkPreset) -> SavedPreset? {
        items.first { $0.file.preset == preset }
    }

    @discardableResult
    public func save(_ preset: SparkPreset, origin: String, isBackup: Bool = false,
                     date: Date = Date()) throws -> SavedPreset {
        var base = Self.fileName(for: preset.name)
        if isBackup {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm"
            base += " – Sicherung \(formatter.string(from: date))"
        }
        let url = uniqueURL(base)
        let saved = SavedPreset(url: url, file: PresetFile(savedAt: date, origin: origin, isBackup: isBackup,
                                                           preset: preset))
        try write(saved)
        try reload()
        return saved
    }

    /// Renames the preset itself, the name the amp shows, and its file.
    @discardableResult
    public func rename(_ item: SavedPreset, to name: String) throws -> SavedPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PresetLibraryError.emptyName }
        guard trimmed.utf8.count <= Self.nameLimit else { throw PresetLibraryError.nameTooLong(Self.nameLimit) }
        var renamed = item
        renamed.file.preset.name = trimmed
        let wanted = Self.fileName(for: trimmed)
        if wanted != item.url.deletingPathExtension().lastPathComponent {
            renamed.url = uniqueURL(wanted)
        }
        try write(renamed)
        if renamed.url != item.url { try fileManager.removeItem(at: item.url) }
        try reload()
        return items.first { $0.url == renamed.url } ?? renamed
    }

    /// Moves the file to the Trash and returns where it went.
    @discardableResult
    public func trash(_ item: SavedPreset) throws -> URL? {
        var trashed: NSURL?
        try fileManager.trashItem(at: item.url, resultingItemURL: &trashed)
        try reload()
        return trashed as URL?
    }

    private func write(_ item: SavedPreset) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(item.file).write(to: item.url, options: .atomic)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A file name for a preset name, without characters the Finder or the file system reject.
    static func fileName(for name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) || $0.isNewline ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        let safe = cleaned.hasPrefix(".") ? "-" + cleaned.dropFirst() : cleaned
        return safe.isEmpty ? "Preset" : safe
    }

    private func uniqueURL(_ base: String) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension("json")
        var number = 2
        while fileManager.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension("json")
            number += 1
        }
        return url
    }
}
