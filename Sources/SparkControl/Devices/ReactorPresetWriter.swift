import AmpText
import Foundation

extension ReactorPreset {
    /// How a value is written: a zero as one byte, everything else as a half float, as the REACTOR does itself.
    static func encoded(_ value: Float) -> [UInt8] {
        guard value != 0 else { return [0x00] }
        let bits = Float16(value).bitPattern
        return [0xCD, UInt8(bits >> 8), UInt8(bits & 0xFF)]
    }

    static func encoded(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8.prefix(255))
        return (bytes.count < 32 ? [0xA0 | UInt8(bytes.count)] : [0xD9, UInt8(bytes.count)]) + bytes
    }

    /// The preset's bytes for a slot with another name, tempo, switches and values, for `01 01`. Only what differs
    /// is written anew, everything else stays byte for byte as the REACTOR sent it, and the checksum is recomputed:
    /// an unchanged preset comes out exactly as it was read. The blocks must be the preset's own, in their order,
    /// with as many values; a model cannot be changed this way.
    public func rewritten(slot: Int, name: String? = nil, tempo: Float? = nil, fixed: [Block]? = nil,
                          effects: [Block]? = nil) throws -> [UInt8] {
        guard (0..<8).contains(slot) else { throw Unreadable(text: tr("no slot at the start")) }
        let newFixed = fixed ?? self.fixed, newEffects = effects ?? self.effects
        guard newFixed.count == self.fixed.count, newEffects.count == self.effects.count else {
            throw Unreadable(text: tr("the blocks do not fit the preset"))
        }
        var patches: [(range: Range<Int>, bytes: [UInt8])] = []
        var reader = Reader(data)
        _ = try reader.byte()
        _ = try reader.byte()
        _ = try reader.binary()
        let nameStart = reader.index
        let oldName = try reader.string()
        if let name, name != oldName { patches.append((nameStart..<reader.index, Self.encoded(name))) }
        for _ in 0..<3 { _ = try reader.string() }
        _ = try reader.number()
        for _ in 0..<(try reader.count()) { _ = try reader.string() }
        let tempoStart = reader.index
        let oldTempo = try reader.number()
        if let tempo, tempo != oldTempo {
            let bits = tempo.bitPattern
            patches.append((tempoStart..<reader.index, [0xCA, UInt8(bits >> 24), UInt8(bits >> 16 & 0xFF),
                                                        UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]))
        }
        _ = try reader.card()
        for blocks in [newFixed, newEffects] {
            guard try reader.count() == blocks.count else { throw Unreadable(text: tr("the blocks do not fit the preset")) }
            for block in blocks {
                let id = try reader.binary()
                guard id.count == 2, UInt16(id[0]) << 8 | UInt16(id[1]) == block.id else {
                    throw Unreadable(text: tr("the blocks do not fit the preset"))
                }
                let flagAt = reader.index
                let wasOn = try reader.byte() == 0xC3
                if wasOn != block.isOn { patches.append((flagAt..<flagAt + 1, [block.isOn ? 0xC3 : 0xC2])) }
                guard try reader.count() == block.values.count else {
                    throw Unreadable(text: tr("the blocks do not fit the preset"))
                }
                for value in block.values {
                    let start = reader.index
                    let old = try reader.number()
                    if old != value, Self.encoded(old) != Self.encoded(value) {
                        patches.append((start..<reader.index, Self.encoded(value)))
                    }
                }
            }
        }
        var out = data
        for patch in patches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(patch.range, with: patch.bytes)
        }
        guard out.count >= 6 else { throw Unreadable(text: tr("too short")) }
        out[0] = 0
        out[1] = UInt8(slot)
        out.replaceSubrange((out.count - 4)..., with: Self.checksum(of: out[2..<(out.count - 4)]))
        return out
    }

    /// The messages that store the preset's bytes: chunks of `chunkSize` with the REACTOR's four-byte header (count,
    /// number, length in 16 bits), each a frame `01 01` without a block header. Written and read back on a REACTOR 50
    /// on 2026-11-11; it acknowledges every chunk with `04 01`.
    public static func storeFrames(_ data: [UInt8], sequence: UInt8) -> [[UInt8]] {
        let parts = stride(from: 0, to: data.count, by: chunkSize).map { Array(data[$0..<min($0 + chunkSize, data.count)]) }
        return parts.enumerated().map { number, part in
            let raw = [UInt8(parts.count), UInt8(number), UInt8(part.count >> 8), UInt8(part.count & 0xFF)] + part
            let packed = SparkProtocol.pack7(raw)
            return [0xF0, 0x01, sequence & 0x7F, packed.reduce(UInt8(0), ^), SparkProtocol.Command.set,
                    SparkProtocol.Sub.preset] + packed + [0xF7]
        }
    }
}
