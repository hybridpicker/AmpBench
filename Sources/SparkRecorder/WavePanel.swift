import SparkCore
import SwiftUI

/// The middle panel: the take in focus, its waveform, the transport and the decision keys.
struct WavePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            if !model.compareIDs.isEmpty {
                CompareStack()
            } else if model.isRecording {
                LiveWaveView().frame(height: 118)
            } else {
                singleWave.frame(height: 118)
            }
            TransportBar()
            if !model.isRecording, model.compareIDs.isEmpty, let recording = model.current, let grid = recording.grid,
               recording.health == .ok {
                BarControls(recording: recording, grid: grid)
            }
            if let banner = model.banner {
                BannerView(banner: banner)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var singleWave: some View {
        if let recording = model.current {
            switch recording.health {
            case .ok:
                if let waveform = model.currentWaveform {
                    WaveformEditor(recording: recording, waveform: waveform, isActive: true)
                } else {
                    placeholder(model.isAnalyzing ? "Wellenform wird berechnet …" : "Keine Wellenform verfügbar")
                }
            case .missing:
                placeholder("Die Datei „\(recording.fileName)“ fehlt im Ordner.")
            case .damaged:
                placeholder("Die Datei „\(recording.fileName)“ ist beschädigt und lässt sich nicht lesen.")
            }
        } else {
            placeholder(!model.recordings.isEmpty
                        ? "Wähle unten eine Aufnahme aus."
                        : model.selectedInput == nil
                        ? "Noch keine Aufnahmen. Schließ den Spark an, dann nimmst du mit R die erste auf."
                        : "Noch keine Aufnahmen. Mit R nimmst du die erste auf.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.waveBackground)
            .overlay(Text(text).foregroundStyle(.secondary))
    }
}

// MARK: - Waveform

/// Draws peaks only when the data or size changes. The playhead sits in a separate view on top.
private struct WaveformShape: View, Equatable {
    let waveform: WaveformData
    let duration: Double

    var body: some View {
        Canvas { context, size in
            let columns = waveform.columns(Int(size.width), from: 0, to: duration)
            let middle = size.height / 2
            // Drawn relative to its own peak, so a quiet source still shows its shape. The meter shows true levels.
            let scale = CGFloat(WaveformData.displayScale(peak: waveform.peak)) * middle * 0.96
            var path = Path()
            for (index, column) in columns.enumerated() {
                let top = middle - CGFloat(column.max) * scale
                let bottom = middle - CGFloat(column.min) * scale
                path.addRect(CGRect(x: CGFloat(index), y: top, width: 1, height: max(bottom - top, 0.5)))
            }
            context.fill(path, with: .color(Theme.wave))
        }
    }

    static func == (lhs: WaveformShape, rhs: WaveformShape) -> Bool {
        lhs.duration == rhs.duration && lhs.waveform.binCount == rhs.waveform.binCount
    }
}

struct WaveformEditor: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording
    let waveform: WaveformData
    let isActive: Bool
    @State private var dragStart: CGFloat?
    @State private var dragCurrent: CGFloat?

    private var duration: Double { max(recording.duration, 0.001) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.waveBackground)
                WaveformShape(waveform: waveform, duration: duration)
                    .equatable()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if let grid = recording.grid {
                    BarGridOverlay(grid: grid, duration: duration)
                        .equatable()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                trimShade(width: width, height: geometry.size.height)
                loopOverlay(width: width, height: geometry.size.height)
                markerOverlay(width: width, height: geometry.size.height)
                if isActive {
                    PlayheadLine(duration: duration)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation.x }
                        dragCurrent = value.location.x
                    }
                    .onEnded { value in
                        finishDrag(start: value.startLocation.x, end: value.location.x, width: width)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Wellenform von \(recording.name)")
            .accessibilityValue("Länge \(TimeText.spoken(recording.duration))")
            .accessibilityHint("Mit Pfeiltasten springen, Taste L setzt die Schleife")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.nudge(by: 5)
                case .decrement: model.nudge(by: -5)
                @unknown default: break
                }
            }
        }
    }

    private func finishDrag(start: CGFloat, end: CGFloat, width: CGFloat) {
        dragStart = nil
        dragCurrent = nil
        guard width > 0 else { return }
        func seconds(_ x: CGFloat) -> Double { min(max(Double(x / width), 0), 1) * duration }
        if abs(end - start) < 4 {
            model.seek(to: seconds(end))
        } else {
            let lower = seconds(min(start, end))
            let upper = seconds(max(start, end))
            // Dragging over a take with bars picks whole bars. Holding Option selects freely.
            if isActive, let grid = recording.grid, !NSEvent.modifierFlags.contains(.option) {
                model.setBarSelection(grid.snappedBars(from: lower, to: upper, duration: duration))
                model.loopSelectedBars()
            } else if upper - lower >= 0.05 {
                model.setLoop(lower...upper)
                model.seek(to: lower)
            }
        }
    }

    @ViewBuilder
    private func trimShade(width: CGFloat, height: CGFloat) -> some View {
        let start = CGFloat(recording.edit.trimStart / duration) * width
        let end = CGFloat((recording.edit.trimEnd ?? duration) / duration) * width
        Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(start, 0), height: height)
        Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(width - end, 0), height: height).offset(x: end)
    }

    @ViewBuilder
    private func loopOverlay(width: CGFloat, height: CGFloat) -> some View {
        if let dragStart, let dragCurrent, abs(dragCurrent - dragStart) >= 4 {
            let lower = max(min(dragStart, dragCurrent), 0)
            let upper = min(max(dragStart, dragCurrent), width)
            Rectangle().fill(Theme.loop).frame(width: upper - lower, height: height).offset(x: lower)
        } else if isActive, let loop = model.loopRange {
            let lower = CGFloat(loop.lowerBound / duration) * width
            let upper = CGFloat(loop.upperBound / duration) * width
            Rectangle().fill(Theme.loop)
                .frame(width: max(upper - lower, 1), height: height)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.loopEdge).frame(width: 1.5) }
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.loopEdge).frame(width: 1.5) }
                .overlay(alignment: .topLeading) {
                    Text("A").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.loopEdge).padding(2)
                }
                .overlay(alignment: .topTrailing) {
                    Text("B").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.loopEdge).padding(2)
                }
                .offset(x: lower)
                .allowsHitTesting(false)
        } else if isActive, let start = model.loopStart {
            Rectangle().fill(Theme.loopEdge).frame(width: 1.5, height: height)
                .offset(x: CGFloat(start / duration) * width)
                .allowsHitTesting(false)
        }
    }

    private func markerOverlay(width: CGFloat, height: CGFloat) -> some View {
        ForEach(recording.markers) { marker in
            let x = CGFloat(marker.time / duration) * width
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.marker)
                Rectangle().fill(Theme.marker.opacity(0.7)).frame(width: 1)
            }
            .frame(height: height, alignment: .top)
            .offset(x: x)
            .allowsHitTesting(false)
            .help(marker.label)
            .accessibilityHidden(true)
        }
    }
}

