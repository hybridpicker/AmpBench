import AmpText
import AVFoundation
import Foundation

/// How long a beat takes from the click output until it shows up in the file, if someone plays exactly on it.
///
/// Core Audio stamps output audio when it reaches the output driver and input audio when it leaves the input
/// driver. Between those, the sound spends the output's latency in the output device and, once played, the input's
/// latency in the input device. Both devices report these, but an amp also delays the guitar inside, in its
/// converters and effects, without reporting it. `correction` holds that rest, measured with a cable or set by hand.
public struct ClickLatency: Codable, Equatable, Sendable {
    public var output: Double
    public var input: Double
    public var correction: Double

    public init(output: Double = 0, input: Double = 0, correction: Double = 0) {
        self.output = output
        self.input = input
        self.correction = correction
    }

    public var reported: Double { output + input }
    public var total: Double { reported + correction }
}

/// Where the bars of a recording lie, from the input frames the click and the file are placed on.
public enum ClickTiming {
    public static func beatInterval(bpm: Double, inputRate: Double) -> Double {
        inputRate * 60 / bpm
    }

    /// The input frame of the beat that starts bar 1, at the click: `beatsBefore` counts the count-in.
    public static func downbeatFrame(anchorFrame: Double, beatsBefore: Int, bpm: Double, inputRate: Double) -> Double {
        anchorFrame + Double(beatsBefore) * beatInterval(bpm: bpm, inputRate: inputRate)
    }

    /// Where bar 1 lies in the file, in seconds: the place where a note played exactly on its click ends up.
    public static func gridOffset(anchorFrame: Double, beatsBefore: Int, bpm: Double, inputRate: Double,
                                  fileFirstFrame: Int64, latency: ClickLatency) -> Double {
        let downbeat = downbeatFrame(anchorFrame: anchorFrame, beatsBefore: beatsBefore, bpm: bpm, inputRate: inputRate)
        return (downbeat - Double(fileFirstFrame)) / inputRate + latency.total
    }

    /// The input frame where a recording after a count-in starts: `preRoll` seconds before bar 1 at the click.
    public static func gateFrame(anchorFrame: Double, beatsBefore: Int, bpm: Double, inputRate: Double,
                                 preRoll: Double) -> Int64 {
        let downbeat = downbeatFrame(anchorFrame: anchorFrame, beatsBefore: beatsBefore, bpm: bpm, inputRate: inputRate)
        return Int64((downbeat - preRoll * inputRate).rounded())
    }
}

public enum LatencyProbeError: LocalizedError, Equatable {
    case clickDidNotStart
    case noSignal
    case unstable(spreadMilliseconds: Double)

    public var errorDescription: String? {
        switch self {
        case .clickDidNotStart:
            return tr("The click did not start.")
        case .noSignal:
            return tr("No click arrived at the input. Is the cable in the guitar input, or do the headphones lie directly on the pickup? Is the output loud enough?")
        case .unstable(let spread):
            return tr("The clicks arrived unevenly (spread %.1f ms). Choose a preset without delay, reverb and noise gate on the amp and measure again.", spread)
        }
    }
}

/// Measures the real delay from the click output to the file, the way a DAW does with a loopback cable.
///
/// The click plays into the input, here through a cable from the click output into the amp's guitar input. Because
/// that is exactly the way a played note takes, the measured delay is what the bars of a recording need.
public enum LatencyProbe {
    public struct Result: Equatable, Sendable {
        /// Seconds from the click's input frame to its arrival in the file.
        public let measured: Double
        /// What the devices report for the same way.
        public let reported: Double
        /// Largest difference between single clicks, in seconds.
        public let spread: Double
        public let detected: Int
        public let played: Int

        /// The part the devices do not report.
        public var correction: Double { measured - reported }
    }

    public struct Analysis: Equatable, Sendable {
        /// Frames from each expected beat to its onset, for the beats that were found.
        public let lags: [Double]
        public let played: Int
    }

    public static let maximumLatency = 0.35
    private static let earlyTolerance = 0.002
    private static let stableSpread = 0.002

