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
    /// A new preset that is not saved yet.
    case draft
}

/// Storing a preset in a slot, waiting for the user to confirm.
struct StoreRequest: Identifiable {
    let id = UUID()
    let preset: SparkPreset
    let slot: Int
    /// Runs after the preset is stored and checked, with what the slot now holds.
    var then: (@MainActor (SparkPreset) -> Void)?
}

/// A store that a lost connection cut short. It is checked when the amp is back.
private struct InterruptedStore {
    let slot: Int
    let preset: SparkPreset
    let backup: SparkPreset
}

@MainActor
final class PresetsModel: ObservableObject {
    let link = SparkLink()
    let library: PresetLibrary
    let editor: EditorModel
    @Published private(set) var items: [SavedPreset] = []
    @Published private(set) var unreadable: [String] = []
    @Published private(set) var selection: Selection?
    /// A selection waiting for a decision about unsaved changes.
    @Published var pendingSelection: Selection?
    @Published var search = ""
    @Published var banner: Banner?
    @Published private(set) var isBusy = false
    @Published var storeRequest: StoreRequest?
    @Published var renameTarget: SavedPreset?
    @Published var renameText = ""
    /// The "Speichern unter" sheet, with the name to save under.
    @Published var saveAsName: String?
    @Published var showsTemplates = false
    private var bannerTask: Task<Void, Never>?
    private var changes: Set<AnyCancellable> = []
    private var interrupted: InterruptedStore?

