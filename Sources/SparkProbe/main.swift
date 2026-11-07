import CoreBluetooth
import Foundation
import SparkControl

// spark-probe: an experimental test tool for the Spark's Bluetooth LE control channel.
//
// It only shows and connects to devices with "Spark" in their name. Other Bluetooth devices nearby are counted but
// never printed. Nothing leaves this Mac.

let usage = """
    usage: spark-probe <command> [options]

    commands:
      scan            look for Spark amps for 10 seconds
      info            connect, list services, read firmware, name and the presets
      preset <1-4>    switch to a stored preset, like the preset button on the amp
      try <1-4>       send a copy of a stored preset, renamed, to play without storing it
      store-test <1-4> <backup.json>
                      back up a stored preset, store a renamed copy in its slot, read it back, then put the
                      original back and check it is byte for byte the same
      watch [secs]    connect and print what the amp sends, default 30 seconds

    options:
      --raw           also print every byte sent and received
      --no-header     send messages without the 16-byte block header

    The Spark app on the phone must be disconnected, the amp accepts only one control connection.
    """

enum Mode {
    case scan, info, watch(TimeInterval), preset(UInt8), audition(UInt8), storeTest(UInt8, String)
}

struct Options {
    var mode: Mode
    var raw = false
    var header = true
}

func parseOptions() -> Options {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var raw = false, header = true
    arguments.removeAll { argument in
        switch argument {
        case "--raw": raw = true; return true
        case "--no-header": header = false; return true
        default: return false
        }
    }
    let mode: Mode
    switch (arguments.first, arguments.dropFirst().first) {
    case ("scan", nil): mode = .scan
    case ("info", nil): mode = .info
    case ("watch", nil): mode = .watch(30)
    case ("watch", let seconds?) where TimeInterval(seconds).map({ $0 > 0 }) == true:
        mode = .watch(TimeInterval(seconds)!)
    case ("preset", let number?) where UInt8(number).map({ (1...4).contains($0) }) == true:
        mode = .preset(UInt8(number)! - 1)
    case ("store-test", let number?) where UInt8(number).map({ (1...4).contains($0) }) == true
        && arguments.count == 3:
        mode = .storeTest(UInt8(number)! - 1, arguments[2])
    case ("try", let number?) where UInt8(number).map({ (1...4).contains($0) }) == true:
        mode = .audition(UInt8(number)! - 1)
    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(64)
    }
    return Options(mode: mode, raw: raw, header: header)
}

func log(_ text: String) {
    print(text)
    fflush(stdout)
}

