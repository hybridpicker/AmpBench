import AmpText
import SparkControl
import SparkDesign
import SwiftUI

/// The editor: the preset's name and state on top, the signal chain on a dark board, the unit in focus below it.
struct EditorView: View {
    @EnvironmentObject private var model: PresetsModel
    @EnvironmentObject private var editor: EditorModel
    @EnvironmentObject private var link: SparkLink

    var body: some View {
        // A device that is only listened to shows what it reports. A preset from the Mac still opens in the editor,
        // for "Copy text for REACTOR"; nothing of it goes to the device.
        if link.status == .connected, !link.profile.canSend, editor.preset == nil || model.selectedSlot != nil {
            ReactorPanel()
        } else if let preset = editor.preset {
            VStack(spacing: 0) {
                Faceplate(top: Theme.device.faceTop, bottom: Swatch(hex: 0x1C1C1F)) {
                    VStack(alignment: .leading, spacing: 8) {
                        EditorHeader(preset: preset)
                        if let item = model.selectedItem, !item.file.isBackup {
                            PresetDetailsBar(item: item)
                                .environment(\.colorScheme, .dark)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                ScrollView {
                    VStack(spacing: 20) {
                        ChainStrip(preset: preset)
                        UnitPanel(preset: preset)
                        if preset.effects.count != ChainPlace.allCases.count {
                            Text(tr("This preset has %d effects instead of 7. The places are therefore numbered.", preset.effects.count))
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
                Button(tr("New preset")) { model.newPreset() }
                Button(tr("From template …")) { model.showsTemplates = true }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderText: String {
        if case .slot(let slot) = model.selection, (link.slots[safe: slot] ?? nil) == nil {
            let name = link.profile.slotName(slot)
            return link.can(.read) ? tr("%@ is being read …", name) : tr("%@ has not been read.", name)
        }
        return tr("Choose a slot on the amp or a preset on this Mac on the left, or create a new one.")
    }
}
