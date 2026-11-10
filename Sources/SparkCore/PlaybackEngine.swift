import AmpText
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Plans which file frames play next. Pure logic, so looping and trimming can be tested without audio.
public struct PlaybackPlanner: Equatable, Sendable {
    public let start: Int64
    public let end: Int64
    public let looping: Bool
    public let chunkFrames: Int64
    public private(set) var cursor: Int64

    public struct Chunk: Equatable, Sendable {
        public let frame: Int64
        public let count: Int64
        /// The window ends here and nothing follows, because the planner does not loop.
        public let isLast: Bool
    }

    public init(start: Int64, end: Int64, looping: Bool, chunkFrames: Int64, cursor: Int64) {
        self.start = start
        self.end = max(start, end)
        self.looping = looping
        self.chunkFrames = max(chunkFrames, 1)
        self.cursor = min(max(cursor, start), self.end)
    }

    public mutating func next() -> Chunk? {
        guard end > start else { return nil }
        if cursor >= end {
            guard looping else { return nil }
            cursor = start
        }
        let count = min(chunkFrames, end - cursor)
        let chunk = Chunk(frame: cursor, count: count, isLast: !looping && cursor + count >= end)
        cursor += count
        return chunk
    }
}

/// Maps the player's rendered sample count back to a file position, also across loop jumps.
public struct PlaybackTimeline: Sendable {
    private struct Entry: Sendable {
        let playerStart: Int64
        let fileStart: Int64
        let count: Int64
    }

    private var entries: [Entry] = []
    private var scheduled: Int64 = 0

    public init() {}

    public mutating func append(fileStart: Int64, count: Int64) {
        entries.append(Entry(playerStart: scheduled, fileStart: fileStart, count: count))
        scheduled += count
        if entries.count > 64 { entries.removeFirst(entries.count - 64) }
    }

    public func fileFrame(atPlayerSample sample: Int64) -> Int64? {
        guard let first = entries.first else { return nil }
        if sample <= first.playerStart { return first.fileStart }
        for entry in entries.reversed() where sample >= entry.playerStart {
            return entry.fileStart + min(sample - entry.playerStart, entry.count)
        }
        return first.fileStart
    }
}

public enum PlaybackError: LocalizedError {
    case noFile
    case unsupportedFormat
    case device(OSStatus)
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .noFile: return tr("No take is loaded.")
        case .unsupportedFormat: return tr("This file format cannot be played.")
        case .device(let status): return tr("The output device could not be selected (error %d).", Int(status))
        case .engine(let text): return tr("Playback could not start: %@", text)
        }
    }
}

/// Plays one file through a chosen output with tempo, pitch, loop and edits.
///
/// Only the engine's output side is used. Its input node is never touched, because recording stays on its own AUHAL
/// unit and must not depend on this engine in any way. Audio is read in short chunks on a background queue, and all
/// edits are applied there, so the listening result matches an export sample for sample at neutral tempo and pitch.
public final class PlaybackEngine {
    public static let tempoRange = 0.5...1.5
    public static let pitchRange = -12.0...12.0
    private static let loopRampSeconds = 0.004
    private static let chunkSeconds = 0.25
    private static let queuedChunks = 4

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let queue = DispatchQueue(label: "local.sparkrecorder.playback", qos: .userInitiated)
    private let lock = NSLock()

    // Protected by `lock`, read from the main thread for the playhead.
    private var timeline = PlaybackTimeline()
    private var storedPosition: Int64 = 0
    private var playing = false
    private var generation = 0

    // Owned by `queue`.
    private var file: AVAudioFile?
    private var planner: PlaybackPlanner?
    private var queued = 0
    private var finishedPlanning = false
    private var format: AVAudioFormat?
    private var connectedFormat: AVAudioFormat?
    private var renderer: EditRenderer?
    private var loopRange: (start: Int64, end: Int64)?
    private var idleStop: DispatchWorkItem?
    private var clickGrid: BeatGrid?
    private var clickVolume: Float = 0

    public private(set) var sampleRate: Double = 0
    public private(set) var totalFrames: Int64 = 0
    public private(set) var loadedURL: URL?
    private var selectedOutput: AudioDeviceID?
    private var edit = EditList()
    private var loopSeconds: ClosedRange<Double>?

    /// Called on the main queue when the end of the window is reached.
    public var onFinished: (() -> Void)?
    /// Called on the main queue when the output disappeared or changed.
    public var onOutputChanged: (() -> Void)?

    private var configurationObserver: NSObjectProtocol?

