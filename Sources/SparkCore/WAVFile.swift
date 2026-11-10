import AmpText
import Foundation

/// Reads WAV headers and repairs files whose sizes were never finalized, such as after a crash or power loss.
///
/// Repair only changes header size fields and cuts a trailing partial frame. Audio data is never rewritten.
public enum WAVFile {
    public struct Format: Equatable, Sendable {
        public let sampleRate: Double
        public let channels: Int
        public let bits: Int
        public var bytesPerFrame: Int { channels * ((bits + 7) / 8) }
    }

    public enum Health: Equatable, Sendable {
        case ok(format: Format, frames: Int64)
        /// The audio is intact but the header sizes are wrong.
        case needsRepair(format: Format, frames: Int64)
        /// Valid header but no audio at all.
        case empty(format: Format)
        case unreadable(String)
    }

    private struct Layout {
        var format: Format?
        var riffSizeOffset: UInt64 = 4
        var dataSizeOffset: UInt64?
        var dataStart: UInt64?
        var declaredData: UInt64 = 0
        var fileSize: UInt64 = 0
        var isRF64 = false
    }

    private static func readLayout(_ handle: FileHandle) throws -> Layout {
        var layout = Layout()
        layout.fileSize = try handle.seekToEnd()
        guard layout.fileSize >= 12 else { throw WAVError.tooShort }
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 12), header.count == 12 else { throw WAVError.tooShort }
        let magic = String(decoding: header[0..<4], as: UTF8.self)
        guard magic == "RIFF" || magic == "RF64", String(decoding: header[8..<12], as: UTF8.self) == "WAVE" else {
            throw WAVError.notWAV
        }
        layout.isRF64 = magic == "RF64"

        var offset: UInt64 = 12
        while offset + 8 <= layout.fileSize {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { break }
            let id = String(decoding: chunk[0..<4], as: UTF8.self)
            let size = UInt64(chunk.littleEndianUInt32(at: 4))
            if id == "fmt " {
                guard let body = try handle.read(upToCount: 16), body.count == 16 else { throw WAVError.tooShort }
                layout.format = Format(
                    sampleRate: Double(body.littleEndianUInt32(at: 4)),
                    channels: Int(body.littleEndianUInt16(at: 2)),
                    bits: Int(body.littleEndianUInt16(at: 14))
                )
            } else if id == "data" {
                layout.dataSizeOffset = offset + 4
                layout.dataStart = offset + 8
                layout.declaredData = size
                break
            }
            offset += 8 + size + (size & 1)
        }
        return layout
    }

    public static func inspect(_ url: URL) -> Health {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let layout = try readLayout(handle)
            guard let format = layout.format, format.channels > 0, format.bytesPerFrame > 0, format.sampleRate > 0 else {
                return .unreadable(tr("The file's format cannot be read."))
            }
            guard let dataStart = layout.dataStart else { return .unreadable(tr("The file contains no audio data.")) }
            let available = layout.fileSize - dataStart
            let bytesPerFrame = UInt64(format.bytesPerFrame)
            let frames = Int64(available / bytesPerFrame)
            if layout.isRF64 { return .ok(format: format, frames: frames) }
            if available < bytesPerFrame { return .empty(format: format) }
            // A declared size of zero or beyond the end of the file means the writer never finished.
            let finalized = layout.declaredData > 0 && layout.declaredData <= available
            if finalized {
                return .ok(format: format, frames: Int64(layout.declaredData / bytesPerFrame))
            }
            return .needsRepair(format: format, frames: frames)
        } catch WAVError.notWAV {
            return .unreadable(tr("The file is not a WAV file."))
        } catch WAVError.tooShort {
            return .unreadable(tr("The file is too short."))
        } catch {
            return .unreadable(tr("The file could not be read."))
        }
    }

    /// Fixes the header sizes in place and returns the number of recovered frames.
    ///
    /// With `treatTrailingDataAsAudio`, audio beyond a finalized-looking data chunk is recovered too. Only use that
    /// when the file is known to have been interrupted, because other files can have valid trailing chunks.
    @discardableResult
    public static func repair(_ url: URL, treatTrailingDataAsAudio: Bool = false) throws -> Int64 {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let layout = try readLayout(handle)
        guard let format = layout.format, format.bytesPerFrame > 0,
              let dataStart = layout.dataStart, let dataSizeOffset = layout.dataSizeOffset else {
            throw WAVError.notWAV
        }
        let available = layout.fileSize - dataStart
        let bytesPerFrame = UInt64(format.bytesPerFrame)
        let finalized = layout.declaredData > 0 && layout.declaredData <= available
        if finalized && !treatTrailingDataAsAudio {
            return Int64(layout.declaredData / bytesPerFrame)
        }

        let frames = available / bytesPerFrame
        let dataBytes = frames * bytesPerFrame
        guard dataBytes <= UInt64(UInt32.max) - 64 else { throw WAVError.tooLarge }

        // Cut a partial frame first, then write sizes that match. A second crash here leaves a repairable file.
        let end = dataStart + dataBytes
        var finalSize = end
        if dataBytes & 1 == 1 {
            // Chunks are word aligned. Mono 24-bit data can end on an odd byte, so a pad byte follows.
            try handle.truncate(atOffset: end)
            try handle.seek(toOffset: end)
            try handle.write(contentsOf: Data([0]))
            finalSize = end + 1
        } else {
            try handle.truncate(atOffset: end)
        }
        try handle.seek(toOffset: dataSizeOffset)
        try handle.write(contentsOf: Data(littleEndian: UInt32(dataBytes)))
        try handle.seek(toOffset: layout.riffSizeOffset)
        try handle.write(contentsOf: Data(littleEndian: UInt32(finalSize - 8)))
        try handle.synchronize()
        return Int64(frames)
    }

    public enum WAVError: LocalizedError {
        case tooShort, notWAV, tooLarge

        public var errorDescription: String? {
            switch self {
            case .tooShort: return tr("The file is too short.")
            case .notWAV: return tr("The file is not a WAV file.")
            case .tooLarge: return tr("The file is larger than the WAV format allows.")
            }
        }
    }
}

private extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }

    func littleEndianUInt16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    init(littleEndian value: UInt32) {
        var value = value.littleEndian
        self = Swift.withUnsafeBytes(of: &value) { Data($0) }
    }
}
