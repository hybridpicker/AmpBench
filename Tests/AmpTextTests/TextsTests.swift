import XCTest
@testable import AmpText

final class TextsTests: XCTestCase {
    override func tearDown() {
        Texts.language = .english
        super.tearDown()
    }

    func testTestsRunInEnglish() {
        XCTAssertEqual(Texts.language, .english)
    }

    func testSystemLanguageChoosesGermanOnlyForGerman() {
        XCTAssertEqual(Texts.language(forPreferred: ["de-AT", "en"]), .german)
        XCTAssertEqual(Texts.language(forPreferred: ["de"]), .german)
        XCTAssertEqual(Texts.language(forPreferred: ["en-US", "de"]), .english)
        XCTAssertEqual(Texts.language(forPreferred: ["fr-FR"]), .english)
        XCTAssertEqual(Texts.language(forPreferred: []), .english)
    }

    func testArgumentsAreFilledInAndNumbersFollowTheLanguage() {
        XCTAssertEqual(tr("%d of %@", 2, "four"), "2 of four")
        XCTAssertEqual(tr("%.1f s", 1.5), "1.5 s")
        Texts.language = .german
        XCTAssertEqual(tr("%.1f s", 1.5), "1,5 s")
    }

    func testATextWithoutGermanStaysEnglish() {
        Texts.language = .german
        XCTAssertEqual(tr("zzz no such text zzz"), "zzz no such text zzz")
    }

    /// The texts name the Mac. The iPad says "iPad", "Files" and "Settings" in the same sentences.
    func testTheIPadNamesItselfInTheMacsTexts() {
        XCTAssertEqual(Texts.forPad("Save to this Mac"), "Save to this iPad")
        XCTAssertEqual(Texts.forPad("Auf dem Mac sichern (⌘S)"), "Auf dem iPad sichern (⌘S)")
        XCTAssertEqual(Texts.forPad("Show in Finder"), "Show in Files")
        XCTAssertEqual(Texts.forPad("Im Finder zeigen"), "In Dateien zeigen")
        XCTAssertEqual(Texts.forPad("Allow access in System Settings → Privacy & Security → Bluetooth."),
                       "Allow access in Settings → Privacy & Security → Bluetooth.")
        XCTAssertEqual(Texts.forPad("Erlaube ihn unter Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon."),
                       "Erlaube ihn unter Einstellungen → Datenschutz & Sicherheit → Mikrofon.")
        // Only the whole word: a MacBook stays one, and placeholders are untouched.
        XCTAssertEqual(Texts.forPad("Sounds from your MacBook, slot %d of %@"), "Sounds from your MacBook, slot %d of %@")
    }

    /// A key in two tables must mean the same thing in both.
    func testTablesAgreeOnSharedKeys() {
        var seen: [String: (table: String, german: String)] = [:]
        for (name, table) in German.tables {
            for (english, german) in table {
                if let earlier = seen[english] {
                    XCTAssertEqual(earlier.german, german,
                                   "\"\(english)\" differs between \(earlier.table) and \(name)")
                } else {
                    seen[english] = (name, german)
                }
            }
        }
    }

    /// Placeholders must survive the translation, or `String(format:)` reads the wrong arguments.
    func testGermanKeepsThePlaceholders() {
        let placeholder = try! NSRegularExpression(pattern: #"%(\d+\$)?[-+ 0#]*\d*(\.\d+)?(@|d|ld|f|x|X)"#)
        func kinds(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            return placeholder.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        for (english, german) in German.all {
            XCTAssertEqual(kinds(english), kinds(german), "placeholders differ in \"\(english)\"")
        }
    }

    /// Every `tr("…")` in the sources has a German text. Reads the Swift files next to this test.
    func testEveryTextInTheSourcesHasGerman() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let call = try NSRegularExpression(pattern: #"\btr\(\s*"((?:[^"\\]|\\.)*)""#)
        var missing: Set<String> = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" {
            if file.path.contains("/AmpText/") { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in call.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let literal = String(source[Range(match.range(at: 1), in: source)!])
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                if German.all[literal] == nil { missing.insert("\(file.lastPathComponent): \(literal)") }
            }
        }
        XCTAssertTrue(missing.isEmpty, "no German text for:\n" + missing.sorted().joined(separator: "\n"))
    }
}
