import CoreBluetooth
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

    var errorDescription: String? {
        switch self {
        case .refused(let problems):
            "Nicht gesendet, damit der Verstärker nichts Unbekanntes spielt: " + problems.joined(separator: " ")
        case .notConnected: "Der Verstärker ist nicht verbunden."
        case .noAnswer: "Der Verstärker hat nicht geantwortet."
        case .unreadable(let detail): "Der Verstärker hat ein Preset geschickt, das nicht lesbar ist (\(detail))."
        case .verifyFailed(let name):
            "Beim Zurücklesen enthielt der Platz nicht „\(name)“. Die Sicherung liegt in der Bibliothek."
        }
    }
}

/// The Bluetooth LE connection to the amp. It only looks for devices that offer the Spark control service, so no
/// other Bluetooth device nearby is ever seen by the app. Requests run one at a time.
@MainActor
final class SparkLink: NSObject, ObservableObject {
    enum Status: Equatable {
        /// `off`: disconnected on request, in Spark Studio. The link does not look for the amp until started again.
        case starting, unauthorized, bluetoothOff, unsupported, searching, connecting, connected, off
    }

    @Published private(set) var status = Status.starting
    @Published private(set) var deviceName: String?
    @Published private(set) var firmware: String?
    /// The stored preset playing, 0 to 3. Nil while unknown or while a preset is tried out.
    @Published private(set) var activeSlot: Int?
    /// The name of a preset that plays without being stored.
    @Published private(set) var tryingOut: String?
    /// True while the editor's preset plays on the temporary place, so live changes are heard.
    @Published private(set) var isEditingLive = false
    @Published private(set) var slots: [SparkPreset?] = Array(repeating: nil, count: 4)
    /// What the link is doing, for the status line.
    @Published private(set) var activity: String?
    /// What is moving between Mac and amp right now, with its progress.
    @Published private(set) var transfer: Transfer?
    private var transferToken = 0
    /// Something the amp did by itself, such as a press of its preset button.
    var onAmpEvent: ((String) -> Void)?
    /// Every message sent and received, one line each, for the live self-test.
    var trace: ((String) -> Void)?
    /// The amp switched to a stored preset by itself, 0 to 3.
    var onAmpSelected: ((Int) -> Void)?
    /// Called after every new connection, once the amp was read.
    var onConnected: (() -> Void)?
    /// Called when the amp confirmed a change with an echo (`03`) instead of an acknowledgement (`04`). That came
    /// before the amp hung once, so whoever sends changes should slow down.
    var onStrain: (() -> Void)?

    nonisolated(unsafe) private static let service = CBUUID(string: SparkProtocol.serviceUUID)
    nonisolated(unsafe) private static let write = CBUUID(string: SparkProtocol.writeUUID)
    nonisolated(unsafe) private static let notify = CBUUID(string: SparkProtocol.notifyUUID)
    /// The amp sometimes ignores a request that follows the previous answer right away.
    private static let gap: Duration = .milliseconds(150)
    /// Waiting ends when the amp stays silent this long. A preset takes several seconds, but data keeps coming.
    private static let silence = 3.0

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var parser = SparkProtocol.Parser()
    private var sequence: UInt8 = 0
    private var waiting: (sub: UInt8, commands: Set<UInt8>, token: Int, continuation: CheckedContinuation<SparkProtocol.Message, Error>)?
    private var token = 0
    private var queue: Task<Void, Never>?
    /// True between `start` and `stop`: the link should hold or look for a connection.
    @Published private(set) var wanted = false

