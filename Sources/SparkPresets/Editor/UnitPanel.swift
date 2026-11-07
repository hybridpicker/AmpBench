import SparkControl
import SwiftUI

/// The controls of the unit in focus: its model, on and off, and every parameter.
struct UnitPanel: View {
    let preset: SparkPreset
    @EnvironmentObject private var editor: EditorModel

    var body: some View {
        let index = editor.focus.rawValue
        if preset.effects.indices.contains(index) {
            let effect = preset.effects[index]
            let place = ChainPlace.of(index: index, count: preset.effects.count) ?? .modulation
            let info = ModelCatalog.info(for: effect.name, place: place, parameterCount: effect.parameters.count)
            VStack(alignment: .leading, spacing: 14) {
                header(index: index, place: place, effect: effect, info: info)
                ParameterGrid(index: index, place: place, effect: effect, info: info)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.faceGradient)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.16), .black.opacity(0.5)], startPoint: .top,
                                       endPoint: .bottom)))
                    .overlay(alignment: .top) {
                        Capsule().fill(Theme.accent(place)).frame(height: 3).padding(.horizontal, 18)
                            .shadow(color: Theme.accent(place).opacity(0.7), radius: 4)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
            )
        }
    }

    private func header(index: Int, place: ChainPlace, effect: SparkPreset.Effect, info: ModelInfo) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                PanelLabel(place.title, color: Theme.accent(place))
                ModelPicker(index: index, place: place, current: info)
                Text(info.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.label)
                    .lineLimit(2)
                if let inspiration = info.inspiration {
                    Text("Vorbild: \(inspiration)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.labelDim)
                }
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                LED(isOn: effect.isOn, color: Theme.accent(place), size: 11)
                Footswitch(isOn: effect.isOn, label: "\(place.title) an oder aus", size: 38,
                           isEnabled: !editor.isLocked) {
                    editor.setOn(place: index, !effect.isOn)
                }
                PanelLabel(effect.isOn ? "An" : "Aus", color: effect.isOn ? Theme.amber : Theme.labelDim)
            }
        }
    }
}

/// Chooses the model of a place from the catalog.
private struct ModelPicker: View {
    let index: Int
    let place: ChainPlace
    let current: ModelInfo
    @EnvironmentObject private var editor: EditorModel

    var body: some View {
        if ModelCatalog.models(for: place).count < 2 {
            Text(current.name)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.amber)
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            let models = ModelCatalog.models(for: place)
            let groups = ModelInfo.Group.allCases.filter { group in models.contains { $0.group == group } }
            if groups.isEmpty {
                ForEach(models) { model in item(model) }
            } else {
                ForEach(groups, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(models.filter { $0.group == group }) { model in item(model) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(current.name)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.amber)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.amberDim)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(editor.isLocked)
        .accessibilityLabel("Modell: \(current.name)")
        .accessibilityHint("Wählt ein anderes Modell für \(place.title)")
    }

    private func item(_ model: ModelInfo) -> some View {
        Button {
            editor.setModel(place: index, to: model.id)
        } label: {
            if model.id == current.id {
                Label("\(model.name) – \(model.summary)", systemImage: "checkmark")
            } else {
                Text("\(model.name) – \(model.summary)")
            }
        }
    }
}

/// Every visible parameter of an effect as a knob, switch or selector.
private struct ParameterGrid: View {
    let index: Int
    let place: ChainPlace
    let effect: SparkPreset.Effect
    let info: ModelInfo
    @EnvironmentObject private var editor: EditorModel

    var body: some View {
        let visible = effect.parameters.filter { info.parameter(Int($0.index)).isVisible }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 82, maximum: 110), spacing: 12)], alignment: .leading,
                  spacing: 14) {
            ForEach(visible, id: \.index) { parameter in
                control(for: parameter, info: info.parameter(Int(parameter.index)))
            }
        }
        if visible.isEmpty {
            Text("Dieses Modell hat keine einstellbaren Regler.")
                .font(.callout)
                .foregroundStyle(Theme.labelDim)
        }
    }

    @ViewBuilder
    private func control(for parameter: SparkPreset.Parameter, info parameterInfo: ParameterInfo) -> some View {
        let start = info.defaults.indices.contains(Int(parameter.index)) ? info.defaults[Int(parameter.index)] : nil
        switch parameterInfo.kind {
        case .toggle(let off, let on):
            LeverSwitch(name: parameterInfo.name, isOn: parameter.value >= 0.5, off: off, on: on,
                        accent: Theme.accent(place), isEnabled: !editor.isLocked) {
                editor.setParameter(place: index, index: parameter.index, value: parameter.value >= 0.5 ? 0 : 1)
            }
        case .selector(let options):
            rotary(parameter, parameterInfo, mode: .steps(options), start: start)
        default:
            rotary(parameter, parameterInfo, mode: .continuous, start: start)
        }
    }

    private func rotary(_ parameter: SparkPreset.Parameter, _ parameterInfo: ParameterInfo, mode: RotaryControl.Mode,
                        start: Float?) -> some View {
        RotaryControl(name: parameterInfo.name, value: parameter.value, mode: mode, accent: Theme.accent(place),
                      size: 58, startValue: start, isEnabled: !editor.isLocked,
                      display: parameterInfo.display,
                      onBegin: { editor.beginGesture() },
                      onChange: { editor.setParameter(place: index, index: parameter.index, value: $0) },
                      onEnd: { editor.endGesture() })
    }
}
