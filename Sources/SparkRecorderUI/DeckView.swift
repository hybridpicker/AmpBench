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
                .accessibilityHint("Taste R")
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
            return model.selectedInput == nil ? "Kein Spark verbunden, Aufnahme nicht möglich" : "Aufnahme starten (R)"
        case .countIn: return "Einzähler abbrechen (R)"
        case .recording: return "Aufnahme stoppen (R)"
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
            if model.selectedInput == nil { return "KEIN SPARK" }
            if model.isRetroOn { return "HÖRT MIT" }
            return model.isMonitoring ? "PRÜFEN" : "BEREIT"
        case .preparing: return "START …"
        case .countIn(let beats): return "EINZÄHLER \(beats)"
        case .recording: return "AUFNAHME"
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
                    Text("R · AUFNAHME")
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
        .accessibilityLabel("Aufnahmezustand")
        .accessibilityValue("\(stateText), \(TimeText.spoken(meter.seconds))")
    }

    private var stateColor: Swatch {
        switch stateTone {
        case .listening: Theme.device.listening
        case .custom(let swatch): swatch
        default: Theme.device.amber
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            if model.isRecording, let grid = model.activeGrid {
                let position = grid.position(at: meter.seconds)
                Text((position.map { "Takt \($0.bar) · Schlag \($0.beat)" } ?? "Gleich geht's los")
                     + (model.pendingMarkerCount > 0 ? " · \(model.pendingMarkerCount) Marker" : ""))
                    .foregroundStyle(Theme.device.amber)
            } else if model.isRetroOn {
                Text("Puffer \(TimeText.clock(meter.retroSeconds)) von \(TimeText.clock(model.retroMinutes * 60))")
                    .foregroundStyle(Theme.device.listening)
            } else if model.pendingMarkerCount > 0, model.isRecording {
                Text("\(model.pendingMarkerCount) Marker")
                    .foregroundStyle(Theme.device.amber)
            } else {
                Text(model.isRecording ? "Gespeichert wird laufend"
                     : model.selectedInput == nil ? "Ohne Spark keine Aufnahme" : "Takt — · Schlag —")
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
        case .ok, .silent: return "Kein Signal"
        case .noData: return "Keine Daten"
        }
    }

    var body: some View {
        FaceplateModule("Pegel") {
            HStack(spacing: 12) {
                Button(action: model.clearClip) {
                    Lamp("Übersteuert", tone: .record, isOn: meter.clipped)
                }
                .buttonStyle(.plain)
                .help("Das Signal hat die Vollaussteuerung erreicht. Klick setzt die Anzeige zurück.")
                .accessibilityLabel(meter.clipped ? "Übersteuert, zurücksetzen" : "Keine Übersteuerung")

                Lamp(signalText, tone: .amber, isOn: model.isListening && meter.signal != .ok)
                    .accessibilityLabel(signalAccessibilityText)

                if meter.droppedFrames > 0 {
                    Lamp("Aussetzer", tone: .record, isOn: true)
                        .accessibilityLabel("Aussetzer in der Aufnahme")
                }
            }
        } content: {
            Spacer(minLength: 5)
            LEDMeter(level: meter.level, hold: meter.peakHold)
                .accessibilityLabel("Eingangspegel")
                .accessibilityValue(meterValue)
            Spacer(minLength: 5)
            HStack(alignment: .bottom, spacing: 8) {
                QualityLines()
                Spacer(minLength: 4)
                if !model.isRecording {
                    Button(model.isMonitoring ? "Prüfen beenden" : "Eingang prüfen", action: model.toggleMonitor)
                        .buttonStyle(.hardwareKey(model.isMonitoring ? .on : .normal, size: .small))
                        .disabled(model.selectedInput == nil || model.isRetroOn)
                        .help("Öffnet den Eingang nur zum Pegel prüfen. Es wird nichts gespeichert. Endet nach zwei Minuten von selbst.")
                }
            }
        }
    }

    private var meterValue: String {
        guard model.isListening else { return "Eingang geschlossen" }
        guard meter.peakHold > 0 else { return "Stille" }
        return "\(Int((20 * log10(meter.peakHold)).rounded())) dBFS"
    }

    private var signalAccessibilityText: String {
        guard model.isListening else { return "Eingang geschlossen" }
        switch meter.signal {
        case .ok: return "Signal vorhanden"
        case .silent: return "Kein Signal: Es kommt gerade nichts an"
        case .noData: return "Der Eingang liefert keine Daten"
        }
    }
}

