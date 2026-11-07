import XCTest
@testable import SparkCore

final class QueryTests: XCTestCase {
    private func recording(_ name: String, rating: Int = 0, favorite: Bool = false, tags: [String] = [], note: String = "",
                           status: TakeStatus = .kept, pieceID: UUID? = nil) -> Recording {
        Recording(fileName: "\(name).wav", createdAt: Date(), duration: 1, sampleRate: 44_100, channels: 1, fileBits: 24,
                  status: status, rating: rating, favorite: favorite, tags: tags, note: note, pieceID: pieceID)
    }

    func testSearchCoversNameNoteTagsAndPiece() {
        let piece = Piece(name: "Etüde Nr. 3")
        let items = [
            recording("Blues in A"),
            recording("x", note: "Solo klappt jetzt"),
            recording("y", tags: ["Jazz"]),
            recording("z", pieceID: piece.id),
        ]
        func names(_ search: String) -> [String] {
            var query = LibraryQuery()
            query.search = search
            return query.filter(items, pieces: [piece]).map(\.name)
        }
        XCTAssertEqual(names("blues"), ["Blues in A"])
        XCTAssertEqual(names("SOLO"), ["x"])
        XCTAssertEqual(names("jazz"), ["y"])
        XCTAssertEqual(names("etude"), ["z"], "diacritics are ignored")
        XCTAssertEqual(names("blues a"), ["Blues in A"], "all terms must match")
        XCTAssertEqual(names("nichts"), [])
        XCTAssertEqual(names("").count, 4)
    }

    func testFiltersCombine() {
        let pieceID = UUID()
        let items = [
            recording("a", rating: 5, favorite: true, tags: ["x"], status: .kept, pieceID: pieceID),
            recording("b", rating: 3, status: .open),
            recording("c", rating: 1, favorite: true),
        ]
        var query = LibraryQuery()
        query.onlyFavorites = true
        XCTAssertEqual(query.filter(items).map(\.name), ["a", "c"])
        query.minimumRating = 4
        XCTAssertEqual(query.filter(items).map(\.name), ["a"])

        query = LibraryQuery()
        query.status = .open
        XCTAssertEqual(query.filter(items).map(\.name), ["b"])

        query = LibraryQuery()
        query.tag = "x"
        XCTAssertEqual(query.filter(items).map(\.name), ["a"])

        query = LibraryQuery()
        query.piece = .piece(pieceID)
        XCTAssertEqual(query.filter(items).map(\.name), ["a"])
        query.piece = LibraryQuery.PieceFilter.none
        XCTAssertEqual(query.filter(items).map(\.name), ["b", "c"])
    }

    func testIsActiveReflectsFilters() {
        var query = LibraryQuery()
        XCTAssertFalse(query.isActive)
        query.minimumRating = 1
        XCTAssertTrue(query.isActive)
    }

    func testTableSortingWorksOnAllColumns() {
        let items = [
            recording("b", rating: 1, favorite: true, status: .kept),
            recording("a", rating: 5, status: .open),
        ]
        XCTAssertEqual(items.sorted(using: KeyPathComparator(\Recording.name)).map(\.name), ["a", "b"])
        XCTAssertEqual(items.sorted(using: KeyPathComparator(\Recording.rating)).map(\.name), ["b", "a"])
        XCTAssertEqual(items.sorted(using: KeyPathComparator(\Recording.favoriteRank, order: .reverse)).map(\.name), ["b", "a"])
        XCTAssertEqual(items.sorted(using: KeyPathComparator(\Recording.statusRank)).map(\.name), ["a", "b"])
    }

    func testTagParsing() {
        XCTAssertEqual(LibraryQuery.parseTags(" Blues, Solo ,,blues, Jazz "), ["Blues", "Solo", "Jazz"])
        XCTAssertEqual(LibraryQuery.parseTags("   "), [])
    }
}

