import AmpText
import XCTest
@testable import SparkControl

final class ModelCatalogTests: XCTestCase {
    func testIDsAreUniqueAndEveryPlaceHasModels() {
        let ids = ModelCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for place in ChainPlace.allCases {
            XCTAssertFalse(ModelCatalog.models(for: place).isEmpty, "\(place)")
        }
        XCTAssertEqual(ModelCatalog.models(for: .reverb).map(\.id), ["bias.reverb"])
        XCTAssertEqual(ModelCatalog.models(for: .gate).map(\.id), ["bias.noisegate"])
    }

    func testModelsSeenInTheAmpsPresetsAreInTheirPlace() {
        let seen: [(String, ChainPlace)] = [
            ("bias.noisegate", .gate), ("BlueComp", .compressor), ("Compressor", .compressor),
            ("DistortionTS9", .drive), ("Overdrive", .drive), ("Deluxe65", .amp), ("Twin", .amp), ("Plexi", .amp),
            ("Rectifier", .amp), ("ChorusAnalog", .modulation), ("Cloner", .modulation), ("UniVibe", .modulation),
            ("GuitarEQ6", .modulation), ("DelayMono", .delay), ("VintageDelay", .delay), ("bias.reverb", .reverb),
        ]
        for (id, place) in seen {
            XCTAssertEqual(ModelCatalog.known(id)?.place, place, id)
        }
    }

    func testIDsKeepTheirExactSpelling() {
        XCTAssertNotNil(ModelCatalog.known("SABdriver"))
        XCTAssertNil(ModelCatalog.known("SABDriver"))
        XCTAssertNotNil(ModelCatalog.known("AC Boost"))
    }

    func testAmpsHaveFiveParameters() {
        for amp in ModelCatalog.models(for: .amp, includingPacks: true) {
            XCTAssertEqual(amp.parameters.count, 5, amp.id)
            XCTAssertEqual(amp.parameters.first?.name, "Gain", amp.id)
        }
    }

    func testPacksAreLeftOutUnlessAskedFor() {
        XCTAssertFalse(ModelCatalog.models(for: .amp).contains { $0.isPack })
        XCTAssertTrue(ModelCatalog.models(for: .amp, includingPacks: true).contains { $0.id == "JH.JTM45" })
    }

    func testUnknownModelsGetNumberedKnobs() {
        let info = ModelCatalog.info(for: "FutureModel", place: .delay, parameterCount: 3)
        XCTAssertFalse(info.isKnown)
        XCTAssertEqual(info.place, .delay)
        XCTAssertEqual(info.parameters.map(\.name), ["Knob 1", "Knob 2", "Knob 3"])
        XCTAssertTrue(info.parameters.allSatisfy(\.isVisible))
        // A known model with more parameters than the catalog lists shows the extra ones numbered.
        let gate = ModelCatalog.info(for: "bias.noisegate", parameterCount: 3)
        XCTAssertEqual(gate.parameter(5).name, "Knob 6")
    }

    func testHiddenParametersAreTheMirrorsAndTheUnknownOnes() {
        XCTAssertEqual(ModelCatalog.known("bias.noisegate")?.parameter(2).kind, .mirror)
        XCTAssertEqual(ModelCatalog.known("bias.reverb")?.parameter(7).kind, .mirror)
        XCTAssertEqual(ModelCatalog.known("DistortionTS9")?.parameter(3).kind, .reserved)
        XCTAssertFalse(ModelCatalog.known("bias.reverb")!.parameter(7).isVisible)
    }

    func testValuesAreShownTheWayTheyAreMeant() {
        let gain = ParameterInfo.knob("Gain")
        XCTAssertEqual(gain.display(0.5), "5.0")
        XCTAssertEqual(gain.display(1), "10.0")
        XCTAssertEqual(ParameterInfo.bpm.display(0.2), "Free")
        XCTAssertEqual(ParameterInfo.bpm.display(0.5), "BPM")
        let type = ModelCatalog.known("bias.reverb")!.parameter(6)
        XCTAssertEqual(type.display(0.3), "Natural hall")
        XCTAssertEqual(type.display(0.72), "Rich plate")
        guard case .selector(let options) = type.kind else { return XCTFail("reverb type is a selector") }
        XCTAssertEqual(options.count, 9)
    }

    func testAccentsAreReadableOnTheDarkDevice() {
        let device = RGB(0.09, 0.09, 0.10)
        for place in ChainPlace.allCases {
            XCTAssertGreaterThanOrEqual(place.accent.contrast(with: device), 4.5, "\(place)")
        }
    }

    func testEveryFreeModelWasCheckedOnTheMini() {
        for model in ModelCatalog.all where !model.isPack {
            XCTAssertTrue(model.isCheckedOnMini, model.id)
            XCTAssertFalse(model.defaults.isEmpty, model.id)
            // The amp may give a model more parameters than the catalog names, never fewer.
            XCTAssertGreaterThanOrEqual(model.defaults.count, model.parameters.count, model.id)
            XCTAssertTrue(model.defaults.allSatisfy { (0...1).contains($0) }, model.id)
        }
        for id in ModelCatalog.refusedOnMini {
            XCTAssertEqual(ModelCatalog.known(id)?.isPack, true, id)
        }
        XCTAssertTrue(ModelCatalog.measuredDefaults.keys.allSatisfy { ModelCatalog.known($0) != nil })
    }

