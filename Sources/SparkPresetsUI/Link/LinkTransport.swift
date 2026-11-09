import CoreBluetooth
import Foundation
import SparkControl

/// A device the Bluetooth search found: its identifier, the name it advertises and the control service it offers.
struct FoundDevice: Equatable {
    let id: UUID
    let name: String?
    /// "FFC0" for a Spark, "FFD0" for a REACTOR.
    let service: String
}

enum TransportState: Equatable {
    case unknown, poweredOn, unauthorized, poweredOff, unsupported
}

/// What `SparkLink` needs from Bluetooth. CoreBluetooth in the app; a simulated device in tests.
@MainActor
protocol LinkTransport: AnyObject {
    var delegate: LinkTransportDelegate? { get set }
    var state: TransportState { get }
    /// Starts Bluetooth. Before the first call nothing touches it, so the app asks for no Bluetooth access at launch.
    func powerUp()
    /// Looks for devices that offer one of `services`. Nothing else nearby is reported.
    func startSearch(services: [String])
    func stopSearch()
    /// Connects and opens the control channel: subscribes to FFC2, and on a Spark keeps FFC1 for writing. On a
    /// device whose profile may not send, `listenOnly` keeps no characteristic to write to at all.
    func connect(_ device: FoundDevice, listenOnly: Bool)
    func disconnect(_ id: UUID)
    /// Writes to the connected device. Each block goes on its own, split to the packet size.
    func write(_ blocks: [[UInt8]]) throws
}

@MainActor
protocol LinkTransportDelegate: AnyObject {
    func transport(changedState state: TransportState)
    func transport(found device: FoundDevice)
    /// The control channel is open: notifications are subscribed.
    func transport(connected id: UUID)
    func transport(lost id: UUID)
    func transport(received bytes: [UInt8])
}

/// The real Bluetooth LE transport.
@MainActor
final class CoreBluetoothTransport: NSObject, LinkTransport {
    weak var delegate: LinkTransportDelegate?
    private(set) var state = TransportState.unknown

    nonisolated(unsafe) private static let write = CBUUID(string: SparkProtocol.writeUUID)
    nonisolated(unsafe) private static let notify = CBUUID(string: SparkProtocol.notifyUUID)

    private var central: CBCentralManager?
    /// Every device found in this session, so it can be connected by its identifier.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connecting: (device: FoundDevice, listenOnly: Bool)?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    func powerUp() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    func startSearch(services: [String]) {
        guard let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: services.map { CBUUID(string: $0) }, options: nil)
    }

    func stopSearch() {
        central?.stopScan()
    }

    func connect(_ device: FoundDevice, listenOnly: Bool) {
        guard let central else { return }
        let known = peripherals[device.id] ?? central.retrievePeripherals(withIdentifiers: [device.id]).first
        guard let known else {
            delegate?.transport(lost: device.id)
            return
        }
        connecting = (device, listenOnly)
        peripheral = known
        writeCharacteristic = nil
        known.delegate = self
        central.connect(known)
    }

    func disconnect(_ id: UUID) {
        guard let peripheral = peripherals[id] ?? (self.peripheral?.identifier == id ? self.peripheral : nil) else { return }
        central?.cancelPeripheralConnection(peripheral)
    }

    func write(_ blocks: [[UInt8]]) throws {
        guard let peripheral, let characteristic = writeCharacteristic, connecting?.listenOnly == false else {
            throw LinkError.notConnected
        }
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

    private func ended(_ id: UUID) {
        if peripheral?.identifier == id {
            peripheral = nil
            writeCharacteristic = nil
            connecting = nil
        }
        delegate?.transport(lost: id)
    }
}

extension CoreBluetoothTransport: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state: TransportState = switch central.state {
        case .poweredOn: .poweredOn
        case .unauthorized: .unauthorized
        case .poweredOff: .poweredOff
        case .unsupported: .unsupported
        default: .unknown
        }
        MainActor.assumeIsolated {
            self.state = state
            delegate?.transport(changedState: state)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let isReactor = services.contains(CBUUID(string: DeviceProfile.reactorService))
        let device = FoundDevice(id: peripheral.identifier, name: name,
                                 service: isReactor ? DeviceProfile.reactorService : DeviceProfile.sparkService)
        MainActor.assumeIsolated {
            peripherals[peripheral.identifier] = peripheral
            delegate?.transport(found: device)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard let connecting, connecting.device.id == peripheral.identifier else { return }
            peripheral.discoverServices([CBUUID(string: connecting.device.service)])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { ended(peripheral.identifier) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { ended(peripheral.identifier) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let connecting, let service = peripheral.services?.first(where: {
                $0.uuid == CBUUID(string: connecting.device.service)
            }) else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            // A device that may not get any byte: only the notifications are looked for, nothing to write to.
            let wanted = connecting.listenOnly ? [Self.notify] : [Self.write, Self.notify]
            peripheral.discoverCharacteristics(wanted, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let characteristics = service.characteristics ?? []
        MainActor.assumeIsolated {
            guard let connecting else { return }
            writeCharacteristic = connecting.listenOnly ? nil : characteristics.first { $0.uuid == Self.write }
            guard connecting.listenOnly || writeCharacteristic != nil,
                  let notify = characteristics.first(where: { $0.uuid == Self.notify }) else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.setNotifyValue(true, for: notify)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if error == nil { delegate?.transport(connected: peripheral.identifier) }
            else { central?.cancelPeripheralConnection(peripheral) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        MainActor.assumeIsolated { delegate?.transport(received: bytes) }
    }
}
