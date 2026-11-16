import AmpText
import SparkCore
import SparkDesign
import SwiftUI

/// The area "Metronome": one dark front, like the tuner. On top the tempo large in amber, the bar and the trainer;
/// below it one lamp per beat, which lights when its click is heard and which a click sets to accent, normal, soft
/// or silent; at the bottom the modules tempo, bar, subdivision, sound, trainer and piece.
struct MetronomeView: View {
    @ObservedObject var model: MetronomeModel

    var body: some View {
        VStack(spacing: 12) {
            Faceplate(radius: Theme.Radius.panel) {
                VStack(spacing: 0) {
                    TimelineView(.animation(minimumInterval: nil, paused: !model.isRunning)) { context in
                        let pulse = model.pulse(at: MetronomeEngine.now)
                        VStack(spacing: 14) {
                            readout(pulse)
                            BeatRow(model: model, pulse: pulse)
                        }
                        .padding(18)
                        .onChange(of: context.date) { _, _ in }
                    }
                    EngravedDivider(.horizontal, inset: 0)
                    controls
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                }
            }
            .frame(maxWidth: 1040)
            Text(caption)
                .font(.callout)
                .foregroundStyle(model.problem == nil ? .secondary : Theme.device.amberHot.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
        }
        .padding(24)
        // Drawn for the Mac's smallest window; a narrower iPad shows it scaled, not cut.
        .fittedOnPad(designWidth: 1000)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var caption: String {
        if let problem = model.problem { return problem }
        #if os(macOS)
        let output = model.outputName.isEmpty ? tr("the system output") : model.outputName
        let place = tr("Plays on %@, the output chosen in the deck.", output)
        #else
        let place = tr("Plays on the iPad’s current output; other apps keep playing.")
        #endif
        return place + " " + tr("Every click is placed on the output’s own sample clock, to a fraction of a sample, and the lamps light when it is heard. Space starts and stops it; a recording takes over the tempo and stops it.")
    }

    // MARK: Readout

    private func readout(_ pulse: MetronomePulse?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Display(padding: EdgeInsets(top: 10, leading: 18, bottom: 12, trailing: 18)) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(model.playingBPM.rounded()))")
                            .font(Theme.Fonts.mono(76, weight: .semibold))
                            .foregroundStyle(Theme.device.amber.color)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("BPM")
                            .font(Theme.Fonts.mono(16, weight: .semibold))
                            .foregroundStyle(Theme.device.amberDim.color)
                    }
                    Text(trainerLine)
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.device.amberDim.color)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tr("%d beats per minute", Int(model.playingBPM.rounded())))
            Display(padding: EdgeInsets(top: 10, leading: 18, bottom: 12, trailing: 18)) {
                VStack(alignment: .leading, spacing: 6) {
                    PanelLabel(tr("Bar"), color: Theme.device.amberDim.color)
                    Text(pulse.map { "\($0.bar + 1)" } ?? "–")
                        .font(Theme.Fonts.mono(40, weight: .semibold))
                        .foregroundStyle(Theme.device.amber.color)
                        .monospacedDigit()
                    Text(pulse.map { tr("Beat %d of %d", $0.beat + 1, model.settings.beatsPerBar) }
                         ?? "\(model.settings.beatsPerBar)/4")
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.device.amberDim.color)
                }
                .frame(width: 150, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(height: 128)
    }

    private var trainerLine: String {
        let trainer = model.settings.trainer
        guard trainer.isOn else {
            return model.isRunning ? tr("playing") : tr("stopped")
        }
        return tr("Trainer: %1$@%2$d BPM every %3$d bars, up to %4$d", trainer.targetBPM >= model.settings.bpm ? "+" : "−",
                  Int(abs(trainer.stepBPM)), trainer.everyBars, Int(trainer.targetBPM))
    }

    // MARK: Controls

    private var controls: some View {
        HStack(alignment: .top, spacing: 14) {
            module(tr("Tempo")) {
                HStack(spacing: 6) {
                    DisplayStepper(tr("Tempo"), value: Binding(get: { model.settings.bpm }, set: { model.setBPM($0) }),
                                   in: MetronomeSettings.bpmRange, step: 1, text: "\(Int(model.settings.bpm))",
                                   unit: "BPM", size: 20,
                                   spokenValue: tr("%d beats per minute", Int(model.settings.bpm)))
                    Button(tr("Tap"), action: model.tap)
                        .buttonStyle(.hardwareKey(keycap: "⌘T", size: .small))
                        .fixedSize()
                        .help(tr("Tap in the tempo (⌘T)"))
                }
                Button(model.isRunning ? tr("Stop") : tr("Start"), action: model.toggle)
                    .buttonStyle(.hardwareKey(model.isRunning ? .on : .primary, keycap: tr("Space")))
                    .fixedSize()
                    .help(tr("Start or stop the metronome (Space)"))
            }
            EngravedDivider()
            module(tr("Bar")) {
                DevicePopup(tr("Beats per bar"), selection: Binding(get: { model.settings.beatsPerBar },
                                                                    set: { model.setBeats($0) }),
                            options: MetronomeSettings.beatsRange.map { ($0, "\($0)/4") })
                    .frame(width: 70)
                SegmentTabs(tr("Subdivision"), selection: Binding(
                    get: { model.settings.pattern.subdivision },
                    set: { value in model.update { $0.pattern.subdivision = value } }),
                            options: [(.quarters, "♩"), (.eighths, "♪♪"), (.triplets, "3"), (.sixteenths, "16")])
                    .fixedSize()
                    .help(tr("Quarters, eighths, triplets or sixteenths between the beats"))
            }
            EngravedDivider()
            module(tr("Sound")) {
                DevicePopup(tr("Sound"), selection: Binding(get: { model.settings.pattern.sound },
                                                            set: { value in model.update { $0.pattern.sound = value } }),
                            options: [(.classic, tr("Classic")), (.wood, tr("Wood")), (.beep, tr("Beep"))])
                    .frame(width: 100)
                labeled(tr("Volume")) {
                    DeviceSlider(tr("Volume"), value: Binding(get: { Double(model.settings.volume) },
                                                              set: { value in model.update { $0.volume = Float(value) } }),
                                 in: 0...1, step: 0.05, valueText: "\(Int(model.settings.volume * 100)) %")
                }
                labeled(tr("Subdivisions")) {
                    DeviceSlider(tr("Subdivisions"), value: Binding(
                        get: { Double(model.settings.pattern.subdivisionLevel) },
                        set: { value in model.update { $0.pattern.subdivisionLevel = Float(value) } }),
                                 in: 0...1, step: 0.05,
                                 valueText: "\(Int(model.settings.pattern.subdivisionLevel * 100)) %")
                }
                .disabled(model.settings.pattern.subdivision == .quarters)
            }
            EngravedDivider()
            trainer
            if !model.pieces.isEmpty {
                EngravedDivider()
                piece
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var trainer: some View {
        let value = model.settings.trainer
        return module(tr("Tempo trainer")) {
            HStack(spacing: 8) {
                DeviceToggle(tr("Trainer"), isOn: Binding(get: { value.isOn },
                                                          set: { on in model.update { $0.trainer.isOn = on } }))
                PanelLabel(value.isOn ? tr("on") : tr("off"))
            }
            HStack(spacing: 6) {
                DisplayStepper(tr("Step"), value: Binding(get: { value.stepBPM },
                                                          set: { step in model.update { $0.trainer.stepBPM = step } }),
                               in: 1...20, step: 1, text: "±\(Int(value.stepBPM))", unit: "BPM", size: 14,
                               spokenValue: tr("Step %d beats per minute", Int(value.stepBPM)))
                DisplayStepper(tr("Every"), value: Binding(get: { Double(value.everyBars) },
                                                           set: { bars in model.update { $0.trainer.everyBars = Int(bars) } }),
                               in: 1...32, step: 1, text: "\(value.everyBars)", unit: tr("bars"), size: 14,
                               spokenValue: tr("Every %d bars", value.everyBars))
            }
            DisplayStepper(tr("Target"), value: Binding(get: { value.targetBPM },
                                                        set: { target in model.update { $0.trainer.targetBPM = target } }),
                           in: MetronomeSettings.bpmRange, step: 1, text: "\(Int(value.targetBPM))", unit: tr("BPM target"),
                           size: 14, spokenValue: tr("Target %d beats per minute", Int(value.targetBPM)))
        }
        .opacity(value.isOn ? 1 : 0.75)
    }

    private var piece: some View {
        module(tr("Piece")) {
            DevicePopup(tr("Piece"), selection: Binding(get: { model.chosenPieceID ?? model.pieces.first?.id ?? UUID() },
                                                        set: { model.chosenPieceID = $0 }),
                        options: model.pieces.map { ($0.id, pieceTitle($0)) })
                .frame(width: 170)
            HStack(spacing: 6) {
                Button(tr("Load"), action: model.loadChosenPiece)
                    .buttonStyle(.hardwareKey(size: .small))
                    .disabled(model.chosenPiece?.bpm == nil)
                    .help(tr("Take tempo, bar, accents and subdivision from the piece"))
                Button(tr("Keep in piece"), action: model.storeInChosenPiece)
                    .buttonStyle(.hardwareKey(size: .small))
                    .disabled(model.chosenPiece == nil)
                    .help(tr("Keep this tempo, bar, accents and subdivision in the piece"))
            }
            .fixedSize()
        }
    }

    private func pieceTitle(_ piece: MetronomePiece) -> String {
        guard let bpm = piece.bpm else { return piece.name }
        return "\(piece.name) · \(Int(bpm))"
    }

    /// A slider with its name in small letters to its left.
    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            PanelLabel(title, size: 8.5)
                .frame(width: 98, alignment: .leading)
            content()
                .frame(width: 110)
        }
    }

    private func module<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(title)
            content()
        }
    }
}

