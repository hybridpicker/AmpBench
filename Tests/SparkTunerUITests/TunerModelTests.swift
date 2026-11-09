import SparkCore
import XCTest
@testable import SparkTunerUI

/// The tuner's model with a made-up input: it listens only while its area shows, and keeps its settings.
@MainActor
final class TunerModelTests: XCTestCase {
    /// Stands in for the recorder's input. No audio device is touched.
    final class FakeInput: SharedInput {
        var device: InputDevice?
        var isHeldOpen = false
        var allowsOtherInputs = false
        var sharing: AudioTap?
        var shareCount = 0
        var failure: SharedInputError?

        init(device: InputDevice?) {
            self.device = device
        }

        func share(with tap: AudioTap) async throws {
            if let failure { throw failure }
            shareCount += 1
            sharing = tap
        }

        func stopSharing(with tap: AudioTap) {
            if sharing === tap { sharing = nil }
        }

        func isSharing(with tap: AudioTap) -> Bool { sharing === tap }
        func owns(_ device: InputDevice) -> Bool { true }
    }

    /// Stands in for the presets' link with an amp whose own tuner can be used.
    final class FakeAmp: AmpTuner {
        var ampTunerDevice: String? = "Spark NEO"
        var isAmpTunerOn = false
        var onAmpTunerReading: ((Int, Double?) -> Void)?
        var asked: [Bool] = []

