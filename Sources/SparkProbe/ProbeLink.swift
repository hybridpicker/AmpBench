import CoreBluetooth
import Foundation
import SparkControl

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ text: String) {
    print(text)
    fflush(stdout)
}

/// The probe's Bluetooth LE connection. It only shows and connects to devices with "Spark" in their name, other
/// devices nearby are only counted. Requests run one at a time, like in Spark Presets.
@MainActor
final class ProbeLink: NSObject {
    let raw: Bool
    let header: Bool
    /// Part of the name of the device to use when several are found. Nil: the first one.
    let deviceFilter: String?
    /// The amp sometimes ignores a request that follows the previous answer right away.
    static let gap: Duration = .milliseconds(150)
    /// Waiting ends when the amp stays silent this long. A preset takes several seconds, but data keeps coming.
    static let silence = 3.0

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var servicesLeft = 0
    private var listServices = false
    private var seen: [UUID: String] = [:]
    private var ignored = Set<UUID>()
    private var scanOnly = false
    private var ready: CheckedContinuation<Void, Error>?
    private let parser = SparkProtocol.Parser()
    private var sequence: UInt8 = 0
    private var waiting: (sub: UInt8, command: UInt8?, token: Int, continuation: CheckedContinuation<SparkProtocol.Message, Error>)?
    private var token = 0
    /// Messages nobody waits for, printed as they come. `listen` collects them as well.
    private var collected: [SparkProtocol.Message]?
    private(set) var hiddenTuner = 0
    /// Every tuner reading (`03 64`): the note byte and the value, nil without a signal. Kept for `tuner`.
    private(set) var tunerReadings: [(note: UInt8, value: Float?)] = []
    /// Called with every tuner reading as it comes.
    var onTunerReading: ((UInt8, Float?) -> Void)?

    init(raw: Bool, header: Bool, device: String? = nil) {
        self.raw = raw
        self.header = header
        deviceFilter = device
        super.init()
    }

    // MARK: Connecting

    /// Scans for 10 seconds and lists the Spark amps found, without connecting.
    func scan() async -> Bool {
        scanOnly = true
        try? await start()
        try? await Task.sleep(for: .seconds(10))
        central.stopScan()
        log("\(ignored.count) other Bluetooth device(s) nearby, not shown.")
        if seen.isEmpty { log("No Spark found. Is it switched on, and is the Spark app on the phone disconnected?") }
        return !seen.isEmpty
    }

