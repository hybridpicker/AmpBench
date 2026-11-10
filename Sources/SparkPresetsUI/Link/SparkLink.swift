import Foundation
import OSLog
import SparkControl

/// A preset on its way to or from the amp, for the load meter.
struct Transfer: Equatable {
    enum Kind { case sending, reading, switching }
    var kind: Kind
    var done = 0
    /// Chunks in all. Nil while unknown, and for a switch, which is a single message.
    var total: Int?

    var fraction: Double? { total.map { Double(min(done, $0)) / Double(max($0, 1)) } }
}

enum LinkError: LocalizedError {
    case notConnected
    case noAnswer
    case unreadable(String)
    case verifyFailed(String)
    case refused([String])
    /// The device's profile does not allow this, such as anything at all on a REACTOR.
    case notAllowed(String)
    case notSupported(String)

    var errorDescription: String? {
        switch self {
        case .refused(let problems):
            "Nicht gesendet, damit der Verstärker nichts Unbekanntes spielt: " + problems.joined(separator: " ")
        case .notAllowed(let device): "An \(device) sendet Spark Studio nichts. Er wird nur mitgelesen."
        case .notSupported(let device): "Das kann Spark Studio mit \(device) noch nicht; es ist dort nicht geprüft."
        case .notConnected: "Der Verstärker ist nicht verbunden."
        case .noAnswer: "Der Verstärker hat nicht geantwortet."
        case .unreadable(let detail): "Der Verstärker hat ein Preset geschickt, das nicht lesbar ist (\(detail))."
        case .verifyFailed(let name):
            "Beim Zurücklesen enthielt der Platz nicht „\(name)“. Die Sicherung liegt in der Bibliothek."
        }
    }
}

/// A device Spark Studio has been connected to, remembered by its Bluetooth identifier so two devices of the same kind
/// stay apart.
struct KnownDevice: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var kind: DeviceProfile.Kind

    var profile: DeviceProfile { DeviceProfile.profile(kind) }
}

/// The devices Spark Studio knows and the one last chosen, kept in UserDefaults.
@MainActor
final class DeviceMemory {
    private let defaults: UserDefaults
    private static let knownKey = "Known Devices"
    private static let chosenKey = "Chosen Device"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var known: [KnownDevice] {
        get {
            guard let data = defaults.data(forKey: Self.knownKey) else { return [] }
            return (try? JSONDecoder().decode([KnownDevice].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.knownKey) }
    }

    var chosen: UUID? {
        get { defaults.string(forKey: Self.chosenKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.chosenKey) }
    }

    func remember(_ device: KnownDevice) {
        var all = known
        if let index = all.firstIndex(where: { $0.id == device.id }) { all[index] = device } else { all.append(device) }
        known = all
    }
}

/// One line of the device choice: a known or nearby device and whether it is there.
struct DeviceEntry: Identifiable, Equatable {
    enum Presence { case connected, nearby, absent }
    let id: UUID
    let name: String
    let profile: DeviceProfile
    let presence: Presence
}

/// The Bluetooth LE connection to a Positive Grid device. It only looks for devices that offer the Spark control
/// service FFC0 or REACTOR's FFD0, so no other Bluetooth device nearby is ever seen by the app. Requests run one at a
/// time. There is one control connection at a time; choosing another device ends the current one first.
///
/// What may go to a device is decided by its `DeviceProfile`. A profile without `.send` (the REACTOR) gets not a single
/// byte: the transport keeps no characteristic to write to, and every write is refused here too.
@MainActor
final class SparkLink: NSObject, ObservableObject {
    enum Status: Equatable {
        /// `off`: disconnected on request, in Spark Studio. The link does not look for the amp until started again.
        case starting, unauthorized, bluetoothOff, unsupported, searching, connecting, connected, off
    }

