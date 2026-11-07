import CoreAudio
import SparkCore
import SwiftUI

/// The top panel: recording state, level, source and file format, devices, metronome.
struct DeckView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            recordKey
            RecordDisplay()
                .frame(width: 214)
            VStack(alignment: .leading, spacing: 6) {
                MeterPanel()
                QualityPanel()
            }
            .frame(minWidth: 300, maxWidth: .infinity)
            DevicePanel()
                .frame(width: 236)
            MetronomePanel()
                .frame(width: 212)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [Theme.faceplateTop, Theme.faceplateBottom], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.faceplateLine).frame(height: 1)
        }
    }

    private var recordKey: some View {
        Button(action: model.toggleRecord) {
            ZStack {
                switch model.phase {
                case .recording:
                    RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 22, height: 22)
                case .countIn(let beats):
                    Text("\(beats)").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                case .idle, .preparing:
                    EmptyView()
                }
            }
            .frame(width: 92, height: 92)
            .contentShape(Circle())
        }
        .buttonStyle(RecordKeyStyle(isActive: model.isRecording, reduceMotion: reduceMotion))
        .frame(width: 92, height: 92)
        .disabled(!model.libraryIsUsable || (model.selectedInput == nil && !model.isRecording))
        .help(recordHelp)
        .accessibilityLabel(recordHelp)
        .accessibilityHint("Taste R")
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

// MARK: - Display

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

    private var stateColor: Color {
        if model.isRecording { return Theme.record }
        if model.selectedInput == nil { return Theme.meterAmber }
        return model.isListening ? Theme.listening : Theme.displayText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 12, height: 12)
                    .opacity(model.isRecording && pulse && !reduceMotion ? 0.3 : 1)
                    .accessibilityHidden(true)
                Text(stateText)
                    .font(.system(size: 19, weight: .heavy, design: .monospaced))
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(TimeText.clock(meter.seconds, tenths: true))
                .font(.system(size: 34, weight: .semibold, design: .monospaced).monospacedDigit())
                .foregroundStyle(model.isRecording ? Color.white : Theme.displayText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            statusLine
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 92)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.display))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(model.isRecording ? Theme.record : Theme.displayLine, lineWidth: model.isRecording ? 2 : 1)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aufnahmezustand")
        .accessibilityValue("\(stateText), \(TimeText.spoken(meter.seconds))")
    }

    @ViewBuilder
    private var statusLine: some View {
        if model.isRecording, let grid = model.activeGrid {
            let position = grid.position(at: meter.seconds)
            Text((position.map { "Takt \($0.bar) · Schlag \($0.beat)" } ?? "Gleich geht's los")
                 + (model.pendingMarkerCount > 0 ? " · \(model.pendingMarkerCount) Marker" : ""))
                .font(.system(size: 11, weight: .semibold, design: .monospaced).monospacedDigit())
                .foregroundStyle(Theme.displayText)
                .lineLimit(1)
        } else if model.isRetroOn {
            Text("Puffer \(TimeText.clock(meter.retroSeconds)) von \(TimeText.clock(model.retroMinutes * 60))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.listening)
                .lineLimit(1)
        } else if model.pendingMarkerCount > 0, model.isRecording {
            Text("\(model.pendingMarkerCount) Marker")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.displayText)
        } else {
            Text(model.isRecording ? "Gespeichert wird laufend"
                 : model.selectedInput == nil ? "Ohne Spark keine Aufnahme" : "Taste R nimmt auf")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.displayDim)
                .lineLimit(1)
        }
    }
}

// MARK: - Meter

