@testable import SparkControl
import XCTest

/// The REACTOR's own messages, built as it sends them (Spark frames without block header), with the contents seen on
/// 2026-11-09 when every control was used once.
final class ReactorDecoderTests: XCTestCase {
    private func wire(_ sub: UInt8, _ payload: [UInt8], sequence: UInt8 = 0x10) -> [UInt8] {
        SparkProtocol.frame(command: SparkProtocol.Command.response, sub: sub, payload: payload, sequence: sequence,
                            header: false)
    }

    private func parameter(_ block: String, _ index: UInt8, _ value: Float) -> [UInt8] {
        var writer = SparkWriter()
        writer.prefixedString(block)
        writer.bytes([index])
        writer.float(value)
        return wire(SparkProtocol.Sub.parameterChanged, writer.data)
    }

    private func onOff(_ model: String, _ isOn: Bool) -> [UInt8] {
        var writer = SparkWriter()
        writer.prefixedString(model)
        writer.bool(isOn)
        return wire(SparkProtocol.Sub.effectOnOff, writer.data)
    }

    private func float(_ sub: UInt8, prefix: [UInt8] = [], _ value: Float) -> [UInt8] {
        var writer = SparkWriter()
        writer.bytes(prefix)
        writer.float(value)
        return wire(sub, writer.data)
    }

    private func decode(_ frames: [[UInt8]], into state: inout ReactorState) {
        let parser = SparkProtocol.Parser()
        // Notifications split the bytes anywhere.
        let bytes = frames.flatMap { $0 }
        for start in stride(from: 0, to: bytes.count, by: 7) {
            for message in parser.feed(Array(bytes[start..<min(start + 7, bytes.count)])) { state.apply(message) }
        }
    }

    func testTheAmpKnobs() {
        var state = ReactorState()
        decode([parameter("Amp.Preamp", 0, 0.62), wire(0x1A, [0x91, 0x00, 0x02, 0xC3]),
                parameter("Amp.Tonestack", 1, 0.3), parameter("Amp.Tonestack", 2, 0.45),
                parameter("Amp.Tonestack", 3, 0.8), parameter("Amp.Poweramp", 0, 0.5),
                wire(0x1A, [0x91, 0x00, 0x02, 0xC3])], into: &state)
        XCTAssertEqual(state.knobs[.gain] ?? -1, 0.62, accuracy: 1e-6)
        XCTAssertEqual(state.knobs[.bass] ?? -1, 0.3, accuracy: 1e-6)
        XCTAssertEqual(state.knobs[.middle] ?? -1, 0.45, accuracy: 1e-6)
        XCTAssertEqual(state.knobs[.treble] ?? -1, 0.8, accuracy: 1e-6)
        XCTAssertEqual(state.knobs[.master] ?? -1, 0.5, accuracy: 1e-6)
        // 03 1A is counted, never interpreted.
        XCTAssertEqual(state.unknown, ["03 1A": 2])
    }

    func testTheAmpSelectorPushSmoothAndHeat() {
        var state = ReactorState()
        // Crunch, switch in the middle (Standard), Heat in the middle: 5 × 1 + 2.
        decode([wire(ReactorState.ampSelector, [3, 7])], into: &state)
        XCTAssertEqual(state.ampName, "Crunch")
        XCTAssertEqual(state.voiceName, "Standard")
        XCTAssertEqual(state.heat, 2)
        // Seen: Push 2–4, Standard 5–9, Smooth 12–14.
        decode([wire(ReactorState.ampSelector, [0, 4])], into: &state)
        XCTAssertEqual(state.ampName, "Clean")
        XCTAssertEqual(state.voice, 0)
        XCTAssertEqual(state.heat, 4)
        decode([wire(ReactorState.ampSelector, [5, 12])], into: &state)
        XCTAssertEqual(state.ampName, "Extreme")
        XCTAssertEqual(state.voiceName, "Smooth")
        XCTAssertEqual(state.heat, 2)
        // Out of range: not taken, counted.
        decode([wire(ReactorState.ampSelector, [6, 0])], into: &state)
        XCTAssertEqual(state.ampName, "Extreme")
        XCTAssertEqual(state.unknown["03 B1"], 1)
    }

    func testFXKeysOnOffPlaceAndLevel() {
        var state = ReactorState()
        decode([onOff("MonoReverb", true), wire(ReactorState.selectedEffect, [6, 0xC3]),
                parameter("MonoReverb", 0, 0.4), wire(0x1A, [0x91, 0x00, 0x02, 0xC3]),
                onOff("DistortionTS9", false)], into: &state)
        XCTAssertEqual(state.effects["MonoReverb"]?.isOn, true)
        XCTAssertEqual(state.effects["MonoReverb"]?.place, 6)
        XCTAssertEqual(state.effects["MonoReverb"]?.level ?? -1, 0.4, accuracy: 1e-6)
        XCTAssertEqual(state.selectedPlace, 6)
        XCTAssertEqual(state.selectedEffect?.model, "MonoReverb")
        XCTAssertEqual(state.levelModel, "MonoReverb")
        XCTAssertEqual(state.effects["DistortionTS9"]?.isOn, false)
        XCTAssertNil(state.effects["DistortionTS9"]?.place, "switching off reports no place")
        // A short press alone selects a place.
        decode([wire(ReactorState.selectedEffect, [2, 0xC3])], into: &state)
        XCTAssertEqual(state.selectedPlace, 2)
        XCTAssertNil(state.effects["DistortionTS9"]?.place, "only an effect just switched on learns its place")
    }

