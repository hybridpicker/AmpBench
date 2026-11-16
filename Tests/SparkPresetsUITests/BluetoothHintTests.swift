import AmpText
import XCTest
@testable import SparkPresetsUI

/// The hint on top of the window while Bluetooth keeps AmpBench from the amp.
@MainActor
final class BluetoothHintTests: XCTestCase {
    override func tearDown() {
        Texts.language = .english
        super.tearDown()
    }

    func testBluetoothOffOnTheMacLeadsToItsSettings() throws {
        let hint = try XCTUnwrap(BluetoothHintContent.make(status: .bluetoothOff, wanted: true, on: .mac))
        XCTAssertTrue(hint.text.hasPrefix("Bluetooth is off on this Mac"))
        XCTAssertEqual(hint.url?.absoluteString, "x-apple.systempreferences:com.apple.BluetoothSettings")
        XCTAssertNotNil(hint.button)
    }

    func testBluetoothOffOnTheIPadSaysWhereToTurnItOn() throws {
        let hint = try XCTUnwrap(BluetoothHintContent.make(status: .bluetoothOff, wanted: true, on: .pad))
        XCTAssertTrue(hint.text.contains("Control Center"))
        XCTAssertNil(hint.button, "an app cannot open the iPad's Bluetooth settings")
    }

    func testNoAccessLeadsToPrivacy() throws {
        let hint = try XCTUnwrap(BluetoothHintContent.make(status: .unauthorized, wanted: true, on: .mac))
        XCTAssertEqual(hint.url?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
    }

    func testNothingWhileBluetoothWorksOrTheLinkIsNotWanted() {
        for status: SparkLink.Status in [.starting, .searching, .connecting, .connected, .off] {
            XCTAssertNil(BluetoothHintContent.make(status: status, wanted: true, on: .mac), "\(status)")
        }
        XCTAssertNil(BluetoothHintContent.make(status: .bluetoothOff, wanted: false, on: .mac),
                     "after Disconnect, Bluetooth being off is no problem")
    }

    func testALinkWithBluetoothOffGetsTheHint() async throws {
        let suite = "local.ampbench.tests.bluetooth-hint.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = SimulatedDevice([.reactor])
        device.powerState = .poweredOff
        let link = SparkLink(transport: device, memory: DeviceMemory(defaults: defaults))
        link.start()
        for _ in 0..<200 where link.status != .bluetoothOff { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(link.status, .bluetoothOff)
        XCTAssertNotNil(BluetoothHintContent.make(status: link.status, wanted: link.wanted))
        link.stop()
        XCTAssertNil(BluetoothHintContent.make(status: .bluetoothOff, wanted: link.wanted))
    }

    func testGerman() throws {
        Texts.language = .german
        let hint = try XCTUnwrap(BluetoothHintContent.make(status: .bluetoothOff, wanted: true, on: .mac))
        XCTAssertTrue(hint.text.hasPrefix("Bluetooth ist an diesem Mac aus"))
        XCTAssertEqual(hint.button, "Bluetooth-Einstellungen …")
    }
}
