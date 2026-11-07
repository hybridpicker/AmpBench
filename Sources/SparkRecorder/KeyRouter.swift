import AppKit
import SparkCore

/// Handles the single-key shortcuts. They run ahead of the normal key handling so a focused table cannot swallow
/// them, and they step aside whenever text is being typed. None of them can delete anything.
@MainActor
final class KeyRouter {
    private var monitor: Any?
    private weak var model: AppModel?

    private(set) static var shared: KeyRouter?
    /// Lets the self-test act on the window while the screen is locked, when no window can become key.
    static var windowOverride: NSWindow?
    static var activeWindow: NSWindow? { NSApp.keyWindow ?? windowOverride }

    init(model: AppModel) {
        self.model = model
        Self.shared = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) ? nil : event }
        }
    }

    static var isEditingText: Bool {
        activeWindow?.firstResponder is NSText
    }

    /// AppKit gives the first text field the focus when a window opens, which would turn the first R into a search
    /// for "r" instead of a recording. The window starts without a focused field.
    static func releaseInitialFocus() {
        for delay in [0.0, 0.2, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard let window = activeWindow ?? NSApp.mainWindow, window.firstResponder is NSText else { return }
                    window.makeFirstResponder(nil)
                }
            }
        }
    }

    /// Esc leaves any text field, Return leaves a single-line one, so the shortcuts work again right away.
    private func handleLeavingTextField(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView else { return false }
        switch event.keyCode {
        case 53:
            window.makeFirstResponder(nil)
            return true
        case 36, 76:
            guard editor.isFieldEditor else { return false }
            // Return still reaches the field first, so it can commit its text.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if window.firstResponder === editor { window.makeFirstResponder(nil) }
                }
            }
            return false
        default:
            return false
        }
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }
        if let window = Self.activeWindow, window.isMainWindow || window === Self.windowOverride,
           handleLeavingTextField(event, in: window) {
            return true
        }
        guard let window = Self.activeWindow, !Self.isEditingText, window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return false }
        // Popovers and other panels keep their own keys. Only the main window is routed.
        guard window.isMainWindow || window === Self.windowOverride else { return false }

        // Left and right arrows move through the take. Up and down stay with the table.
        switch event.keyCode {
        case 123:
            model.nudge(by: modifiers.contains(.shift) ? -1 : -5)
            return true
        case 124:
            model.nudge(by: modifiers.contains(.shift) ? 1 : 5)
            return true
        default:
            break
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return false }
        // Space activates the focused control for people who navigate by keyboard or VoiceOver. A running recording
        // goes first: space ends it and plays the new take, whatever has the focus. R and VoiceOver's own keys still work.
        if key == " ", model.phase == .idle, NSApp.isFullKeyboardAccessEnabled, window.firstResponder is NSButton {
            return false
        }

        switch key {
        case "r": model.toggleRecord()
        case " ": model.spaceBarPressed()
        case "l": model.toggleLoop()
        case "m": model.addMarker()
        case "k": model.keep()
        case "f": model.toggleFavorite()
        case "b": model.switchCompare()
        case "n": model.toggleClick()
        case "t": model.tap()
        case "g": model.saveRetro()
        case "1", "2", "3", "4", "5": model.setRating(Int(key) ?? 0)
        case "+": model.setTempo(model.tempo + 0.05)
        case "-": model.setTempo(model.tempo - 0.05)
        case "0": model.resetTempoAndPitch()
        default:
            // A focused device picker would jump to the device starting with that letter, so "s" could silently
            // switch the input to the Spark. Stray letters must not change anything about a recording setup.
            return window.firstResponder is NSPopUpButton && key.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        }
        return true
    }
}
