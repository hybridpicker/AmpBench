import XCTest
@testable import SparkControl

final class SparkCommandsTests: XCTestCase {
    /// The single chunk of a message built without a block header, unpacked.
    private func payload(_ bytes: [UInt8]) -> SparkProtocol.Message? {
        SparkProtocol.Parser().feed(bytes).first
    }

    func testSetParameterBytes() {
        // Checked on a Spark MINI 1.11.2.75: the amp plays the new value, with and without the input byte.
        let message = SparkProtocol.setParameter(effect: "Twin", index: 0, value: 0.5, sequence: 1, header: false)
        XCTAssertEqual(message, [0xF0, 0x01, 0x01, 0x72, 0x01, 0x04,
                                 0x02, 0x04, 0x24, 0x54, 0x77, 0x69, 0x6E, 0x00,
                                 0x01, 0x4A, 0x3F, 0x00, 0x00, 0x00, 0x00, 0xF7])
        let decoded = payload(message)
        XCTAssertEqual(decoded?.command, 0x01)
        XCTAssertEqual(decoded?.sub, 0x04)
        XCTAssertEqual(decoded?.payload, [0x04, 0xA4] + Array("Twin".utf8) + [0x00, 0xCA, 0x3F, 0, 0, 0, 0x00])
        let short = SparkProtocol.setParameter(effect: "Twin", index: 0, value: 0.5, input: false, sequence: 1,
                                               header: false)
        XCTAssertEqual(payload(short)?.payload.count, 12)
    }

    func testSetEffectAndChangeModelBytes() {
        let toggle = payload(SparkProtocol.setEffect("DelayMono", on: true, sequence: 2, header: false))
        XCTAssertEqual(toggle?.sub, 0x15)
        XCTAssertEqual(toggle?.payload, [0x09, 0xA9] + Array("DelayMono".utf8) + [0xC3, 0x00])

        let model = payload(SparkProtocol.changeModel(from: "Rectifier", to: "Twin", sequence: 3, header: false))
        XCTAssertEqual(model?.sub, 0x06)
        XCTAssertEqual(model?.payload, [0x09, 0xA9] + Array("Rectifier".utf8) + [0x04, 0xA4] + Array("Twin".utf8) + [0x00])
    }

    func testCommandsCarryTheBlockHeader() {
        let message = SparkProtocol.setParameter(effect: "Twin", index: 1, value: 0.25, sequence: 4)
        XCTAssertEqual(Array(message.prefix(6)), [0x01, 0xFE, 0x00, 0x00, 0x53, 0xFE])
        XCTAssertEqual(Int(message[6]), message.count)
    }

    private func event(command: UInt8 = 0x03, sub: UInt8, _ payload: [UInt8]) -> SparkEvent? {
        SparkEvent(SparkProtocol.Message(command: command, sub: sub, sequence: 1, payload: payload, checksumOK: true))
    }

    func testEventsFromTheAmp() {
        let name = [0x09, 0xA9] + Array("Rectifier".utf8)
        let value = Synthetic.float(0.8)
        XCTAssertEqual(event(sub: 0x37, name + [0x00] + value),
                       .parameter(effect: "Rectifier", index: 0, value: 0.8))
        XCTAssertEqual(event(sub: 0x37, name + [0x02] + value + [0x00]),
                       .parameter(effect: "Rectifier", index: 2, value: 0.8))
        XCTAssertEqual(event(sub: 0x15, [0x0D, 0xAD] + Array("DistortionTS9".utf8) + [0xC2]),
                       .effectOnOff(effect: "DistortionTS9", isOn: false))
        XCTAssertEqual(event(sub: 0x06, name + [0x04, 0xA4] + Array("Twin".utf8) + [0x00]),
                       .modelChanged(from: "Rectifier", to: "Twin"))
        XCTAssertEqual(event(sub: 0x38, [0x00, 0x02]), .presetSelected(slot: 2))
        XCTAssertEqual(event(sub: 0x27, [0x00, 0x01]), .storeRequested(slot: 1))
        XCTAssertEqual(event(sub: 0x64, [0x04] + Synthetic.float(-1)), .tuner(note: 4, offset: nil))
        XCTAssertEqual(event(sub: 0x64, [0x09] + Synthetic.float(0.5)), .tuner(note: 9, offset: 0.5))
        XCTAssertEqual(event(sub: 0x65, [0xC3]), .tunerOn(true))
        XCTAssertEqual(event(sub: 0x63, Synthetic.float(96)), .tapTempo(bpm: 96))
        XCTAssertEqual(event(command: 0x04, sub: 0x15, []), .acknowledged(sub: 0x15))
        // A preset is no event, and a broken message is dropped.
        XCTAssertNil(event(sub: 0x01, Synthetic.presetPayload()))
        XCTAssertNil(event(sub: 0x37, [0x09, 0xA9, 0x41]))
        // The prefix must state the string's real length.
        XCTAssertNil(event(sub: 0x15, [0x05, 0xA4] + Array("Twin".utf8) + [0xC3]))
    }

