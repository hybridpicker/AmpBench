import SparkControl
import SwiftUI

@main
struct PresetsApp: App {
    @StateObject private var model = PresetsModel()

    var body: some Scene {
        Window("Spark Presets", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.link)
                .frame(minWidth: 820, minHeight: 560)
                .task { model.start() }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Verstärker") {
                ForEach(0..<4, id: \.self) { slot in
                    Button("Platz \(slot + 1) spielen") { model.play(slot: slot) }
                        .keyboardShortcut(KeyEquivalent(Character("\(slot + 1)")), modifiers: .command)
                        .disabled(!model.canUseAmp)
                }
                Divider()
                Button("Ausgewählten Platz auf dem Mac sichern") { model.backUpSelection() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.selectedSlot == nil)
                Button("Ausgewähltes Preset ausprobieren") { model.tryOutSelection() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(model.selectedItem == nil || !model.canUseAmp)
                Divider()
                Button("Verstärker neu lesen") { model.reloadAmp() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.canUseAmp)
            }
            CommandGroup(after: .pasteboard) {
                Button("Umbenennen …") { model.beginRename() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.selectedItem == nil)
                Button("In den Papierkorb") { model.trash() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedItem == nil)
                Button("Im Finder zeigen") { model.reveal() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
