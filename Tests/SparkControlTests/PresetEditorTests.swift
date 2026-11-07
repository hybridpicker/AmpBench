import XCTest
@testable import SparkControl

final class PresetEditorTests: XCTestCase {
    private func editor() -> PresetEditor { PresetEditor(PresetFactory.empty(name: "Test")) }

    func testAParameterChangeIsSentAndCanBeUndone() {
        var editor = editor()
        XCTAssertFalse(editor.isModified)
        let changes = editor.setParameter(place: 3, index: 0, value: 0.9)
        XCTAssertEqual(changes, [.parameter(effect: "Twin", index: 0, value: 0.9)])
        XCTAssertTrue(editor.isModified)
        XCTAssertEqual(editor.undo(), [.parameter(effect: "Twin", index: 0, value: 0.696)])
        XCTAssertFalse(editor.isModified)
        XCTAssertEqual(editor.redo(), [.parameter(effect: "Twin", index: 0, value: 0.9)])
    }

    func testValuesStayBetweenZeroAndOneAndNothingIsSentForNoChange() {
        var editor = editor()
        XCTAssertEqual(editor.setParameter(place: 3, index: 0, value: 3), [.parameter(effect: "Twin", index: 0, value: 1)])
        XCTAssertEqual(editor.setParameter(place: 3, index: 0, value: 1), [])
        XCTAssertEqual(editor.setParameter(place: 3, index: 9, value: 1), [])
        XCTAssertEqual(editor.setParameter(place: 12, index: 0, value: 1), [])
    }

    func testAKnobTurnIsOneUndoStep() {
        var editor = editor()
        editor.beginGesture()
        for step in 1...20 { _ = editor.setParameter(place: 3, index: 0, value: Float(step) / 20) }
        editor.endGesture()
        XCTAssertTrue(editor.canUndo)
        _ = editor.undo()
        XCTAssertFalse(editor.canUndo)
        XCTAssertFalse(editor.isModified)
    }

    func testSwitchingOnMovesTheMirrorParameter() {
        var editor = editor()
        XCTAssertEqual(editor.setOn(place: 6, true), [.toggle(effect: "bias.reverb", isOn: true)])
        XCTAssertEqual(editor.current.effects[6].parameters[7].value, 1)
        _ = editor.setOn(place: 6, false)
        XCTAssertEqual(editor.current.effects[6].parameters[7].value, 0)
        XCTAssertEqual(editor.setOn(place: 6, false), [])
    }

    func testAModelChangeSendsTheNewValuesAfterIt() {
        var editor = editor()
        let changes = editor.setModel(place: 3, to: "Plexi")
        XCTAssertEqual(changes.first, .model(from: "Twin", to: "Plexi"))
        XCTAssertEqual(changes.count, 6)
        XCTAssertEqual(changes.last, .parameter(effect: "Plexi", index: 4, value: 0.344))
        XCTAssertEqual(editor.current.effects[3].parameters.count, 5)

        // Undo goes back to the old model and its values, in an order the amp can follow.
        let back = editor.undo()
        XCTAssertEqual(back.first, .model(from: "Plexi", to: "Twin"))
        XCTAssertTrue(back.contains(.parameter(effect: "Twin", index: 0, value: 0.696)))
        XCTAssertEqual(back.last, .toggle(effect: "Twin", isOn: true))
        XCTAssertEqual(editor.current.effects[3].name, "Twin")
    }

    func testModelsWithAnotherParameterCount() {
        var editor = editor()
        _ = editor.setModel(place: 4, to: "GuitarEQ6")
        XCTAssertEqual(editor.current.effects[4].parameters.count, 7)
        _ = editor.setModel(place: 4, to: "Cloner")
        XCTAssertEqual(editor.current.effects[4].parameters.map(\.value), [0.249, 1])
    }

    func testBPMSendsTheWholePresetAndNamesSendNothing() {
        var editor = editor()
        guard case .whole(let preset) = editor.setBPM(96.4).first else { return XCTFail("expected the whole preset") }
        XCTAssertEqual(preset.bpm, 96)
        XCTAssertEqual(editor.setBPM(1000).count, 1)
        XCTAssertEqual(editor.current.bpm, 250)
        editor.setName("Neu")
        XCTAssertEqual(editor.current.name, "Neu")
        XCTAssertTrue(editor.canUndo)
    }

    func testRevertAndSave() {
        var editor = editor()
        _ = editor.setParameter(place: 0, index: 0, value: 0.9)
        _ = editor.setOn(place: 2, true)
        let changes = editor.revert()
        XCTAssertEqual(Set(changes.map { "\($0)" }).count, changes.count)
        XCTAssertFalse(editor.isModified)
        _ = editor.undo()
        XCTAssertTrue(editor.isModified)
        editor.markSaved()
        XCTAssertFalse(editor.isModified)
        XCTAssertTrue(editor.original.effects[2].isOn)
    }

    func testTheChecksumAloneIsNoChange() {
        var preset = PresetFactory.empty()
        preset.trailer[preset.trailer.count - 1] = 0x42
        var editor = PresetEditor(preset)
        editor.markSaved(PresetFactory.empty().withUUID(preset.uuid))
        XCTAssertFalse(editor.isModified)
    }

    func testEventsFromTheAmpAreFollowedWithoutUndo() {
        var editor = editor()
        editor.follow(.parameter(effect: "Twin", index: 1, value: 0.1))
        XCTAssertEqual(editor.current.effects[3].parameters[1].value, 0.1)
        XCTAssertFalse(editor.canUndo)
    }
}