    public init() {
        engine.attach(player)
        engine.attach(timePitch)
        timePitch.bypass = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                // Choosing a device also posts this. Only a stopped engine means the output really went away.
                guard !self.engine.isRunning else { return }
                let current = self.positionFrames
                self.haltPlayer()
                self.lock.lock()
                self.storedPosition = current
                self.lock.unlock()
                self.connectedFormat = nil
                DispatchQueue.main.async { self.onOutputChanged?() }
            }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine.stop()
    }

    public var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return playing
    }

    public var position: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(positionFrames) / sampleRate
    }

    private var positionFrames: Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard playing,
              let renderTime = player.lastRenderTime,
              renderTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: renderTime),
              let frame = timeline.fileFrame(atPlayerSample: playerTime.sampleTime) else {
            return storedPosition
        }
        return frame
    }

    // MARK: Loading

    /// Opens a file and prepares it. The previous one stops.
    public func load(url: URL, edit: EditList, startAt seconds: Double? = nil) throws {
        let newFile: AVAudioFile
        do {
            newFile = try AVAudioFile(forReading: url)
        } catch {
            throw PlaybackError.unsupportedFormat
        }
        let frames = newFile.length
        let rate = newFile.processingFormat.sampleRate
        queue.sync {
            haltPlayer()
            file = newFile
            format = newFile.processingFormat
            renderer = EditRenderer(edit: edit, sampleRate: rate, totalFrames: frames)
        }
        sampleRate = rate
        totalFrames = frames
        loadedURL = url
        self.edit = edit
        loopSeconds = nil
        let start = seconds.map { Int64($0 * rate) } ?? renderer(rate: rate, frames: frames).startFrame
        lock.lock()
        storedPosition = min(max(start, 0), frames)
        lock.unlock()
    }

    private func renderer(rate: Double, frames: Int64) -> EditRenderer {
        EditRenderer(edit: edit, sampleRate: rate, totalFrames: frames)
    }

    /// Releases the current file.
    public func unload() {
        queue.sync {
            haltPlayer()
            file = nil
            format = nil
            renderer = nil
        }
        sampleRate = 0
        totalFrames = 0
        loadedURL = nil
        loopSeconds = nil
        lock.lock()
        storedPosition = 0
        lock.unlock()
    }

    // MARK: Output device

    /// Nil follows the system's default output.
    public func setOutput(_ device: AudioDeviceID?) throws {
        selectedOutput = device
        var thrown: Error?
        queue.sync {
            haltPlayer()
            engine.stop()
            connectedFormat = nil
            do {
                try applyOutputDevice()
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
    }

    private func applyOutputDevice() throws {
        guard var device = selectedOutput ?? AudioDevices.defaultOutputDevice(),
              let unit = engine.outputNode.audioUnit else { return }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw PlaybackError.device(status) }
    }

    // MARK: Transport

    public func play(from seconds: Double? = nil) throws {
        guard sampleRate > 0 else { throw PlaybackError.noFile }
        let target = seconds.map { Int64($0 * sampleRate) } ?? positionFrames
        var thrown: Error?
        queue.sync {
            do {
                try startPlaying(at: target)
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
    }

    public func pause() {
        let current = positionFrames
        queue.sync {
            haltPlayer()
            lock.lock()
            storedPosition = current
            lock.unlock()
            scheduleIdleStop()
        }
    }

    /// Moves the playhead, keeping the current play state.
    public func seek(to seconds: Double) {
        guard sampleRate > 0 else { return }
        let target = min(max(Int64(seconds * sampleRate), 0), totalFrames)
        let wasPlaying = isPlaying
        queue.sync {
            haltPlayer()
            lock.lock()
            storedPosition = target
            lock.unlock()
            if wasPlaying { try? startPlaying(at: target) }
        }
    }

    public func setTempo(_ rate: Double, pitchSemitones: Double) {
        let clampedRate = min(max(rate, Self.tempoRange.lowerBound), Self.tempoRange.upperBound)
        let clampedPitch = min(max(pitchSemitones, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
        timePitch.rate = Float(clampedRate)
        timePitch.pitch = Float(clampedPitch * 100)
        // Neutral settings bypass the unit, so listening at normal speed stays untouched by its processing.
        timePitch.bypass = clampedRate == 1 && clampedPitch == 0
    }

    /// Nil plays the whole trimmed window.
    public func setLoop(_ range: ClosedRange<Double>?) {
        loopSeconds = range
        restartIfPlaying()
    }

    /// Mixes a click on the given grid into what plays, or none with nil. Nothing of it reaches a file or an export.
    /// A new volume arrives with the next chunks, while a new grid restarts the queued audio.
    public func setClick(_ grid: BeatGrid?, volume: Float) {
        let changed = queue.sync { () -> Bool in
            let changed = clickGrid != grid
            clickGrid = grid
            clickVolume = volume
            return changed
        }
        if changed { restartIfPlaying() }
    }

    public func setEdit(_ edit: EditList) {
        self.edit = edit
        guard sampleRate > 0 else { return }
        let rate = sampleRate
        let frames = totalFrames
        queue.sync { renderer = EditRenderer(edit: edit, sampleRate: rate, totalFrames: frames) }
        restartIfPlaying()
    }

    private func restartIfPlaying() {
        guard isPlaying else { return }
        let current = positionFrames
        queue.sync { try? startPlaying(at: current) }
    }

    // MARK: Queue-only

    private func ensureEngineRunning() throws {
        idleStop?.cancel()
        idleStop = nil
        guard let format else { throw PlaybackError.noFile }
        if connectedFormat != format {
            let wasRunning = engine.isRunning
            if wasRunning { engine.stop() }
            try applyOutputDevice()
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
            connectedFormat = format
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                throw PlaybackError.engine(error.localizedDescription)
            }
        }
    }

    /// Keeps the output open briefly for an instant restart, then releases the device.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.engine.stop()
        }
        idleStop = item
        queue.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func haltPlayer() {
        lock.lock()
        generation += 1
        playing = false
        lock.unlock()
        player.stop()
        planner = nil
        queued = 0
        finishedPlanning = false
    }

    private func startPlaying(at frame: Int64) throws {
        guard file != nil, let renderer else { throw PlaybackError.noFile }
        haltPlayer()
        try ensureEngineRunning()

        var start = renderer.startFrame
        var end = renderer.endFrame
        var looping = false
        if let loopSeconds, sampleRate > 0 {
            let loopStart = max(Int64(loopSeconds.lowerBound * sampleRate), start)
            let loopEnd = min(Int64(loopSeconds.upperBound * sampleRate), end)
            if loopEnd > loopStart {
                start = loopStart
                end = loopEnd
                looping = true
            }
        }
        loopRange = looping ? (start, end) : nil
        // A playhead at the end restarts from the beginning, so pressing play always plays something.
        var cursor = min(max(frame, start), end)
        if cursor >= end { cursor = start }
        planner = PlaybackPlanner(
            start: start, end: end, looping: looping,
            chunkFrames: Int64(Self.chunkSeconds * sampleRate), cursor: cursor)

        lock.lock()
        timeline = PlaybackTimeline()
        storedPosition = cursor
        let currentGeneration = generation
        lock.unlock()

        scheduleMore(generation: currentGeneration)

        lock.lock()
        playing = true
        lock.unlock()
        player.play()
    }

    private func scheduleMore(generation scheduled: Int) {
        guard let file, let format, let renderer else { return }
        while queued < Self.queuedChunks, !finishedPlanning {
            guard let chunk = planner?.next() else {
                finishedPlanning = true
                break
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)) else {
                finishedPlanning = true
                break
            }
            do {
                file.framePosition = chunk.frame
                try file.read(into: buffer, frameCount: AVAudioFrameCount(chunk.count))
            } catch {
                finishedPlanning = true
                break
            }
            guard buffer.frameLength > 0 else {
                finishedPlanning = true
                break
            }
            process(buffer, firstFrame: chunk.frame, renderer: renderer)

            lock.lock()
            timeline.append(fileStart: chunk.frame, count: Int64(buffer.frameLength))
            lock.unlock()
            queued += 1

            if chunk.isLast {
                finishedPlanning = true
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.finishIfCurrent(generation: scheduled) }
                }
            } else {
                player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        guard self.isCurrent(scheduled) else { return }
                        self.queued -= 1
                        self.scheduleMore(generation: scheduled)
                    }
                }
            }
        }
    }

    private func isCurrent(_ scheduled: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == scheduled
    }

    private func finishIfCurrent(generation scheduled: Int) {
        guard isCurrent(scheduled), let renderer else { return }
        haltPlayer()
        lock.lock()
        storedPosition = renderer.startFrame
        lock.unlock()
        scheduleIdleStop()
        DispatchQueue.main.async { [weak self] in self?.onFinished?() }
    }

    private func process(_ buffer: AVAudioPCMBuffer, firstFrame: Int64, renderer: EditRenderer) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            renderer.apply(to: channels[channel], count: count, firstFrame: firstFrame)
            if let loopRange {
                Self.applyLoopRamps(channels[channel], count: count, firstFrame: firstFrame, loop: loopRange,
                                    rampFrames: Int64(Self.loopRampSeconds * sampleRate))
            }
            // After the ramps, so a click right on the loop start is not faded away.
            if let clickGrid {
                PlaybackClick.mix(into: channels[channel], count: count, firstFrame: firstFrame, sampleRate: sampleRate,
                                  grid: clickGrid, volume: clickVolume)
            }
        }
    }

    /// Short ramps at the loop points, so the jump from B back to A does not click.
    private static func applyLoopRamps(_ samples: UnsafeMutablePointer<Float>, count: Int, firstFrame: Int64,
                                       loop: (start: Int64, end: Int64), rampFrames: Int64) {
        guard rampFrames > 0 else { return }
        let ramp = min(rampFrames, (loop.end - loop.start) / 2)
        guard ramp > 0 else { return }
        for index in 0..<count {
            let frame = firstFrame + Int64(index)
            if frame < loop.start + ramp {
                samples[index] *= Float(frame - loop.start) / Float(ramp)
            } else if frame >= loop.end - ramp {
                samples[index] *= Float(loop.end - 1 - frame) / Float(ramp)
            }
        }
    }
}
