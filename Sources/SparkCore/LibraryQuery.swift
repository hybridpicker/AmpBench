import Foundation

/// Search, filters and the takes they leave over. Sorting is applied by the table with its own comparators.
public struct LibraryQuery: Equatable, Sendable {
    public enum StatusFilter: String, CaseIterable, Sendable {
        case all, open, kept
    }

    public var search = ""
    public var onlyFavorites = false
    public var minimumRating = 0
    public var tag: String?
    public var status = StatusFilter.all
    /// Nil shows all pieces.
    public var piece: PieceFilter?

    public enum PieceFilter: Hashable, Sendable {
        case none
        case piece(UUID)
    }

    public init() {}

    public var isActive: Bool {
        !search.isEmpty || onlyFavorites || minimumRating > 0 || tag != nil || status != .all || piece != nil
    }

    public func matches(_ recording: Recording, pieceName: String? = nil) -> Bool {
        if onlyFavorites && !recording.favorite { return false }
        if recording.rating < minimumRating { return false }
        if let tag, !recording.tags.contains(tag) { return false }
        switch status {
        case .all: break
        case .open: if recording.status != .open { return false }
        case .kept: if recording.status != .kept { return false }
        }
        switch piece {
        case nil: break
        case .none?: if recording.pieceID != nil { return false }
        case .piece(let id)?: if recording.pieceID != id { return false }
        }
        let terms = search.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = ([recording.name, recording.note, pieceName ?? ""] + recording.tags).joined(separator: " ")
        return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    public func filter(_ recordings: [Recording], pieces: [Piece] = []) -> [Recording] {
        let names = Dictionary(uniqueKeysWithValues: pieces.map { ($0.id, $0.name) })
        return recordings.filter { recording in
            matches(recording, pieceName: recording.pieceID.flatMap { names[$0] })
        }
    }

    /// Tags typed as free text, separated by commas: trimmed, without duplicates.
    public static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").compactMap { part in
            let tag = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
    }
}

/// Recorded time per day and per piece. It reports plain totals, with no goals, streaks or comparisons.
public enum PracticeStats {
    public struct Day: Identifiable, Equatable, Sendable {
        public let date: Date
        public let minutes: Double
        public var id: Date { date }
    }

    public struct PieceTotal: Identifiable, Equatable, Sendable {
        public let pieceID: UUID?
        public let name: String
        public let minutes: Double
        public var id: String { pieceID?.uuidString ?? "none" }
    }

    /// Every day of the range, oldest first. Days without recordings count as 0 and stay in the list.
    public static func minutesPerDay(_ log: [PracticeEntry], days: Int, endingOn end: Date = Date(),
                                     calendar: Calendar = .current) -> [Day] {
        let lastDay = calendar.startOfDay(for: end)
        var totals: [Date: Double] = [:]
        for entry in log {
            totals[calendar.startOfDay(for: entry.date), default: 0] += entry.seconds
        }
        return (0..<max(days, 0)).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: lastDay) else { return nil }
            return Day(date: day, minutes: (totals[day] ?? 0) / 60)
        }
    }

    public static func minutesPerPiece(_ log: [PracticeEntry], pieces: [Piece], since: Date? = nil) -> [PieceTotal] {
        var totals: [UUID?: Double] = [:]
        for entry in log where since.map({ entry.date >= $0 }) ?? true {
            // Time logged for a piece that no longer exists counts as "no piece".
            let id = entry.pieceID.flatMap { pieceID in pieces.contains { $0.id == pieceID } ? pieceID : nil }
            totals[id, default: 0] += entry.seconds
        }
        return totals
            .map { id, seconds in
                PieceTotal(pieceID: id, name: pieces.first { $0.id == id }?.name ?? "Ohne Stück", minutes: seconds / 60)
            }
            .sorted { $0.minutes > $1.minutes }
    }

    public static func totalMinutes(_ log: [PracticeEntry], since: Date? = nil) -> Double {
        log.reduce(0) { sum, entry in
            since.map { entry.date >= $0 } ?? true ? sum + entry.seconds : sum
        } / 60
    }
}

