import AppKit
import SparkControl
import SparkCore
import SparkPresetsUI
import SparkRecorderUI
import SparkTunerUI
import SwiftUI

/// The areas below the deck, in the order of the toolbar's tabs.
///
/// A new app joins Spark Studio as a new case here: its UI library provides a host with content and menus (like
/// RecorderHost and PresetsHost), StudioKeymap gets a scope for its keys, `StudioWindowView` shows its content and
/// `StudioCommands` adds its menus. ⇧⌘ plus the next digit then shows it.
enum StudioArea: String, CaseIterable, Identifiable {
    case recording
    case presets
    case tuner

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: "Aufnahme"
        case .presets: "Presets"
        case .tuner: "Stimmgerät"
        }
    }

    /// ⇧⌘ plus this digit shows the area.
    var digit: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

/// Spark Studio: one window with the recorder's deck on top and the areas below it.
///
/// It ties the two apps together: a take keeps the sound the amp plays when it starts, a preset's tempo sets the
/// metronome, and a tempo changed by hand is offered to the preset, never written into it silently.
@MainActor
final class Studio: ObservableObject {
    static let shared = Studio()

    let recorder = RecorderHost(folder: StudioLaunch.folders?.recordings, inputNames: DeviceProfile.recordableUSBNames)
    let presets = PresetsHost(folder: StudioLaunch.folders?.presets)
    /// Reads the recorder's input along with it. A test library keeps its settings apart.
    let tuner: TunerHost
    @Published var area = StudioArea.recording {
        didSet {
            guard area != oldValue else { return }
            updateTuner()
            // SwiftUI rebuilds a menu only when it opens, but a key goes to whatever the menus hold right now.
            // Without this, ⌘N could still open a preset just after switching to Aufnahme.
            for delay in [0.0, 0.15] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { Self.refreshMenus() } }
            }
        }
    }
    @Published var showsShortcuts = false
    private(set) var window: NSWindow?
    private var tempoQuestion: Task<Void, Never>?

    private init() {
        let tunerDefaults = StudioLaunch.isTestLibrary ? UserDefaults(suiteName: "local.sparkstudio.tuner.tests") : nil
        tuner = TunerHost(input: recorder.sharedInput, defaults: tunerDefaults ?? .standard)
        tuner.offerAmpTuner(presets)
        // The recorder's single keys act only in its area. R and Space record and play from everywhere.
        recorder.routeKeys { [weak self] key in
            self?.area == .recording || StudioKeymap.isSingleKeyEverywhere(key)
        }
        recorder.onShowShortcuts { [weak self] in self?.showsShortcuts = true }
        connectTakesToSounds()
        connectPiecesToPresets()
        connectTempo()
        offerTunerPictures()
    }

    // MARK: Pictures of the tuner

    /// The recorder's `pictures` self-test draws the tuner too, with a synthetic string, never a real input.
    private func offerTunerPictures() {
        recorder.addPictures(steps: [
            ("tuner", { [weak self] in self?.showTunerDemo(frequency: 110 * pow(2, -3.4 / 1200), strobe: false) }),
            ("tuner-strobe", { [weak self] in self?.showTunerDemo(frequency: 196 * pow(2, 1.8 / 1200), strobe: true) }),
            ("tuner-intune", { [weak self] in self?.showTunerDemo(frequency: 82.4069, strobe: false) }),
            ("tuner-amp", { [weak self] in
                guard let self else { return }
                isShowingTunerDemo = true
                tuner.showAmpDemo(pitchClass: 9, cents: 6)
                area = .tuner
                updateTuner()
            }),
        ], done: { [weak self] in
            self?.isShowingTunerDemo = false
            self?.tuner.endDemo()
            self?.area = .recording
        })
    }

    private func showTunerDemo(frequency: Double, strobe: Bool) {
        isShowingTunerDemo = true
        tuner.showDemo(frequency: frequency, strobe: strobe)
        area = .tuner
        updateTuner()
    }

    // MARK: Window

    /// The one window. The recorder and the presets' snapshot both work with it.
    @discardableResult
    func makeWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 812),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: StudioWindowView(studio: self, presets: presets))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = host
        window.title = "Spark Studio"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: StudioWindowView.minimumWidth, height: StudioWindowView.minimumHeight)
        window.center()
        window.setFrameAutosaveName("SparkStudioMain")
        recorder.adopt(window)
        presets.adopt(window)
        self.window = window
        // The tuner hears only while its area shows in a window one can see: not when it is closed, in the Dock or
        // hidden behind other windows.
        let names: [Notification.Name] = [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.didBecomeKeyNotification]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.updateTuner(closing: note.name == NSWindow.willCloseNotification) }
            }
        }
        return window
    }

    private func updateTuner(closing: Bool = false) {
        let visible = !closing && window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
        // The pictures' synthetic string opens no input, so it may play while the screen is locked, as tests run.
        let active = area == .tuner && (visible || isShowingTunerDemo)
        // The amp's own tuner needs the link, which otherwise starts only with the area Presets.
        if active, !isShowingTunerDemo { presets.startLinkOnce() }
        tuner.setActive(active)
    }

    private var isShowingTunerDemo = false

    func show(_ area: StudioArea) {
        self.area = area
        showWindow()
    }

    func showWindow() {
        makeWindow().makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateTuner()
    }

    /// What AppKit does right before a menu opens, for every menu at once.
    static func refreshMenus() {
        func refresh(_ menu: NSMenu) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items { if let submenu = item.submenu { refresh(submenu) } }
        }
        if let menu = NSApp.mainMenu { refresh(menu) }
    }

    // MARK: Takes and sounds

    private func connectTakesToSounds() {
        // Read from memory when a take starts. Without a connection the take simply has no sound.
        recorder.provideSound { [weak self] in
            guard let heard = self?.presets.heardSound() else { return nil }
            let listened = heard.listened?.map { ListenedValue(label: $0.label, value: $0.value) }
            return TakeSound(stamp: PresetStamp(slot: heard.slot, name: heard.name, sha256: heard.sha256,
                                                device: heard.device, listened: listened),
                             snapshot: heard.snapshot)
        }
        // The NEO plays its stored slot again when the connection ends. A take keeps the sound it started with, and
        // the recorder says what happened.
        presets.onTemporaryLost { [weak self] device in
            guard let self, recorder.isRecording else { return }
            recorder.warn("\(device) ist getrennt und zum gespeicherten Platz zurückgesprungen. Der Take behält den Sound, mit dem er begann; ab jetzt klingt es anders.")
        }
        recorder.handleSounds(SoundActions(
            sendToAmp: { [weak self] snapshot in
                self?.presets.play(snapshot: snapshot) { problem in
                    if let problem {
                        self?.recorder.warn(problem)
                    } else {
                        self?.recorder.inform("Der Sound spielt am Verstärker, auf dem vorübergehenden Platz. Kein Platz wurde überschrieben.")
                    }
                }
            },
            openInEditor: { [weak self] snapshot in
                self?.presets.open(snapshot: snapshot)
                self?.show(.presets)
            }))
    }

    // MARK: Pieces and their sounds

    private func connectPiecesToPresets() {
        recorder.offerPresets({ [weak self] in
            self?.presets.choices.map { PresetLink(presetID: $0.id, fileName: $0.fileName, name: $0.name) } ?? []
        }, play: { [weak self] link in
            self?.presets.play(presetID: link.presetID, fileName: link.fileName) { problem in
                if let problem { self?.recorder.warn(problem) } else { self?.recorder.inform("„\(link.name)“ spielt am Verstärker, auf dem vorübergehenden Platz.") }
            }
        })
        // Songs of an import (Kemper performances) become pieces, each part with its preset.
        presets.onImportSongs { [weak self] songs in
            guard let self else { return nil }
            let pieces = songs.map { song in
                RecorderHost.NewPiece(title: song.title, notes: song.notes, parts: song.parts.map { part in
                    (part.name, PresetLink(presetID: part.presetID, fileName: part.fileName, name: part.presetName))
                })
            }
            let (added, kept) = recorder.addPieces(pieces)
            var text = "\(added) Stücke unter Aufnahme angelegt."
            if !kept.isEmpty { text += " Schon da und unverändert: " + kept.joined(separator: ", ") + "." }
            return text
        }
    }

    // MARK: Tempo, one source

    private func connectTempo() {
        // Opening a preset sets the metronome to its tempo, except while recording.
        presets.onPresetOpened { [weak self] _, bpm in
            guard let self, !recorder.isRecording, bpm > 0, bpm.rounded() != recorder.tempo else { return }
            tempoQuestion?.cancel()
            recorder.setTempoFromPreset(bpm)
        }
        // A tempo set by hand is offered to the open preset once it settles, so tapping asks only once.
        recorder.onTempoChanged { [weak self] bpm in
            guard let self else { return }
            tempoQuestion?.cancel()
            tempoQuestion = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled, let open = presets.openPreset,
                      open.bpm.rounded() != bpm.rounded() else { return }
                recorder.ask("Tempo \(Int(bpm)) auch ins Preset „\(open.name)“ übernehmen?", action: "Übernehmen") {
                    [weak self] in self?.presets.setTempoOfOpenPreset(bpm)
                }
            }
        }
    }
}

/// The presets' Bluetooth link offers the amp's own tuner to the tuner area.
extension PresetsHost: AmpTuner {}
