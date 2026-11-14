import AmpText
import Foundation

public enum PresetLibraryError: LocalizedError {
    case emptyName
    case nameTooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyName: tr("The name must not be empty.")
        case .nameTooLong(let limit): tr("The name is too long. The amp takes at most %d characters.", limit)
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

    /// Where removed presets go on iPadOS, inside the presets folder. Hidden, so no scan lists it.
    public static let padTrashName = ".Trash"

    public static var defaultFolder: URL {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #else
        // An iPad app has no home folder to share: its sounds live in its own Documents, which the Files app shows.
        let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return home.appendingPathComponent("Music", isDirectory: true)
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
    public func save(_ preset: SparkPreset, origin: String, isBackup: Bool = false, tags: [String] = [],
                     notes: String = "", date: Date = Date(), reloads: Bool = true) throws -> SavedPreset {
        var base = Self.fileName(for: preset.name)
        if isBackup {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm"
            // A name on disk: backups made before the app spoke English are called like this, so it stays.
            base += " – Sicherung \(formatter.string(from: date))"
        }
        let url = uniqueURL(base)
        let saved = SavedPreset(url: url, file: PresetFile(savedAt: date, origin: origin, isBackup: isBackup,
                                                           tags: PresetFile.normalized(tags), notes: notes,
                                                           preset: preset))
        try write(saved)
        if reloads { try reload() }
        return saved
    }

    /// Writes a sound recipe into the folder under a free file name and returns the file. The library itself is not
    /// reloaded here; the caller reloads to list it. The file stays a recipe (the wand) until it is saved in the
    /// editor, which rewrites it as an ordinary preset.
    @discardableResult
    public func addRecipe(_ recipe: SoundRecipe) throws -> URL {
        let base = Self.fileName(for: recipe.name)
        let url = uniqueURL(base)
        try recipe.jsonData().write(to: url, options: .atomic)
        return url
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

    /// Changes what the Mac keeps about a preset (tags, notes, favorite, rating) without touching its sound. A recipe
    /// becomes an ordinary preset file this way, with an id of its own so songs can refer to it.
    @discardableResult
    public func updateDetails(_ item: SavedPreset, reloads: Bool = true,
                              _ change: (inout PresetFile) -> Void) throws -> SavedPreset {
        var updated = item
        change(&updated.file)
        updated.file.tags = PresetFile.normalized(updated.file.tags)
        if updated.file.id == nil { updated.file.id = UUID().uuidString }
        updated.isRecipe = false
        try write(updated)
        if reloads { try reload() }
        return items.first { $0.url == updated.url } ?? updated
    }

    /// Every tag in the folder with how many presets carry it, most used first, then by name.
    public var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: (spelling: String, count: Int)] = [:]
        for item in items where !item.file.isBackup {
            for tag in item.file.tags {
                let key = tag.lowercased()
                counts[key] = (counts[key]?.spelling ?? tag, (counts[key]?.count ?? 0) + 1)
            }
        }
        return counts.values.map { ($0.spelling, $0.count) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.tag.localizedStandardCompare($1.tag) == .orderedAscending
        }
    }

    /// Moves the file to the Trash and returns where it went.
    @discardableResult
    public func trash(_ item: SavedPreset) throws -> URL? {
        let place = try Self.discard(item.url, in: folder)
        try reload()
        return place
    }

    /// Takes a file of the presets folder away without deleting it, and returns where it went. The library and the
    /// sound store (for a sound removed on another device) both remove this way.
    @discardableResult
    public static func discard(_ url: URL, in folder: URL) throws -> URL? {
        let fileManager = FileManager.default
        #if os(macOS)
        var trashed: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
        #else
        // iPadOS has no Trash for an app's own files. The preset moves to a hidden folder beside the others, so
        // nothing is deleted, the library no longer lists it, and it can be brought back.
        let trash = folder.appendingPathComponent(padTrashName, isDirectory: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        var place = trash.appendingPathComponent(url.lastPathComponent)
        var count = 2
        while fileManager.fileExists(atPath: place.path) {
            let base = url.deletingPathExtension().lastPathComponent
            place = trash.appendingPathComponent("\(base) \(count).\(url.pathExtension)")
            count += 1
        }
        try fileManager.moveItem(at: url, to: place)
        return place
        #endif
    }

    private func write(_ item: SavedPreset) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(item.file).write(to: item.url, options: .atomic)
    }

    /// A sound recipe in the folder as a preset file. Saving it in the editor writes it as an ordinary preset file.
    /// Nil when it is no recipe or has a problem; `AmpBench --recipe-check` says which.
    static func recipeFile(_ data: Data, url: URL) -> PresetFile? {
        guard let recipe = try? SoundRecipe.decodeIfRecipe(data),
              let conversion = try? recipe.preset(identity: data) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return PresetFile(id: nil, savedAt: date, origin: tr("Recipe"), tags: PresetFile.normalized(recipe.tags),
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
