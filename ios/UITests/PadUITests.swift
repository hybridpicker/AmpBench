import XCTest

/// Drives AmpBench on the iPad simulator the way a player would, with fingers. Every test starts the app with a
/// test library (`--library`): made-up presets, a simulated Spark MINI instead of Bluetooth, and a sound store
/// profile apart from the real one. No test opens the microphone or talks to a real amp or server.
///
/// With `AMPBENCH_PICTURES=<folder>` in the environment the tests also write pictures of what they see, for the docs.
final class PadUITests: XCTestCase {
    private var library = ""

    override func setUp() {
        continueAfterFailure = false
        // The simulator shares the Mac's files, so a folder under /tmp is one for the app too.
        library = "/tmp/ampbench-uitest-\(UUID().uuidString)"
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: library)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--library", library] + arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func picture(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["AMPBENCH_PICTURES"], !folder.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let shot = XCUIScreen.main.screenshot().image
        // The picture carries its turn as a note beside the pixels, which a PNG drops. Drawn once more, the pixels
        // themselves are upright.
        let format = UIGraphicsImageRendererFormat()
        format.scale = shot.scale
        let image = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in shot.draw(at: .zero) }
        try? image.pngData()?.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
    }

    /// The Mac's editor on the iPad: a saved preset opens, plays on the simulated amp, and a finger turns a knob.
    func testAFingerTurnsAKnob() {
        let app = launch(["--demo-devices", "mini", "--open", "saved:Lead"])
        let gain = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Gain'")).firstMatch
        XCTAssertTrue(gain.waitForExistence(timeout: 20), "the editor did not open the preset")
        XCTAssertTrue(app.staticTexts["On this iPad"].firstMatch.exists, "the iPad must name itself, not the Mac")
        picture("ipad-presets")

        let before = gain.value as? String
        let start = gain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -70)))
        let after = gain.value as? String
        XCTAssertNotNil(before)
        XCTAssertNotEqual(before, after, "dragging up on a knob must turn it")
        XCTAssertGreaterThan(Double(after ?? "") ?? 0, Double(before ?? "") ?? 0)
    }

    /// The tuner shows a made-up string through its real pipeline. No input is opened.
    func testTheTunerShowsAString() {
        let app = launch(["--tuner-demo"])
        XCTAssertTrue(app.buttons["Tuner"].waitForExistence(timeout: 20))
        // 110 Hz less 3.4 cents: the A string, a little flat.
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'A' AND label CONTAINS 'string'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "the tuner shows no note")
        picture("ipad-tuner")
    }

    /// The sound store's sheet opens from the sidebar and makes a key, which then stays hidden until asked for.
    func testTheSoundStoreIsSetUpFromTheSidebar() {
        let app = launch(["--offline"])
        let setUp = app.buttons["Set up"]
        XCTAssertTrue(setUp.waitForExistence(timeout: 20), "the sidebar has no sound store")
        setUp.tap()
        let create = app.buttons["Create a new key"]
        if create.waitForExistence(timeout: 5) {
            create.tap()
        }
        XCTAssertTrue(app.buttons["Show key …"].waitForExistence(timeout: 5), "no key was made")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'AGE-SECRET-KEY-'")).firstMatch.exists,
                       "the key must not show before it is asked for")
        // A store over SSH needs the Mac's ssh: the iPad offers a folder or an HTTPS address.
        XCTAssertTrue(app.buttons["Folder"].exists)
        XCTAssertTrue(app.buttons["Server (HTTPS)"].exists)
        XCTAssertFalse(app.buttons["Server (SSH)"].exists)
        picture("ipad-store")
    }

    /// The Mac's sheets have fixed widths. On the iPad they must still show whole, with their buttons in reach.
    func testTheMacsSheetsFitTheIPad() {
        let app = launch(["--offline"])
        // The template sheet from the empty editor, the Kemper import from the sidebar's "+" menu.
        let new = app.buttons["new-preset-menu"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 20))
        let steps: [(name: String, picture: String, open: () -> Void)] = [
            ("templates", "ipad-templates", { app.buttons["From template …"].firstMatch.tap() }),
            ("Kemper import", "ipad-kemper", {
                new.tap()
                let entry = app.buttons["Import from Kemper …"].firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 5), "the menu has no Kemper import")
                entry.tap()
            }),
        ]
        for step in steps {
            step.open()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the sheet for \(step.name) did not open")
            XCTAssertTrue(cancel.isHittable, "the sheet for \(step.name) is cut off: its Cancel cannot be reached")
            XCTAssertTrue(app.frame.contains(cancel.frame))
            picture(step.picture)
            cancel.tap()
            XCTAssertTrue(new.waitForExistence(timeout: 5))
        }
    }

    /// The library opens over the area from the sidebar, finds a sound by its name and shows it, and closes again.
    func testTheLibraryFindsASound() {
        let app = launch(["--offline", "--made-up-sounds"])
        let entry = app.buttons["library-entry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "the sidebar has no way into the library")
        entry.tap()
        let search = app.textFields["library-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the library did not open")
        search.tap()
        search.typeText("harbor verse")
        let row = app.staticTexts["Glass Harbor Verse"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the search does not find the sound")
        row.tap()
        XCTAssertTrue(app.buttons["Hear"].waitForExistence(timeout: 5), "the preview does not show the sound")
        XCTAssertTrue(app.staticTexts["Harbor clean (old)"].exists, "the preview shows the sound's close one")
        app.buttons["library-close"].firstMatch.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "closing must bring back sidebar and editor")
        app.terminate()

        // The picture without the on-screen keyboard: the library opened at the start, a song's sounds by tag.
        let shown = launch(["--offline", "--made-up-sounds", "--library-open", "#song", "--library-group", "tag",
                            "--library-select", "Glass Harbor Verse"])
        XCTAssertTrue(shown.buttons["Hear"].waitForExistence(timeout: 20), "the library did not open at the start")
        picture("ipad-library")
    }
}
