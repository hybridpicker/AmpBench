import Foundation

/// Non-destructive edits. They are stored as metadata and applied while listening and exporting.
public struct EditList: Codable, Equatable, Sendable {
    public var trimStart: Double
    /// Nil keeps the file's end.
    public var trimEnd: Double?
    public var fadeIn: Double
    public var fadeOut: Double
    public var gainDB: Double
    public var autoLevelEnabled: Bool
    public var autoLevelDB: Double

    public init(trimStart: Double = 0, trimEnd: Double? = nil, fadeIn: Double = 0, fadeOut: Double = 0,
                gainDB: Double = 0, autoLevelEnabled: Bool = false, autoLevelDB: Double = 0) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.gainDB = gainDB
        self.autoLevelEnabled = autoLevelEnabled
        self.autoLevelDB = autoLevelDB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        autoLevelEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoLevelEnabled) ?? false
        autoLevelDB = try c.decodeIfPresent(Double.self, forKey: .autoLevelDB) ?? 0
    }

    public var totalGainDB: Double { gainDB + (autoLevelEnabled ? autoLevelDB : 0) }
    public var linearGain: Float { Float(pow(10, totalGainDB / 20)) }
    public var isNeutral: Bool { self == EditList(autoLevelEnabled: autoLevelEnabled, autoLevelDB: autoLevelDB) && totalGainDB == 0 }

    /// The peak after gain, in dBFS. Above 0 means an export would clip.
    public func peakAfterGain(originalPeakDB: Double?) -> Double? {
        originalPeakDB.map { $0 + totalGainDB }
    }
}

/// Constant gain that brings a recording's peak to a target. It keeps dynamics intact and raises noise equally.
public enum AutoLevel {
    public static let targetPeakDB = -1.0
    /// Keeps near silence from being raised into loud noise.
    public static let maxGainDB = 30.0

    public static func gainDB(forPeak peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        let gain = min(targetPeakDB - 20 * log10(Double(peak)), maxGainDB)
        return gain >= 0.1 ? gain : 0
    }
}

/// An `EditList` resolved to frames for one file. Applying it is the single place edits turn into samples, so
/// listening and exporting cannot disagree.
public struct EditRenderer: Sendable {
    public let startFrame: Int64
    public let endFrame: Int64
    public let fadeInFrames: Int64
    public let fadeOutFrames: Int64
    public let gain: Float

    public init(edit: EditList, sampleRate: Double, totalFrames: Int64) {
        let start = Self.clampFrame(edit.trimStart * sampleRate, total: totalFrames)
        let end = edit.trimEnd.map { Self.clampFrame($0 * sampleRate, total: totalFrames) } ?? totalFrames
        startFrame = min(start, end)
        endFrame = max(start, end)
        let length = endFrame - startFrame
        var fadeIn = Int64((max(edit.fadeIn, 0) * sampleRate).rounded())
        var fadeOut = Int64((max(edit.fadeOut, 0) * sampleRate).rounded())
        if fadeIn + fadeOut > length, fadeIn + fadeOut > 0 {
            // Overlapping fades are scaled down so they meet instead of skipping part of the level.
            let scale = Double(length) / Double(fadeIn + fadeOut)
            fadeIn = Int64(Double(fadeIn) * scale)
            fadeOut = length - fadeIn
        }
        fadeInFrames = fadeIn
        fadeOutFrames = fadeOut
        gain = edit.linearGain
    }

    private static func clampFrame(_ value: Double, total: Int64) -> Int64 {
        guard value.isFinite else { return 0 }
        return min(max(0, Int64(value.rounded())), total)
    }

    public var lengthFrames: Int64 { endFrame - startFrame }

    public func gain(atFrame frame: Int64) -> Float {
        guard frame >= startFrame, frame < endFrame else { return 0 }
        var value = gain
        if fadeInFrames > 0, frame < startFrame + fadeInFrames {
            value *= Self.curve(Double(frame - startFrame) / Double(fadeInFrames))
        }
        if fadeOutFrames > 0, frame >= endFrame - fadeOutFrames {
            value *= Self.curve(Double(endFrame - 1 - frame) / Double(fadeOutFrames))
        }
        return value
    }

    /// Raised-cosine shape: no audible corner at either end.
    private static func curve(_ position: Double) -> Float {
        Float(0.5 - 0.5 * cos(Double.pi * min(max(position, 0), 1)))
    }

    /// Applies gain and fades to one channel in place. `firstFrame` is the file position of `samples[0]`.
    public func apply(to samples: UnsafeMutablePointer<Float>, count: Int, firstFrame: Int64) {
        let needsCurve = fadeInFrames > 0 || fadeOutFrames > 0
        if !needsCurve && firstFrame >= startFrame && firstFrame + Int64(count) <= endFrame {
            if gain != 1 { for index in 0..<count { samples[index] *= gain } }
            return
        }
        for index in 0..<count {
            samples[index] *= gain(atFrame: firstFrame + Int64(index))
        }
    }
}