    func testEventsUpdateACopyOfThePreset() throws {
        var preset = try SparkPreset(payload: Synthetic.presetPayload())
        XCTAssertTrue(preset.apply(.parameter(effect: "Twin", index: 1, value: 0.75)))
        XCTAssertEqual(preset.effects[1].parameters[1].value, 0.75)
        XCTAssertTrue(preset.apply(.effectOnOff(effect: "bias.noisegate", isOn: true)))
        XCTAssertTrue(preset.effects[0].isOn)
        XCTAssertTrue(preset.apply(.modelChanged(from: "Twin", to: "Plexi")))
        XCTAssertEqual(preset.effects[1].name, "Plexi")
        XCTAssertFalse(preset.apply(.parameter(effect: "Twin", index: 0, value: 0)))
        XCTAssertFalse(preset.apply(.parameter(effect: "Plexi", index: 9, value: 0)))
        XCTAssertFalse(preset.apply(.tunerOn(true)))
    }

    func testChecksumIsKeptForReadPresetsAndRecomputedForEdits() throws {
        let payload = Synthetic.presetPayload()
        var preset = try SparkPreset(payload: payload)
        XCTAssertTrue(preset.hasChecksum)
        XCTAssertTrue(preset.checksumMatches)
        XCTAssertEqual(preset.trailerFloats, [9990, 0.5])
        XCTAssertEqual(preset.encode(place: .slot(2)), payload)

        preset.name = "Test Clean 2"
        XCTAssertFalse(preset.checksumMatches)
        let edited = preset.encode(place: .temporary)
        XCTAssertEqual(edited.last, Synthetic.checksum(edited.dropFirst(2).dropLast()))
        let again = try SparkPreset(payload: edited)
        XCTAssertTrue(again.checksumMatches)
        XCTAssertEqual(again.name, "Test Clean 2")
    }

    func testPlayingPresetHasOnlyAChecksum() throws {
        var payload = Synthetic.presetPayload()
        payload.removeLast(11)
        payload.append(Synthetic.checksum(payload.dropFirst(2)))
        let preset = try SparkPreset(payload: payload)
        XCTAssertEqual(preset.trailer.count, 1)
        XCTAssertTrue(preset.checksumMatches)
        XCTAssertEqual(preset.trailerFloats, [])
        XCTAssertEqual(preset.encode(place: .slot(2)), payload)
    }

    func testTrailerWithoutChecksumStaysUntouched() throws {
        var preset = try SparkPreset(payload: Synthetic.presetPayload())
        preset.trailer = []
        XCTAssertFalse(preset.hasChecksum)
        XCTAssertEqual(preset.encode(place: .slot(0)).count, Synthetic.presetPayload().count - 11)
        preset.trailer = [0xCA, 0x00]
        XCTAssertFalse(preset.hasChecksum)
        XCTAssertEqual(Array(preset.encode(place: .slot(0)).suffix(2)), [0xCA, 0x00])
    }

    func testNewPresetsGetTheStandardTrailer() {
        let preset = SparkPreset(name: "Neu", effects: [])
        XCTAssertEqual(preset.trailerFloats, [9990, 0.5])
        let bytes = preset.encode(place: .temporary)
        XCTAssertEqual(bytes.last, Synthetic.checksum(bytes.dropFirst(2).dropLast()))
    }
}