/// One lamp per beat, with small dots for the subdivisions between them. A lamp lights while its beat is heard; a
/// click on it changes its level.
private struct BeatRow: View {
    @ObservedObject var model: MetronomeModel
    let pulse: MetronomePulse?

    var body: some View {
        let levels = model.settings.levels
        let sub = model.settings.pattern.subdivision.rawValue
        HStack(spacing: 10) {
            ForEach(levels.indices, id: \.self) { beat in
                HStack(spacing: 6) {
                    Button { model.cycleLevel(ofBeat: beat) } label: {
                        BeatLamp(level: levels[beat], isLit: pulse?.beat == beat && pulse?.sub == 0,
                                 number: beat + 1)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Beat %d: %@. A click changes it: accent, normal, soft, silent.", beat + 1, name(levels[beat])))
                    .accessibilityLabel(tr("Beat %d", beat + 1))
                    .accessibilityValue(name(levels[beat]))
                    if sub > 1 {
                        ForEach(1..<sub, id: \.self) { index in
                            LampDot(tone: .amber, isOn: pulse?.beat == beat && pulse?.sub == index, size: 6)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 74)
    }

    private func name(_ level: MetronomePattern.Level) -> String {
        switch level {
        case .accent: tr("accent")
        case .normal: tr("normal")
        case .soft: tr("soft")
        case .mute: tr("silent")
        }
    }
}

private struct BeatLamp: View {
    let level: MetronomePattern.Level
    let isLit: Bool
    let number: Int

    private var size: CGFloat {
        switch level {
        case .accent: 46
        case .normal: 38
        case .soft: 30
        case .mute: 30
        }
    }

    private var color: Color {
        level == .accent ? Theme.device.amberHot.color : Theme.device.amber.color
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isLit && level != .mute ? color : Theme.device.lampOff.color)
                    .shadow(color: isLit && level != .mute ? color.opacity(0.8) : .clear, radius: 10)
                Circle()
                    .strokeBorder(level == .mute ? Theme.device.lampOffText.color : color.opacity(0.6),
                                  style: StrokeStyle(lineWidth: 1.5, dash: level == .mute ? [3, 3] : []))
                Text("\(number)")
                    .font(Theme.Fonts.mono(12, weight: .semibold))
                    .foregroundStyle(isLit ? Color.black.opacity(0.75) : Theme.device.lampOffText.color)
            }
            .frame(width: size, height: size)
            .frame(width: 48, height: 48)
        }
        .contentShape(Rectangle())
    }
}
