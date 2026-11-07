import CoreAudio
import XCTest
@testable import SparkCore

final class InputPolicyTests: XCTestCase {
    private let usb = kAudioDeviceTransportTypeUSB
    private let builtIn = kAudioDeviceTransportTypeBuiltIn
    private let virtual = kAudioDeviceTransportTypeVirtual
    private let aggregate = kAudioDeviceTransportTypeAggregate
    private let bluetooth = kAudioDeviceTransportTypeBluetooth

    func testSparkOnUSBIsAllowed() {
        XCTAssertTrue(InputPolicy.sparkOnly.allows(name: "Spark MINI USB", transport: usb))
        XCTAssertTrue(InputPolicy.sparkOnly.allows(name: "SPARK 40", transport: usb))
        XCTAssertTrue(InputPolicy.sparkOnly.allows(name: "spark go", transport: usb))
    }

    func testMicrophoneIsNeverAllowed() {
        XCTAssertFalse(InputPolicy.sparkOnly.allows(name: "MacBook Pro-Mikrofon", transport: builtIn))
        XCTAssertFalse(InputPolicy.sparkOnly.allows(name: "USB Microphone", transport: usb))
    }

    func testOtherDevicesAreNotAllowed() {
        XCTAssertFalse(InputPolicy.sparkOnly.allows(name: "BlackHole 2ch", transport: virtual))
        XCTAssertFalse(InputPolicy.sparkOnly.allows(name: "Microsoft Teams Audio", transport: virtual))
        XCTAssertFalse(InputPolicy.sparkOnly.allows(name: "ZoomAudioDevice", transport: virtual))
    }

    func testTheNameAloneIsNotEnough() {
        XCTAssertFalse(InputPolicy.sparkOnly.allows(name: "Spark MINI USB", transport: builtIn))
        XCTAssertFalse(InputPolicy.sparkOnly.allows(name: "Spark Bluetooth", transport: bluetooth))
        XCTAssertFalse(InputPolicy.sparkOnly.allows(name: "Spark Loopback", transport: virtual))
        XCTAssertFalse(InputPolicy.sparkOnly.allows(name: "Spark Aggregate", transport: aggregate))
        XCTAssertFalse(InputPolicy.sparkOnly.allows(name: InputPolicy.testDeviceName, transport: aggregate))
    }

    func testTestPolicyNeverAllowsARealInput() {
        XCTAssertFalse(InputPolicy.testDevices.allows(name: "Spark MINI USB", transport: usb))
        XCTAssertFalse(InputPolicy.testDevices.allows(name: "MacBook Pro-Mikrofon", transport: builtIn))
        XCTAssertFalse(InputPolicy.testDevices.allows(name: "Microsoft Teams Audio", transport: virtual))
        XCTAssertTrue(InputPolicy.testDevices.allows(name: "BlackHole 2ch", transport: virtual))
        XCTAssertTrue(InputPolicy.testDevices.allows(name: InputPolicy.testDeviceName, transport: aggregate))
    }

    func testNothingPolicyRefusesEverything() {
        XCTAssertFalse(InputPolicy.nothing.allows(name: "Spark MINI USB", transport: usb))
    }

    // MARK: The engine itself

    private func device(named name: String, transport: UInt32) -> InputDevice {
        InputDevice(id: 0, uid: "test", modelUID: "test", name: name, channels: 1, currentRate: 44_100,
                    maxRate: 44_100, physicalBits: 16, transport: transport)
    }

    func testEngineRefusesAForbiddenInputWithoutTouchingIt() throws {
        for (name, transport) in [("MacBook Pro-Mikrofon", builtIn), ("BlackHole 2ch", virtual)] {
            let capture = CaptureEngine()
            XCTAssertThrowsError(try capture.open(device: device(named: name, transport: transport))) { error in
                XCTAssertTrue(error.localizedDescription.contains("Spark"), error.localizedDescription)
            }
            XCTAssertFalse(capture.isOpen)
        }
    }

    func testEngineWithoutOpenInputCannotRecord() throws {
        let folder = try TemporaryFolder()
        let capture = CaptureEngine()
        XCTAssertThrowsError(try capture.startRecording(to: folder.file("a.wav")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.file("a.wav").path))
    }

    func testRealMicrophoneIsRefusedByTheDefaultEngine() throws {
        let inputs = AudioDevices.inputDevices()
        let others = inputs.filter { !InputPolicy.sparkOnly.allows($0) }
        for input in others {
            let capture = CaptureEngine()
            XCTAssertThrowsError(try capture.open(device: input), input.name)
            XCTAssertFalse(capture.isOpen)
        }
    }
}
