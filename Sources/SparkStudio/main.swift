import Foundation
import SparkRecorderUI

// Spark Studio: Spark Recorder and Spark Presets in one window. Headless audio commands come first (--list, --record,
// --play-tone, --inspect; the recorder's self-test starts this executable with --play-tone). The test options of
// both apps work too (--library, --ui-selftest, --dark, --offline, --snapshot, --open, --size, --appearance,
// --live-selftest), plus --menu-dump.
// Sound recipes and the catalog: --recipe-check, --recipe-from, --catalog-export.
if let status = RecipeCommandLine.run(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
if let status = RecorderCommandLine.run(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
// The folder ~/Music/Spark Studio, taken over from the former apps at the first start.
guard MainActor.assumeIsolated({ StudioLaunch.prepare() }) else { exit(1) }
StudioApp.main()
