import SparkDesign
import XCTest

/// Every text color of the design against every background it is drawn on, at least 4.5 : 1 (WCAG AA).
final class ContrastTests: XCTestCase {
    private let device = Theme.device
    private let desk = Theme.desk

    private func assertReadable(_ text: Swatch, on background: Swatch, _ name: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let ratio = text.contrast(with: background)
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name): \(String(format: "%.2f", ratio)) : 1", file: file, line: line)
    }

    /// The darkest and the lightest point of the front, and the display.
    private var deviceBackgrounds: [(String, Swatch)] {
        [("front bottom", device.faceBottom), ("front top", device.faceTop), ("display", device.display),
         ("pedal", device.pedalTop), ("panel", device.panelTop), ("board", device.board), ("field", device.field)]
    }

    func testTextOnTheDevice() {
        let texts: [(String, Swatch)] = [
            ("label", device.label), ("label dim", device.labelDim), ("engraving", device.engraving),
            ("amber", device.amber), ("amber dim", device.amberDim), ("amber hot", device.amberHot),
            ("record text", device.recordText), ("listening", device.listening), ("on", device.on),
            ("lamp off text", device.lampOffText), ("field text", device.fieldText),
        ]
        for (textName, text) in texts {
            for (backgroundName, background) in deviceBackgrounds {
                assertReadable(text, on: background, "\(textName) on \(backgroundName)")
            }
        }
    }

    func testTextOnKeys() {
        let keyMiddle = device.keyTop.over(device.keyBottom.opacity(0.5))
        for key in [device.keyTop, device.keyBottom, keyMiddle] {
            assertReadable(device.keyText, on: key, "key text")
            assertReadable(device.dangerText, on: key, "danger text")
            assertReadable(device.keycapText, on: device.keycapBack.over(key), "keycap")
        }
        for key in [device.primaryTop, device.primaryBottom, device.onTop, device.onBottom] {
            assertReadable(device.primaryText, on: key, "text on amber key")
            assertReadable(device.keycapTextOnAmber, on: device.keycapBackOnAmber.over(key), "keycap on amber key")
        }
    }

    func testNameplates() {
        // The seven chain colors of Spark Presets, as on the canvas.
        let accents: [UInt32] = [0x8CA6AE, 0x5C9EEB, 0xF28A3C, 0xF7C45C, 0xB088F2, 0x4DCCA8, 0x8CCCFA]
        for accent in accents {
            assertReadable(device.nameplateText, on: Swatch(hex: accent), String(format: "nameplate %06X", accent))
            // The engraving "Verzerrer · Platz 3 von 7" is written in the accent color on the panel.
            assertReadable(Swatch(hex: accent), on: device.panelTop, String(format: "accent %06X on panel", accent))
        }
    }

    func testAmpText() {
        assertReadable(device.amber, on: device.brassBottom, "amp name on brass")
        assertReadable(device.brassText, on: device.brassBottom, "AMP on brass")
        assertReadable(device.ampGroup, on: device.tolex, "amp group on tolex")
    }

    func testTextOnTheDesk() {
        let pairs: [(String, DeskSwatch)] = [
            ("pill amber", desk.pillAmberText), ("pill green", desk.pillGreenText),
        ]
        for (name, text) in pairs {
            for (backgroundName, background) in [("window", desk.windowBackground), ("content", desk.contentBackground)] {
                assertReadable(text.light, on: desk.pillAmberBack.light.over(background.light), "\(name) light on \(backgroundName)")
                assertReadable(text.dark, on: desk.pillAmberBack.dark.over(background.dark), "\(name) dark on \(backgroundName)")
            }
            // On a selected row as well.
            assertReadable(text.light, on: desk.selection.light.over(desk.contentBackground.light), "\(name) light, selected")
            assertReadable(text.dark, on: desk.selection.dark.over(desk.contentBackground.dark), "\(name) dark, selected")
        }
    }

    /// Lines and bars are no text, but they must stand out from their background at 3 : 1.
    func testMarksOnTheDesk() {
        let marks: [(String, DeskSwatch)] = [("wave", desk.wave), ("marker", desk.marker), ("playhead", desk.playhead)]
        for (name, mark) in marks {
            XCTAssertGreaterThanOrEqual(mark.light.contrast(with: desk.waveBackground.light), 3, "\(name) light")
            XCTAssertGreaterThanOrEqual(mark.dark.contrast(with: desk.waveBackground.dark), 3, "\(name) dark")
        }
        for (name, bar) in [("chart bar", desk.chartBar), ("today", desk.chartToday), ("amber", desk.amber)] {
            XCTAssertGreaterThanOrEqual(bar.light.contrast(with: desk.contentBackground.light), 3, "\(name) light")
            XCTAssertGreaterThanOrEqual(bar.dark.contrast(with: desk.contentBackground.dark), 3, "\(name) dark")
        }
    }

    func testCompositing() {
        let half = Swatch.white(0.5).over(Swatch(hex: 0x000000))
        XCTAssertEqual(half.red, 0.5, accuracy: 0.001)
        XCTAssertEqual(Swatch(hex: 0xFFFFFF).contrast(with: Swatch(hex: 0x000000)), 21, accuracy: 0.01)
    }
}
