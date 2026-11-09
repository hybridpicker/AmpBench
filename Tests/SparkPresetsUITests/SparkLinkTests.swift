@testable import SparkControl
@testable import SparkPresetsUI
import XCTest

/// The link against simulated devices: profiles, slot counts, switching between devices, the NEO dropping its
/// temporary sound, and a REACTOR that never gets a byte.
@MainActor
final class SparkLinkTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "local.sparkstudio.tests.devices.\(UUID().uuidString)"
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

    func testTheNEOIsFoundNamedAndRead() async {
        let (device, link) = make([.neo])
        link.start()
        let isReady = await ready(link)
        XCTAssertTrue(isReady)
        XCTAssertEqual(link.profile.id, .sparkNEO)
        XCTAssertEqual(link.deviceName, "Spark NEO")
        XCTAssertEqual(link.firmware, "1.16.1.60")
        XCTAssertEqual(link.slots.count, 4)
        XCTAssertEqual(link.activeSlot, 0)
        XCTAssertEqual(device.listenOnly[device.id(.neo)], false)
        XCTAssertEqual(link.devices.map(\.presence), [.connected])
    }

    func testTheNEODropsItsTemporarySoundWhenTheConnectionEnds() async throws {
        let (device, link) = make([.neo])
        var lost: [String] = []
        var reconnects: [Bool] = []
        var atLoss: (editing: Bool, trying: String?, slot: Int?)?
        link.onTemporaryLost = { [unowned link] name in
            lost.append(name)
            atLoss = (link.isEditingLive, link.tryingOut, link.activeSlot)
        }
        link.onConnected = { reconnects.append($0) }
        link.start()
        _ = await ready(link)
        device.active = 2
        try await link.select(slot: 2)
        try await link.playForEditing(PresetFactory.empty(name: "Probe"))
        XCTAssertTrue(link.isEditingLive)
        XCTAssertEqual(device.temporary?.name, "Probe")

        device.dropConnection()
        let dropped = await until { !lost.isEmpty }
        XCTAssertTrue(dropped)
        XCTAssertEqual(atLoss?.editing, false)
        XCTAssertNil(atLoss?.trying ?? nil)
        XCTAssertNil(atLoss?.slot ?? nil, "not known until read again")
        XCTAssertEqual(lost, ["Spark NEO"])

        // It comes back by itself, and what plays is read, not assumed: the stored slot.
        let back = await until { reconnects.count == 2 }
        XCTAssertTrue(back)
        XCTAssertEqual(reconnects, [false, true])
        XCTAssertEqual(link.activeSlot, 2)
        XCTAssertNil(device.temporary)
    }

    func testNothingIsLostWhenNothingTemporaryPlays() async throws {
        let (device, link) = make([.neo])
        var lost: [String] = []
        link.onTemporaryLost = { lost.append($0) }
        link.start()
        _ = await ready(link)
        try await link.select(slot: 1)
        device.dropConnection()
        _ = await until { link.status != .connected }
        XCTAssertEqual(lost, [])
    }

    /// The NEO sits on the ears: only texts as long as it was heard playing go to it, whatever the preset carries.
    func testTheNEOGetsOnlyTextsAsLongAsItWasHeardPlaying() async throws {
        let (device, link) = make([.neo])
        link.start()
        _ = await ready(link)
        var preset = PresetFactory.empty(name: "Ein sehr langer Name")
        preset.description = String(repeating: "Beschreibung ", count: 6)
        preset.version = "9.9"
        try await link.tryOut(preset)
        XCTAssertEqual(device.temporary?.name, "Ein sehr lan")
        XCTAssertEqual(device.temporary?.description, "")
        XCTAssertEqual(device.temporary?.version, "0.7")
        XCTAssertEqual(device.temporary?.icon, "icon.png")
        XCTAssertEqual(device.temporary?.effects, AmpGuard.prepared(preset).effects, "the sound is unchanged")
        try await link.store(preset, in: 3)
        XCTAssertEqual(device.slots[3].name, "Ein sehr lan")
        XCTAssertEqual(device.slots[3].description, "")
    }

    func testTheNEOsMiddleButtonIsFollowed() async {
        let (device, link) = make([.neo])
        var selected: [Int] = []
        link.onAmpSelected = { selected.append($0) }
        link.start()
        _ = await ready(link)
        device.pressButton(3)
        let followed = await until { link.activeSlot == 3 }
        XCTAssertTrue(followed)
        XCTAssertEqual(selected, [3])
    }

    func testParametersAreNotWaitedFor() async throws {
        let (device, link) = make([.neo])
        link.start()
        _ = await ready(link)
        try await link.playForEditing(device.slots[0])
        let amp = device.slots[0].effects[3].name
        let start = Date()
        let applied = try await link.apply(.parameter(effect: amp, index: 0, value: 1.0))
        XCTAssertTrue(applied)
        XCTAssertLessThan(Date().timeIntervalSince(start), link.silence, "no wait for a 04 04 that never comes")
        let arrived = await until { device.parameters.count == 1 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(device.parameters.first?.0, amp)
        XCTAssertEqual(device.parameters.first?.2, 1.0)
    }

    func testTheREACTORGetsNotASingleByte() async {
        let (device, link) = make([.reactor])
        link.start()
        let connected = await until { link.status == .connected }
        XCTAssertTrue(connected)
        XCTAssertEqual(link.profile.id, .reactor50)
        XCTAssertEqual(link.slots.count, 8)
        XCTAssertEqual(device.listenOnly[device.id(.reactor)], true, "no characteristic to write to is even kept")
        XCTAssertEqual(link.deviceName, "Reactor 50 Proberaum", "the window shows the owner's name")
        XCTAssertEqual(link.loggableName, "Reactor 50", "logs do not")

        // Everything that would send is refused.
        await link.loadAll()
        await link.refresh(slot: 0)
        for attempt in [
            { try await link.select(slot: 1) },
            { try await link.tryOut(PresetFactory.empty()) },
            { try await link.playForEditing(PresetFactory.empty()) },
            { try await link.store(PresetFactory.empty(), in: 0) },
            { _ = try await link.readPreset(.playing) },
            { _ = try await link.apply(.parameter(effect: "Amp.Preamp", index: 0, value: 0.5)) },
            { _ = try await link.apply(.toggle(effect: "MonoReverb", isOn: true)) },
        ] as [() async throws -> Void] {
            do {
                try await attempt()
                XCTFail("sent to a REACTOR")
            } catch {}
        }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(device.written[device.id(.reactor)] ?? [], [], "not one byte on FFC1")

        // It is listened to.
        device.pressButton(5)
        device.report(ReactorState.ampSelector, [3, 7])
        let heard = await until { link.reactor.ampName == "Crunch" }
        XCTAssertTrue(heard)
        XCTAssertEqual(link.activeSlot, 5)
        XCTAssertEqual(link.reactor.slot, 5)
        XCTAssertEqual(link.profile.slotName(5), "Grün 2")
        XCTAssertEqual(device.written[device.id(.reactor)] ?? [], [])
    }

    func testAnUnknownSparkIsOnlyReadAndSwitched() async throws {
        let (_, link) = make([.unknownSpark])
        link.start()
        _ = await ready(link)
        XCTAssertEqual(link.profile.id, .unknownSpark)
        XCTAssertEqual(link.deviceName, "Spark 40")
        try await link.select(slot: 1)
        do {
            try await link.tryOut(PresetFactory.empty())
            XCTFail("an unchecked device got a preset")
        } catch LinkError.notSupported {}
    }

    func testSwitchingDevicesEndsTheOldConnectionFirstAndIsRemembered() async {
        let (device, link) = make([.mini, .neo])
        link.start()
        _ = await ready(link)
        let first = link.chosenID
        XCTAssertNotNil(first)
        let other = first == device.id(.neo) ? device.id(.mini) : device.id(.neo)
        let nearby = await until { link.devices.count == 2 }
        XCTAssertTrue(nearby)

        link.choose(other)
        let switched = await until { device.connected == other && link.status == .connected && link.activity == nil }
        XCTAssertTrue(switched)
        XCTAssertEqual(link.chosenID, other)
        XCTAssertEqual(DeviceMemory(defaults: defaults).chosen, other, "kept by its identifier")
        XCTAssertEqual(link.devices.first { $0.id == other }?.presence, .connected)
        XCTAssertEqual(link.devices.first { $0.id == first }?.presence, .nearby)

        // A new link remembers the choice and its profile before anything is found.
        let again = SparkLink(transport: SimulatedDevice([]), memory: DeviceMemory(defaults: defaults))
        XCTAssertEqual(again.chosenID, other)
        XCTAssertEqual(again.profile.id, other == device.id(.neo) ? .sparkNEO : .sparkMini)
    }

    func testOnlyTheChosenDeviceIsConnected() async {
        let (device, link) = make([.mini, .neo])
        DeviceMemory(defaults: defaults).chosen = device.id(.neo)
        let chosen = SparkLink(transport: device, memory: DeviceMemory(defaults: defaults))
        chosen.gap = .milliseconds(1)
        _ = link
        chosen.start()
        _ = await ready(chosen)
        XCTAssertEqual(device.connected, device.id(.neo))
    }

    func testTheQuestionBeforeASoundIsLost() {
        typealias M = PresetsModel
        XCTAssertTrue(M.wouldLoseSound(profile: .sparkNEO, isEditingLive: true, editorUnsaved: true, triedOutUnsaved: false))
        XCTAssertFalse(M.wouldLoseSound(profile: .sparkNEO, isEditingLive: true, editorUnsaved: false, triedOutUnsaved: true))
        XCTAssertTrue(M.wouldLoseSound(profile: .sparkNEO, isEditingLive: false, editorUnsaved: false, triedOutUnsaved: true))
        XCTAssertFalse(M.wouldLoseSound(profile: .sparkNEO, isEditingLive: false, editorUnsaved: true, triedOutUnsaved: false))
        // The MINI is treated like the NEO until checked.
        XCTAssertTrue(M.wouldLoseSound(profile: .sparkMini, isEditingLive: true, editorUnsaved: true, triedOutUnsaved: false))
        var keeps = DeviceProfile.sparkMini
        keeps.keepsTemporaryAfterDisconnect = true
        XCTAssertFalse(M.wouldLoseSound(profile: keeps, isEditingLive: true, editorUnsaved: true, triedOutUnsaved: true))
    }
}
