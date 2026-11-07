// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The probe and Spark Presets talk Bluetooth, and macOS wants a usage description for that even in a bare binary, so
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
        .executableTarget(name: "SparkRecorder", dependencies: ["SparkCore", "SparkDesign"], path: "Sources/SparkRecorder"),
        // The amp's Bluetooth control protocol: framing, 7-bit packing, parsing. No Bluetooth code.
        .target(name: "SparkControl", path: "Sources/SparkControl"),
        // Experimental test tool: finds the amp over Bluetooth LE, reads presets and switches them.
        .executableTarget(
            name: "spark-probe", dependencies: ["SparkControl"], path: "Sources/SparkProbe",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "\(root)/Resources/SparkProbe-Info.plist"])]),
        // Spark Presets: a separate app that switches, saves and stores the amp's presets over Bluetooth LE.
        .executableTarget(
            name: "SparkPresets", dependencies: ["SparkControl", "SparkDesign"], path: "Sources/SparkPresets",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "\(root)/Resources/SparkPresets-Info.plist"])]),
        .testTarget(name: "SparkCoreTests", dependencies: ["SparkCore", "CSparkRT"], path: "Tests/SparkCoreTests"),
        .testTarget(name: "SparkControlTests", dependencies: ["SparkControl"], path: "Tests/SparkControlTests"),
        .testTarget(name: "SparkDesignTests", dependencies: ["SparkDesign"], path: "Tests/SparkDesignTests"),
    ]
)
