import Foundation

/// A server that takes HTTPS GET and PUT below one address: WebDAV (Nextcloud, a NAS) or a plain web server with PUT
/// switched on. Nothing is listed, so the server needs no PROPFIND.
public struct HTTPLocation: StoreLocation {
    public let base: URL
    private let user: String?
    private let password: String?
    private let session: URLSession

    public init(base: URL, user: String?, password: String?, session: URLSession = .shared) {
        self.base = base
        self.user = user.flatMap { $0.isEmpty ? nil : $0 }
        self.password = password
        self.session = session
    }

    /// The password and the ciphertext travel only over TLS. A server on this machine is the exception, for tests.
    static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return host == "localhost" || host == "127.0.0.1"
        default: return false
        }
    }

    public func read(_ names: [String]) async throws -> [String: Data] {
        try StoreName.check(names)
        try checkBase()
        var found: [String: Data] = [:]
        for name in names {
            let (data, status) = try await send("GET", base.appendingPathComponent(name))
            switch status {
            case 200: found[name] = data
            case 404, 410: continue
            default: throw Self.error(for: status)
            }
        }
        return found
    }

    public func write(_ files: [String: Data]) async throws {
        try StoreName.check(files.keys)
        try checkBase()
        var madeCollections: Set<URL> = []
        for (name, data) in files {
            let url = base.appendingPathComponent(name)
            var status = try await send("PUT", url, body: data).status
            // WebDAV answers 409 (some servers 404) while the collection is missing. It is made once, then retried.
            let parent = url.deletingLastPathComponent()
            if status == 404 || status == 409, !madeCollections.contains(parent) {
                madeCollections.insert(parent)
                if parent != base, !madeCollections.contains(base) {
                    madeCollections.insert(base)
                    _ = try await send("MKCOL", base)
                }
                _ = try await send("MKCOL", parent)
                status = try await send("PUT", url, body: data).status
            }
            guard (200..<300).contains(status) else { throw Self.error(for: status) }
        }
    }

    private func checkBase() throws {
        guard Self.isAllowed(base) else { throw StoreError.insecureURL }
    }

    private func send(_ method: String, _ url: URL, body: Data? = nil) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        if let user {
            let token = Data("\(user):\(password ?? "")".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func error(for status: Int) -> StoreError {
        switch status {
        case 401, 403: .notAllowed(status)
        case 507: .storeFull
        default: .http(status)
        }
    }
}
