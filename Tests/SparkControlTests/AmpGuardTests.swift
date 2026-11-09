import XCTest
@testable import SparkControl

/// The last check before the amp, see `AmpGuard`. It must stop what made the amp howl on 2026-11-08 and let every
/// real preset through.
final class AmpGuardTests: XCTestCase {
    private let howling = "KI-Sound: „U2 - where the streets have no name.“. "
        + "Originalgetreuer The-Edge-Sound: glänzender Vox-Clean mit punktiertem Achtel-Echo"

    private func preset(name: String = "Joshua Tree Echo", description: String = "",
                        models: [ChainPlace: String] = [:]) -> SparkPreset {
        SparkPreset(name: name, description: description, effects: ChainPlace.allCases.map {
            PresetFactory.effect(models[$0] ?? SoundRecipe.fallbackModels[$0]!, on: true)
        })
    }

    /// The largest preset any combination of catalog models makes: the model with the most bytes on every place.
    private func largest(name: String, description: String) -> SparkPreset {
        var models: [ChainPlace: String] = [:]
        for place in ChainPlace.allCases {
            let candidates = ModelCatalog.all.filter { $0.place == place }
            models[place] = candidates.max { a, b in
                AmpGuard.size(of: preset(models: [place: a.id])) < AmpGuard.size(of: preset(models: [place: b.id]))
            }!.id
        }
        return preset(name: name, description: description, models: models)
    }

    func testTheHowlingPresetIsMadeToFit() throws {
        let sent = AmpGuard.prepared(preset(description: howling))
        XCTAssertLessThanOrEqual(AmpGuard.size(of: sent), AmpGuard.payloadLimit)
        XCTAssertTrue(howling.hasPrefix(sent.description))
        XCTAssertEqual(sent.effects, preset(description: howling).effects)
        XCTAssertEqual(AmpGuard.problems(preset(description: howling)), [])
    }

    func testEveryCatalogPresetFitsWithAFullNameAndOnlyLosesDescription() {
        let name = String(repeating: "W", count: PresetRules.nameLimit)
        let biggest = largest(name: name, description: String(repeating: "ä", count: 100))
        let sent = AmpGuard.prepared(biggest)
        XCTAssertEqual(AmpGuard.problems(biggest), [], "size without description: \(AmpGuard.size(of: { var p = biggest; p.description = ""; return p }()))")
        XCTAssertLessThanOrEqual(AmpGuard.size(of: sent), AmpGuard.payloadLimit)
        XCTAssertEqual(sent.effects, biggest.effects)
        XCTAssertEqual(sent.name, name)
    }

    func testNoStringOnTheWireReaches128Bytes() {
        let sent = AmpGuard.prepared(preset(name: String(repeating: "W", count: 31), description: howling))
        for text in [sent.uuid, sent.name, sent.version, sent.description, sent.icon] + sent.effects.map(\.name) {
            XCTAssertLessThanOrEqual(text.utf8.count, AmpGuard.stringLimit)
        }
    }

    func testValuesOutsideTheKnobAreFittedAndNonNumbersRefused() {
        var wild = preset()
        wild.effects[3].parameters[0].value = 7
        wild.effects[5].parameters[1].value = -2
        wild.bpm = 900
        let sent = AmpGuard.prepared(wild)
        XCTAssertEqual(sent.effects[3].parameters[0].value, 1)
        XCTAssertEqual(sent.effects[5].parameters[1].value, 0)
        XCTAssertEqual(sent.bpm, PresetRules.bpmRange.upperBound)
        XCTAssertEqual(AmpGuard.problems(wild), [])

        var broken = preset()
        broken.effects[5].parameters[1].value = .nan
        XCTAssertFalse(AmpGuard.problems(broken).isEmpty)
        broken = preset()
        broken.bpm = .infinity
        XCTAssertFalse(AmpGuard.problems(broken).isEmpty)
        XCTAssertNil(AmpGuard.value(.nan))
        XCTAssertEqual(AmpGuard.value(3), 1)
    }

    func testMalformedPresetsAreRefused() {
        var short = preset()
        short.effects.removeLast()
        XCTAssertFalse(AmpGuard.problems(short).isEmpty)
        var longName = preset()
        longName.name = String(repeating: "N", count: 40)
        XCTAssertFalse(AmpGuard.problems(longName).isEmpty)
        var longIcon = preset()
        longIcon.icon = String(repeating: "i", count: 200)
        XCTAssertFalse(AmpGuard.problems(longIcon).isEmpty)
    }

    func testTheSentMessageCarriesThePreparedPreset() throws {
        let blocks = SparkProtocol.sendPreset(preset(description: howling), to: .temporary, sequence: 1, header: false)
        XCTAssertLessThanOrEqual(blocks.count, 20)
        let parser = SparkProtocol.Parser()
        let message = try XCTUnwrap(parser.feed(blocks.flatMap { $0 }).last)
        XCTAssertLessThanOrEqual(message.payload.count, AmpGuard.payloadLimit)
    }

    func testALiveValueNeverLeavesTheKnob() {
        let loud = SparkProtocol.setParameter(effect: "AC Boost", index: 4, value: 5, sequence: 1, header: false)
        let full = SparkProtocol.setParameter(effect: "AC Boost", index: 4, value: 1, sequence: 1, header: false)
        XCTAssertEqual(loud, full)
    }
}
