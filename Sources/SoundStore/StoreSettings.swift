import AmpText
import Foundation
import Security

/// Where the store is, without any secret: this may sit in the app's settings. The key and a password are in the
/// keychain (`StoreKeychain`), never here and never in a file of the repository.
public struct StoreSettings: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case folder
        case ssh
        case http
    }

    public var kind: Kind
    /// A folder, as a path. On the iPad the bookmark is what counts; the path is only shown.
    public var folderPath: String?
    /// A security-scoped bookmark of a folder picked in the Files dialog.
    public var folderBookmark: Data?
    /// The server's name as `ssh` knows it, for example an entry of `~/.ssh/config`.
    public var host: String?
    /// The folder on the server, relative to the home folder or absolute.
    public var path: String?
    /// The HTTPS address the files live below.
    public var url: String?
    public var user: String?

    public init(kind: Kind, folderPath: String? = nil, folderBookmark: Data? = nil, host: String? = nil,
                path: String? = nil, url: String? = nil, user: String? = nil) {
        self.kind = kind
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.host = host
        self.path = path
        self.url = url
        self.user = user
    }

    /// The place in a few words, for the settings and messages. No user name, no password.
    public var summary: String {
        switch kind {
        case .folder:
            let name = folderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return name.isEmpty ? tr("Folder") : tr("Folder “%@”", name)
        case .ssh:
            return tr("Server %@ (SSH)", host ?? "")
        case .http:
            return URL(string: url ?? "")?.host.map { tr("Server %@ (HTTPS)", $0) } ?? tr("Server (HTTPS)")
        }
    }

    /// The location these settings describe. `folder` is the resolved bookmark where there is one; its
    /// security-scoped access is the caller's to start and stop.
    public func location(folder: URL? = nil, password: String? = nil, session: URLSession = .shared) throws -> StoreLocation {
        switch kind {
        case .folder:
            if let folder { return FolderLocation(folder: folder) }
            guard let folderPath, !folderPath.isEmpty else { throw StoreError.incompleteSettings }
            return FolderLocation(folder: URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true))
        case .ssh:
            guard let host, let path, !host.isEmpty, !path.isEmpty else { throw StoreError.incompleteSettings }
            #if os(macOS)
            return try SSHLocation(host: host, path: path)
            #else
            throw StoreError.sshOnlyOnMac
            #endif
        case .http:
            guard let url, !url.isEmpty else { throw StoreError.incompleteSettings }
            guard let base = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), base.host != nil else {
                throw StoreError.invalidURL
            }
            guard HTTPLocation.isAllowed(base) else { throw StoreError.insecureURL }
            return HTTPLocation(base: base, user: user, password: password, session: session)
        }
    }
}

/// The store's two secrets in the system's keychain: the key that opens the store, and a password for an HTTPS
/// server. Kept on this device only (never synchronized), readable after the first unlock so a background sync works.
public enum StoreKeychain {
    public static let defaultService = "local.ampbench.store"
    private static let identityAccount = "identity"
    private static let passwordAccount = "password"

    public struct Failure: LocalizedError, Equatable {
        public var status: OSStatus
        public var errorDescription: String? { tr("The keychain could not be used (error %d).", Int(status)) }
    }

    public static func identity(service: String = defaultService) -> String? { read(identityAccount, service) }
    public static func password(service: String = defaultService) -> String? { read(passwordAccount, service) }

    /// Stores the key's text, or removes it with nil.
    public static func setIdentity(_ text: String?, service: String = defaultService) throws {
        try write(text, identityAccount, service)
    }

    public static func setPassword(_ text: String?, service: String = defaultService) throws {
        try write(text, passwordAccount, service)
    }

    private static func query(_ account: String, _ service: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
         kSecAttrSynchronizable: false]
    }

    private static func read(_ account: String, _ service: String) -> String? {
        var query = query(account, service)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ text: String?, _ account: String, _ service: String) throws {
        let query = query(account, service)
        guard let text else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }
        let data = Data(text.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
}
