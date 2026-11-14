import AmpText
import Foundation

/// Where a saved sound came from, worked out from what its file says. The file keeps the origin as a sentence in the
/// language of the day it was saved, so both languages are recognized here.
public enum SoundOrigin: String, CaseIterable, Sendable {
    case kemper
    case recipe
    case amp
    case template
    case made
    case backup

    public var title: String {
        switch self {
        case .kemper: tr("Kemper import")
        case .recipe: tr("Recipe or AI Sound")
        case .amp: tr("From the amp")
        case .template: tr("Template")
        case .made: tr("Made here")
        case .backup: tr("Slot backup")
        }
    }

    public static func of(_ item: SavedPreset) -> SoundOrigin {
        if item.file.isBackup { return .backup }
        if item.isRecipe { return .recipe }
        let origin = item.file.origin
        if origin.hasPrefix("Kemper") { return .kemper }
        if ["Recipe", "Rezept"].contains(origin) || origin.hasPrefix("AI Sound") || origin.hasPrefix("KI-Sound") {
            return .recipe
        }
        if ["Template", "Vorlage"].contains(origin) { return .template }
        // "Slot 2 · Spark MINI", "Platz 2 · Spark NEO", "Red 1 · REACTOR 50", "Played temporarily · Spark MINI".
        if origin.contains(" · "), ["Spark", "REACTOR"].contains(where: origin.contains) { return .amp }
        return .made
    }
}

/// How the library groups what it shows.
public enum LibraryGrouping: String, CaseIterable, Sendable {
    case none
    case tag
    case amp
    case origin

    public var title: String {
        switch self {
        case .none: tr("No groups")
        case .tag: tr("By tag")
        case .amp: tr("By amp")
        case .origin: tr("By origin")
        }
    }
}

/// Which part of the library to look at, before search and filters narrow it.
public enum LibraryScope: String, CaseIterable, Sendable {
    /// Every sound, slot backups left out.
    case all
    case favorites
    /// Sounds marked as wanting a listen, such as fresh Kemper imports.
    case toListen
    /// Sounds that have a close or equal sound elsewhere in the library.
    case close
    case backups

    public var title: String {
        switch self {
        case .all: tr("All sounds")
        case .favorites: tr("Favorites")
        case .toListen: tr("To listen")
        case .close: tr("Close sounds")
        case .backups: tr("Slot backups")
        }
    }
}

/// What the library shows: a scope, a search and filters. A sound must match the search, carry every chosen tag,
/// and have one of the chosen amps and one of the chosen origins when any are chosen.
public struct LibraryQuery: Equatable, Sendable {
    public var scope: LibraryScope = .all
    public var search = ""
    public var tags: [String] = []
    /// Amp model ids.
    public var amps: Set<String> = []
    public var origins: Set<SoundOrigin> = []

    public init(scope: LibraryScope = .all, search: String = "", tags: [String] = [], amps: Set<String> = [],
                origins: Set<SoundOrigin> = []) {
        self.scope = scope
        self.search = search
        self.tags = tags
        self.amps = amps
        self.origins = origins
    }

    /// True when anything narrows the scope.
    public var isFiltering: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || !tags.isEmpty || !amps.isEmpty || !origins.isEmpty
    }

    /// The items to show, in the order given. `close` holds the urls of sounds with a close one, for that scope.
    public func apply(to items: [SavedPreset], close: Set<URL> = []) -> [SavedPreset] {
        let wanted = tags.map { $0.lowercased() }
        let query = search.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            switch scope {
            case .all: if item.file.isBackup { return false }
            case .favorites: if item.file.isBackup || !item.file.favorite { return false }
            case .toListen: if item.file.isBackup || !item.file.needsListen { return false }
            case .close: if !close.contains(item.url) { return false }
            case .backups: if !item.file.isBackup { return false }
            }
            let own = Set(item.file.tags.map { $0.lowercased() })
            guard wanted.allSatisfy(own.contains) else { return false }
            if !amps.isEmpty, !amps.contains(item.file.preset.ampModel ?? "") { return false }
            if !origins.isEmpty, !origins.contains(SoundOrigin.of(item)) { return false }
            return Self.matches(item, search: query)
        }
    }

    /// The search looks at names, origin, models, tags and notes; "#clean" looks at tags only.
    public static func matches(_ item: SavedPreset, search query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if query.hasPrefix("#") {
            let tag = PresetFile.tagText(query).lowercased()
            return tag.isEmpty || item.file.tags.contains { $0.lowercased().hasPrefix(tag) }
        }
        // Every word must be found somewhere, so "clean twin" finds a clean sound on the Twin.
        return query.split(separator: " ").allSatisfy { word in
            let word = String(word)
            return item.name.localizedCaseInsensitiveContains(word)
                || item.file.origin.localizedCaseInsensitiveContains(word)
                || item.file.notes.localizedCaseInsensitiveContains(word)
                || item.file.tags.contains { $0.localizedCaseInsensitiveContains(word) }
                || item.file.preset.effects.contains {
                    $0.name.localizedCaseInsensitiveContains(word)
                        || (ModelCatalog.known($0.name)?.name.localizedCaseInsensitiveContains(word) ?? false)
                }
        }
    }
}

