@testable import SparkControl
@testable import SparkPresetsUI
import XCTest

/// The amp's own tuner over the link: one message on, one off, readings passed on, never left on when the
/// connection ends, and never anything to a device that is only listened to.
@MainActor
final class AmpTunerLinkTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "local.sparkstudio.tests.amptuner.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func make(_ kinds: [SimulatedDevice.Kind]) -> (SimulatedDevice, SparkLink) {
        let device = SimulatedDevice(kinds)
        let link = SparkLink(transport: device, memory: DeviceMemory(defaults: defaults))
        link.gap = .milliseconds(1)
        link.silence = 0.4
        return (device, link)
    }

    private func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func ready(_ link: SparkLink) async -> Bool {
        await until {
            link.status == .connected && link.activity == nil
                && (!link.profile.can(.read) || link.slots.allSatisfy { $0 != nil })
        }
    }

    /// The tuner messages a device got, as their payload byte: C3 on, C2 off.
    private func tunerMessages(_ device: SimulatedDevice, _ kind: SimulatedDevice.Kind) -> [UInt8] {
        let parser = SparkProtocol.Parser()
        return (device.written[device.id(kind)] ?? []).flatMap { parser.feed($0) }
            .filter { $0.sub == SparkProtocol.Sub.tuner }
            .map { $0.payload.first ?? 0 }
    }

    func testOneMessageOnReadingsComeAndOneMessageOff() async {
        let (device, link) = make([.neo])
        var readings: [(Int, Double?)] = []
        link.onTunerReading = { readings.append(($0, $1)) }
        link.start()
        _ = await ready(link)
        XCTAssertTrue(link.canUseAmpTuner)

        link.wantAmpTuner(true)
        let on = await until { link.isAmpTunerOn }
        XCTAssertTrue(on)
        XCTAssertTrue(device.tunerOn)
        device.tunerReading(note: 4, value: 0.62)
        device.tunerReading(note: 4, value: -1)
        let came = await until { readings.count == 2 }
        XCTAssertTrue(came)
        XCTAssertEqual(readings.first?.0, 4)
        XCTAssertEqual(readings.first?.1 ?? 0, 12, accuracy: 0.01)
        XCTAssertNil(readings.last?.1)

        link.wantAmpTuner(false)
        let off = await until { !device.tunerOn && !link.ampTunerMayBeOn }
        XCTAssertTrue(off)
        XCTAssertEqual(tunerMessages(device, .neo), [0xC3, 0xC2])
    }

    func testDisconnectingSwitchesTheTunerOffFirst() async {
        let (device, link) = make([.mini])
        link.start()
        _ = await ready(link)
        link.wantAmpTuner(true)
        _ = await until { link.isAmpTunerOn }
        link.stop()
        let gone = await until { device.connected == nil }
        XCTAssertTrue(gone)
        XCTAssertFalse(device.tunerOn, "the amp is not left silent")
        XCTAssertEqual(tunerMessages(device, .mini), [0xC3, 0xC2])
    }

    func testAfterALostConnectionTheTunerIsSwitchedAsWanted() async {
        let (device, link) = make([.mini])
        link.start()
        _ = await ready(link)
        link.wantAmpTuner(true)
        _ = await until { link.isAmpTunerOn }

        // Lost while wanted: on again after the reconnect.
        device.isAway = true
        device.dropConnection()
        _ = await until { link.status != .connected }
        XCTAssertFalse(link.isAmpTunerOn)
        device.comeBack()
        let again = await until { link.isAmpTunerOn }
        XCTAssertTrue(again)

        // Lost, and no longer wanted meanwhile: switched off after the reconnect, as the amp may still be on.
        device.isAway = true
        device.dropConnection()
        _ = await until { link.status != .connected }
        link.wantAmpTuner(false)
        XCTAssertTrue(link.ampTunerMayBeOn)
        device.comeBack()
        let off = await until { link.status == .connected && !link.ampTunerMayBeOn && !device.tunerOn }
        XCTAssertTrue(off)
        XCTAssertEqual(tunerMessages(device, .mini), [0xC3, 0xC3, 0xC2])
    }

    func testAnOffWithoutAnswerCountsWhenTheReadingsStop() async {
        let (device, link) = make([.mini])
        device.acknowledgesTunerOff = false
        link.start()
        _ = await ready(link)
        link.wantAmpTuner(true)
        _ = await until { link.isAmpTunerOn }
        link.wantAmpTuner(false)
        let off = await until(6) { !link.ampTunerMayBeOn }
        XCTAssertTrue(off)
        XCTAssertEqual(tunerMessages(device, .mini), [0xC3, 0xC2], "no second off when readings stopped")
    }

    func testQuittingWaitsForTheTunerToGoOff() async {
        let (device, link) = make([.neo])
        link.start()
        _ = await ready(link)
        link.wantAmpTuner(true)
        _ = await until { link.isAmpTunerOn }
        await link.switchTunerOffBeforeQuitting()
        XCTAssertFalse(device.tunerOn)
        XCTAssertFalse(link.ampTunerMayBeOn)
    }

    func testTheREACTORsTunerIsNeverSwitched() async {
        let (device, link) = make([.reactor])
        link.start()
        _ = await until { link.status == .connected }
        XCTAssertFalse(link.canUseAmpTuner)
        link.wantAmpTuner(true)
        try? await Task.sleep(for: .milliseconds(200))
        await link.switchTunerOffBeforeQuitting()
        link.stop()
        // Only the slot request after connecting went out; never the tuner switch (01 65) or anything else that sets.
        let parser = SparkProtocol.Parser()
        let sent = (device.written[device.id(.reactor)] ?? []).flatMap { parser.feed($0) }
        XCTAssertTrue(sent.allSatisfy { $0.command == SparkProtocol.Command.get && $0.sub == SparkProtocol.Sub.preset })
    }

    func testReadingsDoNotKeepAWaitAlive() async throws {
        let (device, link) = make([.mini])
        link.start()
        _ = await ready(link)
        link.wantAmpTuner(true)
        _ = await until { link.isAmpTunerOn }
        // A request the device does not answer, while readings keep coming: it must still end.
        let feeder = Task { @MainActor in
            for _ in 0..<60 {
                device.tunerReading(note: 9, value: 0.5)
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        let start = Date()
        device.ignoresRequests = true
        _ = try? await link.readPreset(.slot(0))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        feeder.cancel()
    }
}
