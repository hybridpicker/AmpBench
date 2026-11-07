import XCTest
@testable import SparkControl

final class SparkProtocolTests: XCTestCase {
    func testPackingRoundTrip() {
        let data: [UInt8] = (0...40).map { UInt8(($0 * 37) & 0xFF) }
        let packed = SparkProtocol.pack7(data)
        XCTAssertTrue(packed.allSatisfy { $0 < 0x80 })
        XCTAssertEqual(SparkProtocol.unpack7(packed), data)
    }

    func testPackingPutsHighBitsFirst() {
        XCTAssertEqual(SparkProtocol.pack7([0x80, 0x01, 0xFF]), [0b101, 0x00, 0x01, 0x7F])
    }

    func testHardwarePresetMessage() {
        let message = SparkProtocol.changeHardwarePreset(slot: 2, sequence: 5)
        XCTAssertEqual(Array(message[0..<16]),
                       [0x01, 0xFE, 0x00, 0x00, 0x53, 0xFE, UInt8(message.count)] + [UInt8](repeating: 0, count: 9))
        XCTAssertEqual(Array(message[16...]), [0xF0, 0x01, 0x05, 0x02, 0x01, 0x38, 0x00, 0x00, 0x02, 0xF7])
        XCTAssertEqual(SparkProtocol.changeHardwarePreset(slot: 2, sequence: 5, header: false), Array(message[16...]))
    }

    func testParserReadsMessagesSplitAcrossNotifications() {
        let bytes = SparkProtocol.frame(command: 0x03, sub: 0x2F, payload: [0xCE, 0, 7, 0x80, 3], sequence: 9)
        let parser = SparkProtocol.Parser()
        let first = parser.feed(Array(bytes[0..<20]))
        let rest = parser.feed(Array(bytes[20...]))
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest[0].payload, [0xCE, 0, 7, 0x80, 3])
        XCTAssertTrue(rest[0].checksumOK)
        XCTAssertEqual(SparkValues.firmware(rest[0].payload), "0.7.128.3")
    }

    func testMultiChunkPresetIsJoined() throws {
        let preset = Synthetic.presetPayload()
        XCTAssertGreaterThan(preset.count, SparkProtocol.chunkCapacity)
        let bytes = SparkProtocol.frame(command: 0x03, sub: 0x01, payload: preset, sequence: 1, header: false)
        let messages = SparkProtocol.Parser().feed(bytes)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].payload, preset)

        let decoded = try SparkPreset(payload: messages[0].payload)
        XCTAssertEqual(decoded.name, "Test Clean")
        XCTAssertEqual(decoded.bpm, 120)
        XCTAssertEqual(decoded.effects.map(\.name), ["bias.noisegate", "Twin"])
        XCTAssertEqual(decoded.effects.map(\.isOn), [false, true])
        XCTAssertEqual(decoded.effects[1].parameters.map(\.value), [0.5, 0.25])
    }

    func testPresetEncodesBackToTheSameBytes() throws {
        let payload = Synthetic.presetPayload()
        let preset = try SparkPreset(payload: payload)
        XCTAssertEqual(preset.encode(place: .slot(2)), payload)
        XCTAssertEqual(Array(preset.encode(place: .temporary).prefix(2)), [0x00, 0x7F])
        let json = try JSONEncoder().encode(preset)
        XCTAssertEqual(try JSONDecoder().decode(SparkPreset.self, from: json), preset)
    }

    func testPresetIsSentInChunksOf25BytesWithAHeaderEach() throws {
        let preset = try SparkPreset(payload: Synthetic.presetPayload())
        let payload = preset.encode(place: .temporary)
        let blocks = SparkProtocol.sendPreset(preset, to: .temporary, sequence: 3)
        XCTAssertTrue(blocks.allSatisfy { $0.count == Int($0[6]) })
        let bytes = blocks.flatMap { $0 }

        var chunks: [[UInt8]] = []
        var index = 0
        while index < bytes.count {
            XCTAssertEqual(Array(bytes[index..<(index + 6)]), [0x01, 0xFE, 0x00, 0x00, 0x53, 0xFE])
            let length = Int(bytes[index + 6])
            let chunk = Array(bytes[(index + 16)..<(index + length)])
            XCTAssertEqual(chunk.first, 0xF0)
            XCTAssertEqual(chunk.last, 0xF7)
            chunks.append(SparkProtocol.unpack7(Array(chunk[6..<(chunk.count - 1)])))
            index += length
        }
        let count = (payload.count + 24) / 25
        XCTAssertEqual(chunks.count, count)
        for (number, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk[0], UInt8(count))
            XCTAssertEqual(chunk[1], UInt8(number))
            XCTAssertEqual(Int(chunk[2]), chunk.count - 3)
            XCTAssertLessThanOrEqual(chunk.count - 3, 25)
        }
        XCTAssertEqual(chunks.flatMap { $0.dropFirst(3) }, payload)
    }

    func testAmpNameWithLengthPrefix() {
        XCTAssertEqual(SparkValues.string([0x0A, 0xAA] + Array("Spark MINI".utf8)), "Spark MINI")
    }

    func testBrokenPresetReportsWhere() {
        XCTAssertThrowsError(try SparkPreset(payload: [0x00, 0x01, 0x42])) { error in
            XCTAssertEqual("\(error)", "byte 2 is 0x42, expected a string")
        }
    }
}

/// Presets for the tests are built here from made-up values.
enum Synthetic {
    static func string(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return bytes.count < 32 ? [0xA0 + UInt8(bytes.count)] + bytes : [0xD9, UInt8(bytes.count)] + bytes
    }

    static func float(_ value: Float) -> [UInt8] {
        let raw = value.bitPattern
        return [0xCA, UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
    }

    static func presetPayload() -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0x02]
        bytes += string("00000000-1111-2222-3333-444444444444")
        bytes += string("Test Clean") + string("0.7") + string("A synthetic preset for the parser tests")
        bytes += string("icon.png") + float(120) + [0x92]
        bytes += string("bias.noisegate") + [0xC2, 0x91, 0x00, 0x91] + float(0.1)
        bytes += string("Twin") + [0xC3, 0x92, 0x00, 0x91] + float(0.5) + [0x01, 0x91] + float(0.25)
        return bytes + [0x00]
    }
}
