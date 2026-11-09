import Foundation
import SparkControl

/// Simulated Positive Grid devices behind `LinkTransport`, the Swift counterpart of linux/spark_studio/fake_amp.py.
/// Used by the tests and by window pictures (`--library <folder> --demo-devices`), never with a real device.
/// It answers the way the real ones did with spark-probe: chunk acknowledgements `05 01` and `04 01` for presets,
/// `04 38` for a switch, `04 15` and `04 06` for changes, nothing for a parameter. A NEO drops its temporary sound
/// when the connection ends. A REACTOR answers nothing and records every byte it gets, which must stay none.
@MainActor
final class SimulatedDevice: LinkTransport {
    enum Kind { case mini, neo, reactor, unknownSpark }

    struct Device {
        let found: FoundDevice
        let kind: Kind
    }

    weak var delegate: LinkTransportDelegate?
    private(set) var state = TransportState.unknown
    var devices: [Device]
    /// Every block written, per device.
    private(set) var written: [UUID: [[UInt8]]] = [:]
    private(set) var listenOnly: [UUID: Bool] = [:]
    private(set) var connected: UUID?
    var slots: [SparkPreset]
    var active = 0
    var temporary: SparkPreset?
    private(set) var parameters: [(String, UInt8, Float)] = []
    /// The device's own tuner, switched with `01 65`. It stays as it is when the connection ends.
    private(set) var tunerOn = false
    /// False: the device switches its tuner off without `04 65`, as the MINI did once.
    var acknowledgesTunerOff = true
    /// True: the device is out of reach and not found by a search, until `comeBack`.
    var isAway = false
    private var waitingConnect: FoundDevice?
    /// True: the device answers no request, as when it hangs.
    var ignoresRequests = false
    private let parser = SparkProtocol.Parser()
    private var sequence: UInt8 = 0

    init(_ kinds: [Kind]) {
        devices = kinds.map { kind in
            let (name, service): (String, String) = switch kind {
            case .mini: ("Spark MINI BLE", "FFC0")
            case .neo: ("Spark NEO Control", "FFC0")
            case .reactor: ("Reactor 50 Proberaum", "FFD0")
            case .unknownSpark: ("Spark 40 Audio", "FFC0")
            }
            return Device(found: FoundDevice(id: UUID(), name: name, service: service), kind: kind)
        }
        slots = PresetFactory.templates.prefix(4).map { PresetFactory.make($0) }
    }

    func id(_ kind: Kind) -> UUID { devices.first { $0.kind == kind }!.found.id }

    private var connectedKind: Kind? { devices.first { $0.found.id == connected }?.kind }

    // MARK: LinkTransport

    func powerUp() {
        guard state != .poweredOn else { return }
        state = .poweredOn
        later { $0.delegate?.transport(changedState: .poweredOn) }
    }

    func startSearch(services: [String]) {
        guard !isAway else { return }
        for device in devices where services.contains(device.found.service) {
            later { $0.delegate?.transport(found: device.found) }
        }
    }

    func stopSearch() {}

    func connect(_ device: FoundDevice, listenOnly: Bool) {
        self.listenOnly[device.id] = listenOnly
        // Like CoreBluetooth: a connection to a device out of reach waits until it is back.
        guard !isAway else {
            waitingConnect = device
            return
        }
        later {
            $0.connected = device.id
            $0.delegate?.transport(connected: device.id)
        }
    }

    func disconnect(_ id: UUID) {
        guard connected == id else { return }
        dropConnection()
    }

    func write(_ blocks: [[UInt8]]) throws {
        guard let connected else { throw LinkError.notConnected }
        written[connected, default: []] += blocks
        // A REACTOR never answers: nothing Spark Studio may send is known to it.
        guard connectedKind != .reactor, !ignoresRequests else { return }
        for block in blocks {
            for message in parser.feed(block) { handle(message) }
        }
    }

    // MARK: The device's side

    /// The connection ends from the device's side, such as switching it off.
    func dropConnection() {
        guard let id = connected else { return }
        // The NEO plays its stored slot again; heard on 2026-11-09.
        if connectedKind == .neo { temporary = nil }
        connected = nil
        later { $0.delegate?.transport(lost: id) }
    }

    /// The device is in reach again and found.
    func comeBack() {
        isAway = false
        if let device = waitingConnect {
            waitingConnect = nil
            connect(device, listenOnly: listenOnly[device.id] ?? false)
        } else {
            for device in devices { later { $0.delegate?.transport(found: device.found) } }
        }
    }

    /// The preset button on a Spark, the middle button on a NEO, the preset or bank key on a REACTOR.
    func pressButton(_ slot: Int) {
        active = slot
        temporary = nil
        reply(SparkProtocol.Command.response, SparkProtocol.Sub.hardwarePreset, [0x00, UInt8(slot)])
    }

