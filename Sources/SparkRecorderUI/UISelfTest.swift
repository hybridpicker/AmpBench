import AVFoundation
import AppKit
import ApplicationServices
import CoreAudio
import SparkCore
import SparkDesign
import SwiftUI

/// Drives the running app from inside, with real key events and real audio over BlackHole.
///
/// Only active with both `--library <test folder>` and `--ui-selftest <scenario> <output folder>`, so it can never run
/// on the real library. Sound only goes to virtual outputs. Results are written as lines of text and window pictures.
@MainActor
final class UISelfTest {
    private let model: AppModel
    private let scenario: String
    private let output: URL
    private var log: [String] = []
    private var failures = 0
    private var toneProcess: Process?
    private var restoreRate: (device: AudioDeviceID, rate: Double)?
    private var activity: NSObjectProtocol?

    /// Pictures of other areas, given by Spark Studio.
    static var extraPictures: (steps: [(name: String, show: @MainActor () -> Void)], done: @MainActor () -> Void)?

    static func startIfRequested(model: AppModel) {
        let arguments = CommandLine.arguments
        guard LaunchOptions.current.isTestLibrary,
              let index = arguments.firstIndex(of: "--ui-selftest"), index + 2 < arguments.count else { return }
        let test = UISelfTest(model: model, scenario: arguments[index + 1],
                              output: URL(fileURLWithPath: arguments[index + 2], isDirectory: true))
        Task { await test.run() }
    }

    private init(model: AppModel, scenario: String, output: URL) {
        self.model = model
        self.scenario = scenario
        self.output = output
    }

    // MARK: Helpers

    private func note(_ text: String) {
        log.append(text)
        flush()
    }

    private func check(_ condition: Bool, _ text: String, detail: @autoclosure () -> String = "") {
        if !condition { failures += 1 }
        let suffix = condition ? "" : " [\(detail())]"
        note("\(condition ? "PASS" : "FAIL") \(text)\(suffix)")
    }

