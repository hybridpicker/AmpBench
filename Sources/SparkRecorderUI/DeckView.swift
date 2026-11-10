import AmpText
import CoreAudio
import SparkCore
import SparkDesign
import SwiftUI

/// The top panel, one device front with four engraved modules: recording, level, Spark, click.
struct DeckView: View {
    var body: some View {
        Faceplate {
            HStack(alignment: .center, spacing: 0) {
                RecordModule()
                    .padding(.trailing, 14)
                EngravedDivider()
                LevelModule()
                    .padding(.horizontal, 14)
                    .frame(minWidth: 240, maxWidth: .infinity)
                EngravedDivider()
                SparkModule()
                    .frame(width: 192)
                    .padding(.horizontal, 14)
                EngravedDivider()
                ClickModule()
                    .frame(width: 218)
                    .padding(.leading, 14)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(height: 122)
        }
    }
}

// MARK: - Recording

private struct RecordModule: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            RecordKey(state: recordState, action: model.toggleRecord)
                .disabled(!model.libraryIsUsable || (model.selectedInput == nil && !model.isRecording))
                .help(recordHelp)
                .accessibilityLabel(recordHelp)
                .accessibilityHint(tr("R key"))
            RecordDisplay()
                .frame(minWidth: 200, idealWidth: 258, maxWidth: 258)
        }
    }

    private var recordState: RecordKey.State {
        switch model.phase {
        case .recording: .recording
        case .countIn(let beats): .countIn(beats)
        case .idle, .preparing: .idle
        }
    }

    private var recordHelp: String {
        switch model.phase {
        case .idle, .preparing:
            return model.selectedInput == nil ? tr("No Spark connected, recording not possible") : tr("Start recording (R)")
        case .countIn: return tr("Cancel count-in (R)")
        case .recording: return tr("Stop recording (R)")
        }
    }
}

private struct RecordDisplay: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var meter: MeterState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var stateText: String {
        switch model.phase {
        case .idle:
            if model.selectedInput == nil { return tr("NO SPARK") }
            if model.isRetroOn { return tr("LISTENING") }
            return model.isMonitoring ? tr("CHECKING") : tr("READY")
        case .preparing: return tr("START …")
        case .countIn(let beats): return tr("COUNT-IN %d", beats)
        case .recording: return tr("RECORDING")
        }
    }

    private var stateTone: Lamp.Tone {
        if model.isRecording { return .record }
        if model.selectedInput == nil { return .custom(Theme.device.meterAmber) }
        return model.isListening ? .listening : .amber
    }

    var body: some View {
        Display(isAlert: model.isRecording) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    LampDot(tone: stateTone, isOn: true)
                        .opacity(model.isRecording && pulse && !reduceMotion ? 0.3 : 1)
                    Text(stateText)
                        .font(.system(size: 15, weight: .heavy, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(model.isRecording ? Theme.device.recordText : stateColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text(tr("R · RECORD"))
                        .font(Theme.Fonts.lamp())
                        .foregroundStyle(Theme.device.amberDim)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                Text(TimeText.clock(meter.seconds, tenths: true))
                    .font(Theme.Fonts.mono(34, weight: .semibold))
                    .foregroundStyle(model.isRecording ? Color.white : Theme.device.amber.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                // The device name gives way when the status needs the room.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        statusLine
                        Spacer(minLength: 4)
                        Text(model.selectedInput?.name ?? "")
                            .font(Theme.Fonts.mono(10))
                            .foregroundStyle(Theme.device.amberDim)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    statusLine
                }
            }
        }
        .frame(height: 92)
        .onChange(of: model.isRecording, initial: true) { _, recording in
            guard recording, !reduceMotion else {
                pulse = false
                return
            }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Recording state"))
        .accessibilityValue("\(stateText), \(TimeText.spoken(meter.seconds))")
    }

    private var stateColor: Swatch {
        switch stateTone {
        case .listening: Theme.device.listening
        case .custom(let swatch): swatch
        default: Theme.device.amber
        }
    }

    private var markerCountText: String {
        model.pendingMarkerCount == 1 ? tr("1 marker") : tr("%d markers", model.pendingMarkerCount)
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            if model.isRecording, let grid = model.activeGrid {
                let position = grid.position(at: meter.seconds)
                Text((position.map { tr("Bar %d · Beat %d", $0.bar, $0.beat) } ?? tr("Starting in a moment"))
                     + (model.pendingMarkerCount > 0 ? " · " + markerCountText : ""))
                    .foregroundStyle(Theme.device.amber)
            } else if model.isRetroOn {
                Text(tr("Buffer %@ of %@", TimeText.clock(meter.retroSeconds), TimeText.clock(model.retroMinutes * 60)))
                    .foregroundStyle(Theme.device.listening)
            } else if model.pendingMarkerCount > 0, model.isRecording {
                Text(markerCountText)
                    .foregroundStyle(Theme.device.amber)
            } else {
                Text(model.isRecording ? tr("Saving continuously")
                     : model.selectedInput == nil ? tr("No recording without a Spark") : tr("Bar — · Beat —"))
                    .foregroundStyle(Theme.device.amberDim)
            }
        }
        .font(Theme.Fonts.mono(10, weight: .semibold))
        .lineLimit(1)
    }
}

