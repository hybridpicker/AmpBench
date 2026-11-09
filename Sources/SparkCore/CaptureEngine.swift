import AudioToolbox
import CSparkRT
import CoreAudio
import Foundation

public enum CaptureError: LocalizedError {
    case noAudioUnit
    case coreAudio(step: String, status: OSStatus)
    case noInputFormat
    case notOpen
    case alreadyRecording
    case inputNotAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioUnit: return "Der Audioeingang konnte nicht geöffnet werden."
        case .coreAudio(let step, let status): return "\(step) ist fehlgeschlagen (Fehler \(status))."
        case .noInputFormat: return "Das Gerät liefert kein nutzbares Eingangssignal."
        case .notOpen: return "Der Audioeingang ist nicht geöffnet."
        case .alreadyRecording: return "Es läuft bereits eine Aufnahme."
        case .inputNotAllowed(let name):
            return "„\(name)“ ist als Eingang nicht erlaubt. Spark Recorder nimmt nur von einem Spark über USB auf."
        }
    }
}

public struct RecordingResult: Sendable {
    public let url: URL
    public let frames: Int64
    public let seconds: Double
    public let peak: Float
    public let droppedFrames: Int64
    public let clippedBlocks: UInt32
    public let writeError: OSStatus?
    /// False when bins were lost and the waveform must be computed from the file.
    public let overviewComplete: Bool
    /// False when the writer could not be closed, so the header stays open until the next start repairs it.
    public let finalized: Bool
}

public enum CaptureInterruption: Sendable {
    case deviceLost
    case sampleRateChanged
}

/// Records one input device through AUHAL.
///
/// The input can stay open without a file for level checks and the retro buffer, and a file can be attached at any
/// moment. All methods belong on the main thread. The realtime path lives in `CSparkRT`.
public final class CaptureEngine {
    public static let overviewBinFrames: UInt32 = 256
    private static let retroMarginSeconds = 5.0

    private let inputPolicy: InputPolicy
    private var unit: AudioUnit?
    private var capture: OpaquePointer?
    /// Where the input's frames lie in time, for placing the click on them. Replaced whenever the input opens.
    public private(set) var clock: InputClock?
    private var file: ExtAudioFileRef?
    private var url: URL?
    private var deviceID: AudioDeviceID?
    private var restoreRate: Double?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var syncTimer: DispatchSourceTimer?
    private var syncDescriptor: Int32 = -1
    /// A reader of the input, such as the tuner. It stays attached when the input is reopened.
    private var tap: AudioTap?

    public private(set) var sampleRate: Double = 0
    public private(set) var channels: Int = 0
    public private(set) var retroCapacitySeconds: Double = 0

    /// Called on the main queue when the running input can no longer deliver audio.
    public var onInterrupted: ((CaptureInterruption) -> Void)?

    public init(inputPolicy: InputPolicy = .sparkOnly) {
        self.inputPolicy = inputPolicy
    }

    deinit {
        close()
    }

    public var isOpen: Bool { unit != nil }
    public var isRecording: Bool { file != nil }

    // MARK: Opening the input

    /// `raiseRate` switches the device to its highest rate while open, as recordings want. A listener that only
    /// reads, such as the tuner on another input, leaves the device as it is.
    public func open(device: InputDevice, retroSeconds: Double = 0, raiseRate: Bool = true) throws {
        // Checked here, below every feature, so nothing can record from a device that is not allowed.
        guard inputPolicy.allows(device) else { throw CaptureError.inputNotAllowed(device.name) }
        close()
        deviceID = device.id
        if raiseRate, device.maxRate > device.currentRate, AudioDevices.setRate(device.maxRate, on: device.id) {
            restoreRate = device.currentRate
        }
        do {
            try startUnit(deviceID: device.id, retroSeconds: retroSeconds)
            watchDevice(device.id)
        } catch {
            close()
            throw error
        }
    }

