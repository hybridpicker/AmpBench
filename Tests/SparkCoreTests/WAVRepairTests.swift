import XCTest
@testable import SparkCore

final class WAVRepairTests: XCTestCase {
    private var folder: TemporaryFolder!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
    }

    private func audioBytes(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        return data.subdata(in: 44..<data.count)
    }

    func testFinalizedFileIsHealthy() throws {
        let url = try Synthetic.writeWAV(to: folder.file("ok.wav"), seconds: 0.5)
        guard case .ok(let format, let frames) = WAVFile.inspect(url) else { return XCTFail("expected ok") }
        XCTAssertEqual(format.sampleRate, 44_100)
        XCTAssertEqual(format.channels, 1)
        XCTAssertEqual(format.bits, 24)
        XCTAssertEqual(frames, 22_050)
    }

    func testZeroSizedHeaderNeedsRepair() throws {
        let url = folder.file("crash.wav")
        try Synthetic.rawWAV(frames: 1000, declaredData: 0).write(to: url)
        guard case .needsRepair(_, let frames) = WAVFile.inspect(url) else { return XCTFail("expected needsRepair") }
        XCTAssertEqual(frames, 1000)
    }

    func testSizeBeyondEndOfFileNeedsRepair() throws {
        let url = folder.file("crash.wav")
        try Synthetic.rawWAV(frames: 1000, declaredData: 0xFFFF_FFFF, declaredRIFF: 0xFFFF_FFFF).write(to: url)
        guard case .needsRepair = WAVFile.inspect(url) else { return XCTFail("expected needsRepair") }
    }

    func testRepairMakesFileReadableAndKeepsEveryAudioByte() throws {
        let url = folder.file("crash.wav")
        try Synthetic.rawWAV(frames: 2000, channels: 2, declaredData: 0).write(to: url)
        let before = try audioBytes(url)

        XCTAssertEqual(try WAVFile.repair(url), 2000)

        XCTAssertEqual(try audioBytes(url), before)
        guard case .ok(_, let frames) = WAVFile.inspect(url) else { return XCTFail("expected ok") }
        XCTAssertEqual(frames, 2000)
        XCTAssertEqual(try readAudio(url).frames, 2000, "the system audio reader must accept the repaired file")
    }

    func testRepairCutsPartialFrameOnly() throws {
        let url = folder.file("crash.wav")
        // 1000 stereo frames plus 4 bytes of a frame that was never completed.
        try Synthetic.rawWAV(frames: 1000, channels: 2, declaredData: 0, extraBytes: 4).write(to: url)
        XCTAssertEqual(try WAVFile.repair(url), 1000)
        XCTAssertEqual(try Data(contentsOf: url).count, 44 + 6000)
    }

    func testRepairOfOddMonoDataAddsPadByteAndStaysReadable() throws {
        let url = folder.file("crash.wav")
        try Synthetic.rawWAV(frames: 1001, declaredData: 0).write(to: url)
        XCTAssertEqual(try WAVFile.repair(url), 1001)
        XCTAssertEqual(try Data(contentsOf: url).count, 44 + 3003 + 1)
        guard case .ok(_, let frames) = WAVFile.inspect(url) else { return XCTFail("expected ok") }
        XCTAssertEqual(frames, 1001)
        XCTAssertEqual(try readAudio(url).frames, 1001)
    }

    func testRepairIsRepeatable() throws {
        let url = folder.file("crash.wav")
        try Synthetic.rawWAV(frames: 500, declaredData: 0).write(to: url)
        try WAVFile.repair(url)
        let first = try Data(contentsOf: url)
        try WAVFile.repair(url)
        XCTAssertEqual(try Data(contentsOf: url), first)
    }

    func testRepairLeavesFinalizedFileAlone() throws {
        let url = try Synthetic.writeWAV(to: folder.file("ok.wav"), seconds: 0.2)
        let before = try Data(contentsOf: url)
        try WAVFile.repair(url)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testInterruptedFileWithPlausibleHeaderRecoversTrailingAudio() throws {
        // A writer can have updated the header earlier, with more audio written since.
        let url = folder.file("crash.wav")
        try Synthetic.rawWAV(frames: 1000, declaredData: 300).write(to: url)
        XCTAssertEqual(try WAVFile.repair(url, treatTrailingDataAsAudio: true), 1000)
        guard case .ok(_, let frames) = WAVFile.inspect(url) else { return XCTFail("expected ok") }
        XCTAssertEqual(frames, 1000)
    }

    func testFileWithoutAudioIsEmpty() throws {
        let url = folder.file("empty.wav")
        try Synthetic.rawWAV(frames: 0, declaredData: 0).write(to: url)
        guard case .empty = WAVFile.inspect(url) else { return XCTFail("expected empty") }
    }

    func testGarbageIsReportedNotRepaired() throws {
        let url = folder.file("garbage.wav")
        let garbage = Data(repeating: 0x41, count: 500)
        try garbage.write(to: url)
        guard case .unreadable = WAVFile.inspect(url) else { return XCTFail("expected unreadable") }
        XCTAssertThrowsError(try WAVFile.repair(url))
        XCTAssertEqual(try Data(contentsOf: url), garbage, "a file that cannot be repaired stays as it is")
    }

    func testTruncatedHeaderIsReported() throws {
        let url = folder.file("short.wav")
        try Data("RIFF".utf8).write(to: url)
        guard case .unreadable = WAVFile.inspect(url) else { return XCTFail("expected unreadable") }
    }
}
