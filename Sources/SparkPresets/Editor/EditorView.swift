import SparkControl
import SparkDesign
import SwiftUI

/// The editor: the preset's name and state on top, the signal chain on a dark board, the unit in focus below it.
struct EditorView: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var editor: EditorModel
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        if let preset = editor.preset {
            VStack(spacing: 0) {
                Faceplate(top: Theme.device.faceTop, bottom: Swatch(hex: 0x1C1C1F)) {
                    EditorHeader(preset: preset)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
                ScrollView {
                    VStack(spacing: 20) {
                        ChainStrip(preset: preset)
                        UnitPanel(preset: preset)
                        if preset.effects.count != ChainPlace.allCases.count {
                            Text("Dieses Preset hat \(preset.effects.count) statt 7 Effekte. Die Plätze sind daher nummeriert.")
                                .font(.caption)
                                .foregroundStyle(Theme.device.labelDim)
                        }
                    }
                    .padding(18)
                }
                .background(board)
            }
        } else {
            placeholder
        }
    }

    /// The dark board the pedals stand on, lit softly from above.
    private var board: some View {
        ZStack {
            Theme.device.board.color
            EllipticalGradient(colors: [.white.opacity(0.05), .clear], center: .top, startRadiusFraction: 0,
                               endRadiusFraction: 0.6)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "dial.medium")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(placeholderText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Neues Preset") { model.newPreset() }
                Button("Aus Vorlage …") { model.showsTemplates = true }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderText: String {
        if case .slot(let slot) = model.selection, link.slots[slot] == nil {
            return link.status == .connected ? "Platz \(slot + 1) wird gelesen …" : "Platz \(slot + 1) ist nicht gelesen."
        }
        return "Wähle links einen Platz am Verstärker oder ein Preset auf dem Mac, oder lege ein neues an."
    }
}
