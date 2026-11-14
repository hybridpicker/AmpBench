import AmpText
import Foundation
import SoundStore
import SparkControl

/// The sound store as the area Presets shows it: whether it is set up, what it did last, and syncing.
///
/// The store keeps every sound of this device encrypted in a place the user chose, and brings sounds from the other
/// devices here. It syncs when the app starts, when it comes to the front, a little after sounds changed, and on
/// request. The key never leaves the keychain except when the user asks to see it.
@MainActor
final class StoreModel: ObservableObject {
    enum State: Equatable {
        case notSetUp
        case idle
        case syncing
        case failed(String)
    }

    @Published private(set) var state = State.notSetUp
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSummary: String?
    @Published private(set) var settings: StoreSettings?
    @Published private(set) var hasKey = false

    let profile: StoreProfile
    private let folder: URL
    /// Called on the main actor after a sync changed files here, so the library reads its folder again.
    var onChanged: (() -> Void)?
    /// Says what a sync did, when it did something or failed. Automatic syncs that change nothing stay silent.
    var report: ((_ isError: Bool, _ text: String) -> Void)?

    private var task: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var syncedSignature: String?
    private var lastAttempt = Date.distantPast
    private var wantsAnother = false

    init(folder: URL, profile: StoreProfile) {
        self.folder = folder
        self.profile = profile
        refresh()
    }

    var isReady: Bool { settings != nil && hasKey }

    private func refresh() {
        settings = profile.settings
        hasKey = profile.hasKey
        lastSync = profile.lastSync
        if state != .syncing {
            if !isReady { state = .notSetUp } else if case .failed = state {} else { state = .idle }
        }
    }

    // MARK: Setting up

    /// The key's public half, safe to show: it only encrypts.
    var publicKey: String? { profile.identity?.recipient }

    func createKey() throws {
        try profile.createKey()
        refresh()
    }

    func useKey(_ text: String) throws {
        try profile.useKey(text)
        syncedSignature = nil
        refresh()
    }

    /// The key as text, for writing it down or carrying it to another device. Only read when the user asks.
    func revealKey() -> String? { profile.identity?.text }

    func save(_ settings: StoreSettings, password: String?) throws {
        // Fails here, with a clear text, instead of at the first sync.
        _ = try settings.location(password: password)
        if profile.settings != settings {
            // Another place is another store: what was in step with the old one says nothing about it.
            try? FileManager.default.removeItem(at: profile.stateURL)
            syncedSignature = nil
        }
        profile.settings = settings
        if settings.kind == .http { try profile.setPassword(password) }
        state = .idle
        refresh()
    }

    func disconnect() {
        task?.cancel()
        task = nil
        scheduled?.cancel()
        profile.disconnect()
        syncedSignature = nil
        lastSummary = nil
        state = .notSetUp
        refresh()
    }

    // MARK: Syncing

    /// Syncs now. `quiet` is for the automatic syncs: they speak up only when something changed or failed.
    func sync(quiet: Bool = false) {
        guard isReady else { return }
        guard task == nil else {
            wantsAnother = true
            return
        }
        scheduled?.cancel()
        let before = state
        state = .syncing
        lastAttempt = Date()
        let profile = profile, folder = folder
        task = Task { [weak self] in
            let result: Result<SyncReport, Error>
            do {
                result = .success(try await profile.sync(folder: folder) { url in
                    try PresetLibrary.discard(url, in: folder)
                })
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            task = nil
            switch result {
            case .success(let report):
                state = .idle
                lastSync = profile.lastSync
                lastSummary = report.summary
                if !report.downloaded.isEmpty || !report.removedLocally.isEmpty { onChanged?() }
                syncedSignature = Self.signature(of: folder)
                if !quiet || !report.isEmpty { self.report?(false, report.summary) }
            case .failure(let error):
                let text = tr("The sound store could not be synced: %@", error.localizedDescription)
                // A quiet sync that fails the same way again stays quiet: the lamp shows it.
                let repeated = before == .failed(text)
                state = .failed(text)
                if !quiet || !repeated { self.report?(true, text) }
            }
            if wantsAnother {
                wantsAnother = false
                sync(quiet: true)
            }
        }
    }

    /// The app started or came to the front: sync, but not more often than every five minutes.
    func syncIfDue() {
        guard isReady, Date().timeIntervalSince(lastAttempt) > 300 else { return }
        sync(quiet: true)
    }

    /// The library read its folder: when files differ from the last sync, sync a little later, so a run of edits
    /// becomes one sync.
    func libraryChanged() {
        guard isReady, task == nil else { return }
        guard let syncedSignature, syncedSignature != Self.signature(of: folder) else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.sync(quiet: true)
        }
    }

    /// Names, sizes and dates of the sound files, enough to see that something changed.
    static func signature(of folder: URL) -> String {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles]) else { return "" }
        var lines: [String] = []
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let date = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            lines.append("\(file.path)|\(values.fileSize ?? 0)|\(date)")
        }
        return lines.sorted().joined(separator: "\n")
    }
}
