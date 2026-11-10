import XCTest
@testable import SparkControl

final class ReactorSoundTests: XCTestCase {
    private func sound(_ amp: String, gain: Double, on: [String] = []) throws -> ReactorSound {
        var chain: [String: SoundRecipe.Unit] = ["amp": .init(model: amp, settings: ["gain": .number(gain), "bass": .number(5),
                                                                              "middle": .number(5), "treble": .number(5)])]
        for place in on { chain[place] = .init(model: SoundRecipe.fallbackModels[ChainPlace(key: place)!]!) }
        return try ReactorSound(preset: SoundRecipe(name: "T", chain: chain).preset().preset)
    }

    func testAmpsMapToTheReactorsSix() throws {
        XCTAssertEqual(try sound("Twin", gain: 3).ampName, "Clean")
        XCTAssertEqual(try sound("Deluxe65", gain: 4).ampName, "Warm")
        XCTAssertEqual(try sound("OverDrivenLuxVerb", gain: 5).ampName, "Grit")
        XCTAssertEqual(try sound("Plexi", gain: 7).ampName, "Crunch")
        XCTAssertEqual(try sound("SLO100", gain: 7).ampName, "Hi-Gain")
        XCTAssertEqual(try sound("Rectifier", gain: 8).ampName, "Extreme")
        for model in ReactorSound.ampForModel.keys { XCTAssertNotNil(ModelCatalog.known(model), model) }
    }

    func testStepsSetToneAndGainBeforeTheAmpAndNeverTheMaster() throws {
        let sound = try sound("Plexi", gain: 7, on: ["delay", "reverb"])
        let steps = sound.steps()
        XCTAssertEqual(steps.map(\.text).prefix(5), ["Bass 0.50", "Middle 0.50", "Treble 0.50", "Gain 0.70", "Amp Crunch"])
        XCTAssertEqual(steps.map(\.text).suffix(7).prefix(6),
                       ["Gate aus", "Comp aus", "Drive aus", "Mod aus", "Delay an", "Reverb an"])
        let parser = SparkProtocol.Parser()
        let messages = steps.flatMap { parser.feed($0.bytes) }
        XCTAssertEqual(messages.count, steps.count)
        XCTAssertTrue(messages.allSatisfy { $0.command == SparkProtocol.Command.set && $0.checksumOK })
        // The amp selector as the REACTOR reports it: amp 3, 5 × Standard + Heat 2.
        XCTAssertEqual(messages[4].sub, ReactorState.ampSelector)
        XCTAssertEqual(messages[4].payload, [3, 7])
        for step in steps { XCTAssertFalse(String(decoding: step.bytes, as: UTF8.self).contains("Poweramp")) }
    }

    func testTheHeardMessagesAreReproduced() {
        // Sent by hand on 2026-11-10 and heard on the REACTOR 50: gain 0.1 and the amp selector to Clean.
        let gain = SparkProtocol.setParameter(effect: "Amp.Preamp", index: 0, value: 0.1, sequence: 1)
        XCTAssertEqual(Array(gain.suffix(29)).map { String(format: "%02X", $0) }.joined(separator: " "),
                       "F0 01 01 1F 01 04 02 0A 2A 41 6D 70 2E 50 40 72 65 61 6D 70 00 4A 0E 3D 4C 4C 4D 00 F7")
        let amp = SparkProtocol.frame(command: SparkProtocol.Command.set, sub: ReactorState.ampSelector,
                                      payload: [0, 7], sequence: 1)
        XCTAssertEqual(Array(amp.suffix(4)), [0x00, 0x00, 0x07, 0xF7])
    }
}
