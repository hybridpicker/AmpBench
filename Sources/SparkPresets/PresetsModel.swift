import AppKit
import Combine
import Foundation
import SparkControl

struct Banner: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    let id = UUID()
    let kind: Kind
    let text: String
    var undo: (@MainActor () -> Void)?

    static func == (lhs: Banner, rhs: Banner) -> Bool { lhs.id == rhs.id }
}

enum Selection: Hashable {
    case slot(Int)
    case saved(URL)
}

struct StoreRequest: Identifiable {
    let id = UUID()
    let item: SavedPreset
    let slot: Int
}

@MainActor
final class PresetsModel: ObservableObject {
    let link = SparkLink()
    let library: PresetLibrary
    @Published private(set) var items: [SavedPreset] = []
    @Published private(set) var unreadable: [String] = []
    @Published var selection: Selection?
    @Published var search = ""
    @Published var banner: Banner?
    @Published private(set) var isBusy = false
    @Published var storeRequest: StoreRequest?
    @Published var renameTarget: SavedPreset?
    @Published var renameText = ""
    private var bannerTask: Task<Void, Never>?
    private var linkChanges: AnyCancellable?

    init(folder: URL = PresetLibrary.defaultFolder) {
        library = PresetLibrary(folder: folder)
        link.onAmpEvent = { [weak self] text in self?.show(.info, text) }
        // Menus and buttons depend on the connection too.
        linkChanges = link.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func start() {
        reloadLibrary()
        link.start()
    }

    // MARK: Library

    func reloadLibrary() {
        do {
            try library.reload()
        } catch {
            show(.error, "Der Ordner „\(library.folder.path)“ ist nicht lesbar: \(error.localizedDescription)")
        }
        items = library.items
        unreadable = library.unreadable
        if case .saved(let url) = selection, !items.contains(where: { $0.url == url }) { selection = nil }
    }

    var visibleItems: [SavedPreset] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.file.origin.localizedCaseInsensitiveContains(query)
                || $0.file.preset.effects.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    var selectedItem: SavedPreset? {
        guard case .saved(let url) = selection else { return nil }
        return items.first { $0.url == url }
    }

    var selectedSlot: Int? {
        guard case .slot(let slot) = selection else { return nil }
        return slot
    }

    func origin(slot: Int) -> String {
        "Platz \(slot + 1) · \(link.deviceName ?? "Spark")"
    }

    // MARK: Amp

    var canUseAmp: Bool { link.status == .connected && !isBusy }

    func play(slot: Int) {
        selection = .slot(slot)
        guard canUseAmp, link.activeSlot != slot || link.tryingOut != nil else { return }
        run { try await self.link.select(slot: slot) }
    }

    /// Saves what a slot holds on the Mac. A preset with the same settings already saved is not saved twice.
    func backUp(slot: Int) {
        guard let preset = link.slots[slot] else { return }
        if let existing = library.existing(preset) {
            show(.info, "„\(preset.name)“ ist schon auf dem Mac gesichert, als „\(existing.url.deletingPathExtension().lastPathComponent)“.")
            selection = .saved(existing.url)
            return
        }
        do {
            let saved = try library.save(preset, origin: origin(slot: slot))
            reloadLibrary()
            selection = .saved(saved.url)
            show(.info, "„\(preset.name)“ ist auf dem Mac gesichert.")
        } catch {
            show(.error, "Das Preset konnte nicht gesichert werden: \(error.localizedDescription)")
        }
    }

    func backUpSelection() {
        if let slot = selectedSlot { backUp(slot: slot) }
    }

    func tryOut(_ item: SavedPreset) {
        guard canUseAmp else { return }
        run {
            try await self.link.tryOut(item.file.preset)
            self.show(.info, "„\(item.name)“ spielt zum Ausprobieren. Gespeichert ist nichts, ein Preset-Wechsel beendet es.")
        }
    }

    func tryOutSelection() {
        if let item = selectedItem { tryOut(item) }
    }

    func askToStore(_ item: SavedPreset, in slot: Int) {
        guard canUseAmp else { return }
        storeRequest = StoreRequest(item: item, slot: slot)
    }

    /// Backs up what the slot holds now, read fresh from the amp, then stores the preset there and checks it.
    func store(_ request: StoreRequest) {
        storeRequest = nil
        let slot = request.slot
        let preset = request.item.file.preset
        run {
            let current = try await self.link.currentPreset(in: slot)
            if self.library.existing(current) == nil {
                _ = try self.library.save(current, origin: "\(self.origin(slot: slot)), vor dem Überschreiben",
                                          isBackup: true)
                self.reloadLibrary()
            }
            try await self.link.store(preset, in: slot)
            self.show(.info, "„\(preset.name)“ ist auf Platz \(slot + 1) gespeichert und geprüft. Das bisherige „\(current.name)“ liegt als Sicherung auf dem Mac.")
        }
    }

    func reloadAmp() {
        guard canUseAmp else { return }
        run { await self.link.loadAll() }
    }

    // MARK: Saved presets

    func beginRename(_ item: SavedPreset? = nil) {
        guard let item = item ?? selectedItem else { return }
        renameText = item.name
        renameTarget = item
    }

    func commitRename() {
        guard let item = renameTarget else { return }
        renameTarget = nil
        do {
            let renamed = try library.rename(item, to: renameText)
            reloadLibrary()
            selection = .saved(renamed.url)
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func trash(_ item: SavedPreset? = nil) {
        guard let item = item ?? selectedItem else { return }
        do {
            let place = try library.trash(item)
            reloadLibrary()
            show(.info, "„\(item.name)“ liegt im Papierkorb.", undo: place.map { trashed in
                { [weak self] in self?.restore(from: trashed, to: item.url) }
            })
        } catch {
            show(.error, "„\(item.name)“ konnte nicht in den Papierkorb: \(error.localizedDescription)")
        }
    }

    private func restore(from trashed: URL, to original: URL) {
        do {
            try FileManager.default.moveItem(at: trashed, to: original)
            reloadLibrary()
            selection = .saved(original)
            banner = nil
        } catch {
            show(.error, "Die Datei konnte nicht zurückgeholt werden: \(error.localizedDescription)")
        }
    }

    func reveal(_ item: SavedPreset? = nil) {
        if let item = item ?? selectedItem {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([library.folder])
        }
    }

    // MARK: Helpers

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await work()
            } catch {
                show(.error, error.localizedDescription)
            }
        }
    }

    func show(_ kind: Banner.Kind, _ text: String, undo: (@MainActor () -> Void)? = nil) {
        let banner = Banner(kind: kind, text: text, undo: undo)
        self.banner = banner
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        bannerTask?.cancel()
        guard kind != .error else { return }
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(undo == nil ? 6 : 10))
            guard !Task.isCancelled, self.banner == banner else { return }
            self.banner = nil
        }
    }
}