/// Bar lines with their numbers, and beat lines when there is room for them.
private struct BarGridOverlay: View, Equatable {
    let grid: BeatGrid
    let duration: Double

    var body: some View {
        Canvas { context, size in
            guard duration > 0, size.width > 0 else { return }
            let pointsPerSecond = size.width / duration
            let barWidth = grid.secondsPerBar * pointsPerSecond
            let last = grid.lastBar(duration: duration)
            let beatWidth = grid.secondsPerBeat * pointsPerSecond
            let lineEvery = max(Int((3 / barWidth).rounded(.up)), 1)
            let labelEvery = max(Int((24 / barWidth).rounded(.up)), 1)
            var bars = Path()
            var beats = Path()
            var labels: [(bar: Int, x: Double)] = []
            var bar = grid.firstBar
            while bar <= last {
                let index = bar - grid.firstBar
                let x = grid.time(ofBar: bar) * pointsPerSecond
                if index % lineEvery == 0 {
                    bars.addRect(CGRect(x: x, y: 0, width: 1, height: size.height))
                }
                if beatWidth >= 10 {
                    for beat in 1..<grid.beatsPerBar {
                        beats.addRect(CGRect(x: x + Double(beat) * beatWidth, y: 0, width: 1, height: size.height))
                    }
                }
                if index % labelEvery == 0 { labels.append((bar, x)) }
                bar += 1
            }
            context.fill(beats, with: .color(Theme.gridBeat))
            context.fill(bars, with: .color(Theme.gridBar))
            for label in labels {
                BarLabel.draw(label.bar, at: label.x, height: size.height, fontSize: 9, in: context)
            }
        }
    }
}

/// A bar number on its own background, so it stays readable over a loud waveform.
private enum BarLabel {
    static func draw(_ bar: Int, at x: Double, height: Double, fontSize: CGFloat, in context: GraphicsContext) {
        let text = context.resolve(Text("\(bar)")
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundColor(Theme.gridText))
        let measured = text.measure(in: CGSize(width: 80, height: 30))
        let rect = CGRect(x: x + 2, y: height - measured.height - 3, width: measured.width + 5, height: measured.height + 1)
        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Theme.waveBackground.opacity(0.88)))
        context.draw(text, at: CGPoint(x: rect.minX + 2.5, y: rect.minY + 0.5), anchor: .topLeading)
    }
}

