#if os(iOS)
import AVFoundation
import SparkCore

/// The iPad's audio input, for the tuner: whatever the system routes in, which is the Spark when it is plugged in
/// over USB and the built-in microphone otherwise.
///
/// iPadOS has one input route and no device list, so this is the whole "deck" there. It only feeds the tuner's tap:
/// nothing is stored, nothing is played, and the input is open only while the tuner listens.
@MainActor
final class PadInput: SharedInput {
    private let engine = AVAudioEngine()
    private var tap: AudioTap?
    private var observers: [NSObjectProtocol] = []

    var device: InputDevice? {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.currentRoute.inputs.first ?? session.availableInputs?.first else { return nil }
        let isUSB = port.portType == .usbAudio
        return InputDevice(id: 1, uid: port.uid, modelUID: "", name: port.portName,
                           channels: max(port.channels?.count ?? 1, 1), currentRate: session.sampleRate,
                           maxRate: session.sampleRate, physicalBits: 0,
                           transport: isUSB ? kAudioDeviceTransportTypeUSB : kAudioDeviceTransportTypeBuiltIn)
    }

    /// Nothing else on the iPad keeps the input open: there is no recording here.
    var isHeldOpen: Bool { false }
    var allowsOtherInputs: Bool { false }

    func owns(_ device: InputDevice) -> Bool { true }

    func isSharing(with tap: AudioTap) -> Bool {
        self.tap === tap && engine.isRunning
    }

    func share(with tap: AudioTap) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw SharedInputError.noPermission }
        stop()
        let session = AVAudioSession.sharedInstance()
        // Measurement mode switches the system's own processing off, which would bend a pitch reading. Other apps
        // keep playing: a tuner must not stop a backing track.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
        try session.setActive(true)
        guard session.isInputAvailable else { throw SharedInputError.noDevice }
        self.tap = tap
        try start()
        observe()
    }

    func stopSharing(with tap: AudioTap) {
        guard self.tap === tap else { return }
        stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func start() throws {
        guard let tap else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SharedInputError.noDevice }
        tap.beginStream(sampleRate: format.sampleRate)
        // The engine calls this on its own queue, not on the realtime thread, so building the mono block is fine.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for channel in 0..<count {
                let samples = UnsafeBufferPointer(start: channels[channel], count: frames)
                for frame in 0..<frames { mono[frame] += samples[frame] }
            }
            if count > 1 {
                let scale = 1 / Float(count)
                for frame in 0..<frames { mono[frame] *= scale }
            }
            tap.write(mono)
        }
        engine.prepare()
        try engine.start()
    }

    private func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        tap = nil
    }

    /// A plugged or pulled cable changes the engine's format and stops it. It starts again on the new route with
    /// a new stream; when that fails the tuner sees the input gone and tries again itself.
    private func observe() {
        let restart: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tap = self.tap else { return }
                self.engine.inputNode.removeTap(onBus: 0)
                if self.engine.isRunning { self.engine.stop() }
                self.tap = tap
                try? self.start()
            }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main, using: restart),
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main,
                               using: restart),
        ]
    }
}
#endif
