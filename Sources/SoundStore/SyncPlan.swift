import Foundation

/// The store's index: which sound is which object. It is the only index; nothing ever lists a directory, so a store
/// needs no more than reading and writing a file by name.
public struct StoreManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    static let historyLimit = 10

    public struct Entry: Codable, Equatable, Sendable {
        /// The object with the current content, or the last one before the sound was removed.
        public var object: String
        public var modified: Date
        public var size: Int
        /// Set when the sound was removed. Its object stays in the store, so it can be brought back.
        public var deleted: Date?
        /// Objects of earlier contents, newest first.
        public var history: [String]

        public init(object: String, modified: Date, size: Int, deleted: Date? = nil, history: [String] = []) {
            self.object = object
            self.modified = modified
            self.size = size
            self.deleted = deleted
            self.history = history
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            object = try container.decode(String.self, forKey: .object)
            modified = try container.decode(Date.self, forKey: .modified)
            size = try container.decode(Int.self, forKey: .size)
            deleted = try container.decodeIfPresent(Date.self, forKey: .deleted)
            history = try container.decodeIfPresent([String].self, forKey: .history) ?? []
        }

        /// The content this entry had becomes history; `object` takes its place.
        mutating func replace(with object: String, modified: Date, size: Int) {
            let old = self.object
            self.object = object
            if old != object { remember(old) } else { history.removeAll { $0 == object } }
            self.modified = modified
            self.size = size
            deleted = nil
        }

        mutating func remember(_ old: String) {
            history.removeAll { $0 == old }
            history.insert(old, at: 0)
            history.removeAll { $0 == object }
            if history.count > StoreManifest.historyLimit { history.removeLast(history.count - StoreManifest.historyLimit) }
        }
    }

    public var version: Int
    /// Made once when the store is first written. A device's memory of its last sync belongs to one store; with
    /// another store, or the same one set up anew, that memory must not count.
    public var id: String
    public var entries: [String: Entry]

    public init(version: Int = StoreManifest.currentVersion, id: String = UUID().uuidString, entries: [String: Entry] = [:]) {
        self.version = version
        self.id = id
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        // A newer format may hold entries this version cannot read. The version is checked before they are used.
        entries = version > Self.currentVersion ? [:] : try container.decode([String: Entry].self, forKey: .entries)
    }

    /// A relative path that stays inside the sounds folder and names nothing hidden. A store someone tampered with
    /// must not be able to write anywhere else.
    public static func isSafe(path: String) -> Bool {
        guard !path.isEmpty, !path.utf8.contains(0), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && !part.hasPrefix(".")
        }
    }
}

/// A file of the sounds folder as the sync sees it.
public struct LocalSound: Equatable, Sendable {
    public var object: String
    public var modified: Date
    public var size: Int

    public init(object: String, modified: Date, size: Int) {
        self.object = object
        self.modified = modified
        self.size = size
    }
}

/// What one sync has to do, decided from three sides: the folder now, the store's index, and what was in sync after
/// the last run (`base`). Pure, so every rule has a test.
///
/// - Changed or new on one side only: that side wins.
/// - Changed on both sides to different contents: the newer one wins, the other becomes history in the store. A local
///   loser is uploaded first, so it is never lost.
/// - Removed on one side and unchanged on the other: removed on both. Removed on one side but changed on the other:
///   the change wins.
/// - Without a base (first run): the union of both, conflicts by date.
public struct SyncPlan: Equatable, Sendable {
    /// Paths whose local content becomes the store's current one.
    public var uploads: [String] = []
    /// Paths whose local content lost a conflict: uploaded as history before the download replaces it.
    public var preserved: [String] = []
    /// Paths to fetch from the store, with the manifest's entry.
    public var downloads: [String] = []
    /// Paths removed in the store and unchanged here: to remove here.
    public var removals: [String] = []
    /// Paths removed here: marked as deleted in the store.
    public var markedDeleted: [String] = []
    public var unchanged = 0
    public var manifest: StoreManifest
    /// What is in sync once the plan was carried out: path to object.
    public var base: [String: String] = [:]

    public static func make(local: [String: LocalSound], remote: StoreManifest, base: [String: String],
                            now: Date = Date()) -> SyncPlan {
        var plan = SyncPlan(manifest: remote)
        for path in Set(local.keys).union(remote.entries.keys).sorted() {
            let mine = local[path]
            let entry = remote.entries[path]
            let theirs = entry.flatMap { $0.deleted == nil ? $0.object : nil }
            let before = base[path]

            switch (mine, theirs) {
            case (nil, nil):
                break
            case (let mine?, nil):
                if entry != nil, before == mine.object {
                    // Removed in the store, and this device still has exactly what it last synced.
                    plan.removals.append(path)
                } else {
                    // New here, or changed here after it was removed elsewhere: the change wins.
                    var updated = entry ?? StoreManifest.Entry(object: mine.object, modified: mine.modified, size: mine.size)
                    updated.replace(with: mine.object, modified: mine.modified, size: mine.size)
                    plan.manifest.entries[path] = updated
                    plan.uploads.append(path)
                    plan.base[path] = mine.object
                }
            case (nil, let theirs?):
                if before == theirs {
                    // Removed here, and the store still has what this device last synced.
                    plan.manifest.entries[path]?.deleted = now
                    plan.markedDeleted.append(path)
                } else {
                    plan.downloads.append(path)
                    plan.base[path] = theirs
                }
            case (let mine?, let theirs?):
                guard var updated = entry else { break }
                if mine.object == theirs {
                    plan.unchanged += 1
                    plan.base[path] = theirs
                } else if before == mine.object {
                    plan.downloads.append(path)
                    plan.base[path] = theirs
                } else if before == theirs || mine.modified > updated.modified {
                    updated.replace(with: mine.object, modified: mine.modified, size: mine.size)
                    plan.manifest.entries[path] = updated
                    plan.uploads.append(path)
                    plan.base[path] = mine.object
                } else {
                    updated.remember(mine.object)
                    plan.manifest.entries[path] = updated
                    plan.preserved.append(path)
                    plan.downloads.append(path)
                    plan.base[path] = theirs
                }
            }
        }
        return plan
    }

    public var changesStore: Bool {
        !uploads.isEmpty || !preserved.isEmpty || !markedDeleted.isEmpty
    }
}