    func testParameterCountsAsTheMiniReportsThem() {
        let counts: [String: Int] = [
            "bias.noisegate": 3, "LA2AComp": 3, "BlueComp": 4, "Compressor": 2, "Booster": 1, "DistortionTS9": 4,
            "SABdriver": 4, "Twin": 5, "Rectifier": 5, "Vibrato01": 3, "MiniVibe": 4, "TremoloSquare": 4,
            "Phaser": 4, "GuitarEQ6": 7, "DelayMono": 5, "VintageDelay": 4, "bias.reverb": 8,
        ]
        for (id, count) in counts {
            XCTAssertEqual(ModelCatalog.known(id)?.parameterCount, count, id)
        }
        // Parameters the catalog does not name stay usable, numbered.
        XCTAssertEqual(ModelCatalog.known("MiniVibe")?.parameter(3).name, "Knob 4")
    }

    /// The catalog holds English and is read in the app's language each time, so nothing is frozen at first use.
    func testTheCatalogSpeaksGermanWhenTheAppDoes() {
        let reverb = ModelCatalog.known("bias.reverb")!
        XCTAssertEqual(reverb.name, "Reverb")
        Texts.language = .german
        defer { Texts.language = .english }
        XCTAssertEqual(reverb.name, "Hall")
        XCTAssertEqual(reverb.summary, "Raum, Kammer, Saal oder Platte")
        XCTAssertEqual(reverb.parameter(5).name, "Länge")
        XCTAssertEqual(reverb.parameter(5).key, "length")
        XCTAssertEqual(reverb.parameter(6).display(0.3), "Saal natürlich")
        XCTAssertEqual(ParameterInfo.knob("Gain").display(0.5), "5,0")
        XCTAssertEqual(ParameterInfo.bpm.display(0.2), "Frei")
        XCTAssertEqual(ParameterInfo.toggle("Pad").display(1), "An")
        XCTAssertEqual(ModelCatalog.known("Twin")?.parameters.map(\.name), ["Gain", "Höhen", "Mitten", "Bässe", "Master"])
        XCTAssertEqual(ModelCatalog.known("Tremolator")?.parameters.map(\.name), ["Tiefe", "Tempo", "Tempo"])
        XCTAssertEqual(ModelCatalog.known("DistortionTS9")?.parameter(0).name, "Drive")
        XCTAssertEqual(ModelCatalog.known("GuitarEQ6")?.parameter(5).name, "1,6 kHz")
        XCTAssertEqual(ModelCatalog.known("bias.noisegate")?.parameter(5).name, "Regler 6")
        XCTAssertEqual(ChainPlace.allCases.map(\.title),
                       ["Noise Gate", "Kompressor", "Verzerrer", "Amp", "Modulation", "Delay", "Hall"])
        XCTAssertEqual(ChainPlace.compressor.shortTitle, "Komp")
        XCTAssertEqual(ModelInfo.Group.allCases.map(\.title),
                       ["Clean", "Brillant", "Crunch", "High Gain", "Metal", "Akustik", "Bass"])
        XCTAssertEqual(PresetFactory.templates.first?.summary, "Klarer Amp, etwas Kompression und ein kleiner Raum")
        XCTAssertEqual(DeviceProfile.reactor50.bankNames, ["Rot", "Grün"])
    }

    /// Every sentence of the catalog has its German, and no German is left in the code.
    func testEveryCatalogTextHasGerman() {
        for model in ModelCatalog.all {
            XCTAssertNotEqual(model.germanSummary, model.englishSummary, model.id)
            for text in [model.englishName, model.englishSummary] + model.parameters.map(\.englishName) {
                XCTAssertNil(text.rangeOfCharacter(from: CharacterSet(charactersIn: "äöüÄÖÜß")), text)
            }
        }
        for profile in DeviceProfile.all {
            XCTAssertNotEqual(Texts.german(profile.englishChecked), nil, profile.displayName)
        }
        for template in PresetFactory.templates {
            XCTAssertNotNil(Texts.german(template.summary), template.name)
        }
    }

    func testKeysDoNotDependOnTheLanguage() {
        let keys = ModelCatalog.all.map { $0.settableParameters.map(\.info.key) }
        Texts.language = .german
        defer { Texts.language = .english }
        XCTAssertEqual(ModelCatalog.all.map { $0.settableParameters.map(\.info.key) }, keys)
        XCTAssertEqual(ModelCatalog.known("Tremolator")?.settableParameters.map(\.info.key), ["depth", "speed", "sync"])
        XCTAssertEqual(ModelCatalog.known("GuitarEQ6")?.parameter(5).key, "hz1600")
    }

    func testStartValuesMatchWhatTheAmpChose() {
        XCTAssertEqual(ModelCatalog.known("Twin")?.defaults, [0.696, 0.372, 0.453, 0.549, 0.803])
        XCTAssertEqual(ModelCatalog.known("GuitarEQ6")?.defaults, Array(repeating: 0.5, count: 7))
    }

    func testPlacesOfASevenEffectPreset() {
        XCTAssertEqual(ChainPlace.of(index: 3, count: 7), .amp)
        XCTAssertNil(ChainPlace.of(index: 3, count: 6))
    }
}
