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
public final class ClickEngine {
    private var unit: AudioUnit?
    private var click: OpaquePointer?
    private var deviceID: AudioDeviceID?
    public private(set) var sampleRate: Double = 0

    public init() {}

    deinit {
        stop()
    }

    public var isRunning: Bool { unit != nil }
    public var beatCount: UInt64 { click.map { spark_click_beat_count($0) } ?? 0 }

    /// The moment the first beat becomes audible, in host time. Zero until the output has started.
    public var firstBeatHostTime: UInt64 {
        guard let click, let deviceID, sampleRate > 0 else { return 0 }
        let first = spark_click_first_host_time(click)
        guard first != 0 else { return 0 }
        let latency = Double(AudioDevices.outputLatencyFrames(of: deviceID)) / sampleRate
        return first + UInt64(latency * AudioGetHostClockFrequency())
    }

    public func start(device: AudioDeviceID, settings: MetronomeSettings) throws {
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
        try check("Öffnen des Klicks", AudioComponentInstanceNew(component, &newUnit))
        guard let unit = newUnit else { throw CaptureError.noAudioUnit }
        self.unit = unit
        do {
            var mutableDevice = device
            try check("Auswählen des Geräts", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &mutableDevice, UInt32(MemoryLayout<AudioDeviceID>.size)))

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check("Lesen des Ausgabeformats", AudioUnitGetProperty(
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
            try check("Setzen des Klickformats", AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

            let newClick = spark_click_create(hardware.mSampleRate)
            click = newClick
            sampleRate = hardware.mSampleRate
            deviceID = device
            spark_click_set_tempo(newClick, settings.bpm, UInt32(settings.beatsPerBar), settings.volume)

            var callback = AURenderCallbackStruct(
                inputProc: spark_click_output_callback,
                inputProcRefCon: UnsafeMutableRawPointer(newClick)
            )
            try check("Registrieren des Klicks", AudioUnitSetProperty(
                unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check("Initialisieren des Klicks", AudioUnitInitialize(unit))
            try check("Starten des Klicks", AudioOutputUnitStart(unit))
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
    public func muteAfter(beats: Int, bpm: Double) {
        guard let click, sampleRate > 0 else { return }
        spark_click_set_mute_from(click, Int64(Double(beats) * 60 / bpm * sampleRate))
    }

    /// Silences the click or lets it sound. It keeps counting either way, so the bars stay valid.
    public func setMuted(_ muted: Bool) {
        guard let click else { return }
        spark_click_set_mute_from(click, muted ? 0 : -1)
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
