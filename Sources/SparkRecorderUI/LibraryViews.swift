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
                    SegmentTabs("Ansicht der Bibliothek", selection: $model.tab,
                                options: LibraryTab.allCases.map { ($0, $0.rawValue) })
                    Spacer(minLength: 8)
                    if let progress = model.exportProgress {
                        ProgressView(value: progress) { Text("Export").font(.caption) }
                            .frame(width: 110)
                    }
                    CurrentPiecePicker()
                    TextField("Suchen", text: $model.query.search)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .frame(minWidth: 100, maxWidth: 180)
                        .accessibilityLabel("Aufnahmen suchen")
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
            DeskCaption("Neue Aufnahmen in").fixedSize()
            Picker("Neue Aufnahmen in", selection: Binding(get: { model.currentPieceID }, set: { model.setCurrentPiece($0) })) {
                Text("Kein Stück").tag(UUID?.none)
                ForEach(model.pieces) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(minWidth: 100, maxWidth: 170)
            .accessibilityLabel("Stück für neue Aufnahmen")
            Button {
                model.beginNewPiece()
            } label: {
                Image(systemName: "plus")
            }
            .controlSize(.small)
            .help("Neues Stück anlegen")
            .accessibilityLabel("Neues Stück anlegen")
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
                ContentUnavailableView("Noch keine Aufnahmen", systemImage: "waveform",
                                       description: Text(model.selectedInput == nil
                                                         ? "Schließ den Spark an, dann drück R und spiel los. Dateien im Ordner werden automatisch erkannt."
                                                         : "Drück R und spiel los. Dateien im Ordner werden automatisch erkannt."))
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
            .help("Nur Favoriten")
            .accessibilityLabel("Nur Favoriten")

            Picker("Bewertung", selection: $model.query.minimumRating) {
                Text("Alle Sterne").tag(0)
                ForEach(1...5, id: \.self) { Text("ab \($0) ★").tag($0) }
            }
            .labelsHidden()
            .frame(width: 96)
            .accessibilityLabel("Mindestbewertung")

            Picker("Status", selection: $model.query.status) {
                Text("Alle Takes").tag(LibraryQuery.StatusFilter.all)
                Text("Offen").tag(LibraryQuery.StatusFilter.open)
                Text("Behalten").tag(LibraryQuery.StatusFilter.kept)
            }
            .labelsHidden()
            .frame(width: 96)
            .accessibilityLabel("Status")

            Picker("Stück", selection: $model.query.piece) {
                Text("Alle Stücke").tag(LibraryQuery.PieceFilter?.none)
                Text("Ohne Stück").tag(LibraryQuery.PieceFilter?.some(.none))
                ForEach(model.pieces) { Text($0.name).tag(LibraryQuery.PieceFilter?.some(.piece($0.id))) }
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel("Stück")

            Picker("Tag", selection: $model.query.tag) {
                Text("Alle Tags").tag(String?.none)
                ForEach(tags, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 96)
            .accessibilityLabel("Tag")

            if model.query.isActive {
                Button {
                    model.query = LibraryQuery()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Alle Filter zurücksetzen")
                .accessibilityLabel("Alle Filter zurücksetzen")
            }

            Button {
                model.discard()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.isRecording || model.selection.isEmpty)
            .help("Markierte Aufnahmen in den Papierkorb legen (⌘⌫). Lässt sich mit ⌘Z rückgängig machen.")
            .accessibilityLabel("Markierte Aufnahmen in den Papierkorb legen")
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
            TableColumn("Name", value: \.name) { recording in
                NameCell(recording: recording)
            }
            .width(min: 150, ideal: 240)
            TableColumn("Datum", value: \.createdAt) { recording in
                Text(recording.createdAt, format: .dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits).hour().minute())
                    .font(Theme.Fonts.mono(12))
            }
            .width(min: 100, ideal: 118)
            TableColumn("Dauer", value: \.duration) { recording in
                Text(TimeText.clock(recording.duration)).font(Theme.Fonts.mono(12))
            }
            .width(min: 44, ideal: 52)
            TableColumn("Bewertung", value: \.rating) { recording in
                Stars(rating: recording.rating)
                    .accessibilityLabel("\(recording.rating) von 5 Sternen")
            }
            .width(min: 66, ideal: 72)
            TableColumn("♥", value: \.favoriteRank) { recording in
                Image(systemName: recording.favorite ? "heart.fill" : "heart")
                    .foregroundStyle(recording.favorite ? Color.pink : Color.secondary)
                    .accessibilityLabel(recording.favorite ? "Favorit" : "Kein Favorit")
            }
            .width(22)
            TableColumn("Stück") { recording in
                HStack(spacing: 3) {
                    if model.isBestTake(recording) {
                        Image(systemName: "crown.fill").foregroundStyle(Theme.desk.amber.color).accessibilityLabel("Bester Take")
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
            Button("Umbenennen …") { model.beginRename(id) }
            Button("Im Finder zeigen") { model.reveal(id) }
            Divider()
        } else if ids.count == 2 {
            Button("Vergleichen") {
                model.selection = ids
                model.startCompare()
            }
            Divider()
        }
        Menu("Stück zuordnen") {
            Button("Kein Stück") { model.assign(ids, toPiece: nil) }
            ForEach(model.pieces) { piece in
                Button(piece.name) { model.assign(ids, toPiece: piece.id) }
            }
            Divider()
            Button("Neues Stück …") { model.beginNewPiece(assigning: ids) }
        }
        .disabled(ids.isEmpty)
        Divider()
        Button(ids.count > 1 ? "\(ids.count) Aufnahmen in den Papierkorb legen" : "In den Papierkorb legen") { model.discard(ids) }
            .disabled(model.isRecording || ids.isEmpty)
    }
}

private struct NameCell: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 5) {
            switch recording.health {
            case .missing:
                Image(systemName: "questionmark.folder").foregroundStyle(.secondary).accessibilityLabel("Datei fehlt")
            case .damaged:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.desk.amber).accessibilityLabel("Datei beschädigt")
            case .ok:
                EmptyView()
            }
            Text(recording.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(recording.health == .ok ? Color.primary : Color.secondary)
            if recording.status == .open {
                Pill("Offen")
            }
            if recording.recoveredAfterInterruption {
                Image(systemName: "bandage").foregroundStyle(.secondary)
                    .help("Nach einer Unterbrechung repariert")
                    .accessibilityLabel("Nach einer Unterbrechung repariert")
            }
        }
    }
}

