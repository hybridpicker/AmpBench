import AmpText
import SparkControl
import SparkDesign
import SwiftUI

/// The library: every saved sound at a glance, over the area Presets, to find, hear and look after sounds.
///
/// Three columns under one header: the filters on the left (a list, so the arrow keys walk them and ⌘-click adds
/// one), the sounds as a table in the middle, grouped as chosen, and the selected sound on the right. Esc closes it.
struct LibraryOverlay: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var browser: LibraryBrowser
    @FocusState private var focus: LibraryBrowser.Focus?

    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(focus: $focus)
            Divider()
            HStack(spacing: 0) {
                LibraryFilterList()
                    .frame(width: 216)
                    .focused($focus, equals: .filters)
                Divider()
                LibraryTable()
                    .focused($focus, equals: .table)
                    .frame(minWidth: 380)
                Divider()
                LibraryPreview(focus: $focus)
                    .frame(width: 300)
            }
            Divider()
            LibraryStatusLine()
        }
        .background(Color.systemControlBackground)
        .overlay(alignment: .bottom) { BannerView().padding(14).padding(.bottom, 24) }
        .onAppear { moveFocus(browser.focusRequest ?? .search) }
        .onChange(of: browser.focusRequest) { _, request in moveFocus(request) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Library"))
        .accessibilityAddTraits(.isModal)
    }

    private func moveFocus(_ request: LibraryBrowser.Focus?) {
        guard let request else { return }
        // The views take focus a moment after they appear.
        DispatchQueue.main.async {
            focus = request
            browser.focusRequest = nil
        }
    }
}

/// The front strip with the engraved title and the close key, and below it the search and the grouping.
private struct LibraryHeader: View {
    var focus: FocusState<LibraryBrowser.Focus?>.Binding
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var browser: LibraryBrowser