    /// Finds the onset of each click in the recorded samples. `expected` are file frames where the clicks would be
    /// without any delay.
    public static func analyze(samples: [Float], sampleRate: Double, expected: [Double]) -> Analysis {
        guard let first = expected.first, sampleRate > 0 else { return Analysis(lags: [], played: expected.count) }
        let early = Int(earlyTolerance * sampleRate)
        let quietEnd = min(max(Int(first) - early, 0), samples.count)
        let noise = samples[0..<quietEnd].reduce(Float(0)) { max($0, abs($1)) }

        var lags: [Double] = []
        for (index, beat) in expected.enumerated() {
            let lower = max(Int(beat.rounded(.down)) - early, 0)
            var upper = Int(beat + maximumLatency * sampleRate)
            if index + 1 < expected.count { upper = min(upper, Int(expected[index + 1]) - early) }
            upper = min(upper, samples.count)
            guard upper > lower else { continue }
            let window = samples[lower..<upper]
            let peak = window.reduce(Float(0)) { max($0, abs($1)) }
            guard peak > max(noise * 4, 0.003) else { continue }
            let threshold = max(peak * 0.3, noise * 3)
            guard let onset = window.firstIndex(where: { abs($0) >= threshold }) else { continue }
            lags.append(Double(onset) - beat)
        }
        return Analysis(lags: lags, played: expected.count)
    }

    /// Turns single lags into one result, refusing a measurement that is not clean enough to trust.
    public static func evaluate(_ analysis: Analysis, sampleRate: Double, reported: Double) throws -> Result {
        let needed = max(4, (analysis.played * 2 + 2) / 3)
        guard analysis.lags.count >= needed else { throw LatencyProbeError.noSignal }
        let sorted = analysis.lags.sorted()
        let median = sorted[sorted.count / 2]
        let inliers = sorted.filter { abs($0 - median) <= earlyTolerance * sampleRate }
        let spread = ((inliers.last ?? 0) - (inliers.first ?? 0)) / sampleRate
        guard inliers.count >= needed, spread <= stableSpread else {
            let all = ((sorted.last ?? 0) - (sorted.first ?? 0)) / sampleRate
            throw LatencyProbeError.unstable(spreadMilliseconds: max(spread, all) * 1000)
        }
        let mean = inliers.reduce(0, +) / Double(inliers.count)
        return Result(measured: mean / sampleRate, reported: reported, spread: spread, detected: inliers.count,
                      played: analysis.played)
    }

    #if os(macOS)
    /// Runs on the main thread and takes about ten seconds. The audio goes to a temporary file that is deleted
    /// again; nothing is added to the library.
    @MainActor
    public static func measure(input: InputDevice, output: AudioDeviceID, beats: Int = 12, bpm: Double = 100,
                               volume: Float = 0.5, inputPolicy: InputPolicy = .sparkOnly) async throws -> Result {
        let capture = CaptureEngine(inputPolicy: inputPolicy)
        try capture.open(device: input)
        defer { capture.close() }
        guard let clock = capture.clock else { throw CaptureError.notOpen }
        let rate = capture.sampleRate

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spark-latency-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // The file starts first, so the stretch before the first click shows the noise floor.
        try capture.startRecording(to: url)
        try await Task.sleep(nanoseconds: 300_000_000)

        let click = ClickEngine()
        try click.start(device: output, settings: MetronomeSettings(bpm: bpm, beatsPerBar: 4, volume: volume),
                        clock: clock)
        defer { click.stop() }
        guard let anchor = await click.waitForAnchor() else { throw LatencyProbeError.clickDidNotStart }
        // Stops the click after the last measured beat, so its echo cannot run into a new one.
        click.muteAfter(beats: beats)
        let interval = ClickTiming.beatInterval(bpm: bpm, inputRate: rate)
        try await Task.sleep(nanoseconds: UInt64((Double(beats) * 60 / bpm + maximumLatency + 0.2) * 1e9))

        let reported = click.reportedOutputLatency + capture.reportedInputLatency
        let fileFirst = capture.fileFirstFrame
        click.stop()
        guard capture.stopRecording() != nil, let fileFirst else { throw LatencyProbeError.noSignal }

        let samples = try loudestChannel(url)
        let expected = (0..<beats).map { anchor + Double($0) * interval - Double(fileFirst) }
        let analysis = analyze(samples: samples, sampleRate: rate, expected: expected)
        return try evaluate(analysis, sampleRate: rate, reported: reported)
    }
    #endif

    private static func loudestChannel(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        var best: [Float] = []
        var bestPeak: Float = -1
        for channel in 0..<Int(format.channelCount) {
            let samples = Array(UnsafeBufferPointer(start: data[channel], count: frames))
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            if peak > bestPeak {
                bestPeak = peak
                best = samples
            }
        }
        return best
    }
}