private struct PlayheadLine: View {
    @EnvironmentObject private var playhead: PlayheadState
    let duration: Double

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.primary)
                .frame(width: 1.5, height: geometry.size.height)
                .offset(x: min(CGFloat(playhead.position / duration), 1) * geometry.size.width)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The recording in progress. The newest audio stays visible on the right.
private struct LiveWaveView: View {
    @EnvironmentObject private var live: LiveWave
    private let binsPerPoint = 4

    var body: some View {
        Canvas { context, size in
            let columns = Int(size.width)
            let middle = size.height / 2
            let needed = columns * binsPerPoint * 2
            let pairs = live.pairs.suffix(needed)
            var peak: Float = 0
            for sample in pairs { peak = max(peak, abs(sample)) }
            let scale = CGFloat(WaveformData.displayScale(peak: peak)) * middle * 0.96
            var path = Path()
            let base = pairs.startIndex
            let bins = pairs.count / 2
            let startX = CGFloat(columns) - CGFloat(bins / binsPerPoint)
            var bin = 0
            while bin < bins {
                var low: Float = 1
                var high: Float = -1
                for offset in 0..<min(binsPerPoint, bins - bin) {
                    low = min(low, pairs[base + (bin + offset) * 2])
                    high = max(high, pairs[base + (bin + offset) * 2 + 1])
                }
                let top = middle - CGFloat(high) * scale
                let bottom = middle - CGFloat(low) * scale
                path.addRect(CGRect(x: startX + CGFloat(bin / binsPerPoint), y: top, width: 1, height: max(bottom - top, 0.5)))
                bin += binsPerPoint
            }
            context.fill(path, with: .color(Theme.record))
            // Above the audio, so a loud signal cannot hide the bars.
            drawGrid(in: context, size: size)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.waveBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.record.opacity(0.7), lineWidth: 1.5))
        .overlay(alignment: .topLeading) { LiveBarDisplay() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wellenform der laufenden Aufnahme")
    }

    /// The bars move along with the audio, with the present at the right edge.
    private func drawGrid(in context: GraphicsContext, size: CGSize) {
        guard let grid = live.grid, live.secondsPerBin > 0, size.width > 0 else { return }
        let pointsPerSecond = 1 / (live.secondsPerBin * Double(binsPerPoint))
        let now = Double(live.pairs.count / 2) * live.secondsPerBin
        let earliest = now - Double(size.width) / pointsPerSecond
        var bar = max(grid.position(at: max(earliest, grid.offset))?.bar ?? grid.firstBar, grid.firstBar)
        let barWidth = grid.secondsPerBar * pointsPerSecond
        let beatWidth = grid.secondsPerBeat * pointsPerSecond
        let labelEvery = max(Int((24 / barWidth).rounded(.up)), 1)
        var bars = Path()
        var beats = Path()
        var labels: [(bar: Int, x: Double)] = []
        while grid.time(ofBar: bar) <= now {
            let x = Double(size.width) - (now - grid.time(ofBar: bar)) * pointsPerSecond
            bars.addRect(CGRect(x: x, y: 0, width: 1, height: size.height))
            if beatWidth >= 10 {
                for beat in 1..<grid.beatsPerBar {
                    beats.addRect(CGRect(x: x + Double(beat) * beatWidth, y: 0, width: 1, height: size.height))
                }
            }
            if (bar - grid.firstBar) % labelEvery == 0 { labels.append((bar, x)) }
            bar += 1
        }
        context.fill(beats, with: .color(Theme.gridBeat))
        context.fill(bars, with: .color(Theme.gridBar))
        for label in labels {
            BarLabel.draw(label.bar, at: label.x, height: size.height, fontSize: 11, in: context)
        }
    }
}