final class LiveQueueTests: XCTestCase {
    func testOnlyTheNewestValueOfAKnobIsKept() {
        var queue = LiveQueue()
        for step in 1...10 { queue.push(.parameter(effect: "Twin", index: 0, value: Float(step) / 10)) }
        queue.push(.parameter(effect: "Twin", index: 1, value: 0.5))
        XCTAssertEqual(queue.items, [.parameter(effect: "Twin", index: 0, value: 1),
                                     .parameter(effect: "Twin", index: 1, value: 0.5)])
    }

    func testAModelChangeKeepsTheOrder() {
        var queue = LiveQueue()
        queue.push(.parameter(effect: "Twin", index: 0, value: 0.2))
        queue.push(.model(from: "Twin", to: "Plexi"))
        queue.push(.parameter(effect: "Plexi", index: 0, value: 0.3))
        queue.push(.parameter(effect: "Plexi", index: 0, value: 0.4))
        queue.push(.model(from: "Plexi", to: "Twin"))
        queue.push(.parameter(effect: "Twin", index: 0, value: 0.5))
        XCTAssertEqual(queue.items, [
            .parameter(effect: "Twin", index: 0, value: 0.2), .model(from: "Twin", to: "Plexi"),
            .parameter(effect: "Plexi", index: 0, value: 0.4), .model(from: "Plexi", to: "Twin"),
            .parameter(effect: "Twin", index: 0, value: 0.5),
        ])
        XCTAssertEqual(queue.next(), .parameter(effect: "Twin", index: 0, value: 0.2))
        XCTAssertEqual(queue.items.count, 4)
    }

    func testTogglesReplaceEachOtherAndAWholePresetReplacesEverything() {
        var queue = LiveQueue()
        queue.push(.toggle(effect: "DelayMono", isOn: true))
        queue.push(.toggle(effect: "DelayMono", isOn: false))
        XCTAssertEqual(queue.items, [.toggle(effect: "DelayMono", isOn: false)])
        let preset = PresetFactory.empty()
        queue.push(.whole(preset))
        queue.push(.parameter(effect: "Twin", index: 0, value: 1))
        XCTAssertEqual(queue.items, [.whole(preset), .parameter(effect: "Twin", index: 0, value: 1)])
    }

    func testModelChangesArePacedOut() {
        let clock = ContinuousClock()
        let now = clock.now
        let model = LiveChange.model(from: "Twin", to: "Plexi")
        XCTAssertEqual(LivePacing.wait(before: .parameter(effect: "Twin", index: 0, value: 0), now: now,
                                       recentModelChanges: [now]), .zero)
        XCTAssertEqual(LivePacing.wait(before: model, now: now, recentModelChanges: []), .zero)
        XCTAssertEqual(LivePacing.wait(before: model, now: now, recentModelChanges: [now - .milliseconds(400)]),
                       .milliseconds(600))
        let burst = (1...6).map { now - .seconds(12) + .seconds($0) }
        XCTAssertEqual(LivePacing.wait(before: model, now: now, recentModelChanges: burst), .seconds(9))
    }
}

final class PresetFactoryTests: XCTestCase {
    func testEmptyPresetHasTheSevenPlacesWithStartValues() {
        let preset = PresetFactory.empty()
        XCTAssertEqual(preset.effects.count, 7)
        for (index, effect) in preset.effects.enumerated() {
            XCTAssertEqual(ModelCatalog.known(effect.name)?.place, ChainPlace(rawValue: index))
        }
        XCTAssertEqual(preset.effects.filter(\.isOn).map(\.name), ["Twin"])
        XCTAssertEqual(preset.effects[0].parameters[2].value, 0, "gate mirror follows off")
        XCTAssertTrue(preset.hasChecksum)
        XCTAssertEqual(preset.trailerFloats, [9990, 0.5])
    }

    func testTemplatesUseKnownModelsInTheirPlaces() {
        XCTAssertEqual(PresetFactory.templates.count, 5)
        for template in PresetFactory.templates {
            XCTAssertEqual(template.preset.effects.count, 7, template.name)
            for (index, effect) in template.preset.effects.enumerated() {
                let info = ModelCatalog.known(effect.name)
                XCTAssertEqual(info?.place, ChainPlace(rawValue: index), "\(template.name) \(effect.name)")
                XCTAssertEqual(effect.parameters.count, info?.parameterCount, "\(template.name) \(effect.name)")
            }
            XCTAssertNil(PresetRules.problem(withName: template.preset.name))
        }
    }

    func testDuplicatesGetANewIdentityAndAFittingName() {
        let original = PresetFactory.empty(name: String(repeating: "ä", count: 15))
        let copy = PresetFactory.duplicate(original)
        XCTAssertNotEqual(copy.uuid, original.uuid)
        XCTAssertLessThanOrEqual(copy.name.utf8.count, 31)
        XCTAssertEqual(copy.effects, original.effects)
        XCTAssertNotEqual(PresetFactory.make(PresetFactory.templates[0]).uuid, PresetFactory.templates[0].preset.uuid)
    }

    func testNameRules() {
        XCTAssertNil(PresetRules.problem(withName: "Clean Funk"))
        XCTAssertNotNil(PresetRules.problem(withName: "  "))
        XCTAssertNotNil(PresetRules.problem(withName: String(repeating: "ü", count: 16)))
    }
}

private extension SparkPreset {
    func withUUID(_ uuid: String) -> SparkPreset {
        var copy = self
        copy.uuid = uuid
        return copy
    }
}
