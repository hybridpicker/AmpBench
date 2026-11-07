// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SparkRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        // Realtime audio code. Written in C so the audio callbacks are free of Swift runtime work.
        .target(name: "CSparkRT", path: "Sources/CSparkRT"),
        // Everything without UI: capture, library, repair, edits, playback, export.
        .target(name: "SparkCore", dependencies: ["CSparkRT"], path: "Sources/SparkCore"),
        .executableTarget(name: "SparkRecorder", dependencies: ["SparkCore"], path: "Sources/SparkRecorder"),
        .testTarget(name: "SparkCoreTests", dependencies: ["SparkCore", "CSparkRT"], path: "Tests/SparkCoreTests"),
    ]
)
