import AmpText
import Foundation

/// What to make of a Kemper backup: which performances become songs, which are basic setups or lessons, and which
/// single rigs come along. The plan is plain data so the import sheet can show and change it before anything is
/// written.
public struct KemperImportPlan: Equatable, Sendable {
    /// What a performance becomes.
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        /// A song: a piece with parts, one per slot, each with its sound.
        case song
        /// A basic setup ("Clean", "Quick Setup"): its sounds tagged #basis.
        case basis
        /// Material for lessons: its sounds tagged #unterricht.
        case lesson
        case skip

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .song: tr("Song")
            case .basis: tr("Basic setup")
            case .lesson: tr("Lessons")
            case .skip: tr("Do not import")
            }
        }

        /// The tag its sounds get. A stored value, the same in every language.
        public var tag: String? {
            switch self {
            case .song: "song"
            case .basis: "basis"
            case .lesson: "unterricht"
            case .skip: nil
            }
        }
    }

    public struct Performance: Identifiable, Equatable, Sendable {
        public var id: Int { number }
        public var number: Int
        public var name: String
        public var kind: Kind
        /// The used slots: slot number from 1, the slot's name, the translated sound.
        public var slots: [Slot]
    }

    public struct Slot: Equatable, Sendable {
        public var number: Int
        public var name: String
        public var translation: KemperTranslation.Result
    }

    public struct Rig: Identifiable, Equatable, Sendable {
        public var id: Int
        public var isChosen: Bool
        public var translation: KemperTranslation.Result
        public var name: String { translation.recipe.name }
    }

    public var performances: [Performance]
    public var rigs: [Rig]

    /// A plan for everything in the library: the player's own performances with a guessed kind, the single rigs
    /// not chosen (a backup holds a few hundred).
    public init(_ library: KemperLibrary) {
        let own = library.ownPerformances
        performances = own.map { performance in
            // Titles that repeat ("The HybridPicker" three times) get the performance's number.
            let repeats = own.filter { $0.name.caseInsensitiveCompare(performance.name) == .orderedSame }.count > 1
            let title = repeats ? "\(performance.name) \(performance.number)" : performance.name
            let slots = performance.slots.enumerated().compactMap { index, rig -> Slot? in
                guard let rig else { return nil }
                let name = performance.slotName(index)
                let soundTitle = Self.soundName(performance: title, slot: name,
                                           single: performance.slots.compactMap { $0 }.count == 1)
                return Slot(number: index + 1, name: name, translation: KemperTranslation.translate(rig, name: soundTitle))
            }
            return Performance(number: performance.number, name: title,
                               kind: Self.guess(performance.name), slots: slots)
        }.filter { !$0.slots.isEmpty }
        let single = library.performances.isEmpty
        rigs = library.rigs.enumerated().map { index, rig in
            Rig(id: index, isChosen: single, translation: KemperTranslation.translate(rig))
        }
    }

    /// Basic setups and lessons by their usual names; everything else is taken for a song. The player can change it.
    static func guess(_ name: String) -> Kind {
        let lowered = name.lowercased()
        let lessons = ["unterricht", "lesson", "übung", "licks", "schüler", "workshop"]
        if lessons.contains(where: lowered.contains) { return .lesson }
        let setups = ["setup", "clean", "crunch", "drive", "ballad", "solo", "lead", "master", "performance", "basis",
                      "rock'n'roll", "punk", "jazz", "blues", "funk", "oldschool"]
        return setups.contains(where: lowered.contains) ? .basis : .song
    }

    /// "Can't Stop · Solo", fitted to the amp's name length. A performance with one sound is named after itself.
    static func soundName(performance: String, slot: String, single: Bool) -> String {
        let cleanedSlot = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = performance.trimmingCharacters(in: .whitespacesAndNewlines)
        if single || cleanedSlot.isEmpty || cleanedSlot.caseInsensitiveCompare(base) == .orderedSame {
            return PresetFactory.fit(base)
        }
        return PresetFactory.fit("\(base) · \(cleanedSlot)")
    }

    // MARK: Result

    /// One sound to write: the preset from the recipe, its tags and notes. Equal sounds of several slots are one.
    public struct Sound: Equatable, Sendable {
        public var preset: SparkPreset
        public var tags: [String]
        public var notes: String
        public var origin: String
    }

    /// A song to make: its title and its parts in order, each naming its sound by index into `sounds`.
    public struct Song: Equatable, Sendable {
        public var title: String
        public var parts: [(name: String, sound: Int)]
        public var notes: String

        public static func == (lhs: Song, rhs: Song) -> Bool {
            lhs.title == rhs.title && lhs.notes == rhs.notes
                && lhs.parts.map(\.name) == rhs.parts.map(\.name) && lhs.parts.map(\.sound) == rhs.parts.map(\.sound)
        }
    }

    public struct Output: Equatable, Sendable {
        public var sounds: [Sound]
        public var songs: [Song]
    }

    /// The sounds and songs this plan makes. Two slots that end up as the same Spark sound (same models, same values)
    /// are one preset that carries the tags of both.
    public func output() throws -> Output {
        var sounds: [Sound] = []
        var byChain: [String: Int] = [:]

        func add(_ translation: KemperTranslation.Result, tags: [String], origin: String) throws -> Int {
            let preset = try translation.recipe.preset().preset
            let key = try preset.sha256Hex()
            let allTags = translation.recipe.tags + tags
            if let index = byChain[key] {
                sounds[index].tags = PresetFile.normalized(sounds[index].tags + allTags)
                return index
            }
            sounds.append(Sound(preset: preset, tags: PresetFile.normalized(allTags),
                                notes: translation.recipe.notes, origin: origin))
            byChain[key] = sounds.count - 1
            return sounds.count - 1
        }

        var songs: [Song] = []
        for performance in performances where performance.kind != .skip {
            let tags = [performance.kind.tag, PresetFile.hashtag(performance.name)].compactMap { $0 }
            var parts: [(String, Int)] = []
            for slot in performance.slots {
                let index = try add(slot.translation, tags: tags,
                                    origin: tr("Kemper · %@ · slot %d", performance.name, slot.number))
                parts.append((slot.name, index))
            }
            if performance.kind == .song {
                songs.append(Song(title: performance.name, parts: parts,
                                  notes: tr("From the Kemper performance %d “%@”.", performance.number, performance.name)))
            }
        }
        for rig in rigs where rig.isChosen {
            _ = try add(rig.translation, tags: [], origin: "Kemper · Rig")
        }
        return Output(sounds: sounds, songs: songs)
    }
}
