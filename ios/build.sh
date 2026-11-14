#!/bin/zsh
# Builds AmpBench for the iPad.
#
#   ./ios/build.sh                 builds for the iPad simulator (no signing, no Apple account needed)
#   ./ios/build.sh --simulator     also installs and starts it in a booted iPad simulator, booting one if none runs
#   ./ios/build.sh --device        builds signed and installs it on the iPad that is connected or on the same Wi-Fi
#   ./ios/build.sh --test          runs the UI tests in an iPad simulator: made-up presets, a simulated amp
#
# Needs Xcode and XcodeGen (`brew install xcodegen`). For --device it needs your Apple developer team in
# ios/Local.xcconfig; when that file is missing, it is written from your Apple Development certificate. The file is
# not in Git, so no team id or bundle id of yours ends up in the public repository.
set -euo pipefail

cd "$(dirname "$0")"

mode=build
for argument in "$@"; do
    case "$argument" in
        --simulator) mode=simulator ;;
        --device) mode=device ;;
        --test) mode=test ;;
        *) echo "usage: ./ios/build.sh [--simulator | --device | --test]" >&2; exit 64 ;;
    esac
done

command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 69; }

if [[ ! -f App/Assets.xcassets/AppIcon.appiconset/AppIcon.png || ../Tools/make-icon.swift -nt App/Assets.xcassets/AppIcon.appiconset/AppIcon.png ]]; then
    swift ../Tools/make-icon.swift --ios App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
fi

xcodegen generate --quiet

