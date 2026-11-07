import AVFoundation
import AppKit
import ApplicationServices
import CoreAudio
import SparkCore
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

    private var window: NSWindow? { AppDelegate.mainWindow }

    private func snapshot(_ name: String) async {
        await wait(0.25)
        guard let view = window?.contentView, let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            note("NOTE no window for snapshot \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?
            .write(to: output.appendingPathComponent("\(name).png"))
    }

    /// Posts a real key event. It takes the same path as a key press, through the event monitor and menus.
    private func press(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) async {
        guard let window else { return }
        // These tests must only ever hear the virtual test device, never a real input.
        if characters == "r" || characters == "g" {
            let name = model.selectedInput?.name ?? ""
            guard name.contains("BlackHole") || name.contains("SparkRecorder Test Device") else {
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
        default: note("FAIL unknown scenario")
        }
        await finish()
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
            await pressCommandDelete()
            check(!model.recordings.contains { $0.id == target.id }, "⌘⌫ discards the selected take")
            check(!FileManager.default.fileExists(atPath: url.path), "file left the folder")
            let trashPath = model.store.document.trashed.last?.trashPath ?? ""
            check(trashPath.contains(".Trash") && FileManager.default.fileExists(atPath: trashPath), "file is in the Trash")
            await snapshot("05-discarded")
            window?.undoManager?.undo()
            await wait(0.3)
            check(model.recordings.contains { $0.id == target.id }, "undo brings the take back")
            check(FileManager.default.fileExists(atPath: url.path), "file is back in the folder")
        }

        // Single keys can never delete.
        let before = model.recordings.count
        for letter in "abcdefghijklmnopqstuvwxyz" where !"r".contains(letter) {
            await press(String(letter))
        }
        await press("", keyCode: 51)
        await press("", keyCode: 117)
        check(model.recordings.count == before, "no single key removes a recording")
        // Undo what the letters above switched on.
        model.clearLoop()
        if model.playhead.isPlaying { await press(" ", keyCode: 49) }
        if model.isClickRunning { model.toggleClick() }
        if model.current?.favorite == true { model.toggleFavorite() }

        await libraryChecks(first: first)
        await practiceChecks(first: first)
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

        // Metronome and count-in.
        await press("n", keyCode: 45)
        check(model.isClickRunning, "N starts the metronome")
        await wait(0.7)
        check(model.meter.beat > 0, "beats are counted", detail: "\(model.meter.beat)")
        await press("n", keyCode: 45)
        check(!model.isClickRunning, "N stops it")
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
        await press(" ", keyCode: 49)
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
        await press(" ", keyCode: 49)
        check(model.playhead.isPlaying, "playback to another output works during a recording")
        await wait(0.6)
        await press(" ", keyCode: 49)
        await press("r", keyCode: 15)
        _ = await waitUntil { model.phase == .idle }
        check(model.meter.droppedFrames == 0, "no dropouts")
    }

    private func deviceLossChecks() async {
        guard let blackHole = model.inputs.first(where: { $0.name.contains("BlackHole") }) else { return }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SparkRecorder Test Device",
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
    }
}
