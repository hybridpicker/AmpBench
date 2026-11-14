import XCTest
@testable import SoundStore

private let objectA = "objects/" + String(repeating: "a", count: 64) + ".age"
private let objectB = "objects/" + String(repeating: "0f", count: 32) + ".age"

final class StoreNameTests: XCTestCase {
    func testOnlyTheStoresOwnNamesPass() {
        XCTAssertTrue(StoreName.isValid("manifest.age"))
        XCTAssertTrue(StoreName.isValid(objectA))
        XCTAssertTrue(StoreName.isValid(objectB))
        let refused = ["", "manifest", "../manifest.age", "objects/../manifest.age", "objects/abc.age",
                       "objects/" + String(repeating: "A", count: 64) + ".age",
                       "objects/" + String(repeating: "a", count: 64),
                       "objects/" + String(repeating: "a", count: 63) + "/.age",
                       "objects/" + String(repeating: "a", count: 62) + "$x.age",
                       "/" + objectA, objectA + " ", "other/" + String(repeating: "a", count: 64) + ".age"]
        for name in refused { XCTAssertFalse(StoreName.isValid(name), name) }
    }
}

final class FolderLocationTests: XCTestCase {
    func testWritesAndReadsBack() async throws {
        let folder = try makeTemporaryFolder(self).appendingPathComponent("not there yet")
        let location = FolderLocation(folder: folder)
        let nothing = try await location.read(["manifest.age", objectA])
        XCTAssertTrue(nothing.isEmpty)
        try await location.write(["manifest.age": Data([1]), objectA: Data([2, 3])])
        try await location.write(["manifest.age": Data([9])])
        let found = try await location.read(["manifest.age", objectA, objectB])
        XCTAssertEqual(found, ["manifest.age": Data([9]), objectA: Data([2, 3])])
        XCTAssertEqual(Set(allFiles(in: folder).keys), ["manifest.age", objectA])
    }

    func testOtherNamesAreRefused() async throws {
        let location = FolderLocation(folder: try makeTemporaryFolder(self))
        do {
            try await location.write(["../escape.age": Data()])
            XCTFail("a name outside the store was written")
        } catch { XCTAssertEqual(error as? StoreError, .invalidName) }
        do {
            _ = try await location.read(["/etc/hosts"])
            XCTFail("a name outside the store was read")
        } catch { XCTAssertEqual(error as? StoreError, .invalidName) }
    }
}