    func testTapTempo() {
        var state = ReactorState()
        decode([float(SparkProtocol.Sub.tapTempo, 116), parameter("DelayEchoFilt", 4, 1.0)], into: &state)
        XCTAssertEqual(state.tempo ?? 0, 116, accuracy: 1e-4)
        XCTAssertEqual(state.effects["DelayEchoFilt"]?.parameters[4], 1.0)
        XCTAssertNil(state.effects["DelayEchoFilt"]?.level)
        decode([float(SparkProtocol.Sub.tapTempo, 83)], into: &state)
        XCTAssertEqual(state.tempo ?? 0, 83, accuracy: 1e-4)
    }

    func testPresetAndBankKeysMakeTheContentUnknown() {
        var state = ReactorState()
        decode([parameter("Amp.Preamp", 0, 0.7), wire(ReactorState.ampSelector, [1, 6])], into: &state)
        XCTAssertTrue(state.hasReadings)
        // The preset key reports its slot twice, the bank key once.
        decode([wire(SparkProtocol.Sub.hardwarePreset, [0x00, 0x01]),
                wire(SparkProtocol.Sub.hardwarePreset, [0x00, 0x01])], into: &state)
        XCTAssertEqual(state.slot, 1)
        XCTAssertEqual(state.bank, 0)
        XCTAssertFalse(state.hasReadings, "the REACTOR does not send the preset, so nothing of it is known")
        decode([parameter("Amp.Tonestack", 3, 0.25)], into: &state)
        XCTAssertEqual(state.knobs, [.treble: 0.25], "what is turned after the change shows")
        // The same slot again keeps what was read since.
        decode([wire(SparkProtocol.Sub.hardwarePreset, [0x00, 0x01])], into: &state)
        XCTAssertEqual(state.knobs, [.treble: 0.25])
        // Bank key: Rot 2 to Grün 4.
        decode([wire(SparkProtocol.Sub.hardwarePreset, [0x00, 0x07])], into: &state)
        XCTAssertEqual(state.slot, 7)
        XCTAssertEqual(state.bank, 1)
        XCTAssertEqual(DeviceProfile.reactor50.slotName(state.slot!), "Grün 4")
        XCTAssertTrue(state.knobs.isEmpty)
        // There is no ninth slot.
        decode([wire(SparkProtocol.Sub.hardwarePreset, [0x00, 0x08])], into: &state)
        XCTAssertEqual(state.slot, 7)
    }

    func testTheTunerHeldOnTheBankKey() {
        var state = ReactorState()
        decode([wire(SparkProtocol.Sub.tuner, [0xC3]), float(SparkProtocol.Sub.tunerPitch, prefix: [0x00], -1)],
               into: &state)
        XCTAssertTrue(state.tunerOn)
        XCTAssertNil(state.tunerReading, "−1 means no signal")
        decode([float(SparkProtocol.Sub.tunerPitch, prefix: [0x00], 0.47)], into: &state)
        XCTAssertEqual(state.tunerReading ?? -1, 0.47, accuracy: 1e-6)
        decode([wire(SparkProtocol.Sub.tuner, [0xC2])], into: &state)
        XCTAssertFalse(state.tunerOn)
        XCTAssertNil(state.tunerReading)
    }

    func testAcknowledgementsAndUnknownMessagesAreOnlyCounted() {
        var state = ReactorState()
        decode([SparkProtocol.frame(command: SparkProtocol.Command.acknowledge, sub: 0x38, payload: [], sequence: 1,
                                    header: false),
                wire(0x77, [0x01, 0x02])], into: &state)
        XCTAssertEqual(state.unknown, ["04 38": 1, "03 77": 1])
        XCTAssertFalse(state.hasReadings)
    }

    func testTheNEOsMiddleButtonFrameFromTheProbe() {
        // F0 01 50 02 03 38 00 00 02 F7, read on 2026-11-09.
        let messages = SparkProtocol.Parser().feed([0xF0, 0x01, 0x50, 0x02, 0x03, 0x38, 0x00, 0x00, 0x02, 0xF7])
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].checksumOK)
        XCTAssertEqual(SparkEvent(messages[0]), .presetSelected(slot: 2))
    }

    func testTheReadingsInWords() {
        var state = ReactorState()
        decode([wire(SparkProtocol.Sub.hardwarePreset, [0x00, 0x04]), wire(ReactorState.ampSelector, [4, 3]),
                parameter("Amp.Preamp", 0, 0.75), onOff("ChorusCloner", true),
                wire(ReactorState.selectedEffect, [4, 0xC3]), parameter("ChorusCloner", 0, 0.5),
                float(SparkProtocol.Sub.tapTempo, 120)], into: &state)
        let lines = state.lines().map { "\($0.label): \($0.value)" }
        XCTAssertEqual(lines, ["Platz: Grün 1", "Amp: Hi-Gain", "Push/Smooth: Push", "Heat: 4 von 5", "Gain: 7,5",
                               "Mod ChorusCloner: an, Level 5,0", "Tempo: 120 BPM"])
    }
}
