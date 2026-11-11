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
        suite = "local.ampbench.tests.devices.\(UUID().uuidString)"
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
        var preset = PresetFactory.empty(name: "Quite a long name")
        preset.description = String(repeating: "Description ", count: 6)
        preset.version = "9.9"
        try await link.tryOut(preset)
        XCTAssertEqual(device.temporary?.name, "Quite a long")
        XCTAssertEqual(device.temporary?.description, "")
        XCTAssertEqual(device.temporary?.version, "0.7")
        XCTAssertEqual(device.temporary?.icon, "icon.png")
        XCTAssertEqual(device.temporary?.effects, AmpGuard.prepared(preset).effects, "the sound is unchanged")
        try await link.store(preset, in: 3)
        XCTAssertEqual(device.slots[3].name, "Quite a long")
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
        XCTAssertEqual(device.listenOnly[device.id(.reactor)], false, "FFC1 is kept for ReactorSound only")
        XCTAssertEqual(link.deviceName, "Reactor 50 Rehearsal", "the window shows the owner's name")
        XCTAssertEqual(link.loggableName, "Reactor 50", "logs do not")

        // Everything that would send is refused.
        await link.loadAll()
        await link.refresh(slot: 0)
        for attempt in [
            { try await link.select(slot: 8) },
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
        // This REACTOR answers nothing, so the one read request after connecting is all it ever got.
        XCTAssertEqual(reactorRequests(device), ["02 01"], "one slot request, given up when no answer came")

        // It is listened to.
        device.pressButton(5)
        device.report(ReactorState.ampSelector, [3, 7])
        let heard = await until { link.reactor.ampName == "Crunch" }
        XCTAssertTrue(heard)
        XCTAssertEqual(link.activeSlot, 5)
        XCTAssertEqual(link.reactor.slot, 5)
        XCTAssertEqual(link.profile.slotName(5), "Green 2")
        XCTAssertEqual(reactorRequests(device), ["02 01"])
    }

    /// Command and sub of everything written to the simulated REACTOR.
    private func reactorRequests(_ device: SimulatedDevice) -> [String] {
        let parser = SparkProtocol.Parser()
        return (device.written[device.id(.reactor)] ?? []).flatMap { parser.feed($0) }
            .map { String(format: "%02X %02X", $0.command, $0.sub) }
    }

    func testTheREACTORSwitchesToASlot() async throws {
        let (device, link) = make([.reactor])
        for slot in 0..<8 {
            device.reactorPresets[slot] = ReactorFixture.preset(slot: slot, name: "Sound \(slot + 1)", amp: "Twin Clean",
                                                                effectsOn: slot)
        }
        link.start()
        let read = await until { link.reactorPresets.count == 8 && link.reactorPresets.allSatisfy { $0 != nil } }
        XCTAssertTrue(read)
        device.report(ReactorState.ampSelector, [3, 7])
        let heard = await until { link.reactor.ampName == "Crunch" }
        XCTAssertTrue(heard)

        try await link.select(slot: 5)
        XCTAssertEqual(device.active, 5)
        XCTAssertEqual(link.activeSlot, 5)
        XCTAssertEqual(link.reactor.slot, 5)
        XCTAssertNil(link.reactor.ampName, "what was heard belonged to the slot before")
        XCTAssertEqual(reactorRequests(device).last, "01 38")
        XCTAssertEqual(reactorRequests(device).filter { $0 == "01 38" }.count, 1)
    }

    /// A REACTOR with eight presets of models as on a real one.
    private func reactorWithPresets() async -> (SimulatedDevice, SparkLink) {
        let (device, link) = make([.reactor])
        for slot in 0..<8 { device.reactorPresets[slot] = ReactorChainFixture.preset(slot: slot, name: "Sound \(slot + 1)") }
        device.active = 1
        link.start()
        let read = await until { link.slots.count == 8 && link.slots.allSatisfy { $0 != nil } && link.activeSlot == 1 }
        XCTAssertTrue(read)
        return (device, link)
    }

    func testAREACTORSlotIsEditedLiveByTheNamesItTakes() async throws {
        let (device, link) = await reactorWithPresets()
        let stored = try XCTUnwrap(link.slots[1])
        XCTAssertEqual(stored.effects.count, 7)
        XCTAssertTrue(link.canEditLive(slot: 1))
        XCTAssertFalse(link.canEditLive(slot: 2), "only the slot that plays")
        XCTAssertFalse(link.canEditLive(slot: nil))

        var editor = PresetEditor(stored)
        _ = editor.setParameter(place: ChainPlace.amp.rawValue, index: 1, value: 0.25)
        // The first change: the whole state, of which only the difference goes out.
        try await link.playForEditing(editor.current)
        XCTAssertTrue(link.isEditingLive)
        XCTAssertEqual(link.activeSlot, 1)
        for change in editor.setParameter(place: ChainPlace.reverb.rawValue, index: 0, value: 0.5)
            + editor.setOn(place: ChainPlace.drive.rawValue, true)
            + editor.setParameter(place: ChainPlace.delay.rawValue, index: 0, value: 0.9) {
            let applied = try await link.apply(change)
            XCTAssertTrue(applied)
        }
        let arrived = await until { device.parameters.count == 2 && device.switches.count == 1 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(device.parameters.map { "\($0.0) \($0.1) \($0.2)" }, ["Amp.Tonestack 1 0.25", "MonoReverb 0 0.5"],
                       "the delay's model has no known name: stored only")
        XCTAssertEqual(device.switches.map { "\($0.0) \($0.1)" }, ["DistortionTS9 true"])
        XCTAssertEqual(device.reactorPresets[1], ReactorChainFixture.preset(slot: 1, name: "Sound 2"), "nothing stored")

        // Comparing with the stored state sends back only what differs.
        try await link.playForEditing(stored)
        let back = await until { device.parameters.count == 4 && device.switches.count == 2 }
        XCTAssertTrue(back)
        XCTAssertEqual(device.switches.last.map { "\($0.0) \($0.1)" }, "DistortionTS9 false")
    }

    func testAnEditedREACTORPresetIsStoredAndReadBack() async throws {
        let (device, link) = await reactorWithPresets()
        var editor = PresetEditor(try XCTUnwrap(link.slots[1]))
        _ = editor.setParameter(place: ChainPlace.delay.rawValue, index: 0, value: 0.75)
        _ = editor.setOn(place: ChainPlace.modulation.rawValue, true)
        editor.setName("Sound 2b")

        let before = try await link.currentPreset(in: 5)
        XCTAssertEqual(before.name, "Sound 6")
        try await link.store(editor.current, in: 5)
        let stored = try ReactorPreset(data: try XCTUnwrap(device.reactorPresets[5]))
        XCTAssertTrue(stored.checksumOK)
        XCTAssertEqual(stored.slot, 5)
        XCTAssertEqual(stored.name, "Sound 2b")
        XCTAssertEqual(stored.effects.first { $0.id == 0x0432 }?.values[0], 0.75)
        XCTAssertEqual(stored.effects.first { $0.id == 0x0419 }?.isOn, true)
        XCTAssertEqual(device.active, 5)
        XCTAssertEqual(link.activeSlot, 5)
        XCTAssertEqual(link.slots[5], editor.current)
        XCTAssertEqual(link.reactorPresets[5]?.name, "Sound 2b")
        XCTAssertFalse(link.isEditingLive)
        XCTAssertEqual(device.reactorPresets[1], ReactorChainFixture.preset(slot: 1, name: "Sound 2"), "the source stays")

        // A Spark preset never goes to a REACTOR.
        do {
            try await link.store(PresetFactory.empty(), in: 0)
            XCTFail("stored a Spark preset on a REACTOR")
        } catch {}
        XCTAssertEqual(device.reactorPresets[0], ReactorChainFixture.preset(slot: 0, name: "Sound 1"))
    }

    func testTheREACTORsPresetsAreReadAfterConnecting() async {
        let (device, link) = make([.reactor])
        for slot in 0..<8 {
            device.reactorPresets[slot] = ReactorFixture.preset(slot: slot, name: "Sound \(slot + 1)", amp: "Twin Clean",
                                                                effectsOn: slot)
        }
        device.active = 6
        link.start()
        let read = await until { link.reactorPresets.count == 8 && link.reactorPresets.allSatisfy { $0 != nil } && link.activeSlot == 6 }
        XCTAssertTrue(read)
        XCTAssertEqual(link.reactorPresets.map { $0?.name }, (1...8).map { "Sound \($0)" })
        XCTAssertEqual(link.reactorPresets[3]?.summary, "Twin Clean · 3 effects on")
        XCTAssertEqual(link.slots.count, 8)
        XCTAssertTrue(link.slots.allSatisfy { $0 == nil }, "no Spark preset is made of them")
        // Eight slot requests and the playing slot: only reads.
        XCTAssertEqual(reactorRequests(device), Array(repeating: "02 01", count: 8) + ["02 10"])
    }

    func testTheREACTORGetsOnlyTheLiveCommandsOfASound() async throws {
        let (device, link) = make([.reactor])
        link.reactorGap = .milliseconds(1)
        link.start()
        let connected = await until { link.status == .connected }
        XCTAssertTrue(connected)
        let preset = try SoundRecipe(name: "Crunch", chain: [
            "amp": .init(model: "Plexi", settings: ["gain": .number(6), "bass": .number(4)]),
            "reverb": .init(model: "bias.reverb", settings: ["level": .number(3)]),
        ]).preset().preset
        let sound = try ReactorSound(preset: preset)
        try await link.play(sound)
        // The one slot request after connecting came first (this REACTOR answers nothing); then only the sound.
        XCTAssertEqual(reactorRequests(device).first, "02 01")
        let written = Array((device.written[device.id(.reactor)] ?? []).dropFirst())
        XCTAssertEqual(written, sound.steps(firstSequence: 2).map(\.bytes), "exactly the sound's steps, in order")
        XCTAssertEqual(written.count, 12)
        // Every message is a set of a parameter, the amp selector or an effect switch. Never a preset or a request.
        for block in written {
            let message = try XCTUnwrap(SparkProtocol.Parser().feed(block).first)
            XCTAssertEqual(message.command, SparkProtocol.Command.set)
            XCTAssertTrue([SparkProtocol.Sub.parameter, ReactorState.ampSelector, SparkProtocol.Sub.effectOnOff]
                .contains(message.sub))
        }
    }

    func testASparkNeverGetsAReactorSound() async throws {
        let (device, link) = make([.mini])
        link.start()
        _ = await ready(link)
        let before = device.written[device.id(.mini)]?.count ?? 0
        let sound = try ReactorSound(preset: PresetFactory.empty())
        do {
            try await link.play(sound)
            XCTFail("sent a REACTOR sound to a Spark")
        } catch {}
        XCTAssertEqual(device.written[device.id(.mini)]?.count ?? 0, before)
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

    func testLookingAroundListsDevicesWithoutLeavingTheConnection() async {
        let (device, link) = make([.neo])
        link.start()
        _ = await ready(link)
        device.devices.append(SimulatedDevice.Device(
            found: FoundDevice(id: UUID(), name: "Spark MINI BLE", service: "FFC0"), kind: .mini))
        link.lookAround(seconds: 0.2)
        let listed = await until { link.devices.count == 2 }
        XCTAssertTrue(listed)
        XCTAssertEqual(device.connected, device.id(.neo))
        XCTAssertEqual(link.devices.first { $0.name == "Spark MINI" }?.presence, .nearby)
        let done = await until { !link.isLookingAround }
        XCTAssertTrue(done)
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

/// A REACTOR preset built from scratch in the layout read on 2026-11-10, never a real one.
enum ReactorFixture {
    static func string(_ text: String) -> [UInt8] { [0xA0 + UInt8(text.utf8.count)] + Array(text.utf8) }
    static func half(_ value: Float) -> [UInt8] {
        let bits = Float16(value).bitPattern
        return [0xCD, UInt8(bits >> 8), UInt8(bits & 0xFF)]
    }
    static func card(_ name: String, icon: String, tags: [String]) -> [UInt8] {
        [0xC4, 0x10] + [UInt8](repeating: 0xAB, count: 16) + string(name) + string("1.0") + string("") + string(icon)
            + [0x01, 0x90 + UInt8(tags.count)] + tags.flatMap(string)
    }
    static func block(_ id: UInt16, on: Bool, _ values: [Float]) -> [UInt8] {
        let count: [UInt8] = values.count < 16 ? [0x90 + UInt8(values.count)]
            : [0xDC, UInt8(values.count >> 8), UInt8(values.count & 0xFF)]
        return [0xC4, 0x02, UInt8(id >> 8), UInt8(id & 0xFF), on ? 0xC3 : 0xC2] + count
            + values.flatMap { $0 == 0 ? [UInt8(0)] : half($0) }
    }
    /// Long enough for three chunks, like the real ones.
    static func preset(slot: Int, name: String, amp: String, effectsOn: Int = 2) -> [UInt8] {
        let fixed: [(UInt16, Int)] = [(0x0502, 145), (0x0503, 4), (0x0505, 110), (0x0506, 11), (0x0434, 30), (0x0435, 30)]
        var data: [UInt8] = [0x00, UInt8(slot)] + card(name, icon: "icon.png", tags: ["clean", "test"])
        data += [0xCA, 0x42, 0xF0, 0x00, 0x00] + card(amp, icon: "f_amp_Test.png", tags: [])
        data += [0x96] + fixed.flatMap { id, count in block(id, on: true, (0..<count).map { $0 % 3 == 0 ? 0 : 0.5 }) }
        data += [0x9A] + (0..<10).flatMap { block(0x0409 + UInt16($0), on: $0 < effectsOn, [0.25, 1, 0]) }
        return data + ReactorPreset.checksum(of: data.dropFirst(2))
    }
}

/// A REACTOR preset with the effect models seen on a REACTOR 50, built from scratch, never a real one.
enum ReactorChainFixture {
    static let effects: [(UInt16, Bool, [Float])] = [
        (0x0309, true, [0.375, 0.9, 1]), (0x0416, false, [0.72, 0.56, 0]), (0x0422, false, [0.558, 0, 0.905]),
        (0x040C, false, [0.5, 0, 0.5, 0.5, 0.5, 0.5]), (0x040D, true, [7]),
        (0x042C, true, [0.9, 0.45, 0.48, 0.5, 0.55, 0.57, 0.52, 0.46]), (0x0419, false, [0.3, 0]),
        (0x0432, false, [0.48, 0.38, 0.34, 0.45, 0]), (0x0411, true, [0.12, 0.5, 0.4, 0.35, 0.1, 0.7, 0, 1]),
        (0x0412, false, [0.5, 0.5, 1, 1]),
    ]

    static func preset(slot: Int = 1, name: String = "Warm Edge", amp: String = "Tweed Tone") -> [UInt8] {
        let fixed: [(UInt16, [Float])] = [
            (0x0503, [0.009, 0.507, 0.526, 0.67]), (0x0502, [0.793, 2, 10, 10] + [Float](repeating: 0.5, count: 141)),
            (0x0505, [0.314, 0, 5, 10] + [Float](repeating: 1000, count: 106)), (0x0506, [Float](repeating: 0.2, count: 11)),
            (0x0434, [Float](repeating: 0.5, count: 30)), (0x0435, [Float](repeating: -3.6, count: 30)),
        ]
        var data: [UInt8] = [0x00, UInt8(slot)] + ReactorFixture.card(name, icon: "icon.png", tags: ["warm"])
        data += [0xCA, 0x42, 0xF0, 0x00, 0x00] + ReactorFixture.card(amp, icon: "f_amp_Test.png", tags: [])
        data += [0x96] + fixed.flatMap { ReactorFixture.block($0.0, on: true, $0.1) }
        data += [0x9A] + effects.flatMap { ReactorFixture.block($0.0, on: $0.1, $0.2) }
        return data + ReactorPreset.checksum(of: data.dropFirst(2))
    }
}