final class StatsTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return calendar
    }()

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    func testMinutesPerDayIncludesEmptyDays() {
        let log = [
            PracticeEntry(date: date(5), seconds: 120, pieceID: nil),
            PracticeEntry(date: date(5, hour: 20), seconds: 60, pieceID: nil),
            PracticeEntry(date: date(7), seconds: 30, pieceID: nil),
        ]
        let days = PracticeStats.minutesPerDay(log, days: 3, endingOn: date(7), calendar: calendar)
        XCTAssertEqual(days.map(\.minutes), [3, 0, 0.5])
        XCTAssertEqual(days.first?.date, calendar.startOfDay(for: date(5)))
    }

    func testEntriesOutsideTheRangeAreLeftOut() {
        let log = [PracticeEntry(date: date(1), seconds: 600, pieceID: nil)]
        let days = PracticeStats.minutesPerDay(log, days: 2, endingOn: date(7), calendar: calendar)
        XCTAssertEqual(days.map(\.minutes), [0, 0])
    }

    func testMinutesPerPieceSortedWithDeletedPieceAsNoPiece() {
        let piece = Piece(name: "Etüde")
        let log = [
            PracticeEntry(date: date(5), seconds: 600, pieceID: piece.id),
            PracticeEntry(date: date(5), seconds: 60, pieceID: nil),
            PracticeEntry(date: date(5), seconds: 60, pieceID: UUID()),
        ]
        let totals = PracticeStats.minutesPerPiece(log, pieces: [piece])
        XCTAssertEqual(totals.map(\.name), ["Etüde", "Ohne Stück"])
        XCTAssertEqual(totals.map(\.minutes), [10, 2])
    }

    func testTotalRespectsStartDate() {
        let log = [
            PracticeEntry(date: date(1), seconds: 60, pieceID: nil),
            PracticeEntry(date: date(5), seconds: 120, pieceID: nil),
        ]
        XCTAssertEqual(PracticeStats.totalMinutes(log), 3)
        XCTAssertEqual(PracticeStats.totalMinutes(log, since: date(3)), 2)
    }

    func testDiscardingATakeKeepsItsPracticeTime() throws {
        let folder = try TemporaryFolder()
        let store = LibraryStore(folder: folder.file("Library"), trasher: FakeTrash(folder: folder.file("Trash")))
        try store.load()
        let name = "a.wav"
        try Synthetic.writeWAV(to: store.folder.appendingPathComponent(name))
        let recording = Recording(fileName: name, createdAt: Date(), duration: 60, sampleRate: 44_100, channels: 1, fileBits: 24)
        store.add(recording)
        store.logPractice(date: Date(), seconds: 60, pieceID: nil)
        _ = try store.trash(recording.id)
        XCTAssertEqual(PracticeStats.totalMinutes(store.document.practiceLog), 1)
    }
}

final class QualityTextTests: XCTestCase {
    func testSourceAndFileAreStatedSeparately() {
        let source = SourceFormat(deviceName: "Spark MINI USB", bits: 16, sampleRate: 44_100, channels: 1)
        XCTAssertEqual(QualityText.source(source), "16 Bit · 44,1 kHz · Mono")
        XCTAssertEqual(QualityText.file(bits: 24, sampleRate: 44_100, channels: 1), "WAV 24 Bit · 44,1 kHz · Mono")
    }

    func testUnknownSourceIsNotGuessed() {
        XCTAssertEqual(QualityText.source(nil), "nicht erfasst")
    }

    func testNothingClaimsHiRes() {
        let texts = [
            QualityText.source(SourceFormat(deviceName: "x", bits: 16, sampleRate: 44_100, channels: 1)),
            QualityText.source(SourceFormat(deviceName: "x", bits: 24, sampleRate: 96_000, channels: 2)),
            QualityText.file(bits: 24, sampleRate: 96_000, channels: 2),
        ]
        for text in texts { XCTAssertFalse(text.lowercased().contains("hi-res"), text) }
    }

