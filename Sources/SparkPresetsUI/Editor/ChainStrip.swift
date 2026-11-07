import SparkControl
import SparkDesign
import SwiftUI

/// The signal chain as a row of pedals with the amp head in the middle, on a dark cable rail. A click on a unit shows
/// its controls below, the footswitch switches it. Pedals are 104 × 150 pt and the amp 206 pt wide; in a narrow window
/// all of them shrink together.
struct ChainStrip: View {
    let preset: SparkPreset
    @EnvironmentObject private var editor: EditorModel

    static let pedalWidth: CGFloat = 104
    static let ampWidth: CGFloat = 206
    static let spacing: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let scale = scale(for: geometry.size.width)
            ZStack {
                CableRail().padding(.horizontal, 40)
                HStack(alignment: .center, spacing: Self.spacing * scale) {
                    ForEach(Array(preset.effects.enumerated()), id: \.offset) { index, effect in
                        let place = ChainPlace.of(index: index, count: preset.effects.count) ?? .modulation
                        if place == .amp {
                            AmpUnit(index: index, effect: effect, width: Self.ampWidth * scale)
                        } else {
                            PedalUnit(index: index, place: place, count: preset.effects.count, effect: effect,
                                      width: Self.pedalWidth * scale)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 164)
    }

    /// Below 1 when the row is wider than the room, down to two thirds.
    private func scale(for width: CGFloat) -> CGFloat {
        let count = CGFloat(preset.effects.count)
        let hasAmp = preset.effects.count == ChainPlace.allCases.count
        let natural = (count - (hasAmp ? 1 : 0)) * Self.pedalWidth + (hasAmp ? Self.ampWidth : 0)
            + Self.spacing * max(count - 1, 0) + 8
        return min(max(width / max(natural, 1), 0.62), 1)
    }
}

private struct PedalUnit: View {
    let index: Int
    let place: ChainPlace
    let count: Int
    let effect: SparkPreset.Effect
    let width: CGFloat
    @EnvironmentObject private var editor: EditorModel

    private var info: ModelInfo { ModelCatalog.info(for: effect.name, place: place, parameterCount: effect.parameters.count) }
    private var isSelected: Bool { editor.focus == place }

    var body: some View {
        PedalShell(nameplate: width < 96 ? place.shortTitle : place.title, accent: place.color, isOn: effect.isOn,
                   isSelected: isSelected) {
            VStack(spacing: 0) {
                Button {
                    editor.focus = place
                } label: {
                    VStack(spacing: 6) {
                        Text(info.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.device.label)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .frame(height: 28)
                        MiniKnobs(effect: effect, info: info, width: width, size: 14)
                        LampDot(color: place.swatch, isOn: effect.isOn, size: 8)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(place.title): \(info.name), \(effect.isOn ? "an" : "aus")")
                .accessibilityHint("Zeigt die Regler")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                Spacer(minLength: 0)
                Footswitch(isOn: effect.isOn, label: "\(place.title) an oder aus", size: min(30, width * 0.3),
                           isEnabled: !editor.isLocked) {
                    editor.setOn(place: index, !effect.isOn)
                }
                .padding(.bottom, 9)
            }
        }
        .frame(width: width, height: 150)
    }
}

private struct AmpUnit: View {
    let index: Int
    let effect: SparkPreset.Effect
    let width: CGFloat
    @EnvironmentObject private var editor: EditorModel

    private var info: ModelInfo { ModelCatalog.info(for: effect.name, place: .amp, parameterCount: effect.parameters.count) }

    var body: some View {
        AmpHeadShell(isOn: effect.isOn, isSelected: editor.focus == .amp) {
            Button {
                editor.focus = .amp
            } label: {
                VStack(spacing: 8) {
                    BrassPanel {
                        HStack(spacing: 8) {
                            LampDot(tone: .hot, isOn: effect.isOn, size: 8)
                            Text(info.name)
                                .font(.system(size: 14, weight: .bold, design: .serif))
                                .italic()
                                .foregroundStyle(Theme.device.amber)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                            Text("AMP")
                                .font(Theme.Fonts.lamp())
                                .foregroundStyle(Theme.device.brassText)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                    }
                    MiniKnobs(effect: effect, info: info, width: width, size: 18, limit: 5)
                        .frame(maxWidth: .infinity)
                    Grille()
                        .overlay(alignment: .bottomTrailing) {
                            if let group = info.group {
                                PanelLabel(group.rawValue, color: Theme.device.ampGroup)
                                    .padding(.trailing, 4)
                                    .padding(.bottom, 2)
                            }
                        }
                }
                .padding(9)
                .frame(width: width, height: 160)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Amp: \(info.name), \(effect.isOn ? "an" : "aus")")
            .accessibilityHint("Zeigt die Regler")
            .accessibilityAddTraits(editor.focus == .amp ? [.isSelected] : [])
        }
    }
}

/// Small knobs on a unit with amber pointers, showing the first visible values. They are for looking; the control
/// field below sets them.
private struct MiniKnobs: View {
    let effect: SparkPreset.Effect
    let info: ModelInfo
    let width: CGFloat
    var size: CGFloat = 14
    var limit = 4

    var body: some View {
        let visible = effect.parameters.filter { info.parameter(Int($0.index)).isVisible }
        let room = max(1, Int((width - 12) / (size + 5)))
        HStack(spacing: 5) {
            ForEach(visible.prefix(min(room, limit)), id: \.index) { parameter in
                MiniKnob(position: Double(parameter.value), size: size, isEnabled: effect.isOn)
            }
        }
        .frame(height: size + 4)
        .accessibilityHidden(true)
    }
}
