#if os(iOS)
import AmpText
import SparkCore
import SparkPresetsUI
import SparkTunerUI
import SwiftUI

/// The areas of the iPad app, in the order of its tabs. Record is the Mac's and Linux's so far: it needs the
/// Mac's audio engine, which iPadOS has no counterpart for yet.
enum PadArea: String, CaseIterable, Identifiable {
    case presets
    case tuner

    var id: String { rawValue }

    var title: String {
        switch self {
        case .presets: tr("Presets")
        case .tuner: tr("Tuner")
        }
    }

    /// ⇧⌘ plus this digit shows the area, with a keyboard attached. The digits are the Mac's, so Presets stays ⇧⌘2.
    var digit: Int {
        switch self {
        case .presets: 2
        case .tuner: 3
        }
    }
}

/// AmpBench on the iPad: the same Presets and Tuner as on the Mac, from the same code, in one window.
@MainActor
final class PadStudio: ObservableObject {
    static let shared = PadStudio()

    let presets: PresetsHost
    let tuner: TunerHost
    private let input = PadInput()
    @Published var area = PadArea.presets {
        didSet { if area != oldValue { updateTuner() } }
    }
    /// True while the app is in front. The tuner listens only then.
    var isInFront = false {
        didSet { if isInFront != oldValue { updateTuner() } }
    }
    private var isShowingTunerDemo = false

    private init() {
        presets = PresetsHost(folder: PadFolders.presets)
        let isTestLibrary = CommandLine.arguments.contains("--library")
        let defaults = isTestLibrary ? UserDefaults(suiteName: "local.ampbench.tuner.tests") : nil
        tuner = TunerHost(input: input, defaults: defaults ?? .standard)
        tuner.offerAmpTuner(presets)
        // Pictures from the simulator: `--library <folder> --tuner-demo` shows a made-up string, with no input open.
        if isTestLibrary, CommandLine.arguments.contains("--tuner-demo") {
            isShowingTunerDemo = true
            tuner.showDemo(frequency: 110 * pow(2, -3.4 / 1200), strobe: false)
            area = .tuner
        }
    }

    private func updateTuner() {
        let active = area == .tuner && (isInFront || isShowingTunerDemo)
        // The amp's own tuner needs the link, which otherwise starts only with the area Presets.
        if active, !isShowingTunerDemo { presets.startLinkOnce() }
        // Leaving the tuner or the app switches the amp's own tuner off, so the amp is never left silent.
        tuner.setActive(active)
    }
}

/// Where the iPad keeps its sounds: in the app's own Documents, which the Files app shows under "On My iPad".
enum PadFolders {
    static var presets: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Presets", isDirectory: true)
    }
}

/// The presets' Bluetooth link offers the amp's own tuner to the tuner area, as on the Mac.
extension PresetsHost: AmpTuner {}
#endif
