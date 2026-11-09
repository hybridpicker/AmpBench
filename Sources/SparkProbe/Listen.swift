import CoreBluetooth
import Foundation
import SparkControl

/// `spark-probe listen <seconds>`: connects to a Spark (FFC0) or a REACTOR (FFD0), subscribes to FFC2 and only listens.
///
/// This type has no code that writes to a characteristic: it never looks for FFC1 and never calls `writeValue`. The
/// only thing that goes to the device is the subscription to FFC2, which Bluetooth itself sends. At the end it sums up
/// what came: per parameter the count, range, first and last value; other messages with their times. A REACTOR's name
/// is printed without the part its owner chose.
@MainActor
final class ListenLink: NSObject {
    private let seconds: Double
    private let deviceFilter: String?
    private let raw: Bool
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var service: CBUUID?
    private var ignored = 0
    private var started: Date?
    private let parser = SparkProtocol.Parser()
    private var done: CheckedContinuation<Void, Never>?
    private var failure: String?

    private struct Series {
        var count = 0
        var low = Float.infinity
        var high = -Float.infinity
        var first: Float = 0
        var last: Float = 0
    }

    private var series: [String: Series] = [:]
    private var order: [String] = []
    private var others: [(Double, String)] = []

    init(seconds: Double, device: String?, raw: Bool) {
        self.seconds = seconds
        deviceFilter = device
        self.raw = raw
    }

    /// Returns false when nothing could be listened to.
    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            done = continuation
            central = CBCentralManager(delegate: self, queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.started == nil else { return }
                    self.finish("No Spark or REACTOR connected within 20 seconds. Is it on, and is every other app "
                                + "(Spark Studio, the Spark or REACTOR app on the phone) disconnected?")
                }
            }
        }
        if let failure {
            log("✗ \(failure)")
            return false
        }
        summarize()
        return true
    }

    private func finish(_ failure: String? = nil) {
        self.failure = self.failure ?? failure
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        central.stopScan()
        done?.resume()
        done = nil
    }

    private func startListening() {
        started = Date()
        log("Listening for \(Int(seconds)) seconds. Nothing is sent. Use the device's controls now.\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func received(_ bytes: [UInt8]) {
        if raw { log("  received \(bytes.hex)") }
        let time = started.map { Date().timeIntervalSince($0) } ?? 0
        for message in parser.feed(bytes) {
            let event = message.command == SparkProtocol.Command.response ? SparkEvent(message) : nil
            if case .parameter(let name, let index, let value) = event, message.sub == SparkProtocol.Sub.parameterChanged {
                let key = "03 37 \(name) parameter \(index)"
                if series[key] == nil { order.append(key) }
                var entry = series[key] ?? Series(first: value)
                entry.count += 1
                entry.low = min(entry.low, value)
                entry.high = max(entry.high, value)
                entry.last = value
                series[key] = entry
            } else if case .tuner(_, let offset) = event {
                let key = "03 64 tuner reading"
                let value = offset ?? -1
                if series[key] == nil { order.append(key) }
                var entry = series[key] ?? Series(first: value)
                entry.count += 1
                entry.low = min(entry.low, value)
                entry.high = max(entry.high, value)
                entry.last = value
                series[key] = entry
            } else {
                let head = String(format: "%02X %02X", message.command, message.sub)
                let event = SparkEvent(message).map { " \($0)" } ?? ""
                others.append((time, "\(head) \(message.payload.hex)\(event)\(message.checksumOK ? "" : " (checksum!)")"))
            }
        }
    }

    private func summarize() {
        log("\n\(ignored) other Bluetooth device(s) nearby, not shown.")
        if series.isEmpty && others.isEmpty {
            log("Nothing came. The capture runs only while the window is open; start the controls after the line "
                + "\"Listening …\".")
            return
        }
        for key in order {
            guard let entry = series[key] else { continue }
            log(String(format: "%@: %d×, %.3f to %.3f, first %.3f, last %.3f", key, entry.count, entry.low, entry.high,
                       entry.first, entry.last))
        }
        for (time, text) in others { log(String(format: "%6.2f s  ", time) + text) }
    }
}

extension ListenLink: CBCentralManagerDelegate, CBPeripheralDelegate {
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
            if let deviceFilter, !name.localizedCaseInsensitiveContains(deviceFilter) {
                ignored += 1
                return
            }
            let uuid = services.contains(reactor) ? reactor : CBUUID(string: DeviceProfile.sparkService)
            let profile = DeviceProfile.forAdvertisement(service: uuid.uuidString, name: name)
            log("Found \"\(DeviceProfile.loggableName(name))\", service \(uuid.uuidString), profile \(profile.displayName). "
                + "Connecting to listen …")
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
        MainActor.assumeIsolated { finish("Connection failed.") }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            if done != nil { finish(started == nil ? "Disconnected before listening." : nil) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let control = peripheral.services?.first(where: { $0.uuid == service }) else {
                finish("The control service is missing.")
                return
            }
            // Only the notifications. The characteristic to write to is not even looked for.
            peripheral.discoverCharacteristics([CBUUID(string: SparkProtocol.notifyUUID)], for: control)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let notify = service.characteristics?.first(where: {
                $0.uuid == CBUUID(string: SparkProtocol.notifyUUID)
            }) else {
                finish("FFC2 is missing.")
                return
            }
            peripheral.setNotifyValue(true, for: notify)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if error != nil { finish("Could not subscribe to FFC2.") } else { startListening() }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        MainActor.assumeIsolated { received(bytes) }
    }
}