    /// Sends a message by itself, as a REACTOR does when a control is used.
    func report(_ sub: UInt8, _ payload: [UInt8]) {
        reply(SparkProtocol.Command.response, sub, payload)
    }

    /// One reading of the device's own tuner, `03 64 <note> CA <float>`, sent only while it is on.
    func tunerReading(note: UInt8, value: Float) {
        guard tunerOn else { return }
        reply(SparkProtocol.Command.response, SparkProtocol.Sub.tunerPitch,
              [note, 0xCA] + withUnsafeBytes(of: value.bitPattern.bigEndian, Array.init))
    }

    private func reply(_ command: UInt8, _ sub: UInt8, _ payload: [UInt8]) {
        sequence = (sequence + 1) & 0x7F
        let wire = SparkProtocol.frame(command: command, sub: sub, payload: payload, sequence: sequence, header: false)
        // Notifications split chunks anywhere.
        for start in stride(from: 0, to: wire.count, by: 20) {
            let piece = Array(wire[start..<min(start + 20, wire.count)])
            later { $0.delegate?.transport(received: piece) }
        }
    }

    private func handle(_ message: SparkProtocol.Message) {
        typealias Sub = SparkProtocol.Sub
        let set = SparkProtocol.Command.set, get = SparkProtocol.Command.get
        let ack = SparkProtocol.Command.acknowledge, response = SparkProtocol.Command.response
        switch (message.command, message.sub) {
        case (get, Sub.ampName):
            let name = switch connectedKind {
            case .neo: "Spark NEO"
            case .unknownSpark: "Spark 40"
            default: "Spark MINI"
            }
            reply(response, Sub.ampName, [UInt8(name.utf8.count), 0xA0 + UInt8(name.utf8.count)] + Array(name.utf8))
        case (get, Sub.firmware):
            reply(response, Sub.firmware, connectedKind == .neo ? [0xCE, 1, 16, 1, 60] : [0xCE, 1, 11, 2, 75])
        case (get, Sub.presetNumber):
            reply(response, Sub.presetNumber, [0x00, UInt8(active)])
        case (get, Sub.preset):
            if message.payload.first == 0x01 {
                reply(response, Sub.preset, (temporary ?? slots[active]).encode(place: .playing))
            } else {
                let slot = Int(message.payload[1])
                reply(response, Sub.preset, slots[slot].encode(place: .slot(UInt8(slot))))
            }
        case (set, Sub.preset):
            guard let preset = try? SparkPreset(payload: message.payload) else { return }
            for _ in 0..<max(1, (message.payload.count + 24) / 25) { reply(0x05, Sub.preset, []) }
            if message.payload[1] == 0x7F { temporary = preset } else { slots[Int(message.payload[1])] = preset }
            reply(ack, Sub.preset, [])
        case (set, Sub.hardwarePreset):
            let slot = Int(message.payload[1])
            if slot != 0x7F {
                active = slot
                temporary = nil
            }
            reply(ack, Sub.hardwarePreset, message.payload)
        case (set, Sub.parameter):
            if let change = Self.parameterChange(message.payload) { parameters.append(change) }
        case (set, Sub.effectOnOff), (set, Sub.changeEffect):
            reply(ack, message.sub, [])
        case (set, Sub.tuner):
            tunerOn = message.payload.first == 0xC3
            if tunerOn || acknowledgesTunerOff { reply(ack, Sub.tuner, []) }
        default:
            break
        }
    }

    /// `len, A0+len, name, index, CA float`, the form of `01 04` and `03 37`.
    static func parameterPayload(_ name: String, _ index: UInt8, _ value: Float) -> [UInt8] {
        let bytes = Array(name.utf8)
        return [UInt8(bytes.count), 0xA0 + UInt8(bytes.count)] + bytes + [index, 0xCA]
            + withUnsafeBytes(of: value.bitPattern.bigEndian, Array.init)
    }

    /// `len, A0+len, name, C3/C2`, the form of `03 15`.
    static func onOffPayload(_ name: String, _ isOn: Bool) -> [UInt8] {
        let bytes = Array(name.utf8)
        return [UInt8(bytes.count), 0xA0 + UInt8(bytes.count)] + bytes + [isOn ? 0xC3 : 0xC2]
    }

    /// `len, A0+len, name, index, CA float`, the form of `01 04`.
    private static func parameterChange(_ payload: [UInt8]) -> (String, UInt8, Float)? {
        guard payload.count >= 2 else { return nil }
        let length = Int(payload[0])
        guard payload.count >= 2 + length + 6, payload[2 + length + 1] == 0xCA else { return nil }
        let name = String(decoding: payload[2..<(2 + length)], as: UTF8.self)
        let bits = payload[(3 + length + 1)..<(3 + length + 5)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (name, payload[2 + length], Float(bitPattern: bits))
    }

    private func later(_ work: @escaping @MainActor (SimulatedDevice) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let self { work(self) } }
        }
    }
}
