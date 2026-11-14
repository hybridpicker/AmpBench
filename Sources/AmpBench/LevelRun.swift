import AppKit
import Foundation
import SparkCore

/// `--level-measure <plan.json> <results.json>` measures how loud sounds are on the amp: it plays each sound of the
/// plan on the amp's temporary place, one after the other, and reads the loudness of what comes back over USB while
/// someone keeps playing the guitar. Nothing is stored on the amp and no preset file is changed.
///
/// The plan is a list of `{"label": …, "file": <path of a preset file>}`. The results repeat the label with the
/// loudness in LUFS (nil when nothing was heard), the peak in dBFS and how much of the time counted. Each sound gets
/// `--level-seconds` (default 5) after a pause for the amp to switch; sounds follow each other slowly on purpose,
/// because a quick run of model changes once made the amp hang.
@MainActor
enum LevelRun {
    struct Entry: Decodable {
        var label: String
        var file: String
    }

    struct Reading: Encodable {
        var label: String
        var file: String
        var lufs: Double?
        var peakDBFS: Double?
        var keptShare: Double
        var seconds: Double
        var problem: String?
    }

    static var isRequested: Bool { CommandLine.arguments.contains("--level-measure") }

    static func startIfRequested(_ studio: Studio) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--level-measure"), index + 2 < arguments.count else { return }
        let plan = URL(fileURLWithPath: arguments[index + 1]), output = URL(fileURLWithPath: arguments[index + 2])
        let seconds = arguments.firstIndex(of: "--level-seconds").flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 5
        Task {
            let problem = await run(studio, plan: plan, output: output, seconds: min(max(seconds, 2), 30))
            if let problem { say("FAILED: \(problem)") }
            if arguments.contains("--quit") { NSApp.terminate(nil) }
        }
    }

    private static func say(_ text: String) {
        print(text)
        fflush(stdout)
    }

    private static func run(_ studio: Studio, plan: URL, output: URL, seconds: Double) async -> String? {
        guard let data = try? Data(contentsOf: plan), let entries = try? JSONDecoder().decode([Entry].self, from: data),
              !entries.isEmpty else { return "the plan cannot be read" }
        studio.show(.presets)
        studio.presets.startLinkOnce()
        say("Waiting for the amp …")
        guard await until(seconds: 60, { studio.presets.connection == .connected }) else {
            return "the amp did not connect (\(studio.presets.connectionText))"
        }
        // The amp reads its slots after connecting; a sound sent into that would be refused as busy.
        try? await Task.sleep(for: .seconds(4))

        let tap = AudioTap(capacityFrames: 262_144)
        let input = studio.recorder.sharedInput
        do { try await input.share(with: tap) } catch { return "the USB input cannot be opened: \(error.localizedDescription)" }
        defer { input.stopSharing(with: tap) }
        guard await until(seconds: 5, { tap.sampleRate > 0 }) else { return "the USB input delivers nothing" }
        say("Listening to \(input.device?.name ?? "the input") at \(Int(tap.sampleRate)) Hz. Keep playing.")

        var readings: [Reading] = []
        var buffer = [Float](repeating: 0, count: 16_384)
        for (number, entry) in entries.enumerated() {
            var reading = Reading(label: entry.label, file: entry.file, keptShare: 0, seconds: 0)
            if let sound = try? Data(contentsOf: URL(fileURLWithPath: entry.file)) {
                reading.problem = await play(sound, on: studio)
            } else {
                reading.problem = "the file cannot be read"
            }
            if reading.problem == nil {
                // The amp switches within a second; the tail of the sound before must not count.
                try? await Task.sleep(for: .seconds(1.5))
                tap.skip()
                var meter = Loudness(sampleRate: tap.sampleRate)
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    let count = buffer.withUnsafeMutableBufferPointer { tap.read(into: $0) }
                    if count > 0 { buffer.withUnsafeBufferPointer { meter.add(UnsafeBufferPointer(rebasing: $0[0..<count])) } }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                reading.lufs = meter.integrated
                reading.peakDBFS = meter.peak > 0 ? 20 * log10(Double(meter.peak)) : nil
                reading.keptShare = meter.keptShare
                reading.seconds = meter.measuredSeconds
            }
            readings.append(reading)
            let level = reading.lufs.map { String(format: "%6.1f LUFS", $0) } ?? "   silent"
            say(String(format: "%3d/%d  %@  %@%@", number + 1, entries.count, level, entry.label,
                       reading.problem.map { "  (\($0))" } ?? ""))
            // After every sound, so a run that is broken off keeps what it has.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(readings).write(to: output, options: .atomic)
        }
        say("Done: \(readings.filter { $0.lufs != nil }.count) of \(entries.count) measured.")
        return nil
    }

    /// Plays the sound on the temporary place and waits for the amp's answer. Tries again while the amp is busy.
    private static func play(_ sound: Data, on studio: Studio) async -> String? {
        var problem: String?
        for _ in 0..<4 {
            problem = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                var answered = false
                studio.presets.play(snapshot: sound) { result in
                    guard !answered else { return }
                    answered = true
                    continuation.resume(returning: result)
                }
            }
            if problem == nil { return nil }
            try? await Task.sleep(for: .seconds(2))
        }
        return problem
    }

    private static func until(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }
}
