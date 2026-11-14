import Foundation
import XCTest
@testable import SoundStore

/// A folder that exists for one test.
func makeTemporaryFolder(_ test: XCTestCase, _ name: String = "store") throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("ampbench-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return folder
}

/// Bytes that look random but are the same in every run.
func madeUpBytes(_ count: Int, seed: UInt64 = 7) -> Data {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    var bytes = [UInt8](repeating: 0, count: count)
    for index in bytes.indices {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(bytes)
}

/// Every file below a folder, by relative path.
func allFiles(in folder: URL) -> [String: Data] {
    var found: [String: Data] = [:]
    let base = folder.resolvingSymlinksInPath().path
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
    for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        let path = String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
        found[path] = try? Data(contentsOf: url)
    }
    return found
}

/// A location in memory that counts what goes through it.
final class MemoryLocation: StoreLocation, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private var written: [[String]] = []

    var files: [String: Data] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    var writes: [[String]] { lock.withLock { written } }

    func read(_ names: [String]) async throws -> [String: Data] {
        try StoreName.check(names)
        return lock.withLock { stored.filter { names.contains($0.key) } }
    }

    func write(_ files: [String: Data]) async throws {
        try StoreName.check(files.keys)
        lock.withLock {
            stored.merge(files) { _, new in new }
            written.append(files.keys.sorted())
        }
    }
}
