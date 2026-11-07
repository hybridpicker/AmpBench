import SwiftUI

/// Shows a building block on the desk in light and in dark mode side by side, for `#Preview`.
struct PreviewPair<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.desk.windowBackground)
                .environment(\.colorScheme, .light)
            content()
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.desk.windowBackground)
                .environment(\.colorScheme, .dark)
        }
    }
}
