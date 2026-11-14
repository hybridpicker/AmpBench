import AmpText
import SwiftUI
import SparkControl

/// A description in words becomes a few sounds to choose from. Each one plays on the amp first; only the one the
/// player keeps is saved into the library.
struct AISoundSheet: View {
    @EnvironmentObject private var model: PresetsModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftKey = ""
    @State private var showsAdvanced = false

    private var examples: [String] {
        [
            tr("Blues crunch for my Telecaster"),
            "Metallica – Enter Sandman",
            tr("Clean funk with bite"),
            "Pink Floyd – Comfortably Numb, Solo",
            tr("Warm jazz sound"),
        ]
    }

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
            Text(tr("Connect to Ollama Cloud")).font(.title2.weight(.semibold))
            Text(tr("AI Sound needs an Ollama API key. You get one for free with an Ollama account."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(tr("Create a key at ollama.com/settings/keys"),
                 destination: URL(string: "https://ollama.com/settings/keys")!)
            SecureField(tr("Paste the API key"), text: $draftKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connectKey)
            Text(tr("The key is kept in your macOS keychain and is sent only to Ollama (ollama.com) when you have a sound created."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Connect"), action: connectKey)
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
            Text(tr("AI Sound")).font(.title2.weight(.semibold))
            Text(tr("Describe the sound in your own words – a song, a band, a mood. You get three different suggestions, listen to them on the amp, refine them and keep only what you like."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(tr("e.g. “U2 – Where the streets have no name”"), text: $model.aiRequest, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canCreate { model.generateAISound() } }
            if requestLength > SoundAI.requestLimit - 40 {
                Text(tr("%d of %d characters", requestLength, SoundAI.requestLimit))
                    .font(.caption2)
                    .foregroundStyle(requestLength > SoundAI.requestLimit ? .red : .secondary)
            }

            if !model.aiHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(tr("Asked for recently")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(tr("Clear history")) { model.clearAIHistory() }
                            .linkButtonStyle().font(.caption)
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
                Text(tr("Ideas to click")).font(.caption).foregroundStyle(.secondary)
                FlowRow(spacing: 6) {
                    ForEach(examples, id: \.self) { example in
                        Button(example) { model.aiRequest = example }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            DisclosureGroup(tr("Advanced"), isExpanded: $showsAdvanced) {
                HStack(spacing: 6) {
                    Text(tr("Model")).font(.caption).foregroundStyle(.secondary)
                    TextField(String("gpt-oss:120b"), text: $model.aiModel)
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
                    Button(tr("Remove key")) { model.aiAPIKey = "" }
                        .linkButtonStyle().font(.caption)
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
                Text(tr("Only your text goes to Ollama (ollama.com) – no presets, names or device data."))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Create suggestions")) { model.generateAISound() }
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
            Text(tr("Listen to the suggestions")).font(.title2.weight(.semibold))
            Text(tr("“%@” – every suggestion appears as soon as it is ready. “Listen” plays it on the amp, nothing is stored. The buttons below refine only that suggestion. Only “Keep” puts it into your library.", model.aiAsked))
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
                Button(tr("Other description")) { model.discardAIResults() }
                Button(tr("New suggestions")) { model.generateAISound() }.disabled(model.aiIsBusy)
                if model.aiIsBusy {
                    Button(tr("Cancel request"), role: .cancel) { model.cancelAI() }
                }
                Spacer()
                Button(tr("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 660)
    }

    private func title(_ offer: PresetsModel.AIOffer) -> String {
        SoundAI.variantTitles.indices.contains(offer.id) ? SoundAI.variantTitles[offer.id] : tr("Suggestion %d", offer.id + 1)
    }

    @ViewBuilder
    private func card(_ offer: PresetsModel.AIOffer) -> some View {
        let playing = model.aiListening == offer.id
        VStack(alignment: .leading, spacing: 6) {
            switch offer.state {
            case .writing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("%@: being written …", title(offer))).foregroundStyle(.secondary)
                }
            case .failed(let text):
                HStack(alignment: .firstTextBaseline) {
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(tr("Again")) { model.retryAIOffer(offer.id) }
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
                Label(tr("playing"), systemImage: "speaker.wave.2.fill")
                    .font(.caption).foregroundStyle(.tint)
            }
            Spacer()
            if heard {
                Button(tr("Listen")) { model.listenAISound(offer.id) }
                Button(tr("Keep")) { model.pickAISound(offer.id) }.buttonStyle(.borderedProminent)
            } else {
                Button(tr("Keep")) { model.pickAISound(offer.id) }
                Button(tr("Listen")) { model.listenAISound(offer.id) }.buttonStyle(.borderedProminent)
            }
        }
        .disabled(offer.refining != nil)
        if !recipe.description.isEmpty {
            Text(recipe.description).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(chainSummary(recipe)).font(.caption).foregroundStyle(.secondary)
        if !recipe.notes.isEmpty {
            Text(tr("Tip: %@", recipe.notes)).font(.caption).foregroundStyle(.secondary)
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
                .help(reason ?? tr("Make this suggestion %@, the rest stays", adjustment.label))
            }
            if !offer.adjustments.isEmpty {
                Text(tr("adjusted: %@", offer.adjustments.map(\.label).joined(separator: ", ")))
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
