import SwiftUI
import SparkControl

/// A description in words becomes a few sounds to choose from. Each one plays on the amp first; only the one the
/// player keeps is saved into the library.
struct AISoundSheet: View {
    @EnvironmentObject private var model: PresetsModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftKey = ""
    @State private var showsAdvanced = false

    private let examples = [
        "Blues-Crunch für meine Telecaster",
        "Metallica – Enter Sandman",
        "Cleaner Funk mit Biss",
        "Pink Floyd – Comfortably Numb, Solo",
        "Warmer Jazz-Sound",
    ]

    var body: some View {
        // A real container, not a Group: a Group would hand onDisappear to each page, and going from the description
        // to the results would cancel the request that was just sent.
        VStack(spacing: 0) {
            if !model.aiConnected { connect }
            else if model.aiOffers.isEmpty { form }
            else { results }
        }
        // Closing the window stops what is still on its way; no request runs without the window.
        .onDisappear { model.cancelAI() }
    }

    // MARK: Connect

    /// Shown while Ollama Cloud is not connected: the window where the API key goes in.
    private var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mit Ollama Cloud verbinden").font(.title2.weight(.semibold))
            Text("Für KI-Sound braucht Spark Studio einen Ollama-API-Schlüssel. Du bekommst ihn kostenlos mit einem Ollama-Konto.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Schlüssel auf ollama.com/settings/keys erstellen",
                 destination: URL(string: "https://ollama.com/settings/keys")!)
            SecureField("API-Schlüssel einfügen", text: $draftKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connectKey)
            Text("Der Schlüssel liegt in deinem macOS-Schlüsselbund und wird nur an Ollama (ollama.com) gesendet, wenn du einen Sound erzeugen lässt.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Verbinden", action: connectKey)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func connectKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        model.aiAPIKey = key
        draftKey = ""
    }

    // MARK: Description

    private var canCreate: Bool {
        !model.aiIsBusy && !model.aiRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var requestLength: Int { model.aiRequest.trimmingCharacters(in: .whitespacesAndNewlines).count }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("KI-Sound").font(.title2.weight(.semibold))
            Text("Beschreibe den Sound mit eigenen Worten – ein Song, eine Band, eine Stimmung. Du bekommst drei verschiedene Vorschläge, hörst sie am Verstärker an, besserst nach und behältst nur, was dir gefällt.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("z. B. „U2 – Where the streets have no name“", text: $model.aiRequest, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canCreate { model.generateAISound() } }
            if requestLength > SoundAI.requestLimit - 40 {
                Text("\(requestLength) von \(SoundAI.requestLimit) Zeichen")
                    .font(.caption2)
                    .foregroundStyle(requestLength > SoundAI.requestLimit ? .red : .secondary)
            }

            if !model.aiHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Zuletzt gewünscht").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Verlauf löschen") { model.clearAIHistory() }
                            .buttonStyle(.link).font(.caption)
                    }
                    FlowRow(spacing: 6) {
                        ForEach(model.aiHistory, id: \.self) { wish in
                            Button { model.aiRequest = wish } label: {
                                Label(wish, systemImage: "clock.arrow.circlepath").lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ideen zum Anklicken").font(.caption).foregroundStyle(.secondary)
                FlowRow(spacing: 6) {
                    ForEach(examples, id: \.self) { example in
                        Button(example) { model.aiRequest = example }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            DisclosureGroup("Erweitert", isExpanded: $showsAdvanced) {
                HStack(spacing: 6) {
                    Text("Modell").font(.caption).foregroundStyle(.secondary)
                    TextField("gpt-oss:120b", text: $model.aiModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    if !model.aiModelChoices.isEmpty {
                        Menu {
                            ForEach(model.aiModelChoices, id: \.self) { name in
                                Button(name) { model.aiModel = name }
                            }
                        } label: { Image(systemName: "chevron.up.chevron.down") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                    Spacer()
                    Button("Schlüssel entfernen") { model.aiAPIKey = "" }
                        .buttonStyle(.link).font(.caption)
                }
                .padding(.top, 6)
            }
            .font(.callout)

            if let error = model.aiError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Nur dein Text geht an Ollama (ollama.com) – keine Presets, Namen oder Gerätedaten.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Vorschläge erstellen") { model.generateAISound() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear { model.loadAIModels() }
    }

    // MARK: Results

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hör dir die Vorschläge an").font(.title2.weight(.semibold))
            Text("„\(model.aiAsked)“ – jeder Vorschlag erscheint, sobald er fertig ist. „Anhören“ spielt ihn am Verstärker, gespeichert wird nichts. Die Knöpfe darunter bessern nur diesen Vorschlag nach. Erst „Behalten“ legt ihn in deine Bibliothek.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.aiOffers) { offer in card(offer) }
                }
            }
            .frame(height: 470)

            if let note = model.aiPlayNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.aiError {
                Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Andere Beschreibung") { model.discardAIResults() }
                Button("Neue Vorschläge") { model.generateAISound() }.disabled(model.aiIsBusy)
                if model.aiIsBusy {
                    Button("Anfrage abbrechen", role: .cancel) { model.cancelAI() }
                }
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 660)
    }

    private func title(_ offer: PresetsModel.AIOffer) -> String {
        SoundAI.variantTitles.indices.contains(offer.id) ? SoundAI.variantTitles[offer.id] : "Vorschlag \(offer.id + 1)"
    }

    @ViewBuilder
    private func card(_ offer: PresetsModel.AIOffer) -> some View {
        let playing = model.aiListening == offer.id
        VStack(alignment: .leading, spacing: 6) {
            switch offer.state {
            case .writing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(title(offer)): wird geschrieben …").foregroundStyle(.secondary)
                }
            case .failed(let text):
                HStack(alignment: .firstTextBaseline) {
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Nochmal") { model.retryAIOffer(offer.id) }
                }
            case .ready(let recipe):
                ready(offer, recipe, playing: playing)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(playing ? 0.9 : 0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(playing ? Color.accentColor : .clear, lineWidth: 1.5))
    }

    @ViewBuilder
    private func ready(_ offer: PresetsModel.AIOffer, _ recipe: SoundRecipe, playing: Bool) -> some View {
        let heard = model.aiHeard.contains(offer.id)
        HStack(alignment: .firstTextBaseline) {
            Text(recipe.name).font(.headline)
            Text(title(offer)).font(.caption).foregroundStyle(.secondary)
            if playing {
                Label("spielt", systemImage: "speaker.wave.2.fill")
                    .font(.caption).foregroundStyle(.tint)
            }
            Spacer()
            if heard {
                Button("Anhören") { model.listenAISound(offer.id) }
                Button("Behalten") { model.pickAISound(offer.id) }.buttonStyle(.borderedProminent)
            } else {
                Button("Behalten") { model.pickAISound(offer.id) }
                Button("Anhören") { model.listenAISound(offer.id) }.buttonStyle(.borderedProminent)
            }
        }
        .disabled(offer.refining != nil)
        if !recipe.description.isEmpty {
            Text(recipe.description).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(chainSummary(recipe)).font(.caption).foregroundStyle(.secondary)
        if !recipe.notes.isEmpty {
            Text("Tipp: \(recipe.notes)").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 6) {
            ForEach(SoundAI.Adjustment.allCases) { adjustment in
                let reason = adjustment.impossibility(for: recipe)
                Button {
                    model.refineAIOffer(offer.id, adjustment)
                } label: {
                    if offer.refining == adjustment {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(adjustment.label) }
                    } else {
                        Text(adjustment.label)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(offer.refining != nil || reason != nil)
                .help(reason ?? "Diesen Vorschlag \(adjustment.label) machen, der Rest bleibt")
            }
            if !offer.adjustments.isEmpty {
                Text("angepasst: " + offer.adjustments.map(\.label).joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
        if let note = offer.note {
            Text(note).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chainSummary(_ recipe: SoundRecipe) -> String {
        let order = ["gate", "compressor", "drive", "amp", "modulation", "delay", "reverb"]
        let chain = order.compactMap { key -> String? in
            guard let unit = recipe.chain[key], unit.on else { return nil }
            return ModelCatalog.known(unit.model)?.name ?? unit.model
        }.joined(separator: " → ")
        return "\(chain) · \(Int(recipe.bpm.rounded())) BPM"
    }
}

/// Lays its children out in rows that wrap, for the example chips.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 500, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (subview, point) in zip(subviews, layout.points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + rowHeight))
    }
}
