import AmpText
import Foundation

/// Where the encrypted files of a store live: a folder, a server reached over SSH, or one that takes HTTPS GET and
/// PUT. A location only ever sees ciphertext and names that say nothing about the sounds.
public protocol StoreLocation: Sendable {
    /// The files with these names. A name the store does not hold is simply absent from the result.
    func read(_ names: [String]) async throws -> [String: Data]
    func write(_ files: [String: Data]) async throws
}

/// The only names a store uses: the index and the objects it points to.
public enum StoreName {
    public static let manifest = "manifest.age"
    static let objectFolder = "objects"

    static func object(hex: String) -> String { "\(objectFolder)/\(hex).age" }

    /// Every location refuses other names, so no name can ever need quoting or leave the store's folder.
    public static func isValid(_ name: String) -> Bool {
        if name == manifest { return true }
        let prefix = objectFolder + "/"
        guard name.hasPrefix(prefix), name.hasSuffix(".age") else { return false }
        let hex = name.dropFirst(prefix.count).dropLast(4).utf8
        return hex.count == 64 && hex.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    static func check(_ names: some Sequence<String>) throws {
        for name in names where !isValid(name) { throw StoreError.invalidName }
    }
}

public enum StoreError: LocalizedError, Equatable {
    case invalidName
    case wrongKey
    case damagedManifest
    case newerManifest(Int)
    case unsafePath
    case missingObject(String)
    case damagedObject(String)
    case invalidHost
    case invalidPath
    case ssh(String)
    case sshOnlyOnMac
    case insecureURL
    case invalidURL
    case notAllowed(Int)
    case storeFull
    case http(Int)
    case incompleteSettings

    public var errorDescription: String? {
        switch self {
        case .invalidName: tr("The store was asked for a file name it does not use.")
        case .wrongKey: tr("This key does not open the store. Enter the key the store was set up with.")
        case .damagedManifest: tr("The store's index is damaged. Nothing was changed.")
        case .newerManifest(let version):
            tr("The store was written by a newer version of AmpBench (format %d). Update AmpBench on this device.", version)
        case .unsafePath: tr("The store's index names a file outside the sounds folder. Nothing was changed.")
        case .missingObject(let path): tr("The store has no data for “%@”. Nothing was changed.", path)
        case .damagedObject(let path): tr("The stored data for “%@” is damaged. Nothing was changed.", path)
        case .invalidHost: tr("The server name may only hold letters, digits, dots, hyphens, underscores and @.")
        case .invalidPath: tr("The folder on the server may only hold letters, digits, dots, hyphens, underscores, slashes and ~.")
        case .ssh(let message): tr("The server could not be reached over SSH: %@", message)
        case .sshOnlyOnMac: tr("A store over SSH works only on the Mac. Use a folder or an HTTPS address on this device.")
        case .insecureURL: tr("The address must start with https://.")
        case .invalidURL: tr("This is not a valid address.")
        case .notAllowed(let status): tr("The server refused the user name or password (HTTP %d).", status)
        case .storeFull: tr("The server has no space left for the store.")
        case .http(let status): tr("The server answered with an error (HTTP %d).", status)
        case .incompleteSettings: tr("The store's settings are incomplete.")
        }
    }
}

/// A folder as a store: any synced folder (Google Drive, iCloud Drive), a mounted share or a stick. Whoever makes it
/// holds the folder's security-scoped access for as long as it is used.
public struct FolderLocation: StoreLocation {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func read(_ names: [String]) async throws -> [String: Data] {
        try StoreName.check(names)
        var found: [String: Data] = [:]
        for name in names {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            found[name] = try Data(contentsOf: url)
        }
        return found
    }

    public func write(_ files: [String: Data]) async throws {
        try StoreName.check(files.keys)
        for (name, data) in files {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }
}
