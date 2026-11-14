import AmpText
import CryptoKit
import Foundation

/// What a sync did, by the sounds' paths below the folder.
public struct SyncReport: Sendable, Equatable {
    public var uploaded: [String] = []
    public var downloaded: [String] = []
    public var removedLocally: [String] = []
    public var markedDeleted: [String] = []
    public var unchanged = 0

    public init(uploaded: [String] = [], downloaded: [String] = [], removedLocally: [String] = [],
                markedDeleted: [String] = [], unchanged: Int = 0) {
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.removedLocally = removedLocally
        self.markedDeleted = markedDeleted
        self.unchanged = unchanged
    }

    public var isEmpty: Bool {
        uploaded.isEmpty && downloaded.isEmpty && removedLocally.isEmpty && markedDeleted.isEmpty
    }

    /// One line for the message strip.
    public var summary: String {
        if isEmpty { return tr("The store is up to date: %d sounds.", unchanged) }
        var parts: [String] = []
        if !uploaded.isEmpty { parts.append(tr("%d stored", uploaded.count)) }
        if !downloaded.isEmpty { parts.append(tr("%d fetched", downloaded.count)) }
        if !markedDeleted.isEmpty { parts.append(tr("%d removed in the store", markedDeleted.count)) }
        if !removedLocally.isEmpty { parts.append(tr("%d removed here", removedLocally.count)) }
        return tr("Store: %@.", parts.joined(separator: ", "))
    }
}

/// What reading the whole store back found.
public struct VerifyReport: Sendable, Equatable {
    /// Sounds that were fetched, opened with the key and found whole.
    public var readable = 0
    /// Named by the index, but their data is not in the store.
    public var missing: [String] = []
    /// In the store, but not readable with the key or not what the index says.
    public var damaged: [String] = []
    /// Whole in the store, with another content than the file here: changed since the last sync.
    public var differing: [String] = []
    /// Whole in the store, not on this device.
    public var notHere: [String] = []
    /// On this device, not in the store yet.
    public var notStored: [String] = []

    public init() {}

    /// True when every sound of the store can be restored.
    public var isRestorable: Bool { missing.isEmpty && damaged.isEmpty }
    /// True when the store and this device also hold the same sounds.
    public var isInStep: Bool { isRestorable && differing.isEmpty && notHere.isEmpty && notStored.isEmpty }

    public var summary: String {
        if !isRestorable {
            return tr("The store is damaged: %d of its sounds cannot be restored.", missing.count + damaged.count)
        }
        if isInStep { return tr("Checked: all %d sounds in the store can be read and equal the ones here.", readable) }
        return tr("Checked: all %d sounds in the store can be read. %d differ from this device; a sync brings them in step.",
                  readable, differing.count + notHere.count + notStored.count)
    }
}

/// Keeps a folder of sounds and an encrypted store in step, in both directions.
///
/// Every file is encrypted on this device with the age format before it leaves, and so is the index. The store holds
/// `manifest.age` and `objects/<hex>.age`; without the key it shows neither names nor contents, only how many objects
/// there are and how large. Objects are never deleted, so an overwritten or removed sound stays restorable.
public final class SoundStore: Sendable {
    /// Larger files are left alone: the store is for sounds, which are small, not for recordings.
    public static let sizeLimit = 8 * 1024 * 1024

    public let folder: URL
    private let location: StoreLocation
    private let identity: AgeIdentity
    private let stateURL: URL
    private let remove: @Sendable (URL) throws -> Void
    private let nameKey: SymmetricKey

    public init(folder: URL, location: StoreLocation, identity: AgeIdentity, stateURL: URL,
                remove: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.folder = folder
        self.location = location
        self.identity = identity
        self.stateURL = stateURL
        self.remove = remove
        nameKey = SymmetricKey(data: SHA256.hash(data: Data("AmpBench store object".utf8) + identity.secret))
    }

