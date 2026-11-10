import AppKit
import Foundation
import SparkControl
import UniformTypeIdentifiers

enum TagSetting {
    static let pinnedKey = "Pinned Preset Tags"
}

/// A song from an import, for Spark Studio to make a piece of: the title and its parts, each naming its preset.
public struct ImportedSong: Sendable {
    public struct Part: Sendable {
        public let name: String
        public let presetID: String?
        public let fileName: String
        public let presetName: String
    }

    public let title: String
    public let notes: String
    public let parts: [Part]
}

// MARK: Tags

extension PresetsModel {
    /// Every tag in the library, most used first.
    var tagCounts: [(tag: String, count: Int)] { library.tagCounts }

    func isPinned(_ tag: String) -> Bool { pinnedTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }

    func togglePin(_ tag: String) {
        let text = PresetFile.tagText(tag)
        guard !text.isEmpty else { return }
        if isPinned(text) {
            pinnedTags.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        } else {
            pinnedTags.append(text)
        }
    }

    func isFiltering(by tag: String) -> Bool { tagFilter.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }

    func toggleFilter(_ tag: String) {
        if isFiltering(by: tag) {
            tagFilter.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        } else {
            tagFilter.append(tag)
        }
    }

    /// The visible presets carrying a tag, for a pinned section.
    func visibleItems(tagged tag: String) -> [SavedPreset] {
        visibleItems.filter { item in
            !item.file.isBackup && item.file.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    /// Sets a preset's tags. Typed with or without "#"; several at once may be separated by blanks or commas.
    func setTags(_ tags: [String], of item: SavedPreset) {
        changeDetails(of: item) { $0.tags = tags }
    }

    func addTags(_ text: String, to item: SavedPreset) {
        let typed = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard !typed.isEmpty else { return }
        setTags(item.file.tags + typed, of: item)
    }

    func removeTag(_ tag: String, from item: SavedPreset) {
        setTags(item.file.tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }, of: item)
    }

    func toggleTag(_ tag: String, on item: SavedPreset) {
        if item.file.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            removeTag(tag, from: item)
        } else {
            setTags(item.file.tags + [tag], of: item)
        }
    }

    func setNotes(_ notes: String, of item: SavedPreset) {
        guard notes != item.file.notes else { return }
        changeDetails(of: item) { $0.notes = notes }
    }

    private func changeDetails(of item: SavedPreset, _ change: (inout PresetFile) -> Void) {
        do {
            try library.updateDetails(item, change)
            reloadLibrary()
        } catch {
            show(.error, "„\(item.name)“ ließ sich nicht ändern: \(error.localizedDescription)")
        }
    }
}

// MARK: Kemper import