// MARK: - Level

private struct LevelModule: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var meter: MeterState

    private var signalText: String {
        switch meter.signal {
        case .ok, .silent: return tr("No signal")
        case .noData: return tr("No data")
        }
    }

    var body: some View {
        FaceplateModule(tr("Level")) {
            HStack(spacing: 12) {
                Button(action: model.clearClip) {
                    Lamp(tr("Clipping"), tone: .record, isOn: meter.clipped)
                }
                .buttonStyle(.plain)
                .help(tr("The signal reached full scale. A click resets the display."))
                .accessibilityLabel(meter.clipped ? tr("Clipping, reset") : tr("No clipping"))

                Lamp(signalText, tone: .amber, isOn: model.isListening && meter.signal != .ok)
                    .accessibilityLabel(signalAccessibilityText)

                if meter.droppedFrames > 0 {
                    Lamp(tr("Dropouts"), tone: .record, isOn: true)
                        .accessibilityLabel(tr("Dropouts in the recording"))
                }
            }
        } content: {
            Spacer(minLength: 5)
            LEDMeter(level: meter.level, hold: meter.peakHold)
                .accessibilityLabel(tr("Input level"))
                .accessibilityValue(meterValue)
            Spacer(minLength: 5)
            HStack(alignment: .bottom, spacing: 8) {
                QualityLines()
                Spacer(minLength: 4)
                if !model.isRecording {
                    Button(model.isMonitoring ? tr("Stop checking") : tr("Check input"), action: model.toggleMonitor)
                        .buttonStyle(.hardwareKey(model.isMonitoring ? .on : .normal, size: .small))
                        .disabled(model.selectedInput == nil || model.isRetroOn)
                        .help(tr("Opens the input only to check the level. Nothing is saved. Ends by itself after two minutes."))
                }
            }
        }
    }

    private var meterValue: String {
        guard model.isListening else { return tr("Input closed") }
        guard meter.peakHold > 0 else { return tr("Silence") }
        return "\(Int((20 * log10(meter.peakHold)).rounded())) dBFS"
    }

    private var signalAccessibilityText: String {
        guard model.isListening else { return tr("Input closed") }
        switch meter.signal {
        case .ok: return tr("Signal present")
        case .silent: return tr("No signal: nothing is arriving right now")
        case .noData: return tr("The input delivers no data")
        }
    }
}

/// Source and file are two separate lines. The file's 24 bits never get to look like the source's quality.
private struct QualityLines: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                PanelLabel(tr("Source"))
                Text(sourceText)
            }
            GridRow {
                PanelLabel(tr("File"))
                Text(fileText)
            }
        }
        .font(Theme.Fonts.mono(10.5))
        .foregroundStyle(Theme.device.labelDim)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .help(tr("The file has 24 bits so there is headroom for editing. That does not add detail the source does not deliver."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Quality"))
        .accessibilityValue(tr("Source %@. File %@.", sourceText, fileText))
    }

    private var sourceText: String {
        model.selectedInput.map { QualityText.source(device: $0) } ?? tr("no Spark connected")
    }

    private var fileText: String {
        guard let input = model.selectedInput else { return "–" }
        return QualityText.file(bits: 24, sampleRate: input.maxRate, channels: input.channels)
    }
}

// MARK: - Spark

/// The amp's Bluetooth connection, shown in the deck by AmpBench. Nil in Spark Recorder.
public struct DeckBluetooth {
    public enum State { case connected, busy, off, unavailable }

    public var state: State
    /// What the lamp's help and VoiceOver say, such as "Spark MINI" or "Searching for the amp …".
    public var detail: String
    /// Connects when off, disconnects otherwise.
    public var toggle: @MainActor () -> Void

    public init(state: State, detail: String, toggle: @escaping @MainActor () -> Void) {
        self.state = state
        self.detail = detail
        self.toggle = toggle
    }
}

private struct DeckBluetoothKey: EnvironmentKey {
    static var defaultValue: DeckBluetooth? { nil }
}

extension EnvironmentValues {
    public var deckBluetooth: DeckBluetooth? {
        get { self[DeckBluetoothKey.self] }
        set { self[DeckBluetoothKey.self] = newValue }
    }
}