    func testWholeKilohertzRatesHaveNoDecimals() {
        XCTAssertEqual(QualityText.rate(48_000), "48 kHz")
        XCTAssertEqual(QualityText.rate(44_100), "44,1 kHz")
    }
}

final class SignalMonitorTests: XCTestCase {
    func testPlayingSignalIsOk() {
        var monitor = SignalMonitor()
        for tick in 1...100 { monitor.update(level: 0.06, callbackCount: UInt64(tick), elapsed: 0.1) }
        XCTAssertEqual(monitor.status, .ok)
    }

    func testShortPauseBetweenPhrasesDoesNotWarn() {
        var monitor = SignalMonitor(silentAfter: 3)
        for tick in 1...20 { monitor.update(level: 0, callbackCount: UInt64(tick), elapsed: 0.1) }
        XCTAssertEqual(monitor.status, .ok)
    }

    func testLongSilenceWarnsAndClearsWhenSignalReturns() {
        var monitor = SignalMonitor(silentAfter: 3)
        var tick: UInt64 = 0
        for _ in 0..<31 {
            tick += 1
            monitor.update(level: 0, callbackCount: tick, elapsed: 0.1)
        }
        XCTAssertEqual(monitor.status, .silent)
        tick += 1
        monitor.update(level: 0.1, callbackCount: tick, elapsed: 0.1)
        XCTAssertEqual(monitor.status, .ok)
    }

    func testStoppedCallbacksAreNoData() {
        var monitor = SignalMonitor(noDataAfter: 1)
        monitor.update(level: 0.1, callbackCount: 5, elapsed: 0.1)
        for _ in 0..<11 { monitor.update(level: 0, callbackCount: 5, elapsed: 0.1) }
        XCTAssertEqual(monitor.status, .noData)
        monitor.update(level: 0.1, callbackCount: 6, elapsed: 0.1)
        XCTAssertEqual(monitor.status, .ok)
    }
}

final class TapTempoTests: XCTestCase {
    func testFirstTapHasNoTempo() {
        var tap = TapTempo()
        XCTAssertNil(tap.tap(at: 0))
    }

    func testEvenTapsGiveTheTempo() {
        var tap = TapTempo()
        var bpm: Double?
        for index in 0..<5 { bpm = tap.tap(at: Double(index) * 0.5) }
        XCTAssertEqual(try XCTUnwrap(bpm), 120, accuracy: 0.001)
    }

    func testLongPauseStartsOver() {
        var tap = TapTempo(resetAfter: 2)
        _ = tap.tap(at: 0)
        _ = tap.tap(at: 0.5)
        XCTAssertNil(tap.tap(at: 10))
        XCTAssertEqual(try XCTUnwrap(tap.tap(at: 11)), 60, accuracy: 0.001)
    }

    func testTempoStaysInRange() {
        var tap = TapTempo()
        _ = tap.tap(at: 0)
        XCTAssertEqual(tap.tap(at: 0.01), TapTempo.range.upperBound)
    }
}

final class TimeTextTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(TimeText.clock(0), "00:00")
        XCTAssertEqual(TimeText.clock(83.4), "01:23")
        XCTAssertEqual(TimeText.clock(83.46, tenths: true), "01:23,4")
        XCTAssertEqual(TimeText.clock(3723), "1:02:03")
        XCTAssertEqual(TimeText.clock(.nan), "00:00")
        XCTAssertEqual(TimeText.clock(-5), "00:00")
    }
}

final class FeedbackGuardTests: XCTestCase {
    private let sparkIn = DeviceIdentity(uid: "AppleUSBAudioEngine:Positive Grid:Spark MINI USB:1", modelUID: "Spark:1", name: "Spark MINI USB", isBuiltIn: false)
    private let sparkOut = DeviceIdentity(uid: "AppleUSBAudioEngine:Positive Grid:Spark MINI USB:2", modelUID: "Spark:1", name: "Spark MINI USB", isBuiltIn: false)
    private let headphones = DeviceIdentity(uid: "headphones", modelUID: "m1", name: "Externe Kopfhörer", isBuiltIn: true)
    private let speakers = DeviceIdentity(uid: "speakers", modelUID: "m2", name: "MacBook Pro-Lautsprecher", isBuiltIn: true)
    private let microphone = DeviceIdentity(uid: "mic", modelUID: "m3", name: "MacBook Pro-Mikrofon", isBuiltIn: true)

