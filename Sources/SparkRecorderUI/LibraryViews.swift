import AmpText
import Charts
import SparkCore
import SparkDesign
import SwiftUI

/// The lower part of the window: library on the left, the selected recording on the right.
struct LibraryArea: View {
    @EnvironmentObject private var model: AppModel

    @FocusState private var searchFocused: Bool

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    SegmentTabs(tr("Library view"), selection: $model.tab,
                                options: LibraryTab.allCases.map { ($0, $0.title) })
                    Spacer(minLength: 8)
                    if let progress = model.exportProgress {
                        ProgressView(value: progress) { Text(tr("Export")).font(.caption) }
                            .frame(width: 110)
                    }
                    CurrentPiecePicker()
                    TextField(tr("Search"), text: $model.query.search)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .frame(minWidth: 100, maxWidth: 180)
                        .accessibilityLabel(tr("Search takes"))
                        .onChange(of: model.query.search) { if !model.query.search.isEmpty { model.tab = .recordings } }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(
                    // ⌘F focuses the search without taking a key from the shortcuts.
                    Button("") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .hidden()
                        .accessibilityHidden(true)
                )
                Divider()
                switch model.tab {
                case .recordings: RecordingsPane()
                case .pieces: PiecesPane()
                case .stats: StatsPane()
                }
                Divider()
                LibraryStatusLine()
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            InspectorPane()
                .frame(minWidth: 290, idealWidth: 330, maxWidth: 420, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Always in view, because it decides where the next recording goes.
private struct CurrentPiecePicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            DeskCaption(tr("New takes in")).fixedSize()
            Picker(tr("New takes in"), selection: Binding(get: { model.currentPieceID }, set: { model.setCurrentPiece($0) })) {
                Text(tr("None")).tag(UUID?.none)
                ForEach(model.pieces) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(minWidth: 100, maxWidth: 170)
            .accessibilityLabel(tr("Piece for new takes"))
            Button {
                model.beginNewPiece()
            } label: {
                Image(systemName: "plus")
            }
            .controlSize(.small)
            .help(tr("Create a new piece"))
            .accessibilityLabel(tr("Create a new piece"))
        }
    }
}

// MARK: - Recordings