    @Published private(set) var status = Status.starting
    /// The device's name as the window shows it. For a REACTOR it includes the part its owner chose, so it never goes
    /// into a log; `loggableName` does.
    @Published private(set) var deviceName: String?
    @Published private(set) var firmware: String?
    /// What the connected device is, or the chosen one while none is connected.
    @Published private(set) var profile = DeviceProfile.sparkMini
    /// The stored preset playing, from 0. Nil while unknown or while a preset is tried out.
    @Published private(set) var activeSlot: Int?
    /// The name of a preset that plays without being stored.
    @Published private(set) var tryingOut: String?
    /// True while the editor's preset plays on the temporary place, so live changes are heard.
    @Published private(set) var isEditingLive = false
    @Published private(set) var slots: [SparkPreset?] = Array(repeating: nil, count: 4)
    /// What a REACTOR reported by itself since it was connected.
    @Published private(set) var reactor = ReactorState()
    /// The presets of a REACTOR's slots as read after connecting, nil where not read (yet).
    @Published private(set) var reactorPresets: [ReactorPreset?] = []
    /// Devices found in this session and devices connected before, for the device choice.
    @Published private(set) var devices: [DeviceEntry] = []
    /// What the link is doing, for the status line.
    @Published private(set) var activity: String?
    /// What is moving between Mac and amp right now, with its progress.
    @Published private(set) var transfer: Transfer?
    private var transferToken = 0
    /// Something the amp did by itself, such as a press of its preset button.
    var onAmpEvent: ((String) -> Void)?
    /// Every message sent and received, one line each, for the live self-test.
    var trace: ((String) -> Void)?
    /// The amp switched to a stored preset by itself, from 0.
    var onAmpSelected: ((Int) -> Void)?
    /// Called after every new connection, once the amp was read. True when the connection came back by itself after
    /// it was lost, false when it was asked for.
    var onConnected: ((Bool) -> Void)?
    /// The connection ended while a sound played that is not stored, on a device that drops it then (the NEO). The
    /// device plays its stored slot again. Gets the device's name.
    var onTemporaryLost: ((String) -> Void)?
    /// Called when the amp confirmed a change with an echo (`03`) instead of an acknowledgement (`04`). That came
    /// before the amp hung once, so whoever sends changes should slow down.
    var onStrain: (() -> Void)?

    /// True once the amp confirmed that its own tuner is on. The amp is silent then.
    @Published private(set) var isAmpTunerOn = false
    /// Every reading of the amp's own tuner: the note from 0 (C) to 11 (H) and the cents, nil without signal.
    var onTunerReading: ((Int, Double?) -> Void)?
    /// What the tuner area asks for. The link keeps to it, also after a connection came back.
    private(set) var ampTunerWanted = false
    /// The amp's tuner may still be on: it was on when the connection ended, or switching it off got no answer.
    private var ampTunerMaybeOn = false
    private var tunerTask: Task<Void, Never>?
    private var lastTunerReading = Date.distantPast
    /// How often switching off was tried without an answer, so it is not tried forever.
    private var tunerOffTries = 0

    /// The amp sometimes ignores a request that follows the previous answer right away.
    var gap: Duration = .milliseconds(150)
    /// Between two live commands to a REACTOR. By hand they were sent seconds apart; a quarter second is a guess on
    /// the careful side, since a fast series of model changes once made a Spark hang.
    var reactorGap: Duration = .milliseconds(250)
    /// Waiting ends when the amp stays silent this long. A preset takes several seconds, but data keeps coming.
    var silence = 3.0

    private let transport: LinkTransport
    private let memory: DeviceMemory
    private var parser = SparkProtocol.Parser()
    private var sequence: UInt8 = 0
    private var waiting: (sub: UInt8, commands: Set<UInt8>, token: Int, continuation: CheckedContinuation<SparkProtocol.Message, Error>)?
    private var token = 0
    private var queue: Task<Void, Never>?
    /// True between `start` and `stop`: the link should hold or look for a connection.
    @Published private(set) var wanted = false
    /// The device to connect to. Nil until one was chosen or found.
    @Published private(set) var chosenID: UUID?
    private var nearby: [UUID: FoundDevice] = [:]
    private var connecting: FoundDevice?
    private var connectedID: UUID?
    /// True while a connection ends because another device was chosen.
    private var isSwitching = false
    /// True after a connection was lost without being asked to end.
    private var lostByItself = false

    init(transport: LinkTransport? = nil, memory: DeviceMemory? = nil) {
        let transport = transport ?? CoreBluetoothTransport()
        self.transport = transport
        self.memory = memory ?? DeviceMemory()
        super.init()
        transport.delegate = self
        chosenID = self.memory.chosen
        if let chosen = self.memory.known.first(where: { $0.id == chosenID }) { setProfile(chosen.profile) }
        updateDevices()
    }

    /// The simulated devices of window pictures, nil with real Bluetooth.
    var simulated: SimulatedDevice? { transport as? SimulatedDevice }

    /// The device's name for logs: a REACTOR's own part cut off.
    var loggableName: String { DeviceProfile.loggableName(deviceName ?? profile.displayName) }

    /// The name the window uses for the device, its own or the profile's.
    var shownName: String { deviceName ?? profile.displayName }

    func can(_ capability: DeviceProfile.Capabilities) -> Bool {
        status == .connected && profile.can(capability)
    }

    func start() {
        wanted = true
        transport.powerUp()
        updateStatus(for: transport.state)
    }

    /// Ends the connection, so the Spark app on the phone can take the amp. A request still running fails with
    /// "not connected" and is reported like any lost connection.
    func stop() {
        wanted = false
        transport.stopSearch()
        if let id = connectedID ?? connecting?.id { endConnection(id) }
        status = .off
    }