/// A made-up WebDAV server inside the process: files in a dictionary, a collection must exist before a PUT into it.
private final class StubServer: URLProtocol, @unchecked Sendable {
    struct State {
        var files: [String: Data] = [:]
        var collections: Set<String> = []
        var requests: [String] = []
        var authorizations: Set<String> = []
        var requiredAuthorization: String?
        var needsCollections = true
        var failPutWith: Int?
    }
    static let lock = NSLock()
    static var state = State()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        var status = 500
        var answer = Data()
        Self.lock.withLock {
            Self.state.requests.append("\(method) \(path)")
            if let header = request.value(forHTTPHeaderField: "Authorization") { Self.state.authorizations.insert(header) }
            if let required = Self.state.requiredAuthorization, request.value(forHTTPHeaderField: "Authorization") != required {
                status = 401
                return
            }
            let parent = (path as NSString).deletingLastPathComponent
            switch method {
            case "GET":
                if let data = Self.state.files[path] { status = 200; answer = data } else { status = 404 }
            case "PUT":
                if let failure = Self.state.failPutWith {
                    status = failure
                } else if Self.state.needsCollections, !Self.state.collections.contains(parent) {
                    status = 409
                } else {
                    status = Self.state.files[path] == nil ? 201 : 204
                    Self.state.files[path] = body
                }
            case "MKCOL":
                let collection = path.hasSuffix("/") ? String(path.dropLast()) : path
                if Self.state.collections.contains(collection) { status = 405 } else {
                    Self.state.collections.insert(collection)
                    status = 201
                }
            default:
                status = 405
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class HTTPLocationTests: XCTestCase {
    private let base = URL(string: "https://store.example/dav/sounds")!

    override func setUp() {
        StubServer.lock.withLock { StubServer.state = .init() }
    }

    private var state: StubServer.State { StubServer.lock.withLock { StubServer.state } }

    func testPutsMakeTheCollectionsOnceAndGetsReadBack() async throws {
        let location = HTTPLocation(base: base, user: nil, password: nil, session: StubServer.session())
        try await location.write([objectA: Data([1, 2]), objectB: Data([3])])
        try await location.write(["manifest.age": Data([4])])
        XCTAssertEqual(state.files, ["/dav/sounds/\(objectA)": Data([1, 2]), "/dav/sounds/\(objectB)": Data([3]),
                                     "/dav/sounds/manifest.age": Data([4])])
        XCTAssertEqual(state.requests.filter { $0.hasPrefix("MKCOL") }, ["MKCOL /dav/sounds", "MKCOL /dav/sounds/objects"])
        XCTAssertTrue(state.authorizations.isEmpty)
        let found = try await location.read(["manifest.age", objectA, "objects/" + String(repeating: "b", count: 64) + ".age"])
        XCTAssertEqual(found, ["manifest.age": Data([4]), objectA: Data([1, 2])])
    }

    func testAPlainServerNeedsNoCollections() async throws {
        StubServer.lock.withLock { StubServer.state.needsCollections = false }
        let location = HTTPLocation(base: base, user: "", password: nil, session: StubServer.session())
        try await location.write([objectA: Data([1])])
        XCTAssertEqual(state.requests, ["PUT /dav/sounds/\(objectA)"])
    }

    func testUserAndPasswordGoAsBasicAuthorization() async throws {
        let expected = "Basic " + Data("player:made-up word".utf8).base64EncodedString()
        StubServer.lock.withLock { StubServer.state.requiredAuthorization = expected }
        let location = HTTPLocation(base: base, user: "player", password: "made-up word", session: StubServer.session())
        try await location.write(["manifest.age": Data([1])])
        let found = try await location.read(["manifest.age"])
        XCTAssertEqual(found.count, 1)

        let wrong = HTTPLocation(base: base, user: "player", password: "other", session: StubServer.session())
        do {
            _ = try await wrong.read(["manifest.age"])
            XCTFail("a wrong password read the store")
        } catch { XCTAssertEqual(error as? StoreError, .notAllowed(401)) }
        do {
            try await wrong.write(["manifest.age": Data([2])])
            XCTFail("a wrong password wrote to the store")
        } catch { XCTAssertEqual(error as? StoreError, .notAllowed(401)) }
    }

    func testAFullServerAndOtherErrorsAreNamed() async throws {
        let location = HTTPLocation(base: base, user: nil, password: nil, session: StubServer.session())
        for (status, expected) in [(507, StoreError.storeFull), (403, .notAllowed(403)), (500, .http(500))] {
            StubServer.lock.withLock { StubServer.state.failPutWith = status }
            do {
                try await location.write(["manifest.age": Data([1])])
                XCTFail("HTTP \(status) passed as written")
            } catch { XCTAssertEqual(error as? StoreError, expected) }
        }
    }

    func testOnlyHTTPSExceptOnThisMachine() async throws {
        XCTAssertTrue(HTTPLocation.isAllowed(URL(string: "https://store.example/x")!))
        XCTAssertTrue(HTTPLocation.isAllowed(URL(string: "http://localhost:8080/x")!))
        XCTAssertTrue(HTTPLocation.isAllowed(URL(string: "http://127.0.0.1/x")!))
        XCTAssertFalse(HTTPLocation.isAllowed(URL(string: "http://store.example/x")!))
        XCTAssertFalse(HTTPLocation.isAllowed(URL(string: "http://localhost.example/x")!))
        XCTAssertFalse(HTTPLocation.isAllowed(URL(string: "ftp://store.example/x")!))
        XCTAssertFalse(HTTPLocation.isAllowed(URL(string: "file:///tmp/x")!))
        let plain = HTTPLocation(base: URL(string: "http://store.example/x")!, user: "u", password: "p", session: StubServer.session())
        do {
            _ = try await plain.read(["manifest.age"])
            XCTFail("read over plain HTTP")
        } catch { XCTAssertEqual(error as? StoreError, .insecureURL) }
        XCTAssertTrue(state.requests.isEmpty, "nothing may be sent without TLS, least of all the password")
    }

    func testOtherNamesAreRefusedBeforeAnythingIsSent() async throws {
        let location = HTTPLocation(base: base, user: nil, password: nil, session: StubServer.session())
        do {
            try await location.write(["../../etc/passwd": Data()])
            XCTFail("a name outside the store was sent")
        } catch { XCTAssertEqual(error as? StoreError, .invalidName) }
        XCTAssertTrue(state.requests.isEmpty)
    }
}

#if os(macOS)
final class SSHLocationTests: XCTestCase {
    func testHostAndPathTakeOnlyHarmlessCharacters() {
        for host in ["server", "user@server.example", "my_host-2", "192.168.1.5"] {
            XCTAssertNoThrow(try SSHLocation(host: host, path: "sounds"), host)
        }
        for host in ["", "-oProxyCommand=x", "a b", "a;b", "a$(b)", "a`b`", "a/b", "a'b", "a\nb", "ä"] {
            XCTAssertThrowsError(try SSHLocation(host: host, path: "sounds"), host) { XCTAssertEqual($0 as? StoreError, .invalidHost) }
        }
        for path in ["sounds", "~/ampbench-store", "/srv/store/a.b_c-d", "a/b/c"] {
            XCTAssertNoThrow(try SSHLocation(host: "server", path: path), path)
        }
        for path in ["", "-rf", "a b", "a;b", "$(x)", "a/../b", "..", "a'b", "a\"b", "a&b", "a|b", "a*b", "a\\b", "a\nb"] {
            XCTAssertThrowsError(try SSHLocation(host: "server", path: path), path) { XCTAssertEqual($0 as? StoreError, .invalidPath) }
        }
    }

    func testTheCommandsAreWhatTheServerShallRun() {
        XCTAssertEqual(SSHLocation.sshArguments(host: "server", command: "true"),
                       ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", "server", "true"])
        XCTAssertEqual(SSHLocation.writeCommand(path: "~/store"),
                       "umask 077; mkdir -p ~/store && chmod 700 ~/store && tar -xf - -C ~/store")
        XCTAssertEqual(SSHLocation.readCommand(path: "~/store", names: ["manifest.age", objectA]),
                       "cd ~/store 2>/dev/null || exit 0; for f in manifest.age \(objectA); do [ -f \"$f\" ] && echo \"$f\"; done | tar -cf - -T -")
    }

    /// Runs what would go to the server in a local shell instead: the same commands and the same tar streams, no ssh.
    private func localServer(log: CallLog) -> SSHLocation.Runner {
        { executable, arguments, input in
            if executable == SSHLocation.ssh {
                log.add(arguments)
                return try SSHLocation.runProcess("/bin/sh", ["-c", arguments.last!], input)
            }
            return try SSHLocation.runProcess(executable, arguments, input)
        }
    }

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String]] = []
        func add(_ call: [String]) { lock.withLock { all.append(call) } }
        var calls: [[String]] { lock.withLock { all } }
    }

    func testFilesTravelAsTarStreams() async throws {
        let remote = try makeTemporaryFolder(self, "remote").appendingPathComponent("store")
        try XCTSkipUnless(SSHLocation.isValidPath(remote.path), "the temporary folder's path has characters a store path may not have")
        let log = CallLog()
        let location = try SSHLocation(host: "made-up-host", path: remote.path, runner: localServer(log: log))

        let nothing = try await location.read(["manifest.age", objectA])
        XCTAssertTrue(nothing.isEmpty, "a folder that is not there is an empty store")

        let large = madeUpBytes(300_000)
        try await location.write([objectA: large, "manifest.age": Data([1, 2, 3])])
        XCTAssertEqual(allFiles(in: remote), [objectA: large, "manifest.age": Data([1, 2, 3])])
        try await location.write(["manifest.age": Data([4])])

        let found = try await location.read(["manifest.age", objectA, objectB])
        XCTAssertEqual(found, ["manifest.age": Data([4]), objectA: large])
        let none = try await location.read([objectB])
        XCTAssertTrue(none.isEmpty)

        XCTAssertEqual(log.calls.count, 5, "one connection per call")
        XCTAssertTrue(log.calls.allSatisfy { $0.prefix(6) == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", "made-up-host"] })
    }

    func testManyNamesAreReadInSeveralConnections() async throws {
        let remote = try makeTemporaryFolder(self, "remote")
        try XCTSkipUnless(SSHLocation.isValidPath(remote.path))
        let log = CallLog()
        let location = try SSHLocation(host: "made-up-host", path: remote.path, runner: localServer(log: log))
        let names = (0..<(SSHLocation.namesPerRead + 3)).map { "objects/" + String(format: "%064x", $0) + ".age" }
        try await location.write([names[0]: Data([1]), names.last!: Data([2])])
        let found = try await location.read(names)
        XCTAssertEqual(found, [names[0]: Data([1]), names.last!: Data([2])])
        XCTAssertEqual(log.calls.count, 3)
    }

    func testAFailedConnectionSaysWhatSSHSaid() async throws {
        let location = try SSHLocation(host: "made-up-host", path: "store") { _, _, _ in
            (255, Data(), Data(("ssh: Could not resolve hostname made-up-host\n" + String(repeating: "x", count: 900)).utf8))
        }
        do {
            _ = try await location.read(["manifest.age"])
            XCTFail("a failed connection read as an empty store")
        } catch let StoreError.ssh(message) {
            XCTAssertTrue(message.hasPrefix("ssh: Could not resolve hostname"))
            XCTAssertLessThanOrEqual(message.count, 300)
        }
        do {
            try await location.write(["manifest.age": Data([1])])
            XCTFail("a failed connection passed as written")
        } catch { XCTAssertNotNil(error as? StoreError) }
    }

    func testOtherNamesNeverReachACommand() async throws {
        let location = try SSHLocation(host: "made-up-host", path: "store") { _, _, _ in
            XCTFail("a program was started")
            return (0, Data(), Data())
        }
        do {
            _ = try await location.read(["manifest.age; rm -rf ~"])
            XCTFail("a name with a command was read")
        } catch { XCTAssertEqual(error as? StoreError, .invalidName) }
        do {
            try await location.write(["$(reboot)": Data()])
            XCTFail("a name with a command was written")
        } catch { XCTAssertEqual(error as? StoreError, .invalidName) }
    }
}
#endif
