import AmpText
import SparkControl
import SparkDesign
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
                    Button(tr("Undo")) { undo() }
                }
                Button {
                    model.banner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(tr("Close"))
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
        case .info: Theme.device.on.color
        case .warning: Theme.device.amberHot.color
        case .error: .red
        }
    }
}

struct RenameSheet: View {
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        NameSheet(title: tr("Rename preset"), action: tr("Rename"), text: $model.renameText,
                  commit: model.commitRename, cancel: { model.renameTarget = nil })
    }
}

struct SaveAsSheet: View {
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        NameSheet(title: tr("Save as a new preset"), action: tr("Save"),
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
            TextField(tr("Name"), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(commit)
            Text(PresetRules.problem(withName: text) ?? tr("At most %d characters. The name also applies on the amp once the preset is on a slot.", PresetRules.nameLimit))
                .font(.caption)
                .foregroundStyle(PresetRules.problem(withName: text) == nil ? Color.secondary : Color.red)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
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
            Text(tr("New preset")).font(.title2.weight(.semibold))
            Text(tr("A template is only a start. Everything can be changed afterwards."))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                card(name: tr("Empty"), summary: tr("Clean amp, all effects off"), preset: PresetFactory.empty()) {
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
                Button(tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
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
                    .font(Theme.Fonts.title(16))
                    .foregroundStyle(Theme.device.amber)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Theme.device.label.color)
                    .lineLimit(2, reservesSpace: true)
                ChainMiniature(preset: preset)
                Text(ChainSummary.text(preset))
                    .font(.caption2)
                    .foregroundStyle(Theme.device.labelDim.color)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FaceplateSurface(radius: Theme.Radius.display))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("\(name): \(summary)")
    }
}

/// The chain of a preset in miniature: a small dark pedal per effect with its nameplate color, the amp wider, and
/// switched-off effects dimmed.
struct ChainMiniature: View {
    let preset: SparkPreset

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(preset.effects.enumerated()), id: \.offset) { index, effect in
                let place = ChainPlace.of(index: index, count: preset.effects.count) ?? .modulation
                VStack(spacing: 0) {
                    Rectangle().fill(place.color).frame(height: 4)
                    Rectangle().fill(LinearGradient(colors: [Theme.device.pedalTop.color, Theme.device.pedalBottom.color],
                                                    startPoint: .top, endPoint: .bottom))
                }
                .frame(width: place == .amp ? 26 : 13, height: 17)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.device.faceEdge, lineWidth: 1))
                .opacity(effect.isOn ? 1 : 0.4)
            }
        }
        .accessibilityHidden(true)
    }
}
