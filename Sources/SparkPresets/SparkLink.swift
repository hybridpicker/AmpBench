import CoreBluetooth
import Foundation
import SparkControl

enum LinkError: LocalizedError {
    case notConnected
    case noAnswer
    case unreadable(String)
    case verifyFailed(String)

    var errorDescription: String? {
        switch self {
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
        case starting, unauthorized, bluetoothOff, unsupported, searching, connecting, connected
    }

    @Published private(set) var status = Status.starting
    @Published private(set) var deviceName: String?
    @Published private(set) var firmware: String?
    /// The stored preset playing, 0 to 3. Nil while unknown or while a preset is tried out.
    @Published private(set) var activeSlot: Int?
    /// The name of a preset that plays without being stored.
    @Published private(set) var tryingOut: String?
    @Published private(set) var slots: [SparkPreset?] = Array(repeating: nil, count: 4)
    /// What the link is doing, for the status line.
    @Published private(set) var activity: String?
    /// Something the amp did by itself, such as a press of its preset button.
    var onAmpEvent: ((String) -> Void)?

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
    private var waiting: (sub: UInt8, command: UInt8, token: Int, continuation: CheckedContinuation<SparkProtocol.Message, Error>)?
    private var token = 0
    private var queue: Task<Void, Never>?
    private var wanted = false

    func start() {
        wanted = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            scan()
        }
    }

    func stop() {
        wanted = false
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
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
                return try await once(build, sub: sub, command: command)
            } catch LinkError.noAnswer {
                return try await once(build, sub: sub, command: command)
            }
        }
    }

    private func once(_ build: (UInt8) -> [[UInt8]], sub: UInt8, command: UInt8) async throws -> SparkProtocol.Message {
        try await Task.sleep(for: Self.gap)
        guard status == .connected, let peripheral, let characteristic = writeCharacteristic else {
            throw LinkError.notConnected
        }
        sequence = (sequence + 1) & 0x7F
        let size = max(peripheral.maximumWriteValueLength(for: .withoutResponse), 20)
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        return try await withCheckedThrowingContinuation { continuation in
            waiting = (sub, command, 0, continuation)
            armTimeout()
            // A write longer than one Bluetooth packet is refused, so every block goes on its own.
            for block in build(sequence) {
                for start in stride(from: 0, to: block.count, by: size) {
                    peripheral.writeValue(Data(block[start..<min(start + size, block.count)]), for: characteristic,
                                          type: type)
                }
            }
        }
    }

    private func armTimeout() {
        guard let current = waiting else { return }
        token += 1
        let mine = token
        waiting = (current.sub, current.command, mine, current.continuation)
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

    private func readPreset(_ place: SparkPresetPlace) async throws -> SparkPreset {
        let slot: UInt8? = if case .slot(let slot) = place { slot } else { nil }
        let message = try await request({ [SparkProtocol.getPreset(slot: slot, sequence: $0)] },
                                        answer: SparkProtocol.Sub.preset)
        do {
            return try SparkPreset(payload: message.payload)
        } catch {
            throw LinkError.unreadable("\(error)")
        }
    }

    private func switchTo(_ slot: UInt8) async throws {
        _ = try await request({ [SparkProtocol.changeHardwarePreset(slot: slot, sequence: $0)] },
                              answer: SparkProtocol.Sub.hardwarePreset, command: SparkProtocol.Command.acknowledge)
    }

    private func send(_ preset: SparkPreset, to place: SparkPresetPlace) async throws {
        _ = try await request({ SparkProtocol.sendPreset(preset, to: place, sequence: $0) },
                              answer: SparkProtocol.Sub.preset, command: SparkProtocol.Command.acknowledge)
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
    }

    /// Plays a preset without storing it. Switching to any slot ends it.
    func tryOut(_ preset: SparkPreset) async throws {
        activity = "Sende „\(preset.name)“ …"
        defer { activity = nil }
        try await send(preset, to: .temporary)
        try await switchTo(0x7F)
        tryingOut = preset.name
        activeSlot = nil
    }

    /// Stores a preset in a slot, switches to it and reads it back to make sure it arrived unchanged.
    func store(_ preset: SparkPreset, in slot: Int) async throws {
        activity = "Speichere „\(preset.name)“ auf Platz \(slot + 1) …"
        defer { activity = nil }
        try await send(preset, to: .slot(UInt8(slot)))
        try await switchTo(UInt8(slot))
        activeSlot = slot
        tryingOut = nil
        activity = "Prüfe Platz \(slot + 1) …"
        let stored = try await readPreset(.slot(UInt8(slot)))
        slots[slot] = stored
        guard stored == preset else { throw LinkError.verifyFailed(preset.name) }
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
        for message in parser.feed(bytes) {
            if let waiting, waiting.sub == message.sub, waiting.command == message.command {
                self.waiting = nil
                waiting.continuation.resume(returning: message)
                continue
            }
            // The amp's own preset button.
            if message.command == SparkProtocol.Command.response, message.sub == SparkProtocol.Sub.hardwarePreset,
               let slot = SparkValues.slot(message.payload), slot < 4 {
                activeSlot = Int(slot)
                tryingOut = nil
                let name = slots[Int(slot)].map { " „\($0.name)“" } ?? ""
                onAmpEvent?("Am Verstärker gewählt: Platz \(slot + 1)\(name)")
            }
        }
    }

    private func connected() {
        status = .connected
        Task { await loadAll() }
    }

    private func lost() {
        failWaiting(LinkError.notConnected)
        peripheral = nil
        writeCharacteristic = nil
        parser = SparkProtocol.Parser()
        activeSlot = nil
        tryingOut = nil
        if central?.state == .poweredOn { status = .searching }
        scan()
    }
}

extension SparkLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: scan()
            case .unauthorized: status = .unauthorized
            case .poweredOff: status = .bluetoothOff
            case .unsupported: status = .unsupported
            default: break
            }
        }
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
