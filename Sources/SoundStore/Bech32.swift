import Foundation

/// Bech32 (BIP 173, not bech32m) as the age format uses it for keys: without the 90-character limit, and identities
/// written in upper case.
enum Bech32 {
    private static let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    private static let values: [UInt8: UInt8] = {
        var table: [UInt8: UInt8] = [:]
        for (index, character) in alphabet.enumerated() { table[character] = UInt8(index) }
        return table
    }()

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generators: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
        var checksum: UInt32 = 1
        for value in values {
            let top = checksum >> 25
            checksum = (checksum & 0x1ff_ffff) << 5 ^ UInt32(value)
            for (bit, generator) in generators.enumerated() where (top >> UInt32(bit)) & 1 == 1 {
                checksum ^= generator
            }
        }
        return checksum
    }

    private static func expand(_ prefix: String) -> [UInt8] {
        let bytes = Array(prefix.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 31 }
    }

    /// Regroups bits. Encoding pads the last group with zeros; decoding refuses padding that is not zero or too long.
    private static func regroup(_ input: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var accumulator = 0
        var bits = 0
        var output: [UInt8] = []
        let mask = (1 << to) - 1
        for value in input {
            guard Int(value) >> from == 0 else { return nil }
            accumulator = (accumulator << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                output.append(UInt8((accumulator >> bits) & mask))
            }
        }
        if pad {
            if bits > 0 { output.append(UInt8((accumulator << (to - bits)) & mask)) }
        } else if bits >= from || (accumulator << (to - bits)) & mask != 0 {
            return nil
        }
        return output
    }

    /// The text in lower case. `prefix` must be lower case too.
    static func encode(prefix: String, data: Data) -> String {
        let groups = regroup(Array(data), from: 8, to: 5, pad: true) ?? []
        let residue = polymod(expand(prefix) + groups + [0, 0, 0, 0, 0, 0]) ^ 1
        let checksum = (0..<6).map { UInt8((residue >> UInt32(5 * (5 - $0))) & 31) }
        let characters = (groups + checksum).map { alphabet[Int($0)] }
        return prefix + "1" + String(decoding: characters, as: UTF8.self)
    }

    /// The prefix in lower case and the bytes, or nil for anything that is not valid Bech32.
    static func decode(_ text: String) -> (prefix: String, data: Data)? {
        guard text.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { return nil }
        let lower = text.lowercased()
        // Mixed case is an error, so a mistyped key is not silently accepted.
        guard text == lower || text == text.uppercased() else { return nil }
        guard let separator = lower.lastIndex(of: "1") else { return nil }
        let prefix = String(lower[..<separator])
        let rest = Array(lower[lower.index(after: separator)...].utf8)
        guard !prefix.isEmpty, rest.count >= 6 else { return nil }
        var groups: [UInt8] = []
        for character in rest {
            guard let value = values[character] else { return nil }
            groups.append(value)
        }
        guard polymod(expand(prefix) + groups) == 1 else { return nil }
        guard let bytes = regroup(Array(groups.dropLast(6)), from: 5, to: 8, pad: false) else { return nil }
        return (prefix, Data(bytes))
    }
}
