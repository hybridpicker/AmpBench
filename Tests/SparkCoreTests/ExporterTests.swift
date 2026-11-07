import AVFoundation
import CryptoKit
import XCTest
@testable import SparkCore

final class ExporterTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var source: URL!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        source = try Synthetic.writeWAV(to: folder.file("original.wav"), seconds: 4, amplitude: 0.1)
    }

    private func checksum(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).description
    }

    func testPlainExportIsSampleIdentical() throws {
        let result = try Exporter.export(source: source, edit: EditList(), format: .wav24, to: folder.file("out.wav"))
        XCTAssertEqual(result.frames, 176_400)
        XCTAssertEqual(try Data(contentsOf: result.url), try Data(contentsOf: source))
    }

    func testOriginalIsNeverChanged() throws {
        let before = try checksum(source)
        let edit = EditList(trimStart: 1, trimEnd: 2, fadeIn: 0.1, fadeOut: 0.1, gainDB: 12)
        _ = try Exporter.export(source: source, edit: edit, format: .wav24, to: folder.file("a.wav"))
        _ = try Exporter.export(source: source, edit: edit, format: .aac(bitRate: 192_000), to: folder.file("a.m4a"))
        XCTAssertEqual(try checksum(source), before)
    }

    func testExportOverOriginalIsRefused() throws {
        let before = try checksum(source)
        XCTAssertThrowsError(try Exporter.export(source: source, edit: EditList(gainDB: 6), format: .wav24, to: source))
        XCTAssertEqual(try checksum(source), before)
    }

    func testExportOverOriginalThroughSymlinkIsRefused() throws {
        let link = folder.file("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try Exporter.export(source: source, edit: EditList(), format: .wav24, to: link))
    }

    func testWavFormatAndLengthAfterTrim() throws {
        let edit = EditList(trimStart: 1, trimEnd: 3)
        let result = try Exporter.export(source: source, edit: edit, format: .wav24, to: folder.file("out.wav"))
        XCTAssertEqual(result.frames, 88_200)
        guard case .ok(let format, let frames) = WAVFile.inspect(result.url) else { return XCTFail("expected ok") }
        XCTAssertEqual(format.bits, 24)
        XCTAssertEqual(format.sampleRate, 44_100)
        XCTAssertEqual(format.channels, 1)
        XCTAssertEqual(frames, 88_200)
    }

    func testGainChangesLevelByExactlyThatMuch() throws {
        let result = try Exporter.export(source: source, edit: EditList(gainDB: 6), format: .wav24, to: folder.file("out.wav"))
        let facts = try readAudio(result.url)
        XCTAssertEqual(dB(facts.peak), dB(0.1) + 6, accuracy: 0.02)
        XCTAssertFalse(result.clipped)
    }

    func testAutoLevelReachesTargetInExport() throws {
        let gain = AutoLevel.gainDB(forPeak: 0.1)
        let edit = EditList(autoLevelEnabled: true, autoLevelDB: gain)
        let result = try Exporter.export(source: source, edit: edit, format: .wav24, to: folder.file("out.wav"))
        XCTAssertEqual(dB(try readAudio(result.url).peak), AutoLevel.targetPeakDB, accuracy: 0.02)
    }

    func testDisabledAutoLevelIsNotApplied() throws {
        let edit = EditList(autoLevelEnabled: false, autoLevelDB: 12)
        let result = try Exporter.export(source: source, edit: edit, format: .wav24, to: folder.file("out.wav"))
        XCTAssertEqual(dB(try readAudio(result.url).peak), dB(0.1), accuracy: 0.02)
    }

    func testFadesAreRendered() throws {
        let edit = EditList(fadeIn: 1, fadeOut: 1)
        let result = try Exporter.export(source: source, edit: edit, format: .wav24, to: folder.file("out.wav"))
        let facts = try readAudio(result.url)
        XCTAssertLessThan(facts.rms(from: 0, to: 2000), 0.001, "starts from silence")
        XCTAssertEqual(facts.rms(from: 80_000, to: 90_000), 0.0707, accuracy: 0.001, "full level in the middle")
        XCTAssertLessThan(facts.rms(from: Int(facts.frames) - 2000), 0.001, "ends in silence")
    }

    func testClippingFromGainIsReportedAndLimited() throws {
        let result = try Exporter.export(source: source, edit: EditList(gainDB: 30), format: .wav24, to: folder.file("out.wav"))
        XCTAssertTrue(result.clipped)
        XCTAssertGreaterThan(result.peak, 1)
        XCTAssertLessThanOrEqual(try readAudio(result.url).peak, 1)
    }

    func testEmptyTrimIsRefusedAndLeavesNoFile() throws {
        let edit = EditList(trimStart: 2, trimEnd: 2)
        XCTAssertThrowsError(try Exporter.export(source: source, edit: edit, format: .wav24, to: folder.file("out.wav")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.file("out.wav").path))
    }

    func testCancelledExportLeavesNoFile() throws {
        XCTAssertThrowsError(try Exporter.export(source: source, edit: EditList(), format: .wav24,
                                                 to: folder.file("out.wav"), isCancelled: { true }))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        XCTAssertEqual(names, ["original.wav"], "no partial or temporary file may remain")
    }

    func testExportReplacesPreviousExport() throws {
        let destination = folder.file("out.wav")
        _ = try Exporter.export(source: source, edit: EditList(trimEnd: 1), format: .wav24, to: destination)
        _ = try Exporter.export(source: source, edit: EditList(trimEnd: 2), format: .wav24, to: destination)
        XCTAssertEqual(try readAudio(destination).frames, 88_200)
    }

    func testAACFormatLengthAndLevel() throws {
        let edit = EditList(trimStart: 1, trimEnd: 3, gainDB: 6)
        let result = try Exporter.export(source: source, edit: edit, format: .aac(bitRate: 192_000), to: folder.file("out.m4a"))
        let facts = try readAudio(result.url)
        XCTAssertEqual(facts.settings["AVFormatIDKey"] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(facts.sampleRate, 44_100)
        XCTAssertEqual(facts.channels, 1)
        XCTAssertEqual(Double(facts.frames) / facts.sampleRate, 2, accuracy: 0.05)
        XCTAssertEqual(dB(facts.rms(from: 20_000, to: 60_000)), dB(0.1 * 0.7071) + 6, accuracy: 0.5)
        XCTAssertEqual(facts.frequency(from: 20_000, to: 60_000), 1000, accuracy: 10)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int)
        XCTAssertLessThan(size, 88_200 * 3 / 2, "AAC must be much smaller than the WAV")
    }

    func testAACOfHighSampleRateFallsBackToSupportedRate() throws {
        let high = try Synthetic.writeWAV(to: folder.file("high.wav"), seconds: 1, sampleRate: 96_000, channels: 2)
        let result = try Exporter.export(source: high, edit: EditList(), format: .aac(bitRate: 256_000), to: folder.file("out.m4a"))
        let facts = try readAudio(result.url)
        XCTAssertEqual(facts.sampleRate, 48_000)
        XCTAssertEqual(facts.channels, 2)
        XCTAssertEqual(Double(facts.frames) / facts.sampleRate, 1, accuracy: 0.05)
    }

    func testStereoExportStaysStereo() throws {
        let stereo = try Synthetic.writeWAV(to: folder.file("stereo.wav"), seconds: 1, channels: 2)
        let result = try Exporter.export(source: stereo, edit: EditList(gainDB: 3), format: .wav24, to: folder.file("out.wav"))
        let facts = try readAudio(result.url)
        XCTAssertEqual(facts.channels, 2)
        XCTAssertEqual(facts.frames, 44_100)
    }
}
