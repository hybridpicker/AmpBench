import XCTest
@testable import SparkControl

/// A REACTOR preset built from scratch in the layout read on 2026-11-10, never a real one.
enum ReactorFixture {
    static func string(_ text: String) -> [UInt8] { [0xA0 + UInt8(text.utf8.count)] + Array(text.utf8) }
    static func half(_ value: Float) -> [UInt8] {
        let bits = Float16(value).bitPattern
        return [0xCD, UInt8(bits >> 8), UInt8(bits & 0xFF)]
    }
    static func card(_ name: String, icon: String, tags: [String]) -> [UInt8] {
        [0xC4, 0x10] + [UInt8](repeating: 0xAB, count: 16) + string(name) + string("1.0") + string("") + string(icon)
            + [0x01, 0x90 + UInt8(tags.count)] + tags.flatMap(string)
    }
    static func block(_ id: UInt16, on: Bool, _ values: [Float]) -> [UInt8] {
        let count: [UInt8] = values.count < 16 ? [0x90 + UInt8(values.count)]
            : [0xDC, UInt8(values.count >> 8), UInt8(values.count & 0xFF)]
        return [0xC4, 0x02, UInt8(id >> 8), UInt8(id & 0xFF), on ? 0xC3 : 0xC2] + count
            + values.flatMap { $0 == 0 ? [UInt8(0)] : half($0) }
    }
    /// Long enough for three chunks, like the real ones.
    static func preset(slot: Int, name: String, amp: String, effectsOn: Int = 2) -> [UInt8] {
        let fixed: [(UInt16, Int)] = [(0x0502, 145), (0x0503, 4), (0x0505, 110), (0x0506, 11), (0x0434, 30), (0x0435, 30)]
        var data: [UInt8] = [0x00, UInt8(slot)] + card(name, icon: "icon.png", tags: ["clean", "test"])
        data += [0xCA, 0x42, 0xF0, 0x00, 0x00] + card(amp, icon: "f_amp_Test.png", tags: [])
        data += [0x96] + fixed.flatMap { id, count in block(id, on: true, (0..<count).map { $0 % 3 == 0 ? 0 : 0.5 }) }
        data += [0x9A] + (0..<10).flatMap { block(0x0409 + UInt16($0), on: $0 < effectsOn, [0.25, 1, 0]) }
        return data + [0x12, 0x34, 0x56, 0x78]
    }
}

final class ReactorPresetTests: XCTestCase {
    func testReadsNamesTempoAndBlocks() throws {
        let preset = try ReactorPreset(data: ReactorFixture.preset(slot: 5, name: "Bright Clean", amp: "Twin Clean"))
        XCTAssertEqual(preset.slot, 5)
        XCTAssertEqual(preset.name, "Bright Clean")
        XCTAssertEqual(preset.preset.tags, ["clean", "test"])
        XCTAssertEqual(preset.tempo, 120)
        XCTAssertEqual(preset.ampName, "Twin Clean")
        XCTAssertEqual(preset.amp.icon, "f_amp_Test.png")
        XCTAssertEqual(preset.fixed.map(\.id), [0x0502, 0x0503, 0x0505, 0x0506, 0x0434, 0x0435])
        XCTAssertEqual(preset.fixed.map(\.values.count), [145, 4, 110, 11, 30, 30])
        XCTAssertEqual(preset.fixed[1].values, [0, 0.5, 0.5, 0])
        XCTAssertEqual(preset.effects.count, 10)
        XCTAssertEqual(preset.effects[0].values, [0.25, 1, 0])
        XCTAssertEqual(preset.summary, "Twin Clean · 2 Effekte an")
        XCTAssertEqual(preset.trailer, [0x12, 0x34, 0x56, 0x78])
    }

    /// The Spark parser leaves one byte of every chunk's 16-bit length in front of the chunk's data.
    func testJoinsWhatTheSparkParserDelivers() throws {
        let data = ReactorFixture.preset(slot: 0, name: "A", amp: "B")
        XCTAssertGreaterThan(data.count, 2 * ReactorPreset.chunkSize)
        var delivered: [UInt8] = []
        for start in stride(from: 0, to: data.count, by: ReactorPreset.chunkSize) {
            let part = Array(data[start..<min(start + ReactorPreset.chunkSize, data.count)])
            delivered += [UInt8(part.count & 0xFF)] + part
        }
        XCTAssertEqual(ReactorPreset.joined(delivered), data)
        XCTAssertEqual(try ReactorPreset(payload: delivered).name, "A")
    }

    func testDamagedPresetsAreRefused() {
        let data = ReactorFixture.preset(slot: 0, name: "A", amp: "B")
        XCTAssertThrowsError(try ReactorPreset(data: Array(data.dropLast(2))), "trailer too short")
        XCTAssertThrowsError(try ReactorPreset(data: Array(data.prefix(100))))
        XCTAssertThrowsError(try ReactorPreset(data: [0x01] + data.dropFirst()))
        XCTAssertThrowsError(try ReactorPreset(data: []))
    }
}