    func testAmpOutputIsBlockedWhileRecordingAmpInput() {
        XCTAssertEqual(FeedbackGuard.assess(input: sparkIn, output: sparkOut), .sameHardware)
    }

    func testAmpIsRecognizedByNameEvenWithDifferentIdentifiers() {
        let other = DeviceIdentity(uid: "x", modelUID: "y", name: "Spark MINI", isBuiltIn: false)
        XCTAssertEqual(FeedbackGuard.assess(input: sparkIn, output: other), .sameHardware)
    }

    func testMeasuredCleanPairIsAllowed() {
        let key = FeedbackGuard.pairKey(input: sparkIn, output: sparkOut)
        XCTAssertEqual(FeedbackGuard.assess(input: sparkIn, output: sparkOut, measuredClean: [key]), .none)
    }

    func testMeasurementOnlyCountsForThatPair() {
        let other = DeviceIdentity(uid: "other", modelUID: "Spark:1", name: "Spark MINI USB", isBuiltIn: false)
        let key = FeedbackGuard.pairKey(input: sparkIn, output: other)
        XCTAssertEqual(FeedbackGuard.assess(input: sparkIn, output: sparkOut, measuredClean: [key]), .sameHardware)
    }

    func testVirtualLoopDeviceIsBlocked() {
        let blackHole = DeviceIdentity(uid: "BlackHole2ch_UID", modelUID: "BlackHole", name: "BlackHole 2ch", isBuiltIn: false)
        XCTAssertEqual(FeedbackGuard.assess(input: blackHole, output: blackHole), .sameHardware)
    }

    func testHeadphonesAreSafeWithAmpAndMicrophone() {
        XCTAssertEqual(FeedbackGuard.assess(input: sparkIn, output: headphones), .none)
        XCTAssertEqual(FeedbackGuard.assess(input: microphone, output: headphones), .none)
    }

    func testSpeakersAreSafeWithAmpButNotWithMicrophone() {
        XCTAssertEqual(FeedbackGuard.assess(input: sparkIn, output: speakers), .none)
        XCTAssertEqual(FeedbackGuard.assess(input: microphone, output: speakers), .acoustic)
    }

    func testBuiltInDevicesSharingAModelAreNotTheSameHardware() {
        let sameModelHeadphones = DeviceIdentity(uid: "hp", modelUID: "m3", name: "Kopfhörer", isBuiltIn: true)
        XCTAssertEqual(FeedbackGuard.assess(input: microphone, output: sameModelHeadphones), .none)
    }

    func testNoInputMeansNoRisk() {
        XCTAssertEqual(FeedbackGuard.assess(input: nil, output: sparkOut), .none)
    }

    func testEveryRiskIsExplained() {
        XCTAssertNil(FeedbackGuard.explanation(.none))
        XCTAssertNotNil(FeedbackGuard.explanation(.sameHardware))
        XCTAssertNotNil(FeedbackGuard.explanation(.acoustic))
    }
}

final class WaveformTests: XCTestCase {
    func testColumnsKeepPeaks() {
        var pairs: [Float] = []
        for bin in 0..<100 {
            let value: Float = bin == 50 ? 0.9 : 0.1
            pairs += [-value, value]
        }
        let waveform = WaveformData(binFrames: 256, sampleRate: 25_600, pairs: pairs)
        let columns = waveform.columns(10)
        XCTAssertEqual(columns.count, 10)
        XCTAssertEqual(columns.map(\.max).max(), 0.9, "narrow peaks must survive reduction")
        XCTAssertEqual(waveform.duration, 1)
        XCTAssertEqual(waveform.peak, 0.9)
    }

