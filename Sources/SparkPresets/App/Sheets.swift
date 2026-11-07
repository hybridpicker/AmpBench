import SparkControl
import SwiftUI

struct BannerView: View {
    @EnvironmentObject private var model: PresetsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let banner = model.banner {
            HStack(spacing: 10) {
                Image(systemName: icon(banner.kind)).foregroundStyle(color(banner.kind))
                Text(banner.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let undo = banner.undo {
                    Button("Rückgängig") { undo() }
                }
                Button {
                    model.banner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Schließen")
            }
            .padding(12)
            .frame(maxWidth: 640)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .shadow(radius: 8, y: 2)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func icon(_ kind: Banner.Kind) -> String {
        switch kind {
        case .info: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(_ kind: Banner.Kind) -> Color {
        switch kind {
        case .info: Theme.on
        case .warning: Theme.amberHot
        case .error: .red
        }
    }
}

struct RenameSheet: View {
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        NameSheet(title: "Preset umbenennen", action: "Umbenennen", text: $model.renameText,
                  commit: model.commitRename, cancel: { model.renameTarget = nil })
    }
}

struct SaveAsSheet: View {
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        NameSheet(title: "Als neues Preset sichern", action: "Sichern",
                  text: Binding(get: { model.saveAsName ?? "" }, set: { model.saveAsName = $0 }),
                  commit: model.commitSaveAs, cancel: { model.saveAsName = nil })
    }
}

private struct NameSheet: View {
    let title: String
    let action: String
    @Binding var text: String
    let commit: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(commit)
            Text(PresetRules.problem(withName: text) ?? "Höchstens \(PresetRules.nameLimit) Zeichen. Der Name gilt auch auf dem Verstärker, sobald das Preset auf einem Platz liegt.")
                .font(.caption)
                .foregroundStyle(PresetRules.problem(withName: text) == nil ? Color.secondary : Color.red)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Abbrechen", action: cancel).keyboardShortcut(.cancelAction)
                Button(action, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(PresetRules.problem(withName: text) != nil)
            }
        }
        .padding(20)
    }
}

/// New presets from a template, or empty.
struct TemplateSheet: View {
    @EnvironmentObject private var model: PresetsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Neues Preset").font(.title2.weight(.semibold))
            Text("Eine Vorlage ist nur ein Anfang. Alles lässt sich danach ändern.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                card(name: "Leer", summary: "Clean-Amp, alle Effekte aus", preset: PresetFactory.empty()) {
                    model.newPreset()
                }
                ForEach(PresetFactory.templates) { template in
                    card(name: template.name, summary: template.summary, preset: template.preset) {
                        model.newPreset(from: template)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func card(name: String, summary: String, preset: SparkPreset, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.amber)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Theme.label)
                    .lineLimit(2, reservesSpace: true)
                HStack(spacing: 4) {
                    ForEach(Array(preset.effects.enumerated()), id: \.offset) { index, effect in
                        let place = ChainPlace(rawValue: index) ?? .modulation
                        LED(isOn: effect.isOn, color: Theme.accent(place), size: 7)
                    }
                }
                Text(ChainSummary.text(preset))
                    .font(.caption2)
                    .foregroundStyle(Theme.labelDim)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.faceGradient))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("\(name): \(summary)")
    }
}
