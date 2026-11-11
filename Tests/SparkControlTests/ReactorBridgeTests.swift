import XCTest
@testable import SparkControl

/// A REACTOR preset with the effect models seen on a REACTOR 50, built from scratch, never a real one.
enum ReactorChainFixture {
    static let effects: [(UInt16, Bool, [Float])] = [
        (0x0309, true, [0.375, 0.9, 1]), (0x0416, false, [0.72, 0.56, 0]), (0x0422, false, [0.558, 0, 0.905]),
        (0x040C, false, [0.5, 0, 0.5, 0.5, 0.5, 0.5]), (0x040D, true, [7]),
        (0x042C, true, [0.9, 0.45, 0.48, 0.5, 0.55, 0.57, 0.52, 0.46]), (0x0419, false, [0.3, 0]),
        (0x0432, false, [0.48, 0.38, 0.34, 0.45, 0]), (0x0411, true, [0.12, 0.5, 0.4, 0.35, 0.1, 0.7, 0, 1]),
        (0x0412, false, [0.5, 0.5, 1, 1]),
    ]

    static func preset(slot: Int = 1, name: String = "Warm Edge", amp: String = "Tweed Tone") -> [UInt8] {
        let fixed: [(UInt16, [Float])] = [
            (0x0503, [0.009, 0.507, 0.526, 0.67]), (0x0502, [0.793, 2, 10, 10] + [Float](repeating: 0.5, count: 141)),
            (0x0505, [0.314, 0, 5, 10] + [Float](repeating: 1000, count: 106)), (0x0506, [Float](repeating: 0.2, count: 11)),
            (0x0434, [Float](repeating: 0.5, count: 30)), (0x0435, [Float](repeating: -3.6, count: 30)),
        ]
        var data: [UInt8] = [0x00, UInt8(slot)] + ReactorFixture.card(name, icon: "icon.png", tags: ["warm"])
        data += [0xCA, 0x42, 0xF0, 0x00, 0x00] + ReactorFixture.card(amp, icon: "f_amp_Test.png", tags: [])
        data += [0x96] + fixed.flatMap { ReactorFixture.block($0.0, on: true, $0.1) }
        data += [0x9A] + effects.flatMap { ReactorFixture.block($0.0, on: $0.1, $0.2) }
        return data + ReactorPreset.checksum(of: data.dropFirst(2))
    }
}

final class ReactorBridgeTests: XCTestCase {
    private func read(_ data: [UInt8] = ReactorChainFixture.preset()) throws -> ReactorPreset { try ReactorPreset(data: data) }

    func testAnUnchangedPresetIsWrittenByteForByte() throws {
        let data = ReactorChainFixture.preset()
        let preset = try read(data)
        XCTAssertEqual(try preset.rewritten(slot: 1), data)
        var other = try preset.rewritten(slot: 6)
        XCTAssertEqual(other[1], 6)
        other[1] = 1
        XCTAssertEqual(other, data, "the checksum does not cover the slot")
    }

    func testItShowsAsTheSevenPlaces() throws {
        let spark = try XCTUnwrap(ReactorBridge.sparkPreset(try read()))
        XCTAssertTrue(ReactorBridge.isReactor(spark))
        XCTAssertEqual(spark.name, "Warm Edge")
        XCTAssertEqual(spark.bpm, 120)
        XCTAssertEqual(spark.effects.map(\.name), ["bias.noisegate", "BBEOpticalComp", "DistortionTS9", "REACTOR amp: Tweed Tone",
                                                   "ChorusCloner", "REACTOR model 0432", "MonoReverb"])
        XCTAssertEqual(spark.effects.map(\.isOn), [true, false, false, true, false, false, true])
        let amp = spark.effects[ChainPlace.amp.rawValue].parameters.map(\.value)
        for (value, expected) in zip(amp, [0.793, 0.507, 0.526, 0.67, 0.314] as [Float]) {
            XCTAssertEqual(value, expected, accuracy: 0.001)
        }
        let info = ModelCatalog.info(for: spark.effects[3].name, place: .amp, parameterCount: 5)
        XCTAssertEqual(info.englishName, "Tweed Tone")
        XCTAssertEqual(info.parameters.map(\.englishName), ["Gain", "Bass", "Middle", "Treble", "Master"])
        XCTAssertNil(ModelCatalog.known(spark.effects[3].name), "the Spark catalog stays as it is")
    }

