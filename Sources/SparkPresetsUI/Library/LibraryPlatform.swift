import SwiftUI

/// What the library does differently on the Mac and the iPad, so its views do not ask which platform they are on.
enum LibraryPlatform {
    /// Return (and a double click) hears the selected sound on the Mac. On the iPad a tap selects, and the key in the
    /// preview hears; there is no keycap to show then.
    static var hearKeycap: String? {
        #if os(macOS)
        "↩"
        #else
        nil
        #endif
    }
}

extension View {
    /// The table's context menu, and on the Mac its primary action: a double click or Return. On the iPad a tap must
    /// stay a selection, so there is no primary action there.
    @ViewBuilder
    func libraryRowActions<Menu: View>(@ViewBuilder menu: @escaping (Set<String>) -> Menu,
                                       primary: @escaping (Set<String>) -> Void) -> some View {
        #if os(macOS)
        contextMenu(forSelectionType: String.self, menu: menu, primaryAction: primary)
        #else
        contextMenu(forSelectionType: String.self, menu: menu)
        #endif
    }
}
