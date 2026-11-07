import Foundation
import SparkRecorderUI

// Spark Studio: Spark Recorder and Spark Presets in one window. Headless audio commands come first (--list, --record,
// --play-tone, --inspect; the recorder's self-test starts this executable with --play-tone). The test options of
// both apps work too (--library, --ui-selftest, --dark, --offline, --snapshot, --open, --size, --appearance,
// --live-selftest), plus --menu-dump.
if let status = RecorderCommandLine.run(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
StudioApp.main()