    /// Connects to the first Spark found and opens the control channel.
    func connect(listServices: Bool = false) async throws {
        self.listServices = listServices
        try await start()
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready = continuation
            central = CBCentralManager(delegate: self, queue: .main)
            guard !scanOnly else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                MainActor.assumeIsolated {
                    self?.fail(ProbeFailure("No connection within 15 seconds. Is the amp on, and are the Spark app "
                                            + "on the phone and Spark Presets disconnected?"))
                }
            }
        }
    }

    private func fail(_ error: Error) {
        ready?.resume(throwing: error)
        ready = nil
    }

    func disconnect() async {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        try? await Task.sleep(for: .milliseconds(500))
    }

    // MARK: Requests

    /// Sends a message and waits for the answer `sub`. `command` nil accepts a response or an acknowledgement.
    /// Asks a second time when the amp stays silent.
    func request(_ label: String, answer sub: UInt8, command: UInt8? = nil,
                 _ build: (UInt8) -> [[UInt8]]) async throws -> SparkProtocol.Message {
        for attempt in 1...2 {
            log(attempt == 1 ? "→ \(label)" : "→ \(label), attempt 2")
            do {
                return try await once(build, sub: sub, command: command)
            } catch let failure as ProbeFailure where failure.description == "silent" {
                log("  no answer within \(Int(Self.silence)) seconds")
            }
        }
        throw ProbeFailure("The amp did not answer “\(label)”.")
    }

    /// Sends a message that gets no answer, then keeps the usual gap.
    func send(_ label: String, _ build: (UInt8) -> [[UInt8]]) async throws {
        log("→ \(label)")
        try await Task.sleep(for: Self.gap)
        try write(build(nextSequence()))
    }

    /// Sends a message at once, without the gap, for measuring how fast the amp takes messages.
    func sendNow(_ build: (UInt8) -> [UInt8]) throws {
        try write([build(nextSequence())])
    }

    /// Collects and prints whatever the amp sends during `seconds`.
    @discardableResult
    func listen(_ seconds: Double) async -> [SparkProtocol.Message] {
        collected = []
        try? await Task.sleep(for: .seconds(seconds))
        defer { collected = nil }
        return collected ?? []
    }

    private func once(_ build: (UInt8) -> [[UInt8]], sub: UInt8, command: UInt8?) async throws -> SparkProtocol.Message {
        try await Task.sleep(for: Self.gap)
        let blocks = build(nextSequence())
        return try await withCheckedThrowingContinuation { continuation in
            waiting = (sub, command, 0, continuation)
            armTimeout()
            do {
                try write(blocks)
            } catch {
                waiting = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func nextSequence() -> UInt8 {
        // Some community code reports trouble with sequence 0, so it is skipped.
        sequence = sequence >= 0x7F ? 1 : sequence + 1
        return sequence
    }

    /// Writes every block on its own. A write longer than one Bluetooth packet is refused by the amp, so a block
    /// that does not fit one packet is split further.
    private func write(_ blocks: [[UInt8]]) throws {
        guard let peripheral, let characteristic = writeCharacteristic else { throw ProbeFailure("Not connected.") }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let size = max(peripheral.maximumWriteValueLength(for: .withoutResponse), 20)
        for block in blocks {
            if raw { log("  sent \(block.hex)") }
            for start in stride(from: 0, to: block.count, by: size) {
                peripheral.writeValue(Data(block[start..<min(start + size, block.count)]), for: characteristic, type: type)
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
                waiting.continuation.resume(throwing: ProbeFailure("silent"))
            }
        }
    }

    // MARK: Incoming

    private func received(_ bytes: [UInt8]) {
        if raw { log("  received \(bytes.hex)") }
        let messages = parser.feed(bytes)
        // The tuner's readings come many times a second and must not keep a wait alive forever.
        if parser.isInsideChunk || messages.contains(where: { $0.sub != SparkProtocol.Sub.tunerPitch }) {
            armTimeout()
        }
        for message in messages {
            if message.sub == SparkProtocol.Sub.tunerPitch, case .tuner(let note, let value)? = SparkEvent(message) {
                tunerReadings.append((note, value))
                onTunerReading?(note, value)
            }
            if message.sub == SparkProtocol.Sub.tunerPitch, !raw {
                hiddenTuner += 1
                continue
            }
            if let waiting, waiting.sub == message.sub,
               waiting.command.map({ $0 == message.command })
                ?? (message.command == SparkProtocol.Command.response
                    || message.command == SparkProtocol.Command.acknowledge) {
                self.waiting = nil
                report(message)
                waiting.continuation.resume(returning: message)
                continue
            }
            report(message)
            collected?.append(message)
        }
    }
}

extension ProbeLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                log("Scanning for Spark amps …")
                central.scanForPeripherals(withServices: nil, options: nil)
                if scanOnly { ready?.resume(); ready = nil }
            case .unauthorized:
                fail(ProbeFailure("Bluetooth access was denied. Allow it under System Settings → Privacy & Security → "
                                  + "Bluetooth for the app that runs this terminal."))
            case .poweredOff: fail(ProbeFailure("Bluetooth is off."))
            case .unsupported: fail(ProbeFailure("This Mac has no Bluetooth LE."))
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString).joined(separator: ", ") ?? "none"
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? Bool).map { $0 ? "yes" : "no" }
            ?? "unknown"
        MainActor.assumeIsolated {
            guard name.localizedCaseInsensitiveContains("spark") else {
                ignored.insert(peripheral.identifier)
                return
            }
            guard seen[peripheral.identifier] == nil else { return }
            seen[peripheral.identifier] = name
            let isReactor = services.contains(DeviceProfile.reactorService)
            let profile = DeviceProfile.forAdvertisement(service: isReactor ? DeviceProfile.reactorService
                                                                            : DeviceProfile.sparkService, name: name)
            let checked = profile.checkedFirmware.map { "checked with firmware \($0)" } ?? "not checked"
            log("Found \"\(DeviceProfile.loggableName(name))\", signal \(RSSI) dBm, advertised services: \(services), "
                + "connectable: \(connectable), profile: \(profile.displayName) (\(checked))")
            // Nothing that may not get a byte is ever connected here; `listen` is the only way to a REACTOR.
            guard profile.canSend else {
                log("  not connected: its profile may not get anything. Use `listen`.")
                return
            }
            if let deviceFilter, !name.localizedCaseInsensitiveContains(deviceFilter) {
                log("  not chosen: --device \(deviceFilter)")
                return
            }
            guard !scanOnly, self.peripheral == nil else { return }
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            log("Connecting …")
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            fail(ProbeFailure("Connection failed: \(error?.localizedDescription ?? "unknown reason")"))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ".")")
            if let waiting {
                self.waiting = nil
                waiting.continuation.resume(throwing: ProbeFailure("The connection was lost."))
            }
            writeCharacteristic = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        MainActor.assumeIsolated {
            servicesLeft = services.count
            if services.isEmpty { setUpControl() }
        }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let characteristics = service.characteristics ?? []
        MainActor.assumeIsolated {
            if listServices { log("  service \(service.uuid.uuidString)") }
            for characteristic in characteristics {
                if listServices {
                    log("    characteristic \(characteristic.uuid.uuidString): \(describe(characteristic.properties))")
                }
                guard service.uuid == CBUUID(string: SparkProtocol.serviceUUID) else { continue }
                if characteristic.uuid == CBUUID(string: SparkProtocol.writeUUID) { writeCharacteristic = characteristic }
                if characteristic.uuid == CBUUID(string: SparkProtocol.notifyUUID) { notifyCharacteristic = characteristic }
            }
            servicesLeft -= 1
            if servicesLeft == 0 { setUpControl() }
        }
    }

    private func describe(_ properties: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [
            (.read, "read"), (.write, "write"), (.writeWithoutResponse, "write without response"),
            (.notify, "notify"), (.indicate, "indicate"),
        ]
        return names.filter { properties.contains($0.0) }.map(\.1).joined(separator: ", ")
    }

    private func setUpControl() {
        guard let peripheral, let notifyCharacteristic, writeCharacteristic != nil else {
            fail(ProbeFailure("The control service \(SparkProtocol.serviceUUID) with \(SparkProtocol.writeUUID) and "
                              + "\(SparkProtocol.notifyUUID) is missing."))
            return
        }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                fail(ProbeFailure("Could not subscribe to \(characteristic.uuid.uuidString): \(error.localizedDescription)"))
            } else {
                log("Control channel open.\n")
                ready?.resume()
                ready = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        if let error { log("  write failed: \(error.localizedDescription)") }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        MainActor.assumeIsolated { received(bytes) }
    }
}
