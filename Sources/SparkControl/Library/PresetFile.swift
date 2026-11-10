import Foundation

/// A preset saved on the Mac, with where it came from and how it is filed.
///
/// Format 1 had only date, origin, backup flag and preset. Format 2 adds an id, favorite, rating, tags and notes.
/// Every field but the preset may be missing and gets its default, so files of either format read in both versions
/// of the app. A file is raised to the current format only when it is written again.
public struct PresetFile: Codable, Equatable, Sendable {
    public static let currentFormat = 2
    public static let ratingRange = 0...5

    public var format: Int
    /// Stable across renames, so songs can refer to the preset. Nil in older files until they are written again.
    public var id: String?
    public var savedAt: Date
    /// Where it came from, such as "Slot 2 · Spark MINI".
    public var origin: String
    /// True for the copy made automatically before a slot was overwritten.
    public var isBackup: Bool
    public var favorite: Bool
    /// 0 for none, up to 5.
    public var rating: Int
    public var tags: [String]
    public var notes: String
    public var preset: SparkPreset

    public init(id: String? = UUID().uuidString, savedAt: Date = Date(), origin: String, isBackup: Bool = false,
                favorite: Bool = false, rating: Int = 0, tags: [String] = [], notes: String = "",
                preset: SparkPreset) {
        format = Self.currentFormat
        self.id = id
        self.savedAt = savedAt
        self.origin = origin
        self.isBackup = isBackup
        self.favorite = favorite
        self.rating = rating
        self.tags = tags
        self.notes = notes
        self.preset = preset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        id = try c.decodeIfPresent(String.self, forKey: .id)
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date(timeIntervalSince1970: 0)
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        isBackup = try c.decodeIfPresent(Bool.self, forKey: .isBackup) ?? false
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        rating = min(max(try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0, 0), 5)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        preset = try c.decode(SparkPreset.self, forKey: .preset)
    }

    /// Tags without blanks, without a leading "#" (the UI shows it, the file does not keep it) and without repeats
    /// that differ only in case. The first spelling wins.
    public static func normalized(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map(tagText).filter { tag in
            !tag.isEmpty && seen.insert(tag.lowercased()).inserted
        }
    }

    /// One tag as it is kept: trimmed, without leading "#".
    public static func tagText(_ tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A hashtag made from a title: words joined without blanks and apostrophes, "Can't Stop" → "CantStop".
    public static func hashtag(_ title: String) -> String {
        let joined = title.filter { !"'’`´".contains($0) }
        let words = joined.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.map { word in word.prefix(1).uppercased() + word.dropFirst() }.joined()
    }
}

public struct SavedPreset: Identifiable, Equatable, Sendable {
    public var url: URL
    public var file: PresetFile
    /// Read from a sound recipe. The file is written as a preset file only when it is saved.
    public var isRecipe: Bool
    public var id: URL { url }

    public init(url: URL, file: PresetFile, isRecipe: Bool = false) {
        self.url = url
        self.file = file
        self.isRecipe = isRecipe
    }
    public var name: String { file.preset.name }
}
