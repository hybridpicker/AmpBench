import AmpText
import CoreAudio
import Foundation

/// An audio device that exposes at least one input stream.
public struct InputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let modelUID: String
    public let name: String
    public let channels: Int
    public let currentRate: Double
    public let maxRate: Double
    public let physicalBits: Int
    public let transport: UInt32

    public init(id: AudioDeviceID, uid: String, modelUID: String, name: String, channels: Int, currentRate: Double,
                maxRate: Double, physicalBits: Int, transport: UInt32) {
        self.id = id
        self.uid = uid
        self.modelUID = modelUID
        self.name = name
        self.channels = channels
        self.currentRate = currentRate
        self.maxRate = maxRate
        self.physicalBits = physicalBits
        self.transport = transport
    }

    public var identity: DeviceIdentity {
        DeviceIdentity(uid: uid, modelUID: modelUID, name: name, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
    }
    public var isUSB: Bool { transport == kAudioDeviceTransportTypeUSB }
}

/// An audio device that exposes at least one output stream.
public struct OutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let modelUID: String
    public let name: String
    public let channels: Int
    public let transport: UInt32

    public var identity: DeviceIdentity {
        DeviceIdentity(uid: uid, modelUID: modelUID, name: name, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
    }
}

public enum AudioDevices {
    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func array<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> [T] {
        var property = property
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func allDevices() -> [AudioDeviceID] {
        array(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
    }

    private static func streams(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioStreamID] {
        array(device, address(kAudioDevicePropertyStreams, scope))
    }

    private static func transport(of device: AudioDeviceID) -> UInt32 {
        var property = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value)
        return value
    }

    private static func channelCount(_ streams: [AudioStreamID]) -> Int {
        physicalFormats(streams).reduce(0) { $0 + Int($1.mChannelsPerFrame) }
    }

    private static func physicalFormats(_ streams: [AudioStreamID]) -> [AudioStreamBasicDescription] {
        streams.compactMap { stream in
            var property = address(kAudioStreamPropertyPhysicalFormat)
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            return AudioObjectGetPropertyData(stream, &property, 0, nil, &size, &format) == noErr ? format : nil
        }
    }

    public static func currentRate(of device: AudioDeviceID) -> Double {
        var property = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    /// Sets the nominal rate and waits until the hardware reports it, because the change is asynchronous.
    @discardableResult
    public static func setRate(_ rate: Double, on device: AudioDeviceID) -> Bool {
        var property = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = rate
        let status = AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else { return false }
        for _ in 0..<40 {
            if currentRate(of: device) == rate { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// The rate to record at: the highest the device offers up to a limit. Virtual devices advertise rates like
    /// 768 kHz, which only produce huge files, so anything above the limit is ignored unless nothing else exists.
    public static func recordingRate(available: [(minimum: Double, maximum: Double)], current: Double,
                                     limit: Double = 192_000) -> Double {
        let usable = available.map { min($0.maximum, limit) }.enumerated()
            .filter { available[$0.offset].minimum <= limit }
            .map(\.element)
        return usable.max() ?? available.map(\.maximum).min() ?? current
    }

    public static func inputDevices() -> [InputDevice] {
        allDevices().compactMap { device in
            let inputs = streams(of: device, scope: kAudioObjectPropertyScopeInput)
            guard !inputs.isEmpty else { return nil }
            let formats = physicalFormats(inputs)
            let ranges: [AudioValueRange] = array(device, address(kAudioDevicePropertyAvailableNominalSampleRates))
            let current = currentRate(of: device)
            let rates = ranges.map { (minimum: $0.mMinimum, maximum: $0.mMaximum) }
            return InputDevice(
                id: device,
                uid: string(device, kAudioDevicePropertyDeviceUID) ?? "",
                modelUID: string(device, kAudioDevicePropertyModelUID) ?? "",
                name: string(device, kAudioObjectPropertyName) ?? tr("Unknown device"),
                channels: formats.reduce(0) { $0 + Int($1.mChannelsPerFrame) },
                currentRate: current,
                maxRate: recordingRate(available: rates, current: current),
                physicalBits: formats.map { Int($0.mBitsPerChannel) }.max() ?? 0,
                transport: transport(of: device)
            )
        }
    }

    public static func outputDevices() -> [OutputDevice] {
        allDevices().compactMap { device in
            let outputs = streams(of: device, scope: kAudioObjectPropertyScopeOutput)
            guard !outputs.isEmpty else { return nil }
            return OutputDevice(
                id: device,
                uid: string(device, kAudioDevicePropertyDeviceUID) ?? "",
                modelUID: string(device, kAudioDevicePropertyModelUID) ?? "",
                name: string(device, kAudioObjectPropertyName) ?? tr("Unknown device"),
                channels: channelCount(outputs),
                transport: transport(of: device)
            )
        }
    }

    public static func defaultInputDevice() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    public static func defaultOutputDevice() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var property = address(selector)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    public static func isAlive(_ device: AudioDeviceID) -> Bool {
        var property = address(kAudioDevicePropertyDeviceIsAlive)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    public static func exists(_ device: AudioDeviceID) -> Bool {
        allDevices().contains(device)
    }

    /// Frames between the moment Core Audio stamps on output audio and the moment the device plays it.
    public static func outputLatencyFrames(of device: AudioDeviceID) -> UInt32 {
        presentationLatencyFrames(of: device, scope: kAudioObjectPropertyScopeOutput)
    }

    /// Frames between the moment a sound reaches the device and the moment Core Audio stamps on that input.
    public static func inputLatencyFrames(of device: AudioDeviceID) -> UInt32 {
        presentationLatencyFrames(of: device, scope: kAudioObjectPropertyScopeInput)
    }

    /// The device latency plus the latency of its first stream in that direction, as Core Audio defines them.
    ///
    /// The safety offset is not part of it: the time stamps of the IO cycle already lie that far from "now", so
    /// adding it would count it twice.
    static func presentationLatencyFrames(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        func value(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                   _ scope: AudioObjectPropertyScope) -> UInt32 {
            var property = address(selector, scope)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : 0
        }
        let streamLatency = streams(of: device, scope: scope).first
            .map { value($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) } ?? 0
        return value(device, kAudioDevicePropertyLatency, scope) + streamLatency
    }

    /// Spark devices known to the system that expose no input stream, so the UI can explain why they are missing.
    public static func sparkDevicesWithoutInput() -> [String] {
        allDevices()
            .filter { streams(of: $0, scope: kAudioObjectPropertyScopeInput).isEmpty }
            .compactMap { string($0, kAudioObjectPropertyName) }
            .filter { $0.lowercased().contains("spark") }
    }

    /// Calls `handler` on the main queue whenever the set of devices changes. Returns a token for `stopObserving`.
    public static func observeDeviceList(_ handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock? {
        var property = address(kAudioHardwarePropertyDevices)
        // Returns first and reacts afterwards: the reaction can close the input, which removes listeners, and Core
        // Audio waits for a running listener when one gets removed.
        let listener: AudioObjectPropertyListenerBlock = { _, _ in DispatchQueue.main.async(execute: handler) }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
        return status == noErr ? listener : nil
    }

    public static func stopObservingDeviceList(_ listener: @escaping AudioObjectPropertyListenerBlock) {
        var property = address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
    }
}
