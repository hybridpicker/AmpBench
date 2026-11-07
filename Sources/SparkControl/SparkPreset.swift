import Foundation

/// A preset as the amp sends it. The encoding resembles MessagePack: strings, 32-bit floats, booleans, arrays.
///
/// Everything the amp sends is kept, so `encode` writes back exactly the bytes that were read.
public struct SparkPreset: Codable, Equatable, Sendable {
    public struct Parameter: Codable, Equatable, Sendable {
        public var index: UInt8
        /// From 0 to 1.
        public var value: Float
        /// A type marker the amp sends before each value, 0x91 so far.
        public var marker: UInt8

        public init(index: UInt8, value: Float, marker: UInt8 = 0x91) {
            self.index = index
            self.value = value
            self.marker = marker
        }
    }

    public struct Effect: Codable, Equatable, Sendable {
        public var name: String
        public var isOn: Bool
        public var parameters: [Parameter]

        public init(name: String, isOn: Bool, parameters: [Parameter]) {
            self.name = name
            self.isOn = isOn
            self.parameters = parameters
        }
    }

    public var uuid: String
    public var name: String
    public var version: String
    public var description: String
    public var icon: String
    public var bpm: Float
    public var effects: [Effect]
    /// The bytes after the effects, one byte so far. Sent back unchanged.
    public var trailer: [UInt8]

    public init(uuid: String = UUID().uuidString, name: String, version: String = "0.7", description: String = "",
                icon: String = "icon.png", bpm: Float = 120, effects: [Effect], trailer: [UInt8] = [0x00]) {
        self.uuid = uuid
        self.name = name
        self.version = version
        self.description = description
        self.icon = icon
        self.bpm = bpm
        self.effects = effects
        self.trailer = trailer
    }

    /// Reads a preset message's payload. Its first two bytes say where the preset is, see `SparkPresetPlace`.
    public init(payload: [UInt8]) throws {
        var reader = SparkReader(payload)
        _ = try reader.byte()
        _ = try reader.byte()
        try self.init(reader: &reader)
    }

    init(reader: inout SparkReader) throws {
        uuid = try reader.string()
        name = try reader.string()
        version = try reader.string()
        description = try reader.string()
        icon = try reader.string()
        bpm = try reader.float()
        let count = try reader.arrayCount()
        effects = []
        for _ in 0..<count {
            let name = try reader.string()
            let isOn = try reader.bool()
            let parameterCount = try reader.arrayCount()
            var parameters: [Parameter] = []
            for _ in 0..<parameterCount {
                let index = try reader.byte()
                let marker = try reader.byte()
                parameters.append(Parameter(index: index, value: try reader.float(), marker: marker))
            }
            effects.append(Effect(name: name, isOn: isOn, parameters: parameters))
        }
        trailer = reader.rest()
    }

    /// The payload for a preset message, behind the two bytes of `place`.
    public func encode(place: SparkPresetPlace) -> [UInt8] {
        var writer = SparkWriter()
        writer.bytes(place.bytes)
        writer.string(uuid)
        writer.string(name)
        writer.string(version)
        writer.string(description)
        writer.string(icon)
        writer.float(bpm)
        writer.array(effects.count)
        for effect in effects {
            writer.string(effect.name)
            writer.bool(effect.isOn)
            writer.array(effect.parameters.count)
            for parameter in effect.parameters {
                writer.bytes([parameter.index, parameter.marker])
                writer.float(parameter.value)
            }
        }
        writer.bytes(trailer)
        return writer.data
    }
}

/// Where a preset is, as the first two bytes of a preset message.
public enum SparkPresetPlace: Equatable, Sendable {
    /// One of the four stored presets, 0 to 3.
    case slot(UInt8)
    /// What the amp plays now, in requests for it.
    case playing
    /// Played at once without being stored, in presets sent to the amp.
    case temporary

    public var bytes: [UInt8] {
        switch self {
        case .slot(let slot): [0x00, slot]
        case .playing: [0x01, 0x00]
        case .temporary: [0x00, 0x7F]
        }
    }
}

public enum SparkDecodeError: Error, CustomStringConvertible {
    case truncated(at: Int)
    case unexpected(byte: UInt8, at: Int, expected: String)

