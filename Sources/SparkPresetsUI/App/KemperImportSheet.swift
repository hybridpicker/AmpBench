import AmpText
import SparkControl
import SparkDesign
import SwiftUI

/// Imports a Kemper Profiler's sounds: choose a backup or rig, decide per performance whether it is a song, a basic
/// setup or lesson material, choose single rigs, then import. Shows for every slot which Spark amp it becomes and
/// which effects the Spark has nothing for.
struct KemperImportSheet: View {
    @EnvironmentObject private var model: PresetsModel
    @State private var showsRigs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("Import from Kemper")).font(.headline)
                Spacer()
                if let name = model.kemperFileName {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Text(tr("Every rig becomes the closest Spark sound: a matching amp, gain and EQ, and the effects the Spark knows. A Kemper profile is a recording of the real amp, so listen to every sound on the amp. Nothing is sent to the Kemper."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            content
                .frame(minHeight: 320, maxHeight: .infinity)

            if let error = model.kemperError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(tr("Other file …")) { model.chooseKemperFile() }
                    .disabled(model.kemperIsBusy)
                Spacer()
                if let summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                Button(tr("Cancel"), role: .cancel) { model.closeKemperImport() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Import")) { model.performKemperImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
    }

    @ViewBuilder private var content: some View {
        if model.kemperIsBusy {
            ProgressView(tr("Reading the Kemper file …")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plan = model.kemperPlan {
            List {
                if !plan.performances.isEmpty {
                    Section(tr("Performances")) {
                        ForEach(plan.performances) { PerformanceRow(performance: $0) }
                    }
                }
                if !plan.rigs.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showsRigs) {
                            ForEach(plan.rigs) { RigRow(rig: $0) }
                        } label: {
                            Text(tr("Single rigs (%d of %d chosen)", plan.rigs.filter(\.isChosen).count, plan.rigs.count))
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text(tr("Choose a Kemper backup (.kpabackup) or a rig (.kipr)."))
                    .foregroundStyle(.secondary)
                Button(tr("Choose file …")) { model.chooseKemperFile() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var canImport: Bool {
        guard let plan = model.kemperPlan, !model.kemperIsBusy else { return false }
        return plan.performances.contains { $0.kind != .skip } || plan.rigs.contains(where: \.isChosen)
    }

    private var summary: String? {
        guard let plan = model.kemperPlan else { return nil }
        let songs = plan.performances.filter { $0.kind == .song }.count
        let others = plan.performances.filter { $0.kind == .basis || $0.kind == .lesson }.count
        let rigs = plan.rigs.filter(\.isChosen).count
        return tr("%d songs, %d setups, %d rigs", songs, others, rigs)
    }
}

private struct PerformanceRow: View {
    let performance: KemperImportPlan.Performance
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(performance.number).").monospacedDigit().foregroundStyle(.secondary)
                Text(performance.name).fontWeight(.semibold)
                Spacer()
                Picker(tr("Kind"), selection: Binding(get: { performance.kind },
                                                 set: { model.setKind($0, ofPerformance: performance.number) })) {
                    ForEach(KemperImportPlan.Kind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                .accessibilityLabel(tr("Kind of “%@”", performance.name))
            }
            ForEach(performance.slots, id: \.number) { slot in
                SlotLine(number: slot.number, name: slot.name, translation: slot.translation)
            }
        }
        .padding(.vertical, 3)
        .opacity(performance.kind == .skip ? 0.5 : 1)
    }
}

private struct RigRow: View {
    let rig: KemperImportPlan.Rig
    @EnvironmentObject private var model: PresetsModel

    var body: some View {
        Toggle(isOn: Binding(get: { rig.isChosen }, set: { model.setChosen($0, rig: rig.id) })) {
            SlotLine(number: nil, name: rig.name, translation: rig.translation)
        }
        .toggleStyle(.checkbox)
    }
}

/// "2 Solo → Plexi Crunch · drive", and the Kemper effects left out.
private struct SlotLine: View {
    let number: Int?
    let name: String
    let translation: KemperTranslation.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if let number { Text("\(number)").monospacedDigit().foregroundStyle(.secondary).frame(width: 14) }
                Text(name).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(ModelCatalog.known(translation.ampModel)?.name ?? translation.ampModel)
                Text("#\(translation.character.rawValue)").font(.caption).foregroundStyle(.secondary)
            }
            if !translation.leftOut.isEmpty {
                Text(tr("Without: %@", translation.leftOut.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, number == nil ? 0 : 20)
                    .lineLimit(2)
            }
        }
        .font(.callout)
        .help(translation.recipe.notes)
        .accessibilityElement(children: .combine)
    }
}
