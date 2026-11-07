// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The probe, Spark Presets and Spark Studio talk Bluetooth, and macOS wants a usage description for that even in a bare binary, so
// their Info.plist is linked into it. The app bundle carries the same file.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "SparkRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        // Realtime audio code. Written in C so the audio callbacks are free of Swift runtime work.
        .target(name: "CSparkRT", path: "Sources/CSparkRT"),
        // Everything without UI: capture, library, repair, edits, playback, export.
        .target(name: "SparkCore", dependencies: ["CSparkRT"], path: "Sources/SparkCore"),
        // The shared look of both apps: colors, keys, lamps, displays, knobs, pedals. Only SwiftUI and AppKit.
        .target(name: "SparkDesign", path: "Sources/SparkDesign"),
        // Spark Recorder's window, menus, key handling and self-test. The app and Spark Studio both show it.
        .target(name: "SparkRecorderUI", dependencies: ["SparkCore", "SparkDesign"], path: "Sources/SparkRecorderUI"),
        // The Spark Recorder app: headless audio commands, then the window from SparkRecorderUI.
        .executableTarget(name: "SparkRecorder", dependencies: ["SparkCore", "SparkRecorderUI"], path: "Sources/SparkRecorder"),
        // The amp's Bluetooth control protocol: framing, 7-bit packing, parsing. No Bluetooth code.
        .target(name: "SparkControl", path: "Sources/SparkControl"),
        // Experimental test tool: finds the amp over Bluetooth LE, reads presets and switches them.
        .executableTarget(
            name: "spark-probe", dependencies: ["SparkControl"], path: "Sources/SparkProbe",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "\(root)/Resources/SparkProbe-Info.plist"])]),
        // Spark Presets' window, menus, editor and Bluetooth link. The app and Spark Studio both show it.
        .target(name: "SparkPresetsUI", dependencies: ["SparkControl", "SparkDesign"], path: "Sources/SparkPresetsUI"),
        // Spark Presets: a separate app that switches, saves and stores the amp's presets over Bluetooth LE.
        .executableTarget(
            name: "SparkPresets", dependencies: ["SparkPresetsUI"], path: "Sources/SparkPresets",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "\(root)/Resources/SparkPresets-Info.plist"])]),
        // Spark Studio: Spark Recorder and Spark Presets in one app, with both windows and both usage descriptions.
        .executableTarget(
            name: "SparkStudio", dependencies: ["SparkCore", "SparkDesign", "SparkRecorderUI", "SparkPresetsUI"],
            path: "Sources/SparkStudio",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "\(root)/Resources/SparkStudio-Info.plist"])]),
        .testTarget(name: "SparkCoreTests", dependencies: ["SparkCore", "CSparkRT"], path: "Tests/SparkCoreTests"),
        .testTarget(name: "SparkControlTests", dependencies: ["SparkControl"], path: "Tests/SparkControlTests"),
        .testTarget(name: "SparkDesignTests", dependencies: ["SparkDesign"], path: "Tests/SparkDesignTests"),
    ]
)
