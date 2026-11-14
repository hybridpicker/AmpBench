import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few system styles the Mac and the iPad name differently. Views use these, so no view asks which platform
/// it is on.
extension View {
    /// A button that reads as a link in running text.
    @ViewBuilder
    public func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// A toggle shown as a checkbox on the Mac and as the system's switch on the iPad.
    @ViewBuilder
    public func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch)
        #endif
    }

    /// A plain list inside a sheet, with striped rows where the system has them.
    @ViewBuilder
    public func stripedListStyle() -> some View {
        #if os(macOS)
        listStyle(.inset(alternatesRowBackgrounds: true))
        #else
        listStyle(.plain)
        #endif
    }
}

extension Color {
    /// The background of a control such as a list, as the system draws it.
    public static var systemControlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    /// The system's color for secondary labels.
    public static var systemSecondaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .secondaryLabelColor)
        #else
        Color(uiColor: .secondaryLabel)
        #endif
    }
}

/// The system's pasteboard, for the two things the app copies: a text, and a secret.
public enum Clipboard {
    /// Copies a secret such as a key. Clipboard managers that honor the "concealed" mark skip it on the Mac; on the
    /// iPad it leaves the pasteboard again after two minutes. Handoff to one's other devices still works, which is
    /// how a key gets from the Mac to the iPad.
    @MainActor
    public static func copySecret(_ text: String) {
        #if os(macOS)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        #else
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]],
                                      options: [.expirationDate: Date().addingTimeInterval(120)])
        #endif
    }
}

extension View {
    /// On the iPad, shows content made for a width of at least `designWidth` scaled down when there is less room,
    /// such as in portrait or beside another app, so nothing is cut off. On the Mac the window has a smallest size
    /// instead, and this does nothing.
    @ViewBuilder
    public func fittedOnPad(designWidth: CGFloat) -> some View {
        #if os(macOS)
        self
        #else
        GeometryReader { geometry in
            let scale = min(1, geometry.size.width / designWidth)
            self
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        #endif
    }

    /// On the iPad, a sheet as large as its content, as every sheet is on the Mac. Without this an iPad sheet has one
    /// fixed size, which cuts off wide content and leaves short content floating in the middle.
    @ViewBuilder
    public func fittedSheetOnPad() -> some View {
        #if os(macOS)
        self
        #else
        if #available(iOS 18, *) {
            presentationSizing(.fitted)
        } else {
            frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        #endif
    }

    /// On the iPad, a detail column without its navigation bar: the area has its own header, and the bar would
    /// only be an empty band. On the Mac this does nothing.
    @ViewBuilder
    public func withoutNavigationBarOnPad() -> some View {
        #if os(macOS)
        self
        #else
        toolbar(.hidden, for: .navigationBar)
        #endif
    }
}
