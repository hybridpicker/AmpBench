import Foundation

/// The Bluetooth LE control protocol of Positive Grid Spark amps.
///
/// Positive Grid does not document it. This follows the community's reverse engineering (Paul Hamshere's Spark
/// projects, SparkBox, Ignitron). Whatever this file assumes, `spark-probe` checks it against the real amp.
///
/// A message is one or more chunks: `F0 01 <seq> <checksum> <command> <sub-command> <7-bit data> F7`. Messages to
/// the amp are wrapped in a 16-byte block header. The amp's own block headers are skipped while parsing, because only
/// the chunks carry content and nothing in a header can be read as F0 or F7.
public enum SparkProtocol {
    public static let serviceUUID = "FFC0"
    public static let writeUUID = "FFC1"
    public static let notifyUUID = "FFC2"

    public enum Command {
        public static let set: UInt8 = 0x01
        public static let get: UInt8 = 0x02
        public static let response: UInt8 = 0x03
        public static let acknowledge: UInt8 = 0x04
    }

    public enum Sub {
        public static let preset: UInt8 = 0x01
        public static let changeEffect: UInt8 = 0x06
        public static let presetNumber: UInt8 = 0x10
        public static let ampName: UInt8 = 0x11
        public static let effectOnOff: UInt8 = 0x15
        public static let firmware: UInt8 = 0x2F
        public static let parameter: UInt8 = 0x37
        public static let hardwarePreset: UInt8 = 0x38
        /// Repeated many times a second with a float, -1 without signal. Probably the tuner's reading.
        public static let tunerPitch: UInt8 = 0x64
        /// A boolean, probably the tuner switching on or off.
        public static let tuner: UInt8 = 0x65
    }

    /// Raw data per chunk of a multi-chunk message. The Spark MINI uses 25 bytes in its own presets.
    static let chunkCapacity = 0x19

    // MARK: 7-bit packing

