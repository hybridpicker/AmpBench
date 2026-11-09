import SparkDesign
import SparkPresetsUI
import SparkRecorderUI
import SparkTunerUI
import SwiftUI

/// The deck on top, fixed, and the area chosen in the toolbar below it.
struct StudioWindowView: View {
    /// The recorder's width with its deck; the presets' 900 fit inside.
    static let minimumWidth: CGFloat = 1120
    /// Deck 122 plus the presets' 598 (they asked for 600 and fit 598), the recorder's library gets 31 more than before.
    static let minimumHeight: CGFloat = 720

    @ObservedObject var studio: Studio
    @ObservedObject var presets: PresetsHost

    var body: some View {
        studio.recorder.presentations(on: AnyView(layout))
            .sheet(isPresented: $studio.showsShortcuts) {
                StudioShortcutsSheet { studio.showsShortcuts = false }
            }
    }

    private var layout: some View {
        VStack(spacing: 0) {
            studio.recorder.deck
                .environment(\.deckBluetooth, bluetooth)
            Group {
                switch studio.area {
                case .recording:
                    studio.recorder.workspace
                case .presets:
                    presets.content
                        // The recorder's messages, such as "Kein Spark" after R, are seen here too.
                        .overlay(alignment: .top) { recorderBanner }
                case .tuner:
                    studio.tuner.content
                        .overlay(alignment: .top) { recorderBanner }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: Self.minimumWidth, maxWidth: .infinity, minHeight: Self.minimumHeight, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .principal) {
                SegmentTabs("Bereich", selection: Binding(get: { studio.area }, set: { studio.show($0) }),
                            options: StudioArea.allCases.map { ($0, $0.title) })
                    .fixedSize()
                    .help(StudioArea.allCases.map { "\($0.title) ⇧⌘\($0.digit)" }.joined(separator: ", "))
            }
        }
    }

    private var recorderBanner: some View {
        studio.recorder.banner
            .padding(.horizontal, 14)
            .padding(.top, 8)
    }

    private var bluetooth: DeckBluetooth {
        let state: DeckBluetooth.State = switch presets.connection {
        case .connected: .connected
        case .busy: .busy
        case .off: .off
        case .unavailable: .unavailable
        }
        return DeckBluetooth(state: state, detail: presets.connectionText) { [presets] in presets.toggleConnection() }
    }
}
