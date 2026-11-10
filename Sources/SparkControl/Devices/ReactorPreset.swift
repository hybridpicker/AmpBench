import Foundation

/// A preset as a REACTOR stores it, read from its answer to `02 01 00 <slot>`. Its own format, not a Spark preset:
/// MessagePack with the slot, the preset's and the amp's name cards, the tempo, six fixed blocks for amp and
/// equalizer and ten effect blocks, each `C4 02 <id> <on> <values>`, and a checksum of four bytes at the end
/// (`checksum(of:)`). Worked out on 2026-11-10 from the eight slots of a REACTOR 50 (docs/STUDIO.md). Read only: Spark Studio
/// cannot build one.
public struct ReactorPreset: Equatable, Sendable {
    /// Name, version, description, picture and tags, as both the preset and its amp carry them.
    public struct Card: Equatable, Sendable {
        public var id: [UInt8]
        public var name: String
        public var version: String
        public var description: String
        public var icon: String
        public var number: Int
        public var tags: [String]
    }

    public struct Block: Equatable, Sendable {
        /// Two bytes that name what the block is, such as 05 03 or, for an effect, its model.
        public var id: UInt16
        public var isOn: Bool
        public var values: [Float]
    }

    /// From 0.
    public var slot: Int
    public var preset: Card
    public var tempo: Float
    public var amp: Card
    /// Amp and equalizer: the same six kinds in every preset.
    public var fixed: [Block]
    /// The ten effect places.
    public var effects: [Block]
    /// The last four bytes as they came: the checksum over everything after the slot.
    public var trailer: [UInt8]
    /// False when the checksum at the end does not fit the content. The preset is still shown.
    public var checksumOK: Bool

    /// The REACTOR's checksum: CRC-32/MPEG-2 (polynomial 04C11DB7, start FFFFFFFF, not reflected, no final XOR), high
    /// byte first, over the preset's bytes after the two bytes `00 <slot>` and before the checksum itself. Found on
    /// 2026-11-10; it fits all eight presets read from a REACTOR 50.
    public static func checksum(of content: some Sequence<UInt8>) -> [UInt8] {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in content {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
    }

    public var name: String { preset.name }
    public var ampName: String { amp.name }
    public var effectsOn: Int { effects.filter(\.isOn).count }

    /// "Twin Clean · 5 Effekte an", the line under the name in a list.
    public var summary: String {
        let on = effectsOn
        return amp.name + " · " + (on == 0 ? "keine Effekte an" : on == 1 ? "1 Effekt an" : "\(on) Effekte an")
    }

    public struct Unreadable: LocalizedError, Equatable {
        public var text: String
        public var errorDescription: String? { "Das REACTOR-Preset ist nicht lesbar: \(text)" }
    }

    /// A REACTOR numbers its chunks with a four-byte header: count, number and the length in 16 bits. The Spark parser
    /// takes three, so one byte of every chunk's length stays in front of its data. Chunks carry `chunkSize` bytes,
    /// the last one the rest.
    public static let chunkSize = 350

    /// The preset's bytes from a message as the Spark parser joined it.
    public static func joined(_ payload: [UInt8]) -> [UInt8] {
        var data: [UInt8] = []
        var index = 0
        while index < payload.count {
            data += payload[min(index + 1, payload.count)..<min(index + 1 + chunkSize, payload.count)]
            index += chunkSize + 1
        }
        return data
    }

    /// Reads the answer to a slot request, as the Spark parser delivered it.
    public init(payload: [UInt8]) throws {
        try self.init(data: Self.joined(payload))
    }

    /// Reads the preset's own bytes.
    public init(data: [UInt8]) throws {
        var reader = Reader(data)
        guard try reader.byte() == 0 else { throw Unreadable(text: "kein Platz am Anfang") }
        slot = Int(try reader.byte())
        preset = try reader.card()
        tempo = try reader.number()
        amp = try reader.card()
        fixed = try reader.blocks()
        effects = try reader.blocks()
        trailer = reader.rest()
        guard trailer.count == 4 else { throw Unreadable(text: "\(trailer.count) statt 4 Bytes am Ende") }
        checksumOK = Self.checksum(of: data[2..<(data.count - 4)]) == trailer
    }

    /// Just enough MessagePack for a REACTOR preset.
    struct Reader {
        private let data: [UInt8]
        private var index = 0

        init(_ data: [UInt8]) { self.data = data }

        mutating func byte() throws -> UInt8 {
            guard index < data.count else { throw Unreadable(text: "zu kurz") }
            defer { index += 1 }
            return data[index]
        }

        private mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard index + count <= data.count else { throw Unreadable(text: "zu kurz") }
            defer { index += count }
            return Array(data[index..<index + count])
        }

        mutating func rest() -> [UInt8] {
            defer { index = data.count }
            return Array(data[index...])
        }

        mutating func binary() throws -> [UInt8] {
            guard try byte() == 0xC4 else { throw Unreadable(text: "Kennung erwartet bei \(index - 1)") }
            return try bytes(Int(try byte()))
        }

        mutating func string() throws -> String {
            let type = try byte()
            let count: Int
            switch type {
            case 0xA0...0xBF: count = Int(type & 0x1F)
            case 0xD9: count = Int(try byte())
            default: throw Unreadable(text: "Text erwartet bei \(index - 1)")
            }
            return String(decoding: try bytes(count), as: UTF8.self)
        }

        private mutating func count() throws -> Int {
            let type = try byte()
            switch type {
            case 0x90...0x9F: return Int(type & 0x0F)
            case 0xDC:
                let high = try byte(), low = try byte()
                return Int(high) << 8 | Int(low)
            default: throw Unreadable(text: "Liste erwartet bei \(index - 1)")
            }
        }

        /// A value: a small whole number, a 16-bit half float (`CD`) or a float (`CA`).
        mutating func number() throws -> Float {
            let type = try byte()
            switch type {
            case 0x00...0x7F: return Float(type)
            case 0xCC: return Float(try byte())
            case 0xCD:
                let high = try byte(), low = try byte()
                return Float(Float16(bitPattern: UInt16(high) << 8 | UInt16(low)))
            case 0xCA:
                let raw = try bytes(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                return Float(bitPattern: raw)
            default: throw Unreadable(text: String(format: "Wert erwartet bei %d (%02X)", index - 1, type))
            }
        }

        mutating func card() throws -> Card {
            let id = try binary()
            let name = try string(), version = try string(), description = try string(), icon = try string()
            let number = Int(try self.number())
            let tags = try (0..<count()).map { _ in try string() }
            return Card(id: id, name: name, version: version, description: description, icon: icon, number: number,
                        tags: tags)
        }

        /// A counted row of blocks, each `C4 02 <id> <C3|C2> <list of values>`.
        mutating func blocks() throws -> [Block] {
            try (0..<count()).map { _ in
                let id = try binary()
                guard id.count == 2 else { throw Unreadable(text: "Blockkennung mit \(id.count) Bytes") }
                let flag = try byte()
                guard flag == 0xC3 || flag == 0xC2 else { throw Unreadable(text: "an/aus erwartet bei \(index - 1)") }
                let values = try (0..<count()).map { _ in try number() }
                return Block(id: UInt16(id[0]) << 8 | UInt16(id[1]), isOn: flag == 0xC3, values: values)
            }
        }
    }
}
