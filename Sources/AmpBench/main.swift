import Foundation
import SparkRecorderUI

// AmpBench: Spark Recorder and Spark Presets in one window. Headless audio commands come first (--list, --record,
// --play-tone, --inspect; the recorder's self-test starts this executable with --play-tone). The test options of
// both apps work too (--library, --ui-selftest, --dark, --offline, --snapshot, --open, --size, --appearance,
// --live-selftest), plus --menu-dump.
// Sound recipes and the catalog: --recipe-check, --recipe-from, --catalog-export.
// --version: the same line as `ampbench --version` on Linux, so sync.sh can compare the machines.
if CommandLine.arguments.dropFirst().first == "--version" {
    let info = Bundle.main.infoDictionary ?? [:]
    print("AmpBench \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["SparkBuildID"] as? String ?? "dev"))")
    exit(0)
}
// The settings of the former "Spark Studio", once and before anything reads a setting; the language is one of them.
SettingsMigration.runAtLaunch()
if let status = RecipeCommandLine.run(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
// The sound store without the window: --store-setup, --store-key, --store-sync, --store-status.
if let status = StoreCommandLine.run(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
if let status = RecorderCommandLine.run(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
// The folder ~/Music/AmpBench, taken over from the former apps at the first start.
guard MainActor.assumeIsolated({ StudioLaunch.prepare() }) else { exit(1) }
StudioApp.main()
