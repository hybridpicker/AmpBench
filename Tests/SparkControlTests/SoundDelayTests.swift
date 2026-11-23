import XCTest
@testable import SparkControl

/// Whether a take's sound snapshot has a delay switched on, for the hint of its timing review. Made-up presets only.
final class SoundDelayTests: XCTestCase {
    /// A full chain of seven places, the delay switched on or off.
    private func chain(delay: String = "DelayMono", delayOn: Bool, reverbOn: Bool = true) -> SparkPreset {
        func effect(_ name: String, _ isOn: Bool) -> SparkPreset.Effect {
            SparkPreset.Effect(name: name, isOn: isOn, parameters: [.init(index: 0, value: 0.5)])
        }
        return SparkPreset(name: "Test Chain", effects: [
            effect("bias.noisegate", true), effect("LA2AComp", false), effect("Booster", false), effect("Twin", true),
            effect("ChorusAnalog", false), effect(delay, delayOn), effect("bias.reverb", reverbOn),
        ])
    }

    private func snapshot(_ preset: SparkPreset) throws -> Data {
        try PresetFile.snapshotData(for: preset, origin: "Test", date: Date(timeIntervalSince1970: 1_795_435_200))
    }

    func testASnapshotWithTheDelayOnHasADelay() throws {
        XCTAssertTrue(PresetFile.soundHasDelay(try snapshot(chain(delayOn: true))))
        XCTAssertTrue(PresetFile.soundHasDelay(try snapshot(chain(delay: "DelayRe201", delayOn: true))))
    }

    func testADelaySwitchedOffIsNoDelay() throws {
        XCTAssertFalse(PresetFile.soundHasDelay(try snapshot(chain(delayOn: false))))
    }

    func testAReverbAloneIsNoDelay() throws {
        XCTAssertFalse(PresetFile.soundHasDelay(try snapshot(chain(delayOn: false, reverbOn: true))))
    }

    func testASoundWithoutADelayPlaceHasNoDelay() throws {
        let short = try SparkPreset(payload: Synthetic.presetPayload())
        XCTAssertFalse(PresetFile.soundHasDelay(try snapshot(short)))
    }

    /// A delay model the catalog does not know yet still counts by its place in a full chain.
    func testAnUnknownModelOnTheDelayPlaceCounts() throws {
        XCTAssertTrue(PresetFile.soundHasDelay(try snapshot(chain(delay: "SomeFutureEcho", delayOn: true))))
    }

    /// A delay model found at another place of a short chain still counts by its catalog entry.
    func testAKnownDelayModelCountsWhereverItIs() throws {
        let preset = SparkPreset(name: "Short", effects: [
            SparkPreset.Effect(name: "Twin", isOn: true, parameters: []),
            SparkPreset.Effect(name: "VintageDelay", isOn: true, parameters: []),
        ])
        XCTAssertTrue(PresetFile.soundHasDelay(try snapshot(preset)))
    }

    func testASnapshotThatCannotBeReadHasNoDelay() {
        XCTAssertFalse(PresetFile.soundHasDelay(Data("not a preset".utf8)))
        XCTAssertFalse(PresetFile.soundHasDelay(Data()))
    }
}
