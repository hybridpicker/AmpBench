import SparkCore
import SparkDesign
import SwiftUI

/// The middle panel: the take in focus, its waveform, the transport and the decision keys.
struct WavePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if !model.compareIDs.isEmpty {
                    CompareStack()
                } else if model.isRecording {
                    LiveWaveView().frame(height: 132)
                } else {
                    singleWave.frame(height: 132)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .background(Theme.desk.waveBackground)
            Faceplate(top: Theme.device.faceTop, bottom: Swatch(hex: 0x1C1C1F)) {
                VStack(spacing: 0) {
                    TransportBar()
                        .frame(height: 48)
                    if !model.isRecording, model.compareIDs.isEmpty, let recording = model.current, let grid = recording.grid,
                       recording.health == .ok {
                        EngravedDivider(.horizontal, inset: 16)
                        BarControls(recording: recording, grid: grid)
                            .frame(height: 40)
                    }
                }
                .padding(.horizontal, 16)
            }
            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
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
            .fill(Theme.desk.waveBackground.color)
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
            context.fill(path, with: .color(Theme.desk.wave.color))
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
        VStack(spacing: 0) {
            Ruler(marks: Ruler.marks(grid: recording.grid, duration: duration))
                .frame(height: Ruler.height)
            GeometryReader { geometry in
                waveform(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private func waveform(width: CGFloat, height: CGFloat) -> some View {
        Group {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.desk.waveBackground.color)
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
                trimShade(width: width, height: height)
                loopOverlay(width: width, height: height)
                markerOverlay(width: width, height: height)
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
            Rectangle().fill(Theme.desk.loopFill.color).frame(width: upper - lower, height: height).offset(x: lower)
        } else if isActive, let loop = model.loopRange {
            let lower = CGFloat(loop.lowerBound / duration) * width
            let upper = CGFloat(loop.upperBound / duration) * width
            Rectangle().fill(Theme.desk.loopFill)
                .frame(width: max(upper - lower, 1), height: height)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.desk.loopEdge).frame(width: 2) }
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.desk.loopEdge).frame(width: 2) }
                .overlay(alignment: .topLeading) { LoopHandle(letter: "A") }
                .overlay(alignment: .topTrailing) { LoopHandle(letter: "B") }
                .offset(x: lower)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else if isActive, let start = model.loopStart {
            Rectangle().fill(Theme.desk.loopEdge).frame(width: 2, height: height)
                .overlay(alignment: .topLeading) { LoopHandle(letter: "A").fixedSize().offset(x: 0) }
                .offset(x: CGFloat(start / duration) * width)
                .allowsHitTesting(false)
        }
    }

    private func markerOverlay(width: CGFloat, height: CGFloat) -> some View {
        ForEach(recording.markers) { marker in
            let x = CGFloat(marker.time / duration) * width
            Rectangle().fill(Theme.desk.marker).frame(width: 1.5, height: height)
                .overlay(alignment: .topLeading) {
                    Text(marker.label)
                        .font(Theme.Fonts.mono(9.5, weight: .bold))
                        .foregroundStyle(Theme.desk.marker)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 2).fill(Theme.desk.waveBackground.opacity(0.85)))
                        .offset(x: 3, y: 2)
                }
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
            var bars = Path()
            var beats = Path()
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
                bar += 1
            }
            context.fill(beats, with: .color(Theme.desk.gridBeat.color))
            context.fill(bars, with: .color(Theme.desk.gridBar.color))
        }
    }
}

/// The ruler above a waveform: bar numbers for a take with bars, otherwise seconds. It is the same above a take, in
/// the comparison and above a recording in progress.
struct Ruler: View {
    struct Mark {
        var x: Double
        var label: String?
    }

    static let height: CGFloat = 16
    /// The marks for a width, in points from the left.
    let marks: (CGFloat) -> [Mark]

