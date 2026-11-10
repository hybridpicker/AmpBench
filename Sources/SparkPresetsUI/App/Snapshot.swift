import AmpText
import AppKit
import SparkControl
import SparkDesign
import SwiftUI

/// Pictures of AmpBench's own window with the area Presets, for checking the design, without screen recording
/// permission and without ever seeing anything but this window. Only runs when started with `--snapshot`:
///
///     AmpBench --library /tmp/test --offline --appearance dark --size 1180x780 --open template:Crunch \
///                 --focus drive --snapshot /tmp/shot.png [--delay 2] [--quit]
///
/// `--offline` leaves Bluetooth off, `--library <test folder>` keeps made-up presets in its subfolder "Presets".
/// `--demo-devices [neo|mini|reactor]` (only with `--library`) shows simulated devices instead of Bluetooth and
/// connects to the one named; a REACTOR then reports a few made-up control changes.
/// `--open` takes `template:<name>`, `empty`, `slot:<1-4>` or `saved:<file name>`.
@MainActor
enum Snapshot {
    static var arguments: [String: String] {
        var values: [String: String] = [:]
        let list = CommandLine.arguments
        for (index, argument) in list.enumerated() where argument.hasPrefix("--") {
            let next = index + 1 < list.count && !list[index + 1].hasPrefix("--") ? list[index + 1] : ""
            values[String(argument.dropFirst(2))] = next
        }
        return values
    }

    static var isOffline: Bool { arguments["offline"] != nil }
    /// The window to size and draw, set by AmpBench.
    static weak var window: NSWindow?
    private static var target: NSWindow? { window ?? NSApp.windows.first(where: { $0.isVisible }) }
    /// A test folder for presets, so pictures never show one's own presets. A new, empty one gets the templates as
    /// made-up presets and one backup.
    static func seededTestFolder(_ folder: URL) -> URL {
        let library = PresetLibrary(folder: folder)
        try? library.reload()
        if library.items.isEmpty {
            for template in PresetFactory.templates {
                try? library.save(template.preset, origin: tr("Template"))
            }
            if let first = PresetFactory.templates.first {
                try? library.save(first.preset, origin: tr("Slot %d", 2), isBackup: true)
            }
        }
        return folder
    }
    /// Window pictures skip the sidebar's translucent material, so it gets a plain background then.
    static let isActive = CommandLine.arguments.contains("--snapshot")

    static func prepare() {
        switch arguments["appearance"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    static func run(_ model: PresetsModel) async {
        let values = arguments
        guard values["snapshot"] != nil || values["open"] != nil || values["size"] != nil else { return }
        try? await Task.sleep(for: .milliseconds(600))
        if let size = values["size"], let window = target {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                window.center()
            }
        }
        await demoDevice(values["demo-devices"], in: model)
        // A Kemper file in the import sheet, or imported right away (only into a test library).
        if let path = values["kemper"], !path.isEmpty {
            model.showsKemperImport = true
            model.loadKemperPlan(URL(fileURLWithPath: path))
            if values["kemper-import"] != nil {
                model.performKemperImport()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        open(values["open"], in: model)
        if let focus = values["focus"], let place = ChainPlace.allCases.first(where: { "\($0)" == focus }) {
            model.editor.focus = place
        }
        guard let path = values["snapshot"], !path.isEmpty else { return }
        try? await Task.sleep(for: .seconds(Double(values["delay"] ?? "") ?? 1.5))
        write(to: URL(fileURLWithPath: path))
        // An open sheet would hold up quitting.
        if values["quit"] != nil {
            model.closeKemperImport()
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
        }
    }

    private static func demoDevice(_ name: String?, in model: PresetsModel) async {
        guard let name, let simulated = model.link.simulated else { return }
        let kind: SimulatedDevice.Kind = switch name {
        case "mini": .mini
        case "reactor": .reactor
        default: .neo
        }
        model.link.choose(simulated.id(kind))
        func ready() -> Bool {
            model.link.status == .connected && simulated.connected == simulated.id(kind) && model.link.activity == nil
                && (!model.link.profile.can(.read) || model.link.slots.allSatisfy { $0 != nil })
        }
        for _ in 0..<200 where !ready() { try? await Task.sleep(for: .milliseconds(50)) }
        guard kind == .reactor else { return }
        simulated.pressButton(5)
        simulated.report(ReactorState.ampSelector, [3, 6])
        for (block, index, value) in [("Amp.Preamp", 0, 0.62), ("Amp.Tonestack", 1, 0.45), ("Amp.Tonestack", 3, 0.7),
                                      ("Amp.Poweramp", 0, 0.5)] as [(String, UInt8, Float)] {
            simulated.report(SparkProtocol.Sub.parameterChanged, SimulatedDevice.parameterPayload(block, index, value))
        }
        simulated.report(SparkProtocol.Sub.effectOnOff, SimulatedDevice.onOffPayload("MonoReverb", true))
        simulated.report(ReactorState.selectedEffect, [6, 0xC3])
        simulated.report(SparkProtocol.Sub.parameterChanged, SimulatedDevice.parameterPayload("MonoReverb", 0, 0.35))
        simulated.report(SparkProtocol.Sub.effectOnOff, SimulatedDevice.onOffPayload("DistortionTS9", true))
        simulated.report(SparkProtocol.Sub.tapTempo, [0xCA] + withUnsafeBytes(of: Float(96).bitPattern.bigEndian, Array.init))
        try? await Task.sleep(for: .milliseconds(300))
    }

    private static func open(_ what: String?, in model: PresetsModel) {
        guard let what else { return }
        let parts = what.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "empty": model.newPreset()
        case "template":
            model.newPreset(from: PresetFactory.templates.first { $0.name == parts.last })
        case "slot":
            if let number = Int(parts.last ?? ""), model.link.profile.slots.contains(number - 1) {
                model.select(.slot(number - 1))
            }
        case "saved":
            if let item = model.items.first(where: { $0.url.deletingPathExtension().lastPathComponent == parts.last }) {
                model.select(.saved(item.url))
            }
        default: break
        }
    }

    /// Draws the window's content into a PNG. Translucent materials, such as the sidebar's, are left out.
    static func write(to url: URL) {
        // The content only, like the recorder's pictures: the toolbar's translucent material would come out white.
        // "--sheet" draws the sheet in front, such as the Kemper import, instead of the window.
        let window = arguments["sheet"] != nil ? target?.attachedSheet : target
        guard let window, let view = window.contentView, let data = WindowPicture.png(of: view) else {
            FileHandle.standardError.write(Data("No window to draw.\n".utf8))
            return
        }
        do {
            try data.write(to: url)
            print("Snapshot written to \(url.path)")
        } catch {
            FileHandle.standardError.write(Data("Could not write the snapshot.\n".utf8))
        }
    }
}
