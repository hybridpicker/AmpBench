#!/bin/zsh
# Builds "build/Spark Recorder.app".
#
#   ./build.sh            builds the app
#   ./build.sh --install  also copies it to /Applications and adds it to the Dock
#
# Signs with an Apple Development certificate if there is one, because macOS then keeps the microphone permission
# across rebuilds. Without one it falls back to an ad-hoc signature, and macOS may ask again after every build.
# Set SPARK_SIGN_IDENTITY to choose a certificate, or to "-" to force ad-hoc.
set -euo pipefail

cd "$(dirname "$0")"

icon="Resources/AppIcon.icns"
if [[ ! -f "$icon" || "Tools/make-icon.swift" -nt "$icon" ]]; then
    swift Tools/make-icon.swift "$icon"
fi

swift build -c release

app="build/Spark Recorder.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/SparkRecorder" "$app/Contents/MacOS/SparkRecorder"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$icon" "$app/Contents/Resources/AppIcon.icns"

identity="${SPARK_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
fi
codesign --force --sign "${identity:--}" "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
    target="/Applications/Spark Recorder.app"
    # An installed copy that is running keeps the old code, so ask it to quit. It finalizes a recording when it does.
    # Other running copies, such as one started from the build folder, are left alone.
    if pgrep -f "^$target/Contents/MacOS/" >/dev/null; then
        osascript -e "tell application \"$target\" to quit" || true
        sleep 1
    fi
    rm -rf "$target"
    ditto "$app" "$target"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target"
    echo "Installed $target"

    # Keeps one Dock icon: an entry pointing elsewhere, such as at the build folder, moves to the installed app and
    # stays in its place. Without any entry, one is added at the end.
    installed_url="file:///Applications/Spark%20Recorder.app/"
    dock_folder="$(mktemp -d -t spark-dock)"
    dock_copy="$dock_folder/dock.plist"
    defaults export com.apple.dock "$dock_copy"
    buddy=/usr/libexec/PlistBuddy
    found=""
    changed=""
    count="$(plutil -extract persistent-apps raw "$dock_copy" 2>/dev/null || echo 0)"
    for (( index = 0; index < count; index++ )); do
        # Spacers have no file, so a missing value only skips that entry.
        url="$($buddy -c "Print :persistent-apps:${index}:tile-data:file-data:_CFURLString" "$dock_copy" 2>/dev/null || true)"
        if [[ "$url" == *"Spark%20Recorder.app"* ]]; then
            found=1
            if [[ "$url" != "$installed_url" ]]; then
                $buddy -c "Set :persistent-apps:${index}:tile-data:file-data:_CFURLString $installed_url" \
                    -c "Set :persistent-apps:${index}:tile-data:file-data:_CFURLStringType 15" "$dock_copy"
                # The stored bookmark would still resolve to the old place.
                $buddy -c "Delete :persistent-apps:${index}:tile-data:book" "$dock_copy" 2>/dev/null || true
                changed=1
            fi
        fi
    done
    if [[ -n "$changed" ]]; then
        defaults import com.apple.dock "$dock_copy"
        killall Dock
        echo "Dock icon now opens $target"
    elif [[ -z "$found" ]]; then
        defaults write com.apple.dock persistent-apps -array-add \
            "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$installed_url</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
        killall Dock
        echo "Added to the Dock"
    else
        echo "Already in the Dock"
    fi
    rm -rf "$dock_folder"
fi
