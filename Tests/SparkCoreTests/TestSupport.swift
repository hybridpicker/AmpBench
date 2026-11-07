import AVFoundation
import Foundation
import XCTest
@testable import SparkCore

/// All audio in the tests is generated here. No test reads a real recording.
enum Synthetic {
    static func sine(seconds: Double, frequency: Double = 1000, amplitude: Float = 0.5, sampleRate: Double = 44_100,
                     channels: Int = 1) -> [Float] {
        let frames = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<channels { samples[frame * channels + channel] = value }
        }
        return samples
    }

    @discardableResult
    static func writeWAV(to url: URL, seconds: Double = 1, frequency: Double = 1000, amplitude: Float = 0.5,
                         sampleRate: Double = 44_100, channels: Int = 1) throws -> URL {
        try WAVWriter.write(
            samples: sine(seconds: seconds, frequency: frequency, amplitude: amplitude, sampleRate: sampleRate,
                          channels: channels),
            sampleRate: sampleRate, channels: channels, to: url)
        return url
    }

    /// A WAV file with exactly the given header sizes, like one left behind by a crash.
    static func rawWAV(frames: Int, channels: Int = 1, declaredData: UInt32, declaredRIFF: UInt32? = nil,
                       extraBytes: Int = 0) -> Data {
        let bytesPerFrame = channels * 3
        var data = Data("RIFF".utf8)
        data.append(le32(declaredRIFF ?? declaredData &+ 36))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        data.append(le32(16))
        data.append(le16(1))
        data.append(le16(UInt16(channels)))
        data.append(le32(44_100))
        data.append(le32(UInt32(44_100 * bytesPerFrame)))
        data.append(le16(UInt16(bytesPerFrame)))
        data.append(le16(24))
        data.append(Data("data".utf8))
        data.append(le32(declaredData))
        for frame in 0..<(frames * channels) {
            // A recognizable ramp, so tests can prove the audio bytes survive repair unchanged.
            let value = Int32(frame % 1000) * 1000
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
        }
        data.append(Data(repeating: 0x55, count: extraBytes))
        return data
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

struct AudioFacts {
    let frames: Int64
    let sampleRate: Double
    let channels: Int
    let peak: Float
    let samples: [Float]
    let settings: [String: Any]

    /// Dominant frequency from zero crossings. Enough for pure test tones.
    func frequency(from start: Int = 0, to end: Int? = nil) -> Double {
        let end = end ?? samples.count
        guard end - start > 2 else { return 0 }
        var crossings = 0
        for index in (start + 1)..<end where samples[index - 1] < 0 && samples[index] >= 0 {
            crossings += 1
        }
        return Double(crossings) * sampleRate / Double(end - start)
    }

    func rms(from start: Int = 0, to end: Int? = nil) -> Float {
        let slice = samples[start..<(end ?? samples.count)]
        guard !slice.isEmpty else { return 0 }
        return sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
    }
}

func readAudio(_ url: URL) throws -> AudioFacts {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    var collected: [Float] = []
    collected.reserveCapacity(Int(file.length))
    var peak: Float = 0
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536)!
    while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: 65_536)
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
        for frame in 0..<Int(buffer.frameLength) {
            collected.append(channels[0][frame])
            for channel in 0..<Int(format.channelCount) { peak = max(peak, abs(channels[channel][frame])) }
        }
    }
    return AudioFacts(frames: file.length, sampleRate: file.fileFormat.sampleRate,
                      channels: Int(file.fileFormat.channelCount), peak: peak, samples: collected,
                      settings: file.fileFormat.settings)
}

func dB(_ linear: Float) -> Double { 20 * log10(Double(max(linear, 1e-9))) }

/// A throwaway folder that disappears after the test. Nothing touches the real library folder.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// Moves "trashed" files to a folder inside the test folder, leaving the real Trash alone.
final class FakeTrash: Trasher {
    let folder: URL

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func trash(_ url: URL) throws -> URL {
        let destination = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}
