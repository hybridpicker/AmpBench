import AmpText
import Foundation
import SparkControl

// MARK: The library overlay

extension PresetsModel {
    /// Opens the library, with the search in focus. `filter` chooses what it shows first, such as a pinned tag.
    func openLibrary(_ filter: LibraryFilter? = nil) {
        if let filter { browser.filters = [filter] }
        browser.isOpen = true
        browser.focusRequest = .search
    }

    func closeLibrary() {
        browser.isOpen = false
        browser.focusRequest = nil
    }

    func toggleLibrary() {
        if browser.isOpen { closeLibrary() } else { openLibrary() }
    }

    var librarySelection: [SavedPreset] { browser.selectedItems(items) }

    /// Plays a sound of the library on the amp's temporary place, for listening. Nothing is stored and the editor
    /// keeps what it holds.
    func hear(_ item: SavedPreset) {
        tryOut(item.file.preset) { [weak self] problem in
            if problem == nil, !item.file.isBackup { self?.browser.remember(item) }
        }
    }

    func hearSelection() {
        guard let item = librarySelection.first else { return }
        hear(item)
    }

    /// Opens a sound in the editor, as a click in the sidebar does, and closes the library.
    func openInEditor(_ item: SavedPreset) {
        closeLibrary()
        select(.saved(item.url))
    }

    func openSelectionInEditor() {
        guard librarySelection.count == 1, let item = librarySelection.first else { return }
        openInEditor(item)
    }

    /// Selects the sounds' rows in the library, the first group each is in.
    func selectInLibrary(_ wanted: [SavedPreset]) {
        let urls = Set(wanted.map(\.url))
        var rows: Set<String> = []
        var seen: Set<URL> = []
        for (_, groupRows) in browser.rows(items) {
            for row in groupRows where urls.contains(row.url) && seen.insert(row.url).inserted { rows.insert(row.id) }
        }
        browser.selection = rows
    }

    /// The pieces using a sound, as "Piece · Part", or nil where the pieces are not known.
    func pieces(using item: SavedPreset) -> [String]? {
        presetUses?(item.file.id, item.url.lastPathComponent)
    }

    // MARK: Sidebar

    /// The favorite sounds, by name.
    var favoriteItems: [SavedPreset] { items.filter { $0.file.favorite && !$0.file.isBackup } }

