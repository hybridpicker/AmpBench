import Foundation
@testable import SparkControl
@testable import SparkPresetsUI

/// A simulated Positive Grid device behind `LinkTransport`, the Swift counterpart of linux/spark_studio/fake_amp.py.
/// It answers the way the real ones did with spark-probe: chunk acknowledgements `05 01` and `04 01` for presets,
/// `04 38` for a switch, `04 15` and `04 06` for changes, nothing for a parameter. A NEO drops its temporary sound
/// when the connection ends. A REACTOR answers nothing and records every byte it gets, which must stay none.
@MainActor
final class FakeDevice: LinkTransport {
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
        for device in devices where services.contains(device.found.service) {
            later { $0.delegate?.transport(found: device.found) }
        }
    }

    func stopSearch() {}

    func connect(_ device: FoundDevice, listenOnly: Bool) {
        self.listenOnly[device.id] = listenOnly
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
        guard connectedKind != .reactor else { return }
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
            var writer = SparkWriter()
            writer.string(name)
            reply(response, Sub.ampName, [UInt8(name.utf8.count)] + writer.data)
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
            var reader = SparkReader(message.payload)
            if let effect = try? reader.prefixedString(), let index = try? reader.byte(), let value = try? reader.float() {
                parameters.append((effect, index, value))
            }
        case (set, Sub.effectOnOff), (set, Sub.changeEffect):
            reply(ack, message.sub, [])
        default:
            break
        }
    }

    private func later(_ work: @escaping @MainActor (FakeDevice) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let self { work(self) } }
        }
    }
}
