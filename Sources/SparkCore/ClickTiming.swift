import AmpText
import AVFoundation
import Foundation

/// How long a beat takes from the click output until it shows up in the file, if someone plays exactly on it.
///
/// Core Audio stamps output audio when it reaches the output driver and input audio when it leaves the input
/// driver. Between those, the sound spends the output's latency in the output device and, once played, the input's
/// latency in the input device. Both devices report these, but an amp also delays the guitar inside, in its
/// converters and effects, without reporting it. `amp` holds that rest, measured or set by hand.
public struct ClickLatency: Codable, Equatable, Sendable {
    public var output: Double
    public var input: Double
    public var amp: AmpPart?
    public var outputKind: ClickOutputKind

    public init(output: Double = 0, input: Double = 0, amp: AmpPart? = nil, outputKind: ClickOutputKind = .wired) {
        self.output = output
        self.input = input
        self.amp = amp
        self.outputKind = outputKind
    }

    /// The amp's part in seconds, 0 when none is known.
    public var correction: Double { amp?.seconds ?? 0 }
    public var reported: Double { output + input }
    public var total: Double { reported + correction }
}

/// How the click reaches the ear. The delay of a Bluetooth or AirPlay output is not steady enough for a timing
/// review.
public enum ClickOutputKind: String, Codable, Equatable, Sendable {
    case wired
    case bluetooth
    case airPlay

    /// The kind of an output by its transport. `parts` are the transports of the devices an aggregate or multi-output
    /// device plays to: one Bluetooth or AirPlay device among them makes the whole output so.
    public init(transport: UInt32, parts: [UInt32] = []) {
        let transports = [transport] + parts
        if transports.contains(where: { $0 == kAudioDeviceTransportTypeBluetooth
                                        || $0 == kAudioDeviceTransportTypeBluetoothLE }) {
            self = .bluetooth
        } else if transports.contains(kAudioDeviceTransportTypeAirPlay) {
            self = .airPlay
        } else {
            self = .wired
        }
    }
}

/// The amp's part of the click latency: what no device reports. It belongs to the input, the amp, and holds for
/// every wired click output of the computer.
public struct AmpPart: Codable, Equatable, Sendable {
    public enum Origin: Codable, Equatable, Sendable {
        /// Found by a measurement, with the measurement's spread in seconds.
        case measured(spread: Double, date: Date)
        case setByHand
    }

    public var seconds: Double
    public var origin: Origin

    public init(seconds: Double, origin: Origin) {
        self.seconds = seconds
        self.origin = origin
    }
}

/// The amp parts of the click latency, one per input.
public struct AmpLatencies: Codable, Equatable, Sendable {
    /// Keyed by the input's UID.
    public private(set) var parts: [String: AmpPart]

    public init(parts: [String: AmpPart] = [:]) {
        self.parts = parts
    }

    public func part(for input: DeviceIdentity) -> AmpPart? {
        parts[input.uid]
    }

    /// Keeps a measurement's part for the input; it replaces whatever was there.
    public mutating func store(_ result: LatencyProbe.Result, for input: DeviceIdentity, at date: Date) {
        parts[input.uid] = AmpPart(seconds: result.correction, origin: .measured(spread: result.spread, date: date))
    }

    /// The range a hand-set part keeps to, in seconds.
    public static let handSetRange = -0.1...0.3

    /// Sets the part by hand; it then counts as hand-set even when it was measured before. About zero forgets it.
    public mutating func setByHand(_ seconds: Double, for input: DeviceIdentity) {
        let clamped = min(max(seconds, Self.handSetRange.lowerBound), Self.handSetRange.upperBound)
        if abs(clamped) < 0.00005 {
            parts.removeValue(forKey: input.uid)
        } else {
            parts[input.uid] = AmpPart(seconds: clamped, origin: .setByHand)
        }
    }

