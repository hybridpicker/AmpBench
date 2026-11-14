# AmpBench on the iPad

The areas **Presets** and **Tuner** of the Mac app, from the same code, plus the [sound store](../docs/STORE.md) that
brings the Mac's sounds to the iPad. iPadOS 17 or later.

- **Presets**: the amp's slots over Bluetooth LE, the editor with live changes, storing in a slot with a backup,
  hashtags, AI Sound, the Kemper import, several devices (Spark MINI, NEO, REACTOR 50).
- **Tuner**: the audio input the iPad routes in (the Spark over USB-C, or the built-in microphone), or the amp's own
  tuner over Bluetooth.
- **Not yet**: the area Record. It needs the Mac's audio engine (AUHAL, device list), which iPadOS has no counterpart
  for; an input for the tuner is all the iPad has so far.

Sounds are plain JSON files in the app's Documents folder, which the Files app shows under "On My iPad → AmpBench".

## Build

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
./ios/build.sh               # builds for the iPad simulator; no Apple account needed
./ios/build.sh --simulator   # also installs and starts it in an iPad simulator
./ios/build.sh --test        # the UI tests: made-up presets, a simulated amp, fingers on the real window
./ios/build.sh --device      # builds signed and installs it on a connected iPad
```

`--device` needs your Apple account in Xcode (Settings → Accounts) and your team in `ios/Local.xcconfig`. The script
writes that file from your Apple Development certificate when it is missing; `Local.xcconfig.example` shows what it
holds. Git ignores it and the generated `AmpBenchPad.xcodeproj`, so no team id or bundle id of yours is published.

Without an account in Xcode it also works when a development profile that lists your iPad is already on the Mac,
such as a team's wildcard profile: name its UUID as `AMPBENCH_PROFILE` in `Local.xcconfig`, and the script builds
unsigned and signs by hand with that profile and its certificate.

## How it is put together

```
ios/project.yml          the Xcode project, as XcodeGen reads it
ios/Config.xcconfig      public build settings; includes the untracked Local.xcconfig
ios/App/                 the bundle only: Info.plist, icon, main.swift (calls PadApp.main())
ios/UITests/             UI tests that drive the app in the simulator
Sources/AmpBenchPad/     the iPad's own code: the window with its tabs, and the tuner's input (AVAudioEngine)
```

Everything else is the Mac's code. Where the platforms differ, the difference sits in one place each:
`Sources/SparkDesign/Platform.swift` (styles, pasteboard, sheet sizes), `#if os(macOS)` around the Mac's audio
engines in SparkCore, and `Texts.forPad`, which makes the texts say "this iPad" where they say "this Mac".

## Looking at it without an amp

```bash
xcrun simctl launch booted local.ampbench.pad --library /tmp/ampbench-pad --demo-devices mini --open saved:Lead
xcrun simctl launch booted local.ampbench.pad --library /tmp/ampbench-pad --tuner-demo
```

With a `Local.xcconfig` the bundle id is the one in that file. `--library` is a test library: made-up presets, simulated devices instead of Bluetooth, a sound store profile apart
from the real one, and no input is opened for `--tuner-demo`.

## Checked, and not yet

- In the simulator (iPad Air 11-inch, iPadOS 26.5): the four UI tests pass. A finger turns a knob in the editor, the
  tuner shows a made-up string, the sound store's sheet makes a key, the Mac's sheets fit.
- Compiles for a real iPad (arm64), unsigned.
- **Not yet on a real iPad**: Bluetooth to an amp, the tuner with a guitar (USB-C and microphone), the sound store
  with a folder from Files or an HTTPS server.
