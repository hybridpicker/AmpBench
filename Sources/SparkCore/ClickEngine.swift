import AmpText
import AudioToolbox
import CSparkRT
import CoreAudio
import Foundation

public struct MetronomeSettings: Codable, Equatable, Sendable {
    public var bpm: Double
    public var beatsPerBar: Int
    public var volume: Float
    public var countInBars: Int
    /// The click sounds while playing or recording, and never in between.
    public var clickEnabled: Bool

    public init(bpm: Double = 90, beatsPerBar: Int = 4, volume: Float = 0.6, countInBars: Int = 0,
                clickEnabled: Bool = false) {
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.volume = volume
        self.countInBars = countInBars
        self.clickEnabled = clickEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case bpm, beatsPerBar, volume, countInBars, clickEnabled
    }

    private enum LegacyKeys: String, CodingKey {
        case clickWhileRecording
    }

    /// Someone who chose the click during recordings in an earlier version finds it switched on.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) ?? 90
        beatsPerBar = try c.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? 4
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0.6
        countInBars = try c.decodeIfPresent(Int.self, forKey: .countInBars) ?? 0
        clickEnabled = try c.decodeIfPresent(Bool.self, forKey: .clickEnabled)
            ?? legacy.decodeIfPresent(Bool.self, forKey: .clickWhileRecording)
            ?? false
    }

    public var countInBeats: Int { countInBars * beatsPerBar }
    public var countInSeconds: Double { Double(countInBeats) * 60 / bpm }
}

/// Plays the click through its own output unit.
///
/// The click has no path into the capture code, so it cannot be written to a file by the app. Whether it reaches
/// the input through the outside world is what `FeedbackGuard` is for.
///
/// Started on an input's clock, its beats lie on input frames: beat 0 on `anchorFrame` and each further beat one
/// interval of input frames later. The click and the input can then run on different devices with different
/// clocks for any length of time without drifting apart, which is what the bars of a recording rest on.
public final class ClickEngine {
    private var unit: AudioUnit?
    private var click: OpaquePointer?
    private var clock: InputClock?
    public private(set) var deviceID: AudioDeviceID?
    public private(set) var sampleRate: Double = 0

    public init() {}

    deinit {
        stop()
    }

    public var isRunning: Bool { unit != nil }
    public var beatCount: UInt64 { click.map { spark_click_beat_count($0) } ?? 0 }
    public var lateBeats: UInt64 { click.map { spark_click_late_beats($0) } ?? 0 }

    /// The input frame of beat 0, counted like the clock the click started on. Nil until the output has started,
    /// and always without a clock.
    public var anchorFrame: Double? {
        guard let click else { return nil }
        var frame = 0.0
        return spark_click_anchor_frame(click, &frame) ? frame : nil
    }

    /// Waits on the main thread until the output has placed beat 0. Nil when it does not start within a second.
    public func waitForAnchor() async -> Double? {
        for _ in 0..<200 {
            if let anchorFrame { return anchorFrame }
            guard isRunning else { return nil }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    /// The delay between handing the click to the output and hearing it, as the device reports it.
    public var reportedOutputLatency: Double {
        guard let deviceID, sampleRate > 0 else { return 0 }
        return Double(AudioDevices.outputLatencyFrames(of: deviceID)) / sampleRate
    }

    public func start(device: AudioDeviceID, settings: MetronomeSettings, clock: InputClock? = nil) throws {
        stop()
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw CaptureError.noAudioUnit }
        var newUnit: AudioUnit?
        try check(tr("Opening the click"), AudioComponentInstanceNew(component, &newUnit))
        guard let unit = newUnit else { throw CaptureError.noAudioUnit }
        self.unit = unit
        do {
            var mutableDevice = device
            try check(tr("Selecting the device"), AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &mutableDevice, UInt32(MemoryLayout<AudioDeviceID>.size)))

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(tr("Reading the output format"), AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &hardware, &size))
            guard hardware.mSampleRate > 0 else { throw CaptureError.noInputFormat }

            let channelCount = max(min(hardware.mChannelsPerFrame, 2), 1)
            var client = AudioStreamBasicDescription(
                mSampleRate: hardware.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: channelCount,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try check(tr("Setting the click format"), AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

            let newClick = spark_click_create(hardware.mSampleRate, clock?.pointer)
            click = newClick
            self.clock = clock
            sampleRate = hardware.mSampleRate
            deviceID = device
            spark_click_set_tempo(newClick, settings.bpm, UInt32(settings.beatsPerBar), settings.volume)

            var callback = AURenderCallbackStruct(
                inputProc: spark_click_output_callback,
                inputProcRefCon: UnsafeMutableRawPointer(newClick)
            )
            try check(tr("Registering the click"), AudioUnitSetProperty(
                unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check(tr("Initializing the click"), AudioUnitInitialize(unit))
            try check(tr("Starting the click"), AudioOutputUnitStart(unit))
        } catch {
            stop()
            throw error
        }
    }

    public func update(settings: MetronomeSettings) {
        guard let click else { return }
        spark_click_set_tempo(click, settings.bpm, UInt32(settings.beatsPerBar), settings.volume)
    }

    /// Silences the click after the given number of beats from its start, used to end a count-in.
    public func muteAfter(beats: Int) {
        guard let click else { return }
        spark_click_set_mute_from_beat(click, Int64(max(beats, 0)))
    }

    /// Silences the click or lets it sound. It keeps counting either way, so the bars stay valid.
    public func setMuted(_ muted: Bool) {
        guard let click else { return }
        spark_click_set_mute_from_beat(click, muted ? 0 : -1)
    }

    public func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        if let click { spark_click_destroy(click) }
        click = nil
        // Released only after the click, which reads it on the audio thread until the unit has stopped.
        clock = nil
        deviceID = nil
        sampleRate = 0
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw CaptureError.coreAudio(step: step, status: status) }
    }
}

/// Measures whether output to a device arrives at an input, by playing quiet clicks and comparing levels.
public enum LoopbackProbe {
    public struct Measurement: Equatable, Sendable {
        public let baselinePeak: Float
        public let clickPeak: Float
        /// Level rose noticeably while the clicks played.
        public var outputReachesInput: Bool {
            let floor = max(baselinePeak, 0.00001)
            return clickPeak > floor * 2 && clickPeak > 0.0001
        }
    }

    /// Runs on the main thread and takes about three seconds.
    public static func measure(input: InputDevice, output: AudioDeviceID, volume: Float = 0.05,
                               seconds: Double = 1.5, inputPolicy: InputPolicy = .sparkOnly) async throws -> Measurement {
        let capture = CaptureEngine(inputPolicy: inputPolicy)
        try capture.open(device: input)
        defer { capture.close() }
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = capture.takeLevel()

        var baseline: Float = 0
        for _ in 0..<Int(seconds * 20) {
            try await Task.sleep(nanoseconds: 50_000_000)
            baseline = max(baseline, capture.takeLevel())
        }

        let click = ClickEngine()
        try click.start(device: output, settings: MetronomeSettings(bpm: 240, beatsPerBar: 4, volume: volume))
        defer { click.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = capture.takeLevel()

        var measured: Float = 0
        for _ in 0..<Int(seconds * 20) {
            try await Task.sleep(nanoseconds: 50_000_000)
            measured = max(measured, capture.takeLevel())
        }
        return Measurement(baselinePeak: baseline, clickPeak: measured)
    }
}
