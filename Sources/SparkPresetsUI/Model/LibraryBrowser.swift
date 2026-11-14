import AmpText
import Foundation
import SparkControl

/// One filter of the library's filter column. The column is a list with multiple selection: a click chooses one
/// filter, ⌘-click adds another, and the arrow keys walk through them.
enum LibraryFilter: Hashable {
    case scope(LibraryScope)
    case origin(SoundOrigin)
    /// An amp model id.
    case amp(String)
    case tag(String)
}

/// A row of the library's table. A sound stands in every tag group it belongs to, so a row is the sound in its group.
struct LibraryRow: Identifiable, Hashable {
    let id: String
    let item: SavedPreset

    init(group: String, item: SavedPreset) {
        id = group + "\n" + item.url.path
        self.item = item
    }

    static func == (lhs: LibraryRow, rhs: LibraryRow) -> Bool { lhs.id == rhs.id && lhs.item == rhs.item }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var url: URL { item.url }
    var name: String { item.name }
    var amp: String { item.file.preset.ampModel.map { ModelCatalog.known($0)?.name ?? $0 } ?? "" }
    var tags: String {
        item.file.tags.filter { $0.caseInsensitiveCompare(PresetFile.listenTag) != .orderedSame }
            .map { "#\($0)" }.joined(separator: " ")
    }
    var origin: String { item.file.origin }
    var savedAt: Date { item.file.savedAt }
}

/// What the library overlay shows and has selected. The sounds themselves stay in `PresetsModel`.
@MainActor
final class LibraryBrowser: ObservableObject {
    enum Focus: Hashable { case search, filters, table, tags }

    @Published var isOpen = false
    @Published var search = ""
    @Published var filters: Set<LibraryFilter> = []
    /// Remembered on this device; a test library (`--library`) neither reads nor changes what the app remembers.
    @Published var grouping: LibraryGrouping = LibraryBrowser.remembers ? LibraryGrouping(
        rawValue: UserDefaults.standard.string(forKey: "Library Grouping") ?? "") ?? .none : .none {
        didSet { if Self.remembers { UserDefaults.standard.set(grouping.rawValue, forKey: "Library Grouping") } }
    }
    private static var remembers: Bool { Snapshot.arguments["library"] == nil }
    @Published var sortOrder = [KeyPathComparator(\LibraryRow.name, comparator: .localizedStandard)]
    /// Rows of the table, by `LibraryRow.id`.
    @Published var selection: Set<String> = []
    /// Where the keyboard is to go next; the overlay moves its focus there.
    @Published var focusRequest: Focus?
    /// The sounds to rename together, with what to find and what to put instead.
    @Published var renameItems: [SavedPreset]?
    @Published var renameFind = ""
    @Published var renameReplace = ""
    /// Sounds waiting for "Move to Trash" to be confirmed, because pieces use them.
    @Published var trashRequest: [SavedPreset]?

    /// Sounds that have a close one, worked out once per reload of the library.
    private(set) var closeGroups: [[SavedPreset]] = []
    private(set) var closeURLs: Set<URL> = []

    /// The query the filters and the search make.
    var query: LibraryQuery {
        var query = LibraryQuery(search: search)
        query.scope = LibraryScope.allCases.first { filters.contains(.scope($0)) } ?? .all
        for filter in filters {
            switch filter {
            case .scope: break
            case .origin(let origin): query.origins.insert(origin)
            case .amp(let amp): query.amps.insert(amp)
            case .tag(let tag): query.tags.append(tag)
            }
        }
        query.tags.sort()
        return query
    }

    func libraryChanged(_ items: [SavedPreset]) {
        closeGroups = PresetSimilarity.groups(items)
        closeURLs = Set(closeGroups.flatMap { $0.map(\.url) })
        // Selected rows of sounds that are gone, or renamed, leave the selection.
        let paths = Set(items.map(\.url.path))
        selection = selection.filter { paths.contains(String($0.split(separator: "\n", maxSplits: 1).last ?? "")) }
    }

    /// The groups with their rows, sorted as the table's header says.
    func rows(_ items: [SavedPreset]) -> [(group: LibraryGroup, rows: [LibraryRow])] {
        let shown = query.apply(to: items, close: closeURLs)
        if query.scope == .close {
            // Close sounds are shown in their groups, whatever the grouping, or they could not be told apart.
            let wanted = Set(shown.map(\.url))
            return closeGroups.enumerated().compactMap { index, group in
                let members = group.filter { wanted.contains($0.url) }
                guard members.count > 1 else { return nil }
                let title = tr("Close to “%@”", members[0].name)
                let libraryGroup = LibraryGroup(id: "close:\(index)", title: title, items: members)
                return (libraryGroup, members.map { LibraryRow(group: libraryGroup.id, item: $0) }.sorted(using: sortOrder))
            }
        }
        return grouping.groups(shown, leaving: query.tags).map { group in
            (group, group.items.map { LibraryRow(group: group.id, item: $0) }.sorted(using: sortOrder))
        }
    }

    /// The selected sounds, each once.
    func selectedItems(_ items: [SavedPreset]) -> [SavedPreset] {
        let paths = Set(selection.compactMap { $0.split(separator: "\n", maxSplits: 1).last.map(String.init) })
        return items.filter { paths.contains($0.url.path) }
    }

    // MARK: Recently used

    private static let recentKey = "Recent Presets"
    static let recentLimit = 5

    /// The ids (or file names, for files without one) of the sounds opened last, newest first, per presets folder.
    private(set) var recent: [String] = []
    private var recentFolder = ""

    func loadRecent(folder: URL) {
        recentFolder = folder.standardizedFileURL.path
        guard Self.remembers else { return }
        let all = UserDefaults.standard.dictionary(forKey: Self.recentKey) as? [String: [String]] ?? [:]
        recent = all[recentFolder] ?? []
    }

    func remember(_ item: SavedPreset) {
        let key = Self.recentKey(item)
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        recent = Array(recent.prefix(Self.recentLimit * 3))
        objectWillChange.send()
        guard Self.remembers else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.recentKey) as? [String: [String]] ?? [:]
        all[recentFolder] = recent
        UserDefaults.standard.set(all, forKey: Self.recentKey)
    }

    static func recentKey(_ item: SavedPreset) -> String { item.file.id ?? item.url.lastPathComponent }
}

extension LibraryGrouping {
    /// The grouping after this one, for ⌘G.
    var next: LibraryGrouping {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}