    /// Ends a connection. An amp whose tuner may be on gets `tuner off` first, so it is not left silent; the
    /// disconnect waits a moment for that write to go out.
    private func endConnection(_ id: UUID) {
        guard id == connectedID, status == .connected, ampTunerMaybeOn || isAmpTunerOn, profile.canSend else {
            transport.disconnect(id)
            return
        }
        sequence = (sequence + 1) & 0x7F
        try? write([SparkProtocol.setTuner(false, sequence: sequence)])
        isAmpTunerOn = false
        ampTunerMaybeOn = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.connectedID == id, !self.wanted || self.isSwitching else { return }
                self.transport.disconnect(id)
            }
        }
    }

    /// Connects to another device. The current connection ends first, cleanly; there is only ever one.
    func choose(_ id: UUID) {
        guard id != chosenID || status != .connected else { return }
        chosenID = id
        memory.chosen = id
        if let known = memory.known.first(where: { $0.id == id }) { setProfile(known.profile) }
        if let nearby = nearby[id] { setProfile(DeviceProfile.forAdvertisement(service: nearby.service, name: nearby.name)) }
        updateDevices()
        if let current = connectedID ?? connecting?.id, current != id {
            isSwitching = true
            endConnection(current)
        } else if !wanted {
            start()
        } else {
            scan()
        }
    }

    /// Looks for other devices nearby for a few seconds while connected, for the device choice. The connection stays;
    /// nothing is connected to, only listed.
    @Published private(set) var isLookingAround = false

    func lookAround(seconds: Double = 8) {
        guard status == .connected, transport.state == .poweredOn, !isLookingAround else { return }
        isLookingAround = true
        transport.startSearch(services: DeviceProfile.searchedServices)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isLookingAround else { return }
                self.isLookingAround = false
                if self.status == .connected { self.transport.stopSearch() }
            }
        }
    }

    private func updateStatus(for state: TransportState) {
        switch state {
        case .poweredOn: scan()
        case .unauthorized: status = .unauthorized
        case .poweredOff: status = .bluetoothOff
        case .unsupported: status = .unsupported
        case .unknown: break
        }
    }

    private func scan() {
        guard wanted, transport.state == .poweredOn, connectedID == nil, connecting == nil else { return }
        status = .searching
        if let chosenID, let device = nearby[chosenID] {
            connect(device)
            return
        }
        transport.startSearch(services: DeviceProfile.searchedServices)
    }

    private func connect(_ device: FoundDevice) {
        transport.stopSearch()
        connecting = device
        chosenID = device.id
        memory.chosen = device.id
        let remembered = memory.known.first { $0.id == device.id && $0.kind != .unknownSpark }?.profile
        let profile = remembered.flatMap { $0.bleService == device.service ? $0 : nil }
            ?? DeviceProfile.forAdvertisement(service: device.service, name: device.name)
        setProfile(profile)
        deviceName = Self.shown(device.name)
        firmware = nil
        status = .connecting
        memory.remember(KnownDevice(id: device.id, name: deviceName ?? profile.displayName, kind: profile.id))
        updateDevices()
        transport.connect(device, listenOnly: !(profile.canSend || profile.can(.liveSound)
                                                || profile.can(.reactorPresets)))
    }

    private static func shown(_ name: String?) -> String? {
        name.map { $0.replacingOccurrences(of: " BLE", with: "").replacingOccurrences(of: " Control", with: "") }
    }

    private func setProfile(_ new: DeviceProfile) {
        profile = new
        if slots.count != new.slotCount { slots = Array(repeating: nil, count: new.slotCount) }
    }

    private func updateDevices() {
        var entries: [DeviceEntry] = []
        var seen = Set<UUID>()
        for known in memory.known {
            seen.insert(known.id)
            let presence: DeviceEntry.Presence = known.id == connectedID ? .connected
                : nearby[known.id] != nil ? .nearby : .absent
            entries.append(DeviceEntry(id: known.id, name: known.name, profile: known.profile, presence: presence))
        }
        for device in nearby.values.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) where !seen.contains(device.id) {
            let profile = DeviceProfile.forAdvertisement(service: device.service, name: device.name)
            entries.append(DeviceEntry(id: device.id, name: Self.shown(device.name) ?? profile.displayName,
                                       profile: profile, presence: device.id == connectedID ? .connected : .nearby))
        }
        if entries != devices { devices = entries }
    }

    // MARK: Requests

    /// Runs one request after the other, so answers can never be mixed up.
    private func serial<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queue
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await work()
        }
        queue = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Sends a message and waits for the answer, asking a second time when none comes.
    private func request(_ build: @escaping (UInt8) -> [[UInt8]], answer sub: UInt8,
                         command: UInt8 = SparkProtocol.Command.response) async throws -> SparkProtocol.Message {
        try await serial { [self] in
            do {
                return try await once(build, sub: sub, commands: [command])
            } catch LinkError.noAnswer {
                return try await once(build, sub: sub, commands: [command])
            }
        }
    }

    /// Sends a change the amp confirms, with `04 <sub>` or at times with an echo `03 <sub>`. It is not sent a second
    /// time, because a change that already happened gets no answer at all. Returns false when none came.
    private func confirmed(_ build: @escaping (UInt8) -> [[UInt8]], answer sub: UInt8) async throws -> Bool {
        try await serial { [self] in
            do {
                let message = try await once(build, sub: sub, commands: [SparkProtocol.Command.acknowledge,
                                                                         SparkProtocol.Command.response])
                if message.command != SparkProtocol.Command.acknowledge { onStrain?() }
                return true
            } catch LinkError.noAnswer {
                return false
            }
        }
    }

    /// Sends a message the amp does not answer, then keeps a short gap.
    private func sendOnly(_ build: @escaping (UInt8) -> [[UInt8]], gap: Duration) async throws {
        try await serial { [self] in
            guard status == .connected else { throw LinkError.notConnected }
            sequence = (sequence + 1) & 0x7F
            let blocks = build(sequence)
            try write(blocks)
            try await Task.sleep(for: gap)
        }
    }

    /// Plays a sound on a REACTOR with the few live commands it was heard taking: one message at a time with a pause,
    /// tone and gain before the amp. The only way anything reaches a device without `send`; it never gets a preset,
    /// a request or anything else.
    func play(_ sound: ReactorSound) async throws {
        try await serial { [self] in
            guard status == .connected else { throw LinkError.notConnected }
            guard profile.can(.liveSound), !profile.canSend else { throw LinkError.notSupported(profile.displayName) }
            for step in sound.steps(firstSequence: (sequence + 1) & 0x7F) {
                guard status == .connected else { throw LinkError.notConnected }
                sequence = (sequence + 1) & 0x7F
                trace?("→ REACTOR " + step.text)
                try transport.write([step.bytes])
                try await Task.sleep(for: reactorGap)
            }
        }
    }

    /// The one place where bytes go to the device. A profile that may not send gets nothing, whatever asked.
    private func write(_ blocks: [[UInt8]]) throws {
        guard profile.canSend else {
            Self.linkLog.fault("refused to write \(Self.describe(blocks), privacy: .public) to \(self.profile.displayName, privacy: .public): its profile may not send")
            throw LinkError.notAllowed(profile.displayName)
        }
        trace?("→ " + Self.describe(blocks))
        try transport.write(blocks)
    }

    private func once(_ build: (UInt8) -> [[UInt8]], sub: UInt8, commands: Set<UInt8>) async throws -> SparkProtocol.Message {
        try await Task.sleep(for: gap)
        guard status == .connected else { throw LinkError.notConnected }
        guard profile.canSend else { throw LinkError.notAllowed(profile.displayName) }
        sequence = (sequence + 1) & 0x7F
        let blocks = build(sequence)
        return try await withCheckedThrowingContinuation { continuation in
            waiting = (sub, commands, 0, continuation)
            armTimeout()
            do {
                try write(blocks)
            } catch {
                failWaiting(error)
            }
        }
    }

    private func armTimeout() {
        guard let current = waiting else { return }
        token += 1
        let mine = token
        waiting = (current.sub, current.commands, mine, current.continuation)
        DispatchQueue.main.asyncAfter(deadline: .now() + silence) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let waiting = self.waiting, waiting.token == mine else { return }
                self.waiting = nil
                waiting.continuation.resume(throwing: LinkError.noAnswer)
            }
        }
    }

    private func failWaiting(_ error: Error) {
        guard let waiting else { return }
        self.waiting = nil
        waiting.continuation.resume(throwing: error)
    }

    /// Refuses what the connected device's profile does not allow.
    private func require(_ capability: DeviceProfile.Capabilities) throws {
        guard status == .connected else { throw LinkError.notConnected }
        guard profile.can(capability) else { throw LinkError.notSupported(profile.displayName) }
    }

    func readPreset(_ place: SparkPresetPlace) async throws -> SparkPreset {
        try require(.read)
        let slot: UInt8? = if case .slot(let slot) = place { slot } else { nil }
        let message = try await tracked(Transfer(kind: .reading)) {
            try await request({ [SparkProtocol.getPreset(slot: slot, sequence: $0)] }, answer: SparkProtocol.Sub.preset)
        }
        do {
            return try SparkPreset(payload: message.payload)
        } catch {
            throw LinkError.unreadable("\(error)")
        }
    }

    private func switchTo(_ slot: UInt8) async throws {
        _ = try await tracked(Transfer(kind: .switching)) {
            try await request({ [SparkProtocol.changeHardwarePreset(slot: slot, sequence: $0)] },
                              answer: SparkProtocol.Sub.hardwarePreset, command: SparkProtocol.Command.acknowledge)
        }
    }

    /// The amp confirms every chunk with `05 01` and the whole preset with `04 01`, which drives the load meter.
    private func send(_ original: SparkPreset, to place: SparkPresetPlace) async throws {
        let problems = AmpGuard.problems(original, for: profile)
        guard problems.isEmpty else {
            Self.ampLog.error("refused \"\(original.name, privacy: .public)\": \(problems.joined(separator: " "), privacy: .public)")
            throw LinkError.refused(problems)
        }
        // Fitted to this device: on the NEO only texts as long as it was heard playing.
        let preset = AmpGuard.prepared(original, for: profile)
        let total = SparkProtocol.sendPreset(preset, to: place, sequence: 0).count
        Self.log(preset, original: original, to: place, chunks: total, device: profile.displayName)
        _ = try await tracked(Transfer(kind: .sending, total: total)) {
            try await request({ SparkProtocol.sendPreset(preset, to: place, sequence: $0) },
                              answer: SparkProtocol.Sub.preset, command: SparkProtocol.Command.acknowledge)
        }
    }

    /// Every preset that goes to the amp, readable afterwards with
    /// `log show --predicate 'subsystem == "local.sparkstudio" AND category == "amp"' --info --last 1h`.
    /// Only the sound itself is written: name, lengths, models and values, and the kind of device.
    private static let ampLog = Logger(subsystem: "local.sparkstudio", category: "amp")
    private static let linkLog = Logger(subsystem: "local.sparkstudio", category: "link")

    private static func log(_ preset: SparkPreset, original: SparkPreset, to place: SparkPresetPlace, chunks: Int,
                            device: String) {
        let sent = PresetRules.forAmp(preset)
        let target = if case .slot(let slot) = place { "slot \(slot + 1)" } else { "temporary" }
        let chain = sent.effects.map { effect in
            let values = effect.parameters.map { String(format: "%.2f", $0.value) }.joined(separator: " ")
            return "\(effect.name)\(effect.isOn ? "" : " (off)") [\(values)]"
        }.joined(separator: " | ")
        let cut = sent.description == original.description ? "" : " (cut from \(original.description.utf8.count))"
            + (sent.name == original.name ? "" : ", name cut from \(original.name.utf8.count) bytes")
        let line = "send \"\(sent.name)\" to \(device) \(target): \(chunks) chunks, description "
            + "\(sent.description.utf8.count) bytes\(cut), bpm \(sent.bpm), \(chain)"
        ampLog.info("\(line, privacy: .public)")
    }

    /// The command and sub-command of a message to the amp, and the number of chunks.
    private static func describe(_ blocks: [[UInt8]]) -> String {
        guard let first = blocks.first, let start = first.firstIndex(of: 0xF0), first.count > start + 5 else { return "?" }
        let text = String(format: "%02X %02X", first[start + 4], first[start + 5])
        return blocks.count > 1 ? text + " (\(blocks.count) chunks)" : text
    }

    private func tracked<T>(_ transfer: Transfer, _ work: () async throws -> T) async rethrows -> T {
        transferToken += 1
        let mine = transferToken
        self.transfer = transfer
        defer { if transferToken == mine { self.transfer = nil } }
        return try await work()
    }

    // MARK: Actions

    /// Asks a Spark device for its amp name (`02 11`) and takes the profile it names. Falls back to what the Bluetooth
    /// name said when the name is missing or unknown.
    private func identify() async {
        guard let message = try? await request({ [SparkProtocol.getAmpName(sequence: $0)] },
                                               answer: SparkProtocol.Sub.ampName),
              let name = SparkValues.string(message.payload) else { return }
        deviceName = name
        if let named = DeviceProfile.forAmpName(name), named.bleService == profile.bleService { setProfile(named) }
        if let id = connectedID { memory.remember(KnownDevice(id: id, name: name, kind: profile.id)) }
        updateDevices()
    }

    /// Reads everything the window shows: firmware, the preset playing and the slots.
    func loadAll() async {
        guard can(.read) else { return }
        activity = "Lese \(shownName) …"
        defer { activity = nil }
        if let message = try? await request({ [SparkProtocol.getFirmware(sequence: $0)] },
                                            answer: SparkProtocol.Sub.firmware) {
            firmware = SparkValues.firmware(message.payload)
        }
        if let message = try? await request({ [SparkProtocol.getPresetNumber(sequence: $0)] },
                                            answer: SparkProtocol.Sub.presetNumber),
           let slot = SparkValues.slot(message.payload), Int(slot) < profile.slotCount {
            activeSlot = Int(slot)
        }
        for slot in profile.slots {
            activity = "Lese \(profile.slotName(slot)) …"
            await refresh(slot: slot)
        }
    }

    func refresh(slot: Int) async {
        guard slots.indices.contains(slot) else { return }
        if let preset = try? await readPreset(.slot(UInt8(slot))) { slots[slot] = preset }
    }

    func select(slot: Int) async throws {
        try require(.switchSlot)
        guard profile.slots.contains(slot) else { throw LinkError.notSupported(profile.displayName) }
        activity = "Schalte auf \(profile.slotName(slot)) …"
        defer { activity = nil }
        try await switchTo(UInt8(slot))
        activeSlot = slot
        tryingOut = nil
        isEditingLive = false
    }

    /// Plays a preset without storing it. Switching to any slot ends it.
    func tryOut(_ preset: SparkPreset) async throws {
        try require(.playTemporary)
        activity = "Sende „\(preset.name)“ …"
        defer { activity = nil }
        try await send(preset, to: .temporary)
        try await switchTo(0x7F)
        tryingOut = preset.name
        isEditingLive = false
        activeSlot = nil
    }

    // MARK: Live editing

    /// Plays the editor's preset on the temporary place. Changes after it are heard at once.
    func playForEditing(_ preset: SparkPreset) async throws {
        try require(.playTemporary)
        activity = "Sende „\(preset.name)“ zum Bearbeiten …"
        defer { activity = nil }
        try await send(preset, to: .temporary)
        try await switchTo(0x7F)
        tryingOut = nil
        isEditingLive = true
        activeSlot = nil
    }

    /// Sends one live change. Only used while `isEditingLive`. Returns false when a change that the amp confirms
    /// got no answer, so the caller can check what plays. No device checked so far confirms a parameter (`04 04`),
    /// so a parameter is never waited for; reading back after a pause shows whether it arrived.
    func apply(_ change: LiveChange) async throws -> Bool {
        switch change {
        case .parameter(let effect, let index, let value):
            try require(.liveEdit)
            guard AmpGuard.value(value) != nil else { throw LinkError.refused(["Der Wert ist keine Zahl."]) }
            try await sendOnly({ [SparkProtocol.setParameter(effect: effect, index: index, value: value, sequence: $0)] },
                               gap: LivePacing.parameterGap)
            return true
        case .toggle(let effect, let isOn):
            try require(.liveEdit)
            return try await confirmed({ [SparkProtocol.setEffect(effect, on: isOn, sequence: $0)] },
                                       answer: SparkProtocol.Sub.effectOnOff)
        case .model(let old, let new):
            try require(.modelChange)
            return try await confirmed({ [SparkProtocol.changeModel(from: old, to: new, sequence: $0)] },
                                       answer: SparkProtocol.Sub.changeEffect)
        case .whole(let preset):
            try await playForEditing(preset)
            return true
        }
    }

    /// Ends live editing in the link's view, for example when the amp switched to a stored preset.
    func endEditing() {
        isEditingLive = false
    }

    /// Stores a preset in a slot, switches to it and reads it back to make sure it arrived unchanged.
    func store(_ preset: SparkPreset, in slot: Int) async throws {
        try require(.store)
        guard profile.slots.contains(slot) else { throw LinkError.notSupported(profile.displayName) }
        activity = "Speichere „\(preset.name)“ auf \(profile.slotName(slot)) …"
        defer { activity = nil }
        try await send(preset, to: .slot(UInt8(slot)))
        try await switchTo(UInt8(slot))
        activeSlot = slot
        tryingOut = nil
        isEditingLive = false
        activity = "Prüfe \(profile.slotName(slot)) …"
        let stored = try await readPreset(.slot(UInt8(slot)))
        slots[slot] = stored
        // What went out had its description cut to the length the amp takes.
        // Compared apart from the checksum byte, which the amp writes itself, like the Linux app does.
        guard PresetEditor.sameContent(stored, AmpGuard.prepared(preset, for: profile)) else {
            throw LinkError.verifyFailed(preset.name)
        }
    }

    /// Reads a slot fresh from the amp, for a backup that must match what is really stored.
    func currentPreset(in slot: Int) async throws -> SparkPreset {
        let preset = try await readPreset(.slot(UInt8(slot)))
        slots[slot] = preset
        return preset
    }

    // MARK: The amp's own tuner

    /// The connected device can switch its tuner on from here: a MINI or NEO, never a device that is only listened to.
    var canUseAmpTuner: Bool { status == .connected && profile.can(.tuner) && profile.canSend }

    /// Asks for the amp's tuner on or off. It is switched when connected and kept so after a reconnect.
    func wantAmpTuner(_ on: Bool) {
        ampTunerWanted = on
        if on { tunerOffTries = 0 }
        reconcileTuner()
    }

    /// Switches the amp's tuner until it is as wanted: one message at a time, never two at once.
    private func reconcileTuner() {
        guard tunerTask == nil, canUseAmpTuner else { return }
        let on = ampTunerWanted
        if on ? isAmpTunerOn : !(isAmpTunerOn || ampTunerMaybeOn) { return }
        if !on, tunerOffTries >= 3 {
            Self.linkLog.error("the amp's tuner may still be on: switching it off got no answer three times")
            return
        }
        tunerTask = Task { [weak self] in
            guard let self else { return }
            await switchTuner(on)
            tunerTask = nil
            if status == .connected, ampTunerWanted != on || (!on && ampTunerMaybeOn) { reconcileTuner() }
        }
    }

    private func switchTuner(_ on: Bool) async {
        let answered = (try? await confirmed({ [SparkProtocol.setTuner(on, sequence: $0)] },
                                             answer: SparkProtocol.Sub.tuner)) ?? false
        guard status == .connected else { return }
        if on {
            // The amp may be on even without an answer, so it is switched off later in any case.
            ampTunerMaybeOn = true
            isAmpTunerOn = answered || Date().timeIntervalSince(lastTunerReading) < 1
            if !answered { Self.linkLog.notice("the amp did not confirm its tuner on") }
            return
        }
        isAmpTunerOn = false
        if answered {
            ampTunerMaybeOn = false
            tunerOffTries = 0
            return
        }
        // The MINI once switched off without `04 65`. Readings that stop are an answer too.
        tunerOffTries += 1
        try? await Task.sleep(for: .seconds(1))
        ampTunerMaybeOn = Date().timeIntervalSince(lastTunerReading) < 0.8
    }

    /// Switches the amp's tuner off before the app ends, waiting at most `seconds` for it.
    func switchTunerOffBeforeQuitting(seconds: Double = 1.5) async {
        ampTunerWanted = false
        guard canUseAmpTuner, isAmpTunerOn || ampTunerMaybeOn else { return }
        reconcileTuner()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, isAmpTunerOn || ampTunerMaybeOn || tunerTask != nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    var ampTunerMayBeOn: Bool { isAmpTunerOn || ampTunerMaybeOn }

    // MARK: Incoming

    private func received(_ bytes: [UInt8]) {
        let messages = parser.feed(bytes)
        // The tuner's readings come many times a second and must not keep a wait alive forever.
        if messages.isEmpty || parser.isInsideChunk || messages.contains(where: { $0.sub != SparkProtocol.Sub.tunerPitch }) {
            armTimeout()
        }
        if transfer?.kind == .reading, let progress = parser.chunkProgress {
            transfer?.done = progress.received
            transfer?.total = progress.total
        }
        for message in messages {
            if let trace, message.sub != SparkProtocol.Sub.tunerPitch {
                let event = SparkEvent(message).map { " \($0)" } ?? ""
                trace(String(format: "← %02X %02X", message.command, message.sub) + event)
            }
            if !profile.canSend {
                // The answer to one of the few read requests a REACTOR gets.
                if let waiting, waiting.sub == message.sub, waiting.commands.contains(message.command) {
                    self.waiting = nil
                    waiting.continuation.resume(returning: message)
                    continue
                }
                listened(message)
                continue
            }
            if message.sub == SparkProtocol.Sub.tunerPitch, case .tuner(let note, let offset)? = SparkEvent(message) {
                lastTunerReading = Date()
                onTunerReading?(Int(note), offset.map(SparkProtocol.tunerCents))
                continue
            }
            if message.command == 0x05, message.sub == SparkProtocol.Sub.preset, transfer?.kind == .sending {
                transfer?.done += 1
            }
            if let waiting, waiting.sub == message.sub, waiting.commands.contains(message.command) {
                self.waiting = nil
                waiting.continuation.resume(returning: message)
                continue
            }
            // The amp's own preset button, or the NEO's middle button.
            if message.command == SparkProtocol.Command.response, message.sub == SparkProtocol.Sub.hardwarePreset,
               let slot = SparkValues.slot(message.payload), Int(slot) < profile.slotCount {
                activeSlot = Int(slot)
                tryingOut = nil
                isEditingLive = false
                let name = slots[Int(slot)].map { " „\($0.name)“" } ?? ""
                onAmpEvent?("Am \(shownName) gewählt: \(profile.slotName(Int(slot)))\(name)")
                onAmpSelected?(Int(slot))
            }
        }
    }

    /// A device that is only listened to: its messages become its state, nothing is answered.
    private func listened(_ message: SparkProtocol.Message) {
        let before = reactor.slot
        reactor.apply(message)
        guard reactor.slot != before, let slot = reactor.slot else { return }
        activeSlot = slot
        let name = (reactorPresets[safe: slot] ?? nil).map { " „\($0.name)“" }
        onAmpEvent?("Am \(profile.displayName) gewählt: \(profile.slotName(slot))"
                    + (name ?? ". Der Inhalt des Presets ist unbekannt."))
    }

    /// One read request to a REACTOR and its answer. Only for a profile with `reactorPresets`; it has no `send`, so
    /// this and `play(_:)` are the only ways anything reaches it.
    private func askReactor(_ build: @escaping (UInt8) -> [UInt8], answer sub: UInt8) async throws -> SparkProtocol.Message {
        try await serial { [self] in
            try await Task.sleep(for: gap)
            guard status == .connected else { throw LinkError.notConnected }
            guard profile.can(.reactorPresets), !profile.canSend else { throw LinkError.notSupported(profile.displayName) }
            sequence = (sequence + 1) & 0x7F
            let bytes = build(sequence)
            return try await withCheckedThrowingContinuation { continuation in
                waiting = (sub, [SparkProtocol.Command.response], 0, continuation)
                armTimeout()
                do {
                    trace?("→ REACTOR " + Self.describe([bytes]))
                    try transport.write([bytes])
                } catch {
                    failWaiting(error)
                }
            }
        }
    }

    /// Reads the REACTOR's stored presets and the playing slot. Reads only; a slot that does not answer or cannot be
    /// read stays unknown, and the rest is not asked for.
    func loadReactorPresets() async {
        guard status == .connected, profile.can(.reactorPresets) else { return }
        activity = "Lese \(shownName) …"
        defer { activity = nil }
        for slot in profile.slots {
            do {
                let message = try await askReactor({ SparkProtocol.getPreset(slot: UInt8(slot), sequence: $0) },
                                                   answer: SparkProtocol.Sub.preset)
                let preset = try ReactorPreset(payload: message.payload)
                guard reactorPresets.indices.contains(slot) else { return }
                reactorPresets[slot] = preset
            } catch {
                Self.linkLog.error("REACTOR slot \(slot) not read: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        if let message = try? await askReactor({ SparkProtocol.getPresetNumber(sequence: $0) },
                                               answer: SparkProtocol.Sub.presetNumber),
           message.payload.count >= 2, Int(message.payload[1]) < profile.slotCount {
            activeSlot = Int(message.payload[1])
        }
    }

    private func didConnect() {
        status = .connected
        let byItself = lostByItself
        lostByItself = false
        guard profile.canSend else {
            // Listen only: nothing is asked, the device reports by itself.
            reactor = ReactorState()
            reactorPresets = Array(repeating: nil, count: profile.slotCount)
            onConnected?(byItself)
            if profile.can(.reactorPresets) { Task { await loadReactorPresets() } }
            return
        }
        Task {
            await identify()
            await loadAll()
            onConnected?(byItself)
            reconcileTuner()
        }
    }

    private func lost() {
        let wasTemporary = tryingOut != nil || isEditingLive
        let name = shownName
        failWaiting(LinkError.notConnected)
        reactorPresets = []
        connectedID = nil
        connecting = nil
        parser = SparkProtocol.Parser()
        activeSlot = nil
        tryingOut = nil
        // The amp ends the temporary preset when the connection ends; the NEO was heard doing it.
        isEditingLive = false
        // Whether the amp keeps its tuner on without a connection is unknown: it is switched off after reconnecting.
        if isAmpTunerOn { ampTunerMaybeOn = true }
        isAmpTunerOn = false
        tunerOffTries = 0
        if wasTemporary, profile.losesTemporaryOnDisconnect { onTemporaryLost?(name) }
        lostByItself = wanted && !isSwitching
        isSwitching = false
        if let chosen = memory.known.first(where: { $0.id == chosenID }) { setProfile(chosen.profile) }
        updateDevices()
        if transport.state == .poweredOn { status = wanted ? .searching : .off }
        scan()
    }
}

extension SparkLink: LinkTransportDelegate {
    func transport(changedState state: TransportState) {
        updateStatus(for: state)
    }

    func transport(found device: FoundDevice) {
        nearby[device.id] = device
        updateDevices()
        guard wanted, connecting == nil, connectedID == nil else { return }
        if chosenID == nil || chosenID == device.id { connect(device) }
    }

    func transport(connected id: UUID) {
        guard connecting?.id == id else { return }
        connecting = nil
        connectedID = id
        updateDevices()
        didConnect()
    }

    func transport(lost id: UUID) {
        guard id == connectedID || id == connecting?.id else { return }
        lost()
    }

    func transport(received bytes: [UInt8]) {
        guard connectedID != nil else { return }
        received(bytes)
    }
}
