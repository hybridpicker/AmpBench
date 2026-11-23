import CoreAudio
import XCTest
@testable import SparkCore

/// The amp's part of the click latency belongs to the input and holds for every wired click output.
final class AmpLatencyTests: XCTestCase {
    private let mini = DeviceIdentity(uid: "AppleUSBAudioEngine:Positive Grid:Spark MINI:1234:1", modelUID: "Spark:1",
                                      name: "Spark MINI", isBuiltIn: false)
    private let neo = DeviceIdentity(uid: "AppleUSBAudioEngine:Positive Grid:Spark NEO:5678:1", modelUID: "Spark:2",
                                     name: "Spark NEO", isBuiltIn: false)
    private let measuredAt = Date(timeIntervalSince1970: 1_795_000_000)

    /// A measurement of 25.4 ms into the file, 3.7 ms of it reported, spread 1.2 ms.
    private let measurement = LatencyProbe.Result(measured: 0.0254, reported: 0.0037, spread: 0.0012, detected: 12,
                                                  played: 12)

    func testAMeasurementHoldsForEveryWiredOutputWithEachOutputsReportedPart() {
        var amps = AmpLatencies()
        amps.store(measurement, for: mini, at: measuredAt)

        let headphones = amps.clickLatency(input: mini, reportedOutput: 0.0012, reportedInput: 0.0025,
                                           outputTransport: kAudioDeviceTransportTypeBuiltIn)
        let speakers = amps.clickLatency(input: mini, reportedOutput: 0.0105, reportedInput: 0.0025,
                                         outputTransport: kAudioDeviceTransportTypeBuiltIn)

        XCTAssertEqual(headphones.correction, 0.0217, accuracy: 1e-9)
        XCTAssertEqual(speakers.correction, 0.0217, accuracy: 1e-9)
        XCTAssertEqual(headphones.total, 0.0012 + 0.0025 + 0.0217, accuracy: 1e-9)
        XCTAssertEqual(speakers.total, 0.0105 + 0.0025 + 0.0217, accuracy: 1e-9)
        XCTAssertEqual(speakers.amp?.origin, .measured(spread: 0.0012, date: measuredAt))
    }

    func testAHandSetValueIsMarkedAndStillCorrectsTheBars() {
        var amps = AmpLatencies()
        amps.store(measurement, for: mini, at: measuredAt)
        amps.setByHand(0.019, for: mini)

        let latency = amps.clickLatency(input: mini, reportedOutput: 0.002, reportedInput: 0.0025,
                                        outputTransport: kAudioDeviceTransportTypeBuiltIn)
        XCTAssertEqual(latency.amp, AmpPart(seconds: 0.019, origin: .setByHand))
        XCTAssertEqual(latency.total, 0.0235, accuracy: 1e-9)
        let offset = ClickTiming.gridOffset(anchorFrame: 0, beatsBefore: 0, bpm: 120, inputRate: 48_000,
                                            fileFirstFrame: 0, latency: latency)
        XCTAssertEqual(offset, 0.0235, accuracy: 1e-9)
    }

    func testAHandSetValueKeepsToItsRangeAndZeroForgetsIt() {
        var amps = AmpLatencies()
        amps.setByHand(0.5, for: mini)
        XCTAssertEqual(amps.part(for: mini)?.seconds, 0.3)
        amps.setByHand(-0.4, for: mini)
        XCTAssertEqual(amps.part(for: mini)?.seconds, -0.1)
        amps.setByHand(0.00001, for: mini)
        XCTAssertNil(amps.part(for: mini))
    }

    // MARK: Carry-over of the values stored per pair of input and click output

    func testValuesStoredPerPairCarryOverAsHandSet() {
        let amps = AmpLatencies.carryOver(pairs: [
            "\(neo.uid)|speakers-uid": 0.012,
            "\(mini.uid)|BlackHole2ch_UID": -0.004,
        ])
        XCTAssertEqual(amps.part(for: neo), AmpPart(seconds: 0.012, origin: .setByHand))
        XCTAssertEqual(amps.part(for: mini), AmpPart(seconds: -0.004, origin: .setByHand))
    }

