import Foundation

/// A preset as the amp sends it. The encoding resembles MessagePack: strings, 32-bit floats, booleans, arrays.
public struct SparkPreset: Equatable {
    public struct Effect: Equatable {
        public var name: String
        public var isOn: Bool
        /// Parameter number and value, the value from 0 to 1.
        public var parameters: [(index: UInt8, value: Float)]

        public static func == (lhs: Effect, rhs: Effect) -> Bool {
            lhs.name == rhs.name && lhs.isOn == rhs.isOn
                && lhs.parameters.map(\.index) == rhs.parameters.map(\.index)
                && lhs.parameters.map(\.value) == rhs.parameters.map(\.value)
        }
    }

    public var slot: UInt8
    public var uuid: String
    public var name: String
    public var version: String
    public var description: String
    public var icon: String
    public var bpm: Float
    public var effects: [Effect]

    public init(payload: [UInt8]) throws {
        var reader = SparkReader(payload)
        _ = try reader.byte()
        slot = try reader.byte()
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
            var parameters: [(UInt8, Float)] = []
            for _ in 0..<parameterCount {
                let index = try reader.byte()
                _ = try reader.byte()  // a type marker, 0x91 so far
                parameters.append((index, try reader.float()))
            }
            effects.append(Effect(name: name, isOn: isOn, parameters: parameters))
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

    /// A short string (`A0+n`), a longer one (`D9 n`), or a short one behind an extra length byte.
    public mutating func string() throws -> String {
        let start = position
        var marker = try byte()
        if (0x00...0x7F).contains(marker), position < data.count, (0xA0...0xBF).contains(data[position]) {
            marker = try byte()
        }
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

public enum SparkValues {
    /// The firmware version: `CE` and four bytes.
    public static func firmware(_ payload: [UInt8]) -> String? {
        guard payload.count >= 5, payload[0] == 0xCE else { return nil }
        return payload[1...4].map(String.init).joined(separator: ".")
    }

    public static func string(_ payload: [UInt8]) -> String? {
        var reader = SparkReader(payload)
        return try? reader.string()
    }

    /// The slot in a preset number or hardware preset message: `00 <slot>`.
    public static func slot(_ payload: [UInt8]) -> UInt8? {
        payload.count >= 2 ? payload[1] : nil
    }
}
