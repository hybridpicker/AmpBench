#!/bin/zsh
# Builds "build/Spark Studio.app".
#
#   ./build.sh            builds the app
#   ./build.sh --install  also copies it to /Applications and adds it to the Dock
#
# Signs with an Apple Development certificate if there is one, because macOS then keeps the microphone permission
# across rebuilds. Without one it falls back to an ad-hoc signature, and macOS may ask again after every build.
# Set SPARK_SIGN_IDENTITY to choose a certificate, or to "-" to force ad-hoc.
set -euo pipefail

cd "$(dirname "$0")"

install=""
for argument in "$@"; do
    case "$argument" in
        --install) install=1 ;;
        *) echo "usage: ./build.sh [--install]" >&2; exit 64 ;;
    esac
done

name="Spark Studio"
executable="SparkStudio"
icon="Resources/AppIcon.icns"
if [[ ! -f "$icon" || "Tools/make-icon.swift" -nt "$icon" ]]; then
    swift Tools/make-icon.swift "$icon"
fi

swift build -c release --product "$executable"
bin_path="$(swift build -c release --show-bin-path)"

identity="${SPARK_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
fi

app="build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/$executable" "$app/Contents/MacOS/$executable"
cp Resources/Info.plist "$app/Contents/Info.plist"
# One version for every machine and platform: VERSION at the top of the repository, and the id of what was built.
# `SparkStudio --version` prints both, and so does `spark-studio --version` on Linux (see sync.sh).
version="$(tr -d '[:space:]' < VERSION)"
build_id="$(Tools/build-id.sh)"
commit_count="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
plist_buddy=/usr/libexec/PlistBuddy
$plist_buddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $commit_count" \
    -c "Add :SparkBuildID string $build_id" "$app/Contents/Info.plist"
cp "$icon" "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign "${identity:--}" "$app"
echo "Built $app ($version, $build_id)"

[[ -n "$install" ]] || exit 0

target="/Applications/$name.app"
# An installed copy that is running keeps the old code, so ask it to quit. A running recording is finalized when it
# does. Other running copies, such as one started from the build folder, are left alone.
if pgrep -f "^$target/Contents/MacOS/" >/dev/null; then
    osascript -e "tell application \"$target\" to quit" || true
    sleep 1
fi
rm -rf "$target"
ditto "$app" "$target"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target"
echo "Installed $target"

# Keeps one Dock icon: an entry pointing elsewhere, such as at the build folder, moves to the installed app and stays
# in its place. Without any entry, one is added at the end.
encoded="${name// /%20}.app"
installed_url="file:///Applications/$encoded/"
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
exit 0
