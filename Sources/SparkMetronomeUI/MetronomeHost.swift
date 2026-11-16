import AmpText
import SparkCore
import SwiftUI

/// The metronome inside AmpBench: its content, its menus, and starting and stopping from outside (Space).
///
/// It keeps playing while another area shows, so a sound can be changed while counting; a recording or a take
/// playing with its click stops it, because those use the same tempo for their own click.
@MainActor
public final class MetronomeHost: ObservableObject {
    let model: MetronomeModel

    public init(tempo: MetronomeTempo) {
        model = MetronomeModel(tempo: tempo)
    }

    /// The area "Metronome".
    public var content: AnyView { AnyView(MetronomeView(model: model)) }

    public var isRunning: Bool { model.isRunning }
    public func toggle() { model.toggle() }
    public func stop() { model.stop() }
    public func tap() { model.tap() }
}

public struct MetronomeMenus: Commands {
    @ObservedObject private var model: MetronomeModel
    private let isActive: Bool

    public init(_ host: MetronomeHost, isActive: Bool) {
        model = host.model
        self.isActive = isActive
    }

    public var body: some Commands {
        CommandMenu(tr("Metronome")) {
            // Space starts and stops it in its area; the menu item works from everywhere.
            Button(model.isRunning ? tr("Stop the metronome") : tr("Start the metronome")) { model.toggle() }
                .keyboardShortcut(KeyboardShortcut("m", modifiers: [.command, .control]))
            Divider()
            Button(tr("Tap tempo")) { model.tap() }
                .keyboardShortcut(owned(KeyboardShortcut("t", modifiers: .command)))
                .disabled(!isActive)
            Button(tr("1 BPM faster")) { model.nudge(1) }
                .keyboardShortcut(owned(KeyboardShortcut(.upArrow, modifiers: .command)))
                .disabled(!isActive)
            Button(tr("1 BPM slower")) { model.nudge(-1) }
                .keyboardShortcut(owned(KeyboardShortcut(.downArrow, modifiers: .command)))
                .disabled(!isActive)
            Button(tr("10 BPM faster")) { model.nudge(10) }
                .keyboardShortcut(owned(KeyboardShortcut(.upArrow, modifiers: [.command, .shift])))
                .disabled(!isActive)
            Button(tr("10 BPM slower")) { model.nudge(-10) }
                .keyboardShortcut(owned(KeyboardShortcut(.downArrow, modifiers: [.command, .shift])))
                .disabled(!isActive)
            Divider()
            Toggle(tr("Tempo trainer"), isOn: Binding(get: { model.settings.trainer.isOn },
                                                      set: { on in model.update { $0.trainer.isOn = on } }))
                .disabled(!isActive)
        }
    }

    private func owned(_ shortcut: KeyboardShortcut) -> KeyboardShortcut? {
        isActive ? shortcut : nil
    }
}
