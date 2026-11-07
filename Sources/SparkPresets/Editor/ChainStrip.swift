import SparkControl
import SparkDesign
import SwiftUI

/// The signal chain as a row of pedals with the amp head in the middle. A click on a unit shows its controls
/// below, the footswitch switches it.
struct ChainStrip: View {
    let preset: SparkPreset
    @EnvironmentObject private var editor: EditorModel

    var body: some View {
        GeometryReader { geometry in
            let unit = unitWidth(for: geometry.size.width)
            ZStack {
                Cable().padding(.horizontal, unit / 2)
                HStack(alignment: .center, spacing: Self.spacing) {
                    ForEach(Array(preset.effects.enumerated()), id: \.offset) { index, effect in
                        let place = ChainPlace.of(index: index, count: preset.effects.count) ?? .modulation
                        if place == .amp {
                            AmpUnit(index: index, effect: effect, width: unit * Self.ampFactor)
                        } else {
                            PedalUnit(index: index, place: place, effect: effect, width: unit)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 150)
    }

    static let spacing: CGFloat = 10
    static let ampFactor: CGFloat = 1.8

    private func unitWidth(for width: CGFloat) -> CGFloat {
        let count = CGFloat(max(preset.effects.count - 1, 0)) + Self.ampFactor
        let available = width - Self.spacing * CGFloat(max(preset.effects.count - 1, 0))
        return min(max(available / max(count, 1), 64), 112)
    }
}

/// The patch cable that runs behind the units.
private struct Cable: View {
    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
            .frame(height: 5)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 2)
            .accessibilityHidden(true)
    }
}

private struct PedalUnit: View {
    let index: Int
    let place: ChainPlace
    let effect: SparkPreset.Effect
    let width: CGFloat
    @EnvironmentObject private var editor: EditorModel

    private var info: ModelInfo { ModelCatalog.info(for: effect.name, place: place, parameterCount: effect.parameters.count) }
    private var isSelected: Bool { editor.focus == place }

    var body: some View {
        PedalShell(nameplate: width < 104 ? place.shortTitle : place.title, accent: place.color, isOn: effect.isOn, isSelected: isSelected) {
            VStack(spacing: 6) {
                LampDot(color: place.swatch, isOn: effect.isOn, size: 8)
                    .padding(.top, 10)
                Button {
                    editor.focus = place
                } label: {
                    VStack(spacing: 2) {
                        PanelLabel(width < 104 ? place.shortTitle : place.title, color: place.color.opacity(0.95))
                        Text(info.name)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.device.label.color)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .frame(height: 28)
                        MiniKnobs(effect: effect, info: info, accent: place.color, width: width)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(place.title): \(info.name), \(effect.isOn ? "an" : "aus")")
                .accessibilityHint("Zeigt die Regler")
                Spacer(minLength: 0)
                Footswitch(isOn: effect.isOn, label: "\(place.title) an oder aus", size: min(28, width * 0.34),
                           isEnabled: !editor.isLocked) {
                    editor.setOn(place: index, !effect.isOn)
                }
                .padding(.bottom, 9)
            }
            .frame(width: width, height: 146)
        }
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
                VStack(spacing: 7) {
                    BrassPanel {
                        HStack(spacing: 6) {
                            LampDot(tone: .hot, isOn: effect.isOn, size: 9)
                            Text(info.name)
                                .font(.system(size: 13, weight: .bold, design: .serif))
                                .italic()
                                .foregroundStyle(Theme.device.amber.color)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    MiniKnobs(effect: effect, info: info, accent: ChainPlace.amp.color, width: width)
                    Grille().frame(height: 40)
                    if let group = info.group {
                        PanelLabel(group.rawValue, color: Theme.device.amberDim.color)
                    }
                }
                .padding(9)
                .frame(width: width, height: 146)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Amp: \(info.name)")
            .accessibilityHint("Zeigt die Regler")
        }
    }
}

/// Small knobs on a unit, showing the first visible values. They are for looking, the panel below sets them.
private struct MiniKnobs: View {
    let effect: SparkPreset.Effect
    let info: ModelInfo
    let accent: Color
    let width: CGFloat

    var body: some View {
        let visible = effect.parameters.filter { info.parameter(Int($0.index)).isVisible }
        let room = max(1, Int((width - 8) / 22))
        HStack(spacing: 2) {
            ForEach(visible.prefix(min(room, 5)), id: \.index) { parameter in
                KnobFace(position: Double(parameter.value), accent: accent, ticks: 0, isEnabled: effect.isOn)
                    .frame(width: 20, height: 20)
            }
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }
}
