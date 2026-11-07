import AVFoundation
import Foundation

/// Moves files to the Trash. A protocol so tests can avoid the real Trash where it adds nothing.
public protocol Trasher {
    /// Returns where the file ended up.
    func trash(_ url: URL) throws -> URL
}

public struct SystemTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let result = resulting as URL? else { throw LibraryError.trashFailed }
        return result
    }
}

public enum LibraryError: LocalizedError {
    case trashFailed
    case notFound
    case invalidName
    case nameTaken(String)
    case restoreFailed
    case newerSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .trashFailed: return "Die Datei konnte nicht in den Papierkorb gelegt werden."
        case .notFound: return "Die Aufnahme wurde nicht gefunden."
        case .invalidName: return "Dieser Name ist als Dateiname nicht möglich."
        case .nameTaken(let name): return "Es gibt bereits eine Datei mit dem Namen „\(name)“."
        case .restoreFailed: return "Die Datei liegt nicht mehr im Papierkorb."
        case .newerSchema(let version):
            return "Die Bibliothek stammt von einer neueren Version der App (Schema \(version)). Sie bleibt unverändert."
        }
    }
}

/// Written before a recording starts and removed once it is safely in the library.
public struct RecordingJournal: Codable, Equatable, Sendable {
    public var fileName: String
    public var startedAt: Date
    public var source: SourceFormat?
    public var pieceID: UUID?
    public var markers: [Marker]

    public init(fileName: String, startedAt: Date, source: SourceFormat?, pieceID: UUID?, markers: [Marker] = []) {
        self.fileName = fileName
        self.startedAt = startedAt
        self.source = source
        self.pieceID = pieceID
        self.markers = markers
    }
}

public struct ScanReport: Equatable, Sendable {
    public var added: [String] = []
    public var reattached: [String] = []
    public var missing: [String] = []
    public var damaged: [String] = []
    public var repaired: [String] = []
    public init() {}
}

public enum RecoveryOutcome: Equatable, Sendable {
    case none
    case repaired(fileName: String, seconds: Double)
    /// The interrupted recording held no audio, so nothing was added.
    case empty(fileName: String)
    case failed(fileName: String)
}

public enum LoadOutcome: Equatable, Sendable {
    case fresh
    case loaded
    /// The main file was unreadable. It stays on disk under `keptAs`, and the backup was loaded.
    case restoredFromBackup(keptAs: String)
    /// Neither file was readable. Both stay on disk, and recordings are found again by scanning.
    case startedOver(keptAs: String)
}