/// Says where the recording is right now, large enough to read from the instrument.
private struct LiveBarDisplay: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var meter: MeterState

    var body: some View {
        if let grid = model.activeGrid {
            let position = grid.position(at: meter.seconds)
            HStack(spacing: 10) {
                Text(position.map { "Takt \($0.bar)" } ?? "Gleich")
                    .font(.system(size: 22, weight: .heavy, design: .monospaced).monospacedDigit())
                HStack(spacing: 4) {
                    ForEach(1...grid.beatsPerBar, id: \.self) { beat in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(beat == position?.beat ? (beat == 1 ? Theme.record : Theme.meterAmber) : Color.secondary.opacity(0.3))
                            .frame(width: grid.beatsPerBar > 7 ? 10 : 16, height: 16)
                    }
                }
                if let bars = model.activePunchBars {
                    Text("Neu: \(AppModel.barsText(bars))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.82)))
            .padding(6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position in der Aufnahme")
            .accessibilityValue(position.map { "Takt \($0.bar), Schlag \($0.beat)" } ?? "Vor dem ersten Takt")
        }
    }
}

private struct CompareStack: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(model.compareIDs.enumerated()), id: \.element) { index, id in
                if let recording = model.recordings.first(where: { $0.id == id }) {
                    HStack(spacing: 8) {
                        Button(index == 0 ? "A" : "B") {
                            if model.compareActive != index { model.switchCompare() }
                        }
                        .buttonStyle(DeckKeyStyle(isOn: model.compareActive == index))
                        .help("Zu diesem Take wechseln (Taste B)")
                        .accessibilityLabel("Take \(index == 0 ? "A" : "B"): \(recording.name)")

                        if let waveform = model.compareWaveforms[id] {
                            WaveformEditor(recording: recording, waveform: waveform, isActive: model.compareActive == index)
                                .opacity(model.compareActive == index ? 1 : 0.5)
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(Theme.waveBackground)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Button {
                                model.toggleBestTake(id)
                            } label: {
                                Label(model.isBestTake(recording) ? "Bester Take" : "Als besten markieren",
                                      systemImage: model.isBestTake(recording) ? "crown.fill" : "crown")
                            }
                            .controlSize(.small)
                        }
                        .frame(width: 150, alignment: .leading)
                    }
                    .frame(height: 74)
                }
            }
        }
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playhead: PlayheadState

    var body: some View {
        HStack(spacing: 8) {
            Button(action: model.togglePlay) {
                Label(playhead.isPlaying ? "Pause" : "Abspielen", systemImage: playhead.isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 84)
            }
            .buttonStyle(DeckKeyStyle(isOn: playhead.isPlaying))
            .disabled(model.recordings.isEmpty)
            .help("Abspielen oder anhalten (Leertaste)")

            Text("\(TimeText.clock(playhead.position, tenths: true)) / \(TimeText.clock(model.current?.duration ?? 0))")
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .lineLimit(1)
                .accessibilityLabel("Position")
                .accessibilityValue("\(TimeText.spoken(playhead.position)) von \(TimeText.spoken(model.current?.duration ?? 0))")

            Button(action: model.toggleLoop) {
                Label(loopTitle, systemImage: "repeat")
            }
            .buttonStyle(DeckKeyStyle(isOn: model.loopRange != nil))
            .disabled(model.current == nil)
            .help("Taste L: erster Druck setzt A, zweiter setzt B, dritter löscht. Oder in der Wellenform ziehen.")

            Button(action: model.addMarker) {
                Label("Marker", systemImage: "flag")
            }
            .buttonStyle(DeckKeyStyle())
            .disabled(model.current == nil && !model.isRecording)
            .help("Marker an der aktuellen Stelle setzen (M), auch während der Aufnahme")

            Divider().frame(height: 20)

            TempoControls()

            Spacer(minLength: 6)

            if !model.compareIDs.isEmpty {
                Button("Vergleich beenden", action: model.clearCompare)
                    .buttonStyle(DeckKeyStyle())
            } else if model.canCompare {
                Button("Vergleichen", action: model.startCompare)
                    .buttonStyle(DeckKeyStyle())
                    .help("Die zwei markierten Takes direkt vergleichen")
            } else if let recording = model.current, recording.status == .open, !model.isRecording {
                ReviewButtons(recording: recording)
            }
        }
    }

    private var loopTitle: String {
        if let loop = model.loopRange {
            return "\(TimeText.clock(loop.lowerBound)) – \(TimeText.clock(loop.upperBound))"
        }
        return model.loopStart != nil ? "A gesetzt" : "Schleife"
    }
}