    var body: some View {
        Canvas { context, size in
            var ticks = Path()
            for mark in marks(size.width) {
                ticks.addRect(CGRect(x: mark.x, y: size.height - 4, width: 1, height: 4))
                guard let label = mark.label else { continue }
                let text = context.resolve(Text(label).font(Theme.Fonts.mono(9.5, weight: .semibold)).foregroundStyle(.secondary))
                context.draw(text, at: CGPoint(x: mark.x + 3, y: size.height / 2 - 1), anchor: .leading)
            }
            context.fill(ticks, with: .style(.tertiary))
        }
        .accessibilityHidden(true)
    }

    /// Bar numbers when there are bars, otherwise seconds, spaced so labels never collide.
    static func marks(grid: BeatGrid?, duration: Double) -> (CGFloat) -> [Mark] {
        { width in
            guard duration > 0, width > 0 else { return [] }
            let pointsPerSecond = Double(width) / duration
            if let grid {
                let barWidth = grid.secondsPerBar * pointsPerSecond
                let labelEvery = max(Int((28 / barWidth).rounded(.up)), 1)
                let lineEvery = max(Int((4 / barWidth).rounded(.up)), 1)
                var marks: [Mark] = []
                var bar = grid.firstBar
                while bar <= grid.lastBar(duration: duration) {
                    let index = bar - grid.firstBar
                    if index % lineEvery == 0 {
                        marks.append(Mark(x: grid.time(ofBar: bar) * pointsPerSecond,
                                          label: index % labelEvery == 0 ? "\(bar)" : nil))
                    }
                    bar += 1
                }
                return marks
            }
            let step = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { $0 * pointsPerSecond >= 44 } ?? 1200
            return stride(from: 0, through: duration, by: step).map {
                Mark(x: $0 * pointsPerSecond, label: TimeText.clock($0))
            }
        }
    }
}

/// A handle of the loop, A or B, at the top of its edge.
private struct LoopHandle: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(Theme.desk.loopHandleText)
            .frame(width: 16, height: 14)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.desk.loopEdge))
    }
}

