import AVFoundation
import AppKit
import SparkCore

/// Headless commands for checking the audio path without the UI:
///   --list
///   --record <device name part> <seconds> <output.wav>
///   --play-tone <device name part> <seconds> [frequency] [amplitude]
///   --inspect <file.wav>
func runCommandLine(_ arguments: [String]) -> Int32? {
    guard let command = arguments.first, command.hasPrefix("--"), command != "--library" else { return nil }

    switch command {
    case "--inspect":
        guard arguments.count == 2 else {
            print("usage: --inspect <file.wav>")
            return 64
        }
        print(WAVFile.inspect(URL(fileURLWithPath: arguments[1])))
        return 0
    case "--list":
        for device in AudioDevices.inputDevices() {
            print("input \(device.name): \(device.channels) ch, \(device.physicalBits) bit, current \(device.currentRate) Hz, max \(device.maxRate) Hz")
        }
        for device in AudioDevices.outputDevices() {
            print("output \(device.name): \(device.channels) ch")
        }
        print("spark devices without input: \(AudioDevices.sparkDevicesWithoutInput())")
        return 0
    case "--play-tone":
        return playTone(arguments)
    case "--record":
        return record(arguments)
    default:
        print("unknown command")
        return 64
    }
}

private func record(_ arguments: [String]) -> Int32 {
    guard arguments.count == 4, let seconds = Double(arguments[2]) else {
        print("usage: --record <device name part> <seconds> <output.wav>")
        return 64
    }
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .audio) { allowed in
        granted = allowed
        semaphore.signal()
    }
    semaphore.wait()
    print("microphone permission: \(granted)")
    guard let device = AudioDevices.inputDevices().first(where: {
        $0.name.lowercased().contains(arguments[1].lowercased())
    }) else {
        print("no matching input device")
        return 1
    }
    let capture = CaptureEngine()
    do {
        try capture.open(device: device)
        try capture.startRecording(to: URL(fileURLWithPath: arguments[3]))
    } catch {
        print("start failed: \(error.localizedDescription)")
        return 1
    }
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    guard let result = capture.stopRecording() else { return 1 }
    capture.close()
    print("seconds: \(result.seconds), peak: \(result.peak), dropped: \(result.droppedFrames), write error: \(result.writeError.map(String.init) ?? "none")")
    return result.writeError == nil ? 0 : 1
}

/// Feeds a synthetic sine into a device, which is how UI tests get a signal through BlackHole.
private func playTone(_ arguments: [String]) -> Int32 {
    guard arguments.count >= 3, let seconds = Double(arguments[2]) else {
        print("usage: --play-tone <device name part> <seconds> [frequency] [amplitude]")
        return 64
    }
    let frequency = arguments.count > 3 ? Double(arguments[3]) ?? 1000 : 1000
    let amplitude = arguments.count > 4 ? Float(arguments[4]) ?? 0.25 : 0.25
    guard let device = AudioDevices.outputDevices().first(where: {
        $0.name.lowercased().contains(arguments[1].lowercased())
    }) else {
        print("no matching output device")
        return 1
    }
    let rate = AudioDevices.currentRate(of: device.id)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spark-tone-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    var samples = [Float](repeating: 0, count: Int(seconds * rate))
    for index in samples.indices {
        samples[index] = amplitude * Float(sin(2 * .pi * frequency * Double(index) / rate))
    }
    let playback = PlaybackEngine()
    do {
        try WAVWriter.write(samples: samples, sampleRate: rate, channels: 1, to: url)
        try playback.setOutput(device.id)
        try playback.load(url: url, edit: EditList())
        try playback.play()
    } catch {
        print("play failed: \(error.localizedDescription)")
        return 1
    }
    RunLoop.main.run(until: Date().addingTimeInterval(seconds + 0.2))
    return 0
}

if let status = runCommandLine(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
SparkRecorderApp.main()
