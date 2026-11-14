import Foundation

/// The languages AmpBench speaks. English is the language of the source: every text in the code is English, and
/// German comes from the tables in this module.
public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case german = "de"
}

public enum Texts {
    /// The key in the app's defaults that overrides the system's language: "en", "de", or absent for "as the system".
    public static let defaultsKey = "AmpBenchLanguage"
    /// The environment variable that overrides everything else, for command lines and pictures.
    public static let environmentKey = "AMPBENCH_LANGUAGE"

    private static let lock = NSLock()
    private static var chosen: AppLanguage?

    /// The language of every text `tr` returns. Decided once on first use; set it before that, or at any time in tests.
    public static var language: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let chosen { return chosen }
            let decided = decide()
            chosen = decided
            return decided
        }
        set {
            lock.lock()
            chosen = newValue
            lock.unlock()
        }
    }

    /// What the user chose in the app: nil follows the system.
    public static var override: AppLanguage? {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    /// Environment, then the user's choice, then the system's first language. Tests always run in English, so that
    /// what they compare does not depend on the machine.
    private static func decide() -> AppLanguage {
        if let forced = ProcessInfo.processInfo.environment[environmentKey].flatMap(AppLanguage.init(rawValue:)) {
            return forced
        }
        if NSClassFromString("XCTestCase") != nil { return .english }
        if let override { return override }
        return language(forPreferred: Locale.preferredLanguages)
    }

    static func language(forPreferred preferred: [String]) -> AppLanguage {
        guard let first = preferred.first?.lowercased() else { return .english }
        return first == "de" || first.hasPrefix("de-") || first.hasPrefix("de_") ? .german : .english
    }

    /// The locale for numbers and dates in texts: decimal comma in German, decimal point in English.
    public static var locale: Locale {
        Locale(identifier: language == .german ? "de_DE" : "en_US")
    }

    /// The texts were written on and for the Mac. On an iPad the same sentences name the iPad, its Files app and its
    /// Settings instead, so every text stays in one place and both platforms read right.
    static func forPad(_ text: String) -> String {
        guard text.contains("Mac") || text.contains("Finder") || text.contains("System") else { return text }
        var text = text.replacingOccurrences(of: #"\bMac\b"#, with: "iPad", options: .regularExpression)
        for (mac, pad) in [("in Finder", "in Files"), ("Im Finder", "In Dateien"), ("im Finder", "in Dateien"),
                           ("System Settings", "Settings"), ("Systemeinstellungen", "Einstellungen")] {
            text = text.replacingOccurrences(of: mac, with: pad)
        }
        return text
    }

    /// The German text for an English one, or nil when no table has it.
    public static func german(_ english: String) -> String? { German.all[english] }
}

/// The text in the app's language. `english` is the text itself and the key of the German tables; `%@`, `%d` and
/// `%1$@` take the arguments, as in `String(format:)`.
///
///     tr("Cancel")
///     tr("Slot %d of %@", slot, deviceName)
public func tr(_ english: String, _ arguments: CVarArg...) -> String {
    #if os(macOS)
    let template = Texts.language == .german ? (German.all[english] ?? english) : english
    #else
    let template = Texts.forPad(Texts.language == .german ? (German.all[english] ?? english) : english)
    #endif
    guard !arguments.isEmpty else { return template }
    return String(format: template, locale: Texts.locale, arguments: arguments)
}