private struct PlayheadLine: View {
    @EnvironmentObject private var playhead: PlayheadState
    let duration: Double

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Theme.desk.playhead)
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
        VStack(spacing: 0) {
            Ruler(marks: rulerMarks)
                .frame(height: Ruler.height)
            wave
        }
    }

    private var pointsPerSecond: Double { 1 / (live.secondsPerBin * Double(binsPerPoint)) }
    private var now: Double { Double(live.pairs.count / 2) * live.secondsPerBin }

    /// Bars, or seconds without a click, moving along with the audio.
    private func rulerMarks(_ width: CGFloat) -> [Ruler.Mark] {
        guard live.secondsPerBin > 0, width > 0 else { return [] }
        let earliest = now - Double(width) / pointsPerSecond
        func x(_ time: Double) -> Double { Double(width) - (now - time) * pointsPerSecond }
        if let grid = live.grid {
            let labelEvery = max(Int((28 / (grid.secondsPerBar * pointsPerSecond)).rounded(.up)), 1)
            var bar = max(grid.position(at: max(earliest, grid.offset))?.bar ?? grid.firstBar, grid.firstBar)
            var marks: [Ruler.Mark] = []
            while grid.time(ofBar: bar) <= now {
                marks.append(Ruler.Mark(x: x(grid.time(ofBar: bar)),
                                        label: (bar - grid.firstBar) % labelEvery == 0 ? "\(bar)" : nil))
                bar += 1
            }
            return marks
        }
        let step = [1.0, 2, 5, 10, 15, 30, 60].first { $0 * pointsPerSecond >= 44 } ?? 120
        var time = max((earliest / step).rounded(.up) * step, 0)
        var marks: [Ruler.Mark] = []
        while time <= now {
            marks.append(Ruler.Mark(x: x(time), label: TimeText.clock(time)))
            time += step
        }
        return marks
    }

    private var wave: some View {
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
            context.fill(path, with: .color(Theme.device.record.color))
            // Above the audio, so a loud signal cannot hide the bars.
            drawGrid(in: context, size: size)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.desk.waveBackground.color))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.device.record.color.opacity(0.7), lineWidth: 1.5))
        .overlay(alignment: .topLeading) { LiveBarDisplay() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wellenform der laufenden Aufnahme")
    }

    /// The bars move along with the audio, with the present at the right edge.
    private func drawGrid(in context: GraphicsContext, size: CGSize) {
        guard let grid = live.grid, live.secondsPerBin > 0, size.width > 0 else { return }
        let earliest = now - Double(size.width) / pointsPerSecond
        var bar = max(grid.position(at: max(earliest, grid.offset))?.bar ?? grid.firstBar, grid.firstBar)
        let beatWidth = grid.secondsPerBeat * pointsPerSecond
        var bars = Path()
        var beats = Path()
        while grid.time(ofBar: bar) <= now {
            let x = Double(size.width) - (now - grid.time(ofBar: bar)) * pointsPerSecond
            bars.addRect(CGRect(x: x, y: 0, width: 1, height: size.height))
            if beatWidth >= 10 {
                for beat in 1..<grid.beatsPerBar {
                    beats.addRect(CGRect(x: x + Double(beat) * beatWidth, y: 0, width: 1, height: size.height))
                }
            }
            bar += 1
        }
        context.fill(beats, with: .color(Theme.desk.gridBeat.color))
        context.fill(bars, with: .color(Theme.desk.gridBar.color))
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
                            .fill(beat == position?.beat ? (beat == 1 ? Theme.device.record.color : Theme.device.meterAmber.color) : Color.secondary.opacity(0.3))
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
                        .buttonStyle(.hardwareKey(model.compareActive == index ? .on : .normal, keycap: "B"))
                        .help("Zu diesem Take wechseln (Taste B)")
                        .accessibilityLabel("Take \(index == 0 ? "A" : "B"): \(recording.name)")

                        if let waveform = model.compareWaveforms[id] {
                            WaveformEditor(recording: recording, waveform: waveform, isActive: model.compareActive == index)
                                .opacity(model.compareActive == index ? 1 : 0.5)
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(Theme.desk.waveBackground.color)
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
                    .frame(minWidth: 74)
            }
            .buttonStyle(.hardwareKey(playhead.isPlaying ? .on : .normal, keycap: "␣"))
            .fixedSize()
            .disabled(model.recordings.isEmpty)
            .help("Abspielen oder anhalten (Leertaste)")

            (Text(TimeText.clock(playhead.position, tenths: true)).foregroundColor(Theme.device.amber.color)
             + Text(" / \(TimeText.clock(model.current?.duration ?? 0))").foregroundColor(Theme.device.amberDim.color))
                .font(Theme.Fonts.mono(12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
                .accessibilityLabel("Position")
                .accessibilityValue("\(TimeText.spoken(playhead.position)) von \(TimeText.spoken(model.current?.duration ?? 0))")

            Button(loopTitle, action: model.toggleLoop)
                .buttonStyle(.hardwareKey(model.loopRange != nil ? .on : .normal, keycap: "L"))
                .fixedSize()
                .disabled(model.current == nil)
                .help("Taste L: erster Druck setzt A, zweiter setzt B, dritter löscht. Oder in der Wellenform ziehen.")

            Button("Marker", action: model.addMarker)
                .buttonStyle(.hardwareKey(keycap: "M"))
                .fixedSize()
                .disabled(model.current == nil && !model.isRecording)
                .help("Marker an der aktuellen Stelle setzen (M), auch während der Aufnahme")

            EngravedDivider().frame(height: 22).padding(.horizontal, 2)

            TempoControls()

            Spacer(minLength: 6)

            if !model.compareIDs.isEmpty {
                Button("Vergleich beenden", action: model.clearCompare)
                    .buttonStyle(.hardwareKey())
                    .fixedSize()
            } else if model.canCompare {
                Button("Vergleichen", action: model.startCompare)
                    .buttonStyle(.hardwareKey())
                    .fixedSize()
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
                .font(Theme.Fonts.mono(12, weight: .semibold))
                .foregroundStyle(Theme.device.amber)
                .lineLimit(1)
                .frame(minWidth: 134, alignment: .leading)
                .accessibilityLabel("Position")

            EngravedDivider().frame(height: 20).padding(.horizontal, 2)

            PanelLabel("Takte")
            DisplayStepper("Erster Takt",
                           value: Binding(get: { Double(bars.lowerBound) },
                                          set: { model.setBarSelection(Int($0)...max(Int($0), bars.upperBound)) }),
                           in: Double(grid.firstBar)...Double(max(last, grid.firstBar)), step: 1,
                           text: "\(bars.lowerBound)", size: 12)
            PanelLabel("bis")
            DisplayStepper("Letzter Takt",
                           value: Binding(get: { Double(bars.upperBound) },
                                          set: { model.setBarSelection(min(bars.lowerBound, Int($0))...Int($0)) }),
                           in: Double(grid.firstBar)...Double(max(last, grid.firstBar)), step: 1,
                           text: "\(bars.upperBound)", size: 12)
            Text("von \(last)")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.device.labelDim)
                .lineLimit(1)
                .fixedSize()

            Button(model.isLoopingBars ? "Loop aus" : "Takte loopen", action: model.toggleBarLoop)
                .buttonStyle(.hardwareKey(model.isLoopingBars ? .on : .normal, size: .small))
                .fixedSize()
                .help("Spielt die gewählten Takte in Schleife. In der Wellenform ziehen wählt ganze Takte, mit ⌥ frei.")

            Button("Takte neu aufnehmen", action: model.recordSelectedBars)
                .buttonStyle(.hardwareKey(size: .small))
                .fixedSize()
                .disabled(!model.canRecordBars)
                .help("Zählt ein und nimmt die gewählten Takte im Tempo dieser Aufnahme neu auf. Das wird eine eigene Aufnahme, das Original bleibt unverändert.")

            Spacer(minLength: 0)
        }
    }
}

