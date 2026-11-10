import CoreBluetooth
import Foundation
import SparkControl

/// `spark-probe ask <firmware|name|slot|current> [seconds]`: connects to a Spark (FFC0) or a REACTOR (FFD0), sends
/// exactly one read request and prints every byte that comes back.
///
/// Made for a device nothing was ever sent to, such as the REACTOR: one run is one message, a request that reads
/// (command 02), never one that sets. Run it only with the owner's okay for that one request, with the device's
/// volume down. The message goes out once; nothing is repeated when no answer comes.
@MainActor
final class AskLink: NSObject {
    enum Question: String {
        case firmware, name, slot, current

        func message(header: Bool) -> [UInt8] {
            switch self {
            case .firmware: SparkProtocol.getFirmware(sequence: 1, header: header)
            case .name: SparkProtocol.getAmpName(sequence: 1, header: header)
            case .slot: SparkProtocol.getPresetNumber(sequence: 1, header: header)
            case .current: SparkProtocol.getPreset(slot: nil, sequence: 1, header: header)
            }
        }
    }

    /// What goes out, and what to call it in the log.
    private let message: [UInt8]
    private let label: String
    /// Where a preset answer (03 01) is written, when it is wanted.
    private var save: URL?
    private let seconds: Double
    private let header: Bool
    private let deviceFilter: String?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var service: CBUUID?
    private var write: CBCharacteristic?
    private var started: Date?
    private var hasSent = false
    private var receivedBytes = 0
    private let parser = SparkProtocol.Parser()
    private var done: CheckedContinuation<Void, Never>?
    private var failure: String?

    init(question: Question, seconds: Double, header: Bool, device: String?) {
        message = question.message(header: header)
        label = "read request (\(question.rawValue))"
        self.seconds = seconds
        self.header = header
        deviceFilter = device
    }

    /// `spark-probe switch-one <model> on|off`: one message that switches one effect (01 15). Same rules as `set-one`.
    init(model: String, on: Bool, seconds: Double, header: Bool, device: String?) {
        message = SparkProtocol.setEffect(model, on: on, sequence: 1, header: header)
        label = "effect switch (\(model) \(on ? "on" : "off"))"
        self.seconds = seconds
        self.header = header
        deviceFilter = device
    }

    /// `spark-probe send-one <sub> <payload bytes…>`: one set message (01 <sub>) with a payload given in hex. For
    /// trying a command that is only known from what the device reports. Same rules as `set-one`, and one try only.
    init(sub: UInt8, payload: [UInt8], seconds: Double, header: Bool, device: String?) {
        message = SparkProtocol.frame(command: SparkProtocol.Command.set, sub: sub, payload: payload, sequence: 1,
                                      header: header)
        label = String(format: "set message (01 %02X %@)", sub, payload.hex)
        self.seconds = seconds
        self.header = header
        deviceFilter = device
    }

    /// `spark-probe read-slot <0-7> <file>`: one read request for a stored slot (02 01 00 <slot>); the preset that comes
    /// back is written to the file as it came, for working out a device's own preset format. Reads only.
    init(slot: UInt8, save: URL, seconds: Double, header: Bool, device: String?) {
        message = SparkProtocol.getPreset(slot: slot, sequence: 1, header: header)
        label = "read request (slot \(slot))"
        self.save = save
        self.seconds = seconds
        self.header = header
        deviceFilter = device
    }