    private func startUnit(deviceID: AudioDeviceID, retroSeconds: Double) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw CaptureError.noAudioUnit }
        var newUnit: AudioUnit?
        try check("Öffnen des Audioeingangs", AudioComponentInstanceNew(component, &newUnit))
        guard let unit = newUnit else { throw CaptureError.noAudioUnit }
        self.unit = unit

        // Bus 1 is the hardware input and bus 0 the hardware output. Only the input is used.
        var enabled: UInt32 = 1
        var disabled: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        try check("Aktivieren des Eingangs", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, flagSize))
        try check("Deaktivieren des Ausgangs", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, flagSize))

        var device = deviceID
        try check("Auswählen des Geräts", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)))

        var hardware = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("Lesen des Geräteformats", AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &formatSize))
        guard hardware.mChannelsPerFrame > 0, hardware.mSampleRate > 0 else { throw CaptureError.noInputFormat }

        var client = Self.clientFormat(rate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame)
        try check("Setzen des Aufnahmeformats", AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        try check("Initialisieren des Audioeingangs", AudioUnitInitialize(unit))

        var maxFrames: UInt32 = 0
        var maxFramesSize = flagSize
        try check("Lesen der Puffergröße", AudioUnitGetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &maxFramesSize))

        let retroFrames = UInt64(max(retroSeconds, 0) * hardware.mSampleRate)
        let margin = UInt64(Self.retroMarginSeconds * hardware.mSampleRate)
        let newClock = InputClock(sampleRate: hardware.mSampleRate)
        clock = newClock
        let newCapture = spark_capture_create(
            hardware.mChannelsPerFrame, max(maxFrames, 8192), hardware.mSampleRate, retroFrames, margin,
            Self.overviewBinFrames, newClock.pointer)
        spark_capture_set_unit(newCapture, unit)
        if let tap {
            tap.begin(sampleRate: hardware.mSampleRate)
            spark_capture_set_tap(newCapture, tap.pointer)
        }
        capture = newCapture

        var callback = AURenderCallbackStruct(
            inputProc: spark_capture_input_callback,
            inputProcRefCon: UnsafeMutableRawPointer(newCapture)
        )
        try check("Registrieren der Aufnahme", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        sampleRate = hardware.mSampleRate
        channels = Int(hardware.mChannelsPerFrame)
        retroCapacitySeconds = retroSeconds
        try check("Starten des Eingangs", AudioOutputUnitStart(unit))
    }

    static func clientFormat(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        let bytesPerFrame = channels * UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func watchDevice(_ device: AudioDeviceID) {
        addListener(device, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            guard let self, self.deviceID == device, !AudioDevices.isAlive(device) else { return }
            self.onInterrupted?(.deviceLost)
        }
        // A pulled USB cable can also just remove the device from the system.
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) { [weak self] in
            guard let self, self.deviceID == device, !AudioDevices.exists(device) else { return }
            self.onInterrupted?(.deviceLost)
        }
        let rate = sampleRate
        addListener(device, kAudioDevicePropertyNominalSampleRate) { [weak self] in
            guard let self, self.deviceID == device, AudioDevices.currentRate(of: device) != rate else { return }
            self.onInterrupted?(.sampleRateChanged)
        }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ handler: @escaping () -> Void) {
        var address = AudioDevices.address(selector)
        // Core Audio waits for a running listener when one gets removed. Reacting here could end the capture and
        // remove this very listener, which freezes the app, so the reaction runs after the listener has returned.
        let listener: AudioObjectPropertyListenerBlock = { _, _ in DispatchQueue.main.async(execute: handler) }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, listener) == noErr {
            listeners.append((object, address, listener))
        }
    }

    /// Stops the input, finalizing a running recording first.
    public func close() {
        _ = stopRecording()
        for (object, address, listener) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
        }
        listeners = []
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        // The unit is disposed, so no callback runs any more and the tap stays with this engine for the next open.
        if let capture { spark_capture_destroy(capture) }
        capture = nil
        // A click may still hold the clock. It then keeps going on the last known timing until it stops.
        clock = nil
        sampleRate = 0
        channels = 0
        retroCapacitySeconds = 0
        if let restoreRate, let deviceID { AudioDevices.setRate(restoreRate, on: deviceID) }
        restoreRate = nil
        deviceID = nil
    }

    // MARK: Recording

    /// Starts writing a 24-bit WAV file. With a gate, the file begins at exactly that input frame, counted like
    /// `clock`; without one, or with one that has passed, it begins with the next block.
    ///
    /// Files are always 24 bits so a 16-bit source stays lossless and later processing has headroom. This adds no
    /// detail beyond what the source delivers, so the UI reports the source format separately.
    public func startRecording(to destination: URL, gateFrame: Int64? = nil) throws {
        guard let capture else { throw CaptureError.notOpen }
        guard file == nil else { throw CaptureError.alreadyRecording }

        let channelCount = UInt32(channels)
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: channelCount * 3,
            mFramesPerPacket: 1,
            mBytesPerFrame: channelCount * 3,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        var newFile: ExtAudioFileRef?
        try check("Anlegen der Datei", ExtAudioFileCreateWithURL(
            destination as CFURL, kAudioFileWAVEType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &newFile))
        guard let newFile else { throw CaptureError.noInputFormat }
        do {
            var client = Self.clientFormat(rate: sampleRate, channels: channelCount)
            try check("Setzen des Dateiformats", ExtAudioFileSetProperty(
                newFile, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))
            // The first call allocates the async buffers, which must not happen on the realtime thread.
            try check("Vorbereiten der Datei", ExtAudioFileWriteAsync(newFile, 0, nil))
        } catch {
            ExtAudioFileDispose(newFile)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        file = newFile
        url = destination
        spark_capture_attach_file(capture, newFile, gateFrame.map { max($0, 0) } ?? Int64(SPARK_GATE_NONE))
        startPeriodicSync(destination)
    }

    /// Pushes written audio to the disk regularly, off the audio thread, so a power loss costs only seconds.
    private func startPeriodicSync(_ destination: URL) {
        syncDescriptor = Darwin.open(destination.path, O_RDONLY)
        guard syncDescriptor >= 0 else { return }
        let descriptor = syncDescriptor
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { _ = fsync(descriptor) }
        timer.setCancelHandler { Darwin.close(descriptor) }
        timer.resume()
        syncTimer = timer
        syncDescriptor = -1
    }

    @discardableResult
    public func stopRecording() -> RecordingResult? {
        guard let capture, let file, let destination = url else { return nil }
        syncTimer?.cancel()
        syncTimer = nil

        let detached = spark_capture_detach_file(capture)
        let frames = spark_capture_file_frames(capture)
        let dropped = spark_capture_dropped_frames(capture)
        let writeStatus = spark_capture_write_status(capture)
        let result = RecordingResult(
            url: destination,
            frames: frames,
            seconds: sampleRate > 0 ? Double(frames) / sampleRate : 0,
            peak: spark_capture_file_peak(capture),
            droppedFrames: dropped,
            clippedBlocks: spark_capture_clipped_blocks(capture),
            writeError: writeStatus == noErr ? nil : writeStatus,
            overviewComplete: spark_capture_dropped_bins(capture) == 0,
            finalized: detached
        )
        // Disposing flushes the queue and finalizes the header. If the audio thread could still be using the file,
        // leaving it open is the safe choice: the header gets repaired on the next start.
        if detached { ExtAudioFileDispose(file) }
        self.file = nil
        url = nil
        return result
    }

    // MARK: Listening along

    /// Lets `tap` read the input from now on, and after every reopen, until `detach`. Opens nothing by itself.
    public func attach(_ tap: AudioTap) {
        guard self.tap !== tap else { return }
        detachTap()
        self.tap = tap
        if let capture {
            tap.begin(sampleRate: sampleRate)
            spark_capture_set_tap(capture, tap.pointer)
        }
    }

    /// Stops writing into `tap`. A running recording and the retro buffer are not touched.
    public func detach(_ tap: AudioTap) {
        guard self.tap === tap else { return }
        detachTap()
    }

    public func isAttached(_ tap: AudioTap) -> Bool { self.tap === tap }

    private func detachTap() {
        guard let old = tap else { return }
        if let capture, !spark_capture_clear_tap(capture) {
            // A callback that does not finish in a second is stuck; keeping the tap alive is the safe choice.
            Self.stuckTaps.append(old)
        }
        tap = nil
    }

    private static var stuckTaps: [AudioTap] = []

    // MARK: Observing

    public var recordedFrames: Int64 { capture.map { spark_capture_file_frames($0) } ?? 0 }
    public var recordedSeconds: Double { sampleRate > 0 ? Double(recordedFrames) / sampleRate : 0 }
    public var droppedFrames: Int64 { capture.map { spark_capture_dropped_frames($0) } ?? 0 }
    /// The input frame, counted like `clock`, that is the first frame of the file. Nil until it was written.
    public var fileFirstFrame: Int64? {
        guard let capture else { return nil }
        let frame = spark_capture_file_first_frame(capture)
        return frame >= 0 ? frame : nil
    }
    /// The delay between a sound reaching the input device and its frames being stamped, as the device reports it.
    public var reportedInputLatency: Double {
        guard let deviceID, sampleRate > 0 else { return 0 }
        return Double(AudioDevices.inputLatencyFrames(of: deviceID)) / sampleRate
    }
    /// Input frames received since the input opened, counted like `clock`.
    public var framesReceived: Int64 { capture.map { spark_capture_frames_received($0) } ?? 0 }
    public var callbackCount: UInt64 { capture.map { spark_capture_callback_count($0) } ?? 0 }

    public func takeLevel() -> Float { capture.map { spark_capture_take_level($0) } ?? 0 }
    public func takeClip() -> Bool { capture.map { spark_capture_take_clip($0) } ?? false }

    /// Waveform bins written since the previous call, as min/max pairs.
    public func readOverview() -> [Float] {
        guard let capture else { return [] }
        var bins = [Float](repeating: 0, count: 8192 * 2)
        let count = bins.withUnsafeMutableBufferPointer {
            spark_capture_read_overview(capture, $0.baseAddress!, 8192)
        }
        bins.removeLast(bins.count - Int(count) * 2)
        return bins
    }

    // MARK: Retro buffer

    public var retroAvailableSeconds: Double {
        guard let capture, sampleRate > 0 else { return 0 }
        return Double(spark_capture_retro_available_frames(capture)) / sampleRate
    }

    /// Copies the most recent audio out of memory, for writing on a background thread.
    public func copyRetro(seconds: Double) -> (samples: [Float], sampleRate: Double, channels: Int)? {
        guard let capture, sampleRate > 0, channels > 0 else { return nil }
        let wanted = min(UInt64(seconds * sampleRate), spark_capture_retro_available_frames(capture))
        guard wanted > 0 else { return nil }
        var samples = [Float](repeating: 0, count: Int(wanted) * channels)
        let copied = samples.withUnsafeMutableBufferPointer {
            spark_capture_retro_copy_latest(capture, $0.baseAddress!, wanted)
        }
        samples.removeLast(samples.count - Int(copied) * channels)
        return (samples, sampleRate, channels)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw CaptureError.coreAudio(step: step, status: status) }
    }
}