        func wantAmpTuner(_ on: Bool) {
            asked.append(on)
            isAmpTunerOn = on
        }
    }

    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "local.sparkstudio.tuner.unittests")
        defaults.removePersistentDomain(forName: "local.sparkstudio.tuner.unittests")
    }

    private static let spark = InputDevice(id: 77, uid: "spark-uid", modelUID: "spark", name: "Spark MINI", channels: 2,
                                           currentRate: 48_000, maxRate: 48_000, physicalBits: 24, transport: 0)

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    func testListensOnlyWhileActive() async {
        let input = FakeInput(device: Self.spark)
        let model = TunerModel(shared: input, defaults: defaults)
        XCTAssertNil(input.sharing, "nothing is opened before the area shows")
        model.setActive(true)
        let listening = await waitUntil { model.status == .listening }
        XCTAssertTrue(listening)
        XCTAssertTrue(input.sharing === model.engine.tap)
        XCTAssertTrue(model.engine.isRunning)
        model.setActive(false)
        XCTAssertNil(input.sharing, "leaving the area stops reading the input")
        XCTAssertFalse(model.engine.isRunning)
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.readout)
    }

    func testWithoutASparkItSaysSoAndOpensNothing() async {
        let input = FakeInput(device: nil)
        let model = TunerModel(shared: input, defaults: defaults)
        model.setActive(true)
        XCTAssertEqual(model.status, .noInput)
        XCTAssertEqual(input.shareCount, 0)
        model.setActive(false)
    }

    func testMissingPermissionIsReported() async {
        let input = FakeInput(device: Self.spark)
        input.failure = .noPermission
        let model = TunerModel(shared: input, defaults: defaults)
        model.setActive(true)
        let reported = await waitUntil { model.status == .noPermission }
        XCTAssertTrue(reported)
        model.setActive(false)
    }

    func testSettingsAreKept() {
        let input = FakeInput(device: nil)
        let model = TunerModel(shared: input, defaults: defaults)
        XCTAssertEqual(model.a4, 440)
        XCTAssertEqual(model.tuning, .standard)
        model.a4 = 441.26
        model.tuning = .dadgad
        model.showsStrobe = true
        XCTAssertEqual(model.a4, 441.3, "tenths of a hertz")
        let again = TunerModel(shared: input, defaults: defaults)
        XCTAssertEqual(again.a4, 441.3)
        XCTAssertEqual(again.tuning, .dadgad)
        XCTAssertTrue(again.showsStrobe)
        again.a4 = 470
        XCTAssertEqual(again.a4, 450, "never above 450 Hz")
        again.a4 = 400
        XCTAssertEqual(again.a4, 430, "never below 430 Hz")
    }

    func testSpokenReadoutIsShortAndCalm() {
        let e = Note(midi: 40)
        let low = TunerReadout(frequency: 81, note: e, string: 6, cents: -2.6, flats: false, isHeld: false, isInTune: false)
        XCTAssertEqual(TunerModel.spoken(low), "E, 6. Saite, 3 Cent zu tief")
        let close = TunerReadout(frequency: 82.4, note: e, string: 6, cents: 0.74, flats: false, isHeld: false, isInTune: false)
        XCTAssertEqual(TunerModel.spoken(close), "E, 6. Saite, 0,7 Cent zu hoch")
        let tuned = TunerReadout(frequency: 82.4, note: e, string: 6, cents: 0.1, flats: false, isHeld: false, isInTune: true)
        XCTAssertEqual(TunerModel.spoken(tuned), "E, 6. Saite, gestimmt")
        let flat = TunerReadout(frequency: 77.8, note: Note(midi: 39), string: 6, cents: 1.2, flats: true, isHeld: false,
                                isInTune: false)
        XCTAssertEqual(TunerModel.spoken(flat), "Es, 6. Saite, 1,2 Cent zu hoch")
    }

    /// The demo for the window pictures feeds the real pipeline with a synthetic string and opens no input.
    func testDemoShowsASyntheticStringWithoutAnInput() async {
        let input = FakeInput(device: Self.spark)
        let model = TunerModel(shared: input, defaults: defaults)
        model.startDemo(frequency: 110)
        model.setActive(true)
        let found = await waitUntil { model.readout?.note == Note(midi: 45) }
        XCTAssertTrue(found)
        XCTAssertEqual(input.shareCount, 0, "the demo opens nothing")
        XCTAssertEqual(model.readout?.string, 5)
        model.setActive(false)
        model.endDemo()
    }

    func testTheAmpsTunerIsOnOnlyWhileTheAreaShows() async throws {
        let input = FakeInput(device: nil)
        let amp = FakeAmp()
        let model = TunerModel(shared: input, defaults: defaults)
        model.amp = amp
        model.setActive(true)
        _ = await waitUntil { model.status == .noInput }
        XCTAssertEqual(amp.asked, [], "the deck's input is the source until the amp is picked")

        model.choose(.amp)
        XCTAssertEqual(amp.asked, [true])
        XCTAssertEqual(model.inputName, "Stimmgerät des Spark NEO")
        let listening = await waitUntil { model.status == .listening }
        XCTAssertTrue(listening)
        for _ in 0..<6 { amp.onAmpTunerReading?(9, 4) }
        let shown = await waitUntil { model.readout != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(model.readout?.cents, 4)
        XCTAssertEqual(model.readout?.string, 5)
        XCTAssertEqual(model.readout?.isFromAmp, true)

        model.setActive(false)
        XCTAssertEqual(amp.asked, [true, false], "leaving the area switches the amp's tuner off")
        model.setActive(true)
        XCTAssertEqual(amp.asked, [true, false, true], "the choice is kept")
        model.choose(.deck)
        XCTAssertEqual(amp.asked, [true, false, true, false])
        model.setActive(false)
        XCTAssertEqual(amp.asked.count, 4)
    }

    func testTheAmpsTunerGoesOffWhenTheAmpIsGone() async {
        let amp = FakeAmp()
        let model = TunerModel(shared: FakeInput(device: nil), defaults: defaults)
        model.amp = amp
        model.choose(.amp)
        model.setActive(true)
        _ = await waitUntil { model.status == .listening }
        amp.ampTunerDevice = nil
        amp.isAmpTunerOn = false
        let gone = await waitUntil { model.status == .noInput }
        XCTAssertTrue(gone)
        XCTAssertEqual(amp.asked.last, false)
        XCTAssertEqual(model.inputName, "Kein Verstärker verbunden")
        amp.ampTunerDevice = "Spark MINI"
        let back = await waitUntil { model.status == .listening }
        XCTAssertTrue(back)
        XCTAssertEqual(amp.asked.last, true)
        model.setActive(false)
    }
}
