import Foundation
import SparkRecorderUI

// Headless audio commands first (--list, --record, --play-tone, --inspect), otherwise the app.
if let status = RecorderCommandLine.run(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
SparkRecorderApp.main()
