import AmpText
import SparkControl
import SparkDesign
import SwiftUI

/// The control field of the unit in focus: a front with a stripe in the place's color, its model, on and off, and
/// every parameter.
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
                HStack(alignment: .center, spacing: 18) {
                    ParameterGrid(index: index, place: place, effect: effect, info: info)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    EngravedDivider().frame(maxHeight: 90)
                    OperatingHint(isLive: editor.isLiveEnabled)
                        .frame(maxWidth: 300, alignment: .leading)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FaceplateSurface(radius: Theme.Radius.panel, top: Theme.device.panelTop,
                                         bottom: Theme.device.panelBottom))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                    .fill(place.color)
                    .frame(height: 3)
                    .shadow(color: place.color.opacity(0.7), radius: 4)
                    .padding(.horizontal, 20)
                    .accessibilityHidden(true)
            }
        }
    }

    private func header(index: Int, place: ChainPlace, effect: SparkPreset.Effect, info: ModelInfo) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                PanelLabel(tr("%1$@ · place %2$d of %3$d", place.title, index + 1, preset.effects.count), color: place.color,
                           isAccessible: true)
                ModelPicker(index: index, place: place, current: info)
                Text(info.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.device.fieldText)
                    .lineLimit(2)
                if let inspiration = info.inspiration {
                    Text(tr("Modeled on: %@", inspiration))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.device.engraving)
                }
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                LampDot(color: place.swatch, isOn: effect.isOn, size: 10)
                Footswitch(isOn: effect.isOn, label: tr("%@ on or off", place.title), size: 38,
                           isEnabled: !editor.isLocked) {
                    editor.setOn(place: index, !effect.isOn)
                }
                PanelLabel(effect.isOn ? tr("On") : tr("Off"), color: effect.isOn ? Theme.device.amber : Theme.device.lampOffText)
            }
        }
    }
}

/// How the knobs are turned, in two sentences.
private struct OperatingHint: View {
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(tr("**Scrolling** turns finely, **dragging** coarsely, a **double-click** sets the default value.")))
            if isLive {
                Text(tr("Every change can be heard on the amp at once, without overwriting a slot."))
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.device.labelDim)
        .fixedSize(horizontal: false, vertical: true)
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
                .font(Theme.Fonts.title(22))
                .foregroundStyle(Theme.device.amber)
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
            HStack(spacing: 8) {
                Text(current.name)
                    .font(Theme.Fonts.title(22))
                    .foregroundStyle(Theme.device.amber)
                Chevron(color: Theme.device.amberDim, size: 9)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(editor.isLocked)
        .accessibilityLabel(tr("Model: %@", current.name))
        .accessibilityHint(tr("Chooses another model for %@", place.title))
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
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 96), spacing: 14)], alignment: .leading,
                      spacing: 14) {
                ForEach(visible, id: \.index) { parameter in
                    control(for: parameter, info: info.parameter(Int(parameter.index)))
                }
            }
            if visible.isEmpty {
                Text(tr("This model has no adjustable controls."))
                    .font(.callout)
                    .foregroundStyle(Theme.device.labelDim)
            }
        }
    }

    @ViewBuilder
    private func control(for parameter: SparkPreset.Parameter, info parameterInfo: ParameterInfo) -> some View {
        let start = info.defaults.indices.contains(Int(parameter.index)) ? info.defaults[Int(parameter.index)] : nil
        switch parameterInfo.kind {
        case .toggle(let off, let on):
            LeverSwitch(name: parameterInfo.name, isOn: parameter.value >= 0.5, off: off, on: on,
                        accent: place.color, isEnabled: !editor.isLocked) {
                editor.setParameter(place: index, index: parameter.index, value: parameter.value >= 0.5 ? 0 : 1)
            }
        case .selector(let options):
            rotary(parameter, parameterInfo, mode: .steps(options.map(\.value)), start: start)
        default:
            rotary(parameter, parameterInfo, mode: .continuous, start: start)
        }
    }

    private func rotary(_ parameter: SparkPreset.Parameter, _ parameterInfo: ParameterInfo, mode: Knob.Mode,
                        start: Float?) -> some View {
        Knob(name: parameterInfo.name, value: parameter.value, mode: mode, accent: place.color,
                      size: 56, startValue: start, isEnabled: !editor.isLocked,
                      display: parameterInfo.display,
                      onBegin: { editor.beginGesture() },
                      onChange: { editor.setParameter(place: index, index: parameter.index, value: $0) },
                      onEnd: { editor.endGesture() })
    }
}
