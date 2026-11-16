import CSparkRT
import XCTest
@testable import SparkCore

/// The practice metronome's renderer, offline: where every pulse lies, how its sound starts, and that neither the
/// block sizes nor hours of playing move anything.
final class MetronomeTests: XCTestCase {
    private struct Run {
        var samples: [Float] = []
        var events: [SparkMetronomeEvent] = []
    }

    /// Renders `seconds` with blocks of the given sizes in turn, applying `changes` (at an output frame) on the way.
    private func render(_ settings: MetronomeSettings, rate: Double = 48000, seconds: Double,
                        blocks: [Int] = [512], keepSamples: Bool = true,
                        changes: [(frame: Int, settings: MetronomeSettings)] = [],
                        hostTime: (Int) -> UInt64 = { _ in 0 }, latency: Double = 0) -> Run {
        let metronome = spark_metronome_create(rate)
        defer { spark_metronome_destroy(metronome) }
        spark_metronome_set_output_latency(metronome, latency)
        var config = MetronomeEngine.config(for: settings)
        spark_metronome_configure(metronome, &config)
        var run = Run()
        let total = Int(seconds * rate)
        var done = 0
        var blockIndex = 0
        var pending = changes
        var buffer = [Float](repeating: 0, count: blocks.max()!)
        while done < total {
            if let change = pending.first, change.frame <= done {
                var next = MetronomeEngine.config(for: change.settings)
                spark_metronome_configure(metronome, &next)
                pending.removeFirst()
            }
            let frames = min(blocks[blockIndex % blocks.count], total - done)
            blockIndex += 1
            buffer.withUnsafeMutableBufferPointer { pointer in
                let channels: [UnsafeMutablePointer<Float>?] = [pointer.baseAddress]
                spark_metronome_render(metronome, channels, 1, UInt32(frames), hostTime(done))
            }
            if keepSamples { run.samples.append(contentsOf: buffer[0..<frames]) }
            var event = SparkMetronomeEvent()
            while spark_metronome_next_event(metronome, &event) { run.events.append(event) }
            done += frames
        }
        return run
    }

    func testEveryBeatLiesExactlyOnItsFrameForHours() {
        // 97 BPM at 44.1 kHz: an interval of 27278.35… frames, never a whole number.
        let settings = MetronomeSettings(bpm: 97, beatsPerBar: 4)
        let interval = 44100 * 60 / 97.0
        let run = render(settings, rate: 44100, seconds: 2 * 3600, blocks: [512, 37, 1024, 4096, 1],
                         keepSamples: false)
        XCTAssertGreaterThan(run.events.count, 11_000)
        var worst = 0.0
        for (index, event) in run.events.enumerated() {
            worst = max(worst, abs(event.frame - Double(index) * interval))
            XCTAssertEqual(Int(event.beat), index % 4)
            XCTAssertEqual(Int(event.bar), index / 4)
        }
        XCTAssertLessThan(worst, 1e-6, "no beat moves by even a millionth of a frame after two hours")
    }