/// The source and file formats as separate texts. A source's limits are never hidden behind the file's format.
public enum QualityText {
    public static func rate(_ rate: Double) -> String {
        let kilohertz = rate / 1000
        let text = kilohertz.rounded() == kilohertz
            ? String(format: "%.0f", kilohertz)
            : String(format: "%.1f", kilohertz).replacingOccurrences(of: ".", with: ",")
        return "\(text) kHz"
    }

    public static func channels(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(count) Kanäle"
        }
    }

    public static func source(_ source: SourceFormat?) -> String {
        guard let source else { return "nicht erfasst" }
        let bits = source.bits > 0 ? "\(source.bits) Bit" : "Bittiefe unbekannt"
        return "\(bits) · \(rate(source.sampleRate)) · \(channels(source.channels))"
    }

    public static func source(device: InputDevice) -> String {
        let bits = device.physicalBits > 0 ? "\(device.physicalBits) Bit" : "Bittiefe unbekannt"
        return "\(bits) · \(rate(device.maxRate)) · \(channels(device.channels))"
    }

    public static func file(container: String = "WAV", bits: Int, sampleRate: Double, channels count: Int) -> String {
        let depth = bits > 0 ? " \(bits) Bit" : ""
        return "\(container)\(depth) · \(rate(sampleRate)) · \(channels(count))"
    }
}

/// Decides when the UI warns about a missing signal. A silent stretch is normal between phrases, so a warning waits
/// a few seconds and clears as soon as a signal is back.
public struct SignalMonitor: Sendable {
    public enum Status: Equatable, Sendable {
        case ok
        /// Blocks arrive but contain nothing above the noise floor.
        case silent
        /// The input stopped delivering blocks at all.
        case noData
    }

    public static let silenceThreshold: Float = 0.000316 // -70 dBFS
    public var silentAfter: Double
    public var noDataAfter: Double

    private var silentFor: Double = 0
    private var stalledFor: Double = 0
    private var lastCallbackCount: UInt64?
    public private(set) var status = Status.ok

    public init(silentAfter: Double = 3, noDataAfter: Double = 1) {
        self.silentAfter = silentAfter
        self.noDataAfter = noDataAfter
    }

    public mutating func reset() {
        self = SignalMonitor(silentAfter: silentAfter, noDataAfter: noDataAfter)
    }

    public mutating func update(level: Float, callbackCount: UInt64, elapsed: Double) {
        if callbackCount == lastCallbackCount {
            stalledFor += elapsed
        } else {
            stalledFor = 0
        }
        lastCallbackCount = callbackCount
        silentFor = level < Self.silenceThreshold ? silentFor + elapsed : 0
        if stalledFor >= noDataAfter {
            status = .noData
        } else if silentFor >= silentAfter {
            status = .silent
        } else {
            status = .ok
        }
    }
}

/// Averages the time between taps. A long pause starts a new measurement.
public struct TapTempo: Sendable {
    public static let range = 30.0...300.0
    private var taps: [Double] = []
    private let resetAfter: Double
    private let maxTaps: Int

    public init(resetAfter: Double = 2.0, maxTaps: Int = 6) {
        self.resetAfter = resetAfter
        self.maxTaps = maxTaps
    }

    /// Returns the tempo once two taps are known.
    public mutating func tap(at time: Double) -> Double? {
        if let last = taps.last, time - last > resetAfter { taps = [] }
        taps.append(time)
        if taps.count > maxTaps { taps.removeFirst() }
        guard taps.count >= 2, let first = taps.first, let last = taps.last, last > first else { return nil }
        let bpm = 60.0 * Double(taps.count - 1) / (last - first)
        return min(max(bpm, Self.range.lowerBound), Self.range.upperBound)
    }
}

public enum TimeText {
    /// 01:23 or 1:02:03, optionally with tenths.
    public static func clock(_ seconds: Double, tenths: Bool = false) -> String {
        let safe = seconds.isFinite ? max(seconds, 0) : 0
        let total = Int(safe)
        let base = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
        guard tenths else { return base }
        return "\(base),\(Int(safe * 10) % 10)"
    }

    /// The length in words, for VoiceOver.
    public static func spoken(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let minutes = total / 60
        let rest = total % 60
        if minutes == 0 { return "\(rest) Sekunden" }
        return "\(minutes) Minuten \(rest) Sekunden"
    }
}