extension PresetsModel {
    /// Asks for a Kemper backup or rig file and reads it into a plan the sheet shows. Nothing is written yet.
    func chooseKemperFile() {
        let panel = NSOpenPanel()
        panel.title = "Kemper-Backup oder Rig wählen"
        panel.message = "Ein Backup vom USB-Stick (.kpabackup) oder ein einzelnes Rig (.kipr). Spark Studio liest nur."
        panel.allowedContentTypes = ["kpabackup", "kipr"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readKemper(url)
    }

    func readKemper(_ url: URL) {
        kemperIsBusy = true
        kemperError = nil
        kemperPlan = nil
        kemperFileName = url.lastPathComponent
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { KemperImportPlan(try KemperLibrary.read(url)) }
            }.value
            guard let self else { return }
            kemperIsBusy = false
            switch result {
            case .success(let plan):
                kemperPlan = plan
                if plan.performances.isEmpty && plan.rigs.isEmpty { kemperError = "In der Datei sind keine Rigs." }
            case .failure(let error):
                kemperError = error.localizedDescription
            }
        }
    }

    /// Reads a Kemper file right away, for snapshots and tests.
    func loadKemperPlan(_ url: URL) {
        kemperFileName = url.lastPathComponent
        do {
            kemperPlan = KemperImportPlan(try KemperLibrary.read(url))
            kemperError = nil
        } catch {
            kemperError = error.localizedDescription
        }
    }

    func setKind(_ kind: KemperImportPlan.Kind, ofPerformance number: Int) {
        guard let index = kemperPlan?.performances.firstIndex(where: { $0.number == number }) else { return }
        kemperPlan?.performances[index].kind = kind
    }

    func setChosen(_ chosen: Bool, rig id: Int) {
        guard let index = kemperPlan?.rigs.firstIndex(where: { $0.id == id }) else { return }
        kemperPlan?.rigs[index].isChosen = chosen
    }

    func closeKemperImport() {
        showsKemperImport = false
        kemperPlan = nil
        kemperError = nil
        kemperFileName = nil
    }

    /// Writes the plan's sounds as presets and hands its songs to Spark Studio. A sound that is already in the
    /// library under the same name and with the same chain only gets the new tags, so importing twice adds nothing.
    func performKemperImport() {
        guard let plan = kemperPlan else { return }
        do {
            let output = try plan.output()
            var existing: [String: SavedPreset] = [:]
            for item in items where !item.file.isBackup {
                if let key = try? Self.importKey(item.file.preset) { existing[key] = item }
            }
            var written: [(fileName: String, id: String?, name: String)] = []
            var new = 0
            for sound in output.sounds {
                let key = try Self.importKey(sound.preset)
                if let item = existing[key] {
                    let updated = try library.updateDetails(item, reloads: false) { $0.tags += sound.tags }
                    written.append((updated.url.lastPathComponent, updated.file.id, updated.name))
                } else {
                    let saved = try library.save(sound.preset, origin: sound.origin, tags: sound.tags,
                                                 notes: sound.notes, reloads: false)
                    written.append((saved.url.lastPathComponent, saved.file.id, saved.name))
                    new += 1
                }
            }
            reloadLibrary()
            let songs = output.songs.map { song in
                ImportedSong(title: song.title, notes: song.notes, parts: song.parts.map { part in
                    let preset = written[part.sound]
                    return ImportedSong.Part(name: part.name, presetID: preset.id, fileName: preset.fileName,
                                             presetName: preset.name)
                })
            }
            var message = "Kemper-Import: \(new) neue Presets"
            if output.sounds.count > new { message += ", \(output.sounds.count - new) schon vorhandene ergänzt" }
            message += "."
            if !songs.isEmpty {
                message += " " + (onImportSongs?(songs) ?? "\(songs.count) Songs ließen sich nicht als Stücke anlegen.")
            }
            for tag in ["basis", "song", "unterricht"] where !isPinned(tag) && output.sounds.contains(where: {
                $0.tags.contains(tag)
            }) {
                pinnedTags.append(tag)
            }
            closeKemperImport()
            show(.info, message + " Jeder Sound ist eine Annäherung: am Verstärker anhören.")
        } catch {
            kemperError = error.localizedDescription
        }
    }

    /// Same name and same chain: the same imported sound.
    private static func importKey(_ preset: SparkPreset) throws -> String {
        preset.name + "\n" + (try preset.sha256Hex())
    }
}

// MARK: REACTOR

extension PresetsModel {
    /// True when the connected device takes a sound as live commands (a REACTOR) and a preset is open.
    var canPlayOnReactor: Bool {
        link.status == .connected && link.profile.can(.liveSound) && editor.preset != nil
    }

    /// Works out the REACTOR sound for the open preset and asks before anything is sent.
    func askToPlayOnReactor() {
        guard let preset = editor.preset else { return }
        do {
            reactorRequest = try ReactorSound(preset: preset)
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func playOnReactor(_ sound: ReactorSound) {
        reactorRequest = nil
        let device = link.profile.displayName
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await link.play(sound)
                show(.info, "Am \(device) eingestellt: \(sound.summary). Master und Volume bleiben, wie sie sind. "
                     + "Der Sound gilt, bis der Platz wechselt; gespeichert wird nur am Gerät, und das überschreibt den Platz.")
            } catch {
                show(.error, "Der Sound kam nicht ganz am \(device) an: \(error.localizedDescription)")
            }
        }
    }
}
