import Foundation

/// Messages that change the playing preset piece by piece, without sending it whole.
///
/// Effect names in these messages use a prefixed string, `len, A0+len, bytes`, unlike the plain `A0+len` strings
/// inside presets. Each message may end in an input byte, 0 for the guitar input, which newer amps want and older
/// community code leaves out. See the README for what has been checked on the Spark MINI.
public extension SparkProtocol {
    /// Sets parameter `index` of `effect` to `value` (0 to 1). The amp sends no acknowledgement.
    static func setParameter(effect: String, index: UInt8, value: Float, input: Bool = true, sequence: UInt8,
                             header: Bool = true) -> [UInt8] {
        var writer = SparkWriter()
        writer.prefixedString(effect)
        writer.bytes([index])
        writer.float(value)
        if input { writer.bytes([0x00]) }
        return frame(command: Command.set, sub: Sub.parameter, payload: writer.data, sequence: sequence,
                     header: header)
    }

    /// Switches `effect` on or off. The amp acknowledges with `04 15`.
    static func setEffect(_ effect: String, on: Bool, input: Bool = true, sequence: UInt8,
                          header: Bool = true) -> [UInt8] {
        var writer = SparkWriter()
        writer.prefixedString(effect)
        writer.bool(on)
        if input { writer.bytes([0x00]) }
        return frame(command: Command.set, sub: Sub.effectOnOff, payload: writer.data, sequence: sequence,
                     header: header)
    }

    /// Replaces model `old` by model `new` in its place of the chain. The amp acknowledges with `04 06`.
    static func changeModel(from old: String, to new: String, input: Bool = true, sequence: UInt8,
                            header: Bool = true) -> [UInt8] {
        var writer = SparkWriter()
        writer.prefixedString(old)
        writer.prefixedString(new)
        if input { writer.bytes([0x00]) }
        return frame(command: Command.set, sub: Sub.changeEffect, payload: writer.data, sequence: sequence,
                     header: header)
    }
}

extension SparkWriter {
    /// `len, A0+len, bytes`, the string form used for effect names in commands. Model ids are short ASCII.
    mutating func prefixedString(_ text: String) {
        let bytes = Array(text.utf8.prefix(31))
        self.bytes([UInt8(bytes.count), 0xA0 + UInt8(bytes.count)] + bytes)
    }
}

extension SparkReader {
    /// Reads `len, A0+len, bytes` or a plain string.
    mutating func prefixedString() throws -> String {
        let start = position
        let first = try byte()
        if first < 0x80 {
            let text = try string()
            guard text.utf8.count == Int(first) else {
                throw SparkDecodeError.unexpected(byte: first, at: start, expected: "the string's length")
            }
            return text
        }
        position = start
        return try string()
    }
}
