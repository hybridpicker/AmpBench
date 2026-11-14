#if os(macOS)
import Foundation

/// A folder on a server reached with the system's `ssh`, under the name and key of the user's own SSH configuration.
/// The app holds no SSH secret: the connection never asks (`BatchMode`), it works or reports why not.
///
/// One connection per call. Files travel as a tar stream, so a first backup of hundreds of sounds is one connection
/// too.
public struct SSHLocation: StoreLocation {
    /// Runs a program with this standard input and returns what it wrote. Tests replace it and never start ssh.
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ input: Data?) throws
        -> (status: Int32, output: Data, errors: Data)

    public let host: String
    public let path: String
    private let run: Runner

    static let ssh = "/usr/bin/ssh"
    static let tar = "/usr/bin/tar"
    /// A remote command is one argument for the server's shell, which Linux limits to 128 KiB.
    static let namesPerRead = 500

    public init(host: String, path: String) throws {
        try self.init(host: host, path: path, runner: Self.runProcess)
    }

    public init(host: String, path: String, runner: @escaping Runner) throws {
        guard Self.isValidHost(host) else { throw StoreError.invalidHost }
        guard Self.isValidPath(path) else { throw StoreError.invalidPath }
        self.host = host
        self.path = path
        run = runner
    }

    // Host and path go into a command line unquoted, so only characters that mean nothing to ssh or a shell pass.
    static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.range(of: "^[A-Za-z0-9._@-]+$", options: .regularExpression) != nil
    }

    static func isValidPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("-") && !path.contains("..")
            && path.range(of: "^[A-Za-z0-9._/~-]+$", options: .regularExpression) != nil
    }

    static func sshArguments(host: String, command: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", host, command]
    }

    /// Unpacks the stream on standard input into the folder, which it creates.
    static func writeCommand(path: String) -> String {
        "mkdir -p \(path) && tar -xf - -C \(path)"
    }

    /// Packs those of the names that exist. A missing folder is a store with nothing in it, not an error. Only
    /// options every tar knows, so the server may be Linux or a Mac.
    static func readCommand(path: String, names: [String]) -> String {
        "cd \(path) 2>/dev/null || exit 0; for f in \(names.joined(separator: " ")); do [ -f \"$f\" ] && echo \"$f\"; done | tar -cf - -T -"
    }

    public func read(_ names: [String]) async throws -> [String: Data] {
        try StoreName.check(names)
        var found: [String: Data] = [:]
        var rest = ArraySlice(names)
        while !rest.isEmpty {
            let batch = Array(rest.prefix(Self.namesPerRead))
            rest = rest.dropFirst(batch.count)
            let archive = try remote(Self.readCommand(path: path, names: batch), input: nil)
            guard !archive.isEmpty else { continue }
            let folder = try Self.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            try local(Self.tar, ["-xf", "-", "-C", folder.path], input: archive)
            for name in batch {
                let url = folder.appendingPathComponent(name)
                // Only plain files: a link in a stream from the server must not make the app read something else.
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                found[name] = try Data(contentsOf: url)
            }
        }
        return found
    }

    public func write(_ files: [String: Data]) async throws {
        try StoreName.check(files.keys)
        guard !files.isEmpty else { return }
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await FolderLocation(folder: folder).write(files)
        let archive = try local(Self.tar, ["-cf", "-", "-C", folder.path] + files.keys.sorted(), input: nil)
        _ = try remote(Self.writeCommand(path: path), input: archive)
    }

    private func remote(_ command: String, input: Data?) throws -> Data {
        let result = try run(Self.ssh, Self.sshArguments(host: host, command: command), input)
        guard result.status == 0 else { throw StoreError.ssh(Self.message(result.errors, status: result.status)) }
        return result.output
    }

    @discardableResult
    private func local(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        let result = try run(executable, arguments, input)
        guard result.status == 0 else { throw StoreError.ssh(Self.message(result.errors, status: result.status)) }
        return result.output
    }

    /// What ssh said, short enough for a message line.
    static func message(_ errors: Data, status: Int32) -> String {
        let text = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit \(status)" : String(text.prefix(300))
    }

    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ampbench-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Starts the program and reads both pipes while writing the input, so a full pipe cannot block either side.
    static let runProcess: Runner = { executable, arguments, input in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let inPipe = Pipe(), outPipe = Pipe(), errorPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        process.standardOutput = outPipe
        process.standardError = errorPipe
        try process.run()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "local.ampbench.store.process", attributes: .concurrent)
        let results = ProcessOutput()
        queue.async(group: group) { results.output = outPipe.fileHandleForReading.readDataToEndOfFile() }
        queue.async(group: group) { results.errors = errorPipe.fileHandleForReading.readDataToEndOfFile() }
        if let input {
            queue.async(group: group) {
                // The program may end before it read everything; that shows in its status. Without this, writing
                // into the closed pipe would end the whole app with SIGPIPE.
                _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus, results.output, results.errors)
    }

    /// Each field is written by one block and read after all of them ended.
    private final class ProcessOutput: @unchecked Sendable {
        var output = Data()
        var errors = Data()
    }
}
#endif