private struct SparkModule: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.deckBluetooth) private var bluetooth

    var body: some View {
        FaceplateModule("Spark") {
            HStack(spacing: 8) {
                connectionLamp
                if let bluetooth { BluetoothLamp(bluetooth: bluetooth) }
            }
        } content: {
            Spacer(minLength: 4)
            VStack(spacing: 6) {
                row(tr("Input")) {
                    if model.inputs.isEmpty {
                        Text(tr("No Spark connected"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.device.labelDim)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(tr("The app records only from a Spark over USB. Connect the Spark and turn it on."))
                    } else {
                        DevicePopup(tr("Input"), value: model.inputs.first { $0.id == model.inputID }?.name ?? "–") {
                            Picker(tr("Input"), selection: Binding(get: { model.inputID }, set: { model.chooseInput($0) })) {
                                ForEach(model.inputs) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                        .disabled(model.isRecording)
                    }
                }
                row(tr("Output")) {
                    DevicePopup(tr("Output"), value: model.outputs.first { $0.id == model.outputID }?.name ?? tr("System output")) {
                        Picker(tr("Output"), selection: Binding(get: { model.outputID }, set: { model.chooseOutput($0) })) {
                            Text(tr("System output")).tag(AudioDeviceID?.none)
                            ForEach(model.outputs) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                row(tr("Retro")) {
                    HStack(spacing: 8) {
                        DeviceToggle(tr("Retro"), isOn: Binding(get: { model.isRetroOn }, set: { _ in model.toggleRetro() }))
                            .disabled(model.isRecording || (model.selectedInput == nil && !model.isRetroOn))
                            .help(tr("Keeps the last minutes in memory. Nothing is saved by itself. Off by default."))
                            .accessibilityHint(tr("The input keeps listening for as long as this is on."))
                        if model.isRetroOn {
                            Button(tr("That was good")) { model.saveRetro() }
                                .buttonStyle(.hardwareKey(.on, keycap: "G", size: .small))
                                .keyboardShortcut("g", modifiers: .command)
                                .help(tr("Saves the whole buffer as a new take (⌘G or G)."))
                        } else {
                            DevicePopup(tr("Length of the Retro buffer"),
                                        selection: Binding(get: { model.retroMinutes }, set: { model.setRetroMinutes($0) }),
                                        options: AppModel.retroChoices.map { ($0, tr("%d min", Int($0))) })
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectionLamp: some View {
        if model.sparkWithoutInput {
            Lamp(tr("No input"), tone: .amber, isOn: true)
                .help(tr("The Spark Mini is connected but is not providing an audio input to the Mac right now."))
                .accessibilityLabel(tr("Spark without input: The Spark Mini is connected but is not providing an audio input to the Mac right now."))
        } else if model.selectedInput == nil {
            Lamp(tr("No Spark"), isOn: false)
                .accessibilityLabel(tr("No Spark connected"))
        } else if model.feedbackRisk != .none {
            let explanation = FeedbackGuard.explanation(model.feedbackRisk) ?? ""
            Lamp(tr("Output blocked"), tone: .amber, isOn: true)
                .help(explanation)
                .accessibilityLabel(tr("Output blocked while recording. %@", explanation))
        } else {
            Lamp(tr("Connected"), tone: .on, isOn: true)
                .accessibilityLabel(tr("Spark connected"))
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            PanelLabel(label).frame(width: 54, alignment: .leading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// USB brings the sound in, Bluetooth controls the amp. The lamp is a key, like the click's: a click connects or
/// disconnects, so the Spark app on the phone can take the amp.
private struct BluetoothLamp: View {
    let bluetooth: DeckBluetooth

    private var isConnectedOrBusy: Bool { bluetooth.state == .connected || bluetooth.state == .busy }

    var body: some View {
        Button(action: bluetooth.toggle) {
            Lamp("BT", tone: bluetooth.state == .connected ? .on : .amber,
                 isOn: isConnectedOrBusy)
        }
        .buttonStyle(.plain)
        .disabled(bluetooth.state == .unavailable)
        .help(tr("Amp over Bluetooth: %@.", bluetooth.detail) + " " + (isConnectedOrBusy
            ? tr("Clicking disconnects, so the Spark app on the phone can use the amp.")
            : tr("Clicking connects.")))
        .accessibilityLabel(tr("Amp over Bluetooth: %@", bluetooth.detail))
        .accessibilityHint(isConnectedOrBusy ? tr("Disconnects.") : tr("Connects to the amp."))
    }
}

// MARK: - Click

private struct ClickModule: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var meter: MeterState
    @State private var showDetails = false

    var body: some View {
        FaceplateModule(tr("Click")) {
            HStack(spacing: 8) {
                beatLamps
                Button(action: model.toggleClick) {
                    Lamp(model.metronome.clickEnabled ? tr("On · N") : tr("Off · N"), isOn: model.metronome.clickEnabled)
                }
                .buttonStyle(.plain)
                .help(tr("Click on or off (N). It can only be heard while playing and recording."))
                .accessibilityLabel(model.metronome.clickEnabled ? tr("Turn click off") : tr("Turn click on"))
                .accessibilityHint(tr("The click can only be heard while playing and recording."))
            }
        } content: {
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                DisplayStepper(tr("Tempo"), value: Binding(get: { model.metronome.bpm },
                                                       set: { value in model.updateMetronome { $0.bpm = value } }),
                               in: TapTempo.range, step: 1, text: "\(Int(model.metronome.bpm))", unit: "BPM", size: 20,
                               spokenValue: tr("%d beats per minute", Int(model.metronome.bpm)))
                    .disabled(model.phase != .idle)
                DevicePopup(tr("Time signature"),
                            selection: Binding(get: { model.metronome.beatsPerBar },
                                               set: { value in model.updateMetronome { $0.beatsPerBar = value } }),
                            options: [2, 3, 4, 5, 6, 7, 9, 12].map { ($0, "\($0)/4") })
                    .frame(width: 58)
                    .disabled(model.phase != .idle)
                Button(tr("Tap"), action: model.tap)
                    .buttonStyle(.hardwareKey(keycap: "T", size: .small))
                    .fixedSize()
                    .disabled(model.phase != .idle)
                    .help(tr("Tap in the tempo (T)"))
                    .accessibilityLabel(tr("Tap in the tempo"))
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                DevicePopup(tr("Count-in before recording"),
                            selection: Binding(get: { model.metronome.countInBars },
                                               set: { value in model.updateMetronome { $0.countInBars = value } }),
                            options: [(0, tr("No count-in")), (1, tr("Count in 1 bar")), (2, tr("Count in 2 bars"))])
                Button("⋯") { showDetails.toggle() }
                    .buttonStyle(.hardwareKey(size: .small))
                    .fixedSize()
                    .help(tr("Count-in, volume and click output"))
                    .accessibilityLabel(tr("Metronome settings"))
                    .popover(isPresented: $showDetails) { MetronomeDetails().padding(14).frame(width: 300) }
            }
        }
    }

    private var beatLamps: some View {
        let beatsPerBar = max(model.activeBeatsPerBar, 1)
        let current = meter.beat > 0 ? Int((meter.beat - 1) % UInt64(beatsPerBar)) : -1
        return HStack(spacing: 3) {
            ForEach(0..<min(beatsPerBar, 4), id: \.self) { index in
                LampDot(isOn: current == index, size: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MetronomeDetails: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Slider(value: Binding(get: { Double(model.metronome.volume) }, set: { value in model.updateMetronome { $0.volume = Float(value) } }), in: 0...1) {
                Text(tr("Volume"))
            }
            Toggle(tr("Click on"), isOn: Binding(get: { model.metronome.clickEnabled }, set: { _ in model.toggleClick() }))
            Text(tr("It can only be heard while playing and recording. While playing it is on the playback output, while recording on the click output. A count-in always sounds."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(tr("Click output"), selection: Binding(get: { model.clickOutputID }, set: { model.chooseClickOutput($0) })) {
                Text(tr("Automatic")).tag(AudioDeviceID?.none)
                ForEach(model.outputs) { Text($0.name).tag(Optional($0.id)) }
            }
            if let output = model.clickOutput {
                Text(tr("While recording, the click goes to “%@”.", output.name))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(tr("Right now there is no output that is certain not to reach the recording."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.clickOutput != nil {
                Stepper(value: Binding(get: { model.currentLatencyCorrection * 1000 },
                                       set: { model.setLatencyCorrection($0 / 1000) }),
                        in: -100...300, step: 0.5) {
                    Text(tr("Compensation %+.1f ms", model.currentLatencyCorrection * 1000))
                        .monospacedDigit()
                }
                Text(latencyExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("Measure latency with a cable …")) { model.showLatencyInfo = true }
                    .disabled(!model.canMeasureLatency)
            }
            Text(tr("The app never puts the click into the file. Outputs of the same device are skipped until a measurement shows that they do not arrive at the input."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var latencyExplanation: String {
        let reported = model.currentReportedLatency.map { tr("%.1f ms", $0 * 1000) } ?? tr("unknown")
        return tr("The devices report %@ from the click into the file; the app always compensates for that. The compensation is added for what the amp delays internally. It applies to new takes with this click output.", reported)
    }
}
