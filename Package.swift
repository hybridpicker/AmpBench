// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Spark Studio and the probe talk Bluetooth, and Spark Studio records audio. macOS wants usage descriptions for that
// even in a bare binary, so their Info.plist is linked into it. The app bundle carries the same file.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "SparkStudio",
    platforms: [.macOS(.v14)],
    targets: [
        // Realtime audio code. Written in C so the audio callbacks are free of Swift runtime work.
        .target(name: "CSparkRT", path: "Sources/CSparkRT"),
        // Everything without UI: capture, library, repair, edits, playback, export, Studio's folders and keymap.
        .target(name: "SparkCore", dependencies: ["CSparkRT"], path: "Sources/SparkCore"),
        // The shared look: colors, keys, lamps, displays, knobs, pedals. Only SwiftUI and AppKit.
        .target(name: "SparkDesign", path: "Sources/SparkDesign"),
        // The amp's Bluetooth control protocol: framing, 7-bit packing, parsing, catalog, preset library. No Bluetooth code.
        .target(name: "SparkControl", path: "Sources/SparkControl"),
        // The area "Aufnahme" and the deck: window parts, menus, key handling, self-test, headless audio commands.
        .target(name: "SparkRecorderUI", dependencies: ["SparkCore", "SparkDesign"], path: "Sources/SparkRecorderUI"),
        // The area "Presets": sidebar, editor, menus and the Bluetooth link to the amp.
        .target(name: "SparkPresetsUI", dependencies: ["SparkControl", "SparkDesign"], path: "Sources/SparkPresetsUI"),
        // The area "Stimmgerät": the tuner's front and menus. It reads the recorder's input and talks to no amp.
        .target(name: "SparkTunerUI", dependencies: ["SparkCore", "SparkDesign"], path: "Sources/SparkTunerUI"),
        // Spark Studio: the one window with the deck and the areas, and what ties them together.
        .executableTarget(
            name: "SparkStudio",
            dependencies: ["SparkCore", "SparkControl", "SparkDesign", "SparkRecorderUI", "SparkPresetsUI", "SparkTunerUI"],
            path: "Sources/SparkStudio",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "\(root)/Resources/Info.plist"])]),
        // Experimental test tool: finds the amp over Bluetooth LE, reads presets and switches them.
        .executableTarget(
            name: "spark-probe", dependencies: ["SparkControl"], path: "Sources/SparkProbe",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "\(root)/Resources/SparkProbe-Info.plist"])]),
        .testTarget(name: "SparkCoreTests", dependencies: ["SparkCore", "CSparkRT"], path: "Tests/SparkCoreTests"),
        .testTarget(name: "SparkControlTests", dependencies: ["SparkControl"], path: "Tests/SparkControlTests"),
        .testTarget(name: "SparkDesignTests", dependencies: ["SparkDesign"], path: "Tests/SparkDesignTests"),
        .testTarget(name: "SparkTunerUITests", dependencies: ["SparkTunerUI", "SparkCore"], path: "Tests/SparkTunerUITests"),
    ]
)
