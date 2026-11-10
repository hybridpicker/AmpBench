import AmpText
import AVFoundation
import AudioToolbox
import Foundation

public enum ExportFormat: Equatable, Sendable {
    case wav24
    case aac(bitRate: Int)

    public var fileExtension: String {
        switch self {
        case .wav24: return "wav"
        case .aac: return "m4a"
        }
    }

    public var label: String {
        switch self {
        case .wav24: return tr("WAV, 24-bit")
        case .aac(let bitRate): return "AAC, \(bitRate / 1000) kbit/s"
        }
    }
}

public struct ExportResult: Sendable {
    public let url: URL
    public let frames: Int64
    /// Peak after edits, before limiting to full scale.
    public let peak: Float
    /// Samples beyond full scale were cut off because of the chosen gain.
    public let clipped: Bool
}

public enum ExportError: LocalizedError {
    case sameAsOriginal
    case emptySelection
    case coreAudio(step: String, status: OSStatus)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .sameAsOriginal: return tr("The export must not replace the original recording. Choose another name.")
        case .emptySelection: return tr("Nothing is left after trimming.")
        case .coreAudio(let step, let status): return tr("%@ failed (error %d).", step, Int(status))
        case .cancelled: return tr("The export was canceled.")
        }
    }
}

/// Renders a recording and its edits into a new file. The original is only ever read.
public enum Exporter {
    private static let chunkFrames: AVAudioFrameCount = 32_768
    private static let aacMaxRate = 48_000.0

    public static func export(source: URL, edit: EditList, format: ExportFormat, to destination: URL,
                              progress: (@Sendable (Double) -> Void)? = nil,
                              isCancelled: @Sendable () -> Bool = { false }) throws -> ExportResult {
        if source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() {
            throw ExportError.sameAsOriginal
        }
        let input = try AVAudioFile(forReading: source)
        let processing = input.processingFormat
        let renderer = EditRenderer(edit: edit, sampleRate: processing.sampleRate, totalFrames: input.length)
        guard renderer.lengthFrames > 0 else { throw ExportError.emptySelection }

        let channels = processing.channelCount
        var fileFormat: AudioStreamBasicDescription
        let fileType: AudioFileTypeID
        switch format {
        case .wav24:
            fileType = kAudioFileWAVEType
            fileFormat = AudioStreamBasicDescription(
                mSampleRate: processing.sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: channels * 3,
                mFramesPerPacket: 1,
                mBytesPerFrame: channels * 3,
                mChannelsPerFrame: channels,
                mBitsPerChannel: 24,
                mReserved: 0
            )
        case .aac:
            fileType = kAudioFileM4AType
            fileFormat = AudioStreamBasicDescription(
                mSampleRate: min(processing.sampleRate, aacMaxRate),
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 1024,
                mBytesPerFrame: 0,
                mChannelsPerFrame: min(channels, 2),
                mBitsPerChannel: 0,
                mReserved: 0
            )
        }

        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        var created: ExtAudioFileRef?
        try check(tr("Creating the file"), ExtAudioFileCreateWithURL(
            temporary as CFURL, fileType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &created))
        guard let output = created else { throw ExportError.coreAudio(step: tr("Creating the file"), status: -1) }
        var outputOpen = true
        defer { if outputOpen { ExtAudioFileDispose(output) } }

        var client = CaptureEngine.clientFormat(rate: processing.sampleRate, channels: channels)
        if case .aac(let bitRate) = format, channels > 2 {
            // AAC here is at most stereo, so wider sources are reduced by the file's converter channel map.
            _ = bitRate
            client = CaptureEngine.clientFormat(rate: processing.sampleRate, channels: 2)
        }
        try check(tr("Setting the file format"), ExtAudioFileSetProperty(
            output, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))
        if case .aac(let bitRate) = format { try setBitRate(bitRate, on: output) }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: chunkFrames) else {
            throw ExportError.coreAudio(step: tr("Creating the buffer"), status: -1)
        }
        let outChannels = Int(client.mChannelsPerFrame)
        var interleaved = [Float](repeating: 0, count: Int(chunkFrames) * outChannels)
        var peak: Float = 0
        var clipped = false
        var position = renderer.startFrame
        input.framePosition = position
        var written: Int64 = 0

        while position < renderer.endFrame {
            if isCancelled() { throw ExportError.cancelled }
            let wanted = AVAudioFrameCount(min(Int64(chunkFrames), renderer.endFrame - position))
            try input.read(into: buffer, frameCount: wanted)
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            for channel in 0..<Int(processing.channelCount) {
                renderer.apply(to: data[channel], count: count, firstFrame: position)
            }
            for frame in 0..<count {
                for channel in 0..<outChannels {
                    var sample = data[channel][frame]
                    let magnitude = abs(sample)
                    if magnitude > peak { peak = magnitude }
                    if magnitude > 1 {
                        clipped = true
                        sample = sample > 0 ? 1 : -1
                    }
                    interleaved[frame * outChannels + channel] = sample
                }
            }
            let status = interleaved.withUnsafeMutableBytes { bytes -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(outChannels),
                                          mDataByteSize: UInt32(count * outChannels * MemoryLayout<Float>.size),
                                          mData: bytes.baseAddress)
                )
                return ExtAudioFileWrite(output, UInt32(count), &list)
            }
            try check(tr("Writing the file"), status)
            position += Int64(count)
            written += Int64(count)
            progress?(Double(written) / Double(renderer.lengthFrames))
        }
        try check(tr("Finishing the file"), ExtAudioFileDispose(output))
        outputOpen = false

        // The finished file appears in one step, so a failed export never leaves a partial file behind.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return ExportResult(url: destination, frames: written, peak: peak, clipped: clipped)
    }

    private static func setBitRate(_ bitRate: Int, on file: ExtAudioFileRef) throws {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try check(tr("Reading the encoder"), ExtAudioFileGetProperty(
            file, kExtAudioFileProperty_AudioConverter, &size, &converter))
        guard let converter else { return }
        var rate = UInt32(bitRate)
        try check(tr("Setting the bit rate"), AudioConverterSetProperty(
            converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate))
        var config: CFArray?
        try check(tr("Applying the bit rate"), ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFArray?>.size), &config))
    }

    private static func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw ExportError.coreAudio(step: step, status: status) }
    }
}