private struct MeterPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var meter: MeterState

    private static let floorDB: Float = -60
    private static let segments = 48

    private func position(_ level: Float) -> Float {
        guard level > 0 else { return 0 }
        return min(1, max(0, (20 * log10(level) - Self.floorDB) / -Self.floorDB))
    }

    private var signalText: String {
        switch meter.signal {
        case .ok: return "KEIN SIGNAL"
        case .silent: return "KEIN SIGNAL"
        case .noData: return "KEINE DATEN"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let lit = Int(position(meter.level) * Float(Self.segments))
                let hold = Int(position(meter.peakHold) * Float(Self.segments))
                let gap: CGFloat = 2
                let width = (size.width - gap * CGFloat(Self.segments - 1)) / CGFloat(Self.segments)
                for index in 0..<Self.segments {
                    let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                    let isLit = index < lit || (hold > 0 && index == hold - 1)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color(index, lit: isLit)))
                }
            }
            .frame(height: 16)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.display))
            .accessibilityElement()
            .accessibilityLabel("Eingangspegel")
            .accessibilityValue(meterValue)

            MeterScale().frame(height: 11).padding(.horizontal, 4).accessibilityHidden(true)

            HStack(spacing: 12) {
                Button(action: model.clearClip) {
                    Lamp(text: "ÜBERSTEUERT", color: Theme.meterRed, isOn: meter.clipped)
                }
                .buttonStyle(.plain)
                .help("Das Signal hat die Vollaussteuerung erreicht. Klick setzt die Anzeige zurück.")
                .accessibilityLabel(meter.clipped ? "Übersteuert, zurücksetzen" : "Keine Übersteuerung")

                Lamp(text: signalText, color: Theme.meterAmber, isOn: model.isListening && meter.signal != .ok)
                    .accessibilityLabel(signalAccessibilityText)

                if meter.droppedFrames > 0 {
                    Lamp(text: "AUSSETZER", color: Theme.meterRed, isOn: true)
                        .accessibilityLabel("Aussetzer in der Aufnahme")
                }
                Spacer(minLength: 4)
                if !model.isRecording {
                    Button(model.isMonitoring ? "Prüfen beenden" : "Eingang prüfen", action: model.toggleMonitor)
                        .controlSize(.small)
                        .disabled(model.selectedInput == nil || model.isRetroOn)
                        .help("Öffnet den Eingang nur zum Pegel prüfen. Es wird nichts gespeichert. Endet nach zwei Minuten von selbst.")
                }
            }
            .padding(.horizontal, 2)
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

    private func color(_ index: Int, lit: Bool) -> Color {
        guard lit else { return Theme.meterOff }
        let db = Self.floorDB * (1 - Float(index) / Float(Self.segments))
        if db >= -3 { return Theme.meterRed }
        if db >= -12 { return Theme.meterAmber }
        return Theme.meterGreen
    }
}

private struct MeterScale: View {
    private let marks: [Float] = [-60, -48, -36, -24, -12, -6, 0]

    var body: some View {
        GeometryReader { geometry in
            ForEach(marks, id: \.self) { mark in
                Text("\(Int(mark))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.engraved)
                    .fixedSize()
                    .position(x: labelX(mark, width: geometry.size.width), y: geometry.size.height / 2)
            }
        }
    }

    private func labelX(_ mark: Float, width: CGFloat) -> CGFloat {
        let x = CGFloat((mark + 60) / 60) * width
        return min(max(x, 10), width - 6)
    }
}

// MARK: - Quality

/// Source and file are two separate lines. The file's 24 bits never get to look like the source's quality.
private struct QualityPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
            GridRow {
                PanelLabel("Quelle")
                Text(sourceText).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            }
            GridRow {
                PanelLabel("Datei")
                Text(fileText).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            }
        }
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

// MARK: - Devices