    /// The sounds opened or heard last, newest first, favorites left out since they are listed already.
    var recentItems: [SavedPreset] {
        let byKey = Dictionary(items.map { (LibraryBrowser.recentKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        return browser.recent.compactMap { byKey[$0] }.filter { !$0.file.favorite && !$0.file.isBackup }
            .prefix(LibraryBrowser.recentLimit).map { $0 }
    }

    // MARK: Changing several sounds at once

    /// Applies a change to each sound's details and reloads once. A recipe becomes an ordinary preset file this way.
    func changeDetails(of targets: [SavedPreset], _ change: (inout PresetFile) -> Void) {
        var failed: [String] = []
        for item in targets {
            do {
                try library.updateDetails(item, reloads: false, change)
            } catch {
                failed.append(item.name)
            }
        }
        reloadLibrary()
        if !failed.isEmpty {
            show(.error, tr("These sounds could not be changed: %@", failed.joined(separator: ", ")))
        }
    }

    /// Favorites when not all of them are, otherwise none.
    func toggleFavorite(_ targets: [SavedPreset]) {
        guard !targets.isEmpty else { return }
        let on = !targets.allSatisfy(\.file.favorite)
        changeDetails(of: targets) { $0.favorite = on }
    }

    /// Marks the sounds as wanting a listen when not all of them do, otherwise as listened to.
    func toggleListen(_ targets: [SavedPreset]) {
        let targets = targets.filter { !$0.file.isBackup }
        guard !targets.isEmpty else { return }
        let on = !targets.allSatisfy(\.file.needsListen)
        changeDetails(of: targets) { $0.needsListen = on }
        show(.info, on ? (targets.count == 1 ? tr("“%@” is marked to listen to.", targets[0].name)
                                             : tr("%d sounds are marked to listen to.", targets.count))
                       : (targets.count == 1 ? tr("“%@” is marked as listened to.", targets[0].name)
                                             : tr("%d sounds are marked as listened to.", targets.count)))
    }

    /// Adds typed tags to every sound. Typed with or without "#", several separated by blanks or commas.
    func addTags(_ text: String, to targets: [SavedPreset]) {
        let typed = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard !typed.isEmpty, !targets.isEmpty else { return }
        changeDetails(of: targets.filter { !$0.file.isBackup }) { $0.tags += typed }
    }

    func removeTag(_ tag: String, from targets: [SavedPreset]) {
        let carrying = targets.filter { $0.file.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        guard !carrying.isEmpty else { return }
        changeDetails(of: carrying) { file in file.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    // MARK: Renaming

    /// Renames one sound with the usual sheet, several with find and replace.
    func beginRenameInLibrary(_ targets: [SavedPreset]? = nil) {
        let targets = targets ?? librarySelection
        if targets.count == 1 { beginRename(targets[0]) } else if !targets.isEmpty {
            browser.renameItems = targets
            browser.renameFind = ""
            browser.renameReplace = ""
        }
    }

    /// The new name of each sound for the find and replace, and what is wrong with it, if anything.
    func renamePlan() -> [(item: SavedPreset, name: String, problem: String?)] {
        let find = browser.renameFind
        return (browser.renameItems ?? []).map { item in
            guard !find.isEmpty else { return (item, item.name, nil) }
            let name = item.name.replacingOccurrences(of: find, with: browser.renameReplace, options: .caseInsensitive)
            return (item, name, PresetRules.problem(withName: name))
        }
    }

    func commitBatchRename() {
        let plan = renamePlan().filter { $0.name != $0.item.name }
        browser.renameItems = nil
        guard !plan.isEmpty else { return }
        var renamed: [SavedPreset] = []
        var failed: [String] = []
        for step in plan where step.problem == nil {
            do {
                let new = try library.rename(step.item, to: step.name)
                followRename(of: step.item.url, to: new)
                renamed.append(new)
            } catch {
                failed.append(step.item.name)
            }
        }
        failed += plan.filter { $0.problem != nil }.map(\.item.name)
        reloadLibrary()
        selectInLibrary(renamed)
        show(failed.isEmpty ? .info : .warning, failed.isEmpty
             ? (renamed.count == 1 ? tr("1 sound renamed.") : tr("%d sounds renamed.", renamed.count))
             : tr("%1$d sounds renamed. Not renamed: %2$@", renamed.count, failed.joined(separator: ", ")))
    }

    // MARK: Moving to the Trash

    /// Moves the library's selected sounds to the Trash. When pieces use one of them, asks first and names them.
    func trashInLibrary(_ targets: [SavedPreset]? = nil) {
        let targets = targets ?? librarySelection
        guard !targets.isEmpty else { return }
        if targets.contains(where: { !(pieces(using: $0) ?? []).isEmpty }) {
            browser.trashRequest = targets
        } else {
            trash(targets)
        }
    }

    /// The pieces using any of the sounds, each once.
    func pieces(using targets: [SavedPreset]) -> [String] {
        var seen = Set<String>()
        return targets.flatMap { pieces(using: $0) ?? [] }.filter { seen.insert($0).inserted }
    }

    /// Moves several sounds to the Trash at once. The banner's "Undo" brings them all back.
    func trash(_ targets: [SavedPreset]) {
        browser.trashRequest = nil
        guard targets.count > 1 else {
            if let item = targets.first { trash(item) }
            return
        }
        var moved: [(from: URL, to: URL)] = []
        var failed: [String] = []
        for item in targets {
            do {
                if let place = try PresetLibrary.discard(item.url, in: library.folder) { moved.append((item.url, place)) }
                closeEditor(ifShowing: item.url)
            } catch {
                failed.append(item.name)
            }
        }
        reloadLibrary()
        let text = failed.isEmpty ? tr("%d sounds are in the Trash.", moved.count)
            : tr("%1$d sounds are in the Trash. Not moved: %2$@", moved.count, failed.joined(separator: ", "))
        show(failed.isEmpty ? .info : .warning, text, undo: { [weak self] in
            guard let self else { return }
            for step in moved { try? FileManager.default.moveItem(at: step.to, to: step.from) }
            reloadLibrary()
            banner = nil
        })
    }
}
