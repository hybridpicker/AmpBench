#if os(iOS)
import AmpText
import SparkDesign
import SparkPresetsUI
import SparkTunerUI
import SwiftUI

/// AmpBench for the iPad. The Xcode project in `ios/` holds only the bundle around it and calls `PadApp.main()`.
public struct PadApp: App {
    @StateObject private var studio = PadStudio.shared
    @Environment(\.scenePhase) private var phase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            PadRootView(studio: studio, presets: studio.presets)
                // Always dark, like the Mac app: the desk too, not only the device.
                .preferredColorScheme(.dark)
                .tint(Theme.device.amber.color)
                .onChange(of: phase, initial: true) { _, phase in studio.isInFront = phase == .active }
        }
        .commands { PadCommands(studio: studio) }
    }
}

/// The menus a keyboard shows on the iPad: the Mac's, minus the recorder's. Keys both areas use act in the one in
/// front.
struct PadCommands: Commands {
    @ObservedObject var studio: PadStudio

    var body: some Commands {
        PresetMenus(studio.presets, isActive: studio.area == .presets)
        TunerMenus(studio.tuner, isActive: studio.area == .tuner)
        CommandGroup(before: .toolbar) {
            ForEach(PadArea.allCases) { area in
                Button(area.title) { studio.area = area }
                    .keyboardShortcut(KeyEquivalent(Character("\(area.digit)")), modifiers: [.command, .shift])
            }
            Divider()
        }
    }
}

/// A slim bar with the area tabs on top, and the area below it.
struct PadRootView: View {
    @ObservedObject var studio: PadStudio
    @ObservedObject var presets: PresetsHost

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AmpBench")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer()
                SegmentTabs(tr("Area"), selection: $studio.area, options: PadArea.allCases.map { ($0, $0.title) })
                    .fixedSize()
                Spacer()
                // Balances the name on the left, so the tabs sit in the middle.
                Text("AmpBench").font(.system(size: 13, weight: .semibold)).hidden()
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(.bar)
            Divider()
            Group {
                switch studio.area {
                case .presets: presets.content
                case .tuner: studio.tuner.content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