# One version for every machine and platform, as in build.sh: VERSION, and the id of what was built.
version="$(tr -d '[:space:]' < ../VERSION)"
build_id="$(../Tools/build-id.sh)"
commit_count="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
settings=(MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$commit_count" AMPBENCH_BUILD_ID="$build_id")
derived="../.build-ios-app"

# An iPad simulator: one named "AmpBench iPad" if there is one, so simulators set up for other projects are left
# alone (make it with: xcrun simctl create "AmpBench iPad" <device type> <runtime>); else one that runs, else the
# first installed one.
simulator() {
    local id
    id="$(xcrun simctl list devices available | awk -F '[()]' '/AmpBench iPad/ { print $2; exit }')"
    [[ -n "$id" ]] || id="$(xcrun simctl list devices booted | awk -F '[()]' '/iPad/ { print $2; exit }')"
    [[ -n "$id" ]] || id="$(xcrun simctl list devices available | awk -F '[()]' '/iPad/ { print $2; exit }')"
    [[ -n "$id" ]] || { echo "No iPad simulator is installed (Xcode → Settings → Components)." >&2; exit 1; }
    xcrun simctl list devices booted | grep -q "$id" || xcrun simctl boot "$id"
    print -r -- "$id"
}

if [[ "$mode" == test ]]; then
    id="$(simulator)"
    # AMPBENCH_PICTURES=<folder> also writes pictures of what the tests see.
    TEST_RUNNER_AMPBENCH_PICTURES="${AMPBENCH_PICTURES:-}" xcodebuild -project AmpBenchPad.xcodeproj \
        -scheme AmpBenchApp -destination "id=$id" -derivedDataPath "$derived" "${settings[@]}" test \
        | grep -E "^/.*error:|^error:|Test Case .* (passed|failed)|TEST (SUCCEEDED|FAILED)|Executed" | sort -u
    exit ${pipestatus[1]}
fi

if [[ "$mode" != device ]]; then
    xcodebuild -project AmpBenchPad.xcodeproj -scheme AmpBenchApp -configuration Debug \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=NO "${settings[@]}" build | grep -E "^/.*error:|^error:|BUILD (SUCCEEDED|FAILED)" | sort -u \
        | tee /dev/stderr | grep -q "BUILD SUCCEEDED" || { echo "The build failed." >&2; exit 1; }
    app="$derived/Build/Products/Debug-iphonesimulator/AmpBenchApp.app"
    echo "Built $app ($version, $build_id)"
    [[ "$mode" == simulator ]] || exit 0
    booted="$(simulator)"
    open -a Simulator
    xcrun simctl install "$booted" "$app"
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
    xcrun simctl launch "$booted" "$bundle_id"
    exit 0
fi

# A real iPad needs a signature. The team comes from Local.xcconfig, written once from the signing certificate.
if [[ ! -f Local.xcconfig ]]; then
    # The same certificate build.sh signs the Mac app with: the first Apple Development one, or SPARK_SIGN_IDENTITY.
    identity="${SPARK_SIGN_IDENTITY:-}"
    if [[ -z "$identity" || "$identity" == "-" ]]; then
        identity="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development/ { print $2; exit }')"
    fi
    subject="$(security find-certificate -c "$identity" -p 2>/dev/null | openssl x509 -noout -subject -nameopt multiline 2>/dev/null || true)"
    team="$(print -r -- "$subject" | awk -F '= ' '/organizationalUnitName/ { print $2; exit }')"
    [[ -n "$team" ]] || { echo "No Apple Development certificate found. Sign in under Xcode → Settings → Accounts, then copy ios/Local.xcconfig.example to ios/Local.xcconfig and fill it in." >&2; exit 1; }
    umask 077
    print -r -- "DEVELOPMENT_TEAM = $team" > Local.xcconfig
    print -r -- "AMPBENCH_BUNDLE_ID = local.ampbench.pad.${team:l}" >> Local.xcconfig
    echo "Wrote ios/Local.xcconfig from your signing certificate (Git ignores it)."
    xcodegen generate --quiet
fi

app="$derived/Build/Products/Release-iphoneos/AmpBenchApp.app"
# An older build must not pass for this one.
rm -rf "$app"
profile_id="$(awk -F ' *= *' '/^AMPBENCH_PROFILE/ { print $2; exit }' Local.xcconfig)"
if [[ -n "$profile_id" ]]; then
    # Without an account in Xcode: build unsigned, then sign by hand with a development profile that is already on
    # this Mac (AMPBENCH_PROFILE = its UUID), such as a team's wildcard profile.
    profile=""
    for folder in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
        [[ -f "$folder/$profile_id.mobileprovision" ]] && profile="$folder/$profile_id.mobileprovision"
    done
    [[ -n "$profile" ]] || { echo "The profile named in ios/Local.xcconfig is not on this Mac." >&2; exit 1; }
    xcodebuild -project AmpBenchPad.xcodeproj -scheme AmpBenchApp -configuration Release \
        -destination 'generic/platform=iOS' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
        "${settings[@]}" build | grep -E "^/.*error:|^error:|BUILD (SUCCEEDED|FAILED)" | sort -u || true
    [[ -d "$app" ]] || { echo "The build failed." >&2; exit 1; }
    work="$(mktemp -d -t ampbench-sign)"
    trap 'rm -rf "$work"' EXIT
    security cms -D -i "$profile" > "$work/profile.plist" 2>/dev/null
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
    # The profile's entitlements, with this app's id in place of a wildcard, and the profile's certificate.
    identity="$(/usr/bin/python3 -I ../Tools/profile-signing.py "$work/profile.plist" "$bundle_id" "$work/entitlements.plist")"
    [[ -n "$identity" ]] || { echo "No certificate of this profile is in the keychain." >&2; exit 1; }
    cp "$profile" "$app/embedded.mobileprovision"
    for inner in "$app"/Frameworks/*(N); do codesign --force --sign "$identity" "$inner"; done
    codesign --force --sign "$identity" --entitlements "$work/entitlements.plist" "$app"
else
    xcodebuild -project AmpBenchPad.xcodeproj -scheme AmpBenchApp -configuration Release \
        -destination 'generic/platform=iOS' -derivedDataPath "$derived" -allowProvisioningUpdates \
        "${settings[@]}" build | grep -E "^/.*error:|^error:|BUILD (SUCCEEDED|FAILED)" | sort -u || true
    if [[ ! -d "$app" ]]; then
        echo "The signed build failed. Xcode needs your Apple account once: open Xcode → Settings → Accounts and sign in," >&2
        echo "then run this again. A free Apple ID is enough; its apps run for seven days per install. Or name a" >&2
        echo "development profile that is already on this Mac in ios/Local.xcconfig (see Local.xcconfig.example)." >&2
        exit 1
    fi
fi
echo "Built $app ($version, $build_id)"

device="$(xcrun devicectl list devices 2>/dev/null | awk '/iPad/ && /(available|connected)/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F-]{27}$/) { print $i; exit } }')"
[[ -n "$device" ]] || { echo "No iPad found. Connect it by cable, unlock it and trust this Mac, then run this again." >&2; exit 1; }
xcrun devicectl device install app --device "$device" "$app"
echo "Installed on the iPad."