/// A group of the library's list: its title and its sounds. A sound may stand in several groups when grouped by tag.
public struct LibraryGroup: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var items: [SavedPreset]

    public init(id: String, title: String, items: [SavedPreset]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

extension LibraryGrouping {
    /// The items in groups. Groups are ordered by size for tags, by name otherwise; the items keep their order.
    /// `leaving` names tags that get no group, such as those filtered by, which every item carries.
    public func groups(_ items: [SavedPreset], leaving: [String] = []) -> [LibraryGroup] {
        let left = Set((leaving + [PresetFile.listenTag]).map { $0.lowercased() })
        switch self {
        case .none:
            return [LibraryGroup(id: "all", title: "", items: items)]
        case .tag:
            var order: [String] = []
            var byTag: [String: (title: String, items: [SavedPreset])] = [:]
            var untagged: [SavedPreset] = []
            for item in items {
                let tags = item.file.tags.filter { !left.contains($0.lowercased()) }
                if tags.isEmpty { untagged.append(item) }
                for tag in tags {
                    let key = tag.lowercased()
                    if byTag[key] == nil { order.append(key); byTag[key] = ("#\(tag)", []) }
                    byTag[key]?.items.append(item)
                }
            }
            let sorted = order.sorted { a, b in
                let (ca, cb) = (byTag[a]?.items.count ?? 0, byTag[b]?.items.count ?? 0)
                return ca != cb ? ca > cb : a.localizedStandardCompare(b) == .orderedAscending
            }
            var groups = sorted.compactMap { key in byTag[key].map { LibraryGroup(id: "tag:\(key)", title: $0.title, items: $0.items) } }
            if !untagged.isEmpty { groups.append(LibraryGroup(id: "tag:", title: tr("Without tags"), items: untagged)) }
            return groups
        case .amp:
            let keyed = Dictionary(grouping: items) { $0.file.preset.ampModel ?? "" }
            return keyed.map { id, items in
                LibraryGroup(id: "amp:\(id)", title: id.isEmpty ? tr("No amp") : (ModelCatalog.known(id)?.name ?? id),
                             items: items)
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .origin:
            let keyed = Dictionary(grouping: items) { SoundOrigin.of($0) }
            return SoundOrigin.allCases.compactMap { origin in
                keyed[origin].map { LibraryGroup(id: "origin:\(origin.rawValue)", title: origin.title, items: $0) }
            }
        }
    }
}

extension SparkPreset {
    /// The model id of the amp in the chain, if the chain has one.
    public var ampModel: String? {
        effects.enumerated().first { ChainPlace.of(index: $0.offset, count: effects.count) == .amp }?.element.name
    }
}

extension PresetFile {
    /// The tag that marks a sound as wanting a listen, such as an imported Kemper sound, which is an approximation.
    /// A tag rather than a field of its own, so older versions, the Linux app and the sound store keep it as it is.
    public static let listenTag = "listen"

    public var needsListen: Bool {
        get { tags.contains { $0.caseInsensitiveCompare(Self.listenTag) == .orderedSame } }
        set {
            tags.removeAll { $0.caseInsensitiveCompare(Self.listenTag) == .orderedSame }
            if newValue { tags.append(Self.listenTag) }
        }
    }
}
