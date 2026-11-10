/// The German texts, keyed by the English text in the code. One table per module, each in its own file, so that a
/// change to one area touches one file. A key in two tables must have the same German text; a test checks that, and
/// that every `tr("…")` in the sources has an entry.
enum German {
    static let tables: [(name: String, table: [String: String])] = [
        ("Core", core), ("Design", design), ("Control", control), ("RecorderUI", recorderUI),
        ("PresetsUI", presetsUI), ("TunerUI", tunerUI), ("App", app),
    ]

    static let all: [String: String] = {
        var merged: [String: String] = [:]
        for (_, table) in tables { merged.merge(table) { first, _ in first } }
        return merged
    }()
}
