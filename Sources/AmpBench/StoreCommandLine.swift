import AmpText
import Foundation
import SoundStore
import SparkControl
import SparkCore

/// Headless commands for the sound store, for a first setup, a script or a scheduled backup:
///   --store-setup folder <path>          keep the encrypted sounds in a folder (also one a cloud drive syncs)
///   --store-setup ssh <host> <path>      keep them on a server, through this Mac's ssh
///   --store-setup https <url> [user]     keep them below an HTTPS address; the password is read from standard input
///   --store-key new                      make this device's key; prints only its public half
///   --store-key set                      take a key from standard input (the key of a store you already have)
///   --store-key show                     print the key, to write it down or to enter it on another device
///   --store-sync                         bring the presets folder and the store in step, both ways
///   --store-verify                       read every sound back from the store, open it and compare it; changes nothing
///   --store-status                       where the store is, when it last synced, how many sounds it holds
/// With `--library <folder>` they work on that test library's presets and a store profile apart from the real one.
enum StoreCommandLine {
    /// The exit status, or nil when the arguments are not one of these commands.
    static func run(_ arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(where: { $0.hasPrefix("--store-") }) else { return nil }
        let rest = Array(arguments[(index + 1)...]).prefix { !$0.hasPrefix("--") }.map { $0 }
        let library = arguments.firstIndex(of: "--library").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let folder: URL, profile: StoreProfile
        if let library, !library.isEmpty {
            folder = URL(fileURLWithPath: library, isDirectory: true).appendingPathComponent("Presets", isDirectory: true)
            profile = .testing(stateFolder: folder)
        } else {
            folder = StudioFolders.standard.presets
            profile = .standard
        }
        do {
            switch arguments[index] {
            case "--store-setup": return try setup(rest, profile)
            case "--store-key": return try key(rest, profile)
            case "--store-sync": return try sync(folder, profile)
            case "--store-verify": return try verify(folder, profile)
            case "--store-status": return try status(folder, profile)
            default:
                print("usage: --store-setup | --store-key | --store-sync | --store-verify | --store-status")
                return 64
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    private static func setup(_ arguments: [String], _ profile: StoreProfile) throws -> Int32 {
        let settings: StoreSettings
        var password: String?
        switch (arguments.first, arguments.count) {
        case ("folder", 2):
            let path = (arguments[1] as NSString).expandingTildeInPath
            settings = StoreSettings(kind: .folder, folderPath: path)
        case ("ssh", 3):
            settings = StoreSettings(kind: .ssh, host: arguments[1], path: arguments[2])
        case ("https", 2), ("https", 3):
            let user = arguments.count == 3 ? arguments[2] : nil
            settings = StoreSettings(kind: .http, url: arguments[1], user: user)
            // Never an argument: other processes can read a command line.
            if user != nil { password = readLine(strippingNewline: true) }
        default:
            print("usage: --store-setup folder <path> | ssh <host> <path> | https <url> [user]  (password on standard input)")
            return 64
        }
        // Throws for a server name, path or address that cannot be used.
        _ = try settings.location(password: password)
        if profile.settings != settings { try? FileManager.default.removeItem(at: profile.stateURL) }
        profile.settings = settings
        if settings.kind == .http { try profile.setPassword(password) }
        print(tr("The sound store is set up: %@.", settings.summary))
        if !profile.hasKey { print(tr("This device has no key yet: --store-key new makes one, --store-key set takes one you have.")) }
        return 0
    }

    private static func key(_ arguments: [String], _ profile: StoreProfile) throws -> Int32 {
        switch arguments.first {
        case "new":
            let identity = try profile.createKey()
            print(tr("A new key is in the keychain. Its public half: %@", identity.recipient))
            print(tr("Write the key itself down: --store-key show prints it, and so does “Show key” in the app. Without it nobody can read the store."))
        case "set":
            guard let text = readLine(strippingNewline: true) else { return 64 }
            let identity = try profile.useKey(text)
            print(tr("The key is in the keychain. Its public half: %@", identity.recipient))
        case "show":
            guard let identity = profile.identity else { throw StoreProfileError.noKey }
            print(identity.text)
        default:
            print("usage: --store-key new | set (key on standard input) | show")
            return 64
        }
        return 0
    }

    private static func sync(_ folder: URL, _ profile: StoreProfile) throws -> Int32 {
        let report = try wait { try await profile.sync(folder: folder) { url in try PresetLibrary.discard(url, in: folder) } }
        print(report.summary)
        for (label, names) in [(tr("stored"), report.uploaded), (tr("fetched"), report.downloaded),
                               (tr("removed here"), report.removedLocally),
                               (tr("removed in the store"), report.markedDeleted)] {
            for name in names { print("  \(label): \(name)") }
        }
        return 0
    }

    private static func verify(_ folder: URL, _ profile: StoreProfile) throws -> Int32 {
        let report = try wait { try await profile.verify(folder: folder) }
        print(report.summary)
        for (label, names) in [(tr("missing in the store"), report.missing), (tr("damaged in the store"), report.damaged),
                               (tr("differs here"), report.differing), (tr("only in the store"), report.notHere),
                               (tr("only here"), report.notStored)] {
            for name in names { print("  \(label): \(name)") }
        }
        return report.isRestorable ? 0 : 1
    }

    private static func status(_ folder: URL, _ profile: StoreProfile) throws -> Int32 {
        guard let settings = profile.settings else {
            print(tr("The sound store is not set up on this device."))
            return 0
        }
        print(tr("Place: %@", settings.summary))
        print(profile.hasKey ? tr("Key: in the keychain") : tr("Key: none on this device"))
        if let date = profile.lastSync {
            print(tr("Last sync: %@", ISO8601DateFormatter().string(from: date)))
        } else {
            print(tr("Last sync: never"))
        }
        print(tr("Sounds folder: %@", folder.path))
        return 0
    }

    /// Runs an async call from the command line and waits for it.
    private static func wait<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

/// Carries a result out of a task. Written once, and read only after the semaphore said so.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