/// For a take with bars: where the playhead is, which bars are chosen, and what to do with them.
private struct BarControls: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playhead: PlayheadState
    let recording: Recording
    let grid: BeatGrid

    private var last: Int { recording.lastBar ?? grid.firstBar }
    private var bars: ClosedRange<Int> { model.barSelection ?? grid.firstBar...grid.firstBar }

    var body: some View {
        HStack(spacing: 8) {
            let position = grid.position(at: playhead.position)
            Text(position.map { "Takt \($0.bar) · Schlag \($0.beat)" } ?? "Vor Takt \(grid.firstBar)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced).monospacedDigit())
                .lineLimit(1)
                .frame(minWidth: 134, alignment: .leading)
                .accessibilityLabel("Position")

            Divider().frame(height: 20)

            PanelLabel("Takte")
            Stepper(value: Binding(get: { bars.lowerBound }, set: { model.setBarSelection($0...max($0, bars.upperBound)) }),
                    in: grid.firstBar...max(last, grid.firstBar)) {
                Text("\(bars.lowerBound)").font(.system(size: 12, design: .monospaced).monospacedDigit()).frame(minWidth: 24, alignment: .trailing)
            }
            .controlSize(.small)
            .accessibilityLabel("Erster Takt")
            .accessibilityValue("\(bars.lowerBound)")
            PanelLabel("bis")
            Stepper(value: Binding(get: { bars.upperBound }, set: { model.setBarSelection(min(bars.lowerBound, $0)...$0) }),
                    in: grid.firstBar...max(last, grid.firstBar)) {
                Text("\(bars.upperBound)").font(.system(size: 12, design: .monospaced).monospacedDigit()).frame(minWidth: 24, alignment: .trailing)
            }
            .controlSize(.small)
            .accessibilityLabel("Letzter Takt")
            .accessibilityValue("\(bars.upperBound)")
            Text("von \(last)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)

            Button(action: model.toggleBarLoop) {
                Label(model.isLoopingBars ? "Loop aus" : "Takte loopen", systemImage: "repeat")
            }
            .buttonStyle(DeckKeyStyle(isOn: model.isLoopingBars))
            .help("Spielt die gewählten Takte in Schleife. In der Wellenform ziehen wählt ganze Takte, mit ⌥ frei.")

            Button(action: model.recordSelectedBars) {
                Label("Takte neu aufnehmen", systemImage: "record.circle")
            }
            .buttonStyle(DeckKeyStyle())
            .disabled(!model.canRecordBars)
            .help("Zählt ein und nimmt die gewählten Takte im Tempo dieser Aufnahme neu auf. Das wird eine eigene Aufnahme, das Original bleibt unverändert.")

            Spacer(minLength: 0)
        }
    }
}

private struct TempoControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            PanelLabel("Tempo")
            Slider(value: Binding(get: { model.tempo }, set: { model.setTempo($0) }), in: PlaybackEngine.tempoRange, step: 0.05)
                .controlSize(.small)
                .frame(minWidth: 60, maxWidth: 110)
                .accessibilityLabel("Tempo")
                .accessibilityValue("\(Int(model.tempo * 100)) Prozent")
            Text("\(Int((model.tempo * 100).rounded())) %")
                .font(.system(size: 11, design: .monospaced).monospacedDigit())
                .frame(width: 40, alignment: .trailing)
                .accessibilityHidden(true)
            PanelLabel("Ton")
            Stepper(value: Binding(get: { model.pitch }, set: { model.setPitch($0) }), in: PlaybackEngine.pitchRange, step: 1) {
                Text(pitchText)
                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                    .frame(width: 26, alignment: .trailing)
            }
            .controlSize(.small)
            .accessibilityLabel("Tonhöhe")
            .accessibilityValue("\(Int(model.pitch)) Halbtöne")
            if model.tempo != 1 || model.pitch != 0 {
                Button(action: model.resetTempoAndPitch) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .help("Tempo und Tonhöhe zurücksetzen (0)")
                .accessibilityLabel("Tempo und Tonhöhe zurücksetzen")
            }
        }
    }

    private var pitchText: String {
        let value = Int(model.pitch)
        return value > 0 ? "+\(value)" : "\(value)"
    }
}

private struct ReviewButtons: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.keep(recording.id)
            } label: {
                Label("Behalten", systemImage: "checkmark")
            }
            .buttonStyle(DeckKeyStyle())
            .help("Take behalten (K)")

            Button {
                model.discard([recording.id])
            } label: {
                Label("Verwerfen", systemImage: "trash")
            }
            .buttonStyle(DeckKeyStyle())
            .help("In den Papierkorb legen (⌘⌫). Lässt sich mit ⌘Z rückgängig machen.")

            Button(action: model.toggleRecord) {
                Label("Nochmal", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(DeckKeyStyle())
            .help("Neu aufnehmen (R). Dieser Take bleibt als „Offen“ erhalten.")
        }
    }
}

// MARK: - Banner

struct BannerView: View {
    @EnvironmentObject private var model: AppModel
    let banner: Banner

    private var icon: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .info: return .accentColor
        case .warning: return Theme.meterAmber
        case .error: return Theme.meterRed
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
            Text(banner.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if banner.canUndo {
                Button("Rückgängig", action: model.undoLastDiscard).controlSize(.small)
            }
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Meldung schließen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.5)))
    }
}
