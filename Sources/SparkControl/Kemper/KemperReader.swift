import AmpText
import Foundation
import SQLite3

public enum KemperReadError: LocalizedError, Equatable {
    case notKemper(String)
    case damaged(String)

    public var errorDescription: String? {
        switch self {
        case .notKemper(let name): tr("“%@” is not a Kemper file (expected: .kipr or .kpabackup).", name)
        case .damaged(let detail): tr("The Kemper file is damaged: %@", detail)
        }
    }
}

/// A performance of the Kemper: five slots, each a whole rig. Slots the Kemper fills with its placeholder are nil.
public struct KemperPerformance: Equatable, Sendable {
    /// Position on the Kemper, from 1.
    public var number: Int
    public var name: String
    /// The five slots in order.
    public var slots: [KemperRig?]
    /// The slots' own names in the performance ("Intro", "Solo"), empty where the Kemper keeps none.
    public var slotNames: [String] = Array(repeating: "", count: 5)

    /// A slot's name: its own, else the name of its rig.
    public func slotName(_ index: Int) -> String {
        let own = slotNames.indices.contains(index) ? slotNames[index].trimmingCharacters(in: .whitespaces) : ""
        if !own.isEmpty { return own }
        return slots.indices.contains(index) ? slots[index]?.string(KemperRig.Tag.rigName) ?? tr("Slot %d", index + 1)
                                             : tr("Slot %d", index + 1)
    }

    /// True for the Kemper's untouched performances ("New Performance", the examples).
    public var isUnused: Bool {
        let lowered = name.lowercased()
        return name.isEmpty || ["new performance", "default performance"].contains(lowered)
            || lowered.hasPrefix("example") || slots.allSatisfy { $0 == nil }
    }
}

/// What a Kemper file holds: its rigs and, in a backup, its performances.
public struct KemperLibrary: Equatable, Sendable {
    public var rigs: [KemperRig]
    public var performances: [KemperPerformance]

    /// Reads a rig file (.kipr) or a backup of the whole Kemper (.kpabackup, a tar archive).
    public static func read(_ url: URL) throws -> KemperLibrary {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "kipr": return KemperLibrary(rigs: [try KemperReader.rigFile(data)], performances: [])
        case "kpabackup": return try KemperReader.backup(data)
        default: throw KemperReadError.notKemper(url.lastPathComponent)
        }
    }

    /// The performances the player set up, without the Kemper's untouched ones.
    public var ownPerformances: [KemperPerformance] { performances.filter { !$0.isUnused } }
}

/// Reads the Kemper's files. Every function only reads; nothing is ever written back to a Kemper or its files.
public enum KemperReader {
    /// A rig file: a MIDI-like frame ("KThd" or "MThd", then "KTrk" or "MTrk" chunks) of SysEx messages.
    public static func rigFile(_ data: Data) throws -> KemperRig {
        let bytes = [UInt8](data)
        guard bytes.count >= 14, ["KThd", "MThd"].contains(String(decoding: bytes[0..<4], as: UTF8.self)) else {
            throw KemperReadError.damaged(tr("no rig header"))
        }
        var index = 8 + Int(bigEndian(bytes, at: 4))
        var messages: [ArraySlice<UInt8>] = []
        while index + 8 <= bytes.count, ["KTrk", "MTrk"].contains(String(decoding: bytes[index..<index + 4], as: UTF8.self)) {
            let length = Int(bigEndian(bytes, at: index + 4))
            let end = min(index + 8 + length, bytes.count)
            messages += events(bytes[(index + 8)..<end])
            index = end
        }
        return rig(from: messages)
    }

    /// A stream of timed SysEx events without a frame, as a performance keeps its slots.
    public static func rigStream(_ data: Data) -> KemperRig {
        let bytes = [UInt8](data)
        return rig(from: events(bytes[...]))
    }

    /// A backup: rigs from "Rigs/", performances from the database "repository.kdb".
    public static func backup(_ data: Data) throws -> KemperLibrary {
        let files = try Tar.files(in: data)
        guard !files.isEmpty else { throw KemperReadError.damaged(tr("empty archive")) }
        var rigs: [KemperRig] = []
        for (path, content) in files.sorted(by: { $0.key < $1.key }) {
            let parts = path.split(separator: "/").filter { $0 != "." }
            guard parts.count == 2, parts[0] == "Rigs", parts[1].lowercased().hasSuffix(".kipr") else { continue }
            if let rig = try? rigFile(content) { rigs.append(rig) }
        }
        let database = files.first { $0.key.split(separator: "/").last == "repository.kdb" }?.value
        let performances = try database.map(performances(fromDatabase:)) ?? []
        return KemperLibrary(rigs: rigs, performances: performances)
    }

