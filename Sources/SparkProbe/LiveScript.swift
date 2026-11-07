import Foundation
import SparkControl

/// `spark-probe live <1-4> <script>`: plays a copy of a stored preset on the temporary place, then runs a script of
/// changes against it. Nothing is stored. After each `read`, the probe compares what the amp plays with what the
/// changes sent so far should have made of it.
///
/// Script lines, `place` is 1 to 7 or a model id, `noinput` leaves out the trailing input byte:
///
///     say <text>                            print a cue for whoever listens
///     wait <seconds>                        listen and print what the amp sends
///     param <place> <index> <value> [noinput]
///     toggle <place> on|off [noinput]
///     model <place> <model id> [noinput]
///     sweep <place> <index> <from> <to> <steps> <milliseconds> [noinput]
///     read                                  read the playing preset and compare
///     resend                                send the expected preset again, as a whole
///     raw <command> <sub> <hex bytes>       send any single-chunk message, then listen for a second
@MainActor
struct LiveScript {
    let link: ProbeLink
    var expected: SparkPreset
    var input = true

    static func run(_ link: ProbeLink, slot: UInt8, lines: [String], input: Bool) async throws {
        let stored = try await link.readPreset(slot).preset
        log("\nPlaying a copy of stored preset \(slot + 1) on the temporary place. Nothing is stored.")
        let playing = try await link.playTemporarily(stored)
        let first = differences(stored, playing)
        log(first.isEmpty ? "  ✓ the temporary preset is the stored one"
                          : "  the amp plays it with these differences:\n    " + first.joined(separator: "\n    "))
        var script = LiveScript(link: link, expected: playing, input: input)
        for (number, line) in lines.enumerated() {
            let words = line.split(separator: " ").map(String.init)
            guard let command = words.first, !command.hasPrefix("#") else { continue }
            log("\n[\(number + 1)] \(line)")
            try await script.perform(command, Array(words.dropFirst()))
        }
    }

    mutating func perform(_ command: String, _ arguments: [String]) async throws {
        let input = !arguments.contains("noinput") && self.input
        let arguments = arguments.filter { $0 != "noinput" }
        let header = link.header
        switch command {
        case "say":
            log("▶ " + arguments.joined(separator: " "))
        case "wait":
            await link.listen(Double(arguments.first ?? "2") ?? 2)
        case "param":
            guard arguments.count == 3, let index = UInt8(arguments[1]), let value = Float(arguments[2]) else {
                throw ProbeFailure("param <place> <index> <value>")
            }
            let effect = try effectName(arguments[0])
            try await link.send("set \(effect) parameter \(index) to \(value)\(input ? "" : " without input byte")") {
                [SparkProtocol.setParameter(effect: effect, index: index, value: value, input: input, sequence: $0,
                                            header: header)]
            }
            expected.apply(.parameter(effect: effect, index: index, value: value))
        case "sweep":
            guard arguments.count == 6, let index = UInt8(arguments[1]), let from = Float(arguments[2]),
                  let to = Float(arguments[3]), let steps = Int(arguments[4]), steps > 1,
                  let milliseconds = Int(arguments[5]) else {
                throw ProbeFailure("sweep <place> <index> <from> <to> <steps> <milliseconds>")
            }
            let effect = try effectName(arguments[0])
            log("→ sweep \(effect) parameter \(index) from \(from) to \(to) in \(steps) steps, every \(milliseconds) ms")
            for step in 0..<steps {
                let value = from + (to - from) * Float(step) / Float(steps - 1)
                if step > 0 { try await Task.sleep(for: .milliseconds(milliseconds)) }
                try link.sendNow {
                    SparkProtocol.setParameter(effect: effect, index: index, value: value, input: input,
                                               sequence: $0, header: header)
                }
            }
            expected.apply(.parameter(effect: effect, index: index, value: to))
        case "toggle":
            guard arguments.count == 2, ["on", "off"].contains(arguments[1]) else {
                throw ProbeFailure("toggle <place> on|off")
            }
            let effect = try effectName(arguments[0])
            let on = arguments[1] == "on"
            // The amp confirms with 04 15, at times with 03 15 instead, so both count.
            _ = try await link.request("switch \(effect) \(arguments[1])", answer: SparkProtocol.Sub.effectOnOff) {
                [SparkProtocol.setEffect(effect, on: on, input: input, sequence: $0, header: header)]
            }
            expected.apply(.effectOnOff(effect: effect, isOn: on))
        case "model":
            guard arguments.count == 2 else { throw ProbeFailure("model <place> <model id>") }
            let old = try effectName(arguments[0])
            let new = arguments[1]
            _ = try await link.request("change \(old) to \(new)", answer: SparkProtocol.Sub.changeEffect) {
                [SparkProtocol.changeModel(from: old, to: new, input: input, sequence: $0, header: header)]
            }
            expected.apply(.modelChanged(from: old, to: new))
        case "read":
            let playing = try await link.readPreset(nil).preset
            // The checksum byte follows the content and is not compared on its own.
            var plain = playing, wanted = expected
            plain.trailer = Array(plain.trailer.dropLast())
            wanted.trailer = Array(wanted.trailer.dropLast())
            let lines = differences(wanted, plain)
            log(lines.isEmpty ? "  ✓ the amp plays exactly what was sent"
                              : "  differences from what was sent:\n    " + lines.joined(separator: "\n    "))
            expected = playing
        case "resend":
            expected = try await link.playTemporarily(expected)
        case "raw":
            guard arguments.count >= 2, let command = UInt8(arguments[0], radix: 16),
                  let sub = UInt8(arguments[1], radix: 16) else {
                throw ProbeFailure("raw <command> <sub> <hex bytes>")
            }
            let bytes = try arguments.dropFirst(2).map {
                guard let byte = UInt8($0, radix: 16) else { throw ProbeFailure("\($0) is not a hex byte") }
                return byte
            }
            try await link.send("raw \(arguments.joined(separator: " "))") {
                [SparkProtocol.frame(command: command, sub: sub, payload: bytes, sequence: $0, header: header)]
            }
            await link.listen(1)
        default:
            throw ProbeFailure("Unknown script command \"\(command)\".")
        }
    }

    /// A place of the chain, 1 to 7, or a model id that is in the expected preset.
    private func effectName(_ text: String) throws -> String {
        if let place = Int(text), (1...expected.effects.count).contains(place) {
            return expected.effects[place - 1].name
        }
        guard expected.effectIndex(named: text) != nil else {
            throw ProbeFailure("The preset has no place or model \"\(text)\".")
        }
        return text
    }
}