    public var description: String {
        switch self {
        case .truncated(let at): "data ends at byte \(at)"
        case .unexpected(let byte, let at, let expected):
            String(format: "byte %d is 0x%02X, expected %@", at, byte, expected)
        }
    }
}

public struct SparkReader {
    private let data: [UInt8]
    public private(set) var position = 0

    public init(_ data: [UInt8]) { self.data = data }

    public var isAtEnd: Bool { position >= data.count }

    public mutating func byte() throws -> UInt8 {
        guard position < data.count else { throw SparkDecodeError.truncated(at: position) }
        defer { position += 1 }
        return data[position]
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard position + count <= data.count else { throw SparkDecodeError.truncated(at: data.count) }
        defer { position += count }
        return Array(data[position..<(position + count)])
    }

    mutating func rest() -> [UInt8] {
        defer { position = data.count }
        return Array(data[min(position, data.count)...])
    }

    /// A short string (`A0+n`) or a longer one (`D9 n`).
    public mutating func string() throws -> String {
        let start = position
        let marker = try byte()
        let length: Int
        switch marker {
        case 0xA0...0xBF: length = Int(marker - 0xA0)
        case 0xD9: length = Int(try byte())
        default: throw SparkDecodeError.unexpected(byte: marker, at: start, expected: "a string")
        }
        return String(decoding: try bytes(length), as: UTF8.self)
    }

    public mutating func float() throws -> Float {
        let start = position
        let marker = try byte()
        guard marker == 0xCA else { throw SparkDecodeError.unexpected(byte: marker, at: start, expected: "0xCA") }
        let raw = try bytes(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Float(bitPattern: raw)
    }

    public mutating func bool() throws -> Bool {
        let start = position
        switch try byte() {
        case 0xC3: return true
        case 0xC2: return false
        case let other: throw SparkDecodeError.unexpected(byte: other, at: start, expected: "0xC2 or 0xC3")
        }
    }

    public mutating func arrayCount() throws -> Int {
        let start = position
        let marker = try byte()
        guard (0x90...0x9F).contains(marker) else {
            throw SparkDecodeError.unexpected(byte: marker, at: start, expected: "an array")
        }
        return Int(marker - 0x90)
    }
}

struct SparkWriter {
    private(set) var data: [UInt8] = []

    mutating func bytes(_ bytes: [UInt8]) { data += bytes }

    /// Short strings as `A0+n`, from 32 bytes on as `D9 n`, the way the amp writes them. Longer than 255 bytes is
    /// cut at a character boundary.
    mutating func string(_ text: String) {
        var bytes = Array(text.utf8)
        if bytes.count > 255 {
            var cut = String(text.prefix(255))
            while cut.utf8.count > 255 { cut.removeLast() }
            bytes = Array(cut.utf8)
        }
        data += bytes.count < 32 ? [0xA0 + UInt8(bytes.count)] : [0xD9, UInt8(bytes.count)]
        data += bytes
    }

    mutating func float(_ value: Float) {
        let raw = value.bitPattern
        data += [0xCA, UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
    }

    mutating func bool(_ value: Bool) { data.append(value ? 0xC3 : 0xC2) }

    mutating func array(_ count: Int) { data.append(0x90 + UInt8(min(count, 15))) }
}

public enum SparkValues {
    /// The firmware version: `CE` and four bytes.
    public static func firmware(_ payload: [UInt8]) -> String? {
        guard payload.count >= 5, payload[0] == 0xCE else { return nil }
        return payload[1...4].map(String.init).joined(separator: ".")
    }

    /// A string, also with the extra length byte in front that the amp puts before its name.
    public static func string(_ payload: [UInt8]) -> String? {
        var bytes = payload
        if bytes.count >= 2, bytes[0] < 0x80, (0xA0...0xBF).contains(bytes[1]) { bytes.removeFirst() }
        var reader = SparkReader(bytes)
        return try? reader.string()
    }

    /// The slot in a preset number or hardware preset message: `00 <slot>`.
    public static func slot(_ payload: [UInt8]) -> UInt8? {
        payload.count >= 2 ? payload[1] : nil
    }

    /// Where a received preset is: its first two bytes.
    public static func place(_ payload: [UInt8]) -> [UInt8] { Array(payload.prefix(2)) }
}
