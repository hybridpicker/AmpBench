#!/bin/zsh
# Builds "build/Spark Recorder.app", "build/Spark Presets.app" and "build/Spark Studio.app".
#
#   ./build.sh                    builds all three apps
#   ./build.sh --install          also copies them to /Applications and adds them to the Dock
#   ./build.sh [--install] studio   only Spark Studio, "presets" only Spark Presets, "recorder" only Spark Recorder
#
# Signs with an Apple Development certificate if there is one, because macOS then keeps the microphone permission
# across rebuilds. Without one it falls back to an ad-hoc signature, and macOS may ask again after every build.
# Set SPARK_SIGN_IDENTITY to choose a certificate, or to "-" to force ad-hoc.
set -euo pipefail

cd "$(dirname "$0")"

install=""
apps=()
for argument in "$@"; do
    case "$argument" in
        --install) install=1 ;;
        recorder|presets|studio) apps+=("$argument") ;;
        *) echo "usage: ./build.sh [--install] [recorder] [presets] [studio]" >&2; exit 64 ;;
    esac
done
(( ${#apps} )) || apps=(recorder presets studio)

icon="Resources/AppIcon.icns"
if [[ ! -f "$icon" || "Tools/make-icon.swift" -nt "$icon" ]]; then
    swift Tools/make-icon.swift "$icon"
fi
presets_icon="Resources/PresetsIcon.icns"
if [[ ! -f "$presets_icon" || "Tools/make-icon.swift" -nt "$presets_icon" ]]; then
    swift Tools/make-icon.swift "$presets_icon" presets
fi
studio_icon="Resources/StudioIcon.icns"
if [[ ! -f "$studio_icon" || "Tools/make-icon.swift" -nt "$studio_icon" ]]; then
    swift Tools/make-icon.swift "$studio_icon" studio
fi

(( ${apps[(Ie)recorder]} )) && swift build -c release --product SparkRecorder
(( ${apps[(Ie)presets]} )) && swift build -c release --product SparkPresets
(( ${apps[(Ie)studio]} )) && swift build -c release --product SparkStudio
bin_path="$(swift build -c release --show-bin-path)"

identity="${SPARK_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
fi

# make_app <app name> <executable> <Info.plist> <icon>
make_app() {
    local app="build/$1.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin_path/$2" "$app/Contents/MacOS/$2"
    cp "$3" "$app/Contents/Info.plist"
    cp "$4" "$app/Contents/Resources/AppIcon.icns"
    codesign --force --sign "${identity:--}" "$app"
    echo "Built $app"
}

(( ${apps[(Ie)recorder]} )) && make_app "Spark Recorder" SparkRecorder Resources/Info.plist "$icon"
(( ${apps[(Ie)presets]} )) && make_app "Spark Presets" SparkPresets Resources/SparkPresets-Info.plist "$presets_icon"
(( ${apps[(Ie)studio]} )) && make_app "Spark Studio" SparkStudio Resources/SparkStudio-Info.plist "$studio_icon"

# install_app <app name>
install_app() {
    local app="build/$1.app"
    local target="/Applications/$1.app"
    # An installed copy that is running keeps the old code, so ask it to quit. Spark Recorder finalizes a recording
    # when it does.
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
    local encoded="${1// /%20}.app"
    local installed_url="file:///Applications/$encoded/"
    local dock_folder="$(mktemp -d -t spark-dock)"
    local dock_copy="$dock_folder/dock.plist"
    defaults export com.apple.dock "$dock_copy"
    local buddy=/usr/libexec/PlistBuddy
    local found=""
    local changed=""
    local count="$(plutil -extract persistent-apps raw "$dock_copy" 2>/dev/null || echo 0)"
    local index url
    for (( index = 0; index < count; index++ )); do
        # Spacers have no file, so a missing value only skips that entry.
        url="$($buddy -c "Print :persistent-apps:${index}:tile-data:file-data:_CFURLString" "$dock_copy" 2>/dev/null || true)"
        if [[ "$url" == *"$encoded"* ]]; then
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
}

if [[ -n "$install" ]]; then
    (( ${apps[(Ie)recorder]} )) && install_app "Spark Recorder"
    (( ${apps[(Ie)presets]} )) && install_app "Spark Presets"
    (( ${apps[(Ie)studio]} )) && install_app "Spark Studio"
fi
exit 0
