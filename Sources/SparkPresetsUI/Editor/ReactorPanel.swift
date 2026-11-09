import SparkControl
import SparkDesign
import SwiftUI

/// What is set on a REACTOR, as far as it reported it by itself. Nothing here can be turned: Spark Studio only listens
/// to the REACTOR and sends it nothing. After a slot change the REACTOR does not send the preset, so only what was
/// turned or pressed since then is shown, and the rest says "–".
struct ReactorPanel: View {
    @EnvironmentObject private var link: SparkLink

    private var state: ReactorState { link.reactor }

    var body: some View {
        VStack(spacing: 0) {
            Faceplate(top: Theme.device.faceTop, bottom: Swatch(hex: 0x1C1C1F)) {
                header
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ampModule
                    effectsModule
                    HStack(alignment: .top, spacing: 18) {
                        tempoModule
                        tunerModule
                        Spacer(minLength: 0)
                    }
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(Theme.device.labelDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .background(Theme.device.board.color)
        }
    }

    // MARK: Header

    private var header: some View {
        Display(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(link.shownName)
                        .font(Theme.Fonts.title())
                        .foregroundStyle(Theme.device.amber)
                        .lineLimit(1)
                    HStack(spacing: 12) {
                        Lamp("Verbunden", tone: .on, isOn: link.status == .connected)
                        Lamp("Nur mitlesen", tone: .amber, isOn: true)
                    }
                    Text("Preset-Inhalt unbekannt. Angezeigt wird, was seit dem letzten Platzwechsel am Gerät gedreht oder gedrückt wurde.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.device.amberDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    PanelLabel("Platz")
                    Text(state.slot.map { link.profile.slotName($0) } ?? "–")
                        .font(Theme.Fonts.mono(26, weight: .bold))
                        .foregroundStyle(Theme.device.amber)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Platz \(state.slot.map { link.profile.slotName($0) } ?? "unbekannt")")
            }
        }
    }

    // MARK: Amp

    private var ampModule: some View {
        Panel(title: "Amp") {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    PanelLabel("Amp-Wahl")
                    HStack(spacing: 10) {
                        ForEach(ReactorState.ampNames.indices, id: \.self) { index in
                            Lamp(ReactorState.ampNames[index], isOn: state.amp == index)
                        }
                    }
                    PanelLabel("Push / Smooth")
                    HStack(spacing: 10) {
                        ForEach(ReactorState.voiceNames.indices, id: \.self) { index in
                            Lamp(ReactorState.voiceNames[index], isOn: state.voice == index)
                        }
                    }
                    PanelLabel("Heat")
                    HStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { step in
                            LampDot(isOn: (state.heat ?? -1) >= step)
                        }
                        Text(state.heat.map { "\($0 + 1) von 5" } ?? "–")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.device.amberDim)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Heat \(state.heat.map { "\($0 + 1) von 5" } ?? "unbekannt")")
                }
                HStack(spacing: 14) {
                    ForEach(ReactorState.Knob.allCases, id: \.self) { knob in
                        KnobReadout(name: knob.title, value: state.knobs[knob], accent: ChainPlace.amp.swatch.color)
                    }
                }
            }
        }
    }

    // MARK: Effects

    private var effectsModule: some View {
        Panel(title: "Effekte") {
            HStack(alignment: .top, spacing: 10) {
                ForEach(ReactorState.placeNames.indices, id: \.self) { place in
                    if place != ChainPlace.amp.rawValue { effectCell(place) }
                }
            }
        }
    }

    private func effectCell(_ place: Int) -> some View {
        let effect = state.effects.values.first { $0.place == place }
        let selected = state.selectedPlace == place
        let accent = ChainPlace(rawValue: place)?.swatch ?? Theme.device.amber
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                LampDot(color: accent, isOn: effect?.isOn == true)
                PanelLabel(ReactorState.placeNames[place])
            }
            Text(effect?.model ?? "–")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.device.amber)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(effect?.isOn.map { $0 ? "an" : "aus" } ?? "–")
                .font(Theme.Fonts.mono(10.5))
                .foregroundStyle(Theme.device.amberDim)
            Text(effect?.level.map { "Level \(ReactorState.tenths($0))" } ?? " ")
                .font(Theme.Fonts.mono(10.5))
                .foregroundStyle(Theme.device.amberDim)
        }
        .padding(8)
        .frame(width: 118, alignment: .leading)
        .background(DisplayGlass(radius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.device.amber, lineWidth: selected ? 2 : 0))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(effectLabel(place, effect, selected: selected))
    }

    private func effectLabel(_ place: Int, _ effect: ReactorState.Effect?, selected: Bool) -> String {
        var parts = [ReactorState.placeNames[place]]
        if let effect {
            parts.append(effect.model)
            if let isOn = effect.isOn { parts.append(isOn ? "an" : "aus") }
            if let level = effect.level { parts.append("Level \(ReactorState.tenths(level))") }
        } else {
            parts.append("nicht gemeldet")
        }
        if selected { parts.append("ausgewählt") }
        return parts.joined(separator: ", ")
    }

    // MARK: Tempo and tuner

    private var tempoModule: some View {
        Panel(title: "Tap") {
            Text(state.tempo.map { "\(Int($0.rounded())) BPM" } ?? "– BPM")
                .font(Theme.Fonts.mono(22, weight: .bold))
                .foregroundStyle(Theme.device.amber)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DisplayGlass(radius: 7))
        }
    }

    private var tunerModule: some View {
        Panel(title: "Stimmgerät am REACTOR") {
            VStack(alignment: .leading, spacing: 6) {
                Lamp(state.tunerOn ? "An · Ausgang stumm" : "Aus", isOn: state.tunerOn)
                Text(state.tunerOn ? "Wert \(state.tunerReading.map { String(format: "%.3f", $0) } ?? "ohne Signal")" : "Bank halten schaltet es an.")
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.device.amberDim)
            }
        }
    }

    private var footnote: String {
        var text = "Spark Studio sendet nichts an den REACTOR, auch keine Leseanfrage. Volume, Power Control, Wah, EQ und FX-Loop meldet er nicht oder sind nicht geprüft."
        let unknown = state.unknown.values.reduce(0, +)
        if unknown > 0 {
            let kinds = state.unknown.keys.sorted().joined(separator: ", ")
            text += " \(unknown) Meldungen ohne bekannte Bedeutung (\(kinds)) sind nur gezählt."
        }
        return text
    }
}

/// A knob that only shows a value, with the value below it, or "–" while it is not known.
private struct KnobReadout: View {
    let name: String
    let value: Float?
    let accent: Color

    var body: some View {
        VStack(spacing: 4) {
            KnobFace(position: Double(value ?? 0), accent: accent, isEnabled: value != nil)
                .frame(width: 48, height: 48)
            PanelLabel(name)
            Text(value.map(ReactorState.tenths) ?? "–")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.device.amber)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(value.map { ReactorState.tenths($0) + " von 10" } ?? "nicht gemeldet")
    }
}

/// A raised panel with its title engraved.
private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelLabel(title)
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel)
            .fill(LinearGradient(colors: [Swatch(hex: 0x2A2A2F).color, Swatch(hex: 0x19191C).color],
                                 startPoint: .top, endPoint: .bottom)))
    }
}