    /// The one value measured with the owner on 2026-11-23: the MINI, click on the built-in headphone output.
    func testTheMINIsHeadphoneValueCarriesOverAsMeasured() throws {
        let amps = AmpLatencies.carryOver(pairs: ["\(mini.uid)|BuiltInHeadphoneOutputDevice": 0.02166])
        let part = try XCTUnwrap(amps.part(for: mini))
        XCTAssertEqual(part.seconds, 0.02166, accuracy: 1e-12)
        guard case .measured(let spread, let date) = part.origin else { return XCTFail("expected measured, got \(part)") }
        XCTAssertEqual(spread, 0.0012, accuracy: 1e-12)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: date),
                       DateComponents(year: 2026, month: 11, day: 23))
    }

    func testOnlyThatPairCarriesOverAsMeasured() {
        let amps = AmpLatencies.carryOver(pairs: [
            "\(mini.uid)|BuiltInSpeakerDevice": 0.02166,
            "\(neo.uid)|BuiltInHeadphoneOutputDevice": 0.015,
        ])
        XCTAssertEqual(amps.part(for: mini)?.origin, .setByHand)
        XCTAssertEqual(amps.part(for: neo)?.origin, .setByHand)
    }

    /// One amp with values for several outputs keeps one part: the measured one, otherwise the first by key.
    func testSeveralPairsOfOneAmpKeepTheMeasuredValue() {
        let amps = AmpLatencies.carryOver(pairs: [
            "\(mini.uid)|BuiltInSpeakerDevice": 0.03,
            "\(mini.uid)|BuiltInHeadphoneOutputDevice": 0.02166,
            "\(neo.uid)|b-output": 0.02,
            "\(neo.uid)|a-output": 0.01,
        ])
        XCTAssertEqual(amps.part(for: mini)?.seconds ?? 0, 0.02166, accuracy: 1e-12)
        XCTAssertEqual(amps.part(for: neo), AmpPart(seconds: 0.01, origin: .setByHand))
    }

    func testAKeyWithoutAPairIsLeftOut() {
        XCTAssertEqual(AmpLatencies.carryOver(pairs: ["no pair": 0.01, "|x": 0.01]), AmpLatencies())
    }

    func testTheyKeepAcrossSavingAndLoading() throws {
        var amps = AmpLatencies()
        amps.store(measurement, for: mini, at: measuredAt)
        amps.setByHand(0.012, for: neo)
        let data = try JSONEncoder().encode(amps)
        XCTAssertEqual(try JSONDecoder().decode(AmpLatencies.self, from: data), amps)
    }

    // MARK: The click output's kind

    func testABluetoothClickOutputIsKnownByItsTransport() {
        var amps = AmpLatencies()
        amps.store(measurement, for: mini, at: measuredAt)
        let headphones = amps.clickLatency(input: mini, reportedOutput: 0.0012, reportedInput: 0.0025,
                                           outputTransport: kAudioDeviceTransportTypeBuiltIn)
        let earbuds = amps.clickLatency(input: mini, reportedOutput: 0.16, reportedInput: 0.0025,
                                        outputTransport: kAudioDeviceTransportTypeBluetooth)
        let lowEnergy = amps.clickLatency(input: mini, reportedOutput: 0.16, reportedInput: 0.0025,
                                          outputTransport: kAudioDeviceTransportTypeBluetoothLE)
        let interface = amps.clickLatency(input: mini, reportedOutput: 0.003, reportedInput: 0.0025,
                                          outputTransport: kAudioDeviceTransportTypeUSB)
        XCTAssertEqual(headphones.outputKind, .wired)
        XCTAssertEqual(interface.outputKind, .wired)
        XCTAssertEqual(earbuds.outputKind, .bluetooth)
        XCTAssertEqual(lowEnergy.outputKind, .bluetooth)
        // Their bars are still corrected, with the amp part and what the Bluetooth output reports.
        XCTAssertEqual(earbuds.total, 0.16 + 0.0025 + 0.0217, accuracy: 1e-9)
    }

    func testEachAmpKeepsItsOwnPart() {
        var amps = AmpLatencies()
        amps.store(measurement, for: mini, at: measuredAt)
        amps.setByHand(0.012, for: neo)
        XCTAssertEqual(amps.part(for: mini)?.seconds ?? 0, 0.0217, accuracy: 1e-9)
        XCTAssertEqual(amps.part(for: neo), AmpPart(seconds: 0.012, origin: .setByHand))
        let unknown = DeviceIdentity(uid: "other", modelUID: "", name: "Other", isBuiltIn: false)
        XCTAssertEqual(amps.clickLatency(input: unknown, reportedOutput: 0.002, reportedInput: 0.001,
                                         outputTransport: kAudioDeviceTransportTypeBuiltIn).total, 0.003,
                       accuracy: 1e-9)
    }
}
