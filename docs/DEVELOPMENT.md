# Developing AmpBench

Building, the project layout, tests, command-line modes and how the pictures are made. How the app is used is in
[MANUAL.md](MANUAL.md), the Bluetooth protocol in [PROTOCOL.md](PROTOCOL.md), plan and decisions in
[STUDIO.md](STUDIO.md), the design language in [DESIGN.md](DESIGN.md).

## Build

```bash
./build.sh            # builds "build/AmpBench.app"
./build.sh --install  # also copies it to /Applications and adds it to the Dock
```

Requires macOS 14 or later and the Swift toolchain from Xcode. There are no external dependencies. The build signs with
an Apple Development certificate if one exists, because macOS then keeps the microphone permission across rebuilds.
Without one it uses an ad-hoc signature. `SPARK_SIGN_IDENTITY` overrides the choice, and `-` forces ad-hoc.

**Linux and one version everywhere.** AmpBench also runs on Linux (Omarchy) with the areas Record, Presets and
Tuner, the Kemper import, hashtags and AI Sound; only the REACTOR's presets, their editing and storing, and live commands are Mac-only so far.
See [linux/README.md](../linux/README.md).
Development happens on either machine. Each has its own clone, and GitHub's `main` is where they meet: `./sync.sh`
publishes this machine's commits, installs them here and has the other machine pull and install them, then checks
that both report the same version, `AmpBench <VERSION> (<commit>)`. A background job on each machine
(`Tools/autosync.sh install`) pulls and installs every 15 minutes as well, so a machine that was off catches up. Its
setup and the per-machine `sync.local` are in [linux/README.md](../linux/README.md#keep-in-step-with-the-mac).
`VERSION` is the one place to change the version.

**iPad.** Presets, Tuner and the sound store also run on the iPad, from the same sources: the package builds for
iOS 17 as well, and `ios/` holds an Xcode project (made by XcodeGen) that is only the bundle around the library
`AmpBenchPad`. `./ios/build.sh` builds it, `--simulator` starts it, `--test` runs its UI tests, `--device` installs
it on an iPad. See [ios/README.md](../ios/README.md). After a change to a shared module, check that it still compiles
for the iPad: `./ios/build.sh`.

AmpBench joins the former apps Spark Recorder and Spark Presets. Plan, decisions and what comes next are in
[STUDIO.md](STUDIO.md).

## Project layout

```
Sources/CSparkRT        Realtime capture, click and the tuner's tap (C)
Sources/SparkCore       Capture, library, repair, edits, playback, export, statistics, the app's folders and keymap,
                        pitch detection for the tuner (no UI)
Sources/SparkDesign     The design: colors, keys, lamps, displays, knobs, pedals (SwiftUI, no app code)
Sources/SparkControl    The amp's Bluetooth control protocol, the model catalog, the preset library and the Kemper
                        import (reading backups and rigs, translating them to recipes), without Bluetooth code
Sources/SparkRecorderUI The deck and the area Record: window parts, menus, keys, self-test, headless audio commands
Sources/SparkPresetsUI  The area Presets: sidebar, editor, menus and the Bluetooth link (CoreBluetooth)
Sources/SparkTunerUI    The area Tuner: its front and menus; no Bluetooth of its own, no sound
Sources/AmpText         The UI texts: English in the code, German from tables, the language choice
Sources/SoundStore      The sound store: the age format, the places (folder, SSH, HTTPS), the three-way sync, the
                        device's profile (settings, keychain). Foundation and CryptoKit only
Sources/AmpBench        The app: one window, the areas, and what ties takes, sounds and tempo together
Sources/AmpBenchPad     The iPad app's own code: its window with the areas Presets and Tuner, the tuner's input.
                        Empty on the Mac
ios/                    The iPad app's bundle, Xcode project (XcodeGen), build script and UI tests
Sources/SparkProbe      spark-probe, the experimental Bluetooth test tool
Tests/SparkCoreTests    Unit tests and audio tests with synthetic signals
Tests/SparkControlTests Protocol and library tests with made-up presets and Kemper files built in the test
Tests/SparkDesignTests  Contrast of every text color against its backgrounds, the tuner's blocks
Tests/SparkTunerUITests The tuner's model with a made-up input
Tests/AmpTextTests      Every UI text has its German, with matching placeholders
Tests/SoundStoreTests   The age format against the `age` tool, the places with made-up servers, the sync rules, two
                        devices on one store; made-up data in temporary folders, a keychain service of their own
Tools/make-icon.swift   Draws the app icon
linux/                  The Linux app (Python, PySide6), see linux/README.md
```

A new area joins as a library with a host, like `RecorderHost`, `PresetsHost` and `TunerHost`, and a case in
`StudioArea` (`Sources/AmpBench/Studio.swift`); [STUDIO.md](STUDIO.md#adding-an-area) lists the steps.

## Tests

```bash
swift test
```

All audio is generated by the tests. No test reads a real recording. The audio path tests send a tone through the
virtual [BlackHole](https://github.com/ExistentialAudio/BlackHole) device, and they skip with a reason when BlackHole or
the microphone permission is missing. On 2026-11-08 four of them failed for some hours because the tone did not come
back through BlackHole, then passed again without a code change; [STUDIO.md](STUDIO.md#checks) has the details.

The recipe tests also check the files in `docs/ai`: every example must be a valid recipe, and the catalog files must
match the catalog in the code. After a change to `Sources/SparkControl/Catalog`, run
`swift run AmpBench --catalog-export docs/ai`.

The audio engine refuses every input outside its policy. The default allows USB devices whose name holds one of the
device profiles' USB audio names (today "Spark"; the REACTOR's joins once read on the device), and tests use a policy
that allows virtual test devices and nothing real, not even the amp. Device tests run against simulated devices
(`SimulatedDevice`, and `fake_amp.py` on Linux): the NEO drops its temporary sound, and the REACTOR gets nothing but
its read requests, the slot switch, live commands by the names it takes and its own presets back, never a Spark
preset.

### Self-tests in the real window

The app also has self-tests that drive its real window. They only run with a separate test library, which keeps them
away from your recordings and presets and skips taking over the old folders. A test library only hears BlackHole, sound
goes to a silent virtual output, and the presets live in its subfolder `Presets`, filled with made-up presets:

```bash
"build/AmpBench.app/Contents/MacOS/AmpBench" --library /tmp/studio-test --ui-selftest main /tmp/studio-results
```

Other scenarios are `legacy`, `crash-start`, `crash-verify`, `realwindow`, `pictures` and `sound` (a take keeps a
made-up sound, and an amp action that fails during the recording must not end it). Two more cover the Spark-only rule
and take an extra option: `nospark` with `--test-input none`, and `reconnect` with `--test-input aggregate`.
`--menu-dump <file>` lists every menu item with its key and state, once with each area in front, and checks with a real
key press that a Presets key reaches Presets only while that area shows. `--live-selftest <log>` edits a copy of slot 1
on the amp's temporary place and reads back after every step (needs the amp). On the Spark MINI all ten checks passed
in Spark Presets, which ran the same code; in AmpBench it has not been run yet.

## Command-line modes

These headless commands check the audio path without the UI:

```bash
AmpBench --list
AmpBench --record "Spark" 5 /tmp/test.wav
AmpBench --play-tone "BlackHole" 5 1000 0.25
AmpBench --inspect /tmp/test.wav
```

Sound recipes, the catalog, the Kemper import and REACTOR presets:

```bash
swift run AmpBench --recipe-check docs/ai/examples/texas-blues.json    # can AmpBench read it, and with which values
swift run AmpBench --recipe-from "$HOME/Music/AmpBench/Presets/Jazz.json"  # a saved preset as a recipe
swift run AmpBench --recipe-prompt docs/ai/examples/texas-blues.json   # the sound in English, e.g. for REACTOR
swift run AmpBench --catalog-export docs/ai                            # write the catalog files again
swift run AmpBench --kemper-list backup.kpabackup                      # what a Kemper import would make, reads only
swift run AmpBench --reactor-read "Platz 1.reactorpreset"              # what AmpBench reads from a saved REACTOR preset
```

The sound store (see [STORE.md](STORE.md)); with `--library <folder>` on a test library and a profile of its own:

```bash
AmpBench --store-setup folder <path> | ssh <host> <folder> | https <url> [user]
AmpBench --store-key new | set | show
AmpBench --store-sync
AmpBench --store-verify
AmpBench --store-status
```

Use the installed, signed app for the real store. A debug build has a new signature after every build, and macOS
then asks before it lets that build read a keychain item an earlier build made.

A test fails when `docs/ai` falls behind the catalog, so a new model goes into `Sources/SparkControl/Catalog` and then
through `--catalog-export`. The format of a recipe is explained in [ai/SOUND-GUIDE.md](ai/SOUND-GUIDE.md); the
`spark-probe` commands are in [PROTOCOL.md](PROTOCOL.md#spark-probe).

## Design and pictures

One design language: the instrument stays dark, keys instead of buttons and lamps instead of icons. The desk around it
would follow the system, but AmpBench always shows it dark; the light pictures below show the light desk that tests
can still draw. [DESIGN.md](DESIGN.md) has the principles, every value and the building blocks of
`Sources/SparkDesign`. New views use those blocks; a new color or button style goes into SparkDesign and DESIGN.md
first. The icon (`Tools/make-icon.swift`) puts the record key into the amber ring of a control: recording and sound
in one sign.

| | |
| --- | --- |
| ![Record, dark](pictures/record-dark.png) | ![Record, light](pictures/record-light.png) |
| ![While recording](pictures/record-recording-dark.png) | ![At its smallest size](pictures/record-smallest-light.png) |
| ![Presets, dark](pictures/presets-dark.png) | ![Presets, light](pictures/presets-light.png) |
| ![Library, dark](pictures/library-dark.png) | ![Library, light](pictures/library-light.png) |
| ![Library, several selected, by tag](pictures/library-maintenance-dark.png) | ![Library, close sounds, smallest window](pictures/library-smallest-dark.png) |
| ![Tuner, dark](pictures/tuner-dark.png) | ![Tuner with strobe, light](pictures/tuner-strobe-light.png) |
| ![Tuner, in tune](pictures/tuner-in-tune-dark.png) | ![Tuner at its smallest size](pictures/tuner-smallest-dark.png) |
| ![Tuner of the amp, dark](pictures/tuner-amp-dark.png) | ![Tuner of the amp, light](pictures/tuner-amp-light.png) |
| ![Device choice, Spark NEO, dark](pictures/devices-neo-dark.png) | ![Device choice, Spark NEO, light](pictures/devices-neo-light.png) |
| ![REACTOR, listened to, dark](pictures/devices-reactor-dark.png) | ![REACTOR, listened to, light](pictures/devices-reactor-light.png) |

The pictures come from the app's own snapshot modes, with a test library of synthetic takes and made-up presets:

```bash
.build/debug/AmpBench --library /tmp/studio-pictures --ui-selftest pictures /tmp/studio-pictures-out
.build/debug/AmpBench --library /tmp/studio-pictures --demo-devices mini --appearance dark --size 1180x780 \
    --open saved:Lead --focus delay --delay 3 --snapshot /tmp/presets-dark.png --quit
.build/debug/AmpBench --library /tmp/studio-presets --offline --demo-devices reactor --appearance dark \
    --size 1180x780 --open slot:6 --delay 7 --snapshot /tmp/devices-reactor-dark.png --quit
```

The library's pictures use about a hundred made-up sounds (`--made-up-sounds`, only with `--library`: invented
songs as a Kemper import writes them, with pieces, recipes, slot backups, favorites and close sounds):

```bash
.build/debug/AmpBench --library /tmp/studio-library --made-up-sounds --demo-devices mini --appearance dark \
    --size 1180x780 --library-open all --library-select "Basis 1 · 2" --delay 3 --snapshot /tmp/library-dark.png --quit
.build/debug/AmpBench --library /tmp/studio-library --made-up-sounds --demo-devices mini --appearance dark \
    --size 1180x780 --library-open "#song" --library-group tag --library-select "Copper Sky Chorus,Copper Sky Intro" \
    --delay 3 --snapshot /tmp/library-maintenance-dark.png --quit
```

`--library-open` takes `all`, `favorites`, `toListen`, `close`, `backups` or `#tag`; `--library-search <text>`,
`--library-group none|tag|amp|origin` and `--library-select <name>[,<name>…]` set it up. A test library does not
remember the grouping or the recently used sounds, so pictures never change the app's own preferences.

`--demo-devices neo|mini|reactor` (only with `--library`) shows simulated devices instead of Bluetooth. On a German
system, add `-AppleLanguages '(en)' -AppleLocale en_US` to every command so the pictures come out in English.

The `pictures` scenario also shows the tuner, fed with a synthetic string through its real pipeline (no input is
opened), the count-in, a running recording (from the test device only), a piece with its
parts and the smallest window, 1120 × 720 ([Presets at that size](pictures/presets-smallest-dark.png)). `swift
test` checks the contrast of every text color of the design against its backgrounds, at least 4.5 : 1.