    /// Packs every 7 bytes behind a byte that holds their high bits, the first byte in bit 0.
    public static func pack7(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 7 + 1)
        var index = 0
        while index < data.count {
            let group = data[index..<min(index + 7, data.count)]
            var mask: UInt8 = 0
            for (bit, byte) in group.enumerated() where byte & 0x80 != 0 { mask |= 1 << bit }
            out.append(mask)
            out.append(contentsOf: group.map { $0 & 0x7F })
            index += 7
        }
        return out
    }

    public static func unpack7(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var index = 0
        while index < data.count {
            let mask = data[index]
            let group = data[(index + 1)..<min(index + 8, data.count)]
            for (bit, byte) in group.enumerated() {
                out.append(mask & (1 << bit) != 0 ? byte | 0x80 : byte)
            }
            index += 8
        }
        return out
    }

    // MARK: Building messages

    /// Builds a message to the amp. A preset (`set`/`preset`) is split into numbered chunks, everything else is one
    /// chunk. Each chunk gets its own block header, because the header holds the length in one byte. `header: false`
    /// leaves the headers out, the way the amp sends.
    public static func frame(command: UInt8, sub: UInt8, payload: [UInt8], sequence: UInt8,
                             header: Bool = true) -> [UInt8] {
        blocks(command: command, sub: sub, payload: payload, sequence: sequence, header: header).flatMap { $0 }
    }

    /// The same message as separate blocks, one chunk each. Each block goes to the amp in a write of its own.
    public static func blocks(command: UInt8, sub: UInt8, payload: [UInt8], sequence: UInt8,
                              header: Bool = true) -> [[UInt8]] {
        var chunks: [[UInt8]] = []
        if isMultiChunk(command: command, sub: sub) {
            let parts = stride(from: 0, to: max(payload.count, 1), by: chunkCapacity).map {
                Array(payload[$0..<min($0 + chunkCapacity, payload.count)])
            }
            for (number, part) in parts.enumerated() {
                chunks.append([UInt8(parts.count), UInt8(number), UInt8(part.count)] + part)
            }
        } else {
            chunks = [payload]
        }

        return chunks.map { raw in
            let packed = pack7(raw)
            let checksum = packed.reduce(UInt8(0), ^)
            let chunk = [0xF0, 0x01, sequence & 0x7F, checksum, command, sub] + packed + [0xF7]
            return header ? blockHeader(length: chunk.count + 16) + chunk : chunk
        }
    }

    static func blockHeader(length: Int) -> [UInt8] {
        [0x01, 0xFE, 0x00, 0x00, 0x53, 0xFE, UInt8(length & 0xFF)] + [UInt8](repeating: 0, count: 9)
    }

    static func isMultiChunk(command: UInt8, sub: UInt8) -> Bool {
        sub == Sub.preset && (command == Command.set || command == Command.response)
    }

    // MARK: Requests

    public static func getFirmware(sequence: UInt8, header: Bool = true) -> [UInt8] {
        frame(command: Command.get, sub: Sub.firmware, payload: [], sequence: sequence, header: header)
    }

    public static func getAmpName(sequence: UInt8, header: Bool = true) -> [UInt8] {
        frame(command: Command.get, sub: Sub.ampName, payload: [], sequence: sequence, header: header)
    }

    public static func getPresetNumber(sequence: UInt8, header: Bool = true) -> [UInt8] {
        frame(command: Command.get, sub: Sub.presetNumber, payload: [], sequence: sequence, header: header)
    }

    /// `slot` 0 to 3 reads a stored preset, `nil` the one currently playing, with any unsaved changes.
    public static func getPreset(slot: UInt8?, sequence: UInt8, header: Bool = true) -> [UInt8] {
        let selector: [UInt8] = slot.map { [0x00, $0] } ?? [0x01, 0x00]
        return frame(command: Command.get, sub: Sub.preset, payload: selector + [UInt8](repeating: 0, count: 30),
                     sequence: sequence, header: header)
    }

    /// Sends a whole preset. `.temporary` plays it without storing it, `.slot` is meant to store it there.
    public static func sendPreset(_ preset: SparkPreset, to place: SparkPresetPlace, sequence: UInt8,
                                  header: Bool = true) -> [[UInt8]] {
        blocks(command: Command.set, sub: Sub.preset, payload: preset.encode(place: place), sequence: sequence,
               header: header)
    }

    /// Switches to stored preset `slot`, 0 to 3, like the preset button on the amp.
    public static func changeHardwarePreset(slot: UInt8, sequence: UInt8, header: Bool = true) -> [UInt8] {
        frame(command: Command.set, sub: Sub.hardwarePreset, payload: [0x00, slot], sequence: sequence, header: header)
    }

    // MARK: Parsing

    public struct Message: Equatable {
        public var command: UInt8
        public var sub: UInt8
        public var sequence: UInt8
        /// Unpacked data. For multi-chunk messages, the chunks' data joined without their numbering.
        public var payload: [UInt8]
        /// False when a chunk's checksum did not match. The message is still delivered, so it can be inspected.
        public var checksumOK: Bool
    }

    /// Collects notification bytes into messages. Notifications can split a chunk anywhere.
    public final class Parser {
        private var current: [UInt8]?
        private var pending: (command: UInt8, sub: UInt8, sequence: UInt8, data: [UInt8], ok: Bool)?

        public init() {}

        public func feed(_ bytes: [UInt8]) -> [Message] {
            var messages: [Message] = []
            for byte in bytes {
                if byte == 0xF0 {
                    current = []
                } else if byte == 0xF7, let chunk = current {
                    current = nil
                    if let message = finish(chunk) { messages.append(message) }
                } else if current != nil {
                    current!.append(byte)
                }
            }
            return messages
        }

        private func finish(_ chunk: [UInt8]) -> Message? {
            // 01 <seq> <checksum> <command> <sub> <data>
            guard chunk.count >= 5, chunk[0] == 0x01 else { return nil }
            let sequence = chunk[1], checksum = chunk[2], command = chunk[3], sub = chunk[4]
            let packed = Array(chunk[5...])
            let ok = packed.reduce(UInt8(0), ^) == checksum
            let data = SparkProtocol.unpack7(packed)

            guard SparkProtocol.isMultiChunk(command: command, sub: sub), data.count >= 3 else {
                return Message(command: command, sub: sub, sequence: sequence, payload: data, checksumOK: ok)
            }
            let total = Int(data[0]), number = Int(data[1])
            let part = Array(data[3...])
            if number == 0 || pending == nil || pending!.command != command || pending!.sub != sub {
                pending = (command, sub, sequence, [], true)
            }
            pending!.data += part
            pending!.ok = pending!.ok && ok
            guard number + 1 >= total, let done = pending else { return nil }
            pending = nil
            return Message(command: done.command, sub: done.sub, sequence: done.sequence, payload: done.data,
                           checksumOK: done.ok)
        }
    }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