    func testEditedValuesGoBackIntoItsOwnBytes() throws {
        let base = try read()
        var editor = PresetEditor(try XCTUnwrap(ReactorBridge.sparkPreset(base)))
        _ = editor.setParameter(place: ChainPlace.reverb.rawValue, index: 0, value: 0.75)
        _ = editor.setOn(place: ChainPlace.drive.rawValue, true)
        _ = editor.setParameter(place: ChainPlace.amp.rawValue, index: 0, value: 0.25)
        _ = editor.setParameter(place: ChainPlace.amp.rawValue, index: 3, value: 0)
        _ = editor.setBPM(96)
        editor.setName("Warm Edge 2")
        let data = try ReactorBridge.data(for: editor.current, base: base, slot: 3)
        let stored = try ReactorPreset(data: data)
        XCTAssertTrue(stored.checksumOK)
        XCTAssertEqual(stored.slot, 3)
        XCTAssertEqual(stored.name, "Warm Edge 2")
        XCTAssertEqual(stored.tempo, 96)
        XCTAssertEqual(stored.effects.first { $0.id == 0x0411 }?.values[0], 0.75)
        XCTAssertEqual(stored.effects.first { $0.id == 0x0422 }?.isOn, true)
        XCTAssertEqual(stored.fixed.first { $0.id == 0x0502 }?.values[0], 0.25)
        XCTAssertEqual(stored.fixed.first { $0.id == 0x0503 }?.values[3], 0)
        // Everything else is as it was: wah, equalizer, FX loop and the amp's other values.
        XCTAssertEqual(stored.effects.first { $0.id == 0x042C }, base.effects.first { $0.id == 0x042C })
        XCTAssertEqual(stored.fixed.first { $0.id == 0x0505 }, base.fixed.first { $0.id == 0x0505 })
        XCTAssertEqual(stored.amp, base.amp)
        // Read again, it is the edited preset.
        XCTAssertEqual(ReactorBridge.sparkPreset(stored), editor.current)
    }

    func testOnlyItsOwnPresetIsTakenBack() throws {
        let base = try read()
        XCTAssertThrowsError(try ReactorBridge.data(for: PresetFactory.empty(), base: base, slot: 0))
        var changed = try XCTUnwrap(ReactorBridge.sparkPreset(base))
        changed.effects[ChainPlace.drive.rawValue].name = "Overdrive"
        XCTAssertThrowsError(try ReactorBridge.data(for: changed, base: base, slot: 0), "no model change")
    }

    func testLiveCommandsUseTheNamesItTakes() {
        let amp = "REACTOR amp: Tweed Tone"
        XCTAssertEqual(ReactorBridge.live(.parameter(effect: amp, index: 0, value: 0.5)),
                       .parameter(name: "Amp.Preamp", index: 0, value: 0.5))
        XCTAssertEqual(ReactorBridge.live(.parameter(effect: amp, index: 2, value: 0.5)),
                       .parameter(name: "Amp.Tonestack", index: 2, value: 0.5))
        XCTAssertEqual(ReactorBridge.live(.parameter(effect: amp, index: 4, value: 0.5)),
                       .parameter(name: "Amp.Poweramp", index: 0, value: 0.5))
        XCTAssertEqual(ReactorBridge.live(.toggle(effect: "MonoReverb", isOn: false)), .toggle(name: "MonoReverb", isOn: false))
        XCTAssertNil(ReactorBridge.live(.toggle(effect: amp, isOn: false)))
        XCTAssertNil(ReactorBridge.live(.parameter(effect: "REACTOR model 0432", index: 0, value: 0.5)))
        XCTAssertNil(ReactorBridge.live(.model(from: "DistortionTS9", to: "Overdrive")))
    }

    func testAPresetWithModelsThatCannotBeToldApartStaysOutOfTheEditor() throws {
        XCTAssertNil(ReactorBridge.sparkPreset(try ReactorPreset(data: ReactorFixture.preset(slot: 0, name: "A", amp: "B"))))
    }

    func testTheStoreFramesCarryThePresetInChunks() throws {
        let data = ReactorChainFixture.preset()
        let frames = ReactorPreset.storeFrames(data, sequence: 5)
        XCTAssertEqual(frames.count, (data.count + 349) / 350)
        let parser = SparkProtocol.Parser()
        let messages = frames.flatMap { parser.feed($0) }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.command, SparkProtocol.Command.set)
        XCTAssertEqual(ReactorPreset.joined(messages.first?.payload ?? []), data)
    }
}