/// A practice time, such as "1 Std. 56 Min." or "4,5 Min.".
func minutesText(_ minutes: Double) -> String {
    if minutes >= 60 {
        return "\(Int(minutes / 60)) Std. \(Int(minutes) % 60) Min."
}
    return minutes < 10 && minutes > 0 ? String(format: "%.1f Min.", minutes).replacingOccurrences(of: ".", with: ",", range: nil).replacingOccurrences(of: ",0 ", with: " ").replacingOccurrences(of: "Min,", with: "Min.") : "\(Int(minutes)) Min."
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
            Text("\(count) \(count == 1 ? "Aufnahme" : "Aufnahmen") · \(open) offen · \(minutesText(minutes)) in 30 Tagen")
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("⌘/ Tastenkürzel") { model.showShortcuts?() }
                .buttonStyle(.plain)
                .font(Theme.Fonts.mono(11))
                .help("Zeigt alle Tastenkürzel (⌘/)")
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
                    TextField("Titel eines neuen Stücks oder einer Übung", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Anlegen", action: add)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
                Text("Ein Stück sammelt deine Takes. Der Punkt links wählt das Stück für neue Aufnahmen, ein Klick auf den Titel ändert ihn. Fertige Aufnahmen ordnest du im Rechtsklick-Menü der Liste oder rechts unter Details zu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            Divider()
            if model.pieces.isEmpty {
                ContentUnavailableView("Noch keine Stücke", systemImage: "music.note.list",
                                       description: Text("Gib oben einen Titel ein und drück den Zeilenschalter. Neue Aufnahmen landen dann in diesem Stück."))
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
            DeskCaption("Takes")
            if takes.isEmpty {
                Text("Noch keine Takes").foregroundStyle(.secondary)
            }
            ForEach(Array(takes.enumerated()), id: \.element.id) { index, take in
                HStack {
                    Text("Take \(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
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
                    .help("Als besten Take markieren")
                    .accessibilityLabel(model.isBestTake(take) ? "Bester Take, Markierung entfernen" : "Als besten Take markieren")
                    Button("Anhören") {
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
                .help(isCurrent ? "Neue Aufnahmen landen in diesem Stück. Klick hebt das auf." : "Neue Aufnahmen in dieses Stück legen")
                .accessibilityLabel(isCurrent ? "Stück für neue Aufnahmen, aufheben" : "Neue Aufnahmen in \(piece.name) legen")

                TextField("Titel", text: $title)
                    .textFieldStyle(.plain)
                    .fontWeight(.medium)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
                    .help("Klicken und tippen ändert den Titel")
                    .accessibilityLabel("Titel des Stücks")
                if !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(takes.count) \(takes.count == 1 ? "Take" : "Takes") · geübt \(TimeText.clock(model.practiceSeconds(of: piece.id)))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help("Übungszeit aus allen Aufnahmen dieses Stücks, auch verworfenen")
                Button("Takes zeigen") {
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
                .help("Stück entfernen. Die Takes bleiben in der Liste, und es lässt sich rückgängig machen.")
                .accessibilityLabel("\(piece.name) entfernen, die Takes bleiben")
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
/// from Spark Studio's presets and play on the amp's temporary place.
private struct SongDetails: View {
    @EnvironmentObject private var model: AppModel
    let piece: Piece

    private var choices: [PresetLink] { model.presetChoices?() ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    DeskCaption("Interpret")
                    TextField("Interpret", text: binding(\.artist))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Interpret")
                }
                GridRow {
                    DeskCaption("Tempo")
                    HStack(spacing: 6) {
                        TextField("BPM", value: binding(\.bpm), format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .accessibilityLabel("Tempo in BPM")
                        Text("BPM").foregroundStyle(.secondary)
                        Button("Ins Metronom") { model.useTempo(of: piece) }
                            .controlSize(.small)
                            .disabled(piece.bpm == nil || model.phase != .idle)
                            .help("Stellt den Klick auf das Tempo dieses Stücks")
                        DeskCaption("Tonart").padding(.leading, 8)
                        TextField("Tonart", text: Binding(get: { piece.key ?? "" },
                                                          set: { value in model.updatePiece(piece.id) { $0.key = value.isEmpty ? nil : value } }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .accessibilityLabel("Tonart")
                    }
                }
                if model.presetChoices != nil {
                    GridRow {
                        DeskCaption("Sound")
                        soundRow(selection: binding(\.preset), label: "Sound des Stücks")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                DeskCaption("Notizen")
                TextEditor(text: binding(\.notes))
                    .font(.body)
                    .frame(minHeight: 44, maxHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                    .accessibilityLabel("Notizen zum Stück")
            }
            parts
        }
    }

    @ViewBuilder
    private var parts: some View {
        VStack(alignment: .leading, spacing: 4) {
            DeskCaption("Teile")
            ForEach(piece.parts) { part in
                HStack(spacing: 6) {
                    TextField("Teil", text: Binding(get: { part.name }, set: { value in update(part.id) { $0.name = value } }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .accessibilityLabel("Name des Teils")
                    if model.presetChoices != nil {
                        soundRow(selection: Binding(get: { part.preset }, set: { value in update(part.id) { $0.preset = value } }),
                                 label: "Sound für \(part.name)")
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.updatePiece(piece.id) { $0.parts.removeAll { $0.id == part.id } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Teil entfernen")
                    .accessibilityLabel("\(part.name) entfernen")
                }
            }
            Button("Teil hinzufügen") {
                let name = ["Intro", "Strophe", "Refrain", "Solo", "Outro"].first { name in
                    !piece.parts.contains { $0.name == name }
                } ?? "Teil \(piece.parts.count + 1)"
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
                Text("Kein Sound").tag(PresetLink?.none)
                ForEach(choices, id: \.self) { Text($0.name).tag(PresetLink?.some($0)) }
                if let current, !choices.contains(current) {
                    Text("\(current.name) (fehlt)").tag(PresetLink?.some(current))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel(label)
            Button("Spielen") { current.map { model.playPreset?($0) } }
                .controlSize(.small)
                .disabled(current == nil || model.playPreset == nil)
                .help("Spielt den Sound am Verstärker, auf dem vorübergehenden Platz. Kein Platz wird überschrieben.")
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
                        Text("aufgenommen in den letzten \(days) Tagen").font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    SegmentTabs("Zeitraum", selection: $days, options: [(7, "7 Tage"), (30, "30 Tage"), (90, "90 Tage")])
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Minuten pro Tag").font(.headline)
                    dayChart
                        .frame(height: 140)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Minuten pro Stück").font(.headline)
                    if perPiece.isEmpty {
                        Text("In diesem Zeitraum wurde nichts aufgenommen.").foregroundStyle(.secondary)
                    }
                    pieceBars
                }

                Text("Gezählt wird nur Zeit, die aufgenommen wurde. Auch verworfene Takes zählen mit, denn geübt hast du trotzdem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    private var dayChart: some View {
        Chart(range) { day in
            BarMark(
                x: .value("Tag", day.date, unit: .day),
                y: .value("Minuten", day.minutes),
                width: .ratio(0.7)
            )
            .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Theme.desk.chartToday.color : Theme.desk.chartBar.color)
            .cornerRadius(3)
            .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
            .accessibilityValue("\(Int(day.minutes.rounded())) Minuten")

            if let hoveredDay, Calendar.current.isDate(hoveredDay, inSameDayAs: day.date) {
                RuleMark(x: .value("Tag", day.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 0) {
                            Text(day.date, format: .dateTime.day().month())
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("\(minutesText(day.minutes))").font(.caption.monospacedDigit().weight(.semibold))
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.background).shadow(radius: 1))
                    }
            }
        }
        .chartXSelection(value: $hoveredDay)
        .chartYAxisLabel("Min.")
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
                ContentUnavailableView("\(model.selection.count) Aufnahmen markiert", systemImage: "square.stack",
                                       description: Text(model.selection.count == 2 ? "Mit „Vergleichen“ hörst du sie direkt nacheinander." : "Das Kontextmenü gilt für alle markierten Aufnahmen."))
            } else if let recording = model.current {
                VStack(spacing: 0) {
                    HStack {
                        SegmentTabs("Bereich des Inspektors", selection: $section,
                                    options: [(0, "Details"), (1, "Bearbeiten"), (2, "Marker")])
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
                ContentUnavailableView("Keine Aufnahme ausgewählt", systemImage: "waveform")
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
                DeskCaption("Titel, auch der Dateiname")
                TextField("Titel", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { if !nameFocused { commitName() } }
                    .accessibilityLabel("Titel der Aufnahme")
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
                    .accessibilityLabel("\(star) Sterne")
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
                .help("Favorit (F)")
                .accessibilityLabel(recording.favorite ? "Favorit entfernen" : "Als Favorit markieren")
            }

            VStack(alignment: .leading, spacing: 3) {
                DeskCaption("Stück")
                HStack(spacing: 6) {
                    Picker("Stück", selection: Binding(get: { recording.pieceID }, set: { model.assign([recording.id], toPiece: $0) })) {
                        Text("Kein Stück").tag(UUID?.none)
                        ForEach(model.pieces) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Stück")
                    Button {
                        model.beginNewPiece(assigning: [recording.id])
                    } label: {
                        Image(systemName: "plus")
                    }
                    .controlSize(.small)
                    .help("Neues Stück anlegen und diese Aufnahme zuordnen")
                    .accessibilityLabel("Neues Stück für diese Aufnahme anlegen")
                }
                if recording.pieceID != nil {
                    Button {
                        model.toggleBestTake(recording.id)
                    } label: {
                        Label(model.isBestTake(recording) ? "Bester Take" : "Als besten Take markieren",
                              systemImage: model.isBestTake(recording) ? "crown.fill" : "crown")
                    }
                    .controlSize(.small)
                }
            }

            if let sound = recording.preset {
                SoundBlock(recording: recording, sound: sound)
            }

            VStack(alignment: .leading, spacing: 3) {
                DeskCaption("Tags, durch Kommas getrennt")
                TextField("Tags", text: $tags)
                    .textFieldStyle(.roundedBorder)
                    .focused($tagsFocused)
                    .onSubmit { model.setTags(tags, for: recording.id) }
                    .onChange(of: tagsFocused) { if !tagsFocused { model.setTags(tags, for: recording.id) } }
                    .accessibilityLabel("Tags")
            }

            VStack(alignment: .leading, spacing: 3) {
                DeskCaption("Notiz")
                TextEditor(text: model.binding(recording.id, \.note, default: ""))
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                    .accessibilityLabel("Notiz")
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                if let punch = recording.punch {
                    row("Neu", AppModel.barsText(punch.bars))
                }
                if let grid = recording.grid {
                    row("Raster", "\(Int(grid.bpm)) BPM, \(grid.beatsPerBar)/4")
                }
                row("Datum", recording.createdAt.formatted(date: .abbreviated, time: .standard))
                row("Dauer", TimeText.clock(recording.duration, tenths: true), mono: true)
                row("Quelle", QualityText.source(recording.source))
                if let device = recording.source?.deviceName { row("Gerät", device) }
                row("Datei", fileText)
                if let peak = recording.peakDB {
                    row("Spitze", String(format: "%.1f dBFS", peak).replacingOccurrences(of: ".", with: ","), mono: true)
                }
            }
            .font(.system(size: 12))

            HStack(spacing: 8) {
                Button("Im Finder zeigen") { model.reveal(recording.id) }
                    .buttonStyle(.hardwareKey(keycap: "⇧⌘R", size: .small))
                    .fixedSize()
                Button("Umbenennen …") { model.beginRename(recording.id) }
                    .buttonStyle(.hardwareKey(keycap: "⌘E", size: .small))
                    .fixedSize()
                if let source = recording.punch?.sourceID, model.recordings.contains(where: { $0.id == source }) {
                    Button("Zum Original") { model.select(source) }
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

/// The sound a take was recorded with, from Spark Studio: name and place, and in Studio two keys to hear it again
/// on the amp or to open it in the editor.
private struct SoundBlock: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording
    let sound: PresetStamp

    private var place: String {
        sound.slot.map { "Platz \($0)" } ?? "vorübergehend gespielt"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DeskCaption("Sound")
            Text("\(sound.name.isEmpty ? "Ohne Namen" : sound.name), \(place)")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityLabel("Sound: \(sound.name), \(place)")
            if let actions = model.soundActions {
                let snapshot = model.presetSnapshot(of: recording)
                HStack(spacing: 8) {
                    Button("Auf den Amp") { snapshot.map(actions.sendToAmp) }
                        .buttonStyle(.hardwareKey(size: .small))
                        .fixedSize()
                        .help("Spielt diesen Sound am Verstärker, auf dem vorübergehenden Platz. Kein Platz wird überschrieben.")
                    Button("Im Editor öffnen") { snapshot.map(actions.openInEditor) }
                        .buttonStyle(.hardwareKey(size: .small))
                        .fixedSize()
                        .help("Öffnet den Sound im Bereich Presets als neues Preset, das du sichern kannst.")
                }
                .disabled(snapshot == nil)
                if snapshot == nil {
                    Text("Die Einstellungen dieses Sounds fehlen im Ordner .presets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
            Text("Das Original bleibt immer unverändert. Bearbeitungen wirken beim Anhören und erst der Export schreibt eine neue Datei.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                DeskCaption("Zuschnitt")
                HStack {
                    Button("Anfang = Abspielposition", action: model.setTrimStartToPlayhead).controlSize(.small)
                    Text(TimeText.clock(edit.trimStart, tenths: true)).monospacedDigit().font(.callout)
                }
                HStack {
                    Button("Ende = Abspielposition", action: model.setTrimEndToPlayhead).controlSize(.small)
                    Text(TimeText.clock(edit.trimEnd ?? recording.duration, tenths: true)).monospacedDigit().font(.callout)
                }
            }

            seconds("Einblenden", value: edit.fadeIn, set: set(\.fadeIn))
            seconds("Ausblenden", value: edit.fadeOut, set: set(\.fadeOut))

            VStack(alignment: .leading, spacing: 4) {
                DeskCaption("Pegel")
                HStack {
                    Slider(value: Binding(get: { edit.gainDB }, set: { value in set(\.gainDB)((value * 2).rounded() / 2) }), in: -24...24)
                        .controlSize(.small)
                        .accessibilityLabel("Pegel")
                        .accessibilityValue(dbText(edit.gainDB))
                    Text(dbText(edit.gainDB)).font(.callout.monospacedDigit()).frame(width: 58, alignment: .trailing)
                }
                Toggle(isOn: Binding(get: { edit.autoLevelEnabled }, set: set(\.autoLevelEnabled))) {
                    Text("Automatisch anheben: \(dbText(edit.autoLevelDB))")
                }
                .toggleStyle(.checkbox)
                .disabled(recording.peakDB == nil)
                .help("Hebt die Spitze auf \(Int(AutoLevel.targetPeakDB)) dBFS an, höchstens um \(Int(AutoLevel.maxGainDB)) dB. Die Dynamik bleibt gleich, das Grundrauschen steigt mit.")
                if let after = edit.peakAfterGain(originalPeakDB: recording.peakDB) {
                    Label("Spitze nach Bearbeitung: \(dbText(after))", systemImage: after > 0 ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
                        .font(.callout)
                        .foregroundStyle(after > 0 ? Theme.device.meterRed.color : Color.secondary)
                    if after > 0 {
                        Text("Das übersteuert beim Export. Senke den Pegel.")
                            .font(.callout)
                            .foregroundStyle(Theme.device.meterRed.color)
                    }
                }
            }

            HStack {
                Button("Bearbeitungen zurücksetzen") { model.resetEdits(recording.id) }
                    .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                DeskCaption("Export")
                HStack {
                    Button("WAV, 24 Bit …") { model.export(.wav24, id: recording.id) }
                    Menu("AAC …") {
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
                    .accessibilityValue(String(format: "%.1f Sekunden", value))
                Text(String(format: "%.1f s", value).replacingOccurrences(of: ".", with: ","))
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func dbText(_ value: Double) -> String {
        let text = String(format: "%+.1f dB", value).replacingOccurrences(of: ".", with: ",")
        return value == 0 ? "0 dB" : text
    }
}

private struct MarkerSection: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if recording.markers.isEmpty {
                Text("Noch keine Marker. Taste M setzt einen, auch während der Aufnahme.")
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
            .help("Zu diesem Marker springen")
            .accessibilityLabel("Zu \(marker.label) springen")
            TextField("Beschriftung", text: $label)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { model.renameMarker(marker, in: recording.id, to: label) }
                .accessibilityLabel("Beschriftung von \(marker.label)")
            Button {
                model.removeMarker(marker, from: recording.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(marker.label) entfernen")
        }
        .onAppear { label = marker.label }
    }
}