    init(folder: URL = PresetLibrary.defaultFolder) {
        library = PresetLibrary(folder: folder)
        editor = EditorModel(link: link)
        editor.show = { [weak self] kind, text in self?.show(kind, text) }
        link.onAmpEvent = { [weak self] text in self?.show(.info, text) }
        link.onConnected = { [weak self] in self?.connected() }
        // Menus and buttons depend on the connection and the editor too.
        link.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &changes)
        editor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &changes)
        link.$slots.sink { [weak self] slots in self?.slotsChanged(slots) }.store(in: &changes)
    }

    func start(bluetooth: Bool = true) {
        reloadLibrary()
        if bluetooth { link.start() }
    }

    // MARK: Selection

    /// Selects something else. With unsaved changes, it asks first.
    func select(_ new: Selection?) {
        guard new != selection else { return }
        if editor.isModified, new != nil {
            pendingSelection = new
            return
        }
        apply(new)
    }

    /// The answer to the question about unsaved changes.
    func resolvePending(save: Bool) {
        guard let next = pendingSelection else { return }
        pendingSelection = nil
        if save, !saveOnMac() { return }
        apply(next)
    }

    private func apply(_ new: Selection?) {
        selection = new
        switch new {
        case .slot(let slot):
            if let preset = link.slots[slot] { editor.open(preset, from: .slot(slot)) } else { editor.close() }
        case .saved(let url):
            if let item = items.first(where: { $0.url == url }) {
                editor.open(item.file.preset, from: .saved(url))
            } else {
                editor.close()
            }
        case .draft, nil:
            if new == nil { editor.close() }
        }
    }

    private func slotsChanged(_ slots: [SparkPreset?]) {
        guard case .slot(let slot) = selection, let preset = slots[slot] else { return }
        if editor.source == .slot(slot) { editor.refresh(preset, from: .slot(slot)) } else { apply(selection) }
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
        if case .saved(let url) = selection, !items.contains(where: { $0.url == url }), !editor.isModified {
            apply(nil)
        }
    }

    var visibleItems: [SavedPreset] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.file.origin.localizedCaseInsensitiveContains(query)
                || $0.file.preset.effects.contains {
                    $0.name.localizedCaseInsensitiveContains(query)
                        || (ModelCatalog.known($0.name)?.name.localizedCaseInsensitiveContains(query) ?? false)
                }
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

    // MARK: New presets

    func newPreset(from template: PresetFactory.Template? = nil) {
        let preset = template.map { PresetFactory.make($0) } ?? PresetFactory.empty()
        openDraft(preset)
    }

    func duplicateCurrent() {
        guard let preset = editor.preset else { return }
        openDraft(PresetFactory.duplicate(preset))
    }

    private func openDraft(_ preset: SparkPreset) {
        if editor.isModified {
            show(.warning, "Sichere oder verwirf zuerst die Änderungen an „\(editor.preset?.name ?? "")“.")
            return
        }
        selection = .draft
        editor.open(preset, from: .draft)
        // A new preset counts as changed until it is saved, so it is not lost by accident.
        editor.markUnsaved()
    }

    // MARK: Saving

    /// Saves the edited preset on the Mac: into its own file, or as a new one for a slot or a draft.
    @discardableResult
    func saveOnMac() -> Bool {
        guard let preset = editor.editor?.current else { return false }
        if let problem = PresetRules.problem(withName: preset.name) {
            show(.error, problem)
            return false
        }
        do {
            if case .saved(let url) = editor.source, let item = items.first(where: { $0.url == url }) {
                let saved = try library.replace(item, with: preset)
                reloadLibrary()
                editor.markSaved(as: .saved(saved.url))
                selection = .saved(saved.url)
                show(.info, "„\(preset.name)“ ist auf dem Mac gesichert.")
            } else {
                var from = "Neu erstellt"
                if case .slot(let slot) = editor.source { from = origin(slot: slot) }
                let saved = try library.save(preset, origin: from)
                reloadLibrary()
                editor.markSaved(as: .saved(saved.url))
                selection = .saved(saved.url)
                show(.info, "„\(preset.name)“ ist als neues Preset auf dem Mac gesichert.")
            }
            return true
        } catch {
            show(.error, "Das Preset konnte nicht gesichert werden: \(error.localizedDescription)")
            return false
        }
    }

    func beginSaveAs() {
        guard let preset = editor.preset else { return }
        saveAsName = PresetFactory.fit(preset.name + " 2")
    }

    /// Saves a copy under a new name and keeps editing the copy.
    func commitSaveAs() {
        guard let name = saveAsName, let preset = editor.editor?.current else { return }
        if let problem = PresetRules.problem(withName: name) {
            show(.error, problem)
            return
        }
        saveAsName = nil
        let copy = PresetFactory.duplicate(preset, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let saved = try library.save(copy, origin: "Gesichert als Kopie von „\(preset.name)“")
            reloadLibrary()
            editor.open(copy, from: .saved(saved.url))
            selection = .saved(saved.url)
            show(.info, "„\(copy.name)“ ist auf dem Mac gesichert.")
        } catch {
            show(.error, "Das Preset konnte nicht gesichert werden: \(error.localizedDescription)")
        }
    }

    /// Asks before the edited preset goes into a slot.
    func askToStoreEdited(in slot: Int) {
        guard canUseAmp, let preset = editor.editor?.current else { return }
        if let problem = PresetRules.problem(withName: preset.name) {
            show(.error, problem)
            return
        }
        let source = editor.source
        storeRequest = StoreRequest(preset: preset, slot: slot) { [weak self] stored in
            guard let self, source == .slot(slot) else { return }
            self.editor.markSaved(stored, as: .slot(slot))
        }
    }

    // MARK: Amp

    var canUseAmp: Bool { link.status == .connected && !isBusy }

    func play(slot: Int) {
        guard canUseAmp, link.activeSlot != slot || link.tryingOut != nil || link.isEditingLive else { return }
        run { try await self.link.select(slot: slot) }
    }

    /// Saves what a slot holds on the Mac. A preset with the same settings already saved is not saved twice.
    func backUp(slot: Int) {
        guard let preset = link.slots[slot] else { return }
        if let existing = library.existing(preset) {
            show(.info, "„\(preset.name)“ ist schon auf dem Mac gesichert, als „\(existing.url.deletingPathExtension().lastPathComponent)“.")
            return
        }
        do {
            _ = try library.save(preset, origin: origin(slot: slot))
            reloadLibrary()
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

    func askToStore(_ item: SavedPreset, in slot: Int) {
        guard canUseAmp else { return }
        storeRequest = StoreRequest(preset: item.file.preset, slot: slot)
    }

    /// Backs up what the slot holds now, read fresh from the amp, then stores the preset there and checks it.
    func store(_ request: StoreRequest) {
        storeRequest = nil
        let slot = request.slot
        let preset = request.preset
        run {
            let current = try await self.link.currentPreset(in: slot)
            if self.library.existing(current) == nil {
                _ = try self.library.save(current, origin: "\(self.origin(slot: slot)), vor dem Überschreiben",
                                          isBackup: true)
                self.reloadLibrary()
            }
            self.interrupted = InterruptedStore(slot: slot, preset: preset, backup: current)
            do {
                try await self.link.store(preset, in: slot)
            } catch LinkError.notConnected {
                self.show(.error, "Die Verbindung brach beim Speichern auf Platz \(slot + 1) ab. Sobald der Verstärker wieder da ist, prüft die App, was dort liegt. Die Sicherung von „\(current.name)“ ist auf dem Mac.")
                return
            }
            self.interrupted = nil
            guard let stored = self.link.slots[slot] else { return }
            request.then?(stored)
            self.show(.info, "„\(preset.name)“ ist auf Platz \(slot + 1) gespeichert und geprüft. Das bisherige „\(current.name)“ liegt als Sicherung auf dem Mac.")
        }
    }

    func reloadAmp() {
        guard canUseAmp else { return }
        run { await self.link.loadAll() }
    }

    private func connected() {
        if let interrupted, let now = link.slots[interrupted.slot] {
            self.interrupted = nil
            let slot = interrupted.slot + 1
            if now == interrupted.preset {
                show(.info, "Platz \(slot) enthält „\(interrupted.preset.name)“ vollständig. Das Speichern ist trotz des Abbruchs angekommen.")
            } else if now == interrupted.backup {
                show(.warning, "Platz \(slot) enthält noch das bisherige „\(interrupted.backup.name)“. Gespeichert wurde nichts.")
            } else {
                show(.error, "Platz \(slot) enthält „\(now.name)“, weder das neue noch das bisherige Preset. Die Sicherung von „\(interrupted.backup.name)“ liegt auf dem Mac.")
            }
        }
        editor.reconnected()
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
            if editor.source == .saved(item.url) {
                editor.renameSaved(to: renamed.name, at: renamed.url)
                selection = .saved(renamed.url)
            }
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func trash(_ item: SavedPreset? = nil) {
        guard let item = item ?? selectedItem else { return }
        do {
            let place = try library.trash(item)
            if editor.source == .saved(item.url) {
                editor.close()
                selection = nil
            }
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
            select(.saved(original))
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