private struct DevicePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            labeledPicker("Eingang") {
                if model.inputs.isEmpty {
                    Label("Kein Spark verbunden", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.engraved)
                        .lineLimit(1)
                        .help("Die App nimmt nur von einem Spark über USB auf. Verbinde den Spark und schalte ihn ein.")
                } else {
                    Picker("Eingang", selection: Binding(get: { model.inputID }, set: { model.chooseInput($0) })) {
                        ForEach(model.inputs) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .disabled(model.isRecording)
                }
            }
            labeledPicker("Ausgabe") {
                Picker("Ausgabe", selection: Binding(get: { model.outputID }, set: { model.chooseOutput($0) })) {
                    Text("Systemausgang").tag(AudioDeviceID?.none)
                    ForEach(model.outputs) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if model.sparkWithoutInput {
                warning("Spark ohne Eingang", help: "Der Spark Mini ist verbunden, stellt dem Mac aber gerade keinen Audioeingang bereit.")
            } else if model.feedbackRisk != .none {
                warning("Ausgabe bei Aufnahme gesperrt", help: FeedbackGuard.explanation(model.feedbackRisk) ?? "")
            }
            HStack(spacing: 6) {
                Toggle("Retro", isOn: Binding(get: { model.isRetroOn }, set: { _ in model.toggleRetro() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .disabled(model.isRecording || (model.selectedInput == nil && !model.isRetroOn))
                    .help("Hält die letzten Minuten im Arbeitsspeicher. Nichts wird von selbst gespeichert. Standardmäßig aus.")
                    .accessibilityHint("Der Eingang hört dauerhaft mit, solange das eingeschaltet ist.")
                if model.isRetroOn {
                    Button("Das eben war gut") { model.saveRetro() }
                        .controlSize(.small)
                        .keyboardShortcut("g", modifiers: .command)
                        .help("Speichert den ganzen Puffer als neue Aufnahme (⌘G oder G).")
                } else {
                    Picker("Puffer", selection: Binding(get: { model.retroMinutes }, set: { model.setRetroMinutes($0) })) {
                        ForEach(AppModel.retroChoices, id: \.self) { Text("\(Int($0)) Min.").tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 72)
                    .help("Länge des Retro-Puffers")
                    .accessibilityLabel("Länge des Retro-Puffers")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func labeledPicker<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            PanelLabel(label).frame(width: 44, alignment: .leading)
            content()
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private func warning(_ text: String, help: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.engraved)
            .lineLimit(1)
            .help(help)
            .accessibilityLabel(help)
    }
}

// MARK: - Metronome

private struct MetronomePanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var meter: MeterState
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button(action: model.toggleClick) {
                    Image(systemName: "metronome.fill")
                }
                .buttonStyle(DeckKeyStyle(isOn: model.metronome.clickEnabled))
                .help("Klick an oder aus (N). Er ist nur beim Abspielen und Aufnehmen zu hören.")
                .accessibilityLabel(model.metronome.clickEnabled ? "Klick ausschalten" : "Klick einschalten")
                .accessibilityHint("Der Klick ist nur beim Abspielen und Aufnehmen zu hören.")

                Stepper(value: Binding(get: { model.metronome.bpm }, set: { value in model.updateMetronome { $0.bpm = value } }),
                        in: TapTempo.range, step: 1) {
                    Text("\(Int(model.metronome.bpm))")
                        .font(.system(size: 17, weight: .semibold, design: .monospaced).monospacedDigit())
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .disabled(model.phase != .idle)
                .accessibilityLabel("Tempo")
                .accessibilityValue("\(Int(model.metronome.bpm)) Schläge pro Minute")
                PanelLabel("BPM")
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button("Tap", action: model.tap)
                    .buttonStyle(DeckKeyStyle())
                    .disabled(model.phase != .idle)
                    .help("Tempo eintippen (T)")
                    .accessibilityLabel("Tempo eintippen")
                Picker("Taktart", selection: Binding(get: { model.metronome.beatsPerBar }, set: { value in model.updateMetronome { $0.beatsPerBar = value } })) {
                    ForEach([2, 3, 4, 5, 6, 7, 9, 12], id: \.self) { Text("\($0)/4").tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 62)
                .disabled(model.phase != .idle)
                .accessibilityLabel("Taktart")
                Button {
                    showDetails.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(DeckKeyStyle())
                .help("Einzähler, Lautstärke und Klickausgang")
                .accessibilityLabel("Metronom-Einstellungen")
                .popover(isPresented: $showDetails) { MetronomeDetails().padding(14).frame(width: 300) }
                beatLamps
            }
            Picker("Einzähler", selection: Binding(get: { model.metronome.countInBars }, set: { value in model.updateMetronome { $0.countInBars = value } })) {
                Text("Kein Einzähler").tag(0)
                Text("1 Takt einzählen").tag(1)
                Text("2 Takte einzählen").tag(2)
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Einzähler vor der Aufnahme")
        }
    }

    private var beatLamps: some View {
        let beatsPerBar = max(model.activeBeatsPerBar, 1)
        let current = meter.beat > 0 ? Int((meter.beat - 1) % UInt64(beatsPerBar)) : -1
        return HStack(spacing: 2) {
            ForEach(0..<min(beatsPerBar, 4), id: \.self) { index in
                Circle()
                    .fill(current == index ? Theme.meterAmber : Theme.meterOff)
                    .frame(width: 6, height: 6)
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
            Text("Der Klick landet nie durch die App in der Datei. Ausgänge desselben Geräts werden übersprungen, bis eine Messung zeigt, dass sie nicht am Eingang ankommen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
