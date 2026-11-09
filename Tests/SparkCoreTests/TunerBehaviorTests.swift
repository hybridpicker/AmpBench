import CSparkRT
import XCTest
@testable import SparkCore

/// How the tuner behaves over time: new attacks, a peg being turned, the gate, the hold, and the shared input.
/// Synthetic signals only.
final class TunerBehaviorTests: XCTestCase {
    private let rate = 48_000.0
    private typealias Accuracy = TunerAccuracyTests

    private func string(_ frequency: Double, seconds: Double, seed: UInt64 = 7) -> [Float] {
        TunerTestSignal.karplusStrong(frequency: frequency, sampleRate: rate, seconds: seconds, seed: seed)
    }

    // MARK: Smoothing and response

    /// A new string played while the first still rings: the reading moves to it quickly, without passing through
    /// an octave of either.
    func testNewAttackMovesToTheNewNoteQuickly() {
        let first = string(82.41, seconds: 1.5)
        let second = string(110, seconds: 1.5, seed: 9)
        var signal = first + [Float](repeating: 0, count: second.count)
        for index in second.indices { signal[first.count + index] += second[index] * 1.4 }
        let (tracker, timeline) = Accuracy.track(TunerTestSignal.addingNoise(signal, decibels: -40), sampleRate: rate)
        XCTAssertGreaterThanOrEqual(tracker.attackCount, 2, "both attacks were noticed")
        let switchTime = 1.5
        let arrived = timeline.first { $0.time > switchTime && $0.reading.map { abs(Accuracy.cents($0.frequency, 110)) < 5 } == true }
        XCTAssertNotNil(arrived)
        XCTAssertLessThan((arrived?.time ?? 99) - switchTime, 0.15, "the new note shows within 150 ms")
        for sample in timeline where sample.time > switchTime {
            guard let reading = sample.reading else { continue }
            let nearFirst = abs(Accuracy.cents(reading.frequency, 82.41)) < 50
            let nearSecond = abs(Accuracy.cents(reading.frequency, 110)) < 50
            XCTAssertTrue(nearFirst || nearSecond, "an unrelated value \(reading.frequency) Hz at \(sample.time) s")
        }
    }

