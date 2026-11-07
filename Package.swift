// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The probe talks Bluetooth, and macOS wants a usage description for that even in a command-line tool, so its
// Info.plist is linked into the binary.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "SparkRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        // Realtime audio code. Written in C so the audio callbacks are free of Swift runtime work.
        .target(name: "CSparkRT", path: "Sources/CSparkRT"),
        // Everything without UI: capture, library, repair, edits, playback, export.
        .target(name: "SparkCore", dependencies: ["CSparkRT"], path: "Sources/SparkCore"),
        .executableTarget(name: "SparkRecorder", dependencies: ["SparkCore"], path: "Sources/SparkRecorder"),
        // The amp's Bluetooth control protocol: framing, 7-bit packing, parsing. No Bluetooth code.
        .target(name: "SparkControl", path: "Sources/SparkControl"),
        // Experimental test tool: finds the amp over Bluetooth LE, reads presets and switches them.
        .executableTarget(
            name: "spark-probe", dependencies: ["SparkControl"], path: "Sources/SparkProbe",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "\(root)/Resources/SparkProbe-Info.plist"])]),
        .testTarget(name: "SparkCoreTests", dependencies: ["SparkCore", "CSparkRT"], path: "Tests/SparkCoreTests"),
        .testTarget(name: "SparkControlTests", dependencies: ["SparkControl"], path: "Tests/SparkControlTests"),
    ]
)