private struct TempoControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            PanelLabel("Tempo")
            DeviceSlider("Tempo", value: Binding(get: { model.tempo }, set: { model.setTempo($0) }),
                         in: PlaybackEngine.tempoRange, step: 0.05,
                         valueText: "\(Int((model.tempo * 100).rounded())) Prozent")
                .frame(minWidth: 56, maxWidth: 110)
            Text("\(Int((model.tempo * 100).rounded())) %")
                .font(Theme.Fonts.mono(11.5))
                .foregroundStyle(Theme.device.label)
                .frame(width: 38, alignment: .leading)
                .accessibilityHidden(true)
            PanelLabel("Ton")
            DisplayStepper("Tonhöhe", value: Binding(get: { model.pitch }, set: { model.setPitch($0) }),
                           in: PlaybackEngine.pitchRange, step: 1, text: pitchText, size: 11.5,
                           spokenValue: "\(Int(model.pitch)) Halbtöne")
            if model.tempo != 1 || model.pitch != 0 {
                Button {
                    model.resetTempoAndPitch()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.hardwareKey(keycap: "0", size: .small))
                .fixedSize()
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

/// The decision about an open take: keep it, throw it away, or play it again.
private struct ReviewButtons: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording

    var body: some View {
        HStack(spacing: 8) {
            Button("Behalten") { model.keep(recording.id) }
                .buttonStyle(.hardwareKey(.primary, keycap: "K"))
                .fixedSize()
                .help("Take behalten (K)")

            Button("Verwerfen") { model.discard([recording.id]) }
                .buttonStyle(.hardwareKey(.danger, keycap: "⌫"))
                .fixedSize()
                .help("In den Papierkorb legen (⌘⌫). Lässt sich mit ⌘Z rückgängig machen.")

            Button("Nochmal", action: model.toggleRecord)
                .buttonStyle(.hardwareKey(keycap: "R"))
                .fixedSize()
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
        case .warning: return Theme.device.meterAmber.color
        case .error: return Theme.device.meterRed.color
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
