import AmpText
import Foundation
import SparkControl

/// About a hundred made-up sounds for a test library, so the library can be seen and checked at a realistic size
/// without one's own presets: `--library <test folder> --made-up-sounds`. Songs, basic setups and lessons as a Kemper
/// import makes them, some recipes, sounds saved from slots, backups, favorites, and a few close sounds. Every name
/// is invented. Only ever written into a test library's own folder.
@MainActor
enum MadeUpLibrary {
    static let songs = ["Glass Harbor", "Northbound Lights", "Paper Tigers", "Slow River", "Copper Sky",
                        "Night Shift", "Lantern Hill", "Velvet Static", "Echo Garden", "Iron Meadow",
                        "Blue Window", "Silver Thread"]
    static let parts = ["Intro", "Verse", "Chorus", "Bridge", "Solo", "Outro"]

    /// Fills `folder` once: nothing is written when it already holds more than the templates.
    static func fill(_ folder: URL) {
        let library = PresetLibrary(folder: folder)
        try? library.reload()
        guard library.items.count < 20 else { return }
        var random = Generator(seed: 7)
        let amps = ModelCatalog.models(for: .amp).map(\.id)
        let drives = ModelCatalog.models(for: .drive).map(\.id)
        let delays = ModelCatalog.models(for: .delay).map(\.id)
        let modulations = ModelCatalog.models(for: .modulation).map(\.id)
        let base = PresetFactory.templates.map(\.preset)
        let date = Date(timeIntervalSince1970: 1_793_000_000)

        func sound(_ name: String, amp: String? = nil) -> SparkPreset {
            var preset = base[random.next(base.count)]
            preset.uuid = UUID().uuidString
            preset.name = name
            let ampID = amp ?? amps[random.next(amps.count)]
            preset.effects[3] = PresetFactory.effect(ampID, on: true, [0: random.value(), 1: random.value(),
                                                                       2: random.value()])
            if random.next(3) == 0 {
                preset.effects[2] = PresetFactory.effect(drives[random.next(drives.count)], on: true, [0: random.value()])
            }
            if random.next(3) == 0 {
                preset.effects[5] = PresetFactory.effect(delays[random.next(delays.count)], on: true, [0: random.value()])
            }
            if random.next(4) == 0 {
                preset.effects[4] = PresetFactory.effect(modulations[random.next(modulations.count)], on: true)
            }
            preset.bpm = Float(70 + random.next(80))
            return preset
        }

        func save(_ preset: SparkPreset, origin: String, tags: [String] = [], notes: String = "",
                  favorite: Bool = false, backup: Bool = false, days: Int) {
            guard let saved = try? library.save(preset, origin: origin, isBackup: backup, tags: tags, notes: notes,
                                                date: date.addingTimeInterval(Double(days) * 86_400),
                                                reloads: false) else { return }
            if favorite { _ = try? library.updateDetails(saved, reloads: false) { $0.favorite = true } }
        }

        // Songs, as a Kemper import writes them: one sound per slot, tags "song" and the song's own.
        for (index, song) in songs.enumerated() {
            let count = 4 + index % 3
            let amp = amps[random.next(amps.count)]
            for slot in 0..<count {
                let part = parts[slot % parts.count]
                var tags = ["song", PresetFile.hashtag(song)]
                if (index + slot) % 3 != 0 { tags.append(PresetFile.listenTag) }
                save(sound("\(song) \(part)", amp: slot % 2 == 0 ? amp : nil),
                     origin: "Kemper · \(song) · slot \(slot + 1)", tags: tags,
                     notes: "Made-up rig “\(song) \(part)”.", days: index)
            }
        }
        // Basic setups and lessons.
        for number in 1...3 {
            for slot in 1...5 {
                save(sound("Basis \(number) · \(slot)"), origin: "Kemper · Basis \(number) · slot \(slot)",
                     tags: ["basis", "Basis\(number)"] + (slot == 1 ? [] : [PresetFile.listenTag]), days: 14 + number)
            }
        }
        for (number, lesson) in ["Lesson Rhythm", "Lesson Blues"].enumerated() {
            for slot in 1...5 {
                save(sound("\(lesson) \(slot)"), origin: "Kemper · \(lesson) · slot \(slot)",
                     tags: ["unterricht", PresetFile.hashtag(lesson)], days: 20 + number)
            }
        }
        // Recipes, sounds from the amp, favorites, and close sounds the import did not merge.
        for (index, name) in ["Warm Jazz Box", "Surf Spring", "Desert Fuzz", "Shimmer Pad", "Tight Rhythm"].enumerated() {
            save(sound(name), origin: "Recipe", tags: index < 2 ? ["clean"] : [], favorite: index == 0, days: 25 + index)
        }
        for slot in 1...4 {
            save(sound("Spark slot \(slot) sound"), origin: "Slot \(slot) · Spark MINI", favorite: slot == 2,
                 days: 30 + slot)
        }
        try? library.reload()
        if let first = library.items.first(where: { $0.name == "Glass Harbor Verse" }) {
            var copy = first.file.preset
            copy.name = "Harbor clean (old)"
            save(copy, origin: "Newly created", tags: ["clean"], favorite: true, days: 40)
            copy.name = "Harbor clean, brighter"
            copy.effects[3].parameters[0].value = min(1, copy.effects[3].parameters[0].value + 0.08)
            save(copy, origin: "Newly created", days: 41)
        }
        for slot in 1...3 {
            save(sound("Slot \(slot) before"), origin: "Slot \(slot) · Spark MINI, before overwriting", backup: true,
                 days: 42 + slot)
        }
    }

    /// The made-up songs as pieces, for AmpBench's test library, the same way a Kemper import hands them over.
    static func songs(in items: [SavedPreset]) -> [ImportedSong] {
        songs.map { song in
            let parts = items.filter { $0.file.origin.hasPrefix("Kemper · \(song) · ") }.map { item in
                ImportedSong.Part(name: String(item.name.dropFirst(song.count + 1)), presetID: item.file.id,
                                  fileName: item.url.lastPathComponent, presetName: item.name)
            }
            return ImportedSong(title: song, notes: "", parts: parts)
        }.filter { !$0.parts.isEmpty }
    }

    /// A small fixed sequence, so the made-up library is the same on every run.
    struct Generator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(max(bound, 1)))
        }
        mutating func value() -> Float { Float(next(1000)) / 1000 }
    }
}
