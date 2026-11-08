import Foundation

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
    public static let nameLimit = PresetRules.nameLimit

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
            guard let data = try? Data(contentsOf: url) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            if let file = try? decoder.decode(PresetFile.self, from: data) {
                items.append(SavedPreset(url: url, file: file))
            } else if let recipe = Self.recipeFile(data, url: url) {
                items.append(SavedPreset(url: url, file: recipe, isRecipe: true))
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
        renamed.isRecipe = false
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

    /// Writes new settings into a saved preset. A changed name renames the file too.
    @discardableResult
    public func replace(_ item: SavedPreset, with preset: SparkPreset, date: Date = Date()) throws -> SavedPreset {
        let trimmed = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PresetLibraryError.emptyName }
        guard trimmed.utf8.count <= Self.nameLimit else { throw PresetLibraryError.nameTooLong(Self.nameLimit) }
        var updated = item
        updated.isRecipe = false
        updated.file.preset = preset
        updated.file.savedAt = date
        let wanted = Self.fileName(for: preset.name)
        if wanted != item.url.deletingPathExtension().lastPathComponent { updated.url = uniqueURL(wanted) }
        try write(updated)
        if updated.url != item.url { try fileManager.removeItem(at: item.url) }
        try reload()
        return items.first { $0.url == updated.url } ?? updated
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

    /// A sound recipe in the folder as a preset file. Saving it in the editor writes it as an ordinary preset file.
    /// Nil when it is no recipe or has a problem; `SparkStudio --recipe-check` says which.
    static func recipeFile(_ data: Data, url: URL) -> PresetFile? {
        guard let recipe = try? SoundRecipe.decodeIfRecipe(data),
              let conversion = try? recipe.preset(identity: data) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return PresetFile(id: nil, savedAt: date, origin: "Rezept", tags: PresetFile.normalized(recipe.tags),
                          notes: recipe.notes, preset: conversion.preset)
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
