import CoreBluetooth
import Foundation
import SparkControl

/// `spark-probe script <file>`: connects to a Spark (FFC0) or a REACTOR (FFD0) once and sends the messages of a
/// script one after the other, printing every message that comes back. For working out a device's commands with its
/// owner's okay for the whole script, volume down. One step per line:
///
///     msg <command> <sub> <seconds> [payload bytes in hex]   one framed message
///     effect <model> on|off <seconds>                         01 15
///     param <model> <index> <0-1> <seconds>                   01 04
///     slot <0-7> <seconds>                                    01 38 00 <slot>
///     current <seconds> | read <slot> <seconds>               02 01, the preset that plays or a stored one
///     raw <seconds> <bytes in hex>                            bytes as they are, one Bluetooth write
///     wait <seconds>                                          sends nothing and prints what the device reports
///     # text                                                  printed as it is
///
/// A step ends when something came back and 0.25 s passed without more, or after its seconds.
@MainActor
final class ScriptLink: NSObject {
    private let lines: [String]
    private let header: Bool
    private let deviceFilter: String?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var service: CBUUID?
    private var write: CBCharacteristic?
    private let parser = SparkProtocol.Parser()
    private var done: CheckedContinuation<Void, Never>?
    private var failure: String?
    private var sequence: UInt8 = 0
    private var lastReceived: Date?
    private var running = false

    init(lines: [String], header: Bool, device: String?) {
        self.lines = lines
        self.header = header
        deviceFilter = device
    }

    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            done = continuation
            central = CBCentralManager(delegate: self, queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.running else { return }
                    self.finish("No device connected within 20 seconds. Nothing was sent.")
                }
            }
        }
        if let failure {
            log("✗ \(failure)")
            return false
        }
        return true
    }

    private func finish(_ failure: String? = nil) {
        self.failure = self.failure ?? failure
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        central.stopScan()
        done?.resume()
        done = nil
    }

    private func bytes(_ words: ArraySlice<String>) -> [UInt8]? {
        let all = words.map { UInt8($0, radix: 16) }
        return all.contains(nil) ? nil : all.map { $0! }
    }

    /// The bytes of one step and how long to wait for answers; nil for a line that is not understood.
    private func step(_ line: String) -> (bytes: [UInt8], seconds: Double)? {
        let words = line.split(separator: " ").map(String.init)
        sequence = (sequence + 1) & 0x7F
        switch words.first {
        case "msg":
            guard words.count >= 4, let command = UInt8(words[1], radix: 16), let sub = UInt8(words[2], radix: 16),
                  let seconds = Double(words[3]), let payload = bytes(words.dropFirst(4)) else { return nil }
            return (SparkProtocol.frame(command: command, sub: sub, payload: payload, sequence: sequence,
                                        header: header), seconds)
        case "effect":
            guard words.count == 4, ["on", "off"].contains(words[2]), let seconds = Double(words[3]) else { return nil }
            return (SparkProtocol.setEffect(words[1], on: words[2] == "on", sequence: sequence, header: header), seconds)
        case "param":
            guard words.count == 5, let index = UInt8(words[2]), let value = Float(words[3]), (0...1).contains(value),
                  let seconds = Double(words[4]) else { return nil }
            return (SparkProtocol.setParameter(effect: words[1], index: index, value: value, sequence: sequence,
                                               header: header), seconds)
        case "slot":
            guard words.count == 3, let slot = UInt8(words[1]), slot < 8, let seconds = Double(words[2]) else { return nil }
            return (SparkProtocol.changeHardwarePreset(slot: slot, sequence: sequence, header: header), seconds)
        case "current":
            guard words.count == 2, let seconds = Double(words[1]) else { return nil }
            return (SparkProtocol.getPreset(slot: nil, sequence: sequence, header: header), seconds)
        case "read":
            guard words.count == 3, let slot = UInt8(words[1]), slot < 8, let seconds = Double(words[2]) else { return nil }
            return (SparkProtocol.getPreset(slot: slot, sequence: sequence, header: header), seconds)
        case "wait":
            guard words.count == 2, let seconds = Double(words[1]) else { return nil }
            return ([], seconds)
        case "raw":
            guard words.count >= 3, let seconds = Double(words[1]), let raw = bytes(words.dropFirst(2)) else { return nil }
            return (raw, seconds)
        default:
            return nil
        }
    }

    private func play() async {
        running = true
        if let peripheral { log("# largest write \(peripheral.maximumWriteValueLength(for: .withoutResponse)) bytes") }
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if text.hasPrefix("#") {
                log(text)
                continue
            }
            guard let step = step(text) else {
                finish("Not understood, stopped: \(text)")
                return
            }
            guard let peripheral, let write, done != nil else { return }
            log("> \(text)")
            lastReceived = nil
            let start = Date()
            // A write longer than one Bluetooth packet is refused, so long steps go out in pieces.
            let size = max(peripheral.maximumWriteValueLength(for: .withoutResponse), 20)
            for from in stride(from: 0, to: step.bytes.count, by: size) {
                peripheral.writeValue(Data(step.bytes[from..<min(from + size, step.bytes.count)]), for: write,
                                      type: .withoutResponse)
            }
            while Date().timeIntervalSince(start) < step.seconds {
                try? await Task.sleep(for: .milliseconds(50))
                if !step.bytes.isEmpty, let lastReceived, Date().timeIntervalSince(lastReceived) > 0.25,
                   !parser.isInsideChunk { break }
            }
        }
        finish()
    }

    private func received(_ bytes: [UInt8]) {
        lastReceived = Date()
        for message in parser.feed(bytes) {
            log(String(format: "< %02X %02X ", message.command, message.sub) + message.payload.hex
                + (message.checksumOK ? "" : " (checksum!)"))
        }
    }
}

extension ScriptLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
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
            log("# found \"\(DeviceProfile.loggableName(name))\", service \(uuid.uuidString)")
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
            finish("The device ended the connection.")
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
            if error != nil { finish("Could not subscribe to FFC2. Nothing was sent.") } else if !running { Task { await play() } }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        MainActor.assumeIsolated { received(bytes) }
    }
}
