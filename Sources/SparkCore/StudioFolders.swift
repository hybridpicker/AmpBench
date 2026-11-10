import Foundation

/// AmpBench's folder: `~/Music/AmpBench` with `Aufnahmen` (the recordings library) and `Presets`.
///
/// At the first start it takes over the folders of Spark Recorder and Spark Presets by copying them. On APFS a copy is a
/// clone: instant, and it takes no space until a file changes. The old folders stay exactly as they were, so the old
/// apps keep working on their own data and nothing can be lost. The copy is made in a hidden folder next to the new
/// one and renamed only when complete, so there is never a half-taken-over library.
///
/// The app was called Spark Studio before, with its folder `~/Music/Spark Studio`. That folder is the app's own, so it
/// is not copied but renamed, once, before anything reads it: see `adoptFormerRoot`.
public struct StudioFolders: Equatable, Sendable {
    public static let rootName = "AmpBench"
    /// The folder's name while the app was called Spark Studio.
    public static let formerRootName = "Spark Studio"
    public static let recordingsName = "Aufnahmen"
    public static let presetsName = "Presets"
    /// Says when and from where the folders were taken over. Hidden, so the library scan never sees it.
    public static let markerName = ".uebernommen.json"

    public let root: URL
    public var recordings: URL { root.appendingPathComponent(Self.recordingsName, isDirectory: true) }
    public var presets: URL { root.appendingPathComponent(Self.presetsName, isDirectory: true) }

    public init(root: URL) {
        self.root = root
    }

    public static var standard: StudioFolders {
        StudioFolders(root: FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(rootName, isDirectory: true))
    }

    /// The folders of the two former apps.
    public static var formerRecordings: URL { LibraryStore.defaultFolder }
    public static var formerPresets: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spark Presets", isDirectory: true)
    }

    public enum Outcome: Equatable, Sendable {
        /// The folder was there already.
        case ready
        /// Nothing to take over: a new, empty folder.
        case created
        /// Copied from the old folders that existed.
        case tookOver(recordings: Bool, presets: Bool)
        /// Not now: another app uses the old recordings library. Nothing was changed.
        case blocked
        /// The folder from the time the app was called Spark Studio was renamed to the new name.
        case renamed
    }

    private struct Marker: Codable {
        var date: Date
        var recordingsFrom: String?
        var presetsFrom: String?
    }

    /// Makes the folder ready. Throws only when copying fails, and then leaves no trace but the untouched old folders.
    public func prepare(formerRecordings: URL, formerPresets: URL,
                        fileManager: FileManager = .default) throws -> Outcome {
        switch try adoptFormerRoot(fileManager: fileManager) {
        case .renamed:
            try fileManager.createDirectory(at: recordings, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: presets, withIntermediateDirectories: true)
            return .renamed
        case .inUse:
            return .blocked
        case .nothingToDo:
            break
        }
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: recordings, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: presets, withIntermediateDirectories: true)
            return .ready
        }
        let hasRecordings = fileManager.fileExists(atPath: formerRecordings.path)
        let hasPresets = fileManager.fileExists(atPath: formerPresets.path)

        // Spark Recorder holds this lock while it runs. It is held here during the copy too, so it cannot start a
        // recording into the old folder halfway through.
        var lock: Int32 = -1
        if hasRecordings {
            lock = open(formerRecordings.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
            guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                if lock >= 0 { close(lock) }
                return .blocked
            }
        }
        defer { if lock >= 0 { close(lock) } }

        let parent = root.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(Self.rootName) wird eingerichtet \(UUID().uuidString)",
                                                    isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            let stagedRecordings = staging.appendingPathComponent(Self.recordingsName, isDirectory: true)
            let stagedPresets = staging.appendingPathComponent(Self.presetsName, isDirectory: true)
            if hasRecordings {
                try fileManager.copyItem(at: formerRecordings, to: stagedRecordings)
                // The old app's lock file belongs to the old folder.
                try? fileManager.removeItem(at: stagedRecordings.appendingPathComponent(".lock"))
            } else {
                try fileManager.createDirectory(at: stagedRecordings, withIntermediateDirectories: false)
            }
            if hasPresets {
                try fileManager.copyItem(at: formerPresets, to: stagedPresets)
            } else {
                try fileManager.createDirectory(at: stagedPresets, withIntermediateDirectories: false)
            }
            let marker = Marker(date: Date(), recordingsFrom: hasRecordings ? formerRecordings.path : nil,
                                presetsFrom: hasPresets ? formerPresets.path : nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(marker).write(to: staging.appendingPathComponent(Self.markerName))
            try fileManager.moveItem(at: staging, to: root)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return hasRecordings || hasPresets ? .tookOver(recordings: hasRecordings, presets: hasPresets) : .created
    }

    public enum FormerRoot: Equatable, Sendable {
        /// No folder of the former name, or the new folder is there already. Nothing was changed.
        case nothingToDo
        /// The former folder now has the new name.
        case renamed
        /// A running app holds the library in the former folder. Nothing was changed.
        case inUse
    }

    /// Renames the folder of the former name, next to `root`, to `root`: once, because afterwards it is gone. When both
    /// folders exist nothing is moved, overwritten or deleted, and the new one counts. A rename within one folder is
    /// one step for the file system, so there is never half a folder under either name.
    public func adoptFormerRoot(named formerName: String = StudioFolders.formerRootName,
                                fileManager: FileManager = .default) throws -> FormerRoot {
        let former = root.deletingLastPathComponent().appendingPathComponent(formerName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: former.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !Self.itemExists(at: root) else { return .nothingToDo }

        // An app still running under the former name holds this lock. The file is not created here: no lock file
        // means no such app ever opened the library.
        let lock = open(former.appendingPathComponent(Self.recordingsName).appendingPathComponent(".lock").path, O_RDWR)
        if lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0 {
            close(lock)
            return .inUse
        }
        defer { if lock >= 0 { close(lock) } }
        try fileManager.moveItem(at: former, to: root)
        return .renamed
    }

    /// True for anything of that name, also a file or a link that points nowhere, so that a rename never replaces it.
    private static func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

/// Settings of the former apps for AmpBench, which as a new app starts with none.
public enum SettingsTakeover {
    /// Copies the keys of the given apps' settings that `target` does not have yet, once: `markerKey` records that it
    /// happened. System keys (starting with "NS" or "Apple") stay behind. Returns the number of keys copied.
    @discardableResult
    public static func copy(from domains: [String], into target: UserDefaults, markerKey: String,
                            reading source: UserDefaults = .standard) -> Int {
        guard !target.bool(forKey: markerKey) else { return 0 }
        var copied = 0
        for domain in domains {
            for (key, value) in source.persistentDomain(forName: domain) ?? [:]
            where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && target.object(forKey: key) == nil {
                target.set(value, forKey: key)
                copied += 1
            }
        }
        target.set(true, forKey: markerKey)
        return copied
    }
}