    /// The performances in a backup's SQLite database, in the Kemper's order.
    static func performances(fromDatabase data: Data) throws -> [KemperPerformance] {
        // SQLite reads from a file. The copy is private to this process and removed right after.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kemper-\(UUID().uuidString).kdb")
        try data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: file) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw KemperReadError.damaged(tr("database cannot be read"))
        }
        defer { sqlite3_close(db) }

        func rows(_ sql: String, _ bind: [Int64] = [], _ each: (OpaquePointer) -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw KemperReadError.damaged(tr("database has an unknown schema"))
            }
            defer { sqlite3_finalize(statement) }
            for (offset, value) in bind.enumerated() { sqlite3_bind_int64(statement, Int32(offset + 1), value) }
            while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
        }
        func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
            guard let pointer = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        }

        var order: [Int64] = []
        try rows("SELECT perfid FROM perflist ORDER BY id") { order.append(sqlite3_column_int64($0, 0)) }
        var result: [KemperPerformance] = []
        for (position, id) in order.enumerated() {
            var header = Data()
            try rows("SELECT perfdata FROM perfs WHERE id = ?", [id]) { header = blob($0, 0) }
            let names = performanceStrings(header)
            var slots: [KemperRig?] = Array(repeating: nil, count: 5)
            try rows("SELECT p.slot, t.track FROM perfslots p JOIN perftracks t ON t.id = p.trackid "
                     + "WHERE p.perfid = ? ORDER BY p.slot", [id]) { statement in
                let slot = Int(sqlite3_column_int64(statement, 0))
                guard slots.indices.contains(slot) else { return }
                let rig = rigStream(blob(statement, 1))
                let placeholder = rig.isPlaceholder || ["Initialized Rig", "Slot", ""].contains(rig.string(KemperRig.Tag.rigName) ?? "")
                slots[slot] = placeholder ? nil : rig
            }
            result.append(KemperPerformance(number: position + 1, name: names[0] ?? "", slots: slots,
                                            slotNames: (1...5).map { names[$0] ?? "" }))
        }
        return result
    }

    /// The performance's own strings (function 07): 0 is its name, 1 to 5 the slot names.
    static func performanceStrings(_ data: Data) -> [Int: String] {
        var strings: [Int: String] = [:]
        for message in events([UInt8](data)[...]) {
            let body = Array(message)
            // 00 20 33 | product, device | 07 | 00 00 01 00 | index | text 00
            guard body.count > 12, body[0...2] == [0x00, 0x20, 0x33], body[5] == 0x07 else { continue }
            let text = body[12...].prefix { $0 != 0 && $0 != 0xF7 }
            strings[Int(body[11])] = String(decoding: text, as: UTF8.self)
        }
        return strings
    }

    // MARK: SysEx

    /// The SysEx messages in a stream of timed events: delta time, F0, length, message.
    static func events(_ bytes: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var messages: [ArraySlice<UInt8>] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard let (_, afterDelta) = variableLength(bytes, at: index), afterDelta < bytes.endIndex,
                  bytes[afterDelta] == 0xF0,
                  let (length, start) = variableLength(bytes, at: afterDelta + 1), start + length <= bytes.endIndex
            else { break }
            messages.append(bytes[start..<(start + length)])
            index = start + length
        }
        return messages
    }

    static func rig(from messages: [ArraySlice<UInt8>]) -> KemperRig {
        var rig = KemperRig()
        for message in messages {
            let body = Array(message)
            guard body.count >= 9, body[0...2] == [0x00, 0x20, 0x33] else { continue }
            let function = body[5]
            var rest = Array(body[7...])
            if rest.last == 0xF7 { rest.removeLast() }
            switch function {
            case 0x03 where rest.count >= 2 && rest[0] == 0:
                // String parameter: page 0, number, text up to a zero byte. The first one of a number wins.
                let tag = Int(rest[1])
                guard rig.strings[tag] == nil else { continue }
                rig.strings[tag] = String(decoding: rest.dropFirst(2).prefix { $0 != 0 }, as: UTF8.self)
            case 0x01, 0x02:
                // Single or multiple parameters: page, first number, then 14-bit values.
                guard rest.count >= 4 else { continue }
                let page = Int(rest[0])
                let first = Int(rest[1])
                var offset = 2
                var number = first
                while offset + 1 < rest.count {
                    rig.pages[page, default: [:]][number] = Int(rest[offset]) << 7 | Int(rest[offset + 1])
                    offset += 2
                    number += 1
                }
            default:
                continue
            }
        }
        return rig
    }

    static func variableLength(_ bytes: ArraySlice<UInt8>, at start: Int) -> (Int, Int)? {
        var value = 0
        var index = start
        for _ in 0..<4 {
            guard index < bytes.endIndex else { return nil }
            let byte = bytes[index]
            index += 1
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return (value, index) }
        }
        return nil
    }

    static func bigEndian(_ bytes: [UInt8], at index: Int) -> UInt32 {
        bytes[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// The plain files of a tar archive, by path. Enough for the Kemper's backups (ustar, GNU long names).
enum Tar {
    static func files(in data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        var files: [String: Data] = [:]
        var index = 0
        var longName: String?
        while index + 512 <= bytes.count {
            let header = bytes[index..<index + 512]
            if header.allSatisfy({ $0 == 0 }) { break }
            func text(_ offset: Int, _ length: Int) -> String {
                String(decoding: header[(index + offset)..<(index + offset + length)].prefix { $0 != 0 }, as: UTF8.self)
            }
            let sizeText = text(124, 12).trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText.isEmpty ? "0" : sizeText, radix: 8) else {
                throw KemperReadError.damaged(tr("archive header cannot be read"))
            }
            let type = bytes[index + 156]
            var name = text(0, 100)
            if text(257, 5) == "ustar", !text(345, 155).isEmpty { name = text(345, 155) + "/" + name }
            let start = index + 512
            guard start + size <= bytes.count else { throw KemperReadError.damaged(tr("archive ends too early")) }
            let content = Data(bytes[start..<(start + size)])
            switch type {
            case UInt8(ascii: "L"):
                longName = String(decoding: content.prefix { $0 != 0 }, as: UTF8.self)
            case 0, UInt8(ascii: "0"):
                files[longName ?? name] = content
                longName = nil
            default:
                longName = nil
            }
            index = start + (size + 511) / 512 * 512
        }
        return files
    }
}