    func start() {
        wanted = true
        if let central {
            updateStatus(for: central.state)
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    /// Ends the connection, so the Spark app on the phone can take the amp. A request still running fails with
    /// "not connected" and is reported like any lost connection.
    func stop() {
        wanted = false
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        status = .off
    }

    private func updateStatus(for state: CBManagerState) {
        switch state {
        case .poweredOn: scan()
        case .unauthorized: status = .unauthorized
        case .poweredOff: status = .bluetoothOff
        case .unsupported: status = .unsupported
        default: break
        }
    }

    private func scan() {
        guard wanted, let central, central.state == .poweredOn, peripheral == nil else { return }
        status = .searching
        central.scanForPeripherals(withServices: [Self.service], options: nil)
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
            guard status == .connected, let peripheral, let characteristic = writeCharacteristic else {
                throw LinkError.notConnected
            }
            sequence = (sequence + 1) & 0x7F
            let blocks = build(sequence)
            trace?("→ " + Self.describe(blocks))
            write(blocks, to: peripheral, characteristic)
            try await Task.sleep(for: gap)
        }
    }

    private func write(_ blocks: [[UInt8]], to peripheral: CBPeripheral, _ characteristic: CBCharacteristic) {
        let size = max(peripheral.maximumWriteValueLength(for: .withoutResponse), 20)
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        // A write longer than one Bluetooth packet is refused, so every block goes on its own.
        for block in blocks {
            for start in stride(from: 0, to: block.count, by: size) {
                peripheral.writeValue(Data(block[start..<min(start + size, block.count)]), for: characteristic,
                                      type: type)
            }
        }
    }

    private func once(_ build: (UInt8) -> [[UInt8]], sub: UInt8, commands: Set<UInt8>) async throws -> SparkProtocol.Message {
        try await Task.sleep(for: Self.gap)
        guard status == .connected, let peripheral, let characteristic = writeCharacteristic else {
            throw LinkError.notConnected
        }
        sequence = (sequence + 1) & 0x7F
        let blocks = build(sequence)
        trace?("→ " + Self.describe(blocks))
        return try await withCheckedThrowingContinuation { continuation in
            waiting = (sub, commands, 0, continuation)
            armTimeout()
            write(blocks, to: peripheral, characteristic)
        }
    }

    private func armTimeout() {
        guard let current = waiting else { return }
        token += 1
        let mine = token
        waiting = (current.sub, current.commands, mine, current.continuation)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silence) { [weak self] in
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

    func readPreset(_ place: SparkPresetPlace) async throws -> SparkPreset {
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
    private func send(_ preset: SparkPreset, to place: SparkPresetPlace) async throws {
        let problems = AmpGuard.problems(preset)
        guard problems.isEmpty else {
            Self.ampLog.error("refused \"\(preset.name, privacy: .public)\": \(problems.joined(separator: " "), privacy: .public)")
            throw LinkError.refused(problems)
        }
        let total = SparkProtocol.sendPreset(preset, to: place, sequence: 0).count
        Self.log(preset, to: place, chunks: total)
        _ = try await tracked(Transfer(kind: .sending, total: total)) {
            try await request({ SparkProtocol.sendPreset(preset, to: place, sequence: $0) },
                              answer: SparkProtocol.Sub.preset, command: SparkProtocol.Command.acknowledge)
        }
    }

    /// Every preset that goes to the amp, readable afterwards with
    /// `log show --predicate 'subsystem == "local.sparkstudio" AND category == "amp"' --info --last 1h`.
    /// Only the sound itself is written: name, lengths, models and values.
    private static let ampLog = Logger(subsystem: "local.sparkstudio", category: "amp")

    private static func log(_ preset: SparkPreset, to place: SparkPresetPlace, chunks: Int) {
        let sent = PresetRules.forAmp(preset)
        let target = if case .slot(let slot) = place { "slot \(slot + 1)" } else { "temporary" }
        let chain = sent.effects.map { effect in
            let values = effect.parameters.map { String(format: "%.2f", $0.value) }.joined(separator: " ")
            return "\(effect.name)\(effect.isOn ? "" : " (off)") [\(values)]"
        }.joined(separator: " | ")
        let cut = sent.description == preset.description ? "" : " (cut from \(preset.description.utf8.count))"
        let line = "send \"\(sent.name)\" to \(target): \(chunks) chunks, description "
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

    /// Reads everything the window shows: firmware, the preset playing and the four slots.
    func loadAll() async {
        activity = "Lese den Verstärker …"
        defer { activity = nil }
        if let message = try? await request({ [SparkProtocol.getFirmware(sequence: $0)] },
                                            answer: SparkProtocol.Sub.firmware) {
            firmware = SparkValues.firmware(message.payload)
        }
        if let message = try? await request({ [SparkProtocol.getPresetNumber(sequence: $0)] },
                                            answer: SparkProtocol.Sub.presetNumber),
           let slot = SparkValues.slot(message.payload), slot < 4 {
            activeSlot = Int(slot)
        }
        for slot in 0..<4 {
            activity = "Lese Platz \(slot + 1) …"
            await refresh(slot: slot)
        }
    }

    func refresh(slot: Int) async {
        if let preset = try? await readPreset(.slot(UInt8(slot))) { slots[slot] = preset }
    }

    func select(slot: Int) async throws {
        activity = "Schalte auf Platz \(slot + 1) …"
        defer { activity = nil }
        try await switchTo(UInt8(slot))
        activeSlot = slot
        tryingOut = nil
        isEditingLive = false
    }

    /// Plays a preset without storing it. Switching to any slot ends it.
    func tryOut(_ preset: SparkPreset) async throws {
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
        activity = "Sende „\(preset.name)“ zum Bearbeiten …"
        defer { activity = nil }
        try await send(preset, to: .temporary)
        try await switchTo(0x7F)
        tryingOut = nil
        isEditingLive = true
        activeSlot = nil
    }

    /// Sends one live change. Only used while `isEditingLive`. Returns false when a change that the amp confirms
    /// got no answer, so the caller can check what plays.
    func apply(_ change: LiveChange) async throws -> Bool {
        switch change {
        case .parameter(let effect, let index, let value):
            guard AmpGuard.value(value) != nil else { throw LinkError.refused(["Der Wert ist keine Zahl."]) }
            try await sendOnly({ [SparkProtocol.setParameter(effect: effect, index: index, value: value, sequence: $0)] },
                               gap: LivePacing.parameterGap)
            return true
        case .toggle(let effect, let isOn):
            return try await confirmed({ [SparkProtocol.setEffect(effect, on: isOn, sequence: $0)] },
                                       answer: SparkProtocol.Sub.effectOnOff)
        case .model(let old, let new):
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
        activity = "Speichere „\(preset.name)“ auf Platz \(slot + 1) …"
        defer { activity = nil }
        try await send(preset, to: .slot(UInt8(slot)))
        try await switchTo(UInt8(slot))
        activeSlot = slot
        tryingOut = nil
        isEditingLive = false
        activity = "Prüfe Platz \(slot + 1) …"
        let stored = try await readPreset(.slot(UInt8(slot)))
        slots[slot] = stored
        // What went out had its description cut to the length the amp takes.
        guard stored == PresetRules.forAmp(preset) else { throw LinkError.verifyFailed(preset.name) }
    }

    /// Reads a slot fresh from the amp, for a backup that must match what is really stored.
    func currentPreset(in slot: Int) async throws -> SparkPreset {
        let preset = try await readPreset(.slot(UInt8(slot)))
        slots[slot] = preset
        return preset
    }

    // MARK: Incoming

    private func received(_ bytes: [UInt8]) {
        armTimeout()
        let messages = parser.feed(bytes)
        if transfer?.kind == .reading, let progress = parser.chunkProgress {
            transfer?.done = progress.received
            transfer?.total = progress.total
        }
        for message in messages {
            if let trace, message.sub != SparkProtocol.Sub.tunerPitch {
                let event = SparkEvent(message).map { " \($0)" } ?? ""
                trace(String(format: "← %02X %02X", message.command, message.sub) + event)
            }
            if message.command == 0x05, message.sub == SparkProtocol.Sub.preset, transfer?.kind == .sending {
                transfer?.done += 1
            }
            if let waiting, waiting.sub == message.sub, waiting.commands.contains(message.command) {
                self.waiting = nil
                waiting.continuation.resume(returning: message)
                continue
            }
            // The amp's own preset button.
            if message.command == SparkProtocol.Command.response, message.sub == SparkProtocol.Sub.hardwarePreset,
               let slot = SparkValues.slot(message.payload), slot < 4 {
                activeSlot = Int(slot)
                tryingOut = nil
                isEditingLive = false
                let name = slots[Int(slot)].map { " „\($0.name)“" } ?? ""
                onAmpEvent?("Am Verstärker gewählt: Platz \(slot + 1)\(name)")
                onAmpSelected?(Int(slot))
            }
        }
    }

    private func connected() {
        status = .connected
        Task {
            await loadAll()
            onConnected?()
        }
    }

    private func lost() {
        failWaiting(LinkError.notConnected)
        peripheral = nil
        writeCharacteristic = nil
        parser = SparkProtocol.Parser()
        activeSlot = nil
        tryingOut = nil
        // The amp ends the temporary preset when the connection ends.
        isEditingLive = false
        if central?.state == .poweredOn { status = wanted ? .searching : .off }
        scan()
    }
}

extension SparkLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { updateStatus(for: central.state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        MainActor.assumeIsolated {
            guard self.peripheral == nil else { return }
            central.stopScan()
            self.peripheral = peripheral
            deviceName = name.map { $0.replacingOccurrences(of: " BLE", with: "") }
            peripheral.delegate = self
            status = .connecting
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { lost() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { lost() }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            MainActor.assumeIsolated { central?.cancelPeripheralConnection(peripheral) }
            return
        }
        peripheral.discoverCharacteristics([Self.write, Self.notify], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let characteristics = service.characteristics ?? []
        MainActor.assumeIsolated {
            writeCharacteristic = characteristics.first { $0.uuid == Self.write }
            guard writeCharacteristic != nil, let notify = characteristics.first(where: { $0.uuid == Self.notify }) else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.setNotifyValue(true, for: notify)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if error == nil { connected() } else { central?.cancelPeripheralConnection(peripheral) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        MainActor.assumeIsolated { received(bytes) }
    }
}