struct RecordingsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if model.recordings.isEmpty {
                ContentUnavailableView(tr("No takes yet"), systemImage: "waveform",
                                       description: Text(model.selectedInput == nil
                                                         ? tr("Connect the Spark, then press R and start playing. Files in the folder are recognized automatically.")
                                                         : tr("Press R and start playing. Files in the folder are recognized automatically.")))
            } else {
                table
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $model.query.onlyFavorites) {
                Image(systemName: "heart.fill")
            }
            .toggleStyle(.button)
            .help(tr("Favorites only"))
            .accessibilityLabel(tr("Favorites only"))

            Picker(tr("Rating"), selection: $model.query.minimumRating) {
                Text(tr("All stars")).tag(0)
                ForEach(1...5, id: \.self) { Text(tr("%d ★ and up", $0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 96)
            .accessibilityLabel(tr("Minimum rating"))

            Picker(tr("Status"), selection: $model.query.status) {
                Text(tr("All takes")).tag(LibraryQuery.StatusFilter.all)
                Text(tr("Open")).tag(LibraryQuery.StatusFilter.open)
                Text(tr("Kept")).tag(LibraryQuery.StatusFilter.kept)
            }
            .labelsHidden()
            .frame(width: 96)
            .accessibilityLabel(tr("Status"))

            Picker(tr("Piece"), selection: $model.query.piece) {
                Text(tr("All pieces")).tag(LibraryQuery.PieceFilter?.none)
                Text(tr("No piece")).tag(LibraryQuery.PieceFilter?.some(.none))
                ForEach(model.pieces) { Text($0.name).tag(LibraryQuery.PieceFilter?.some(.piece($0.id))) }
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel(tr("Piece"))

            Picker(tr("Tag"), selection: $model.query.tag) {
                Text(tr("All tags")).tag(String?.none)
                ForEach(tags, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 96)
            .accessibilityLabel(tr("Tag"))

            if model.query.isActive {
                Button {
                    model.query = LibraryQuery()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help(tr("Reset all filters"))
                .accessibilityLabel(tr("Reset all filters"))
            }

            Button {
                model.discard()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.isRecording || model.selection.isEmpty)
            .help(tr("Move selected takes to the Trash (⌘⌫). Can be undone with ⌘Z."))
            .accessibilityLabel(tr("Move selected takes to the Trash"))
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var tags: [String] {
        Array(Set(model.recordings.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var table: some View {
        Table(model.visibleRecordings, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn(tr("Name"), value: \.name) { recording in
                NameCell(recording: recording)
            }
            .width(min: 150, ideal: 240)
            TableColumn(tr("Date"), value: \.createdAt) { recording in
                Text(recording.createdAt, format: .dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits).hour().minute().locale(Texts.locale))
                    .font(Theme.Fonts.mono(12))
            }
            .width(min: 100, ideal: 126)
            TableColumn(tr("Length"), value: \.duration) { recording in
                Text(TimeText.clock(recording.duration)).font(Theme.Fonts.mono(12))
            }
            .width(min: 44, ideal: 52)
            TableColumn(tr("Rating"), value: \.rating) { recording in
                Stars(rating: recording.rating)
                    .accessibilityLabel(tr("%d of 5 stars", recording.rating))
            }
            .width(min: 66, ideal: 72)
            TableColumn("♥", value: \.favoriteRank) { recording in
                Image(systemName: recording.favorite ? "heart.fill" : "heart")
                    .foregroundStyle(recording.favorite ? Color.pink : Color.secondary)
                    .accessibilityLabel(recording.favorite ? tr("Favorite") : tr("Not a favorite"))
            }
            .width(22)
            TableColumn(tr("Piece")) { recording in
                HStack(spacing: 3) {
                    if model.isBestTake(recording) {
                        Image(systemName: "crown.fill").foregroundStyle(Theme.desk.amber.color).accessibilityLabel(tr("Best take"))
                    }
                    Text(model.pieceName(recording.pieceID)).lineLimit(1)
                }
            }
            .width(min: 60, ideal: 90)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            if let id = ids.first {
                model.select(id)
                model.togglePlay()
            }
        }
        .amberSelection()
        .onChange(of: model.selection) { model.selectionChanged() }
    }

    @ViewBuilder
    private func contextMenu(_ menuIDs: Set<UUID>) -> some View {
        // A click beside the rows delivers no ids. The menu then acts on what is marked, and says so.
        let ids = RemovalTargets.resolve(menuIDs: menuIDs, selection: model.selection, current: nil)
        if ids.count == 1, let id = ids.first {
            Button(tr("Rename …")) { model.beginRename(id) }
            Button(tr("Show in Finder")) { model.reveal(id) }
            Divider()
        } else if ids.count == 2 {
            Button(tr("Compare")) {
                model.selection = ids
                model.startCompare()
            }
            Divider()
        }
        Menu(tr("Assign to piece")) {
            Button(tr("None")) { model.assign(ids, toPiece: nil) }
            ForEach(model.pieces) { piece in
                Button(piece.name) { model.assign(ids, toPiece: piece.id) }
            }
            Divider()
            Button(tr("New piece …")) { model.beginNewPiece(assigning: ids) }
        }
        .disabled(ids.isEmpty)
        Divider()
        Button(ids.count > 1 ? tr("Move %d takes to Trash", ids.count) : tr("Move to Trash")) { model.discard(ids) }
            .disabled(model.isRecording || ids.isEmpty)
    }
}

private struct NameCell: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 5) {
            switch recording.health {
            case .missing:
                Image(systemName: "questionmark.folder").foregroundStyle(.secondary).accessibilityLabel(tr("File missing"))
            case .damaged:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.desk.amber).accessibilityLabel(tr("File damaged"))
            case .ok:
                EmptyView()
            }
            Text(recording.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(recording.health == .ok ? Color.primary : Color.secondary)
            if recording.status == .open {
                Pill(tr("Open"))
            }
            if recording.recoveredAfterInterruption {
                Image(systemName: "bandage").foregroundStyle(.secondary)
                    .help(tr("Repaired after an interruption"))
                    .accessibilityLabel(tr("Repaired after an interruption"))
            }
        }
    }
}

/// A practice time, such as "1 h 56 min" or "4.5 min"; below ten minutes with one decimal, unless that is a zero.
func minutesText(_ minutes: Double) -> String {
    if minutes >= 60 {
        return tr("%d h %d min", Int(minutes / 60), Int(minutes) % 60)
    }
    guard minutes < 10, minutes > 0 else { return tr("%d min", Int(minutes)) }
    let tenths = (minutes * 10).rounded() / 10
    return tenths == tenths.rounded() ? tr("%d min", Int(tenths)) : tr("%.1f min", tenths)
}


/// Five stars, the given number of them amber.
private struct Stars: View {
    let rating: Int

    var body: some View {
        let filled = min(max(rating, 0), 5)
        (Text(String(repeating: "★", count: filled)).foregroundColor(Theme.desk.star.color)
         + Text(String(repeating: "★", count: 5 - filled)).foregroundColor(Color(nsColor: .quaternaryLabelColor)))
            .font(.system(size: 12))
            .tracking(1)
    }
}

/// Below the library: how many recordings, how many open, how much was practiced, and where the shortcuts are.
private struct LibraryStatusLine: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let count = model.recordings.count
        let open = model.recordings.filter { $0.status == .open }.count
        let since = PracticeStats.minutesPerDay(model.practiceLog, days: 30).first?.date
        let minutes = PracticeStats.totalMinutes(model.practiceLog, since: since)
        HStack {
            Text(count == 1 ? tr("1 take · %d open · %@ in 30 days", open, minutesText(minutes))
                 : tr("%d takes · %d open · %@ in 30 days", count, open, minutesText(minutes)))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(tr("⌘/ Keyboard shortcuts")) { model.showShortcuts?() }
                .buttonStyle(.plain)
                .font(Theme.Fonts.mono(11))
                .help(tr("Shows all keyboard shortcuts (⌘/)"))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Pieces

private struct PiecesPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField(tr("Title of a new piece or exercise"), text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button(tr("Create"), action: add)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
                Text(tr("A piece collects your takes. The dot on the left chooses the piece for new takes; a click on the title changes it. You assign finished takes in the list's right-click menu or on the right under Details."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            Divider()
            if model.pieces.isEmpty {
                ContentUnavailableView(tr("No pieces yet"), systemImage: "music.note.list",
                                       description: Text(tr("Enter a title above and press Return. New takes then go into this piece.")))
            } else {
                List {
                    ForEach(model.pieces.sorted { $0.createdAt > $1.createdAt }) { piece in
                        PieceRow(piece: piece)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func add() {
        model.addPiece(named: newName)
        newName = ""
    }
}

private struct PieceRow: View {
    @EnvironmentObject private var model: AppModel
    let piece: Piece
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    private var isCurrent: Bool { model.currentPieceID == piece.id }

    private var takes: [Recording] { model.takes(of: piece.id) }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { model.expandedPieces.contains(piece.id) },
            set: { open in if open { model.expandedPieces.insert(piece.id) } else { model.expandedPieces.remove(piece.id) } }
        )) {
            SongDetails(piece: piece)
                .padding(.vertical, 6)
            DeskCaption(tr("Takes in this piece"))
            if takes.isEmpty {
                Text(tr("No takes in this piece yet")).foregroundStyle(.secondary)
            }
            ForEach(Array(takes.enumerated()), id: \.element.id) { index, take in
                HStack {
                    Text(tr("Take %d", index + 1)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(take.name).lineLimit(1).truncationMode(.middle)
                    Text(TimeText.clock(take.duration)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.toggleBestTake(take.id)
                    } label: {
                        Image(systemName: model.isBestTake(take) ? "crown.fill" : "crown")
                            .foregroundStyle(model.isBestTake(take) ? Theme.desk.amber.color : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Mark as best take"))
                    .accessibilityLabel(model.isBestTake(take) ? tr("Best take, remove mark") : tr("Mark as best take"))
                    Button(tr("Listen")) {
                        model.select(take.id)
                        model.togglePlay()
                    }
                    .controlSize(.small)
                }
            }
        } label: {
            HStack {
                Button {
                    model.setCurrentPiece(isCurrent ? nil : piece.id)
                } label: {
                    Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isCurrent ? Theme.desk.amber.color : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isCurrent ? tr("New takes go into this piece. A click undoes that.") : tr("Put new takes into this piece"))
                .accessibilityLabel(isCurrent ? tr("Piece for new takes, undo") : tr("Put new takes into %@", piece.name))

                TextField(tr("Title"), text: $title)
                    .textFieldStyle(.plain)
                    .fontWeight(.medium)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
                    .help(tr("Click and type to change the title"))
                    .accessibilityLabel(tr("Title of the piece"))
                if !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(takes.count == 1 ? tr("1 take · practiced %@", TimeText.clock(model.practiceSeconds(of: piece.id)))
                     : tr("%d takes · practiced %@", takes.count, TimeText.clock(model.practiceSeconds(of: piece.id))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(tr("Practice time from all takes of this piece, including discarded ones"))
                Button(tr("Show takes")) {
                    model.query = LibraryQuery()
                    model.query.piece = .piece(piece.id)
                    model.tab = .recordings
                }
                .controlSize(.small)
                Button {
                    model.removePiece(piece.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help(tr("Remove piece. The takes stay in the list, and it can be undone."))
                .accessibilityLabel(tr("Remove %@, the takes stay", piece.name))
            }
        }
        .onAppear { title = piece.name }
        .onChange(of: piece.name) { if !titleFocused { title = piece.name } }
    }

    /// Artist, key and tempo, as far as they are known.
    private var summary: String {
        [piece.artist, piece.key ?? "", piece.bpm.map { "\(Int($0)) BPM" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func commitTitle() {
        if !model.renamePiece(piece.id, to: title) { title = piece.name }
    }
}

/// What it takes to play a piece: artist, tempo, key, notes, its sound and the sounds of its parts. The sounds come
/// from AmpBench's presets and play on the amp's temporary place.
private struct SongDetails: View {
    @EnvironmentObject private var model: AppModel
    let piece: Piece

    private var choices: [PresetLink] { model.presetChoices?() ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    DeskCaption(tr("Artist"))
                    TextField(tr("Artist"), text: binding(\.artist))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(tr("Artist"))
                }
                GridRow {
                    DeskCaption(tr("Tempo"))
                    HStack(spacing: 6) {
                        TextField("BPM", value: binding(\.bpm), format: .number.precision(.fractionLength(0)).locale(Texts.locale))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .accessibilityLabel(tr("Tempo in BPM"))
                        Text("BPM").foregroundStyle(.secondary)
                        Button(tr("To metronome")) { model.useTempo(of: piece) }
                            .controlSize(.small)
                            .disabled(piece.bpm == nil || model.phase != .idle)
                            .help(tr("Sets the click to this piece's tempo"))
                        DeskCaption(tr("Key")).padding(.leading, 8)
                        TextField(tr("Key"), text: Binding(get: { piece.key ?? "" },
                                                          set: { value in model.updatePiece(piece.id) { $0.key = value.isEmpty ? nil : value } }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .accessibilityLabel(tr("Key"))
                    }
                }
                if model.presetChoices != nil {
                    GridRow {
                        DeskCaption(tr("Sound"))
                        soundRow(selection: binding(\.preset), label: tr("Sound of the piece"))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                DeskCaption(tr("Notes"))
                TextEditor(text: binding(\.notes))
                    .font(.body)
                    .frame(minHeight: 44, maxHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                    .accessibilityLabel(tr("Notes on the piece"))
            }
            parts
        }
    }

    @ViewBuilder
    private var parts: some View {
        VStack(alignment: .leading, spacing: 4) {
            DeskCaption(tr("Parts"))
            ForEach(piece.parts) { part in
                HStack(spacing: 6) {
                    TextField(tr("Part"), text: Binding(get: { part.name }, set: { value in update(part.id) { $0.name = value } }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .accessibilityLabel(tr("Name of the part"))
                    if model.presetChoices != nil {
                        soundRow(selection: Binding(get: { part.preset }, set: { value in update(part.id) { $0.preset = value } }),
                                 label: tr("Sound for %@", part.name))
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.updatePiece(piece.id) { $0.parts.removeAll { $0.id == part.id } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help(tr("Remove part"))
                    .accessibilityLabel(tr("Remove %@", part.name))
                }
            }
            Button(tr("Add part")) {
                let name = [tr("Intro"), tr("Verse"), tr("Chorus"), tr("Solo"), tr("Outro")].first { name in
                    !piece.parts.contains { $0.name == name }
                } ?? tr("Part %d", piece.parts.count + 1)
                model.updatePiece(piece.id) { $0.parts.append(PiecePart(name: name)) }
            }
            .controlSize(.small)
        }
    }

    /// A sound: the saved presets to choose from, and a key that plays the chosen one on the amp.
    private func soundRow(selection: Binding<PresetLink?>, label: String) -> some View {
        let current = selection.wrappedValue.map(resolve)
        return HStack(spacing: 6) {
            Picker(label, selection: Binding(get: { current }, set: { selection.wrappedValue = $0 })) {
                Text(tr("No sound")).tag(PresetLink?.none)
                ForEach(choices, id: \.self) { Text($0.name).tag(PresetLink?.some($0)) }
                if let current, !choices.contains(current) {
                    Text(tr("%@ (missing)", current.name)).tag(PresetLink?.some(current))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel(label)
            Button(tr("Play on amp")) { current.map { model.playPreset?($0) } }
                .controlSize(.small)
                .disabled(current == nil || model.playPreset == nil)
                .help(tr("Plays the sound on the amp, in the temporary slot. No slot is overwritten."))
        }
    }

    /// The same preset after a rename: found again by its id, then by its file.
    private func resolve(_ link: PresetLink) -> PresetLink {
        choices.first { $0.presetID != nil && $0.presetID == link.presetID }
            ?? choices.first { $0.fileName != nil && $0.fileName == link.fileName }
            ?? link
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Piece, Value>) -> Binding<Value> {
        Binding(get: { piece[keyPath: keyPath] }, set: { value in model.updatePiece(piece.id) { $0[keyPath: keyPath] = value } })
    }

    private func update(_ partID: UUID, _ change: (inout PiecePart) -> Void) {
        model.updatePiece(piece.id) { piece in
            if let index = piece.parts.firstIndex(where: { $0.id == partID }) { change(&piece.parts[index]) }
        }
    }
}

// MARK: - Statistics

/// Plain totals of recorded time. No goals, streaks or comparisons.
private struct StatsPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var days = 30
    @State private var hoveredDay: Date?

    private var range: [PracticeStats.Day] { PracticeStats.minutesPerDay(model.practiceLog, days: days) }
    private var startDate: Date? { range.first?.date }
    private var total: Double { PracticeStats.totalMinutes(model.practiceLog, since: startDate) }
    private var perPiece: [PracticeStats.PieceTotal] {
        PracticeStats.minutesPerPiece(model.practiceLog, pieces: model.pieces, since: startDate)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(minutesText(total)).font(Theme.Fonts.title(28).monospacedDigit())
                        Text(tr("recorded in the last %d days", days)).font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    SegmentTabs(tr("Period"), selection: $days, options: [(7, tr("7 days")), (30, tr("30 days")), (90, tr("90 days"))])
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Minutes per day")).font(.headline)
                    dayChart
                        .frame(height: 140)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Minutes per piece")).font(.headline)
                    if perPiece.isEmpty {
                        Text(tr("Nothing was recorded in this period.")).foregroundStyle(.secondary)
                    }
                    pieceBars
                }

                Text(tr("Only time that was recorded counts. Discarded takes count too, because you practiced anyway."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    private var dayChart: some View {
        Chart(range) { day in
            BarMark(
                x: .value(tr("Day"), day.date, unit: .day),
                y: .value(tr("Minutes"), day.minutes),
                width: .ratio(0.7)
            )
            .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Theme.desk.chartToday.color : Theme.desk.chartBar.color)
            .cornerRadius(3)
            .accessibilityLabel(day.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Texts.locale)))
            .accessibilityValue(tr("%d minutes", Int(day.minutes.rounded())))

            if let hoveredDay, Calendar.current.isDate(hoveredDay, inSameDayAs: day.date) {
                RuleMark(x: .value(tr("Day"), day.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 0) {
                            Text(day.date, format: .dateTime.day().month().locale(Texts.locale))
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("\(minutesText(day.minutes))").font(.caption.monospacedDigit().weight(.semibold))
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.background).shadow(radius: 1))
                    }
            }
        }
        .chartXSelection(value: $hoveredDay)
        .chartYAxisLabel(tr("min"))
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
    }

    private var pieceBars: some View {
        let maximum = max(perPiece.map(\.minutes).max() ?? 1, 0.001)
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(perPiece) { item in
                HStack(spacing: 8) {
                    Text(item.name).lineLimit(1).truncationMode(.middle).frame(width: 130, alignment: .leading)
                    GeometryReader { geometry in
                        UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                            .fill(Theme.desk.chartBar.color)
                            .frame(width: max(geometry.size.width * CGFloat(item.minutes / maximum), 1), height: 12)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 16)
                    Text(minutesText(item.minutes)).font(.callout.monospacedDigit()).lineLimit(1).fixedSize().frame(minWidth: 74, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityValue(minutesText(item.minutes))
            }
        }
    }
}

// MARK: - Inspector

struct InspectorPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var section = 0

    var body: some View {
        Group {
            if model.selection.count > 1 {
                ContentUnavailableView(tr("%d takes selected", model.selection.count), systemImage: "square.stack",
                                       description: Text(model.selection.count == 2 ? tr("With “Compare” you hear them one right after the other.") : tr("The context menu applies to all selected takes.")))
            } else if let recording = model.current {
                VStack(spacing: 0) {
                    HStack {
                        SegmentTabs(tr("Inspector section"), selection: $section,
                                    options: [(0, tr("Details")), (1, tr("Edit")), (2, tr("Markers"))])
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    Divider()
                    ScrollView {
                        Group {
                            switch section {
                            case 0: DetailsSection(recording: recording)
                            case 1: EditSection(recording: recording)
                            default: MarkerSection(recording: recording)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .id(recording.id)
            } else {
                ContentUnavailableView(tr("No take selected"), systemImage: "waveform")
            }
        }
    }
}

private struct DetailsSection: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording
    @State private var name = ""
    @State private var tags = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var tagsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                DeskCaption(tr("Title, also the file name"))
                TextField(tr("Title"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { if !nameFocused { commitName() } }
                    .accessibilityLabel(tr("Title of the take"))
            }

            HStack {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        model.setRating(star, for: recording.id)
                    } label: {
                        Image(systemName: "star.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(star <= recording.rating ? Theme.desk.star.color : Color(nsColor: .quaternaryLabelColor))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("%d stars", star))
                    .accessibilityAddTraits(star == recording.rating ? .isSelected : [])
                }
                Spacer()
                Button {
                    model.toggleFavorite(recording.id)
                } label: {
                    Image(systemName: recording.favorite ? "heart.fill" : "heart")
                        .foregroundStyle(recording.favorite ? Color.pink : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(tr("Favorite (F)"))
                .accessibilityLabel(recording.favorite ? tr("Remove favorite") : tr("Mark as favorite"))
            }

            VStack(alignment: .leading, spacing: 3) {
                DeskCaption(tr("Piece"))
                HStack(spacing: 6) {
                    Picker(tr("Piece"), selection: Binding(get: { recording.pieceID }, set: { model.assign([recording.id], toPiece: $0) })) {
                        Text(tr("None")).tag(UUID?.none)
                        ForEach(model.pieces) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(tr("Piece"))
                    Button {
                        model.beginNewPiece(assigning: [recording.id])
                    } label: {
                        Image(systemName: "plus")
                    }
                    .controlSize(.small)
                    .help(tr("Create a new piece and assign this take"))
                    .accessibilityLabel(tr("Create a new piece for this take"))
                }
                if recording.pieceID != nil {
                    Button {
                        model.toggleBestTake(recording.id)
                    } label: {
                        Label(model.isBestTake(recording) ? tr("Best take") : tr("Mark as best take"),
                              systemImage: model.isBestTake(recording) ? "crown.fill" : "crown")
                    }
                    .controlSize(.small)
                }
            }

            if let sound = recording.preset {
                SoundBlock(recording: recording, sound: sound)
            }

            VStack(alignment: .leading, spacing: 3) {
                DeskCaption(tr("Tags, separated by commas"))
                TextField(tr("Tags"), text: $tags)
                    .textFieldStyle(.roundedBorder)
                    .focused($tagsFocused)
                    .onSubmit { model.setTags(tags, for: recording.id) }
                    .onChange(of: tagsFocused) { if !tagsFocused { model.setTags(tags, for: recording.id) } }
                    .accessibilityLabel(tr("Tags"))
            }

            VStack(alignment: .leading, spacing: 3) {
                DeskCaption(tr("Note"))
                TextEditor(text: model.binding(recording.id, \.note, default: ""))
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                    .accessibilityLabel(tr("Note"))
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                if let punch = recording.punch {
                    row(tr("New"), AppModel.barsText(punch.bars))
                }
                if let grid = recording.grid {
                    row(tr("Grid"), "\(Int(grid.bpm)) BPM, \(grid.beatsPerBar)/4")
                }
                row(tr("Date"), recording.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(Texts.locale)))
                row(tr("Length"), TimeText.clock(recording.duration, tenths: true), mono: true)
                row(tr("Source"), QualityText.source(recording.source))
                if let device = recording.source?.deviceName { row(tr("Device"), device) }
                row(tr("File"), fileText)
                if let peak = recording.peakDB {
                    row(tr("Peak"), tr("%.1f dBFS", peak), mono: true)
                }
            }
            .font(.system(size: 12))

            HStack(spacing: 8) {
                Button(tr("Show in Finder")) { model.reveal(recording.id) }
                    .buttonStyle(.hardwareKey(keycap: "⇧⌘R", size: .small))
                    .fixedSize()
                Button(tr("Rename …")) { model.beginRename(recording.id) }
                    .buttonStyle(.hardwareKey(keycap: "⌘E", size: .small))
                    .fixedSize()
                if let source = recording.punch?.sourceID, model.recordings.contains(where: { $0.id == source }) {
                    Button(tr("To the original")) { model.select(source) }
                        .buttonStyle(.hardwareKey(size: .small))
                        .fixedSize()
                }
            }
            .padding(.top, 2)
        }
        .onAppear {
            name = recording.name
            tags = recording.tags.joined(separator: ", ")
        }
        .onChange(of: recording.fileName) { name = recording.name }
        .onChange(of: recording.tags) {
            if !tagsFocused { tags = recording.tags.joined(separator: ", ") }
        }
    }

    private var fileText: String {
        let container = (recording.fileName as NSString).pathExtension.uppercased()
        return QualityText.file(container: container.isEmpty ? "Audio" : container, bits: recording.fileBits,
                                sampleRate: recording.sampleRate, channels: recording.channels)
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).fontWeight(.semibold).foregroundStyle(.secondary)
            Text(value).font(mono ? Theme.Fonts.mono(12) : nil).textSelection(.enabled).lineLimit(2)
        }
    }

    private func commitName() {
        guard name != recording.name, !name.isEmpty else { return }
        model.rename(recording.id, to: name)
        name = model.recordings.first { $0.id == recording.id }?.name ?? name
    }
}

/// The sound a take was recorded with, from AmpBench: name and place, and in Studio two keys to hear it again
/// on the amp or to open it in the editor.
private struct SoundBlock: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording
    let sound: PresetStamp

    private var place: String {
        sound.slot.map { tr("Slot %d", $0) } ?? tr("played temporarily")
    }

    private var origin: String {
        [place, sound.device].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DeskCaption(tr("Sound"))
            if let listened = sound.listened {
                ListenedSound(name: sound.name, device: sound.device, values: listened)
            } else {
                Text("\(sound.name.isEmpty ? tr("Unnamed") : sound.name), \(origin)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityLabel(tr("Sound: %@, %@", sound.name, origin))
            }
            if let actions = model.soundActions, !sound.isListened {
                let snapshot = model.presetSnapshot(of: recording)
                HStack(spacing: 8) {
                    Button(tr("To the amp")) { snapshot.map(actions.sendToAmp) }
                        .buttonStyle(.hardwareKey(size: .small))
                        .fixedSize()
                        .help(tr("Plays this sound on the amp, in the temporary slot. No slot is overwritten."))
                    Button(tr("Open in editor")) { snapshot.map(actions.openInEditor) }
                        .buttonStyle(.hardwareKey(size: .small))
                        .fixedSize()
                        .help(tr("Opens the sound in the Presets area as a new preset that you can save."))
                }
                .disabled(snapshot == nil)
                if snapshot == nil {
                    Text(tr("The settings of this sound are missing from the folder .presets."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A sound read from what a device reported (the REACTOR), not a preset: it cannot go back to the device or into the
/// editor, so it shows only what was read, marked "Read from device".
private struct ListenedSound: View {
    let name: String
    let device: String?
    let values: [ListenedValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(name.isEmpty ? (device ?? tr("Device")) : name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Pill(tr("Read from device"))
            }
            if values.isEmpty {
                Text(tr("Since the last slot change nothing was turned on the device; the preset's content is unknown."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    ForEach(values.indices, id: \.self) { index in
                        GridRow {
                            Text(values[index].label).foregroundStyle(.secondary)
                            Text(values[index].value).monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 12))
                .textSelection(.enabled)
                Text(tr("Not a preset: the device does not send its content. Shown is what it had reported when the take started."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("Sound read from device: %@, %@", name, values.map { "\($0.label) \($0.value)" }.joined(separator: ", ")))
    }
}

private struct EditSection: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording

    private var edit: EditList { recording.edit }

    private func set<Value>(_ keyPath: WritableKeyPath<EditList, Value>) -> (Value) -> Void {
        { value in model.updateEdit(recording.id) { $0[keyPath: keyPath] = value } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("The original always stays unchanged. Edits take effect when listening, and only the export writes a new file."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                DeskCaption(tr("Trim"))
                HStack {
                    Button(tr("Start = playback position"), action: model.setTrimStartToPlayhead).controlSize(.small)
                    Text(TimeText.clock(edit.trimStart, tenths: true)).monospacedDigit().font(.callout)
                }
                HStack {
                    Button(tr("End = playback position"), action: model.setTrimEndToPlayhead).controlSize(.small)
                    Text(TimeText.clock(edit.trimEnd ?? recording.duration, tenths: true)).monospacedDigit().font(.callout)
                }
            }

            seconds(tr("Fade in"), value: edit.fadeIn, set: set(\.fadeIn))
            seconds(tr("Fade out"), value: edit.fadeOut, set: set(\.fadeOut))

            VStack(alignment: .leading, spacing: 4) {
                DeskCaption(tr("Level"))
                HStack {
                    Slider(value: Binding(get: { edit.gainDB }, set: { value in set(\.gainDB)((value * 2).rounded() / 2) }), in: -24...24)
                        .controlSize(.small)
                        .accessibilityLabel(tr("Level"))
                        .accessibilityValue(dbText(edit.gainDB))
                    Text(dbText(edit.gainDB)).font(.callout.monospacedDigit()).frame(width: 58, alignment: .trailing)
                }
                Toggle(isOn: Binding(get: { edit.autoLevelEnabled }, set: set(\.autoLevelEnabled))) {
                    Text(tr("Raise automatically: %@", dbText(edit.autoLevelDB)))
                }
                .toggleStyle(.checkbox)
                .disabled(recording.peakDB == nil)
                .help(tr("Raises the peak to %d dBFS, by at most %d dB. The dynamics stay the same; the noise floor rises with it.", Int(AutoLevel.targetPeakDB), Int(AutoLevel.maxGainDB)))
                if let after = edit.peakAfterGain(originalPeakDB: recording.peakDB) {
                    Label(tr("Peak after editing: %@", dbText(after)), systemImage: after > 0 ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
                        .font(.callout)
                        .foregroundStyle(after > 0 ? Theme.device.meterRed.color : Color.secondary)
                    if after > 0 {
                        Text(tr("That clips on export. Lower the level."))
                            .font(.callout)
                            .foregroundStyle(Theme.device.meterRed.color)
                    }
                }
            }

            HStack {
                Button(tr("Reset edits")) { model.resetEdits(recording.id) }
                    .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                DeskCaption(tr("Export"))
                HStack {
                    Button(tr("WAV, 24-bit …")) { model.export(.wav24, id: recording.id) }
                    Menu(tr("AAC …")) {
                        Button("128 kbit/s") { model.export(.aac(bitRate: 128_000), id: recording.id) }
                        Button("192 kbit/s") { model.export(.aac(bitRate: 192_000), id: recording.id) }
                        Button("256 kbit/s") { model.export(.aac(bitRate: 256_000), id: recording.id) }
                    }
                    .frame(width: 90)
                }
                .controlSize(.small)
                .disabled(model.isRecording || recording.health != .ok)
            }
        }
    }

    private func seconds(_ label: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            DeskCaption(label)
            HStack {
                Slider(value: Binding(get: { value }, set: { set(($0 * 10).rounded() / 10) }), in: 0...10)
                    .controlSize(.small)
                    .accessibilityLabel(label)
                    .accessibilityValue(tr("%.1f seconds", value))
                Text(tr("%.1f s", value))
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func dbText(_ value: Double) -> String {
        let text = tr("%+.1f dB", value)
        return value == 0 ? "0 dB" : text
    }
}

private struct MarkerSection: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if recording.markers.isEmpty {
                Text(tr("No markers yet. The M key adds one, also while recording."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(recording.markers) { marker in
                MarkerRow(recording: recording, marker: marker)
            }
        }
    }
}

private struct MarkerRow: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording
    let marker: Marker
    @State private var label = ""

    var body: some View {
        HStack(spacing: 6) {
            Button(TimeText.clock(marker.time, tenths: true)) {
                model.seek(to: marker.time)
            }
            .controlSize(.small)
            .monospacedDigit()
            .help(tr("Jump to this marker"))
            .accessibilityLabel(tr("Jump to %@", marker.label))
            TextField(tr("Label"), text: $label)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { model.renameMarker(marker, in: recording.id, to: label) }
                .accessibilityLabel(tr("Label of %@", marker.label))
            Button {
                model.removeMarker(marker, from: recording.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Remove %@", marker.label))
        }
        .onAppear { label = marker.label }
    }
}
