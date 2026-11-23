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
}