func finish(_ code: Int32, after delay: TimeInterval = 0.3) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { exit(code) }
}

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private struct Step {
        var label: String
        var build: (UInt8) -> [[UInt8]]
        var answer: UInt8
        /// The command of the answer, or nil for a response or an acknowledgement.
        var answerCommand: UInt8? = nil
        var attempt = 1
    }

    private let options: Options
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var servicesLeft = 0
    private var seen: [UUID: String] = [:]
    private var ignored = Set<UUID>()
    private let parser = SparkProtocol.Parser()
    private var steps: [Step] = []
    private var waitingFor: (sub: UInt8, command: UInt8?, token: Int)?
    private var auditionName: String?
    private var original: (preset: SparkPreset, payload: [UInt8])?
    private var storeStage = 0
    private var token = 0
    private var sequence: UInt8 = 0
    private var hiddenStatus = 0
    private var currentStep: Step?

    init(options: Options) {
        self.options = options
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Scanning and connecting

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("Scanning for Spark amps …")
            central.scanForPeripherals(withServices: nil, options: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in scanEnded() }
        case .unauthorized:
            log("Bluetooth access was denied. Allow it under System Settings → Privacy & Security → Bluetooth for "
                + "the app that runs this terminal.")
            finish(2)
        case .poweredOff:
            log("Bluetooth is off.")
            finish(2)
        case .unsupported:
            log("This Mac has no Bluetooth LE.")
            finish(2)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.localizedCaseInsensitiveContains("spark") else {
            ignored.insert(peripheral.identifier)
            return
        }
        guard seen[peripheral.identifier] == nil else { return }
        seen[peripheral.identifier] = name
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString).joined(separator: ", ") ?? "none"
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? Bool).map { $0 ? "yes" : "no" }
            ?? "unknown"
        log("Found \"\(name)\", signal \(RSSI) dBm, advertised services: \(services), connectable: \(connectable)")

        if case .scan = options.mode { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        log("Connecting …")
        central.connect(peripheral)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            guard writeCharacteristic == nil else { return }
            log("No connection within 10 seconds. Is the Spark app on the phone still connected?")
            finish(1)
        }
    }

    private func scanEnded() {
        guard central.isScanning else { return }
        central.stopScan()
        log("\(ignored.count) other Bluetooth device(s) nearby, not shown.")
        if seen.isEmpty {
            log("No Spark found. Is it switched on, and is the Spark app on the phone disconnected?")
            finish(1)
        } else {
            finish(0)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected. Looking at its services …")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Connection failed: \(error?.localizedDescription ?? "unknown reason")")
        finish(1)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ".")")
        finish(error == nil ? 0 : 1)
    }

    // MARK: Services

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        if let error { log("Service discovery failed: \(error.localizedDescription)") }
        servicesLeft = services.count
        if services.isEmpty { setUpControl() }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        log("  service \(service.uuid.uuidString)")
        for characteristic in service.characteristics ?? [] {
            log("    characteristic \(characteristic.uuid.uuidString): \(describe(characteristic.properties))")
            guard service.uuid == CBUUID(string: SparkProtocol.serviceUUID) else { continue }
            if characteristic.uuid == CBUUID(string: SparkProtocol.writeUUID) { writeCharacteristic = characteristic }
            if characteristic.uuid == CBUUID(string: SparkProtocol.notifyUUID) { notifyCharacteristic = characteristic }
        }
        servicesLeft -= 1
        if servicesLeft == 0 { setUpControl() }
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
            log("The control service \(SparkProtocol.serviceUUID) with \(SparkProtocol.writeUUID) and "
                + "\(SparkProtocol.notifyUUID) is missing. The list above shows what the amp offers instead.")
            disconnect(code: 3)
            return
        }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log("Could not subscribe to \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            disconnect(code: 3)
            return
        }
        log("Control channel open.\n")
        start()
    }

    // MARK: Commands

    private func start() {
        let header = options.header
        switch options.mode {
        case .scan:
            break
        case .info:
            steps = [
                Step(label: "firmware", build: { [SparkProtocol.getFirmware(sequence: $0, header: header)] },
                     answer: SparkProtocol.Sub.firmware),
                Step(label: "amp name", build: { [SparkProtocol.getAmpName(sequence: $0, header: header)] },
                     answer: SparkProtocol.Sub.ampName),
                Step(label: "current preset number",
                     build: { [SparkProtocol.getPresetNumber(sequence: $0, header: header)] },
                     answer: SparkProtocol.Sub.presetNumber),
                Step(label: "preset playing now",
                     build: { [SparkProtocol.getPreset(slot: nil, sequence: $0, header: header)] },
                     answer: SparkProtocol.Sub.preset),
            ]
            for slot in UInt8(0)...3 {
                steps.append(Step(label: "stored preset \(slot + 1)",
                                  build: { [SparkProtocol.getPreset(slot: slot, sequence: $0, header: header)] },
                                  answer: SparkProtocol.Sub.preset))
            }
        case .storeTest(let slot, _):
            steps = [
                Step(label: "read stored preset \(slot + 1)",
                     build: { [SparkProtocol.getPreset(slot: slot, sequence: $0, header: header)] },
                     answer: SparkProtocol.Sub.preset, answerCommand: SparkProtocol.Command.response),
            ]
        case .audition(let slot):
            steps = [
                Step(label: "read stored preset \(slot + 1)",
                     build: { [SparkProtocol.getPreset(slot: slot, sequence: $0, header: header)] },
                     answer: SparkProtocol.Sub.preset, answerCommand: SparkProtocol.Command.response),
            ]
        case .preset(let slot):
            steps = [
                Step(label: "switch to preset \(slot + 1)",
                     build: { [SparkProtocol.changeHardwarePreset(slot: slot, sequence: $0, header: header)] },
                     answer: SparkProtocol.Sub.hardwarePreset),
                Step(label: "current preset number",
                     build: { [SparkProtocol.getPresetNumber(sequence: $0, header: header)] },
                     answer: SparkProtocol.Sub.presetNumber),
            ]
        case .watch(let seconds):
            log("Listening for \(Int(seconds)) seconds. Press the preset button or turn a knob on the amp.")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in disconnect(code: 0) }
            return
        }
        next()
    }

    private func next() {
        guard !steps.isEmpty else {
            log("\nDone. \(hiddenStatus) repeated 03 64 message(s) hidden.")
            disconnect(code: 0)
            return
        }
        // The amp sometimes ignores a request that follows the last answer right away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in run(steps.removeFirst()) }
    }

    private func run(_ step: Step) {
        currentStep = step
        sequence = (sequence + 1) & 0x7F
        log(step.attempt == 1 ? "→ \(step.label)" : "→ \(step.label), attempt \(step.attempt)")
        send(step.build(sequence))
        waitingFor = (step.answer, step.answerCommand, 0)
        armTimeout()
    }

    /// Gives up when the amp stays silent for 3 seconds. A preset takes longer than that to arrive, so every
    /// notification starts the wait again.
    private func armTimeout() {
        guard let waiting = waitingFor else { return }
        token += 1
        let current = token
        waitingFor = (waiting.sub, waiting.command, current)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            guard waitingFor?.token == current else { return }
            waitingFor = nil
            log("  no answer within 3 seconds")
            if var step = currentStep, step.attempt < 2 {
                step.attempt += 1
                steps.insert(step, at: 0)
            }
            next()
        }
    }

    /// Writes every block on its own. A write longer than one Bluetooth packet is refused by the amp, so a block
    /// that does not fit one packet is split further.
    private func send(_ blocks: [[UInt8]]) {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse : .withoutResponse
        let size = max(peripheral.maximumWriteValueLength(for: .withoutResponse), 20)
        for block in blocks {
            if options.raw { log("  sent \(block.hex)") }
            for start in stride(from: 0, to: block.count, by: size) {
                peripheral.writeValue(Data(block[start..<min(start + size, block.count)]), for: characteristic,
                                      type: type)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("  write failed: \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        if options.raw { log("  received \(bytes.hex)") }
        armTimeout()
        for message in parser.feed(bytes) {
            // The amp repeats this one many times a second. It is counted, and shown with --raw.
            if message.sub == SparkProtocol.Sub.tunerPitch, !options.raw {
                hiddenStatus += 1
                continue
            }
            report(message)
            if let waitingFor, waitingFor.sub == message.sub,
               waitingFor.command.map({ $0 == message.command })
                ?? (message.command == SparkProtocol.Command.response
                    || message.command == SparkProtocol.Command.acknowledge) {
                self.waitingFor = nil
                next()
            }
        }
    }

    private func disconnect(code: Int32) {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        finish(code, after: 1)
    }

    // MARK: Output

    private func report(_ message: SparkProtocol.Message) {
        typealias Sub = SparkProtocol.Sub
        let checksum = message.checksumOK ? "" : " (checksum mismatch)"
        let head = String(format: "  ← %02X %02X", message.command, message.sub) + checksum

        if message.command == SparkProtocol.Command.acknowledge {
            log("\(head) acknowledged")
            return
        }
        switch message.sub {
        case Sub.firmware:
            log("\(head) firmware \(SparkValues.firmware(message.payload) ?? message.payload.hex)")
        case Sub.ampName:
            log("\(head) amp name \"\(SparkValues.string(message.payload) ?? message.payload.hex)\"")
        case Sub.presetNumber:
            log("\(head) preset number: \(slotText(message.payload))")
        case Sub.hardwarePreset:
            log("\(head) amp switched preset: \(slotText(message.payload))")
        case Sub.preset where message.command == 0x05:
            log("\(head) chunk received")
        case Sub.preset:
            do {
                let preset = try SparkPreset(payload: message.payload)
                let place = SparkValues.place(message.payload)
                let exact = preset.encode(place: .slot(0)).dropFirst(2) == message.payload.dropFirst(2)
                log("\(head) preset \"\(preset.name)\", place \(place.hex), \(String(format: "%.0f", preset.bpm)) "
                    + "BPM, \(message.payload.count) bytes, encodes back \(exact ? "exactly" : "DIFFERENTLY")")
                if case .audition = options.mode { planAudition(after: preset) }
                if case .storeTest(let slot, let path) = options.mode {
                    planStoreTest(after: preset, payload: message.payload, slot: slot, backup: path)
                }
                for effect in preset.effects {
                    let values = effect.parameters.map { String(format: "%d=%.2f", $0.index, $0.value) }
                    log("      \(effect.isOn ? "on " : "off") \(effect.name)  \(values.joined(separator: " "))")
                }
            } catch {
                log("\(head) preset, not decoded (\(error)): \(message.payload.hex)")
            }
        default:
            log("\(head) \(message.payload.hex)")
        }
    }

    /// After reading the stored preset: send it renamed as a temporary preset, then read back what plays.
    private func planAudition(after preset: SparkPreset) {
        let header = options.header
        if let expected = auditionName {
            log(preset.name == expected
                ? "  ✓ the amp plays the sent preset \"\(expected)\""
                : "  ✗ the amp plays \"\(preset.name)\", not the sent \"\(expected)\"")
            return
        }
        var copy = preset
        copy.name = String((preset.name + " Test").prefix(31))
        auditionName = copy.name
        steps = [
            Step(label: "send \"\(copy.name)\" to play without storing",
                 build: { SparkProtocol.sendPreset(copy, to: .temporary, sequence: $0, header: header) },
                 answer: SparkProtocol.Sub.preset, answerCommand: SparkProtocol.Command.acknowledge),
            Step(label: "switch to the temporary preset",
                 build: { [SparkProtocol.changeHardwarePreset(slot: 0x7F, sequence: $0, header: header)] },
                 answer: SparkProtocol.Sub.hardwarePreset),
            Step(label: "read the preset playing now",
                 build: { [SparkProtocol.getPreset(slot: nil, sequence: $0, header: header)] },
                 answer: SparkProtocol.Sub.preset, answerCommand: SparkProtocol.Command.response),
        ]
    }

    private func planStoreTest(after preset: SparkPreset, payload: [UInt8], slot: UInt8, backup path: String) {
        let header = options.header
        let read = Step(label: "read stored preset \(slot + 1)",
                        build: { [SparkProtocol.getPreset(slot: slot, sequence: $0, header: header)] },
                        answer: SparkProtocol.Sub.preset, answerCommand: SparkProtocol.Command.response)
        func store(_ preset: SparkPreset, _ label: String) -> [Step] {
            [Step(label: label, build: { SparkProtocol.sendPreset(preset, to: .slot(slot), sequence: $0, header: header) },
                  answer: SparkProtocol.Sub.preset, answerCommand: SparkProtocol.Command.acknowledge),
             Step(label: "switch to preset \(slot + 1)",
                  build: { [SparkProtocol.changeHardwarePreset(slot: slot, sequence: $0, header: header)] },
                  answer: SparkProtocol.Sub.hardwarePreset)]
        }
        storeStage += 1
        switch storeStage {
        case 1:
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(preset).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                log("  backup written to \(path)")
            } catch {
                log("  backup failed, nothing is stored: \(error.localizedDescription)")
                steps = []
                return
            }
            original = (preset, payload)
            var copy = preset
            copy.name = String((preset.name + " Test").prefix(31))
            auditionName = copy.name
            steps = store(copy, "store \"\(copy.name)\" in slot \(slot + 1)") + [read]
        case 2:
            log(preset.name == auditionName
                ? "  ✓ slot \(slot + 1) now holds \"\(preset.name)\""
                : "  ✗ slot \(slot + 1) holds \"\(preset.name)\", not \"\(auditionName ?? "")\"")
            guard let original else { return }
            steps = store(original.preset, "put the original \"\(original.preset.name)\" back") + [read]
        default:
            guard let original else { return }
            log(payload == original.payload
                ? "  ✓ slot \(slot + 1) is byte for byte the original again"
                : "  ✗ slot \(slot + 1) differs from the original. The backup is in \(path)")
            steps = [Step(label: "switch to preset 1",
                          build: { [SparkProtocol.changeHardwarePreset(slot: 0, sequence: $0, header: header)] },
                          answer: SparkProtocol.Sub.hardwarePreset)]
        }
    }

    private func slotText(_ payload: [UInt8]) -> String {
        guard let slot = SparkValues.slot(payload) else { return payload.hex }
        return (0...3).contains(slot) ? "\(slot + 1) (\(payload.hex))" : "raw \(payload.hex)"
    }
}

let probe = Probe(options: parseOptions())
dispatchMain()