    /// Takes over the corrections stored per pair of input and click output (`input UID|output UID`) before the
    /// amp part moved to the input. None was confirmed as measured, so they come over as hand-set, except the one
    /// measured with the owner on 2026-11-23: the Spark MINI with the built-in headphone output, spread 1.2 ms.
    /// An input with values for several outputs keeps that measured one, otherwise the first by key.
    public static func carryOver(pairs: [String: Double]) -> AmpLatencies {
        var amps = AmpLatencies()
        for key in pairs.keys.sorted() {
            guard let value = pairs[key], let bar = key.firstIndex(of: "|") else { continue }
            let input = String(key[..<bar])
            let output = String(key[key.index(after: bar)...])
            guard !input.isEmpty, !output.isEmpty else { continue }
            if isFirstMeasurement(input: input, output: output) {
                amps.parts[input] = AmpPart(seconds: value, origin: .measured(spread: firstMeasurementSpread,
                                                                              date: firstMeasurementDate))
            } else if amps.parts[input] == nil {
                amps.parts[input] = AmpPart(seconds: value, origin: .setByHand)
            }
        }
        return amps
    }

    /// 2026-11-23, noon UTC.
    static let firstMeasurementDate = Date(timeIntervalSince1970: 1_795_435_200)
    /// The spread of that measurement: 1.2 ms over 12 clicks.
    static let firstMeasurementSpread = 0.0012

    /// The Mac's built-in headphone output, by its UID.
    private static let builtInHeadphones = "BuiltInHeadphoneOutputDevice"

    /// The Spark MINI's USB input (`AppleUSBAudioEngine:<maker>:<product>:<place>:<stream>`, the product "Spark MINI"
    /// or "Spark MINI USB") with the built-in headphone output.
    private static func isFirstMeasurement(input: String, output: String) -> Bool {
        let fields = input.split(separator: ":", omittingEmptySubsequences: false)
        guard output == builtInHeadphones, fields.count >= 3, fields[0] == "AppleUSBAudioEngine" else { return false }
        let product = fields[2].lowercased().filter { $0.isLetter || $0.isNumber }
        return product == "sparkmini" || product == "sparkminiusb"
    }

    /// The click latency of a recording from this input, with what the click output and the input report. Without
    /// an input there is no amp part.
    public func clickLatency(input: DeviceIdentity?, reportedOutput: Double, reportedInput: Double,
                             outputKind: ClickOutputKind) -> ClickLatency {
        ClickLatency(output: reportedOutput, input: reportedInput, amp: input.flatMap(part(for:)),
                     outputKind: outputKind)
    }
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
    /// without any delay. A click is placed where it begins, by the timing review's own onset detector, so a note
    /// played exactly on the click reviews as on it.
    public static func analyze(samples: [Float], sampleRate: Double, expected: [Double]) -> Analysis {
        guard let first = expected.first, sampleRate > 0 else { return Analysis(lags: [], played: expected.count) }
        let early = Int(earlyTolerance * sampleRate)
        let quietEnd = min(max(Int(first) - early, 0), samples.count)
        let noise = samples[0..<quietEnd].reduce(Float(0)) { max($0, abs($1)) }
        let onsets = OnsetDetector.attacks(in: samples, sampleRate: sampleRate).map { $0.time * sampleRate }

        var lags: [Double] = []
        for (index, beat) in expected.enumerated() {
            let lower = max(Int(beat.rounded(.down)) - early, 0)
            var upper = Int(beat + maximumLatency * sampleRate)
            if index + 1 < expected.count { upper = min(upper, Int(expected[index + 1]) - early) }
            upper = min(upper, samples.count)
            guard upper > lower else { continue }
            let window = samples[lower..<upper]
            let peak = window.reduce(Float(0)) { max($0, abs($1)) }
            guard peak > max(noise * 4, 0.003),
                  let onset = onsets.first(where: { $0 >= Double(lower) && $0 < Double(upper) }) else { continue }
            lags.append(onset - beat)
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

        guard let samples = try AudioAnalyzer.loudestChannel(url)?.samples else { throw LatencyProbeError.noSignal }
        let expected = (0..<beats).map { anchor + Double($0) * interval - Double(fileFirst) }
        let analysis = analyze(samples: samples, sampleRate: rate, expected: expected)
        return try evaluate(analysis, sampleRate: rate, reported: reported)
    }
    #endif
}
