#!/bin/zsh
# Runs spark-probe inside a small app bundle, so macOS asks for (and remembers) Bluetooth access for the probe itself.
#
#   Tools/probe-app.sh <spark-probe arguments>      for example: Tools/probe-app.sh listen 60
#
# Why: started from a Claude Code session in the desktop app, a bare spark-probe is counted as part of Claude, which
# has no Bluetooth usage text, and macOS ends it at the first Bluetooth call. As its own bundle (Info.plist from
# Resources/SparkProbe-Info.plist plus CFBundleExecutable, CFBundlePackageType APPL and LSUIElement, ad hoc signed)
# started with `open`, it is its own app. Its output comes back through files and is printed when it ends.
#
# The bundle lives in .build/SparkProbe.app and is rebuilt every time from the current debug build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product spark-probe >/dev/null
app=".build/SparkProbe.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/debug/spark-probe "$app/Contents/MacOS/spark-probe"
plist="$app/Contents/Info.plist"
cp Resources/SparkProbe-Info.plist "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string spark-probe" \
    -c "Add :CFBundlePackageType string APPL" \
    -c "Add :LSUIElement bool true" "$plist" >/dev/null
codesign --force --sign - "$app" >/dev/null 2>&1

out="$(mktemp -t spark-probe-out)"
err="$(mktemp -t spark-probe-err)"
trap 'rm -f "$out" "$err"' EXIT
code=0
open -W -n --stdout "$out" --stderr "$err" "$app" --args "$@" || code=$?
cat "$out"
cat "$err" >&2
exit $code
