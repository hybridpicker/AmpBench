import Foundation
import SparkControl

/// Where the preset in the editor came from, and where "Auf dem Mac sichern" puts it.
enum EditSource: Equatable {
    case slot(Int)
    case saved(URL)
    /// New, not saved yet.
    case draft
}

/// The preset being edited, and how its changes reach the amp.
///
/// Live changes only ever go to the temporary place 7F. The first change of a session sends the whole preset there,
/// later ones go one by one through a queue that keeps only the newest value of a knob and paces model changes out.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var editor: PresetEditor?
    @Published private(set) var source: EditSource?
    /// The place of the chain shown in the large panel.
    @Published var focus: ChainPlace = .amp
    /// Plays the saved state instead of the edited one, for comparing. Controls are locked meanwhile.
    @Published private(set) var showsOriginal = false
    /// Changes go to the amp as they happen.
    @Published var isLiveEnabled = true
    @Published private(set) var isSending = false

    private let link: SparkLink
    private var queue = LiveQueue()
    private var worker: Task<Void, Never>?
    private var modelChanges: [ContinuousClock.Instant] = []
    private var strainedUntil: ContinuousClock.Instant?
    /// What the amp is known to play on 7F, to check it after a change got no answer.
    private var needsCheck = false
    /// A stored preset to switch to before anything else in the queue.
    private var pendingSlot: Int?
    var show: ((Banner.Kind, String) -> Void)?

    init(link: SparkLink) {
        self.link = link
        link.onStrain = { [weak self] in self?.strained() }
    }

    var preset: SparkPreset? { showsOriginal ? editor?.original : editor?.current }
    var isModified: Bool { editor?.isModified ?? false }
    var canUndo: Bool { editor?.canUndo ?? false }
    var canRedo: Bool { editor?.canRedo ?? false }
    var isLocked: Bool { showsOriginal || editor == nil }

    /// True when what the amp plays now is this editor's state.
    var isHeard: Bool { link.isEditingLive && editor != nil }

    // MARK: Sessions

    func open(_ preset: SparkPreset, from source: EditSource) {
        stopLive()
        editor = PresetEditor(preset)
        self.source = source
        showsOriginal = false
    }

    /// Takes a fresh copy of the source, such as a slot read again, when nothing was changed.
    func refresh(_ preset: SparkPreset, from source: EditSource) {
        guard self.source == source, !isModified, editor?.current != preset else { return }
        editor = PresetEditor(preset)
    }

    func close() {
        stopLive()
        editor = nil
        source = nil
    }

    /// What plays on 7F belongs to the previous session, so the next change sends the whole preset again.
    private func stopLive() {
        queue.removeAll()
        needsCheck = false
        link.endEditing()
    }

    // MARK: Changes

    func setParameter(place: Int, index: UInt8, value: Float) {
        guard !isLocked else { return }
        send(editor?.setParameter(place: place, index: index, value: value) ?? [])
    }

    func beginGesture() { editor?.beginGesture() }
    func endGesture() { editor?.endGesture() }

    func setOn(place: Int, _ isOn: Bool) {
        guard !isLocked else { return }
        send(editor?.setOn(place: place, isOn) ?? [])
    }

    func setModel(place: Int, to id: String) {
        guard !isLocked else { return }
        send(editor?.setModel(place: place, to: id) ?? [])
    }

    func setBPM(_ bpm: Float) {
        guard !isLocked else { return }
        send(editor?.setBPM(bpm) ?? [])
    }

    func setName(_ name: String) {
        guard !isLocked else { return }
        editor?.setName(name)
    }

    func setDescription(_ text: String) {
        guard !isLocked else { return }
        editor?.setDescription(text)
    }

    func undo() {
        guard !showsOriginal else { return }
        send(editor?.undo() ?? [])
    }

    func redo() {
        guard !showsOriginal else { return }
        send(editor?.redo() ?? [])
    }

    func revert() {
        guard !showsOriginal else { return }
        send(editor?.revert() ?? [])
    }

    /// A/B: plays the saved state, then the edited one again.
    func toggleComparison() {
        guard let editor, editor.isModified || showsOriginal else { return }
        showsOriginal.toggle()
        guard isLiveEnabled, link.status == .connected else { return }
        queue.push(.whole(showsOriginal ? editor.original : editor.current))
        runQueue()
    }

    /// Takes over the state that was just saved.
    func markSaved(_ preset: SparkPreset? = nil, as source: EditSource? = nil) {
        editor?.markSaved(preset)
        if let source { self.source = source }
        showsOriginal = false
    }

    func markUnsaved() {
        editor?.markUnsaved()
    }

    func renameSaved(to name: String, at url: URL) {
        editor?.renameSaved(to: name)
        source = .saved(url)
    }

    /// Switches the amp to a stored preset. It goes through the same queue as live changes, so a change made right
    /// after it can never arrive before it and end up on the stored preset's sound.
    func play(slot: Int) {
        guard link.status == .connected else { return }
        queue.removeAll()
        pendingSlot = slot
        runQueue()
    }

    /// Plays the current state on the amp, for example after reconnecting or switching live on.
    func playNow() {
        guard let preset, link.status == .connected else { return }
        queue.push(.whole(preset))
        runQueue()
    }

    /// After a new connection the temporary preset is gone. An edit in progress goes back to the amp.
    func reconnected() {
        guard editor != nil, isLiveEnabled, isModified else { return }
        playNow()
        show?(.info, "Die Verbindung war weg. Der bearbeitete Stand spielt wieder am Verstärker.")
    }

    // MARK: Sending

    private func send(_ changes: [LiveChange]) {
        guard !changes.isEmpty, isLiveEnabled, link.status == .connected, let editor else { return }
        if link.isEditingLive || queue.items.contains(where: { if case .whole = $0 { true } else { false } }) {
            queue.push(changes)
        } else {
            // The first change of a session: the whole preset goes to 7F, with this change already in it.
            queue.push(.whole(editor.current))
        }
        runQueue()
    }

    private func runQueue() {
        guard worker == nil else { return }
        isSending = true
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
            self?.isSending = false
        }
    }

    private func drain() async {
        while pendingSlot != nil || !queue.isEmpty {
            if let slot = pendingSlot {
                pendingSlot = nil
                guard link.activeSlot != slot || link.isEditingLive || link.tryingOut != nil else { continue }
                do {
                    try await link.select(slot: slot)
                } catch {
                    show?(.error, "Der Verstärker hat nicht auf Platz \(slot + 1) umgeschaltet: \(error.localizedDescription)")
                }
                continue
            }
            guard let change = queue.next() else { break }
            let clock = ContinuousClock()
            if let until = strainedUntil, until > clock.now { try? await Task.sleep(until: until) }
            let wait = LivePacing.wait(before: change, now: clock.now, recentModelChanges: modelChanges)
            if wait > .zero { try? await Task.sleep(for: wait) }
            if case .model = change {
                modelChanges.append(clock.now)
                modelChanges.removeAll { clock.now - $0 > LivePacing.modelWindow }
            }
            do {
                if !(try await link.apply(change)) { needsCheck = true }
            } catch {
                queue.removeAll()
                needsCheck = false
                if link.status == .connected { show?(.error, "Die Änderung kam nicht am Verstärker an: \(error.localizedDescription)") }
                return
            }
            if queue.isEmpty, needsCheck { await check() }
        }
    }

    /// Reads what the amp plays and sends the whole preset again if it differs, after a change got no answer.
    private func check() async {
        needsCheck = false
        guard let wanted = preset, let playing = try? await link.readPreset(.playing) else { return }
        if !LiveChange.between(playing, wanted).isEmpty { queue.push(.whole(wanted)) }
    }

    /// The amp answered with an echo. Before it hung once, it did that, so changes wait a few seconds.
    private func strained() {
        strainedUntil = ContinuousClock().now + .seconds(3)
    }
}