    /// `spark-probe set-one <block> <index> <value>`: one message that sets one parameter (01 04), 0 to 1. The first
    /// thing that changes a device nothing was written to before: only with the owner's okay for that one value,
    /// volume down, and never a volume or master parameter first.
    init(block: String, index: UInt8, value: Float, seconds: Double, header: Bool, device: String?) {
        message = SparkProtocol.setParameter(effect: block, index: index, value: value, sequence: 1, header: header)
        label = "parameter change (\(block) parameter \(index) = \(value))"
        self.seconds = seconds
        self.header = header
        deviceFilter = device
    }

    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            done = continuation
            central = CBCentralManager(delegate: self, queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.started == nil else { return }
                    self.finish("No device connected within 20 seconds. Nothing was sent.")
                }
            }
        }
        if let failure {
            log("✗ \(failure)")
            return false
        }
        log(receivedBytes == 0 ? "\nNothing came back. One message was sent."
                               : "\n\(receivedBytes) byte(s) came back. One message was sent.")
        return true
    }

    private func finish(_ failure: String? = nil) {
        self.failure = self.failure ?? failure
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        central.stopScan()
        done?.resume()
        done = nil
    }

    /// The one message of this run.
    private func sendOnce() {
        guard !hasSent, let peripheral, let write else { return }
        hasSent = true
        started = Date()
        let bytes = message
        log("Sending one \(label): \(bytes.hex)")
        peripheral.writeValue(Data(bytes), for: write, type: .withoutResponse)
        log("Listening for \(Int(seconds)) seconds.\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func received(_ bytes: [UInt8]) {
        let time = started.map { Date().timeIntervalSince($0) } ?? -1
        receivedBytes += bytes.count
        if save == nil { log(String(format: "%6.2f s  received ", time) + bytes.hex) }
        for message in parser.feed(bytes) {
            let head = String(format: "%02X %02X", message.command, message.sub)
            let event = SparkEvent(message).map { " \($0)" } ?? ""
            if let save, message.command == SparkProtocol.Command.response, message.sub == SparkProtocol.Sub.preset {
                do {
                    try Data(message.payload).write(to: save, options: .atomic)
                    log("          preset of \(message.payload.count) bytes written to \(save.lastPathComponent)")
                } catch {
                    log("          could not write \(save.lastPathComponent)")
                }
                continue
            }
            log("          message \(head) \(message.payload.hex)\(event)\(message.checksumOK ? "" : " (checksum!)")")
        }
    }
}

extension AskLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                log("Looking for Spark (FFC0) and REACTOR (FFD0) devices …")
                central.scanForPeripherals(withServices: DeviceProfile.searchedServices.map { CBUUID(string: $0) })
            case .unauthorized: finish("Bluetooth access was denied.")
            case .poweredOff: finish("Bluetooth is off.")
            case .unsupported: finish("This Mac has no Bluetooth LE.")
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
        let reactor = CBUUID(string: DeviceProfile.reactorService)
        MainActor.assumeIsolated {
            guard self.peripheral == nil else { return }
            if let deviceFilter, !name.localizedCaseInsensitiveContains(deviceFilter) { return }
            let uuid = services.contains(reactor) ? reactor : CBUUID(string: DeviceProfile.sparkService)
            let profile = DeviceProfile.forAdvertisement(service: uuid.uuidString, name: name)
            log("Found \"\(DeviceProfile.loggableName(name))\", service \(uuid.uuidString), profile \(profile.displayName).")
            central.stopScan()
            service = uuid
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard let service else { return }
            peripheral.discoverServices([service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { finish("Connection failed. Nothing was sent.") }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard done != nil else { return }
            if hasSent { log("The device ended the connection.") }
            finish(hasSent ? nil : "Disconnected before anything was sent.")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let control = peripheral.services?.first(where: { $0.uuid == service }) else {
                finish("The control service is missing. Nothing was sent.")
                return
            }
            peripheral.discoverCharacteristics([CBUUID(string: SparkProtocol.writeUUID),
                                                CBUUID(string: SparkProtocol.notifyUUID)], for: control)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            let all = service.characteristics ?? []
            guard let notify = all.first(where: { $0.uuid == CBUUID(string: SparkProtocol.notifyUUID) }),
                  let write = all.first(where: { $0.uuid == CBUUID(string: SparkProtocol.writeUUID) }) else {
                finish("FFC1 or FFC2 is missing. Nothing was sent.")
                return
            }
            self.write = write
            peripheral.setNotifyValue(true, for: notify)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if error != nil { finish("Could not subscribe to FFC2. Nothing was sent.") } else { sendOnce() }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        MainActor.assumeIsolated { received(bytes) }
    }
}
