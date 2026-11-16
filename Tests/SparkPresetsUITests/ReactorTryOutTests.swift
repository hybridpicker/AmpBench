import SoundStore
import SparkControl
import XCTest
@testable import SparkPresetsUI

/// "Listen" on a sound that is not the REACTOR's own, such as an AI suggestion: the REACTOR has no temporary place,
/// so it gets its nearest sound as live commands on the slot it plays.
@MainActor
final class ReactorTryOutTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var folder: URL!

    override func setUp() async throws {
        suite = "local.ampbench.tests.reactor-tryout.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testASuggestionPlaysOnTheREACTORAsItsNearestSound() async throws {
        let device = SimulatedDevice([.reactor])
        for slot in 0..<8 { device.reactorPresets[slot] = ReactorChainFixture.preset(slot: slot, name: "Sound \(slot + 1)") }
        let link = SparkLink(transport: device, memory: DeviceMemory(defaults: defaults))
        link.reactorGap = .milliseconds(1)
        link.gap = .milliseconds(1)
        link.silence = 0.4
        let model = PresetsModel(folder: folder, link: link, store: StoreProfile.testing(stateFolder: folder))
        link.start()
        let ready = await until { link.status == .connected && link.slots.allSatisfy { $0 != nil } && link.activity == nil }
        XCTAssertTrue(ready)
        let before = device.written[device.id(.reactor)]?.count ?? 0

        let suggestion = PresetFactory.make(PresetFactory.templates[0])
        var reported: String?? = .none
        model.tryOut(suggestion) { reported = .some($0) }
        let done = await until { reported != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(reported, .some(nil), "no problem reported")

        let sent = Array((device.written[device.id(.reactor)] ?? []).dropFirst(before))
        let expected = try ReactorSound(preset: suggestion).steps().count
        XCTAssertEqual(sent.count, expected, "one live command per step, nothing else: no preset, no request")
        XCTAssertTrue(sent.contains { $0.contains(ReactorState.ampSelector) }, "the amp is chosen")
    }
}
