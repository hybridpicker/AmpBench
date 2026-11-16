import AmpText
import AudioToolbox
import CSparkRT
import Foundation
#if os(iOS)
import AVFoundation
#endif

public enum MetronomeError: LocalizedError {
    case noOutput
    case coreAudio(step: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noOutput: tr("No audio output could be opened for the metronome.")
        case .coreAudio(let step, let status): tr("%@ failed (error %d).", step, Int(status))
        }
    }
}

/// One pulse of the metronome as the window gets it: which beat, and when it is heard.
public struct MetronomePulse: Equatable, Sendable {
    public var bar: Int
    public var beat: Int
    /// 0 on the beat, then the subdivisions.
    public var sub: Int
    public var bpm: Double
    /// Seconds on the host clock (`MetronomeEngine.now`), nil while the output gave no time.
    public var heardAt: Double?
}

/// The practice metronome's output: a C renderer (`spark_metronome_*`) on the output's own sample clock, called by
/// the output unit's callback with no Swift on the audio thread. The Mac plays on a chosen device through AUHAL, the
/// iPad through RemoteIO.
public final class MetronomeEngine {
    private var unit: AudioUnit?
    private var metronome: OpaquePointer?
    public private(set) var sampleRate: Double = 0
    public private(set) var outputLatency: Double = 0

    public init() {}

    deinit {
        stop()
    }

    public var isRunning: Bool { unit != nil }

    /// The tempo playing now; the trainer may have changed it.
    public var currentBPM: Double? { metronome.map { spark_metronome_current_bpm($0) }.flatMap { $0 > 0 ? $0 : nil } }

    /// Seconds on the host clock, comparable with `MetronomePulse.heardAt`.
    public static var now: Double { Double(mach_absolute_time()) / hostTicksPerSecond }

    static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    /// What the renderer gets for the settings. The trainer's direction follows from where the target lies.
    public static func config(for settings: MetronomeSettings) -> SparkMetronomeConfig {
        var config = SparkMetronomeConfig()
        config.bpm = min(max(settings.bpm, MetronomeSettings.bpmRange.lowerBound), MetronomeSettings.bpmRange.upperBound)
        config.beats_per_bar = UInt32(min(max(settings.beatsPerBar, 1), Int(SPARK_METRONOME_MAX_BEATS)))
        let levels = settings.levels
        withUnsafeMutableBytes(of: &config.levels) { bytes in
            for index in 0..<min(levels.count, bytes.count) { bytes[index] = UInt8(levels[index].rawValue) }
        }
        config.subdivision = UInt32(settings.pattern.subdivision.rawValue)
        config.subdivision_level = min(max(settings.pattern.subdivisionLevel, 0), 1)
        config.volume = min(max(settings.volume, 0), 1)
        config.sound = UInt32(settings.pattern.sound.rawValue)
        let trainer = settings.trainer
        if trainer.isOn, trainer.stepBPM != 0, trainer.targetBPM != config.bpm {
            config.trainer_step = trainer.targetBPM > config.bpm ? abs(trainer.stepBPM) : -abs(trainer.stepBPM)
            config.trainer_every_bars = UInt32(max(trainer.everyBars, 1))
            config.trainer_target = min(max(trainer.targetBPM, MetronomeSettings.bpmRange.lowerBound),
                                        MetronomeSettings.bpmRange.upperBound)
        }
        return config
    }

    #if os(macOS)
    /// Starts on `device`, or on the system's output when nil.
    public func start(device: AudioDeviceID?, settings: MetronomeSettings) throws {
        stop()
        guard let device = device ?? AudioDevices.defaultOutputDevice() else { throw MetronomeError.noOutput }
        try open(subType: kAudioUnitSubType_HALOutput) { unit in
            var mutableDevice = device
            try self.check(tr("Selecting the device"), AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &mutableDevice, UInt32(MemoryLayout<AudioDeviceID>.size)))
        } latency: { rate in
            Double(AudioDevices.outputLatencyFrames(of: device)) / rate
        }
        update(settings: settings)
    }
    #else
    /// Starts on the iPad's current output (headphones, speaker or an interface). Other apps keep playing.
    public func start(settings: MetronomeSettings) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try session.setCategory(.playback, options: [.mixWithOthers])
        }
        try session.setActive(true)
        try open(subType: kAudioUnitSubType_RemoteIO) { _ in } latency: { _ in
            session.outputLatency + session.ioBufferDuration
        }
        update(settings: settings)
    }
    #endif

    private func open(subType: OSType, configure: (AudioUnit) throws -> Void,
                      latency: (Double) -> Double) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw MetronomeError.noOutput }
        var newUnit: AudioUnit?
        try check(tr("Opening the metronome"), AudioComponentInstanceNew(component, &newUnit))
        guard let unit = newUnit else { throw MetronomeError.noOutput }
        self.unit = unit
        do {
            try configure(unit)
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(tr("Reading the output format"), AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &hardware, &size))
            let rate = hardware.mSampleRate > 0 ? hardware.mSampleRate : 48000
            var client = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: max(min(hardware.mChannelsPerFrame, 2), 1), mBitsPerChannel: 32, mReserved: 0)
            try check(tr("Setting the metronome's format"), AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            let newMetronome = spark_metronome_create(rate)
            metronome = newMetronome
            sampleRate = rate
            outputLatency = latency(rate)
            spark_metronome_set_output_latency(newMetronome, outputLatency)
            var callback = AURenderCallbackStruct(inputProc: spark_metronome_output_callback,
                                                  inputProcRefCon: UnsafeMutableRawPointer(newMetronome))
            try check(tr("Registering the metronome"), AudioUnitSetProperty(
                unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check(tr("Initializing the metronome"), AudioUnitInitialize(unit))
            try check(tr("Starting the metronome"), AudioOutputUnitStart(unit))
        } catch {
            stop()
            throw error
        }
    }

    /// New settings take effect on the next beat; the trainer starts again from their tempo.
    public func update(settings: MetronomeSettings) {
        guard let metronome else { return }
        var config = Self.config(for: settings)
        spark_metronome_configure(metronome, &config)
    }

    /// Every pulse placed since the last call, oldest first.
    public func drainPulses() -> [MetronomePulse] {
        guard let metronome else { return [] }
        var pulses: [MetronomePulse] = []
        var event = SparkMetronomeEvent()
        while spark_metronome_next_event(metronome, &event) {
            pulses.append(MetronomePulse(
                bar: Int(event.bar), beat: Int(event.beat), sub: Int(event.sub), bpm: event.bpm,
                heardAt: event.host_time == 0 ? nil : Double(event.host_time) / Self.hostTicksPerSecond))
        }
        return pulses
    }

    public func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        // Freed only after the unit has stopped calling it.
        if let metronome { spark_metronome_destroy(metronome) }
        metronome = nil
        sampleRate = 0
        outputLatency = 0
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw MetronomeError.coreAudio(step: step, status: status) }
    }
}