    var body: some View {
        VStack(spacing: 0) {
            Faceplate {
                HStack(spacing: 14) {
                    PanelLabel(tr("Library"), size: 10, isAccessible: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(countText)
                        .font(Theme.Fonts.mono(10.5, weight: .semibold))
                        .foregroundStyle(Theme.device.amberDim)
                        .lineLimit(1)
                    Spacer()
                    Button(tr("Close")) { model.closeLibrary() }
                        .buttonStyle(.hardwareKey(keycap: "Esc", size: .small))
                        .keyboardShortcut(.cancelAction)
                        .help(tr("Closes the library (Esc)"))
                        .accessibilityIdentifier("library-close")
                }
                .padding(.horizontal, 16)
                .frame(height: 38)
            }
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(tr("Search names, amps, tags, notes – “#song” searches tags"), text: $browser.search)
                        .textFieldStyle(.plain)
                        .focused(focus, equals: .search)
                        .onSubmit { model.hearFirstMatch() }
                        .onKeyPress(.downArrow) {
                            model.selectFirstRowIfNone()
                            focus.wrappedValue = .table
                            return .handled
                        }
                        .accessibilityLabel(tr("Search the library"))
                        .accessibilityIdentifier("library-search")
                    if !browser.search.isEmpty {
                        Button {
                            browser.search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(tr("Clear the search"))
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
                .frame(maxWidth: 460)
                Spacer(minLength: 0)
                SegmentTabs(tr("Groups"), selection: $browser.grouping, options: LibraryGrouping.allCases.map {
                    ($0, $0.shortTitle)
                })
                .help(tr("How the sounds are grouped (⌘G for the next)"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var countText: String {
        let all = model.items.filter { !$0.file.isBackup }.count
        let shown = browser.rows(model.items).reduce(into: Set<URL>()) { urls, entry in
            entry.rows.forEach { urls.insert($0.url) }
        }.count
        return shown == all && !browser.query.isFiltering && browser.query.scope == .all
            ? tr("%d SOUNDS", all) : tr("%1$d OF %2$d SOUNDS", shown, all)
    }
}

extension LibraryGrouping {
    var shortTitle: String {
        switch self {
        case .none: tr("A–Z")
        case .tag: tr("Tag")
        case .amp: tr("Amp")
        case .origin: tr("Origin")
        }
    }
}

// MARK: Filters

/// The filters as a list with multiple selection: scope, origin, amp and tags. Chosen tags must all match, chosen
/// amps and origins any of them.
private struct LibraryFilterList: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var browser: LibraryBrowser
    @State private var showsRareTags = false

    var body: some View {
        let sounds = model.items.filter { !$0.file.isBackup }
        let tags = model.tagCounts.filter { $0.tag.caseInsensitiveCompare(PresetFile.listenTag) != .orderedSame }
        let common = tags.filter { $0.count > 1 || model.isPinned($0.tag) || browser.filters.contains(.tag($0.tag)) }
        let rare = tags.filter { entry in !common.contains { $0.tag == entry.tag } }
        List(selection: $browser.filters) {
            Section(tr("Show")) {
                ForEach(LibraryScope.allCases, id: \.self) { scope in
                    let count = count(scope, sounds: sounds)
                    if scope == .all || count > 0 {
                        FilterRow(title: scope.title, symbol: Self.symbol(scope), count: count)
                            .tag(LibraryFilter.scope(scope))
                    }
                }
            }
            Section(tr("Origin")) {
                let origins = Dictionary(grouping: sounds, by: SoundOrigin.of)
                ForEach(SoundOrigin.allCases.filter { $0 != .backup && origins[$0] != nil }, id: \.self) { origin in
                    FilterRow(title: origin.title, count: origins[origin]?.count ?? 0).tag(LibraryFilter.origin(origin))
                }
            }
            Section(tr("Amp")) {
                let amps = Dictionary(grouping: sounds) { $0.file.preset.ampModel ?? "" }
                    .map { (id: $0.key, name: ModelCatalog.known($0.key)?.name ?? $0.key, count: $0.value.count) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                ForEach(amps, id: \.id) { amp in
                    FilterRow(title: amp.name.isEmpty ? tr("No amp") : amp.name, count: amp.count)
                        .tag(LibraryFilter.amp(amp.id))
                }
            }
            if !tags.isEmpty {
                Section(tr("Tags")) {
                    ForEach(common, id: \.tag) { entry in
                        FilterRow(title: "#\(entry.tag)", symbol: model.isPinned(entry.tag) ? "pin.fill" : nil,
                                  count: entry.count)
                            .tag(LibraryFilter.tag(entry.tag))
                            .contextMenu { pinButton(entry.tag) }
                    }
                    if !rare.isEmpty {
                        DisclosureGroup(isExpanded: $showsRareTags) {
                            ForEach(rare, id: \.tag) { entry in
                                FilterRow(title: "#\(entry.tag)", count: entry.count)
                                    .tag(LibraryFilter.tag(entry.tag))
                                    .contextMenu { pinButton(entry.tag) }
                            }
                        } label: {
                            Text(rare.count == 1 ? tr("1 tag used once") : tr("%d tags used once", rare.count))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .modifier(SidebarListStyle())
        .amberSelection()
        .accessibilityLabel(tr("Filters"))
    }

    private func pinButton(_ tag: String) -> some View {
        Button(model.isPinned(tag) ? tr("Unpin from the sidebar") : tr("Pin to the sidebar")) { model.togglePin(tag) }
    }

    private func count(_ scope: LibraryScope, sounds: [SavedPreset]) -> Int {
        switch scope {
        case .all: sounds.count
        case .favorites: sounds.filter(\.file.favorite).count
        case .toListen: sounds.filter(\.file.needsListen).count
        case .close: browser.closeURLs.count
        case .backups: model.items.count - sounds.count
        }
    }

    static func symbol(_ scope: LibraryScope) -> String {
        switch scope {
        case .all: "square.grid.2x2"
        case .favorites: "star"
        case .toListen: "ear"
        case .close: "equal.circle"
        case .backups: "clock"
        }
    }
}

private struct FilterRow: View {
    let title: String
    var symbol: String?
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Table

private struct LibraryTable: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var browser: LibraryBrowser

    var body: some View {
        let groups = browser.rows(model.items)
        let showsHeaders = browser.grouping != .none || browser.query.scope == .close
        Group {
            if groups.allSatisfy({ $0.rows.isEmpty }) {
                VStack(spacing: 8) {
                    Text(model.items.isEmpty
                         ? tr("No sounds yet. Save a slot, create a new one or import sounds from the Kemper.")
                         : tr("No sound matches."))
                        .foregroundStyle(.secondary)
                    if browser.query.isFiltering || browser.query.scope != .all {
                        Button(tr("Show all sounds")) {
                            browser.filters = []
                            browser.search = ""
                        }
                        .linkButtonStyle()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(of: LibraryRow.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
                    TableColumn(tr("Name"), value: \.name) { row in NameCell(item: row.item) }
                        .width(min: 180, ideal: 220)
                    TableColumn(tr("Chain")) { row in ChainMiniature(preset: row.item.file.preset) }
                        .width(min: 120, ideal: 124, max: 140)
                    TableColumn(tr("Amp"), value: \.amp) { row in Text(row.amp).lineLimit(1) }
                        .width(min: 70, ideal: 110)
                    TableColumn(tr("Tags"), value: \.tags) { row in
                        Text(row.tags).foregroundStyle(Theme.desk.amber).lineLimit(1)
                    }
                    .width(min: 70, ideal: 150)
                    TableColumn(tr("Origin"), value: \.origin) { row in
                        Text(row.origin).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .width(min: 70, ideal: 160)
                    TableColumn(tr("Saved"), value: \.savedAt) { row in
                        Text(row.savedAt.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(Texts.locale)))
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 64, ideal: 76)
                } rows: {
                    ForEach(groups, id: \.group.id) { entry in
                        if showsHeaders {
                            Section {
                                ForEach(entry.rows) { TableRow($0) }
                            } header: {
                                Text("\(entry.group.title)  \(entry.rows.count)")
                            }
                        } else {
                            ForEach(entry.rows) { TableRow($0) }
                        }
                    }
                }
                .libraryRowActions { rows in
                    RowMenu(items: model.items(forRows: rows))
                } primary: { rows in
                    if let item = model.items(forRows: rows).first { model.hear(item) }
                }
                .amberSelection()
                .accessibilityLabel(tr("Sounds"))
            }
        }
    }
}

/// The name with what marks it: a star for a favorite, a wand for a recipe, a clock for a backup, and the pill
/// "To listen".
private struct NameCell: View {
    let item: SavedPreset

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(item.file.favorite ? AnyShapeStyle(Theme.desk.amber) : AnyShapeStyle(.secondary))
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(item.name).lineLimit(1)
            if item.file.needsListen { Pill(tr("To listen")) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([item.name, item.file.favorite ? tr("favorite") : nil,
                             item.file.needsListen ? tr("to listen") : nil].compactMap { $0 }.joined(separator: ", "))
    }

    private var symbol: String {
        if item.file.favorite { return "star.fill" }
        if item.file.isBackup { return "clock" }
        if item.isRecipe || SoundOrigin.of(item) == .recipe { return "wand.and.stars" }
        return "waveform"
    }
}

/// The context menu of one or more sounds, in the table and in the sidebar.
struct RowMenu: View {
    let items: [SavedPreset]
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        if let item = items.first, items.count == 1 {
            Button(tr("Hear on the amp")) { model.hear(item) }
            Button(tr("Open in the editor")) { model.openInEditor(item) }
            Menu(tr("Store on slot")) {
                ForEach(Array(model.link.profile.slots), id: \.self) { slot in
                    Button(model.link.profile.slotName(slot)) { model.askToStore(item, in: slot) }
                }
            }
            .disabled(!model.canUse(.store))
            Divider()
        }
        if !items.isEmpty {
            Button(items.allSatisfy(\.file.favorite) ? tr("Remove from favorites") : tr("Add to favorites")) {
                model.toggleFavorite(items)
            }
            Button(items.allSatisfy(\.file.needsListen) ? tr("Mark as listened to") : tr("Mark to listen to")) {
                model.toggleListen(items)
            }
            .disabled(items.allSatisfy(\.file.isBackup))
            Divider()
            Button(items.count == 1 ? tr("Rename …") : tr("Rename %d sounds …", items.count)) {
                model.beginRenameInLibrary(items)
            }
            Button(tr("Show in Finder")) { model.reveal(items.first) }
            Button(items.count == 1 ? tr("Move to Trash") : tr("Move %d sounds to the Trash", items.count)) {
                model.trashInLibrary(items)
            }
        }
    }
}

// MARK: Status line

private struct LibraryStatusLine: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var browser: LibraryBrowser

    var body: some View {
        HStack(spacing: 14) {
            let toListen = model.items.filter { !$0.file.isBackup && $0.file.needsListen }.count
            Text([tr("%d to listen", toListen),
                  browser.closeGroups.count == 1 ? tr("1 group of close sounds")
                      : tr("%d groups of close sounds", browser.closeGroups.count)]
                .joined(separator: " · "))
            if !model.unreadable.isEmpty {
                Menu(model.unreadable.count == 1 ? tr("1 file unreadable") : tr("%d files unreadable", model.unreadable.count)) {
                    ForEach(model.unreadable, id: \.self) { Text($0) }
                    Divider()
                    Button(tr("Show the folder")) { model.reveal(nil) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer(minLength: 8)
            Text(hint)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 26)
    }

    private var hint: String {
        let keys = [LibraryPlatform.hearKeycap.map { tr("%@ hear", $0) }, tr("⌘↩ open"), tr("⌘K to listen"),
                    tr("⌘T tag"), tr("⌘/ all keys")]
        // The text form of ↩, or the iPad draws it as an emoji.
        return keys.compactMap { $0 }.joined(separator: "   ").replacingOccurrences(of: "↩", with: "↩\u{FE0E}")
    }
}

extension PresetsModel {
    /// The sounds of table rows, each once, in the library's order.
    func items(forRows rows: Set<String>) -> [SavedPreset] {
        let paths = Set(rows.compactMap { $0.split(separator: "\n", maxSplits: 1).last.map(String.init) })
        return items.filter { paths.contains($0.url.path) }
    }

    /// Return in the search field: the first sound that matches plays, and the table takes the keyboard.
    func hearFirstMatch() {
        selectFirstRowIfNone()
        browser.focusRequest = .table
        hearSelection()
    }

    func selectFirstRowIfNone() {
        guard browser.selection.isEmpty, let first = browser.rows(items).first(where: { !$0.rows.isEmpty })?.rows.first
        else { return }
        browser.selection = [first.id]
    }
}