    func testTheSoundDoesNotDependOnTheBlockSize() {
        var settings = MetronomeSettings(bpm: 133, beatsPerBar: 7)
        settings.pattern.subdivision = .triplets
        settings.pattern.sound = .wood
        let small = render(settings, seconds: 20, blocks: [64, 7, 333])
        let large = render(settings, seconds: 20, blocks: [4096])
        XCTAssertEqual(small.samples.count, large.samples.count)
        let worst = zip(small.samples, large.samples).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-5)
    }

    func testAClickStartsAtTheFractionOfAFrameWhereItsBeatLies() {
        // 100 BPM at 48 kHz with sixteenths: pulses every 7200 frames; 133 BPM: every 5413.53… frames.
        let rate = 48000.0
        let settings = MetronomeSettings(bpm: 133, beatsPerBar: 4, volume: 1)
        let run = render(settings, rate: rate, seconds: 3)
        let second = run.events[1]
        XCTAssertEqual(second.frame, rate * 60 / 133, accuracy: 1e-9)
        let first = Int(second.frame.rounded(.up))
        // The classic sound on a normal beat: 1175 Hz, 12 ms decay, level 0.7.
        for n in first..<(first + 40) {
            let t = (Double(n) - second.frame) / rate
            let expected = 0.7 * sin(2 * Double.pi * 1175 * t) * exp(-t / 0.012)
            XCTAssertEqual(Double(run.samples[n]), expected, accuracy: 2e-5, "sample \(n)")
        }
        // Nothing before it but the decay of the first click, long gone.
        XCTAssertEqual(run.samples[first - 1], 0, accuracy: 1e-6)
    }

    func testSubdivisionsLieBetweenTheBeats() {
        var settings = MetronomeSettings(bpm: 100, beatsPerBar: 3)
        settings.pattern.subdivision = .triplets
        let run = render(settings, seconds: 10, blocks: [300])
        let interval = 48000 * 60 / 100.0 / 3
        for (index, event) in run.events.enumerated() {
            XCTAssertEqual(event.frame, Double(index) * interval, accuracy: 1e-9)
            XCTAssertEqual(Int(event.sub), index % 3)
            XCTAssertEqual(Int(event.beat), (index / 3) % 3)
        }
    }

    func testAccentsSoftAndMutedBeats() {
        var settings = MetronomeSettings(bpm: 120, beatsPerBar: 4, volume: 1)
        settings.pattern.levels = [.accent, .normal, .soft, .mute]
        let run = render(settings, seconds: 2.1)
        func peak(_ beat: Int) -> Float {
            let start = beat * 24000
            return run.samples[start..<(start + 2000)].map(abs).max() ?? 0
        }
        XCTAssertEqual(peak(0), 1.0, accuracy: 0.02)
        XCTAssertEqual(peak(1), 0.7, accuracy: 0.02)
        XCTAssertEqual(peak(2), 0.4, accuracy: 0.02)
        XCTAssertEqual(peak(3), 0, accuracy: 1e-6)
        XCTAssertEqual(run.events.filter { $0.bar == 0 }.count, 4, "a muted beat is still counted")
    }

    func testTheTrainerRaisesTheTempoOnBarLinesUpToItsTarget() {
        var settings = MetronomeSettings(bpm: 100, beatsPerBar: 4)
        settings.trainer = TempoTrainer(isOn: true, stepBPM: 5, everyBars: 2, targetBPM: 112)
        let run = render(settings, seconds: 60, blocks: [480, 17])
        // Expected positions, bar by bar, from the trainer's own rule.
        var frame = 0.0
        var expected: [(Double, Double)] = []
        for bar in 0..<40 {
            let bpm = settings.trainer.tempo(afterBars: bar, from: 100)
            for _ in 0..<4 {
                expected.append((frame, bpm))
                frame += 48000 * 60 / bpm
            }
        }
        for (event, (position, bpm)) in zip(run.events, expected) {
            XCTAssertEqual(event.bpm, bpm, "bar \(event.bar)")
            XCTAssertEqual(event.frame, position, accuracy: 1e-6, "bar \(event.bar) beat \(event.beat)")
        }
        XCTAssertEqual(run.events.last?.bpm, 112, "it stops at the target")
        XCTAssertEqual(settings.trainer.tempo(afterBars: 4, from: 100), 110)
        XCTAssertEqual(settings.trainer.tempo(afterBars: 6, from: 100), 112)
    }

    func testTheTrainerCanSlowDownToo() {
        let trainer = TempoTrainer(isOn: true, stepBPM: 4, everyBars: 1, targetBPM: 90)
        XCTAssertEqual(trainer.tempo(afterBars: 2, from: 100), 92)
        XCTAssertEqual(trainer.tempo(afterBars: 5, from: 100), 90)
        var settings = MetronomeSettings(bpm: 100)
        settings.trainer = trainer
        XCTAssertLessThan(MetronomeEngine.config(for: settings).trainer_step, 0)
    }

    func testANewTempoStartsOnTheNextBeatNotInTheMiddleOfOne() {
        var settings = MetronomeSettings(bpm: 120, beatsPerBar: 4)
        settings.pattern.subdivision = .eighths
        var faster = settings
        faster.bpm = 150
        // Changed a little after the first eighth between beats 1 and 2.
        let run = render(settings, seconds: 4, blocks: [256], changes: [(frame: 36_100, settings: faster)])
        let beatAt120 = 24000.0
        // Beat 2 (index 4: beats 0, 0+, 1, 1+, 2) still comes on the old grid.
        XCTAssertEqual(run.events[4].frame, 2 * beatAt120, accuracy: 1e-9)
        XCTAssertEqual(run.events[3].bpm, 120)
        XCTAssertEqual(run.events[4].bpm, 150, "from beat 2 on the new tempo")
        XCTAssertEqual(run.events[5].frame - run.events[4].frame, 48000 * 60 / 150.0 / 2, accuracy: 1e-9)
    }

    func testFewerBeatsPerBarStartANewBar() {
        let settings = MetronomeSettings(bpm: 120, beatsPerBar: 4)
        var three = settings
        three.beatsPerBar = 3
        let run = render(settings, seconds: 4, blocks: [256], changes: [(frame: 3 * 24000 + 100, settings: three)])
        // Beats 0 1 2 3 of bar 0, then the change lands on the next beat: bar 1 with three beats.
        XCTAssertEqual(run.events.prefix(7).map { Int($0.beat) }, [0, 1, 2, 3, 0, 1, 2])
        XCTAssertEqual(Int(run.events[4].bar), 1)
    }

    func testPulsesKnowWhenTheyAreHeard() {
        let settings = MetronomeSettings(bpm: 120, beatsPerBar: 4)
        let ticksPerFrame = MetronomeEngine.hostTicksPerSecond / 48000
        let latency = 0.010
        let run = render(settings, seconds: 2, blocks: [512],
                         hostTime: { frame in UInt64(1_000_000_000 + Double(frame) * ticksPerFrame) },
                         latency: latency)
        for event in run.events {
            let heard = Double(event.host_time) / MetronomeEngine.hostTicksPerSecond
            let expected = (1_000_000_000 + event.frame * ticksPerFrame) / MetronomeEngine.hostTicksPerSecond + latency
            XCTAssertEqual(heard, expected, accuracy: 1e-6)
        }
    }

    func testOldSettingsGetTheDefaultPattern() throws {
        let old = #"{"bpm":101,"beatsPerBar":3,"volume":0.5,"countInBars":1,"clickEnabled":true}"#
        let settings = try JSONDecoder().decode(MetronomeSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.bpm, 101)
        XCTAssertEqual(settings.levels, [.accent, .normal, .normal])
        XCTAssertEqual(settings.pattern.subdivision, .quarters)
        XCTAssertFalse(settings.trainer.isOn)
        let again = try JSONDecoder().decode(MetronomeSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(again, settings)
    }

    func testABeatLampCyclesItsLevel() {
        let pattern = MetronomePattern()
        let changed = pattern.setting(MetronomePattern.Level.accent.next, at: 0, beats: 4)
        XCTAssertEqual(changed.levels(for: 4), [.normal, .normal, .normal, .normal])
        XCTAssertEqual(MetronomePattern.Level.mute.next, .accent)
    }
}
