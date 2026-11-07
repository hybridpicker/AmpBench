import AppKit
import SparkControl

/// Checks live editing end to end on the real amp: `--live-selftest <log file>`. It edits a copy of stored preset 1
/// through the same code the window uses, then reads back what the amp plays and compares. Everything happens on
/// the temporary place 7F, nothing is stored, and it ends by switching back to preset 1. It makes only two model
/// changes, far below what once made the amp hang.
@MainActor
enum LiveSelfTest {
    static func run(_ model: PresetsModel) async {
        guard let path = Snapshot.arguments["live-selftest"], !path.isEmpty else { return }
        var lines: [String] = []
        var failures = 0
        func note(_ text: String) {
            lines.append(text)
            print(text)
        }
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            note("\(ok ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        let link = model.link, editor = model.editor
        let started = Date()
        link.trace = { line in lines.append(String(format: "    %6.2f ", Date().timeIntervalSince(started)) + line) }
        note("Waiting for the amp …")
        guard await until(seconds: 40, { link.status == .connected && link.slots.allSatisfy { $0 != nil } }) else {
            note("FAIL the amp was not connected and read within 40 seconds")
            finish(lines, path, failures: 1)
            return
        }
        // Clicking two slots quickly and turning a knob at once: the switches must come first, the edit last.
        model.select(.slot(1))
        model.select(.slot(0))
        guard let start = editor.preset, start.effects.count == 7 else {
            note("FAIL stored preset 1 has no chain of 7")
            finish(lines, path, failures: 1)
            return
        }
        note("Editing a copy of \"\(start.name)\" on the temporary place.")

        func verify(_ label: String, against wanted: SparkPreset?) async {
            _ = await until(seconds: 20) { !editor.isSending && link.activity == nil }
            try? await Task.sleep(for: .milliseconds(400))
            guard let wanted, let playing = try? await link.readPreset(.playing) else {
                check(label, false, "could not read the playing preset")
                return
            }
            let differences = LiveChange.between(playing, wanted)
            check(label, differences.isEmpty, differences.map { "\($0)" }.joined(separator: "; "))
        }

        let gain = start.effects[3].parameters[0].value
        editor.setParameter(place: 3, index: 0, value: gain > 0.5 ? 0.3 : 0.7)
        await verify("first change sends the whole preset, then plays live", against: editor.preset)
        check("the amp plays the edit", link.isEditingLive)

        editor.setOn(place: 2, !start.effects[2].isOn)
        await verify("effect on or off", against: editor.preset)

        editor.beginGesture()
        for step in 0...30 { editor.setParameter(place: 3, index: 1, value: Float(step) / 30) }
        editor.endGesture()
        await verify("a fast knob turn arrives with its last value", against: editor.preset)

        let modulation = start.effects[4].name == "Flanger" ? "Tremolo" : "Flanger"
        editor.setModel(place: 4, to: modulation)
        await verify("model change with start values", against: editor.preset)
        editor.undo()
        await verify("undo of the model change", against: editor.preset)

        editor.setBPM(start.bpm == 100 ? 110 : 100)
        await verify("BPM sends the whole preset", against: editor.preset)

        editor.toggleComparison()
        await verify("A/B plays the saved state", against: editor.editor?.original)
        editor.toggleComparison()
        await verify("A/B back to the edit", against: editor.editor?.current)

        editor.revert()
        model.play(slot: 0)
        _ = await until(seconds: 10) { link.activeSlot == 0 && !model.isBusy }
        check("back on stored preset 1", link.activeSlot == 0 && !link.isEditingLive)
        finish(lines, path, failures: failures)
    }

    private static func until(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private static func finish(_ lines: [String], _ path: String, failures: Int) {
        let text = (lines + ["\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")"]).joined(separator: "\n") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