/// The library document plus every operation on the folder. Not thread-safe: use it from one thread.
public final class LibraryStore {
    public static let documentName = "Bibliothek.json"
    public static let backupName = "Bibliothek.backup.json"
    public static let journalName = ".aufnahme-laeuft.json"
    public static let peaksFolderName = ".wellenformen"
    public static let exportFolderName = "Exporte"
    public static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "caf", "m4a", "mp3", "flac"]

    public let folder: URL
    public private(set) var document = LibraryDocument()
    public private(set) var isReadOnly = false

    private let trasher: Trasher
    private let fileManager = FileManager.default
    private let saveQueue = DispatchQueue(label: "local.sparkrecorder.library-save", qos: .utility)
    private var lockDescriptor: Int32 = -1

    public init(folder: URL, trasher: Trasher = SystemTrasher()) {
        self.folder = folder
        self.trasher = trasher
    }

    deinit {
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spark Recorder", isDirectory: true)
    }

    public var documentURL: URL { folder.appendingPathComponent(Self.documentName) }
    public var backupURL: URL { folder.appendingPathComponent(Self.backupName) }
    public var journalURL: URL { folder.appendingPathComponent(Self.journalName) }
    public var peaksFolder: URL { folder.appendingPathComponent(Self.peaksFolderName, isDirectory: true) }
    public var exportFolder: URL { folder.appendingPathComponent(Self.exportFolderName, isDirectory: true) }

    public func url(of recording: Recording) -> URL { folder.appendingPathComponent(recording.fileName) }
    public func peaksURL(of id: UUID) -> URL { peaksFolder.appendingPathComponent("\(id.uuidString).peaks") }

    public func recording(_ id: UUID) -> Recording? { document.recordings.first { $0.id == id } }

    /// Takes a lock tied to this process, so a second instance cannot treat a live recording as a crash.
    /// The system releases it when the process ends, however that happens.
    public func acquireProcessLock() -> Bool {
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(".lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }

    // MARK: Loading and saving

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    @discardableResult
    public func load() throws -> LoadOutcome {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: documentURL.path) else {
            if let backup = try? readDocument(at: backupURL) {
                document = backup
                try checkSchema()
                return .loaded
            }
            document = LibraryDocument()
            return .fresh
        }
        do {
            document = try readDocument(at: documentURL)
            try checkSchema()
            return .loaded
        } catch LibraryError.newerSchema(let version) {
            throw LibraryError.newerSchema(version)
        } catch {
            let keptAs = try keepUnreadableDocument()
            if let backup = try? readDocument(at: backupURL) {
                document = backup
                try checkSchema()
                return .restoredFromBackup(keptAs: keptAs)
            }
            document = LibraryDocument()
            return .startedOver(keptAs: keptAs)
        }
    }

    private func checkSchema() throws {
        guard document.schemaVersion <= LibraryDocument.currentSchema else {
            isReadOnly = true
            throw LibraryError.newerSchema(document.schemaVersion)
        }
    }

    private func readDocument(at url: URL) throws -> LibraryDocument {
        try Self.makeDecoder().decode(LibraryDocument.self, from: Data(contentsOf: url))
    }

    private func keepUnreadableDocument() throws -> String {
        let stamp = Self.fileStamp(Date())
        let name = "Bibliothek.defekt-\(stamp).json"
        try fileManager.moveItem(at: documentURL, to: folder.appendingPathComponent(name))
        return name
    }

    /// Saves atomically. The previous version becomes the backup, and a crash at any point leaves a readable file.
    public func save() throws {
        guard !isReadOnly else { return }
        let data = try Self.makeEncoder().encode(document)
        try write(data)
    }

    /// Saves on a background queue, so disk access never holds up the UI.
    public func saveInBackground(completion: (@Sendable (Error?) -> Void)? = nil) {
        guard !isReadOnly else { return }
        let snapshot = document
        saveQueue.async { [self] in
            do {
                try write(Self.makeEncoder().encode(snapshot))
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
    }

    /// Waits for background saves. Call it before quitting.
    public func flushSaves() {
        saveQueue.sync {}
    }

    private func write(_ data: Data) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: documentURL.path) {
            let temporary = folder.appendingPathComponent(".\(UUID().uuidString).backup")
            try fileManager.copyItem(at: documentURL, to: temporary)
            _ = Darwin.rename(temporary.path, backupURL.path)
        }
        try data.write(to: documentURL, options: .atomic)
    }

    // MARK: Journal

    public func writeJournal(_ journal: RecordingJournal) throws {
        let data = try Self.makeEncoder().encode(journal)
        try data.write(to: journalURL, options: .atomic)
    }

    public func removeJournal() {
        try? fileManager.removeItem(at: journalURL)
    }

    public func readJournal() -> RecordingJournal? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        return try? Self.makeDecoder().decode(RecordingJournal.self, from: data)
    }

    /// Repairs the recording a previous run did not finish, and adds it to the library.
    @discardableResult
    public func recoverInterruptedRecording() -> RecoveryOutcome {
        guard let journal = readJournal() else { return .none }
        let fileURL = folder.appendingPathComponent(journal.fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            removeJournal()
            return .none
        }
        switch WAVFile.inspect(fileURL) {
        case .empty, .unreadable:
            // A file without audio holds nothing worth keeping, but it still goes to the Trash, not away.
            if case .empty = WAVFile.inspect(fileURL) {
                _ = try? trasher.trash(fileURL)
                removeJournal()
                return .empty(fileName: journal.fileName)
            }
            removeJournal()
            markDamagedOrAdd(fileURL)
            return .failed(fileName: journal.fileName)
        case .ok, .needsRepair:
            break
        }
        do {
            try WAVFile.repair(fileURL, treatTrailingDataAsAudio: true)
        } catch {
            removeJournal()
            markDamagedOrAdd(fileURL)
            return .failed(fileName: journal.fileName)
        }
        guard case .ok(let format, let frames) = WAVFile.inspect(fileURL) else {
            removeJournal()
            markDamagedOrAdd(fileURL)
            return .failed(fileName: journal.fileName)
        }
        let seconds = Double(frames) / format.sampleRate
        if document.recordings.contains(where: { $0.fileName == journal.fileName }) {
            removeJournal()
            return .repaired(fileName: journal.fileName, seconds: seconds)
        }
        let attributes = fileAttributes(fileURL)
        let recording = Recording(
            fileName: journal.fileName,
            createdAt: journal.startedAt,
            duration: seconds,
            sampleRate: format.sampleRate,
            channels: format.channels,
            fileBits: format.bits,
            fileSize: attributes.size,
            inode: attributes.inode,
            source: journal.source,
            status: .open,
            markers: journal.markers,
            pieceID: journal.pieceID,
            recoveredAfterInterruption: true
        )
        document.recordings.append(recording)
        document.practiceLog.append(PracticeEntry(date: journal.startedAt, seconds: seconds, pieceID: journal.pieceID))
        try? save()
        removeJournal()
        return .repaired(fileName: journal.fileName, seconds: seconds)
    }

    private func markDamagedOrAdd(_ url: URL) {
        let name = url.lastPathComponent
        if let index = document.recordings.firstIndex(where: { $0.fileName == name }) {
            document.recordings[index].health = .damaged
        } else {
            let attributes = fileAttributes(url)
            document.recordings.append(Recording(
                fileName: name, createdAt: attributes.created, duration: 0, sampleRate: 0, channels: 0, fileBits: 0,
                fileSize: attributes.size, inode: attributes.inode, status: .open, health: .damaged,
                recoveredAfterInterruption: true))
        }
        try? save()
    }

    // MARK: Scanning the folder

    private func fileAttributes(_ url: URL) -> (size: Int64, inode: UInt64, created: Date) {
        let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
        return (
            (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            (attributes[.creationDate] as? Date) ?? Date()
        )
    }

    private func audioFilesInFolder() -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Makes the library match the folder: finds new and renamed files, notes missing ones and repairs headers.
    /// It never deletes anything, and a recording that is missing keeps its entry and metadata.
    public func scan() -> ScanReport {
        var report = ScanReport()
        let activeFile = readJournal()?.fileName
        let files = audioFilesInFolder().filter { $0.lastPathComponent != activeFile }
        let known = Set(document.recordings.map(\.fileName))
        var unknown = files.filter { !known.contains($0.lastPathComponent) }
        var changed = false

        for index in document.recordings.indices {
            let recording = document.recordings[index]
            let url = url(of: recording)
            if fileManager.fileExists(atPath: url.path) {
                let attributes = fileAttributes(url)
                if recording.health == .missing {
                    document.recordings[index].health = .ok
                    changed = true
                }
                if recording.inode != attributes.inode || recording.fileSize != attributes.size {
                    document.recordings[index].inode = attributes.inode
                    document.recordings[index].fileSize = attributes.size
                    changed = true
                }
                continue
            }
            // Renamed in the Finder: the same file on disk under another name keeps its metadata.
            if recording.inode != 0,
               let match = unknown.firstIndex(where: { fileAttributes($0).inode == recording.inode }) {
                document.recordings[index].fileName = unknown[match].lastPathComponent
                document.recordings[index].health = .ok
                report.reattached.append(unknown[match].lastPathComponent)
                unknown.remove(at: match)
                changed = true
                continue
            }
            if recording.health != .missing {
                document.recordings[index].health = .missing
                changed = true
            }
            report.missing.append(recording.fileName)
        }

        for url in unknown {
            // A file put back from the Trash through the Finder gets its metadata back.
            let inode = fileAttributes(url).inode
            if let trashed = document.trashed.firstIndex(where: {
                $0.recording.inode == inode && inode != 0 || $0.recording.fileName == url.lastPathComponent
            }) {
                var restored = document.trashed.remove(at: trashed).recording
                restored.fileName = url.lastPathComponent
                restored.inode = inode
                restored.health = .ok
                document.recordings.append(restored)
                report.reattached.append(url.lastPathComponent)
                changed = true
                continue
            }
            switch adopt(url) {
            case .added(let wasRepaired):
                report.added.append(url.lastPathComponent)
                if wasRepaired { report.repaired.append(url.lastPathComponent) }
            case .damaged:
                report.damaged.append(url.lastPathComponent)
            }
            changed = true
        }

        // Known files can also have lost their header, for example from an older crash.
        for index in document.recordings.indices where document.recordings[index].health != .missing {
            // Files adopted above were already checked.
            guard known.contains(document.recordings[index].fileName) else { continue }
            let url = url(of: document.recordings[index])
            guard url.pathExtension.lowercased() == "wav" else { continue }
            switch WAVFile.inspect(url) {
            case .needsRepair:
                if (try? WAVFile.repair(url)) != nil, case .ok(let format, let frames) = WAVFile.inspect(url) {
                    document.recordings[index].duration = Double(frames) / format.sampleRate
                    document.recordings[index].fileSize = fileAttributes(url).size
                    document.recordings[index].health = .ok
                    report.repaired.append(url.lastPathComponent)
                } else {
                    document.recordings[index].health = .damaged
                    report.damaged.append(url.lastPathComponent)
                }
                changed = true
            case .unreadable, .empty:
                if document.recordings[index].health != .damaged {
                    document.recordings[index].health = .damaged
                    changed = true
                }
                report.damaged.append(url.lastPathComponent)
            case .ok:
                if document.recordings[index].health == .damaged {
                    document.recordings[index].health = .ok
                    changed = true
                }
            }
        }
        if changed { try? save() }
        return report
    }

    private enum Adoption { case added(repaired: Bool), damaged }

    /// Adds a file found in the folder. Files already there get no gain and an unknown source: what they went
    /// through before is not known, so nothing is assumed about them.
    private func adopt(_ url: URL) -> Adoption {
        let attributes = fileAttributes(url)
        var repaired = false
        var format: (rate: Double, channels: Int, bits: Int, frames: Int64)?

        if url.pathExtension.lowercased() == "wav" {
            switch WAVFile.inspect(url) {
            case .ok(let found, let frames):
                format = (found.sampleRate, found.channels, found.bits, frames)
            case .needsRepair:
                if (try? WAVFile.repair(url)) != nil, case .ok(let found, let frames) = WAVFile.inspect(url) {
                    format = (found.sampleRate, found.channels, found.bits, frames)
                    repaired = true
                }
            case .empty, .unreadable:
                break
            }
        } else if let file = try? AVAudioFile(forReading: url) {
            let settings = file.fileFormat.settings
            format = (
                file.fileFormat.sampleRate, Int(file.fileFormat.channelCount),
                (settings[AVLinearPCMBitDepthKey] as? Int) ?? 0, file.length
            )
        }

        guard let format, format.rate > 0 else {
            document.recordings.append(Recording(
                fileName: url.lastPathComponent, createdAt: attributes.created, duration: 0, sampleRate: 0,
                channels: 0, fileBits: 0, fileSize: attributes.size, inode: attributes.inode, status: .kept,
                health: .damaged))
            return .damaged
        }
        let seconds = Double(format.frames) / format.rate
        document.recordings.append(Recording(
            fileName: url.lastPathComponent, createdAt: attributes.created, duration: seconds,
            sampleRate: format.rate, channels: format.channels, fileBits: format.bits, fileSize: attributes.size,
            inode: attributes.inode, status: .kept, recoveredAfterInterruption: repaired))
        document.practiceLog.append(PracticeEntry(date: attributes.created, seconds: seconds, pieceID: nil))
        return .added(repaired: repaired)
    }

    // MARK: Changing recordings

    public func add(_ recording: Recording) {
        var recording = recording
        let attributes = fileAttributes(url(of: recording))
        recording.fileSize = attributes.size
        recording.inode = attributes.inode
        document.recordings.append(recording)
    }

    public func logPractice(date: Date, seconds: Double, pieceID: UUID?) {
        guard seconds > 0 else { return }
        document.practiceLog.append(PracticeEntry(date: date, seconds: seconds, pieceID: pieceID))
    }

    public func update(_ id: UUID, _ change: (inout Recording) -> Void) {
        guard let index = document.recordings.firstIndex(where: { $0.id == id }) else { return }
        change(&document.recordings[index])
    }

    /// A safe file name stem, or nil when nothing usable remains.
    public static func sanitizedName(_ name: String) -> String? {
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        cleaned = cleaned.filter { !$0.isNewline && $0 != "\0" }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned.utf8.count <= 200 else { return nil }
        return cleaned
    }

    /// Renames the file itself, so Finder and library agree. Existing files are never overwritten.
    public func rename(_ id: UUID, to newName: String) throws {
        guard let recording = recording(id) else { throw LibraryError.notFound }
        guard let stem = Self.sanitizedName(newName) else { throw LibraryError.invalidName }
        let ext = (recording.fileName as NSString).pathExtension
        let fileName = ext.isEmpty ? stem : "\(stem).\(ext)"
        guard fileName != recording.fileName else { return }
        let destination = folder.appendingPathComponent(fileName)
        let isSameFileWithNewCase = fileName.lowercased() == recording.fileName.lowercased()
        if fileManager.fileExists(atPath: destination.path) && !isSameFileWithNewCase {
            throw LibraryError.nameTaken(fileName)
        }
        try fileManager.moveItem(at: url(of: recording), to: destination)
        update(id) { $0.fileName = fileName }
    }

    public func uniqueName(_ stem: String, ext: String = "wav") -> URL {
        var candidate = folder.appendingPathComponent("\(stem).\(ext)")
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Moves the file to the Trash, never deleting it, and keeps its metadata for restoring.
    public func trash(_ id: UUID) throws -> TrashedRecording {
        guard let recording = recording(id) else { throw LibraryError.notFound }
        let source = url(of: recording)
        var trashPath = ""
        if fileManager.fileExists(atPath: source.path) {
            trashPath = try trasher.trash(source).path
        }
        let entry = TrashedRecording(recording: recording, trashPath: trashPath, trashedAt: Date())
        document.recordings.removeAll { $0.id == id }
        document.trashed.removeAll { $0.recording.id == id }
        document.trashed.append(entry)
        for index in document.pieces.indices where document.pieces[index].bestTakeID == id {
            document.pieces[index].bestTakeID = nil
        }
        return entry
    }

    /// Puts a trashed file back. Another file having taken its name gets the restored one a numbered name.
    public func restore(_ entry: TrashedRecording) throws {
        let trashURL = URL(fileURLWithPath: entry.trashPath)
        var recording = entry.recording
        if !entry.trashPath.isEmpty {
            guard fileManager.fileExists(atPath: trashURL.path) else { throw LibraryError.restoreFailed }
            let stem = (recording.fileName as NSString).deletingPathExtension
            let ext = (recording.fileName as NSString).pathExtension
            let destination = uniqueName(stem, ext: ext)
            try fileManager.moveItem(at: trashURL, to: destination)
            recording.fileName = destination.lastPathComponent
        }
        document.trashed.removeAll { $0.recording.id == recording.id }
        document.recordings.append(recording)
    }

    /// The most recently trashed recording whose file is still in the Trash.
    public var lastRestorable: TrashedRecording? {
        document.trashed
            .sorted { $0.trashedAt > $1.trashedAt }
            .first { !$0.trashPath.isEmpty && fileManager.fileExists(atPath: $0.trashPath) }
    }

    // MARK: Pieces and takes

    @discardableResult
    public func addPiece(named name: String) -> Piece? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if let existing = document.pieces.first(where: { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            return existing
        }
        let piece = Piece(name: cleaned)
        document.pieces.append(piece)
        return piece
    }

    public func renamePiece(_ id: UUID, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = document.pieces.firstIndex(where: { $0.id == id }) else { return }
        document.pieces[index].name = cleaned
    }

    /// Takes keep their files and metadata. They just no longer belong to the piece.
    public func removePiece(_ id: UUID) {
        document.pieces.removeAll { $0.id == id }
        for index in document.recordings.indices where document.recordings[index].pieceID == id {
            document.recordings[index].pieceID = nil
        }
    }

    public func assign(_ id: UUID, toPiece pieceID: UUID?) {
        let previous = recording(id)?.pieceID
        update(id) { $0.pieceID = pieceID }
        if let previous, previous != pieceID,
           let index = document.pieces.firstIndex(where: { $0.id == previous && $0.bestTakeID == id }) {
            document.pieces[index].bestTakeID = nil
        }
    }

    /// Marks one take as the best of its piece. Marking it again removes the mark.
    public func toggleBestTake(_ id: UUID) {
        guard let pieceID = recording(id)?.pieceID,
              let index = document.pieces.firstIndex(where: { $0.id == pieceID }) else { return }
        document.pieces[index].bestTakeID = document.pieces[index].bestTakeID == id ? nil : id
    }

    /// The takes of a piece from first to last.
    public func takes(ofPiece pieceID: UUID) -> [Recording] {
        document.recordings.filter { $0.pieceID == pieceID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func isBestTake(_ recording: Recording) -> Bool {
        guard let pieceID = recording.pieceID else { return false }
        return document.pieces.first { $0.id == pieceID }?.bestTakeID == recording.id
    }

    public var allTags: [String] {
        Array(Set(document.recordings.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
