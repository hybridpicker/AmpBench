import SparkCore
import SwiftUI

/// The tuner inside Spark Studio: its content, its menus, and when it may listen.
///
/// Studio calls `setActive(true)` while the area shows in a visible window, and `false` otherwise; only then is an
/// input open for it. The input is the recorder's, given as `SharedInput`, or another one the user picks.
@MainActor
public final class TunerHost: ObservableObject {
    let model: TunerModel

    public init(input: SharedInput, defaults: UserDefaults = .standard) {
        model = TunerModel(shared: input, defaults: defaults)
    }

    /// The area "Stimmgerät".
    public var content: AnyView { AnyView(TunerView(model: model)) }

    public func setActive(_ active: Bool) {
        model.setActive(active)
    }

    public var isListening: Bool { model.status == .listening }

    /// A synthetic string for the window pictures of a test library: the tuner shows it as if one played it. With
    /// `strobe`, the strobe shows instead of the needle.
    public func showDemo(frequency: Double, strobe: Bool) {
        model.showsStrobe = strobe
        model.startDemo(frequency: frequency)
    }

    public func endDemo() {
        model.endDemo()
        model.showsStrobe = false
    }
}

/// The menu "Stimmgerät". While another area shows, its keys rest and its items are dimmed.
public struct TunerMenus: Commands {
    @ObservedObject private var model: TunerModel
    private let isActive: Bool

    public init(_ host: TunerHost, isActive: Bool) {
        model = host.model
        self.isActive = isActive
    }

    public var body: some Commands {
        CommandMenu("Stimmgerät") {
            Toggle("Stroboskop", isOn: $model.showsStrobe)
                .keyboardShortcut(owned(KeyboardShortcut("t", modifiers: .command)))
                .disabled(!isActive)
            Divider()
            Button("Kammerton 0,1 Hz höher") { model.a4 += 0.1 }
                .keyboardShortcut(owned(KeyboardShortcut(.upArrow, modifiers: .command)))
                .disabled(!isActive || model.a4 >= TunerInterpreter.a4Range.upperBound)
            Button("Kammerton 0,1 Hz tiefer") { model.a4 -= 0.1 }
                .keyboardShortcut(owned(KeyboardShortcut(.downArrow, modifiers: .command)))
                .disabled(!isActive || model.a4 <= TunerInterpreter.a4Range.lowerBound)
            Button("Kammerton 440 Hz") { model.a4 = TunerInterpreter.defaultA4 }
                .keyboardShortcut(owned(KeyboardShortcut("0", modifiers: .command)))
                .disabled(!isActive || model.a4 == TunerInterpreter.defaultA4)
            Divider()
            ForEach(Array(Tuning.allCases.enumerated()), id: \.element) { index, tuning in
                Toggle(tuning.title, isOn: Binding(get: { model.tuning == tuning }, set: { if $0 { model.tuning = tuning } }))
                    .keyboardShortcut(owned(KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)))
                    .disabled(!isActive)
            }
        }
    }

    /// A shortcut that belongs to this menu only while its area shows.
    private func owned(_ shortcut: KeyboardShortcut) -> KeyboardShortcut? {
        isActive ? shortcut : nil
    }
}
