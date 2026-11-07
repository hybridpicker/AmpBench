import Foundation
import SparkControl

// spark-probe: an experimental test tool for the Spark's Bluetooth LE control channel.
//
// It only shows and connects to devices with "Spark" in their name. Other Bluetooth devices nearby are counted but
// never printed. Nothing leaves this Mac.

let usage = """
    usage: spark-probe <command> [options]

    commands:
      scan            look for Spark amps for 10 seconds
      info            connect, list services, read firmware, name and the presets
      preset <1-4>    switch to a stored preset, like the preset button on the amp
      try <1-4>       send a copy of a stored preset, renamed, to play without storing it
      store-test <1-4> <backup.json>
                      back up a stored preset, store a renamed copy in its slot, read it back, then put the
                      original back and check it is byte for byte the same
      persist-test store <1-4> <backup.json>
                      back up a stored preset and leave a renamed copy in its slot, to switch the amp off and on
      persist-test check <1-4> <backup.json>
                      check whether the copy survived, then put the original back
      live <1-4> <script|->
                      play a copy of a stored preset without storing it and run a script of live changes on it,
                      see Sources/SparkProbe/LiveScript.swift
      watch [secs]    connect and print what the amp sends, default 30 seconds

    options:
      --raw           also print every byte sent and received
      --no-header     send messages without the 16-byte block header
      --no-input      leave the trailing input byte out of live changes

    The Spark app on the phone and Spark Presets must be disconnected, the amp accepts only one control connection.
    """

enum Mode {
    case scan, info, watch(Double), preset(UInt8), audition(UInt8), storeTest(UInt8, String)
    case persistStore(UInt8, String), persistCheck(UInt8, String), live(UInt8, [String])
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(64)
}

func slotArgument(_ text: String?) -> UInt8? {
    text.flatMap(UInt8.init).flatMap { (1...4).contains($0) ? $0 - 1 : nil }
}

func parseMode(_ arguments: [String]) -> Mode {
    let first = arguments.first, second = arguments.dropFirst().first
    switch (first, arguments.count) {
    case ("scan", 1): return .scan
    case ("info", 1): return .info
    case ("watch", 1): return .watch(30)
    case ("watch", 2):
        guard let seconds = Double(second!), seconds > 0 else { break }
        return .watch(seconds)
    case ("preset", 2):
        guard let slot = slotArgument(second) else { break }
        return .preset(slot)
    case ("try", 2):
        guard let slot = slotArgument(second) else { break }
        return .audition(slot)
    case ("store-test", 3):
        guard let slot = slotArgument(second) else { break }
        return .storeTest(slot, arguments[2])
    case ("persist-test", 4):
        guard let slot = slotArgument(arguments[2]) else { break }
        if second == "store" { return .persistStore(slot, arguments[3]) }
        if second == "check" { return .persistCheck(slot, arguments[3]) }
    case ("live", 3):
        guard let slot = slotArgument(second) else { break }
        let source = arguments[2]
        let text: String?
        if source == "-" {
            text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
        } else {
            text = try? String(contentsOfFile: source, encoding: .utf8)
        }
        guard let text else { fail("Cannot read the script \(source).") }
        return .live(slot, text.components(separatedBy: .newlines))
    default:
        break
    }
    fail(usage)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var raw = false, header = true, input = true
arguments.removeAll { argument in
    switch argument {
    case "--raw": raw = true
    case "--no-header": header = false
    case "--no-input": input = false
    default: return false
    }
    return true
}
let mode = parseMode(arguments)

Task { @MainActor in
    let link = ProbeLink(raw: raw, header: header)
    if case .scan = mode {
        exit(await link.scan() ? 0 : 1)
    }
    var code: Int32 = 0
    do {
        if case .info = mode { try await link.connect(listServices: true) } else { try await link.connect() }
        switch mode {
        case .scan: break
        case .info: try await Commands.info(link)
        case .watch(let seconds): await Commands.watch(link, seconds: seconds)
        case .preset(let slot): try await Commands.preset(link, slot: slot)
        case .audition(let slot): try await Commands.audition(link, slot: slot)
        case .storeTest(let slot, let path): try await Commands.storeTest(link, slot: slot, backup: path)
        case .persistStore(let slot, let path): try await Commands.persistStore(link, slot: slot, backup: path)
        case .persistCheck(let slot, let path): try await Commands.persistCheck(link, slot: slot, backup: path)
        case .live(let slot, let lines): try await LiveScript.run(link, slot: slot, lines: lines, input: input)
        }
        log("\nDone. \(link.hiddenTuner) tuner reading(s) hidden.")
    } catch {
        log("\n✗ \(error)")
        code = 1
    }
    await link.disconnect()
    exit(code)
}
dispatchMain()
