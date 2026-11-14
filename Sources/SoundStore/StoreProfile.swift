import AmpText
import Foundation

/// Everything one device remembers about its store: where it is (in the app's settings), the key and a password (in
/// the keychain) and what was in step after the last sync (a small file). Nothing of it is ever in the repository.
///
/// A test library gets a profile of its own, so tests and window pictures never see or touch the real store.
public struct StoreProfile: @unchecked Sendable {
    public static let settingsKey = "soundStoreSettings"
    public static let lastSyncKey = "soundStoreLastSync"

    public let defaults: UserDefaults
    public let keychainService: String
    public let stateURL: URL

    public init(defaults: UserDefaults, keychainService: String, stateURL: URL) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.stateURL = stateURL
    }

    /// The real store of this device.
    public static var standard: StoreProfile {
        StoreProfile(defaults: .standard, keychainService: StoreKeychain.defaultService,
                     stateURL: supportFolder.appendingPathComponent("store-state.json"))
    }

    /// A store apart from the real one, for a test library: its own settings, key and state.
    public static func testing(stateFolder: URL) -> StoreProfile {
        StoreProfile(defaults: UserDefaults(suiteName: "local.ampbench.store.tests") ?? .standard,
                     keychainService: "local.ampbench.store.tests",
                     stateURL: stateFolder.appendingPathComponent(".store-state.json"))
    }

    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AmpBench", isDirectory: true)
    }

    // MARK: Where

    public var settings: StoreSettings? {
        get { defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(StoreSettings.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.settingsKey)
            } else {
                defaults.removeObject(forKey: Self.settingsKey)
            }
        }
    }

    public var lastSync: Date? {
        get { defaults.object(forKey: Self.lastSyncKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastSyncKey) }
    }

    // MARK: Key

    public var hasKey: Bool { StoreKeychain.identity(service: keychainService) != nil }

    /// The key, or nil when there is none or the keychain's text is no key.
    public var identity: AgeIdentity? {
        StoreKeychain.identity(service: keychainService).flatMap { try? AgeIdentity($0) }
    }

    /// Makes a new key and keeps it in the keychain. Refuses when there is one already: replacing a key would lock
    /// this device out of the store it was made for.
    @discardableResult
    public func createKey() throws -> AgeIdentity {
        guard !hasKey else { throw StoreProfileError.keyExists }
        let identity = AgeIdentity.generate()
        try StoreKeychain.setIdentity(identity.text, service: keychainService)
        return identity
    }

    /// Takes a key made on another device, as text.
    @discardableResult
    public func useKey(_ text: String) throws -> AgeIdentity {
        let identity = try AgeIdentity(text)
        try StoreKeychain.setIdentity(identity.text, service: keychainService)
        // What was in step belonged to the store of the old key.
        try? FileManager.default.removeItem(at: stateURL)
        return identity
    }

    public var password: String? { StoreKeychain.password(service: keychainService) }

    public func setPassword(_ text: String?) throws {
        try StoreKeychain.setPassword(text?.isEmpty == true ? nil : text, service: keychainService)
    }

    /// Forgets the place on this device. The store itself and the key stay as they are.
    public func disconnect() {
        settings = nil
        lastSync = nil
        try? StoreKeychain.setPassword(nil, service: keychainService)
        try? FileManager.default.removeItem(at: stateURL)
    }

    // MARK: Syncing

    /// Brings `folder` and the store in step. `remove` takes a sound away that was removed on another device; the
    /// apps pass their Trash, so nothing is deleted for good.
    public func sync(folder: URL, remove: @escaping @Sendable (URL) throws -> Void) async throws -> SyncReport {
        guard let settings else { throw StoreProfileError.notSetUp }
        guard let identity else { throw StoreProfileError.noKey }
        // A folder picked in the system's dialog is reachable only between these two calls.
        let picked = Self.resolve(settings.folderBookmark)
        let scoped = picked?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { picked?.stopAccessingSecurityScopedResource() } }
        let location = try settings.location(folder: settings.kind == .folder ? picked : nil, password: password)
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = SoundStore(folder: folder, location: location, identity: identity, stateURL: stateURL, remove: remove)
        let report = try await store.sync()
        lastSync = Date()
        return report
    }

    private static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
    }

    /// A bookmark that finds a picked folder again after a restart. On the iPad it also carries the permission.
    public static func bookmark(for folder: URL) -> Data? {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return try? folder.bookmarkData()
    }
}

public enum StoreProfileError: LocalizedError, Equatable {
    case notSetUp
    case noKey
    case keyExists

    public var errorDescription: String? {
        switch self {
        case .notSetUp: tr("The sound store is not set up on this device.")
        case .noKey: tr("This device has no key for the sound store. Create one, or enter the key of your store.")
        case .keyExists:
            tr("This device already has a key. Replacing it would lock it out of its store; enter another key on purpose if that is what you want.")
        }
    }
}