extension OpaquePointer: @unchecked Sendable {}

/// Owns the realtime clock shared by an input and a click. Either may outlive the other, so both hold this object.
public final class InputClock: @unchecked Sendable {
    let pointer: OpaquePointer
    public let sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        pointer = spark_clock_create(sampleRate)
    }

    deinit {
        spark_clock_destroy(pointer)
    }

    /// For tests that drive the realtime code by hand.
    public func publish(frame: Int64, hostTime: UInt64) {
        spark_clock_publish(pointer, frame, hostTime)
    }

    public func hostTime(ofFrame frame: Double) -> Double? {
        var host = 0.0
        return spark_clock_host_time_of_frame(pointer, frame, &host) ? host : nil
    }

    public func frame(atHostTime host: Double) -> Double? {
        var frame = 0.0
        return spark_clock_frame_at_host_time(pointer, host, &frame) ? frame : nil
    }
}

/// Writes interleaved float samples to a 24-bit WAV file on a normal thread. Used for saving the retro buffer.
public enum WAVWriter {
    public static func write(samples: [Float], sampleRate: Double, channels: Int, to url: URL) throws {
        let channelCount = UInt32(channels)
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: channelCount * 3,
            mFramesPerPacket: 1,
            mBytesPerFrame: channelCount * 3,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        var created: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &fileFormat, nil,
                                               AudioFileFlags.eraseFile.rawValue, &created)
        guard status == noErr, let file = created else {
            throw CaptureError.coreAudio(step: "Anlegen der Datei", status: status)
        }
        defer { ExtAudioFileDispose(file) }
        var client = CaptureEngine.clientFormat(rate: sampleRate, channels: channelCount)
        let formatStatus = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard formatStatus == noErr else {
            throw CaptureError.coreAudio(step: "Setzen des Dateiformats", status: formatStatus)
        }
        var samples = samples
        let frames = UInt32(samples.count / channels)
        let writeStatus = samples.withUnsafeMutableBytes { bytes -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: channelCount, mDataByteSize: UInt32(bytes.count),
                                      mData: bytes.baseAddress)
            )
            return ExtAudioFileWrite(file, frames, &list)
        }
        guard writeStatus == noErr else {
            throw CaptureError.coreAudio(step: "Schreiben der Datei", status: writeStatus)
        }
    }
}
