import AVFoundation
import Foundation
import SparkCore

/// Hears the Spark's USB input around and while the amp's own tuner runs, to learn what the amp's tuner value means.
///
/// It only reads: the input is opened at its current rate, nothing is recorded or written, and no audio leaves the
/// process. The USB pitch is sampled every 20 ms in phases: before the tuner is on, while it is on, after it is off.
@MainActor
final class TunerCompare {
    enum Phase: String, CaseIterable { case before, during, after }

    struct Heard {
        let midi: Int
        let cents: Double
    }

    private struct Record {
        var samples = 0
        var receiving = 0
        var loudest = -120.0
        var heard: [Heard] = []
        var amp: [(note: UInt8, value: Float)] = []
        /// Amp readings paired with the USB pitch of the same moment.
        var pairs: [(amp: Float, heard: Heard, sameNote: Bool)] = []
    }

    private let capture = CaptureEngine(inputPolicy: .sparkOnly)
    private let engine = TunerEngine()
    private var records: [Phase: Record] = [:]
    private var poller: Task<Void, Never>?
    var phase = Phase.before
    let deviceName: String

    init() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw ProbeFailure("no microphone access for SparkProbe.app (System Settings → Privacy → Microphone)")
        }
        guard let device = AudioDevices.inputDevices().first(where: { InputPolicy.sparkOnly.allows($0) }) else {
            throw ProbeFailure("no Spark USB input found, plug the amp in by USB")
        }
        deviceName = device.name
        try capture.open(device: device, raiseRate: false)
        capture.attach(engine.tap)
        engine.start()
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private var steady: Heard? {
        let snapshot = engine.snapshot
        guard snapshot.hasSignal, let reading = snapshot.reading, !reading.isHeld,
              let uncertainty = reading.uncertainty, uncertainty < 5 else { return nil }
        let note = Note.nearest(to: reading.frequency, a4: 440)
        return Heard(midi: note.midi, cents: note.cents(of: reading.frequency, a4: 440))
    }

    private func sample() {
        let snapshot = engine.snapshot
        var record = records[phase, default: Record()]
        record.samples += 1
        if snapshot.isReceiving { record.receiving += 1 }
        record.loudest = max(record.loudest, snapshot.levelDB)
        if let steady { record.heard.append(steady) }
        records[phase] = record
    }

    func note(ampNote: UInt8, value: Float?) {
        guard let value else { return }
        var record = records[phase, default: Record()]
        record.amp.append((ampNote, value))
        if let steady {
            record.pairs.append((value, steady, Int(ampNote) == ((steady.midi % 12) + 12) % 12))
        }
        records[phase] = record
    }

    func close() {
        poller?.cancel()
        engine.stop()
        capture.detach(engine.tap)
        capture.close()
    }

    private static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "H"]

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .nan : sorted[sorted.count / 2]
    }

    func summarize() {
        log("\nUSB input (\(deviceName)), sampled every 20 ms:")
        for phase in Phase.allCases {
            let record = records[phase, default: Record()]
            log(String(format: "  %@: receiving %d of %d, loudest %.0f dBFS, steady pitch %d×",
                       phase.rawValue, record.receiving, record.samples, record.loudest, record.heard.count))
            for midi in Set(record.heard.map(\.midi)).sorted() {
                let cents = record.heard.filter { $0.midi == midi }.map(\.cents)
                guard cents.count >= 10 else { continue }
                let note = Note(midi: midi)
                log(String(format: "    %@%d: %d×, median %+.1f ct, %+.1f to %+.1f", note.name(), note.octave,
                           cents.count, Self.median(cents), cents.min() ?? 0, cents.max() ?? 0))
            }
            for note in Set(record.amp.map(\.note)).sorted() {
                let values = record.amp.filter { $0.note == note }.map { Double($0.value) }
                guard values.count >= 10 else { continue }
                let name = Int(note) < Self.names.count ? Self.names[Int(note)] : "note \(note)"
                let settled = Self.settled(record.amp, note: note)
                log(String(format: "    amp %@: %d×, median %.3f, %.3f to %.3f; settled %d×, median %.3f", name,
                           values.count, Self.median(values), values.min() ?? 0, values.max() ?? 0, settled.count,
                           Self.median(settled)))
            }
            let same = record.pairs.filter(\.sameNote)
            if same.count >= 10 { Self.fit(same.map { ($0.heard.cents, Double($0.amp)) }) }
        }
    }

    /// The values of a note inside runs of at least 12 readings in a row, without the first 6 of each run: the attack
    /// and a change of string are left out.
    private static func settled(_ readings: [(note: UInt8, value: Float)], note: UInt8) -> [Double] {
        var result: [Double] = [], run: [Double] = []
        func close() {
            if run.count >= 12 { result += run.dropFirst(6) }
            run = []
        }
        for reading in readings {
            if reading.note == note { run.append(Double(reading.value)) } else { close() }
        }
        close()
        return result
    }

    /// A straight line `value = a + b · cents` through pairs heard at the same moment.
    private static func fit(_ points: [(Double, Double)]) {
        let n = Double(points.count)
        let mx = points.map(\.0).reduce(0, +) / n, my = points.map(\.1).reduce(0, +) / n
        let sxx = points.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
        let sxy = points.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        guard sxx > 0 else { return }
        let slope = sxy / sxx, intercept = my - slope * mx
        log(String(format: "    pairs: %d, fit value = %.4f + %.5f · cents", points.count, intercept, slope))
    }
}
