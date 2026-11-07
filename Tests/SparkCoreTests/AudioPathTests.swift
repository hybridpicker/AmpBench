import AVFoundation
import CoreAudio
import XCTest
@testable import SparkCore

/// End-to-end tests with real audio streams over the virtual BlackHole device: a synthetic tone goes out of the
/// playback engine and comes back in through the capture engine.
///
/// They need BlackHole and microphone permission for the process running the tests. Without those they are skipped
/// and say why, so a green run never quietly means "not tested".
final class AudioPathTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var input: InputDevice!
    private var output: OutputDevice!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        guard let input = AudioDevices.inputDevices().first(where: { $0.name.contains("BlackHole") }),
              let output = AudioDevices.outputDevices().first(where: { $0.name.contains("BlackHole") }) else {
            throw XCTSkip("BlackHole is not installed")
        }
        self.input = input
        self.output = output
    }

    private func wait(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Skips when the OS delivers silence because this process has no microphone permission.
    private func requireMicrophone(_ capture: CaptureEngine) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("no microphone permission for the test process (status \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue))")
        }
        _ = capture
    }

    private func makeTone(frequency: Double = 1000, amplitude: Float = 0.25, seconds: Double = 6, rate: Double? = nil) throws -> URL {
        try Synthetic.writeWAV(to: folder.file("tone-\(UUID().uuidString).wav"), seconds: seconds, frequency: frequency,
                               amplitude: amplitude, sampleRate: rate ?? AudioDevices.currentRate(of: input.id))
    }

    private func record(seconds: Double, whilePlaying tone: URL, edit: EditList = EditList(),
                        configure: (PlaybackEngine) -> Void = { _ in }) throws -> (result: RecordingResult, facts: AudioFacts) {
        let capture = CaptureEngine()
        try requireMicrophone(capture)
        try capture.open(device: input)
        defer { capture.close() }

        let playback = PlaybackEngine()
        try playback.setOutput(output.id)
        try playback.load(url: tone, edit: edit)
        configure(playback)
        try playback.play()
        wait(0.3)

        let url = folder.file("capture-\(UUID().uuidString).wav")
        try capture.startRecording(to: url)
        wait(seconds)
        let result = try XCTUnwrap(capture.stopRecording())
        playback.pause()
        return (result, try readAudio(url))
    }

    func testInputDeviceSelectionAndFileFormat() throws {
        let tone = try makeTone()
        let (result, facts) = try record(seconds: 2, whilePlaying: tone)

        XCTAssertNil(result.writeError)
        XCTAssertEqual(result.droppedFrames, 0)
        XCTAssertTrue(result.finalized)
        XCTAssertEqual(result.seconds, 2, accuracy: 0.2)
        XCTAssertEqual(facts.frames, result.frames)

        guard case .ok(let format, let frames) = WAVFile.inspect(result.url) else { return XCTFail("expected ok") }
        XCTAssertEqual(format.bits, 24, "files are always 24-bit WAV")
        XCTAssertEqual(format.sampleRate, AudioDevices.currentRate(of: input.id))
        XCTAssertEqual(frames, result.frames)
    }

    func testOutputSelectionTonePitchAndLevelArrive() throws {
        let tone = try makeTone(amplitude: 0.25)
        let (result, facts) = try record(seconds: 2, whilePlaying: tone)

        // Only reachable if the engine really played to BlackHole instead of the system output.
        XCTAssertGreaterThan(result.peak, 0.01, "the tone must arrive through the selected output")
        let quarter = Int(facts.frames) / 4
        XCTAssertEqual(facts.frequency(from: quarter, to: quarter * 3), 1000, accuracy: 10)
        XCTAssertEqual(dB(facts.peak), dB(0.25), accuracy: 3.5, "stays within pan law of the source level")
    }

    func testPlaybackAppliesEdits() throws {
        let tone = try makeTone(amplitude: 0.1)
        let plain = try record(seconds: 1.5, whilePlaying: tone).facts
        let raised = try record(seconds: 1.5, whilePlaying: tone, edit: EditList(gainDB: 6)).facts
        XCTAssertEqual(dB(raised.peak) - dB(plain.peak), 6, accuracy: 0.5)
    }

    func testAutoLevelEditIsHeardWhenListening() throws {
        let tone = try makeTone(amplitude: 0.05)
        let gain = AutoLevel.gainDB(forPeak: 0.05)
        let plain = try record(seconds: 1.5, whilePlaying: tone).facts
        let levelled = try record(seconds: 1.5, whilePlaying: tone,
                                  edit: EditList(autoLevelEnabled: true, autoLevelDB: gain)).facts
        XCTAssertEqual(dB(levelled.peak) - dB(plain.peak), gain, accuracy: 0.6)
    }

    func testHalfTempoKeepsPitchAndTakesTwiceAsLong() throws {
        let tone = try makeTone(seconds: 2)
        var finished = false
        let capture = CaptureEngine()
        try requireMicrophone(capture)
        try capture.open(device: input)
        defer { capture.close() }
        let playback = PlaybackEngine()
        try playback.setOutput(output.id)
        try playback.load(url: tone, edit: EditList())
        playback.setTempo(0.5, pitchSemitones: 0)
        playback.onFinished = { finished = true }
        let url = folder.file("slow.wav")
        try capture.startRecording(to: url)
        let start = Date()
        try playback.play()
        while !finished, Date().timeIntervalSince(start) < 8 { wait(0.02) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(finished)
        XCTAssertEqual(elapsed, 4, accuracy: 0.5, "2 seconds of audio at 50 % take 4 seconds")
        capture.stopRecording()
        let facts = try readAudio(url)
        let rate = Int(facts.sampleRate)
        XCTAssertEqual(facts.frequency(from: rate, to: rate * 3), 1000, accuracy: 20, "tempo must not change pitch")
    }

    func testPitchShiftOfAnOctave() throws {
        let tone = try makeTone()
        let (_, facts) = try record(seconds: 1.5, whilePlaying: tone) { $0.setTempo(1, pitchSemitones: 12) }
        let quarter = Int(facts.frames) / 4
        XCTAssertEqual(facts.frequency(from: quarter, to: quarter * 3), 2000, accuracy: 40)
    }

    func testPositionFollowsPlaybackAtSlowerTempo() throws {
        let tone = try makeTone(seconds: 6)
        let playback = PlaybackEngine()
        try playback.setOutput(output.id)
        try playback.load(url: tone, edit: EditList())
        playback.setTempo(0.5, pitchSemitones: 0)
        try playback.play(from: 1)
        wait(2)
        XCTAssertEqual(playback.position, 2, accuracy: 0.3, "2 seconds at 50 % advance 1 second")
        playback.pause()
        let paused = playback.position
        wait(0.3)
        XCTAssertEqual(playback.position, paused, accuracy: 0.001, "pausing freezes the playhead")
    }

    func testLoopStaysInsideItsRange() throws {
        let tone = try makeTone(seconds: 6)
        let playback = PlaybackEngine()
        try playback.setOutput(output.id)
        try playback.load(url: tone, edit: EditList())
        playback.setLoop(2...2.5)
        try playback.play(from: 2)
        var positions: [Double] = []
        for _ in 0..<40 {
            wait(0.05)
            positions.append(playback.position)
        }
        playback.pause()
        XCTAssertTrue(playback.position >= 1.99)
        XCTAssertGreaterThanOrEqual(positions.min()!, 1.99)
        XCTAssertLessThanOrEqual(positions.max()!, 2.51)
        XCTAssertTrue(zip(positions, positions.dropFirst()).contains { $1 < $0 }, "the playhead must jump back at least once")
    }

    func testPlaybackStopsAtTrimEndAndReturnsToStart() throws {
        let tone = try makeTone(seconds: 6)
        var finished = false
        let playback = PlaybackEngine()
        try playback.setOutput(output.id)
        try playback.load(url: tone, edit: EditList(trimStart: 1, trimEnd: 1.5))
        playback.onFinished = { finished = true }
        try playback.play()
        let start = Date()
        while !finished, Date().timeIntervalSince(start) < 3 { wait(0.02) }
        XCTAssertTrue(finished)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(playback.position, 1, accuracy: 0.01)
    }

    func testPlaybackDoesNotDisturbRunningRecording() throws {
        let tone = try makeTone(seconds: 8)
        let capture = CaptureEngine()
        try requireMicrophone(capture)
        try capture.open(device: input)
        defer { capture.close() }
        let url = folder.file("busy.wav")
        try capture.startRecording(to: url)

        // Everything a user could do with the player during a recording, repeatedly.
        let playback = PlaybackEngine()
        try playback.setOutput(output.id)
        for round in 0..<8 {
            try playback.load(url: tone, edit: EditList(gainDB: Double(round)))
            try playback.play(from: Double(round % 3))
            wait(0.1)
            playback.setTempo(round % 2 == 0 ? 0.5 : 1, pitchSemitones: 0)
            playback.seek(to: 1)
            wait(0.1)
            playback.pause()
        }
        wait(0.2)
        let result = try XCTUnwrap(capture.stopRecording())

        XCTAssertEqual(result.droppedFrames, 0)
        XCTAssertNil(result.writeError)
        let rate = AudioDevices.currentRate(of: input.id)
        XCTAssertGreaterThan(result.seconds, 1.5)
        XCTAssertEqual(Double(try readAudio(url).frames) / rate, result.seconds, accuracy: 0.01)
    }

    func testLiveOverviewMatchesTheFile() throws {
        let tone = try makeTone(amplitude: 0.25)
        let capture = CaptureEngine()
        try requireMicrophone(capture)
        try capture.open(device: input)
        defer { capture.close() }
        let playback = PlaybackEngine()
        try playback.setOutput(output.id)
        try playback.load(url: tone, edit: EditList())
        try playback.play()
        wait(0.3)
        let url = folder.file("wave.wav")
        try capture.startRecording(to: url)
        var pairs: [Float] = []
        for _ in 0..<20 {
            wait(0.1)
            pairs += capture.readOverview()
        }
        let result = try XCTUnwrap(capture.stopRecording())
        pairs += capture.readOverview()
        playback.pause()

        XCTAssertTrue(result.overviewComplete)
        let live = WaveformData(binFrames: Int(CaptureEngine.overviewBinFrames), sampleRate: capture.sampleRate, pairs: pairs)
        let analyzed = try XCTUnwrap(AudioAnalyzer.analyze(url))
        XCTAssertEqual(live.binCount, analyzed.waveform.binCount)
        XCTAssertEqual(live.peak, analyzed.peak, accuracy: 0.001)
    }

    func testRetroBufferSavesWhatWasJustPlayed() throws {
        let tone = try makeTone(amplitude: 0.25)
        let capture = CaptureEngine()
        try requireMicrophone(capture)
        try capture.open(device: input, retroSeconds: 3)
        defer { capture.close() }
        let playback = PlaybackEngine()
        try playback.setOutput(output.id)
        try playback.load(url: tone, edit: EditList())
        try playback.play()
        wait(2)
        XCTAssertEqual(capture.retroAvailableSeconds, 2, accuracy: 0.3)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)

        let copy = try XCTUnwrap(capture.copyRetro(seconds: 1))
        playback.pause()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.path), before,
                       "the buffer stays in memory until explicitly saved")

        let url = folder.file("retro.wav")
        try WAVWriter.write(samples: copy.samples, sampleRate: copy.sampleRate, channels: copy.channels, to: url)
        let facts = try readAudio(url)
        XCTAssertEqual(Double(facts.frames) / facts.sampleRate, 1, accuracy: 0.01)
        XCTAssertEqual(facts.frequency(), 1000, accuracy: 15)
    }

    func testClickDoesNotReachTheFile() throws {
        // A second virtual output that does not loop back to BlackHole, so nothing audible plays during tests.
        guard let sink = AudioDevices.outputDevices().first(where: {
            !$0.name.contains("BlackHole") && !$0.identity.isBuiltIn && !$0.name.lowercased().contains("spark")
                && $0.transport == kAudioDeviceTransportTypeVirtual
        }) else {
            throw XCTSkip("no second virtual output available")
        }
        let capture = CaptureEngine()
        try requireMicrophone(capture)
        try capture.open(device: input)
        defer { capture.close() }
        let click = ClickEngine()
        try click.start(device: sink.id, settings: MetronomeSettings(bpm: 240, beatsPerBar: 4, volume: 1))
        defer { click.stop() }
        let url = folder.file("click.wav")
        try capture.startRecording(to: url)
        wait(1.5)
        let result = try XCTUnwrap(capture.stopRecording())

        XCTAssertGreaterThan(click.beatCount, 3, "the click must really have run")
        XCTAssertGreaterThan(result.frames, 0)
        XCTAssertEqual(try readAudio(url).peak, 0, "the file must stay digitally silent")
    }

    func testLoopbackProbeRecognizesARealLoop() async throws {
        let (input, output) = (self.input!, self.output!)
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("no microphone permission for the test process")
        }
        let measurement = try await MainActor.run {
            Task { try await LoopbackProbe.measure(input: input, output: output.id, seconds: 0.5) }
        }.value
        XCTAssertTrue(measurement.outputReachesInput, "BlackHole loops output to input by design")
    }

    func testGateStartsTheFileAtTheRequestedMoment() throws {
        let capture = CaptureEngine()
        try requireMicrophone(capture)
        try capture.open(device: input)
        defer { capture.close() }
        let url = folder.file("gate.wav")
        let gate = AudioGetCurrentHostTime() + UInt64(AudioGetHostClockFrequency() * 0.5)
        try capture.startRecording(to: url, gateHostTime: gate)
        wait(0.25)
        XCTAssertEqual(capture.recordedFrames, 0, "nothing before the gate")
        wait(0.75)
        let result = try XCTUnwrap(capture.stopRecording())
        XCTAssertEqual(result.seconds, 0.5, accuracy: 0.15)
    }

    func testRemovedDeviceEndsRecordingAndKeepsAudio() throws {
        // A private aggregate around BlackHole can be destroyed mid-recording, like a pulled cable.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SparkRecorder Test Device",
            kAudioAggregateDeviceUIDKey: "local.sparkrecorder.test.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: input.uid]],
        ]
        var aggregate = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else { throw XCTSkip("could not create an aggregate device (\(status))") }
        var destroyed = false
        defer { if !destroyed { AudioHardwareDestroyAggregateDevice(aggregate) } }
        wait(0.5)

        guard let device = AudioDevices.inputDevices().first(where: { $0.id == aggregate }) else {
            throw XCTSkip("the aggregate device did not appear as input")
        }
        let capture = CaptureEngine()
        try requireMicrophone(capture)
        var interruption: CaptureInterruption?
        capture.onInterrupted = { interruption = $0 }
        try capture.open(device: device)
        defer { capture.close() }
        let url = folder.file("pulled.wav")
        try capture.startRecording(to: url)
        wait(1.5)
        let framesBefore = capture.recordedFrames
        XCTAssertGreaterThan(framesBefore, 0)

        XCTAssertEqual(AudioHardwareDestroyAggregateDevice(aggregate), noErr)
        destroyed = true
        let start = Date()
        while interruption == nil, Date().timeIntervalSince(start) < 3 { wait(0.05) }
        XCTAssertEqual(interruption, .deviceLost, "the loss must be noticed")

        let result = try XCTUnwrap(capture.stopRecording())
        XCTAssertGreaterThanOrEqual(result.frames, framesBefore)
        guard case .ok(_, let frames) = WAVFile.inspect(url) else { return XCTFail("expected a finalized file") }
        XCTAssertEqual(frames, result.frames, "everything recorded up to the loss must be in the file")
    }
}
