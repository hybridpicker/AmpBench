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
    let link: SparkLink
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
    // KI-Sound: a description in words becomes a recipe over Ollama's cloud API.
    @Published var showsAI = false
    @Published var aiRequest = ""
    @Published var aiModel: String = "gpt-oss:120b" {
        didSet { if !aiModel.isEmpty { AISetting.save(AISetting.modelKey, aiModel) } }
    }
    @Published var aiAPIKey: String = "" {
        didSet { AIKeyStore.save(aiAPIKey) }
    }
    /// Ollama Cloud counts as connected once an API key is stored.
    var aiConnected: Bool { !aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// True while the variants for a wish are being written.
    @Published private(set) var aiIsGenerating = false
    /// The sounds on offer, from the moment they are asked for, and the wish they answer.
    @Published private(set) var aiOffers: [AIOffer] = []
    @Published private(set) var aiAsked = ""
    /// Why a request could not start or brought nothing back. Shows inside the sheet.
    @Published private(set) var aiError: String?
    @Published private(set) var aiModelChoices: [String] = []
    /// The last wishes, newest first, kept on this Mac only.
    @Published private(set) var aiHistory: [String] = []
    /// Which offered sound plays on the amp now, which ones were heard, and why playing failed.
    @Published private(set) var aiListening: Int?
    @Published private(set) var aiHeard: Set<Int> = []
    @Published private(set) var aiPlayNote: String?
    private var aiTask: Task<Void, Never>?
    private var aiOfferTasks: [Int: Task<Void, Never>] = [:]

    func loadAIModels() {
        guard aiModelChoices.isEmpty else { return }
        Task { @MainActor [weak self] in
            if let names = try? await OllamaCloud.availableModels() { self?.aiModelChoices = names }
        }
    }
    private var bannerTask: Task<Void, Never>?
    private var changes: Set<AnyCancellable> = []
    private var interrupted: InterruptedStore?
    /// The last preset played with "Ausprobieren", to know what the amp plays while `link.tryingOut` is set.
    private var lastTriedOut: SparkPreset?
    /// A device chosen while a sound plays that ending the connection would drop, waiting for a decision.
    @Published var pendingDevice: UUID?
    /// "Trennen" asked while such a sound plays.
    @Published var pendingDisconnect = false
    /// Called when the device dropped a sound that was not stored, because the connection ended (the NEO).
    var onTemporaryLost: ((String) -> Void)?

    init(folder: URL = PresetLibrary.defaultFolder, link: SparkLink? = nil) {
        self.link = link ?? SparkLink()
        library = PresetLibrary(folder: folder)
        editor = EditorModel(link: self.link)
        editor.show = { [weak self] kind, text in self?.show(kind, text) }
        self.link.onAmpEvent = { [weak self] text in self?.show(.info, text) }
        self.link.onAmpSelected = { [weak self] slot in self?.ampSelected(slot) }
        self.link.onConnected = { [weak self] byItself in self?.connected(byItself: byItself) }
        self.link.onTemporaryLost = { [weak self] name in self?.temporaryLost(on: name) }
        // Menus and buttons depend on the connection and the editor too.
        self.link.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &changes)
        editor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &changes)
        self.link.$slots.sink { [weak self] slots in self?.slotsChanged(slots) }.store(in: &changes)
        // "qwen3:32b" was the first default but is not offered by the cloud.
        let storedModel = AISetting.load(AISetting.modelKey, default: AISetting.defaultModel)
        aiModel = storedModel == "qwen3:32b" ? AISetting.defaultModel : storedModel
        // Earlier versions kept the key in the preferences file; move it into the Keychain and delete the copy.
        let legacy = AISetting.load("AI Sound API Key", default: "")
        if !legacy.isEmpty {
            AIKeyStore.save(legacy)
            UserDefaults.standard.removeObject(forKey: "AI Sound API Key")
        }
        AIKeyStore.bindToThisMac()
        aiAPIKey = AIKeyStore.load()
        aiHistory = UserDefaults.standard.stringArray(forKey: AISetting.historyKey) ?? []
    }

    func start(bluetooth: Bool = true) {
        reloadLibrary()
        if bluetooth { link.start() }
    }

    // MARK: Selection

    /// Selects something else and plays it: a slot by switching the amp to it, a preset from the Mac on the
    /// temporary place, which never touches a slot. With unsaved changes, it asks first.
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

    private func apply(_ new: Selection?, play: Bool = true) {
        selection = new
        switch new {
        case .slot(let slot):
            if let preset = link.slots[slot] { editor.open(preset, from: .slot(slot)) } else { editor.close() }
            if play { self.play(slot: slot) }
        case .saved(let url):
            if let item = items.first(where: { $0.url == url }) {
                editor.open(item.file.preset, from: .saved(url))
                // Clicking through the list sends only the last one: the queue keeps only the newest whole preset.
                if play, editor.isLiveEnabled { editor.playNow() }
            } else {
                editor.close()
            }
        case .draft, nil:
            if new == nil { editor.close() }
        }
    }

    private func slotsChanged(_ slots: [SparkPreset?]) {
        guard case .slot(let slot) = selection, let preset = slots[slot] else { return }
        if editor.source == .slot(slot) { editor.refresh(preset, from: .slot(slot)) } else { apply(selection, play: false) }
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
        "\(link.profile.slotName(slot)) · \(link.profile.displayName)"
    }

    // MARK: Devices

    /// True when ending the connection would drop a sound that plays without being stored anywhere: the editor's
    /// unsaved state or a tried-out preset that is not in the library.
    var temporarySoundWouldBeLost: Bool {
        guard link.status == .connected else { return false }
        return Self.wouldLoseSound(profile: link.profile, isEditingLive: link.isEditingLive,
                                   editorUnsaved: editor.isModified || selection == .draft,
                                   triedOutUnsaved: link.tryingOut != nil
                                       && (lastTriedOut.map { library.existing($0) == nil } ?? false))
    }

    /// Whether ending the connection drops a sound that exists nowhere else: only on a device that loses its
    /// temporary place then (the NEO, and the MINI until checked), and only for a sound not saved on the Mac.
    nonisolated static func wouldLoseSound(profile: DeviceProfile, isEditingLive: Bool, editorUnsaved: Bool,
                                           triedOutUnsaved: Bool) -> Bool {
        guard profile.losesTemporaryOnDisconnect else { return false }
        return isEditingLive ? editorUnsaved : triedOutUnsaved
    }

    /// Connects to another device. Asks first when the current one would drop an unsaved sound.
    func chooseDevice(_ id: UUID) {
        guard id != link.chosenID || link.status != .connected else { return }
        if temporarySoundWouldBeLost {
            pendingDevice = id
            return
        }
        link.choose(id)
    }

    /// Ends the connection. Asks first when the device would drop an unsaved sound.
    func disconnect() {
        if temporarySoundWouldBeLost {
            pendingDisconnect = true
            return
        }
        link.stop()
    }

    /// The answer to "Vorher als Preset sichern?": saves what plays, then goes on, or goes on without saving.
    func resolveDeviceChange(save: Bool) {
        let device = pendingDevice
        let disconnecting = pendingDisconnect
        pendingDevice = nil
        pendingDisconnect = false
        if save {
            if link.isEditingLive {
                guard saveOnMac() else { return }
            } else if let preset = lastTriedOut {
                do {
                    _ = try library.save(preset, origin: "Vorübergehend gespielt · \(link.profile.displayName)")
                    reloadLibrary()
                } catch {
                    show(.error, "Das Preset konnte nicht gesichert werden: \(error.localizedDescription)")
                    return
                }
            }
        }
        if disconnecting { link.stop() } else if let device { link.choose(device) }
    }

    private func temporaryLost(on name: String) {
        show(.warning, "\(name) ist getrennt und spielt wieder seinen gespeicherten Platz. Der vorübergehende Sound ist dort weg. Beim nächsten Verbinden liest Studio nach, was spielt.")
        onTemporaryLost?(name)
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
        if editor.isLiveEnabled { editor.playNow() }
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
        guard canUse(.store), let preset = editor.editor?.current else { return }
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

    /// True when the connected device allows this and nothing else runs.
    func canUse(_ capability: DeviceProfile.Capabilities) -> Bool { canUseAmp && link.profile.can(capability) }

    /// Switches the amp to a slot, in turn with live changes.
    func play(slot: Int) {
        editor.play(slot: slot)
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
        guard canUse(.playTemporary) else { return }
        lastTriedOut = item.file.preset
        run {
            try await self.link.tryOut(item.file.preset)
            self.show(.info, "„\(item.name)“ spielt zum Ausprobieren. Gespeichert ist nichts, ein Preset-Wechsel beendet es.")
        }
    }

    /// Plays a preset that is not in the library, such as a take's sound, on the temporary place 7F. `report` gets
    /// nil when it plays, or what went wrong, for showing it where the request came from.
    func tryOut(_ preset: SparkPreset, report: (@MainActor (String?) -> Void)? = nil) {
        guard link.status == .connected else {
            let text = "Der Verstärker ist nicht verbunden. Verbinde ihn, dann spielt der Sound auf dem vorübergehenden Platz."
            show(.warning, text)
            report?(text)
            return
        }
        guard link.profile.can(.playTemporary) else {
            let text = "\(link.profile.displayName) spielt keinen Sound von Spark Studio. Er wird nur mitgelesen."
            show(.warning, text)
            report?(text)
            return
        }
        guard canUseAmp else {
            report?("Der Verstärker ist gerade beschäftigt. Versuch es gleich noch einmal.")
            return
        }
        lastTriedOut = preset
        run {
            do {
                try await self.link.tryOut(preset)
            } catch {
                report?(error.localizedDescription)
                throw error
            }
            self.show(.info, "„\(preset.name)“ spielt zum Ausprobieren. Gespeichert ist nichts, ein Preset-Wechsel beendet es.")
            report?(nil)
        }
    }

    /// Opens a preset from elsewhere, such as a take's sound, as a new preset that can be saved.
    func openCopy(_ preset: SparkPreset) {
        openDraft(preset)
    }

    /// What the amp plays now, as far as the app knows, and from which slot. Read from memory only, never asked of
    /// the amp, so it costs nothing at the start of a recording.
    var heardPreset: (preset: SparkPreset, slot: Int?)? {
        guard link.status == .connected else { return nil }
        // The editor's state on the temporary place, including the saved state while comparing (A/B).
        if link.isEditingLive, let preset = editor.preset { return (preset, nil) }
        // A preset tried out without the editor.
        if let name = link.tryingOut, let preset = lastTriedOut, preset.name == name { return (preset, nil) }
        // A stored slot: what is stored there, whatever the editor shows.
        if let slot = link.activeSlot, let preset = link.slots[slot] { return (preset, slot + 1) }
        return nil
    }

    func askToStore(_ item: SavedPreset, in slot: Int) {
        guard canUse(.store) else { return }
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
                self.show(.error, "Die Verbindung brach beim Speichern auf \(self.link.profile.slotName(slot)) ab. Sobald der Verstärker wieder da ist, prüft die App, was dort liegt. Die Sicherung von „\(current.name)“ ist auf dem Mac.")
                return
            }
            self.interrupted = nil
            guard let stored = self.link.slots[slot] else { return }
            request.then?(stored)
            self.show(.info, "„\(preset.name)“ ist auf \(self.link.profile.slotName(slot)) gespeichert und geprüft. Das bisherige „\(current.name)“ liegt als Sicherung auf dem Mac.")
        }
    }

    /// The amp's own preset button: the app follows, unless the editor holds unsaved changes.
    private func ampSelected(_ slot: Int) {
        guard !editor.isModified, selection != .slot(slot) else { return }
        apply(.slot(slot), play: false)
    }

    func reloadAmp() {
        guard canUse(.read) else { return }
        run { await self.link.loadAll() }
    }

    private func connected(byItself: Bool) {
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
        // Only a connection that came back by itself gets the edit again. After "Trennen" or another device, what
        // the device plays is read, not assumed.
        if byItself { editor.reconnected() }
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

    // MARK: AI-Sound

    private enum AISetting {
        static let modelKey = "AI Sound Model"
        static let historyKey = "AI Sound History"
        static let defaultModel = "gpt-oss:120b"
        static func load(_ key: String, default defaultValue: String) -> String {
            let value = UserDefaults.standard.string(forKey: key) ?? ""
            return value.isEmpty ? defaultValue : value
        }
        static func save(_ key: String, _ value: String) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    /// One offered sound in the sheet, from the moment it is asked for until one is kept.
    struct AIOffer: Identifiable {
        enum State {
            case writing
            case ready(SoundRecipe)
            case failed(String)
        }

        let id: Int
        var state: State
        /// The quick changes made to it so far, kept as tags when it is kept.
        var adjustments: [SoundAI.Adjustment] = []
        /// The quick change on its way, if one is.
        var refining: SoundAI.Adjustment?
        /// What the last quick change had to say, or why it failed.
        var note: String?

        var recipe: SoundRecipe? {
            if case .ready(let recipe) = state { return recipe }
            return nil
        }
    }

    private var aiChat: SoundAI.Chat { SoundAI.ollama(model: aiModel, apiKey: aiAPIKey) }

    private func updateOffer(_ id: Int, _ change: (inout AIOffer) -> Void) {
        guard let index = aiOffers.firstIndex(where: { $0.id == id }) else { return }
        change(&aiOffers[index])
    }

    /// Asks Ollama for a few sounds for the description. Each one shows as soon as it is written; nothing is saved
    /// until one is kept. A wish with personal data in it is refused before anything is sent.
    func generateAISound() {
        guard aiConnected, !aiIsGenerating else { return }
        let request: String
        let stream: AsyncStream<SoundAI.VariantEvent>
        do {
            request = try SoundAI.checkedRequest(aiRequest)
            stream = try SoundAI.variants(request: request, chat: aiChat)
        } catch {
            aiError = SoundAI.message(for: error)
            return
        }
        cancelAI()
        aiError = nil
        aiAsked = request
        aiListening = nil
        aiHeard = []
        aiPlayNote = nil
        aiOffers = SoundAI.variantHints.indices.map { AIOffer(id: $0, state: .writing) }
        aiIsGenerating = true
        aiTask = Task { @MainActor [weak self] in
            var remembered = false
            for await event in stream {
                guard let self else { return }
                switch event {
                case .ready(let index, let recipe):
                    self.updateOffer(index) { $0.state = .ready(recipe) }
                    if !remembered { remembered = true; self.rememberAIRequest(request) }
                case .failed(let index, let error):
                    let text = SoundAI.message(for: error) ?? "Abgebrochen."
                    self.updateOffer(index) { $0.state = .failed(text) }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.aiTask = nil
            self.aiIsGenerating = false
            let writing = self.aiOffers.contains { offer in
                if case .writing = offer.state { return true }
                return false
            }
            guard !writing, self.aiOffers.allSatisfy({ $0.recipe == nil }) else { return }
            // Nothing worked: back to the description, with the first reason.
            let reasons = self.aiOffers.compactMap { offer -> String? in
                if case .failed(let text) = offer.state { return text }
                return nil
            }
            self.aiOffers = []
            self.aiError = reasons.first ?? "Es kam kein Vorschlag zurück. Versuch es noch einmal."
        }
    }

    /// Stops every request on its way. Sounds already offered stay; the ones still being written are dropped.
    func cancelAI() {
        aiTask?.cancel()
        aiTask = nil
        aiIsGenerating = false
        for task in aiOfferTasks.values { task.cancel() }
        aiOfferTasks = [:]
        aiOffers = aiOffers.compactMap { offer in
            var offer = offer
            if case .writing = offer.state { return nil }
            offer.refining = nil
            return offer
        }
        if aiOffers.allSatisfy({ $0.recipe == nil }) { aiOffers = [] }
    }

    /// True while anything for the sheet is on its way to or from Ollama.
    var aiIsBusy: Bool {
        aiIsGenerating || aiOffers.contains { offer in
            if case .writing = offer.state { return true }
            return offer.refining != nil
        }
    }

    /// Writes one variant again after it failed, different from the ones on offer.
    func retryAIOffer(_ id: Int) {
        guard SoundAI.variantHints.indices.contains(id), aiOfferTasks[id] == nil, !aiAsked.isEmpty else { return }
        let others = aiOffers.filter { $0.id != id }.compactMap(\.recipe)
        let request = aiAsked
        let chat = aiChat
        updateOffer(id) { $0.state = .writing; $0.note = nil; $0.adjustments = [] }
        aiOfferTasks[id] = Task { @MainActor [weak self] in
            do {
                let recipe = try await SoundAI.generate(request: request, chat: chat, hint: SoundAI.variantHints[id],
                                                        temperature: 0.6, avoid: others)
                self?.updateOffer(id) { $0.state = .ready(recipe) }
            } catch {
                guard let text = SoundAI.message(for: error) else { return }
                self?.updateOffer(id) { $0.state = .failed(text) }
            }
            self?.aiOfferTasks[id] = nil
        }
    }

    /// Changes one offered sound with a follow-up request (wärmer, mehr Gain, …) instead of writing it anew. If it
    /// plays on the amp, the changed sound plays right away.
    func refineAIOffer(_ id: Int, _ adjustment: SoundAI.Adjustment) {
        guard aiOfferTasks[id] == nil, let offer = aiOffers.first(where: { $0.id == id }),
              let recipe = offer.recipe else { return }
        let request = aiAsked
        let chat = aiChat
        updateOffer(id) { $0.refining = adjustment; $0.note = nil }
        aiOfferTasks[id] = Task { @MainActor [weak self] in
            do {
                let result = try await SoundAI.refine(recipe, adjustment, request: request, chat: chat)
                guard let self else { return }
                self.updateOffer(id) {
                    $0.state = .ready(result.recipe)
                    $0.adjustments.append(adjustment)
                    $0.note = result.note
                    $0.refining = nil
                }
                self.aiOfferTasks[id] = nil
                if self.aiListening == id { self.listenAISound(id) } else { self.aiHeard.remove(id) }
            } catch {
                let text = SoundAI.message(for: error)
                self?.updateOffer(id) { $0.refining = nil; if let text { $0.note = text } }
                self?.aiOfferTasks[id] = nil
            }
        }
    }

    /// Back from the offered sounds to the description.
    func discardAIResults() {
        cancelAI()
        aiOffers = []
        aiError = nil
        aiListening = nil
        aiHeard = []
        aiPlayNote = nil
    }

    /// Plays an offered sound on the amp's temporary place. Nothing is saved; the library stays as it is.
    func listenAISound(_ id: Int) {
        guard let recipe = aiOffers.first(where: { $0.id == id })?.recipe else { return }
        aiPlayNote = nil
        do {
            let preset = try recipe.preset().preset
            tryOut(preset) { [weak self] problem in
                guard let self else { return }
                if let problem {
                    self.aiPlayNote = problem
                } else {
                    self.aiListening = id
                    self.aiHeard.insert(id)
                }
            }
        } catch {
            aiPlayNote = error.localizedDescription
        }
    }

    /// Takes one of the offered sounds: into the library with the wish as its description, selected, playing.
    func pickAISound(_ id: Int) {
        guard let offer = aiOffers.first(where: { $0.id == id }), let recipe = offer.recipe else { return }
        do {
            try adopt(SoundAI.keepsake(recipe, request: aiAsked, adjustments: offer.adjustments))
            cancelAI()
            aiOffers = []
            showsAI = false
        } catch {
            aiError = error.localizedDescription
        }
    }

    private func rememberAIRequest(_ request: String) {
        aiHistory = SoundAI.remember(request, in: aiHistory)
        UserDefaults.standard.set(aiHistory, forKey: AISetting.historyKey)
    }

    func clearAIHistory() {
        aiHistory = []
        UserDefaults.standard.removeObject(forKey: AISetting.historyKey)
    }

    /// Writes the generated recipe into the library and selects it, so it opens in the editor and plays on the amp.
    private func adopt(_ recipe: SoundRecipe) throws {
        let url = try library.addRecipe(recipe)
        reloadLibrary()
        guard let item = items.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) else {
            throw SoundAI.Error.unreadable("Das Rezept ließ sich nicht als Preset lesen.")
        }
        select(.saved(item.url))
        let verbunden = link.status == .connected
        let play = verbunden ? " Es spielt am Verstärker." : " Verbinde den Verstärker, um es zu hören."
        let note = recipe.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = note.isEmpty ? "" : " Hinweis: \(note)"
        show(.info, "„\(recipe.name)“ ist bereit." + play + hint)
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