    /// The object name for a content: the same content always has the same name, so it uploads once, and without the
    /// key the name says nothing about it.
    func objectName(for content: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: content, using: nameKey)
        return StoreName.object(hex: code.map { String(format: "%02x", $0) }.joined())
    }

    /// What the device remembers of its last sync with one store.
    private struct State: Codable {
        var store: String
        var objects: [String: String]
    }

    // MARK: Sync

    public func sync() async throws -> SyncReport {
        let (files, tooLarge) = try scan()
        var local: [String: LocalSound] = [:]
        var contents: [String: Data] = [:]
        for file in files {
            let data = try Data(contentsOf: file.url)
            let object = objectName(for: data)
            local[file.path] = LocalSound(object: object, modified: file.modified, size: data.count)
            contents[file.path] = data
        }

        let stored = try await readManifest()
        var remote = stored ?? StoreManifest()
        // A file too large to sync is neither new nor removed: its path is left out of the decision altogether.
        let setAside = remote.entries.filter { tooLarge.contains($0.key) }
        for path in tooLarge { remote.entries[path] = nil }

        let state = loadState()
        let base = stored != nil && state?.store == remote.id ? state?.objects ?? [:] : [:]
        var plan = SyncPlan.make(local: local, remote: remote, base: base)

        // Everything that will be written here is fetched, opened and checked first. A store that is damaged, tampered
        // with or incomplete then ends the sync before a single local file changed.
        var fetched: [String: Data] = [:]
        let wanted = plan.downloads.compactMap { plan.manifest.entries[$0]?.object }
        let objects = try await location.read(Array(Set(wanted)))
        for path in plan.downloads {
            guard let entry = plan.manifest.entries[path] else { continue }
            guard let sealed = objects[entry.object] else { throw StoreError.missingObject(path) }
            guard let plain = try? Age.decrypt(sealed, with: identity), objectName(for: plain) == entry.object else {
                throw StoreError.damagedObject(path)
            }
            fetched[path] = plain
        }

        // Objects first, the index last: an index never points at something that is not there yet.
        var sealed: [String: Data] = [:]
        for path in plan.uploads + plan.preserved {
            guard let data = contents[path], let sound = local[path] else { continue }
            sealed[sound.object] = try Age.encrypt(data, to: identity.recipient)
        }
        if !sealed.isEmpty { try await location.write(sealed) }
        if plan.changesStore || stored == nil {
            plan.manifest.entries.merge(setAside) { _, kept in kept }
            try await writeManifest(plan.manifest)
        }

        for path in plan.downloads {
            guard let data = fetched[path], let entry = plan.manifest.entries[path] else { continue }
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            // The store's date, so that the file does not look newer than it is at the next conflict.
            try? FileManager.default.setAttributes([.modificationDate: entry.modified], ofItemAtPath: url.path)
        }
        for path in plan.removals {
            try remove(folder.appendingPathComponent(path))
        }
        for path in tooLarge { plan.base[path] = base[path] }
        saveState(State(store: plan.manifest.id, objects: plan.base))

        return SyncReport(uploaded: plan.uploads, downloaded: plan.downloads, removedLocally: plan.removals,
                          markedDeleted: plan.markedDeleted, unchanged: plan.unchanged)
    }

    /// How many sounds the store holds, and how many removed ones it still keeps. Also the check that the key fits.
    public func status() async throws -> (entries: Int, deleted: Int) {
        let manifest = try await readManifest() ?? StoreManifest()
        let deleted = manifest.entries.values.filter { $0.deleted != nil }.count
        return (manifest.entries.count - deleted, deleted)
    }

    // MARK: Verify

    /// Reads every sound back from the store, opens it and compares it with the file here. Changes nothing, here or
    /// in the store. This is the proof that a backup can be restored, not only that it was written.
    public func verify() async throws -> VerifyReport {
        let manifest = try await readManifest() ?? StoreManifest()
        let live = manifest.entries.filter { $0.value.deleted == nil }
        let objects = try await location.read(Array(Set(live.values.map(\.object))))
        var report = VerifyReport()
        for (path, entry) in live.sorted(by: { $0.key < $1.key }) {
            guard let sealed = objects[entry.object] else {
                report.missing.append(path)
                continue
            }
            guard let plain = try? Age.decrypt(sealed, with: identity), objectName(for: plain) == entry.object else {
                report.damaged.append(path)
                continue
            }
            report.readable += 1
            guard let here = try? Data(contentsOf: folder.appendingPathComponent(path)) else {
                report.notHere.append(path)
                continue
            }
            if here != plain { report.differing.append(path) }
        }
        let (files, _) = try scan()
        report.notStored = files.map(\.path).filter { live[$0] == nil }.sorted()
        return report
    }

    // MARK: Manifest

    private func readManifest() async throws -> StoreManifest? {
        guard let sealed = try await location.read([StoreName.manifest])[StoreName.manifest] else { return nil }
        let plain: Data
        do {
            plain = try Age.decrypt(sealed, with: identity)
        } catch AgeError.wrongKey {
            throw StoreError.wrongKey
        } catch {
            throw StoreError.damagedManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(StoreManifest.self, from: plain) else { throw StoreError.damagedManifest }
        guard manifest.version <= StoreManifest.currentVersion else { throw StoreError.newerManifest(manifest.version) }
        for (path, entry) in manifest.entries {
            guard StoreManifest.isSafe(path: path) else { throw StoreError.unsafePath }
            guard ([entry.object] + entry.history).allSatisfy(StoreName.isValid), entry.object != StoreName.manifest else {
                throw StoreError.damagedManifest
            }
        }
        return manifest
    }

    private func writeManifest(_ manifest: StoreManifest) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let sealed = try Age.encrypt(try encoder.encode(manifest), to: identity.recipient)
        try await location.write([StoreName.manifest: sealed])
    }

    // MARK: Local side

    private struct LocalFile {
        var path: String
        var url: URL
        var modified: Date
    }

    /// Every plain, visible file below the folder. Links are not followed, so nothing outside the folder is read.
    private func scan() throws -> (files: [LocalFile], tooLarge: Set<String>) {
        var files: [LocalFile] = []
        var tooLarge: Set<String> = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                         .contentModificationDateKey]
        func walk(_ directory: URL, prefix: String) throws {
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                       options: [.skipsHiddenFiles])
            for child in children {
                let name = child.lastPathComponent
                let path = prefix + name
                let values = try child.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true, StoreManifest.isSafe(path: path) else { continue }
                if values.isDirectory == true {
                    try walk(child, prefix: path + "/")
                } else if values.isRegularFile == true {
                    if (values.fileSize ?? 0) > Self.sizeLimit {
                        tooLarge.insert(path)
                    } else {
                        files.append(LocalFile(path: path, url: child, modified: values.contentModificationDate ?? Date()))
                    }
                }
            }
        }
        guard FileManager.default.fileExists(atPath: folder.path) else { return ([], []) }
        try walk(folder, prefix: "")
        return (files, tooLarge)
    }

    private func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    /// Losing this file costs nothing but a first-run sync, so a failure to write it does not fail the sync.
    private func saveState(_ state: State) {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }
}