/// Source and file are two separate lines. The file's 24 bits never get to look like the source's quality.
private struct QualityLines: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                PanelLabel("Quelle")
                Text(sourceText)
            }
            GridRow {
                PanelLabel("Datei")
                Text(fileText)
            }
        }
        .font(Theme.Fonts.mono(10.5))
        .foregroundStyle(Theme.device.labelDim)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .help("Die Datei hat 24 Bit, damit beim Bearbeiten Reserve bleibt. Details, die die Quelle nicht liefert, kommen dadurch nicht dazu.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Qualität")
        .accessibilityValue("Quelle \(sourceText). Datei \(fileText).")
    }

    private var sourceText: String {
        model.selectedInput.map { QualityText.source(device: $0) } ?? "kein Spark verbunden"
    }

    private var fileText: String {
        guard let input = model.selectedInput else { return "–" }
        return QualityText.file(bits: 24, sampleRate: input.maxRate, channels: input.channels)
    }
}

// MARK: - Spark

/// The amp's Bluetooth connection, shown in the deck by Spark Studio. Nil in Spark Recorder.
public struct DeckBluetooth {
    public enum State { case connected, busy, off, unavailable }

    public var state: State
    /// What the lamp's help and VoiceOver say, such as "Spark MINI" or "Suche den Verstärker …".
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
                row("Eingang") {
                    if model.inputs.isEmpty {
                        Text("Kein Spark verbunden")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.device.labelDim)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help("Die App nimmt nur von einem Spark über USB auf. Verbinde den Spark und schalte ihn ein.")
                    } else {
                        DevicePopup("Eingang", value: model.inputs.first { $0.id == model.inputID }?.name ?? "–") {
                            Picker("Eingang", selection: Binding(get: { model.inputID }, set: { model.chooseInput($0) })) {
                                ForEach(model.inputs) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                        .disabled(model.isRecording)
                    }
                }
                row("Ausgabe") {
                    DevicePopup("Ausgabe", value: model.outputs.first { $0.id == model.outputID }?.name ?? "Systemausgang") {
                        Picker("Ausgabe", selection: Binding(get: { model.outputID }, set: { model.chooseOutput($0) })) {
                            Text("Systemausgang").tag(AudioDeviceID?.none)
                            ForEach(model.outputs) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                row("Retro") {
                    HStack(spacing: 8) {
                        DeviceToggle("Retro", isOn: Binding(get: { model.isRetroOn }, set: { _ in model.toggleRetro() }))
                            .disabled(model.isRecording || (model.selectedInput == nil && !model.isRetroOn))
                            .help("Hält die letzten Minuten im Arbeitsspeicher. Nichts wird von selbst gespeichert. Standardmäßig aus.")
                            .accessibilityHint("Der Eingang hört dauerhaft mit, solange das eingeschaltet ist.")
                        if model.isRetroOn {
                            Button("Das eben war gut") { model.saveRetro() }
                                .buttonStyle(.hardwareKey(.on, keycap: "G", size: .small))
                                .keyboardShortcut("g", modifiers: .command)
                                .help("Speichert den ganzen Puffer als neue Aufnahme (⌘G oder G).")
                        } else {
                            DevicePopup("Länge des Retro-Puffers",
                                        selection: Binding(get: { model.retroMinutes }, set: { model.setRetroMinutes($0) }),
                                        options: AppModel.retroChoices.map { ($0, "\(Int($0)) Min.") })
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectionLamp: some View {
        if model.sparkWithoutInput {
            Lamp("Ohne Eingang", tone: .amber, isOn: true)
                .help("Der Spark Mini ist verbunden, stellt dem Mac aber gerade keinen Audioeingang bereit.")
                .accessibilityLabel("Spark ohne Eingang: Der Spark Mini ist verbunden, stellt dem Mac aber gerade keinen Audioeingang bereit.")
        } else if model.selectedInput == nil {
            Lamp("Kein Spark", isOn: false)
                .accessibilityLabel("Kein Spark verbunden")
        } else if model.feedbackRisk != .none {
            let explanation = FeedbackGuard.explanation(model.feedbackRisk) ?? ""
            Lamp("Ausgabe gesperrt", tone: .amber, isOn: true)
                .help(explanation)
                .accessibilityLabel("Ausgabe bei Aufnahme gesperrt. \(explanation)")
        } else {
            Lamp("Verbunden", tone: .on, isOn: true)
                .accessibilityLabel("Spark verbunden")
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
        .help("Verstärker über Bluetooth: \(bluetooth.detail). " + (isConnectedOrBusy
            ? "Klicken trennt, damit die Spark-App am Handy den Verstärker nutzen kann."
            : "Klicken verbindet."))
        .accessibilityLabel("Verstärker über Bluetooth: \(bluetooth.detail)")
        .accessibilityHint(isConnectedOrBusy ? "Trennt die Verbindung." : "Verbindet mit dem Verstärker.")
    }
}

// MARK: - Click

private struct ClickModule: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var meter: MeterState
    @State private var showDetails = false

    var body: some View {
        FaceplateModule("Klick") {
            HStack(spacing: 8) {
                beatLamps
                Button(action: model.toggleClick) {
                    Lamp(model.metronome.clickEnabled ? "An · N" : "Aus · N", isOn: model.metronome.clickEnabled)
                }
                .buttonStyle(.plain)
                .help("Klick an oder aus (N). Er ist nur beim Abspielen und Aufnehmen zu hören.")
                .accessibilityLabel(model.metronome.clickEnabled ? "Klick ausschalten" : "Klick einschalten")
                .accessibilityHint("Der Klick ist nur beim Abspielen und Aufnehmen zu hören.")
            }
        } content: {
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                DisplayStepper("Tempo", value: Binding(get: { model.metronome.bpm },
                                                       set: { value in model.updateMetronome { $0.bpm = value } }),
                               in: TapTempo.range, step: 1, text: "\(Int(model.metronome.bpm))", unit: "BPM", size: 20,
                               spokenValue: "\(Int(model.metronome.bpm)) Schläge pro Minute")
                    .disabled(model.phase != .idle)
                DevicePopup("Taktart",
                            selection: Binding(get: { model.metronome.beatsPerBar },
                                               set: { value in model.updateMetronome { $0.beatsPerBar = value } }),
                            options: [2, 3, 4, 5, 6, 7, 9, 12].map { ($0, "\($0)/4") })
                    .frame(width: 58)
                    .disabled(model.phase != .idle)
                Button("Tap", action: model.tap)
                    .buttonStyle(.hardwareKey(keycap: "T", size: .small))
                    .fixedSize()
                    .disabled(model.phase != .idle)
                    .help("Tempo eintippen (T)")
                    .accessibilityLabel("Tempo eintippen")
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                DevicePopup("Einzähler vor der Aufnahme",
                            selection: Binding(get: { model.metronome.countInBars },
                                               set: { value in model.updateMetronome { $0.countInBars = value } }),
                            options: [(0, "Kein Einzähler"), (1, "1 Takt einzählen"), (2, "2 Takte einzählen")])
                Button("⋯") { showDetails.toggle() }
                    .buttonStyle(.hardwareKey(size: .small))
                    .fixedSize()
                    .help("Einzähler, Lautstärke und Klickausgang")
                    .accessibilityLabel("Metronom-Einstellungen")
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
                Text("Lautstärke")
            }
            Toggle("Klick an", isOn: Binding(get: { model.metronome.clickEnabled }, set: { _ in model.toggleClick() }))
            Text("Er ist nur beim Abspielen und Aufnehmen zu hören. Beim Abspielen liegt er auf dem Ausgang der Wiedergabe, beim Aufnehmen auf dem Klick-Ausgang. Ein Einzähler klingt immer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Klick-Ausgang", selection: Binding(get: { model.clickOutputID }, set: { model.chooseClickOutput($0) })) {
                Text("Automatisch").tag(AudioDeviceID?.none)
                ForEach(model.outputs) { Text($0.name).tag(Optional($0.id)) }
            }
            if let output = model.clickOutput {
                Text("Beim Aufnehmen geht der Klick auf „\(output.name)“.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Es gibt gerade keinen Ausgang, der die Aufnahme sicher nicht erreicht.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.clickOutput != nil {
                Stepper(value: Binding(get: { model.currentLatencyCorrection * 1000 },
                                       set: { model.setLatencyCorrection($0 / 1000) }),
                        in: -100...300, step: 0.5) {
                    Text(String(format: "Ausgleich %+.1f ms", model.currentLatencyCorrection * 1000))
                        .monospacedDigit()
                }
                Text(latencyExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Latenz mit Kabel messen …") { model.showLatencyInfo = true }
                    .disabled(!model.canMeasureLatency)
            }
            Text("Der Klick landet nie durch die App in der Datei. Ausgänge desselben Geräts werden übersprungen, bis eine Messung zeigt, dass sie nicht am Eingang ankommen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var latencyExplanation: String {
        let reported = model.currentReportedLatency.map { String(format: "%.1f ms", $0 * 1000) } ?? "unbekannt"
        return "Die Geräte melden \(reported) vom Klick bis in die Datei, das gleicht die App immer aus. Der Ausgleich kommt für das, was der Amp intern verzögert, dazu. Er gilt für neue Aufnahmen mit diesem Klick-Ausgang."
    }
}