    /// A peg turned, 20 cents in a second: the reading follows at most 150 ms behind, and settles soon after the
    /// peg stops.
    func testFollowsATurningPegAndSettles() {
        let target = 110.0, seconds = 3.0
        let count = Int(seconds * rate)
        var phase = 0.0
        var truth = [Double](repeating: 0, count: count)
        var signal = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let time = Double(index) / rate
            let cents = time < 0.5 ? -20 : time < 1.5 ? -20 + 20 * (time - 0.5) : 0
            let frequency = target * pow(2, cents / 1200)
            truth[index] = frequency
            phase += 2 * .pi * frequency / rate
            signal[index] = Float(0.3 * sin(phase) + 0.1 * sin(2 * phase + 0.3) + 0.05 * sin(3 * phase))
        }
        let (_, timeline) = Accuracy.track(TunerTestSignal.addingNoise(signal, decibels: -30), sampleRate: rate)
        for sample in timeline where sample.time > 0.8 && sample.time < 1.5 {
            guard let reading = sample.reading else { continue }
            let earlier = truth[Int((sample.time - 0.15) * rate)]
            XCTAssertLessThan(abs(Accuracy.cents(reading.frequency, earlier)), 2, "lags behind at \(sample.time) s")
        }
        let settled = Accuracy.errors(timeline, truth: target, from: 2, to: 3)
        XCTAssertLessThanOrEqual(settled.map(abs).max() ?? .infinity, 0.2, "settled half a second after the peg stopped")
        let soon = Accuracy.errors(timeline, truth: target, from: 1.75, to: 3)
        XCTAssertLessThanOrEqual(soon.map(abs).max() ?? .infinity, 0.5, "within half a cent 0.25 s after the peg stopped")
    }

    /// The last value stays for a moment after the string is stopped, marked as held, then goes.
    func testLastValueStaysBrieflyAfterTheToneEnds() {
        let signal = string(196, seconds: 1) + TunerTestSignal.silence(sampleRate: rate, seconds: 3)
        let (_, timeline) = Accuracy.track(signal, sampleRate: rate)
        let held = timeline.filter { $0.time > 1.1 && $0.time < 2.3 }
        XCTAssertFalse(held.isEmpty)
        XCTAssertTrue(held.allSatisfy { $0.reading?.isHeld == true }, "held for over a second")
        XCTAssertLessThan(abs(Accuracy.cents(held.last?.reading?.frequency ?? 0, 196)), 0.5, "with the right value")
        XCTAssertTrue(timeline.filter { $0.time > 3 }.allSatisfy { $0.reading == nil }, "and then it goes")
    }

    /// The first 20 ms of an attack are left out: a loud click before the tone does not reach the reading.
    func testAttackTransientIsLeftOut() {
        var generator = SeededGenerator(seed: 4)
        let click = (0..<Int(0.008 * rate)).map { _ in Float(generator.uniform() * 1.6 - 0.8) }
        let tone = TunerTestSignal.sawtooth(frequency: 146.83, sampleRate: rate, seconds: 1.5, decay: 2)
        var signal = TunerTestSignal.silence(sampleRate: rate, seconds: 0.2) + tone
        for index in click.indices { signal[Int(0.2 * rate) + index] += click[index] }
        let (_, timeline) = Accuracy.track(signal, sampleRate: rate)
        let readings = timeline.compactMap(\.reading)
        XCTAssertFalse(readings.isEmpty)
        XCTAssertTrue(readings.allSatisfy { abs(Accuracy.cents($0.frequency, 146.83)) < 30 }, "no value from the click")
    }

    /// Noise alone, silence, and a tone below the gate never give a value.
    func testNoValueWithoutATone() {
        var generator = SeededGenerator(seed: 1)
        let noise = (0..<Int(2 * rate)).map { _ in Float(0.1 * generator.gaussian()) }
        let quiet = TunerTestSignal.sine(frequency: 220, sampleRate: rate, seconds: 1, amplitude: 0.0005)
        for signal in [noise, TunerTestSignal.silence(sampleRate: rate, seconds: 1), quiet] {
            let (_, timeline) = Accuracy.track(signal, sampleRate: rate)
            XCTAssertTrue(timeline.allSatisfy { $0.reading == nil })
        }
        let (tracker, _) = Accuracy.track(quiet, sampleRate: rate)
        XCTAssertFalse(tracker.hasSignal, "−66 dBFS stays below the gate")
    }

    /// A DC offset on the input, as some interfaces have, does not hide the pitch.
    func testOffsetDoesNotHideThePitch() {
        let signal = TunerTestSignal.sine(frequency: 82.41, sampleRate: rate, seconds: 1.5, amplitude: 0.2).map { $0 + 0.3 }
        let (_, timeline) = Accuracy.track(signal, sampleRate: rate)
        XCTAssertLessThanOrEqual(Accuracy.errors(timeline, truth: 82.41, from: 1, to: 1.5).map(abs).max() ?? .infinity, 0.1)
    }

    // MARK: Tunings and notes

    func testEveryStringOfEveryTuningIsFound() {
        for tuning in Tuning.allCases where tuning != .chromatic {
            var interpreter = TunerInterpreter(tuning: tuning)
            for (index, note) in tuning.strings.enumerated() {
                let off = note.frequency(a4: 440) * pow(2, 12.0 / 1200)
                let readout = interpreter.interpret(PitchReading(frequency: off, uncertainty: 0.05), time: 0)
                XCTAssertEqual(readout?.note, note, "\(tuning.title) string \(6 - index)")
                XCTAssertEqual(readout?.string, 6 - index)
                XCTAssertEqual(readout?.cents ?? 0, 12, accuracy: 1e-9)
                XCTAssertEqual(readout?.direction, .high)
            }
        }
    }

    func testTuningsAreWhatTheyAreCalled() {
        XCTAssertEqual(Tuning.standard.summary, "E A D G H E")
        XCTAssertEqual(Tuning.dropD.summary, "D A D G H E")
        XCTAssertEqual(Tuning.dadgad.summary, "D A D G A D")
        XCTAssertEqual(Tuning.openG.summary, "D G D G H D")
        XCTAssertEqual(Tuning.halfStepDown.summary, "E♭ A♭ D♭ G♭ B E♭")
        XCTAssertEqual(Tuning.chromatic.summary, "Alle Töne")
        XCTAssertEqual(Tuning.standard.strings.first?.frequency(a4: 440) ?? 0, 82.4069, accuracy: 0.0001)
        XCTAssertEqual(Tuning.dropD.strings.first?.frequency(a4: 440) ?? 0, 73.4162, accuracy: 0.0001)
    }

    func testFarFromEveryStringFallsBackToTheNearestNote() {
        var interpreter = TunerInterpreter(tuning: .standard)
        // A bass's low E, an octave below the guitar's.
        let readout = interpreter.interpret(PitchReading(frequency: 41.2), time: 0)
        XCTAssertNil(readout?.string)
        XCTAssertEqual(readout?.noteName, "E")
        XCTAssertEqual(readout?.note.octave, 1)
    }

    func testChromaticNamesInGerman() {
        var interpreter = TunerInterpreter(tuning: .chromatic)
        let cases: [(Double, String, Int)] = [(30.868, "H", 0), (246.94, "H", 3), (233.08, "A♯", 3), (440, "A", 4),
                                              (277.18, "C♯", 4), (1396.91, "F", 6)]
        for (frequency, name, octave) in cases {
            let readout = interpreter.interpret(PitchReading(frequency: frequency), time: 0)
            XCTAssertEqual(readout?.noteName, name, "\(frequency)")
            XCTAssertEqual(readout?.note.octave, octave, "\(frequency)")
            XCTAssertLessThan(abs(readout?.cents ?? 99), 0.1)
        }
        XCTAssertEqual(Note(midi: 70).name(flats: true), "B")
        XCTAssertEqual(Note(midi: 63).spokenName(flats: true), "Es")
        XCTAssertEqual(Note(midi: 66).spokenName(), "Fis")
    }

    func testConcertPitchMovesEveryTarget() {
        var interpreter = TunerInterpreter(tuning: .chromatic, a4: 442)
        XCTAssertEqual(interpreter.interpret(PitchReading(frequency: 442), time: 0)?.cents ?? 9, 0, accuracy: 1e-9)
        XCTAssertEqual(interpreter.interpret(PitchReading(frequency: 440), time: 0)?.cents ?? 0, -7.85, accuracy: 0.01)
        interpreter.a4 = 430.5
        XCTAssertEqual(Note(midi: 69).frequency(a4: interpreter.a4), 430.5)
        XCTAssertEqual(TunerInterpreter.a4Range, 430...450)
    }

    func testNoteStaysPutAtTheBorderBetweenTwo() {
        var interpreter = TunerInterpreter(tuning: .chromatic)
        let a = Note(midi: 57).frequency(a4: 440)
        XCTAssertEqual(interpreter.interpret(PitchReading(frequency: a * pow(2, 45 / 1200.0)), time: 0)?.noteName, "A")
        // 55 cents above A is nearer to A♯, but the A stays until the tone is clearly nearer the next note.
        XCTAssertEqual(interpreter.interpret(PitchReading(frequency: a * pow(2, 55 / 1200.0)), time: 0.1)?.noteName, "A")
        XCTAssertEqual(interpreter.interpret(PitchReading(frequency: a * pow(2, 65 / 1200.0)), time: 0.2)?.noteName, "A♯")
    }

    func testInTuneNeedsTimeAndPrecision() {
        var interpreter = TunerInterpreter(tuning: .standard)
        let e = 82.4069
        let near = PitchReading(frequency: e * pow(2, 0.3 / 1200), uncertainty: 0.05)
        XCTAssertEqual(interpreter.interpret(near, time: 0)?.isInTune, false)
        XCTAssertEqual(interpreter.interpret(near, time: 0.3)?.isInTune, false)
        XCTAssertEqual(interpreter.interpret(near, time: 0.45)?.isInTune, true)
        // 0.8 cents off is no longer in tune, at once.
        XCTAssertEqual(interpreter.interpret(PitchReading(frequency: e * pow(2, 0.8 / 1200), uncertainty: 0.05), time: 0.5)?.isInTune, false)
        // Close, but measured too roughly to tell.
        var rough = TunerInterpreter(tuning: .standard)
        let vague = PitchReading(frequency: e, uncertainty: 0.6)
        _ = rough.interpret(vague, time: 0)
        XCTAssertEqual(rough.interpret(vague, time: 1)?.isInTune, false)
    }

    func testTextOfTheNumbers() {
        XCTAssertEqual(TunerText.cents(0.34), "+0,3")
        XCTAssertEqual(TunerText.cents(-12.04), "−12,0")
        XCTAssertEqual(TunerText.cents(-0.04), "±0,0")
        XCTAssertEqual(TunerText.cents(49.96), "+50,0")
        XCTAssertEqual(TunerText.hertz(82.4069), "82,41")
        XCTAssertEqual(TunerText.hertz(440, digits: 1), "440,0")
        XCTAssertEqual(TunerText.spokenCents(-2.25), "minus 2,3 Cent")
    }

    // MARK: The shared input

    func testTapAveragesChannelsAndKeepsOrder() {
        let tap = AudioTap(capacityFrames: 1024)
        tap.beginForTesting(sampleRate: 48_000)
        tap.write([0.2, 0.4, -1, 1, 0.5, 0.5], channels: 2)
        var output = [Float](repeating: 9, count: 8)
        let count = output.withUnsafeMutableBufferPointer { tap.read(into: $0) }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(Array(output.prefix(3)), [0.3, 0, 0.5].map { Float($0) }, accuracy: 1e-6)
        XCTAssertEqual(tap.sampleRate, 48_000)
    }

    func testTapDropsTheNewestWhenTheReaderFallsBehind() {
        let tap = AudioTap(capacityFrames: 1024)
        XCTAssertEqual(tap.capacity, 1024)
        tap.write((0..<1000).map { Float($0) })
        tap.write((1000..<1100).map { Float($0) })
        XCTAssertEqual(tap.overruns, 76)
        var output = [Float](repeating: 0, count: 2048)
        let count = output.withUnsafeMutableBufferPointer { tap.read(into: $0) }
        XCTAssertEqual(count, 1024)
        XCTAssertEqual(output[1023], 1023, "the oldest stayed in order")
    }

    func testTapEpochChangesWithEveryStream() {
        let tap = AudioTap()
        let before = tap.epoch
        tap.beginForTesting(sampleRate: 44_100)
        XCTAssertNotEqual(tap.epoch, before)
        tap.write([1, 2, 3])
        tap.skip()
        var output = [Float](repeating: 0, count: 4)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { tap.read(into: $0) }, 0)
    }

    /// The capture callback writes into an attached tap, besides everything it did before, and stops once it is
    /// cleared. The file, the retro buffer and the level are untouched by it.
    func testCaptureWritesIntoAnAttachedTapOnly() {
        let capture = spark_capture_create(2, 4096, rate, 4096, 0, 256, nil)
        defer { spark_capture_destroy(capture) }
        let tap = AudioTap(capacityFrames: 4096)
        tap.beginForTesting(sampleRate: rate)
        spark_capture_process(capture, [0.5, 0.5], 1, 0)
        spark_capture_set_tap(capture, tap.pointer)
        spark_capture_process(capture, [0.2, 0.6, -0.4, 0], 2, 0)
        XCTAssertTrue(spark_capture_clear_tap(capture))
        spark_capture_process(capture, [0.9, 0.9], 1, 0)
        var output = [Float](repeating: 0, count: 8)
        let count = output.withUnsafeMutableBufferPointer { tap.read(into: $0) }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Array(output.prefix(2)), [0.4, -0.2].map { Float($0) }, accuracy: 1e-6)
        XCTAssertEqual(spark_capture_retro_available_frames(capture), 4, "the retro buffer got every frame")
        XCTAssertEqual(spark_capture_take_level(capture), 0.9, accuracy: 1e-6)
    }

    /// The engine reads the tap on its own thread and finds the string.
    func testEngineFindsAStringFromTheTap() {
        let engine = TunerEngine(tap: AudioTap())
        engine.tap.beginForTesting(sampleRate: rate)
        engine.start()
        defer { engine.stop() }
        let signal = string(110, seconds: 1.2)
        let chunk = Int(0.01 * rate)
        var offset = 0
        let deadline = Date().addingTimeInterval(5)
        while offset < signal.count && Date() < deadline {
            engine.tap.write(Array(signal[offset..<min(offset + chunk, signal.count)]))
            offset += chunk
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.05)
        let snapshot = engine.snapshot
        XCTAssertTrue(snapshot.hasSignal)
        XCTAssertEqual(snapshot.sampleRate, rate)
        XCTAssertLessThan(abs(Accuracy.cents(snapshot.reading?.frequency ?? 0, 110)), 0.5)
    }
}

private func XCTAssertEqual(_ first: [Float], _ second: [Float], accuracy: Float,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(first.count, second.count, file: file, line: line)
    for (a, b) in zip(first, second) { XCTAssertEqual(a, b, accuracy: accuracy, file: file, line: line) }
}