    private func flush() {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? log.joined(separator: "\n").appending("\n")
            .write(to: output.appendingPathComponent("result-\(scenario).txt"), atomically: true, encoding: .utf8)
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return true }
            await wait(0.02)
        }
        return condition()
    }

    private var window: NSWindow? { RecorderSession.mainWindow }

    private func snapshot(_ name: String) async {
        await wait(0.25)
        guard let view = window?.contentView, let data = WindowPicture.png(of: view) else {
            note("NOTE no window for snapshot \(name)")
            return
        }
        try? data.write(to: output.appendingPathComponent("\(name).png"))
    }

    /// Posts a real key event. It takes the same path as a key press, through the event monitor and menus.
    private func press(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) async {
        guard let window else { return }
        // These tests must only ever hear the virtual test device, never a real input.
        if characters == "r" || characters == "g" {
            let name = model.selectedInput?.name ?? ""
            // Without any input the key must do nothing, which is exactly what the "nospark" scenario checks.
            guard model.selectedInput == nil || name.contains("BlackHole") || name == InputPolicy.testDeviceName else {
                check(false, "refused to press \(characters): input is not the test device", detail: name)
                return
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
        if window.isKeyWindow {
            if keyCode != 0, modifiers.isEmpty, AXIsProcessTrusted() {
                // The full path of a real key press, addressed to this process only. The system ignores it for an
                // app without accessibility permission, as the installed app has unless the user grants it.
                postKey(keyCode, flags: [])
            } else {
                NSApp.postEvent(event, atStart: false)
            }
        } else {
            // The same order AppKit uses, for when no window can be key because the screen is locked.
            if KeyRouter.shared?.handle(event) != true { window.sendEvent(event) }
        }
        await wait(0.12)
    }

    /// The action behind ⌘⌫, taken from its real menu item. The item itself is checked for its shortcut too.
    private func pressCommandDelete() async {
        guard let item = menuItem(titled: "In den Papierkorb legen", in: NSApp.mainMenu), let action = item.action else {
            check(false, "menu item for discarding exists")
            return
        }
        if window?.isKeyWindow == true, AXIsProcessTrusted() {
            postKey(51, flags: .maskCommand)
        } else {
            NSApp.sendAction(action, to: item.target, from: item)
        }
        await wait(0.2)
    }

    private func postKey(_ keyCode: UInt16, flags: CGEventFlags) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = flags
            event.postToPid(getpid())
        }
    }

    private func menuItem(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == title { return item }
            if let found = menuItem(titled: title, in: item.submenu) { return found }
        }
        return nil
    }

    private func startTone(seconds: Double = 300, amplitude: Float = 0.05) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--play-tone", "BlackHole", String(seconds), "1000", String(amplitude)]
        try? process.run()
        toneProcess = process
    }

    private func stopTone() async {
        toneProcess?.terminate()
        toneProcess = nil
        await wait(0.3)
    }

    private func useTestDevices() {
        model.refreshDevices()
        let input = model.inputs.first { $0.name.contains("BlackHole") }
        if let input, restoreRate == nil {
            // Opening the input would otherwise switch the rate under the running test tone.
            restoreRate = (input.id, input.currentRate)
            AudioDevices.setRate(input.maxRate, on: input.id)
            model.refreshDevices()
        }
        model.chooseInput(input?.id)
        // A virtual output with nothing listening, so the tests stay silent. It is never the amp or the speakers.
        let sink = model.outputs.first {
            $0.transport == kAudioDeviceTransportTypeVirtual && !$0.name.contains("BlackHole")
        }
        model.chooseOutput(sink?.id)
        model.chooseClickOutput(sink?.id)
        note("NOTE input \(input?.name ?? "none"), output \(sink?.name ?? "none")")
    }

    private func record(seconds: Double) async -> Recording? {
        let before = Set(model.recordings.map(\.id))
        await press("r", keyCode: 15)
        guard await waitUntil(timeout: 8, { model.phase == .recording }) else { return nil }
        await wait(seconds)
        await press("r", keyCode: 15)
        _ = await waitUntil { model.phase == .idle }
        return model.recordings.first { !before.contains($0.id) }
    }

    private func finish() async {
        await stopTone()
        if let restoreRate { AudioDevices.setRate(restoreRate.rate, on: restoreRate.device) }
        note("RESULT \(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        NSApp.terminate(nil)
    }

    // MARK: Scenarios

    private func run() async {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "UI self-test")
        check(window?.isVisible == true, "the window is there right after launching")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await wait(0.5)
        if window?.isKeyWindow != true {
            KeyRouter.windowOverride = window
            note("NOTE window cannot become key, so keys go directly through the key router")
        } else {
            note("NOTE window is key, keys take the full system event path")
        }
        note("NOTE microphone status \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), window \(window?.frame.size ?? .zero)")
        switch scenario {
        case "main": await mainScenario()
        case "crash-start": await crashStartScenario()
        case "crash-verify": await crashVerifyScenario()
        case "legacy": await legacyScenario()
        case "pictures": await pictureScenario()
        case "realwindow": await realWindowScenario()
        case "nospark": await noSparkScenario()
        case "reconnect": await reconnectScenario()
        case "sound": await soundScenario()
        default: note("FAIL unknown scenario")
        }
        await finish()
    }

    /// A take keeps the sound the amp plays when it starts, and a failing amp action during the recording ends
    /// nothing. In Spark Studio the action goes the real way to the presets, which are offline in tests, so it fails
    /// like a lost Bluetooth connection. In Spark Recorder a stand-in action counts the call.
    private func soundScenario() async {
        useTestDevices()
        await wait(1)
        // Whole seconds, because the journal stores dates without fractions.
        let stamp = PresetStamp(slot: 2, name: "Crunch", stampedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                                sha256: String(repeating: "ab", count: 32))
        let soundFile = Data(#"{"format":2,"preset":{"name":"Crunch"}}"#.utf8)
        model.soundProvider = { TakeSound(stamp: stamp, snapshot: soundFile) }
        var standInCalls = 0
        if model.soundActions == nil {
            model.soundActions = SoundActions(sendToAmp: { _ in standInCalls += 1 }, openInEditor: { _ in })
        }
        startTone(amplitude: 0.05)
        await press("r", keyCode: 15)
        check(await waitUntil(timeout: 8) { model.phase == .recording }, "R starts a recording")
        let journal = model.store.readJournal()
        check(journal?.preset == stamp, "the journal keeps the sound, for a take repaired after a crash")
        if let id = journal?.takeID {
            check(model.store.presetSnapshot(of: id) == soundFile, "the snapshot is written when the take starts")
        } else {
            check(false, "the journal names the take's id")
        }
        await wait(0.6)
        // What a lost connection does in Studio: the amp action fails and reports. The recording goes on.
        model.soundActions?.sendToAmp(soundFile)
        await wait(0.8)
        check(model.phase == .recording, "a failing amp action does not end the recording")
        await press("r", keyCode: 15)
        check(await waitUntil { model.phase == .idle && model.current != nil }, "R stops the take")
        await stopTone()
        guard let take = model.current else { return }
        check(take.preset == stamp, "the take keeps its sound", detail: "\(String(describing: take.preset))")
        check(model.presetSnapshot(of: take) == soundFile, "the take's snapshot is next to it")
        check(journal?.takeID == take.id, "the take has the id chosen at its start")
        if standInCalls > 0 { note("NOTE stand-in amp action was called \(standInCalls) time(s)") }
        await snapshot("sound-inspector")
        model.soundProvider = nil
    }

    private func mainScenario() async {
        useTestDevices()
        await wait(1)
        check(!KeyRouter.isEditingText, "no text field has the focus at launch, so the first R records")
        await snapshot("01-empty")

        // Core loop: record, instantly see and hear, decide.
        startTone(amplitude: 0.05)
        await wait(0.4)
        await press("r", keyCode: 15)
        check(await waitUntil(timeout: 8) { model.phase == .recording }, "R starts a recording")
        await wait(1.0)
        check(model.meter.level > 0.01, "meter shows the signal", detail: "\(model.meter.level)")
        check(model.meter.signal == .ok, "no warning with signal present")
        check(NSApp.dockTile.badgeLabel == "REC", "Dock shows REC")
        check(FileManager.default.fileExists(atPath: model.store.journalURL.path), "journal exists during the recording")
        await press("m", keyCode: 46)
        check(model.pendingMarkerCount == 1, "M sets a marker during the recording")
        await wait(1.0)
        await snapshot("02-recording")
        let stopRequested = Date()
        await press("r", keyCode: 15)
        check(await waitUntil { model.phase == .idle && model.currentWaveform != nil }, "R stops and a waveform is there")
        let latency = Date().timeIntervalSince(stopRequested)
        check(latency < 0.6, "waveform appears right after stopping", detail: "\(latency) s")
        note("NOTE stop to waveform took \(String(format: "%.3f", latency)) s including the event delay")
        guard let first = model.current else {
            check(false, "a take is in focus")
            return
        }
        check(first.status == .open, "new take waits for a decision")
        check(first.markers.count == 1, "marker is in the take", detail: "\(first.markers.count)")
        check(first.source != nil, "source format was recorded")
        check(first.fileBits == 24, "file is 24 bit")
        check(first.edit.autoLevelEnabled && first.edit.autoLevelDB > 20, "auto level is an edit, not a file change", detail: "\(first.edit.autoLevelDB)")
        check(!FileManager.default.fileExists(atPath: model.store.journalURL.path), "journal is gone after stopping")
        check(NSApp.dockTile.badgeLabel == nil, "Dock badge is gone")
        if case .ok(let format, let frames) = WAVFile.inspect(model.store.url(of: first)) {
            check(format.bits == 24 && abs(Double(frames) / format.sampleRate - first.duration) < 0.01, "file on disk matches the entry")
        } else {
            check(false, "file on disk is intact")
        }
        // The peak of the unprocessed file proves the gain was not written into it.
        if let analysis = try? AudioAnalyzer.analyze(model.store.url(of: first)) {
            check(abs(analysis.peak - 0.05) < 0.03, "original file keeps its level", detail: "\(analysis.peak)")
        }
        await snapshot("03-review")

        await press(" ", keyCode: 49)
        check(await waitUntil { model.playhead.isPlaying }, "space starts playback")
        await wait(0.5)
        check(model.playhead.position > 0.1, "playhead moves", detail: "\(model.playhead.position)")
        await press("l", keyCode: 37)
        await wait(0.3)
        await press("l", keyCode: 37)
        check(model.loopRange != nil, "L twice sets a loop", detail: "\(String(describing: model.loopRange))")
        await snapshot("04-loop")
        await press("l", keyCode: 37)
        check(model.loopRange == nil, "third L removes it")
        await press(" ", keyCode: 49)
        check(!model.playhead.isPlaying, "space pauses")
        await press("", keyCode: 124)
        await press("+", keyCode: 30)
        check(abs(model.tempo - 1.05) < 0.001, "plus speeds up", detail: "\(model.tempo)")
        await press("0", keyCode: 29)
        check(model.tempo == 1, "0 resets the tempo")

        await press("k", keyCode: 40)
        check(model.current?.status == .kept, "K keeps")
        window?.undoManager?.undo()
        await wait(0.1)
        check(model.current?.status == .open, "undo reverts keeping")

        // "Nochmal": the previous take stays.
        let second = await record(seconds: 1.0)
        check(second != nil, "R records again")
        check(model.recordings.contains { $0.id == first.id && $0.status == .open }, "the earlier take stays as open")
        check(model.selection == Set([second?.id].compactMap { $0 }), "new take is selected")

        // Shortcuts stay out of the way while typing.
        let count = model.recordings.count
        let phaseBefore = model.phase
        model.tab = .recordings
        await wait(0.2)
        if let field = findView(in: window?.contentView, ofType: NSSearchField.self) ?? findTextField(in: window?.contentView) {
            window?.makeFirstResponder(field)
            await wait(0.1)
            let isEditing = KeyRouter.isEditingText
            check(isEditing, "search field takes focus")
            await press("r", keyCode: 15)
            await press("k", keyCode: 40)
            check(model.phase == phaseBefore, "typing R in a text field does not start a recording")
            check(model.query.search.lowercased().contains("r"), "the letter reaches the text field", detail: model.query.search)
            await press("", keyCode: 51)
            check(model.recordings.count == count, "⌫ in a text field does not discard anything")
            await pressCommandDelete()
            check(model.recordings.count == count, "⌘⌫ in a text field does not discard anything")
            check(model.query.search.isEmpty, "⌘⌫ in a text field edits the text", detail: model.query.search)
            await press("x", keyCode: 7)
            await press("", keyCode: 53)
            check(!KeyRouter.isEditingText, "Esc leaves the text field")
            model.query = LibraryQuery()
            await wait(0.1)
        } else {
            check(false, "search field found")
        }

        // Discard goes to the real Trash and comes back.
        if let target = second {
            let url = model.store.url(of: target)
            let order = model.visibleRecordings.map(\.id)
            let expectedNext = RemovalTargets.nextFocus(in: order, removing: [target.id])
            await pressCommandDelete()
            check(!model.recordings.contains { $0.id == target.id }, "⌘⌫ discards the selected take")
            check(expectedNext != nil && model.currentID == expectedNext, "the next take is in focus after discarding",
                  detail: "\(String(describing: model.currentID))")
            check(model.selection == Set([expectedNext].compactMap { $0 }), "the next take is marked after discarding")
            check(!model.playhead.isPlaying, "the next take is not played by itself")
            check(!FileManager.default.fileExists(atPath: url.path), "file left the folder")
            let trashPath = model.store.document.trashed.last?.trashPath ?? ""
            check(trashPath.contains(".Trash") && FileManager.default.fileExists(atPath: trashPath), "file is in the Trash")
            await snapshot("05-discarded")
            window?.undoManager?.undo()
            await wait(0.3)
            check(model.recordings.contains { $0.id == target.id }, "undo brings the take back")
            check(model.currentID == target.id, "the take brought back is in focus again")
            check(FileManager.default.fileExists(atPath: url.path), "file is back in the folder")

            // Delete and forward delete do the same as ⌘⌫.
            for keyCode: UInt16 in [51, 117] {
                model.select(target.id)
                await wait(0.2)
                await press("", keyCode: keyCode)
                await wait(0.2)
                check(!model.recordings.contains { $0.id == target.id }, "key \(keyCode) discards the selected take")
                check(!FileManager.default.fileExists(atPath: url.path), "key \(keyCode) moves the file out of the folder")
                window?.undoManager?.undo()
                await wait(0.3)
                check(model.recordings.contains { $0.id == target.id }, "undo brings the take back after key \(keyCode)")
            }
        }

        // No letter can delete.
        let before = model.recordings.count
        for letter in "abcdefghijklmnopqstuvwxyz" where !"r".contains(letter) {
            await press(String(letter))
        }
        check(model.recordings.count == before, "no letter removes a recording")
        // Undo what the letters above switched on.
        model.clearLoop()
        if model.playhead.isPlaying { await press(" ", keyCode: 49) }
        if model.metronome.clickEnabled { model.toggleClick() }
        if model.current?.favorite == true { model.toggleFavorite() }

        await libraryChecks(first: first)
        await practiceChecks(first: first)
        await spaceAndClickChecks(first: first)
        await barChecks()
        await removalAndPieceChecks()
        await editAndExportChecks(first: first)
        await retroChecks()
        await feedbackChecks()
        await deviceLossChecks()
        await accessibilityChecks()
    }

    private func libraryChecks(first: Recording) async {
        model.select(first.id)
        await press("4", keyCode: 21)
        check(model.current?.rating == 4, "4 rates")
        await press("f", keyCode: 3)
        check(model.current?.favorite == true, "F marks a favorite")
        model.setTags("Blues, Solo", for: first.id)
        model.rename(first.id, to: "Blues in A")
        check(model.current?.fileName == "Blues in A.wav", "rename changes the file name")
        check(FileManager.default.fileExists(atPath: model.store.folder.appendingPathComponent("Blues in A.wav").path), "renamed file exists")
        model.query.search = "blues"
        check(model.visibleRecordings.count == 1, "search finds it")
        model.query = LibraryQuery()
        model.query.onlyFavorites = true
        check(model.visibleRecordings.map(\.id) == [first.id], "favorite filter")
        model.query = LibraryQuery()
        model.query.status = .open
        await wait(0.1)
        await snapshot("06-filter")
        model.query = LibraryQuery()
        model.sortOrder = [KeyPathComparator(\Recording.rating, order: .reverse)]
        check(model.visibleRecordings.first?.id == first.id, "sorting by rating")
        model.sortOrder = [KeyPathComparator(\Recording.createdAt, order: .reverse)]
        await wait(0.5)
        try? model.store.save()
        let text = (try? String(contentsOf: model.store.documentURL, encoding: .utf8)) ?? ""
        check(text.contains("Blues in A.wav") && text.contains("\"rating\" : 4"), "library file is readable and current")
    }

    private func practiceChecks(first: Recording) async {
        // Takes, comparing, best take.
        model.addPiece(named: "Blues in A")
        guard let piece = model.pieces.first else {
            check(false, "piece created")
            return
        }
        check(model.currentPieceID == piece.id, "new piece becomes the current one")
        model.assign([first.id], toPiece: piece.id)
        let take = await record(seconds: 1.0)
        check(take?.pieceID == piece.id, "new take joins the current piece")
        guard let take else { return }
        model.selection = [first.id, take.id]
        await wait(0.1)
        check(model.canCompare, "two selected takes can be compared")
        model.startCompare()
        await wait(0.3)
        check(model.compareIDs.count == 2, "compare opens")
        await snapshot("07-compare")
        await press(" ", keyCode: 49)
        await wait(0.3)
        let playingID = model.currentID
        await press("b", keyCode: 11)
        await wait(0.2)
        check(model.currentID != playingID, "B switches the take")
        check(model.playhead.isPlaying, "playback continues across the switch")
        await press(" ", keyCode: 49)
        model.toggleBestTake(take.id)
        check(model.pieces.first?.bestTakeID == take.id, "best take is marked")
        model.clearCompare()
        model.tab = .pieces
        await snapshot("08-pieces")
        model.tab = .stats
        await snapshot("09-stats")
        check(PracticeStats.totalMinutes(model.practiceLog) > 0, "statistics count the recorded time")
        model.tab = .recordings

        // Tempo and count-in.
        for _ in 0..<4 {
            await press("t", keyCode: 17)
            await wait(0.4)
        }
        check(model.metronome.bpm > 60 && model.metronome.bpm < 200, "T sets the tempo", detail: "\(model.metronome.bpm)")
        model.updateMetronome {
            $0.bpm = 120
            $0.beatsPerBar = 4
            $0.countInBars = 1
        }
        await press("r", keyCode: 15)
        var sawCountIn = false
        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            if case .countIn = model.phase { sawCountIn = true; break }
            await wait(0.02)
        }
        check(sawCountIn, "count-in phase is shown", detail: "\(model.phase)")
        await snapshot("10-countin")
        check(model.isClickRunning, "click runs during the count-in")
        check(await waitUntil(timeout: 4) { model.phase == .recording }, "recording follows the count-in")
        let afterCountIn = Date()
        await wait(1.0)
        await press("r", keyCode: 15)
        _ = await waitUntil { model.phase == .idle }
        let elapsed = Date().timeIntervalSince(afterCountIn)
        if let duration = model.current?.duration {
            check(abs(duration - elapsed) < 0.45, "count-in stays out of the file", detail: "file \(duration), recording phase \(elapsed)")
        }
        check(!model.isClickRunning, "click stops with the recording")

        // Cancelling a count-in leaves nothing behind.
        let countBefore = model.recordings.count
        let filesBefore = (try? FileManager.default.contentsOfDirectory(atPath: model.store.folder.path).count) ?? 0
        await press("r", keyCode: 15)
        _ = await waitUntil(timeout: 3) { if case .countIn = model.phase { return true } else { return false } }
        await press("r", keyCode: 15)
        await wait(0.2)
        check(model.phase == .idle && model.recordings.count == countBefore, "R cancels the count-in")
        let filesAfter = (try? FileManager.default.contentsOfDirectory(atPath: model.store.folder.path).count) ?? 0
        check(filesAfter == filesBefore, "cancelled count-in leaves no file", detail: "\(filesBefore) -> \(filesAfter)")
        model.updateMetronome { $0.countInBars = 0 }
    }

    /// The space bar during a recording, and a click that only sounds while playing or recording.
    private func spaceAndClickChecks(first: Recording) async {
        model.select(first.id)
        await wait(0.2)

        // A switched-on click stays silent until something plays or records.
        await press("n", keyCode: 45)
        check(model.metronome.clickEnabled, "N switches the click on")
        await wait(0.7)
        check(!model.isClickRunning, "the click stays silent while nothing plays or records")
        check(model.meter.beat == 0, "no beats are counted while idle", detail: "\(model.meter.beat)")
        check(model.playbackClickGrid != nil, "the click is ready for playback")

        await press(" ", keyCode: 49)
        check(await waitUntil { model.playhead.isPlaying }, "space plays with the click on")
        check(!model.isClickRunning, "playback carries the click itself, without a second clock")
        await wait(0.8)
        check(model.meter.beat > 0, "the beat lamps follow the playback", detail: "\(model.meter.beat)")
        await press(" ", keyCode: 49)
        await wait(0.2)
        check(!model.playhead.isPlaying && model.meter.beat == 0, "pausing silences the click again", detail: "\(model.meter.beat)")

        // R stops a recording without playing, and space afterwards plays the new take.
        var before = Set(model.recordings.map(\.id))
        await press("r", keyCode: 15)
        check(await waitUntil(timeout: 8) { model.phase == .recording }, "R records with the click on")
        check(model.isClickRunning, "the click sounds while recording")
        check(model.playbackClickGrid == nil, "no click goes to the playback during a recording")
        await wait(1.0)
        await press("r", keyCode: 15)
        _ = await waitUntil { model.phase == .idle }
        check(!model.isClickRunning, "the click stops with the recording")
        check(model.metronome.clickEnabled, "the click stays switched on for next time")
        check(!model.playhead.isPlaying, "R stops without playing")
        var newTake = model.recordings.first { !before.contains($0.id) }
        check(newTake != nil && model.currentID == newTake?.id, "the new take is in focus after stopping")
        await press(" ", keyCode: 49)
        check(await waitUntil { model.playhead.isPlaying }, "space after stopping plays")
        check(model.currentID == newTake?.id, "space after stopping plays the take just recorded")
        await press(" ", keyCode: 49)
        await wait(0.2)

        // Space during a recording stops it and plays the new take right away.
        before = Set(model.recordings.map(\.id))
        await press("r", keyCode: 15)
        check(await waitUntil(timeout: 8) { model.phase == .recording }, "R records again for the space check")
        await wait(1.0)
        await press(" ", keyCode: 49)
        check(await waitUntil { model.phase == .idle }, "space during a recording ends it")
        newTake = model.recordings.first { !before.contains($0.id) }
        check(newTake != nil && model.currentID == newTake?.id, "space during a recording saves the new take")
        check(await waitUntil { model.playhead.isPlaying }, "space during a recording plays the new take right away")
        check(!model.isClickRunning, "the click stops with the recording")
        await press(" ", keyCode: 49)
        await wait(0.2)
        check(!model.playhead.isPlaying, "space pauses the new take")

        await press("n", keyCode: 45)
        check(!model.metronome.clickEnabled && model.playbackClickGrid == nil, "N switches the click off")
    }

    /// Bars while recording, looping them, and recording them again without touching the original.
    private func barChecks() async {
        model.updateMetronome {
            $0.bpm = 120
            $0.beatsPerBar = 4
            $0.countInBars = 1
        }
        if !model.metronome.clickEnabled { model.toggleClick() }
        await press("r", keyCode: 15)
        check(await waitUntil(timeout: 8) { model.phase == .recording }, "recording with bars starts")
        check(await waitUntil { model.activeGrid != nil }, "the bars are known during the recording")
        if let grid = model.activeGrid {
            check(abs(grid.offset - 0.15) < 0.1, "bar 1 starts right after the pre-roll", detail: "\(grid.offset)")
            check(grid.bpm == 120 && grid.beatsPerBar == 4 && grid.firstBar == 1, "the bars follow the metronome")
        }
        let tempo = model.metronome.bpm
        model.updateMetronome { $0.bpm = 80 }
        await press("t", keyCode: 17)
        check(model.metronome.bpm == tempo, "the tempo stays fixed during a recording", detail: "\(model.metronome.bpm)")
        await wait(4.6)
        let position = model.activeGrid?.position(at: model.meter.seconds)
        check(position?.bar == 3, "the display reaches bar 3 after four seconds", detail: "\(String(describing: position))")
        await snapshot("15-bars-recording")
        await press("r", keyCode: 15)
        _ = await waitUntil { model.phase == .idle }
        check(model.activeGrid == nil, "the live bars end with the recording")
        guard let take = model.current, let grid = take.grid else {
            check(false, "the take keeps its bars")
            return
        }
        check(model.store.readJournal() == nil, "the journal is gone")
        try? model.store.save()
        let text = (try? String(contentsOf: model.store.documentURL, encoding: .utf8)) ?? ""
        check(text.contains("\"beatsPerBar\" : 4"), "the bars are in the library file")

        // Looping bars.
        model.setBarSelection(2...2)
        model.loopSelectedBars()
        check(model.isLoopingBars, "the chosen bars loop")
        if let loop = model.loopRange {
            check(abs(loop.lowerBound - grid.time(ofBar: 2)) < 0.001 && abs(loop.upperBound - grid.time(ofBar: 3)) < 0.001,
                  "the loop lies exactly on the bars", detail: "\(loop)")
        } else {
            check(false, "a loop exists")
        }
        await snapshot("16-bars-loop")
        check(grid.position(at: model.playhead.position)?.bar == 2, "after jumping to the loop the display shows its bar",
              detail: "\(model.playhead.position)")
        await press(" ", keyCode: 49)
        await wait(2.6)
        check(model.playhead.isPlaying, "the loop keeps playing past its end")
        let inLoop = model.playhead.position
        check(inLoop >= grid.time(ofBar: 2) - 0.05 && inLoop <= grid.time(ofBar: 3) + 0.05, "the playhead stays in the bar", detail: "\(inLoop)")
        await press(" ", keyCode: 49)
        model.toggleBarLoop()
        check(model.loopRange == nil, "the bar loop switches off")

        // Recording bars again. The count-in can be cancelled without leaving anything.
        let original = model.store.url(of: take)
        let originalData = try? Data(contentsOf: original)
        let countBefore = model.recordings.count
        model.setBarSelection(2...3)
        check(model.canRecordBars, "the chosen bars can be recorded again")
        model.recordSelectedBars()
        _ = await waitUntil(timeout: 3) { if case .countIn = model.phase { return true } else { return false } }
        await press("r", keyCode: 15)
        await wait(0.2)
        check(model.phase == .idle && model.recordings.count == countBefore, "R cancels re-recording during the count-in")

        let started = Date()
        model.recordSelectedBars()
        var sawCountIn = false
        while Date().timeIntervalSince(started) < 4 {
            if case .countIn = model.phase { sawCountIn = true; break }
            await wait(0.02)
        }
        check(sawCountIn, "re-recording counts in")
        check(await waitUntil(timeout: 5) { model.phase == .recording }, "re-recording starts after the count-in")
        check(await waitUntil { model.activeGrid != nil }, "the bars are known during re-recording")
        check(model.activeGrid?.firstBar == 2, "the bars keep their numbers", detail: "\(String(describing: model.activeGrid))")
        await wait(1)
        await snapshot("17-bars-rerecording")
        check(await waitUntil(timeout: 6) { model.phase == .idle }, "re-recording stops by itself after the last bar")
        check(model.recordings.count == countBefore + 1, "re-recording adds one take")
        if let punchTake = model.current {
            check(punchTake.id != take.id, "the new version is in focus")
            check(punchTake.punch?.sourceID == take.id && punchTake.punch?.bars == 2...3, "the new version knows its source")
            check(punchTake.grid?.firstBar == 2, "the new version shows the same bar numbers")
            check(punchTake.fileName.contains("Takt 2-3"), "the file name names the bars", detail: punchTake.fileName)
            check(abs(punchTake.duration - 4.45) < 0.3, "two bars at 120 BPM were recorded", detail: "\(punchTake.duration)")
            check(punchTake.tags.contains("Neuaufnahme"), "the new version is tagged")
            check(punchTake.lastBar == 3, "the ringing out adds no bar to choose", detail: "\(String(describing: punchTake.lastBar))")
            check(model.barSelection == 2...3, "the new version starts with its own bars chosen", detail: "\(String(describing: model.barSelection))")
            await snapshot("18-bars-new-version")
        }
        check((try? Data(contentsOf: original)) == originalData, "the original file stays byte for byte the same")
        check(model.recordings.contains { $0.id == take.id }, "the original stays in the library")
        check(!model.isClickRunning, "the click stops after re-recording")
        model.toggleClick()
        model.updateMetronome { $0.countInBars = 0 }
    }

    /// Removing recordings when nothing is marked, and looking after pieces.
    private func removalAndPieceChecks() async {
        model.selection = []
        await wait(0.1)
        let focused = model.currentID
        let count = model.recordings.count
        model.discard([])
        await wait(0.2)
        check(model.recordings.count == count - (focused == nil ? 0 : 1), "a remove command without rows takes the take in focus")
        if focused != nil {
            window?.undoManager?.undo()
            await wait(0.3)
            check(model.recordings.count == count, "undo brings it back")
        }
        model.selection = []
        await wait(0.1)
        if let visible = model.recordings.first {
            model.selection = [visible.id]
            model.discard([])
            await wait(0.2)
            check(!model.recordings.contains { $0.id == visible.id }, "a remove command without rows takes the marked row")
            model.undoLastDiscard()
            await wait(0.3)
            check(model.recordings.contains { $0.id == visible.id }, "the banner's undo brings it back")
        }
        // Removing another row from its menu leaves the take in focus where it is.
        if model.recordings.count >= 2 {
            let kept = model.recordings[0].id
            let other = model.recordings[1].id
            model.select(kept)
            await wait(0.2)
            model.discard([other])
            await wait(0.2)
            check(model.currentID == kept && model.selection == [kept], "removing another row keeps the focus")
            window?.undoManager?.undo()
            await wait(0.3)
            check(model.recordings.contains { $0.id == other }, "undo brings the other row back")
        }

        model.addPiece(named: "Etüde")
        guard let piece = model.pieces.first(where: { $0.name == "Etüde" }), let take = model.recordings.first else {
            check(false, "a piece exists")
            return
        }
        model.assign([take.id], toPiece: piece.id)
        check(model.renamePiece(piece.id, to: "Etüde 2"), "a piece gets a new title")
        check(model.pieces.first { $0.id == piece.id }?.name == "Etüde 2", "the title changed")
        model.addPiece(named: "Tonleiter", makeCurrent: false)
        check(!model.renamePiece(piece.id, to: "tonleiter"), "two pieces cannot share a title")
        check(model.banner != nil, "the taken title is explained")

        model.tab = .pieces
        await snapshot("19-pieces")
        model.removePiece(piece.id)
        check(!model.pieces.contains { $0.id == piece.id }, "a piece can be removed")
        check(model.recordings.first { $0.id == take.id }?.pieceID == nil, "its takes stay without it")
        check(model.banner?.canUndo == true, "removing a piece offers undo")
        model.undoLastDiscard()
        await wait(0.1)
        check(model.pieces.contains { $0.id == piece.id }, "undo brings the piece back")
        check(model.recordings.first { $0.id == take.id }?.pieceID == piece.id, "undo brings its takes back")
        check(model.currentPieceID == piece.id, "undo restores the piece for new recordings")
        model.setCurrentPiece(nil)
        model.tab = .recordings
    }

    private func editAndExportChecks(first: Recording) async {
        model.select(first.id)
        await wait(0.2)
        guard let recording = model.current else { return }
        let url = model.store.url(of: recording)
        let before = try? Data(contentsOf: url)
        model.updateEdit(first.id) {
            $0.trimStart = 0.5
            $0.fadeIn = 0.2
            $0.fadeOut = 0.2
            $0.gainDB = -3
        }
        await snapshot("11-edit")
        check((try? Data(contentsOf: url)) == before, "editing leaves the original file untouched")
        guard let edited = model.current else { return }
        let wav = model.store.exportFolder.appendingPathComponent("test.wav")
        let aac = model.store.exportFolder.appendingPathComponent("test.m4a")
        model.runExport(of: edited, format: .wav24, to: wav)
        check(await waitUntil { model.exportProgress == nil && FileManager.default.fileExists(atPath: wav.path) }, "WAV export finishes")
        model.runExport(of: edited, format: .aac(bitRate: 192_000), to: aac)
        check(await waitUntil { model.exportProgress == nil && FileManager.default.fileExists(atPath: aac.path) }, "AAC export finishes")
        if case .ok(let format, let frames) = WAVFile.inspect(wav) {
            let expected = (edited.duration - 0.5) * format.sampleRate
            check(abs(Double(frames) - expected) < 2, "export has the trimmed length", detail: "\(frames) vs \(expected)")
        } else {
            check(false, "exported WAV is valid")
        }
        check((try? Data(contentsOf: url)) == before, "exporting leaves the original file untouched")
        let report = model.store.scan()
        check(report.added.isEmpty, "exports do not appear as new recordings")
        model.resetEdits(first.id)
        check(model.current?.edit.trimStart == 0 && model.current?.edit.autoLevelEnabled == true, "reset keeps the auto level setting")
    }

    private func retroChecks() async {
        model.setRetroMinutes(1)
        let files = { (try? FileManager.default.contentsOfDirectory(atPath: self.model.store.folder.path)) ?? [] }
        let before = Set(files())
        check(!model.isRetroOn, "retro is off by default")
        model.toggleRetro()
        check(await waitUntil { model.isRetroOn }, "retro switches on")
        check(model.isListening, "app reports that it is listening")
        await wait(2.5)
        check(model.meter.retroSeconds > 1, "buffer fills", detail: "\(model.meter.retroSeconds)")
        await snapshot("12-retro")
        check(Set(files()) == before, "nothing reaches the disk on its own")
        let count = model.recordings.count
        await press("g", keyCode: 5)
        check(await waitUntil { model.recordings.count == count + 1 }, "G saves the buffer")
        if let saved = model.recordings.last {
            check(saved.fileName.hasPrefix("Retro_") && saved.duration > 1, "retro take looks right", detail: saved.fileName)
            check(saved.tags.contains("Retro"), "retro take is tagged")
        }
        let retroRecord = await record(seconds: 0.5)
        check(retroRecord != nil, "recording works while retro listens")
        check(model.isRetroOn, "retro stays on after the recording")
        model.toggleRetro()
        check(!model.isRetroOn && !model.isListening, "retro switches off and the input closes")
    }

    private func feedbackChecks() async {
        // BlackHole loops by design, so output to it during a recording from it must be refused.
        let safeOutput = model.outputID
        guard let loop = model.outputs.first(where: { $0.name.contains("BlackHole") }) else { return }
        model.chooseOutput(loop.id)
        check(model.feedbackRisk == .sameHardware, "same device is recognized as a risk",
              detail: "\(model.selectedInput?.identity as Any) vs \(model.effectiveOutput?.identity as Any): \(model.feedbackRisk)")
        await press("r", keyCode: 15)
        _ = await waitUntil(timeout: 8) { model.phase == .recording }
        model.togglePlay()
        await wait(0.1)
        check(!model.playhead.isPlaying, "playback to the input device stays blocked during a recording")
        check(model.banner?.kind == .warning, "the block is explained")
        await snapshot("13-feedback")
        await press("r", keyCode: 15)
        _ = await waitUntil { model.phase == .idle }
        model.chooseOutput(safeOutput)
        check(model.clickOutput?.name.contains("BlackHole") != true, "click never picks the input device")

        // Playback to a safe output during a recording stays possible.
        await press("r", keyCode: 15)
        _ = await waitUntil(timeout: 8) { model.phase == .recording }
        model.togglePlay()
        await wait(0.1)
        check(model.playhead.isPlaying, "the play button reaches another output during a recording")
        await wait(0.6)
        model.togglePlay()
        await press("r", keyCode: 15)
        _ = await waitUntil { model.phase == .idle }
        check(model.meter.droppedFrames == 0, "no dropouts")
    }

    private func deviceLossChecks() async {
        guard let blackHole = model.inputs.first(where: { $0.name.contains("BlackHole") }) else { return }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: InputPolicy.testDeviceName,
            kAudioAggregateDeviceUIDKey: "local.sparkrecorder.uitest.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: blackHole.uid]],
        ]
        var aggregate = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate) == noErr else {
            note("NOTE could not create the test device")
            return
        }
        await wait(0.5)
        model.refreshDevices()
        model.chooseInput(aggregate)
        check(model.inputID == aggregate, "test device can be selected")
        let count = model.recordings.count
        await press("r", keyCode: 15)
        check(await waitUntil(timeout: 8) { model.phase == .recording }, "recording starts on the test device")
        await wait(1.5)
        AudioHardwareDestroyAggregateDevice(aggregate)
        check(await waitUntil(timeout: 4) { model.phase == .idle }, "losing the device ends the recording")
        check(model.recordings.count == count + 1, "audio up to the loss is in the library")
        if let recording = model.current {
            check(recording.duration > 1, "audio was kept", detail: "\(recording.duration)")
            if case .ok = WAVFile.inspect(model.store.url(of: recording)) {
                check(true, "file is finalized")
            } else {
                check(false, "file is finalized")
            }
        }
        check(model.banner?.kind == .warning, "the loss is reported")
        await snapshot("14-device-lost")
        model.banner = nil
        model.refreshDevices()
        check(model.selectedInput != nil && model.inputID != aggregate, "another input takes over")
        useTestDevices()
    }

    private func accessibilityChecks() async {
        // Asks through the same interface VoiceOver uses, from a background thread so the app can answer.
        let result = await Task.detached(priority: .userInitiated) { () -> (named: [String], missing: [String]) in
            var named: [String] = []
            var missing: [String] = []
            Self.walkAccessibility(AXUIElementCreateApplication(getpid()), into: &named, missing: &missing)
            return (named, missing)
        }.value
        try? result.named.sorted().joined(separator: "\n")
            .write(to: output.appendingPathComponent("voiceover-labels.txt"), atomically: true, encoding: .utf8)
        note("NOTE \(result.named.count) accessibility elements with names, \(result.missing.count) buttons without")
        check(!result.named.isEmpty, "accessibility tree is readable")
        check(result.missing.isEmpty, "every button has a name", detail: result.missing.joined(separator: ", "))
        for needed in ["Aufnahme starten (R)", "Eingangspegel", "Aufnahmezustand", "Qualität"] {
            check(result.named.contains { $0.contains(needed) }, "VoiceOver finds \(needed)")
        }
        let menus = NSApp.mainMenu?.items.map(\.title) ?? []
        note("NOTE menus: \(menus.joined(separator: ", "))")
        check(menus.contains("Aufnahme") && menus.contains("Wiedergabe") && menus.contains("Bibliothek"), "own menus exist")
    }

    private nonisolated static func walkAccessibility(_ element: AXUIElement, into named: inout [String],
                                                      missing: inout [String], depth: Int = 0) {
        guard depth < 30 else { return }
        func text(_ attribute: String) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return "" }
            return value as? String ?? ""
        }
        let role = text(kAXRoleAttribute)
        // The menu bar is checked separately.
        if role == kAXMenuBarRole { return }
        let name = [text(kAXDescriptionAttribute), text(kAXTitleAttribute)].first { !$0.isEmpty } ?? ""
        if !name.isEmpty {
            let value = text(kAXValueAttribute)
            named.append("\(role): \(name)\(value.isEmpty ? "" : " = \(value)")")
        } else if role == kAXButtonRole {
            // The window's own title bar buttons are named by the system.
            let subrole = text(kAXSubroleAttribute)
            let isWindowControl = [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole,
                                   kAXFullScreenButtonSubrole, kAXToolbarButtonSubrole,
                                   kAXIncrementArrowSubrole, kAXDecrementArrowSubrole,
                                   kAXIncrementPageSubrole, kAXDecrementPageSubrole].contains(subrole)
            if !isWindowControl {
                var position: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
                missing.append("\(subrole) \(text(kAXHelpAttribute)) \(position.map { "\($0)" } ?? "")")
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list {
            walkAccessibility(child, into: &named, missing: &missing, depth: depth + 1)
        }
    }

    private func findView<T: NSView>(in view: NSView?, ofType type: T.Type) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = findView(in: child, ofType: type) { return match }
        }
        return nil
    }

    /// The first editable text field in the window.
    private func findTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews {
            if let match = findTextField(in: child) { return match }
        }
        return nil
    }

    // MARK: Spark only

    private func audioFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: model.store.folder.path)) ?? [])
            .filter { LibraryStore.audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// No allowed device exists, while the microphone, BlackHole and even the amp may be right there on the system.
    private func noSparkScenario() async {
        let available = AudioDevices.inputDevices().map(\.name)
        note("NOTE inputs on this Mac: \(available.count)")
        check(available.count > 0, "the system does offer inputs that must stay unused")
        check(model.inputs.isEmpty, "the app offers no input at all")
        check(model.inputID == nil, "no input is selected")
        await wait(0.5)
        await snapshot("no-spark")

        await press("r", keyCode: 15)
        await wait(0.5)
        check(model.phase == .idle, "R does not start a recording", detail: "\(model.phase)")
        check(model.banner?.text.contains("Kein Spark") == true, "R explains why", detail: model.banner?.text ?? "none")
        check(!model.isListening, "the input stays closed after R")
        check(!FileManager.default.fileExists(atPath: model.store.journalURL.path), "no journal was started")

        model.toggleMonitor()
        await wait(0.5)
        check(!model.isMonitoring && !model.isListening, "level check stays off")
        model.toggleRetro()
        await wait(0.5)
        check(!model.isRetroOn && !model.isListening, "retro stays off")
        await press("g", keyCode: 5)
        check(model.canMeasureLoopback == false, "loopback measurement is unavailable")
        check(audioFiles().isEmpty && model.recordings.isEmpty, "no audio file was created", detail: "\(audioFiles())")
        await snapshot("no-spark-pressed")
    }

    private func makeTestDevice(uid: String) -> AudioObjectID? {
        guard let blackHole = AudioDevices.inputDevices().first(where: { $0.name.contains("BlackHole") }) else { return nil }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: InputPolicy.testDeviceName,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: blackHole.uid]],
        ]
        var device = AudioObjectID(0)
        return AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr ? device : nil
    }

    /// One allowed device comes and goes, as an amp does when its cable is pulled and plugged back in.
    private func reconnectScenario() async {
        useTestOutputOnly()
        check(model.inputs.isEmpty, "no input before the device appears")
        let uid = "local.sparkrecorder.reconnect.\(UUID().uuidString)"
        guard let first = makeTestDevice(uid: uid) else {
            check(false, "test device can be created")
            return
        }
        check(await waitUntil { model.selectedInput != nil }, "a connected device becomes the input")
        check(!model.isListening && model.phase == .idle, "connecting it starts nothing")

        model.toggleMonitor()
        check(await waitUntil { model.isMonitoring }, "level check runs")
        AudioHardwareDestroyAggregateDevice(first)
        check(await waitUntil { model.inputID == nil }, "pulling it leaves no input selected")
        check(await waitUntil { !model.isListening }, "listening ends with the device")
        await wait(0.5)
        check(model.inputs.isEmpty, "the app falls back to nothing, not to another device")
        await press("r", keyCode: 15)
        await wait(0.3)
        check(model.phase == .idle && audioFiles().isEmpty, "R does nothing while it is gone")
        await snapshot("reconnect-gone")

        guard let second = makeTestDevice(uid: uid) else {
            check(false, "test device can be created again")
            return
        }
        defer { AudioHardwareDestroyAggregateDevice(second) }
        check(await waitUntil { model.selectedInput != nil }, "plugging it back selects it again")
        await wait(1)
        check(!model.isListening && model.phase == .idle && audioFiles().isEmpty, "plugging it back starts nothing")
        await press("r", keyCode: 15)
        check(await waitUntil(timeout: 8) { model.phase == .recording }, "R records after it is back")
        await wait(1)
        await press("r", keyCode: 15)
        check(await waitUntil { model.phase == .idle }, "recording stops")
        check(model.recordings.count == 1 && audioFiles().count == 1, "the take is there")

        // A pulled cable during a recording keeps the take and leaves nothing listening.
        await press("r", keyCode: 15)
        _ = await waitUntil(timeout: 8) { model.phase == .recording }
        await wait(1)
        AudioHardwareDestroyAggregateDevice(second)
        check(await waitUntil(timeout: 4) { model.phase == .idle }, "pulling it during a recording ends the recording")
        check(model.recordings.count == 2, "audio up to the pull is kept")
        check(model.inputID == nil && !model.isListening, "afterwards there is no input and nothing listens")
    }

    // MARK: Real window

    /// Started through Launch Services, so this is the SwiftUI window a user gets. Nothing is recorded here, because
    /// the app's own microphone permission belongs to the user to grant.
    private func realWindowScenario() async {
        note("NOTE recordings \(model.recordings.count), usable \(model.libraryIsUsable), banner \(model.banner?.text ?? "none")")
        check(window?.isKeyWindow == true && window?.isMainWindow == true, "the window is key and main")
        check(!KeyRouter.isEditingText, "no text field has the focus at launch")
        note("NOTE first responder \(String(describing: window?.firstResponder)), full keyboard access \(NSApp.isFullKeyboardAccessEnabled), accessibility \(AXIsProcessTrusted())")
        useTestOutputOnly()
        await press(" ", keyCode: 49)
        check(await waitUntil(timeout: 2) { model.playhead.isPlaying }, "space plays the newest take without any click",
              detail: "current \(String(describing: model.currentID)), visible \(model.visibleRecordings.count), health \(model.visibleRecordings.map(\.health.rawValue)), banner \(model.banner?.text ?? "none"), key \(window?.isKeyWindow ?? false), active \(NSApp.isActive), modal \(String(describing: NSApp.modalWindow))")
        await wait(0.5)
        check(model.playhead.position > 0.1, "playhead moves", detail: "\(model.playhead.position)")
        await press(" ", keyCode: 49)
        check(!model.playhead.isPlaying, "space pauses")
        let id = model.currentID
        await press("3", keyCode: 20)
        check(model.current?.rating == 3, "number key rates", detail: "\(model.current?.rating ?? -1)")
        await press("3", keyCode: 20)
        check(model.current?.rating == 0, "the same number again clears the rating")
        // Keyboard use of the table must not lose the shortcuts.
        await press("", keyCode: 125)
        check(model.currentID != nil, "arrow down keeps a take in focus", detail: "\(String(describing: id))")
        await press(" ", keyCode: 49)
        check(await waitUntil(timeout: 2) { model.playhead.isPlaying }, "space still plays after using the table")
        await press(" ", keyCode: 49)
        await snapshotRealWindow()
    }

    private func useTestOutputOnly() {
        model.refreshDevices()
        let sink = model.outputs.first { $0.transport == kAudioDeviceTransportTypeVirtual && !$0.name.contains("BlackHole") }
        model.chooseOutput(sink?.id)
    }

    private func snapshotRealWindow() async {
        await snapshot("real-window")
    }

    // MARK: Crash

    /// Records until this process gets killed from outside.
    private func crashStartScenario() async {
        useTestDevices()
        startTone(amplitude: 0.1)
        await wait(0.4)
        await press("r", keyCode: 15)
        check(await waitUntil(timeout: 8) { model.phase == .recording }, "recording runs for the crash test")
        await press("m", keyCode: 46)
        note("READY")
        // The outside script kills the process with SIGKILL during this wait.
        await wait(600)
    }

    private func crashVerifyScenario() async {
        await wait(0.5)
        check(model.recordings.count == 1, "interrupted take is in the library", detail: "\(model.recordings.count)")
        guard let recording = model.recordings.first else { return }
        check(recording.recoveredAfterInterruption, "it is marked as recovered")
        check(recording.status == .open, "it waits for a decision")
        check(recording.markers.count == 1, "its marker survived", detail: "\(recording.markers.count)")
        check(recording.source != nil, "its source format survived")
        check(model.banner?.kind == .warning, "the repair is reported")
        check(!FileManager.default.fileExists(atPath: model.store.journalURL.path), "journal is gone")
        note("NOTE recovered \(String(format: "%.2f", recording.duration)) s")
        await snapshot("crash-recovered")
        let url = model.store.url(of: recording)
        if case .ok(let format, let frames) = WAVFile.inspect(url) {
            check(format.bits == 24, "repaired file is 24 bit")
            check(Double(frames) / format.sampleRate > 2, "audio up to the crash is there", detail: "\(frames) frames")
        } else {
            check(false, "repaired file is valid")
        }
        if let analysis = try? AudioAnalyzer.analyze(url) {
            check(abs(analysis.peak - 0.1) < 0.05, "repaired file holds the test tone", detail: "\(analysis.peak)")
        } else {
            check(false, "repaired file can be read")
        }
        model.select(recording.id)
        useTestDevices()
        await press(" ", keyCode: 49)
        check(await waitUntil { model.playhead.isPlaying }, "repaired take plays")
        await press(" ", keyCode: 49)
    }

    // MARK: Old recordings

    private func legacyScenario() async {
        await wait(1)
        let names = Set(model.recordings.map(\.fileName))
        note("NOTE adopted \(names.count) files")
        check(names.count == 3, "all three synthetic old files are adopted", detail: "\(names)")
        check(model.recordings.allSatisfy { $0.status == .kept && $0.source == nil }, "old files are kept, with unknown source")
        check(model.recordings.allSatisfy { !$0.edit.autoLevelEnabled }, "old files get no gain")
        let broken = model.recordings.first { $0.fileName == "abgestuerzt.wav" }
        check(broken?.recoveredAfterInterruption == true && (broken?.duration ?? 0) > 0.9, "old file with a broken header is repaired")
        let first = model.recordings.first { $0.fileName == "Aufnahme_2026-11-01_10-00-00.wav" }
        if let first { model.select(first.id) }
        check(await waitUntil(timeout: 5) { model.currentWaveform != nil }, "old file gets a waveform in the background")
        check(model.current?.peakDB != nil, "its peak was measured")
        await snapshot("legacy")
    }

    // MARK: Pictures

    /// A filled library in both appearances, for looking at the design.
    private func pictureScenario() async {
        useTestDevices()
        let piece = model.store.addPiece(named: "Blues in A")
        if let id = piece?.id {
            // A song with its parts, shown open in the pieces' picture.
            model.store.updatePiece(id) {
                $0.artist = "Übungsband"
                $0.bpm = 96
                $0.key = "A-Dur"
                $0.notes = "Solo erst ab Takt 13, vorher nur Akkorde."
                $0.parts = [PiecePart(name: "Intro"), PiecePart(name: "Strophe"), PiecePart(name: "Solo")]
            }
            model.expandedPieces = [id]
        }
        let names = ["Blues in A, Take 1", "Blues in A, Take 2", "Tonleiter E-Moll", "Akkordwechsel langsam", "Solo Ideen"]
        for (index, name) in names.enumerated() {
            let url = model.store.folder.appendingPathComponent("\(name).wav")
            var samples = [Float](repeating: 0, count: 44_100 * 24)
            for frame in samples.indices {
                let time = Double(frame) / 44_100
                let phrase = abs(sin(time * 0.9 + Double(index)))
                let pluck = exp(-(time.truncatingRemainder(dividingBy: 0.5 + Double(index) * 0.1)) * 7)
                samples[frame] = Float(0.45 * phrase * pluck * sin(2 * .pi * 220 * time))
            }
            try? WAVWriter.write(samples: samples, sampleRate: 44_100, channels: 1, to: url)
            let recording = Recording(
                fileName: url.lastPathComponent,
                createdAt: Date().addingTimeInterval(-Double(index) * 90_000),
                duration: 24, sampleRate: 44_100, channels: 1, fileBits: 24,
                source: SourceFormat(deviceName: "Spark MINI USB", bits: 16, sampleRate: 44_100, channels: 1),
                status: index == 0 ? .open : .kept,
                rating: [0, 4, 3, 5, 2][index],
                favorite: index == 3,
                tags: index < 2 ? ["Blues"] : [],
                note: index == 1 ? "Der Lauf in Takt 5 sitzt jetzt." : "",
                markers: index == 0 ? [Marker(time: 6, label: "Refrain"), Marker(time: 15, label: "Solo")] : [],
                pieceID: index < 2 ? piece?.id : nil,
                edit: EditList(autoLevelEnabled: true, autoLevelDB: 7.9),
                peakDB: -8.9
            )
            model.store.add(recording)
            model.store.logPractice(date: recording.createdAt, seconds: Double(600 + index * 400), pieceID: index < 2 ? piece?.id : nil)
        }
        try? model.store.save()
        model.scanFolder(announceNothing: true)
        if let first = model.store.document.recordings.first { model.select(first.id) }
        _ = await waitUntil(timeout: 5) { model.currentWaveform != nil }
        model.seek(to: 8)
        model.setLoop(10...17)
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            NSApp.appearance = NSAppearance(named: appearance)
            model.tab = .recordings
            await snapshot("library-\(suffix)")
            model.tab = .stats
            await snapshot("stats-\(suffix)")
            model.tab = .pieces
            await snapshot("pieces-\(suffix)")
        }
        model.tab = .recordings

        // The smallest window must not cut anything off.
        if let window, let frame = Optional(window.frame) {
            window.setContentSize(window.contentMinSize)
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                NSApp.appearance = NSAppearance(named: appearance)
                await snapshot("smallest-\(suffix)")
            }
            window.setFrame(frame, display: true)
        }

        // Other areas, such as the tuner with a synthetic string.
        if let extra = Self.extraPictures {
            for step in extra.steps {
                step.show()
                // Long enough for the tuner to settle on its synthetic string.
                await wait(1.6)
                for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    await snapshot("\(step.name)-\(suffix)")
                }
            }
            if let window, let step = extra.steps.first {
                let frame = window.frame
                step.show()
                window.setContentSize(window.contentMinSize)
                await wait(1.6)
                for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    await snapshot("\(step.name)-smallest-\(suffix)")
                }
                window.setFrame(frame, display: true)
            }
            extra.done()
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        // The deck while counting in and recording, from the test device only.
        guard model.selectedInput.map({ $0.name.contains("BlackHole") || $0.name == InputPolicy.testDeviceName }) == true else {
            note("NOTE no test input, so no recording pictures")
            return
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        model.updateMetronome { $0.countInBars = 1; $0.bpm = 100 }
        model.toggleRecord()
        if await waitUntil(timeout: 3, { if case .countIn = model.phase { return true } else { return false } }) {
            await snapshot("countin-dark")
        }
        if await waitUntil(timeout: 8, { model.isRecording }) {
            await wait(1.5)
            model.addMarker()
            await snapshot("recording-dark")
            NSApp.appearance = NSAppearance(named: .aqua)
            await snapshot("recording-light")
            model.toggleRecord()
        }
        model.updateMetronome { $0.countInBars = 0 }
    }
}
