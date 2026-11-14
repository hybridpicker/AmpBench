// swift-tools-version: 5.9
import Foundation
import PackageDescription

// AmpBench and the probe talk Bluetooth, and AmpBench records audio. macOS wants usage descriptions for that
// even in a bare binary, so their Info.plist is linked into it. The app bundle carries the same file.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "AmpBench",
    platforms: [.macOS(.v14), .iOS(.v17)],
    // The iPad app is an Xcode project (ios/), because an iPad app needs a bundle, signing and an asset catalog. It
    // links this one library, which holds all of the iPad's own code; everything else is the Mac's.
    products: [.library(name: "AmpBenchPad", targets: ["AmpBenchPad"])],
    targets: [
        // Every text of the app: English in the code, German from tables. `tr("…")` picks the language.
        .target(name: "AmpText", path: "Sources/AmpText"),
        // The sound store: sounds encrypted on this device (the age format) and kept in a place of the user's choice,
        // a folder, a server over SSH or an HTTPS address. Foundation and CryptoKit only; no UI.
        .target(name: "SoundStore", dependencies: ["AmpText"], path: "Sources/SoundStore"),
        // Realtime audio code. Written in C so the audio callbacks are free of Swift runtime work.
        .target(name: "CSparkRT", path: "Sources/CSparkRT"),
        // Everything without UI: capture, library, repair, edits, playback, export, Studio's folders and keymap.
        .target(name: "SparkCore", dependencies: ["CSparkRT", "AmpText"], path: "Sources/SparkCore"),
        // The shared look: colors, keys, lamps, displays, knobs, pedals. Only SwiftUI and AppKit.
        .target(name: "SparkDesign", dependencies: ["AmpText"], path: "Sources/SparkDesign"),
        // The amp's Bluetooth control protocol: framing, 7-bit packing, parsing, catalog, preset library. No Bluetooth code.
        .target(name: "SparkControl", dependencies: ["AmpText"], path: "Sources/SparkControl"),
        // The area "Aufnahme" and the deck: window parts, menus, key handling, self-test, headless audio commands.
        .target(name: "SparkRecorderUI", dependencies: ["SparkCore", "SparkDesign", "AmpText"], path: "Sources/SparkRecorderUI"),
        // The area "Presets": sidebar, editor, menus and the Bluetooth link to the amp.
        .target(name: "SparkPresetsUI", dependencies: ["SparkControl", "SparkDesign", "SoundStore", "AmpText"],
                path: "Sources/SparkPresetsUI"),
        // The area "Stimmgerät": the tuner's front and menus. It reads the recorder's input; the amp's own tuner only
        // through the AmpTuner protocol Studio fills in.
        .target(name: "SparkTunerUI", dependencies: ["SparkCore", "SparkDesign", "AmpText"], path: "Sources/SparkTunerUI"),
        // AmpBench on the iPad: the areas Presets and Tuner in one window, and the input the tuner hears. Empty on
        // the Mac, so `swift build` there still compiles every target.
        .target(name: "AmpBenchPad",
                dependencies: ["SparkCore", "SparkControl", "SparkDesign", "SparkPresetsUI", "SparkTunerUI", "AmpText"],
                path: "Sources/AmpBenchPad"),
        // AmpBench: the one window with the deck and the areas, and what ties them together.
        .executableTarget(
            name: "AmpBench",
            dependencies: ["SparkCore", "SparkControl", "SparkDesign", "SparkRecorderUI", "SparkPresetsUI", "SparkTunerUI",
                           "SoundStore", "AmpText"],
            path: "Sources/AmpBench",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "\(root)/Resources/Info.plist"])]),
        // Experimental test tool: finds the amp over Bluetooth LE, reads presets and switches them.
        .executableTarget(
            name: "spark-probe", dependencies: ["SparkControl", "SparkCore", "AmpText"], path: "Sources/SparkProbe",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "\(root)/Resources/SparkProbe-Info.plist"])]),
        .testTarget(name: "AmpTextTests", dependencies: ["AmpText"], path: "Tests/AmpTextTests"),
        .testTarget(name: "SoundStoreTests", dependencies: ["AmpText", "SoundStore"], path: "Tests/SoundStoreTests"),
        .testTarget(name: "SparkCoreTests", dependencies: ["AmpText", "SparkCore", "CSparkRT"], path: "Tests/SparkCoreTests"),
        .testTarget(name: "SparkControlTests", dependencies: ["AmpText", "SparkControl"], path: "Tests/SparkControlTests"),
        .testTarget(name: "SparkDesignTests", dependencies: ["AmpText", "SparkDesign"], path: "Tests/SparkDesignTests"),
        .testTarget(name: "SparkPresetsUITests", dependencies: ["AmpText", "SparkPresetsUI", "SparkControl"],
                    path: "Tests/SparkPresetsUITests"),
        .testTarget(name: "SparkTunerUITests", dependencies: ["AmpText", "SparkTunerUI", "SparkCore"], path: "Tests/SparkTunerUITests"),
    ]
)