    func testColumnsOfEmptyWaveformAreEmpty() {
        XCTAssertTrue(WaveformData(binFrames: 256, sampleRate: 44_100, pairs: []).columns(100).isEmpty)
    }

    func testMoreColumnsThanBinsStillWorks() {
        let waveform = WaveformData(binFrames: 256, sampleRate: 44_100, pairs: [-0.5, 0.5, -0.2, 0.2])
        XCTAssertEqual(waveform.columns(8).count, 8)
    }

    func testCacheRoundTrip() throws {
        let folder = try TemporaryFolder()
        let waveform = WaveformData(binFrames: 256, sampleRate: 44_100, pairs: [-0.5, 0.5, -0.25, 0.25])
        try waveform.write(to: folder.file("a.peaks"))
        XCTAssertEqual(WaveformData.read(from: folder.file("a.peaks")), waveform)
    }

    func testBrokenCacheIsIgnored() throws {
        let folder = try TemporaryFolder()
        try Data("nonsense-nonsense-nonsense".utf8).write(to: folder.file("a.peaks"))
        XCTAssertNil(WaveformData.read(from: folder.file("a.peaks")))
        XCTAssertNil(WaveformData.read(from: folder.file("missing.peaks")))
    }

    func testAnalyzerMeasuresSyntheticFile() throws {
        let folder = try TemporaryFolder()
        let url = try Synthetic.writeWAV(to: folder.file("a.wav"), seconds: 1, amplitude: 0.25)
        let analysis = try XCTUnwrap(AudioAnalyzer.analyze(url))
        XCTAssertEqual(analysis.frames, 44_100)
        XCTAssertEqual(analysis.peak, 0.25, accuracy: 0.001)
        XCTAssertEqual(analysis.waveform.binCount, 44_100 / 256 + 1)
        XCTAssertEqual(analysis.waveform.peak, 0.25, accuracy: 0.001)
    }

    func testAnalyzerCanBeCancelled() throws {
        let folder = try TemporaryFolder()
        let url = try Synthetic.writeWAV(to: folder.file("a.wav"), seconds: 1)
        XCTAssertNil(try AudioAnalyzer.analyze(url, isCancelled: { true }))
    }
}

final class RecordingRateTests: XCTestCase {
    func testOrdinaryDeviceUsesItsHighestRate() {
        XCTAssertEqual(AudioDevices.recordingRate(available: [(44_100, 44_100), (48_000, 48_000), (96_000, 96_000)], current: 44_100), 96_000)
    }

    func testAmpWithOneRateKeepsIt() {
        XCTAssertEqual(AudioDevices.recordingRate(available: [(44_100, 44_100)], current: 44_100), 44_100)
    }

    func testVirtualDeviceRatesAreCapped() {
        XCTAssertEqual(AudioDevices.recordingRate(available: [(48_000, 48_000), (192_000, 192_000), (768_000, 768_000)], current: 48_000), 192_000)
    }

    func testContinuousRangeIsCapped() {
        XCTAssertEqual(AudioDevices.recordingRate(available: [(8_000, 384_000)], current: 48_000), 192_000)
    }

    func testDeviceAboveTheLimitStillWorks() {
        XCTAssertEqual(AudioDevices.recordingRate(available: [(352_800, 352_800), (384_000, 384_000)], current: 352_800), 352_800)
    }

    func testDeviceWithoutRateListKeepsCurrentRate() {
        XCTAssertEqual(AudioDevices.recordingRate(available: [], current: 48_000), 48_000)
    }

    func testWaveformDisplayScale() {
        XCTAssertEqual(WaveformData.displayScale(peak: 0.05), 20, accuracy: 0.001)
        XCTAssertEqual(WaveformData.displayScale(peak: 0), 1)
        XCTAssertEqual(WaveformData.displayScale(peak: 0.00001), 100, "noise in a silent take stays small")
    }
}
