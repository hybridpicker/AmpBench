# AmpBench

Spark Recorder and Spark Presets are one app: one process, one icon, one window with a fixed deck on top and the
areas below it (Record, Presets, Tuner, Metronome). Every take knows its sound, the tempo has one source, piece and song are
one thing. This document is the one place for structure, decisions and what is still to come. It replaces the earlier
work briefs (ampbench-prompt.md, spark-presets-next-prompt.md, both in the Git history). The design is in
[DESIGN.md](DESIGN.md), how to use the app in the [manual](MANUAL.md) and the [README](../README.md).

The app was called "Spark Studio" until its first publication; identifiers such as `StudioArea` and `StudioKeymap`
keep that name. The UI is English by default and German as a second language; this document quotes the English
labels.

## Status

| Stage | Content | Commit | On the device |
|---|---|---|---|
| 0 | Data model (sound of a take, parts, key), keyboard model, layout | de6f9a2 | – (no behavior) |
| 1 | One bundle, two windows, Bluetooth on demand | 21b14cc, ecfd961 | checked by the owner (2026-11-07) |
| 2 | One window with areas, sound of a take, one tempo | 6525876 | open |
| 3 | Pieces = songs, `~/Music/AmpBench`, old apps removed, new icon | 1849ef0 | open |
| – | Always in dark mode, at the owner's wish | 2814115 | installed, runs |
| – | Sound recipes, AI catalog in `docs/ai`, text for REACTOR | fed85a7, c0fadbb | installed (2026-11-08), no recipe heard on the amp |
| – | AI Sound in the area Presets: description → Ollama Cloud API → three recipes, adjusting, history | c243d07 | installed (2026-11-08), not checked against the cloud and not on the amp |
| – | Area Tuner (⇧⌘3): MPM plus a phase regression, reads the recorder's input along | 26290d0 | installed (2026-11-08); ran over USB on the MINI with a guitar (2026-11-09), not against a reference tuner |
| – | The amp's own tuner (MINI, NEO) as a source, "Automatic", Bluetooth start from the tuner | 1158c58, 6955f4e, 257b833 | command and scale checked with spark-probe on MINI and NEO; used in AmpBench by the owner on NEO and MINI (2026-11-09) |
| – | Protecting the amp (`AmpGuard`) | 7f8baed | description with 80 bytes heard on the MINI (2026-11-08) |
| – | Kemper import (backup, rigs, performances → presets and pieces) and hashtags with pinned sections | 2b498bb | installed (2026-11-10, Mac and Linux); read with the author's backup, no sound heard on the Spark |
| – | REACTOR 50: reads the eight presets after connecting (own format, checksum CRC-32/MPEG-2) and shows them like Spark slots; "Play on the REACTOR" with live commands; probe `ask`, `read-slot`, `set-one`, `switch-one`, `send-one` | 6bf59ac … 13646ee | seen and heard by the owner (2026-11-10): eight presets with names in the sidebar; gain, bass, reverb on/off and level, amp choice Clean. No preset written, no slot in the editor |
| – | REACTOR 50 like a Spark: a slot switches, opens in the editor as seven places (`ReactorBridge`), changes go live by name, "Store" rewrites the read bytes and reads back; probe `script` | 84a149b | with the probe on the device (2026-11-11): slot switch, names by marked values, store and read back on Green 4, all eight slots equal to the backup afterwards. Not yet tried from the app on the device |
| – | Linux catches up: Kemper import and hashtags, area Tuner (numpy, the amp's own tuner), AI Sound (`secret-tool`) | 78e8e58, add00c0, 7b6fd83 | installed on the Linux laptop (2026-11-10), 194 Linux tests green; not checked under Linux with guitar, amp and the real cloud |
| – | The sound store: sounds encrypted on the device (age), kept in a folder, on a server over SSH or below an HTTPS address, synced both ways; in the sidebar's foot, a sheet, File menu, `--store-*` | d4fce74 | 79 unit tests with made-up data, among them the format against the `age` tool; folder and HTTPS place run end to end from the command line with two test libraries; since 2026-11-14 the author's Mac and iPad sync 92 sounds through an HTTPS place on a server (nginx), read back whole with `--store-verify`; see "Sound store" below |
| – | iPad app: the areas Presets and Tuner and the sound store from the Mac's sources (package builds for iOS 17, `ios/` with XcodeGen), the tuner's input through AVAudioEngine | d4fce74 | four UI tests pass in the simulator (iPad Air 11-inch, iPadOS 26.5); installed on a real iPad (iPad Air 13-inch) on 2026-11-14, where the store set itself up and brought the sounds; not yet with an amp there |
| – | The library over the area Presets (⌘L / Ctrl+L): search, filters, a table with groups, a preview, tags, "To listen", favorites, renaming and the Trash for several sounds; close sounds; a short sidebar | 9c5d27e (Mac, iPad), 7e4f451 (Linux) | Mac and iPad installed (2026-11-14), `swift test`, `--menu-dump` and the iPad UI tests green; Linux tests green headless on the Mac (2026-11-15) and on the laptop, installed there (2026-11-18); nothing tried with the real 92 sounds or the amp |
| – | Levels: a loudness meter (ITU-R BS.1770, `Loudness`) and a measuring run over USB (`--level-measure`) | 1a768df, c05928c | measured on the Spark MINI (2026-11-15): 27 sounds and a master sweep; the owner's library corrected and matched by script, heard in part, not measured again; nothing of the rule in the app yet |
| – | Tap tempo on every delay: a "Tap" key in the control field sets the preset's BPM and the tempo switch to BPM, sent once after the taps | ced11d6 | 657 Swift tests and the Linux window test green; installed on Mac and iPad (2026-11-15), on the laptop 2026-11-18; not heard on the amp |
| – | Bluetooth off or not allowed: a lasting strip on top of every area with a key to the right settings, gone by itself once Bluetooth works; Linux the same, and bleak's "No powered Bluetooth adapters found." counts as off | d767958 | seen with simulated Bluetooth off (`--demo-devices bluetooth-off`); found when the owner's REACTOR was "not found" with the Mac's Bluetooth off (2026-11-16) |
| – | Bluetooth starts with the app once a device was connected here before, whichever area shows | 3ccd451 | window capture on the Mac (2026-11-16): REACTOR connected while Record shows |
| – | AI Sound's "Listen" on a REACTOR 50: the suggestion's nearest REACTOR sound as live commands on the playing slot | d099b66 | test with a simulated REACTOR; not yet heard on the device |
| – | REACTOR 50 as a recording input: "Reactor 50 USB Audio" in the profile (Mac and Linux) | 3120c9b | read on the device (2026-11-16); the deck showed "Ready" with it as input; no take recorded yet |
| – | The AI key is read when AI Sound opens, not at launch: a Keychain question after an install had held the launch before the window appeared | fea14dd | installed (2026-11-16); launch checked, AI Sound with the key not yet opened since |
| – | Area Metronome (⇧⌘4) on Mac, iPad and Linux: accents per beat, subdivisions, three sounds, tap, tempo trainer, tempo and pattern kept in a piece; C renderer on the output's sample clock (`spark_metronome_*`), Linux port on `pw-cat` | 9297313, 7125156, 617da0e | offline: two hours at 97 BPM without a millionth of a sample of drift, block-size independent, sub-sample onset, trainer, changes on the beat; seen running in a test instance on the Mac (lamps follow the beat, Space starts and stops); installed on the Mac and on the owner's iPad (2026-11-16), not yet opened there; Linux tested headless on the Mac, all Linux tests green on the laptop and installed there (2026-11-18, 40619f7), not yet heard there; heard by the owner on the Mac (2026-11-17) |
| – | Metronome follows the output on the Mac: headphones plugged in or pulled, a device coming or going, another output chosen | b5a6415 | metronome tests; the owner plugged headphones in and out while it played on the Mac and heard it move (2026-11-17) |
| – | Linux install gate: the Bluetooth banner test waited for the link's "connected", not for the window, which hears of it a queued signal later; it failed on the laptop every time and held the install back at 2ee0d57 | e5be35c | the laptop's full Linux suite green, installed there (2026-11-18), both machines on 40619f7 |
| Phase 2 | Several devices: profiles, device choice, NEO's peculiarities, listening to the REACTOR, probe `listen`, Linux | 1e59cb0 … f59743a | finding and reading the NEO, switching MINI ↔ NEO confirmed by the owner (2026-11-09); the rest see "Open" |

AmpBench has been installed in /Applications and in the Dock since 2026-11-07. At its first start it created
`~/Music/AmpBench` and took over the old folders; that all recordings and presets arrived there is not yet
confirmed.

Still to check on the Spark MINI: a take with a real preset (stamp, "To the amp", "Open in editor"), the tempo
alignment, the lamp "BT" and "Play" for pieces and parts. Also the four example recipes that have been in
`~/Music/AmpBench/Presets` since 2026-11-08: do they appear with a wand, do they sound as described, and does a
saved recipe become an ordinary preset file.

## Structure

```
AmpBench  (app: one window, areas, the connections between them; Info.plist with microphone and Bluetooth)
  ├── SparkRecorderUI  Deck and the area Record; public are only RecorderHost, RecorderMenus, DeckBluetooth,
  │                    TakeSound, SoundActions, RecorderCommandLine
  ├── SparkPresetsUI   Area Presets with the Bluetooth link; public are only PresetsHost, PresetMenus, HeardSound
  ├── SparkTunerUI     Area Tuner; public are only TunerHost, TunerMenus. No Bluetooth of its own, no sound
  ├── SparkMetronomeUI Area Metronome; public are only MetronomeHost, MetronomeMenus, MetronomeTempo (protocol),
  │                    MetronomePiece, StandaloneMetronomeTempo. No Bluetooth, no input
  ├── SparkDesign      Building blocks (DESIGN.md)
  ├── SparkCore        Recording, library, PresetStamp, pieces, StudioFolders, StudioKeymap,
  │                    pitch detection (PitchDetector, PitchTracker, Tuning, TunerEngine, AudioTap, SharedInput)
  └── SparkControl     Protocol, catalog, preset library, fingerprint, device profiles (DeviceProfile),
                       REACTOR messages (ReactorState)
```

- **The link hangs on a transport layer.** `SparkLink` talks to `LinkTransport`: `CoreBluetoothTransport` in the
  app, `SimulatedDevice` in tests and window pictures (`--library … --demo-devices`). This way tests check the NEO's
  falling back and what a REACTOR gets and never gets, without Bluetooth.

- **Hosts instead of public modules.** Every library shows the app exactly one host. The rest stays `internal`.
  `RecorderSession` (formerly Spark Recorder's AppDelegate) takes over the app's window: the Dock's REC, "the
  recording continues when the window is closed", restoring after a crash and the UI self-test refer to it.
- **One window.** The deck fixed on top (122 pt), below it the area, chosen with `SegmentTabs` in the toolbar or
  ⇧⌘1 to ⇧⌘4 (menu View). Smallest content 1120 × 720. Areas are rebuilt when switching, their state lives in
  the models (also which pieces are expanded). The recorder's sheets hang on the whole window, its messages appear in
  the area Presets on top, above the content.
- **Menus follow the area.** `AppCommands` and `PresetCommands` have `isActive`. When their area is not in front,
  they give up shared keys (⌘E, ⌘⌫, ⇧⌘R), their own rest, and ⌘Z goes to the responder chain.
  - SwiftUI rebuilds menus only when they open, so a key would otherwise still go to the old state. The app therefore
    triggers the update of all menus at every change of area (`Studio.refreshMenus`). `--menu-dump` checks this with
    a real key press.
  - The recorder's group "Move to Trash" stands after `.pasteboard`: Presets replaces `.undoRedo`, and SwiftUI
    leaves out groups that hang on a replaced one.
- **Always dark.** The app sets `NSApp.appearance` to dark at start, also for the desk, independent of the system
  setting. The light values from DESIGN.md stay valid; `--appearance light` and the picture self-test still draw them.
- **Bluetooth at start once known.** On a first launch there is no `CBCentralManager` at start, so no Bluetooth
  prompt; it connects when the area Presets or Tuner first shows. Once any device was connected here before
  (`SparkLink.knowsDevices`, the remembered devices), Bluetooth starts with the app (since 3ccd451), so the amp is
  found while Record shows. Either way it starts only once, otherwise "Disconnect" would not hold until the next
  launch; the key "Connect" at the foot of the sidebar, the lamp "BT" in the deck and the menu connect again. Test
  libraries (`--library`) keep the old way, so pictures never reach for a real amp. State `.off` reads
  "Disconnected". A Bluetooth error is reported and never ends a recording.
- **Bluetooth off says so.** While Bluetooth is off, not allowed or missing and the link is wanted, a strip on top
  of every area says why the amp is not found (`BluetoothHint`; in Presets over the editor, since the system
  sidebar draws itself above anything laid across it). Its key opens the Bluetooth settings, or Privacy & Security
  when access is missing; on the iPad only access can be opened. It goes away by itself once Bluetooth works;
  closing it hides it until the state changes.
- **Nothing waits for the Keychain at launch.** The AI key is read when AI Sound first opens
  (`PresetsModel.loadAIKeyOnce`); after an install macOS may ask whether the new build may read it, and that
  question must not hold up the window.

### Metronome

- **The audio thread decides.** `metronome.c` places every pulse at `anchor + k × interval` output frames (a
  product, never a running sum) and starts its sound at the pulse's fraction of a frame: oscillator and envelope begin
  already advanced by the part of a frame before the first sample. A new anchor is set only where the interval
  changes: a new tempo from the window or the trainer, or a new subdivision, at that pulse's exact position. Voices
  end on the sample where they fade out, so the output does not depend on the block size. Settings travel to the
  audio thread through a seqlock and take effect on the next beat; the trainer counts bars on the audio thread.
- **The lamps follow the sound.** Every pulse goes into a lock-free ring with the host time it is heard (the block's
  output time plus the device's reported output latency); the view lights a lamp when that time has come
  (`TimelineView`, Linux a QTimer of 8 ms). The light is as late as the screen, never early.
- **Output:** AUHAL on the deck's output on the Mac (`MetronomeEngine`), RemoteIO on the iPad with the session's
  output latency, `pw-cat` on Linux paced through a one-page pipe. No Swift and no Python allocation decides a
  pulse's time.
- **Following the output (Mac).** AUHAL stays on the device it was started on, and "system output" resolves to a
  device at start. Headphones in the Mac's jack are a device of their own ("External Headphones") and mute the
  speakers, so the click went silent (b5a6415 fixes it). `MetronomeModel` now listens for the default output and the
  device list (`AudioDevices.observeDefaultOutput`, `observeDeviceList`) and checks on every tempo change; when the
  target (the chosen output if it still exists, else the system's) differs from `MetronomeEngine.device`, it stops and
  starts again there, since the new device may run at another sample rate. RemoteIO and PipeWire follow on their own.
- **One tempo.** On the Mac the area works on the recorder's `MetronomeSettings` through `MetronomeTempo`
  (`RecorderMetronomeTempo` in AmpBench); `MetronomeSettings` gained `pattern` and `trainer` (older settings decode
  with the defaults) and moved to its own file, available on the iPad. The iPad uses `StandaloneMetronomeTempo`.
  A piece keeps `meter` (beats per bar and pattern) beside `bpm`; "To metronome" brings both.
- **Stepping aside.** A recording, a count-in or a playing take stops the metronome (they bring their own click on
  the same tempo); it does not start while they run. It keeps playing across areas.
- **Keys:** Space in the area Metronome goes to the metronome through `RecorderHost.routeAreaKeys` (asked before the
  recorder's single keys, same rules); `⌃⌘M` from every area; `⌘T`, `⌘↑`/`⌘↓`, `⇧⌘↑`/`⇧⌘↓` in its scope.

### Adding an area

For another app, such as a tuner or setlists:

1. A new library `Sources/Spark<Name>UI` with a `<Name>Host` (content as `AnyView`, menus as `Commands` with
   `isActive`), depending on SparkDesign and what it needs. A target in Package.swift, a dependency of AmpBench.
2. A new case in `StudioArea` (Sources/AmpBench/Studio.swift). ⇧⌘ plus the next digit and the tab follow from it.
3. One line in the `switch` of `StudioWindowView` and one in `StudioCommands`.
4. A scope in `StudioKeymap` with all keys of the area. `StudioKeymapTests` reports every key used twice.
5. Single keys stay reserved for the area Record, except R and Space.

## Sound store and iPad

Decisions, with the reasons. How the store works is in [STORE.md](STORE.md), the iPad app in
[ios/README.md](../ios/README.md).

- **One code base for the iPad.** The iPad app is not a second app: the package builds for iOS, and the same
  `PresetsHost` and `TunerHost` fill its window. What differs sits in few places: `SparkDesign/Platform.swift`,
  `#if os(macOS)` around the HAL engines in SparkCore, `Texts.forPad` for "this iPad". A new view must not ask which
  platform it is on; it uses those helpers.
- **Record is not on the iPad.** `CaptureEngine`, `PlaybackEngine` and `ClickEngine` are AUHAL with the Mac's device
  list and rate switching. iPadOS has one route and RemoteIO; that is a second engine, and it cannot be checked
  without an iPad and the amp. The iPad has `PadInput` (AVAudioEngine) for the tuner only.
- **The age format instead of an own one.** A store must be readable in ten years and without this app. age is a
  small, specified format with a reference tool; the tests encrypt and decrypt against it in both directions.
- **A random key, not a password.** The key is 256 bits from the system, so the store's strength does not hang on a
  password's, and no key derivation is needed. The price: the user must carry the key to the other device once.
  It is shown only on request and copied as a secret.
- **The place needs GET and PUT, nothing else.** The index names every object, so nothing lists a directory. That is
  why a plain web server, a WebDAV folder, a folder in a cloud drive and `ssh` with `tar` all work, and why the iPad
  can reach a server without SSH.
- **Nothing is deleted in the store.** A sync that goes wrong must never cost a sound. Removed and overwritten
  sounds stay as objects; here they go to the Trash.
- **No secret in the repository.** Key and password: keychain. Place: preferences. Team id: `ios/Local.xcconfig`.
  Tests use a keychain service and preferences of their own, and a test library gets a store profile apart from the
  real one (`StoreProfile.testing`).
- **In the sidebar's foot**, under the connection, with the same lamp and key as the connection: a sound goes to the
  amp or to the store from there, and no new area or window was needed.

- **One HTTPS place for every device.** The first backup went over SSH, which the iPad does not have. Rather than
  one folder written by two server users, the store moved below an HTTPS address of the web server that is there
  anyway (PUT and GET only, Basic auth, nothing deleted, no listing; the example in STORE.md), and the Mac uses the
  same address. The password was made on the server and went into the keychain through a pipe.
- **Signing the iPad app without an account in Xcode.** `ios/build.sh --device` can build unsigned and sign by hand
  with a development profile that is already on the Mac (`AMPBENCH_PROFILE` in the untracked `Local.xcconfig`), so
  a Mac whose Xcode has no account signed in can still install.

Open: Record on the iPad; the store's window on Linux (the laptop syncs the real store from the command line since
2026-11-16, 92 sounds read back); a view for earlier versions and removed sounds;
a lock for the index; Presets and Tuner on the iPad with an amp.

## Tuner

A chromatic tuner with string detection for guitar and bass, 30 Hz to 1.4 kHz (B0 to above E6), shown to
0.1 cent, concert pitch A4 430.0–450.0 Hz in tenths of a hertz (UserDefaults `tunerA4`), the tunings Standard, Drop D,
DADGAD, Open G, half a step down and chromatic (`tunerTuning`), needle or strobe (`tunerStrobe`).

A second source, chosen by the user: **the amp's own tuner** (Spark MINI and NEO, below), so that the NEO, which has
no USB audio, can be tuned too. Coarser, in whole cents, and the amp is silent meanwhile.

### Where the audio comes from, and why this way

- **Reading along instead of a second audio unit.** The recorder's `CaptureEngine` also writes every block into an
  `AudioTap`: a lock-free ring buffer (one writer, one reader, `CSparkRT/tap.c`) with the mean of all channels.
  In the callback nothing is allocated, nothing locked and nothing logged; the buffer is touched when it is created,
  so that no page is loaded later. When the reader falls behind, the newest frames are dropped and counted.
- **Why not a unit of its own on the Spark:** `CaptureEngine.open` sets the device to its highest rate and back
  when closing. Two units on the same device could thus change the rate under a running recording – the recording
  then ends with "Sample rate changed". Reading along cannot do that: there is only the one unit.
- **Rules for sharing** (`AppModel.startTuning/stopTuning`, through `SharedInput`): the tuner opens the input only
  when it is closed, and closes it only when nothing else needs it (`isTuning` stands in every closing condition
  next to recording, retro and "Check input"). A running recording and the retro buffer are never reconfigured or
  ended. When the recorder switches retro on or off, it opens the input anew; the tap stays on the engine and keeps
  reading (a short gap for the tuner, none for the recording). While the tuner listens, the input counts as open
  (`isListening`): the deck shows the level, the measurements are blocked.
- **Other inputs** (USB interface, the Mac's microphone) get a `CaptureEngine` of their own with
  `InputPolicy.listenOnly`, without a rate change (`raiseRate: false`) and without ever recording. The tuner never
  opens a Spark device itself; with a test library there is only the deck's input.
- **Only while the area is in front:** the app switches the tuner on when the area is chosen and the window is
  visible (not closed, not in the Dock, not covered), otherwise off. Then the tap is released and the input closed,
  unless the recorder keeps it open anyway. The only exception is the synthetic string of the window pictures, which
  opens no device.
- **No contact of its own to the amp, no sound:** SparkTunerUI does not depend on SparkControl or SparkPresetsUI, so
  it can use neither Bluetooth nor the link itself. There is no output. The amp's own tuner comes only through the
  protocol `AmpTuner` (SparkCore), which the app fulfills with the existing link of the presets.

### The amp's own tuner (MINI, NEO; checked on the devices on 2026-11-09)

- **Protocol:** `01 65 C3` switches it on, `01 65 C2` off; MINI and NEO confirm with `04 65` (the MINI left the
  confirmation for switching off out once in three times). While it is on, the output is silent (the MINI's speaker
  and the NEO's headphones, heard by the owner), and about 15 times a second `03 64 <note> CA <float>` arrives: note
  0 (C) to 11 (B), value 0 to 1 across a semitone, −1 without a signal. After switching off, 3–5 more values follow.
  Then the amp sounds as before (heard on both).
- **Scale:** cents = (value − 0.5) · 100 (`SparkProtocol.tunerCents`). At the edge 0/1 the note jumps to its
  neighbor, so the window is one semitone. Checked with `spark-probe --compare tuner` on the MINI against the pitch
  that the app measures over USB: E +24 cents → median 0.63, A −32 cents → 0.13 (slope 0.009 per cent), tuned
  strings around 0.5. The single values jump by about ±10 cents, especially at the attack. The MINI's USB audio keeps
  running while the tuner is on.
- **Display** (`AmpTunerInterpreter`): median of the last 0.4 s, whole cents, a new note only after three values in
  a row, "In tune" at ±3 cents for 0.5 s, held for 1.5 s after the signal. The amp names only the note, not the
  octave: the string of the tuning with this note gives it, when there is exactly one; for E in Standard (6th and
  1st string) the display shows only "E" without octave and hertz. A concert pitch other than 440 Hz shifts the cents.
- **When it is on:** the input stands on **"Automatic"** by default (`tunerSource`): when the connected device has
  USB audio and is plugged in (MINI), the tuner listens over USB, more exactly and without muting the amp;
  when it has none (NEO) or no Spark is plugged in over USB, it takes the amp's own tuner. When a device comes or
  goes, "Automatic" follows. The deck's input, "Tuner of the Spark NEO/MINI" and other inputs can still be chosen
  explicitly. The amp's own tuner is on only while the area is in front and visible.
  When the app shows the tuner before the area Presets, it starts the Bluetooth connection (once, like Presets; not
  after "Disconnect"). Leaving, another input, disconnecting through the deck
  or a change of device, and quitting the app (`applicationShouldTerminate` waits up to 1.5 s) switch it off first.
  Without a confirmation it counts as off as soon as no more values arrive; otherwise up to three attempts. If the
  connection breaks while it is on, the link switches it on or off after reconnecting, depending on what is wanted
  (whether the amp leaves it on without a connection is unchecked). A REACTOR's tuner is never switched from here.
- The tuner's values do not keep a running request alive (waiting for an answer does not count them).
- **Privacy:** audio is analyzed in memory only and never stored, sent or logged; the ring buffer is zeroed when it
  is released. No network. All tests use synthetic signals (`TunerTestSignal`).

### The detection (`PitchTracker`, every 5 ms, on its own thread in `TunerEngine`)

1. **Level and attack:** RMS over 20 ms or two periods, threshold −60 dBFS on, −66 off. An attack lifts the level to
   double that of the 25–80 ms before it; its first 20 ms stay out. A high-pass at 10 Hz removes a DC offset that
   would otherwise never let the NSDF become negative.
2. **Coarse: MPM (McLeod).** NSDF through FFT (vDSP), first key maximum ≥ 0.9 × the highest, parabolic
   interpolation. A value counts only when the block has also seen the octave below it (two periods of it) – so the
   first value of a low string cannot be its second harmonic.
3. **Locking with octave protection:** three agreeing values (±30 cents). After that, values an octave, a twelfth
   or a fifth away count as overtones or undertones and are ignored until the next attack; another note needs three
   agreeing values. A clarity of 0.5 is enough to hold, locking needs 0.8.
4. **Fine: phase and regression line.** Every block (12 periods, at most 0.45 s, Hann window symmetric about the
   middle of the block) is demodulated at the locked frequency. For a tone off by δ, the phase of the block's middle
   grows by exactly δ per sample, also while decaying; a weighted line through the phases over up to 60 periods
   (0.6–2 s) gives the frequency. A second demodulation at 1.5 times the frequency measures the noise beside it: from
   it come the expected spread (`PitchReading.uncertainty`) and the threshold above which a short line (80 ms)
   reports "the peg is being turned" and the long one is discarded. Without this threshold a quiet tone chased its
   own noise.
5. **Smoothing:** median of five, then exponential, slow for a held tone (0.12), fast for a change (0.35
   from 0.6 cents, 0.7 from 2 cents). When the string decays into the noise, its last exact value stays, not the
   noisy one. After the tone the value stays for 1.5 s as "held".
6. **Display** (`TunerInterpreter`): the nearest string of the tuning up to ±300 cents, otherwise the nearest note
   chromatically, with some hysteresis at the border. "In tune" at |deviation| ≤ 0.5 cents for 0.4 s and an expected
   spread ≤ 0.2 cents. In German the notes carry German names (H, and B for B♭).

## Sound recipes for AI assistants

A sound recipe (`"format": "spark-sound-recipe"`) describes a sound independent of a device: model and values per
place, knobs 0–10, parameters through fixed English keys (`ParameterInfo.key`). `PresetLibrary` reads recipes in the
folder Presets like presets (`SavedPreset.isRecipe`, a wand in the sidebar); only saving writes them as a preset
file. The uuid comes from the SHA-256 of the file, so it stays the same when read again. A faulty recipe stands under
"Not readable", and `AmpBench --recipe-check` names the reasons.

- Guide, catalog, schema and examples: `docs/ai`. The catalog there is written from the code with
  `--catalog-export docs/ai`, and `SoundRecipeTests` fails when it falls behind.
- Project skill `spark-sound` for Claude Code in this repository.
- AI Sound in the app: the description text goes to Ollama Cloud (`https://ollama.com/api/chat`), the answer is
  checked through the same `SoundRecipe` path and written as a recipe (`PresetLibrary.addRecipe`, `SoundAI`,
  `OllamaCloud`).
  - Beside the catalog, the system prompt carries typical signal chains of guitarists and styles, the rule song
    tempo → delay time, reverb by style and three valid example recipes (`SoundAIKnowledge.swift`). Tests check that
    every model id in it is in the catalog and that every example reads without a warning.
  - Three variants with different leanings (true to the original, more punch, reduced) run in parallel and
    appear one by one as soon as they are ready (`SoundAI.variants`). When a finished variant equals another
    (same amp and same drive), it goes back once with the request for another amp.
  - The quick keys "warmer", "more gain", "less reverb", "brighter" send the recipe back with a follow-up request
    (`SoundAI.refine`). The answer must keep the models and move in the demanded direction, otherwise it goes back
    once; if that still fails, the app turns the obvious knob itself and says so.
  - Robust: a retry on network errors, 429 and 5xx (after 1.5 s and 4 s), a time limit of 120 s per request, clear
    messages for a wrong key, an unknown model, the time limit and answers without JSON. Cancel stops all
    requests; closing the window does too.
  - A history of the last 8 wishes in UserDefaults (`AI Sound History`; on Linux the same key in QSettings,
    `~/.config/local.ampbench/AmpBench.conf`), which can be cleared in the window. A kept
    sound carries the wish in its description, and tags for AI Sound and the adjustments made.
  - Privacy: only rules, catalog, the wish text and, for a follow-up request, the recipe itself go out,
    with the fixed User-Agent `AmpBench`. A wish with an e-mail address, a phone number or something key-like
    is refused before sending (deterministic patterns, `SoundAI.privacyProblem`), at most 200 characters. The
    key lies in the keychain (this Mac only, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) and stands only
    in the Authorization header. Network traffic only when asked for.
- REACTOR (a product line of its own, not Spark-compatible according to Positive Grid, no file format documented):
  the only way is text. `--recipe-prompt` describes a recipe or preset in English for "Text to Tone"
  (`SoundRecipe.toneDescription`).
- The Spark MINI and the Spark NEO are checked (section "Devices"). Other Spark amps are not checked; the
  REACTOR takes recipes only as text.

## Kemper import

Presets ⇒ "Import from Kemper …" (File menu and "+" in the sidebar) reads a Kemper backup
(`.kpabackup`, from the USB stick) or a rig (`.kipr`) and turns it into Spark presets and pieces. Read-only: nothing
ever goes to the Kemper, the file is not changed. `--kemper-list <file>` shows the same on the command line.

- **Format** (`SparkControl/Kemper`): a `.kipr` is a MIDI-like frame (`KThd`/`MThd`, `KTrk`/`MTrk`) with
  Kemper SysEx (`00 20 33`): function 02 sets parameters from a number on (14 bits, 8192 = middle), 03 strings.
  A backup is a tar with `Rigs/*.kipr` and `repository.kdb` (SQLite: `perflist`, `perfs`, `perfslots`,
  `perftracks`). The slots of a performance are the same SysEx events without a frame, their names
  (performance 0, slots 1–5) stand as function 07 in `perfs`. Pages from Kemper's "MIDI Parameter Documentation"
  11.0: 4 rig (tempo = BPM × 64), 10 amp (4 = gain), 11 EQ (4–7), 50–53 stomps A–D, 56 X, 58 MOD, 60 DLY, 61 REV,
  75 the old reverb up to OS 5 (2 on, 3 mix, 6 time). The amp strings stand six higher in the files than in the
  documentation (16 name, 21 manufacturer, 24 model). Effect types from appendix B (`KemperEffectType`).
- **Placeholders:** Kemper's own "Crunch" (amp "Crunch Amp", date field "AmpCreationDateTag") and slots without
  an amp name count as empty. The import does not offer untouched performances ("New Performance", "Example …").
- **Translation** (`KemperTranslation`): a profile is a capture of a real amp, the Spark computes with
  models. Therefore: the nearest Spark amp by keywords in manufacturer, model and rig name (first matching
  rule, some only from gain 4 on; Kemper's cover names such as "Mars", "Fan" are included), otherwise by gain. Gain
  as on the Kemper, bass/middle/treble = 5 + Kemper EQ (−5…+5), half the presence into the treble, master 6.
  Switched-on effects go to their Spark places; DLY and REV before a delay in MOD or X. Delay and reverb level =
  Kemper mix × 0.4, between 1 and 4.5: the Kemper adds them to the dry signal, and its mix is often all the way up.
  What the Spark does not have, or what would hit an occupied place, stands under "Without" and in the preset's
  notes. Every sound needs a listening test.
- **Plan** (`KemperImportPlan`): per own performance song, basic setup, lesson or "Do not import"
  (guessed from the name, changeable in the window), single rigs to tick. Equal titles get the number of the
  performance. A sound is called "Performance · Slot"; equal Spark sounds (same fingerprint of the chain) are
  one preset with the tags of all places.
- **Result:** presets with the tags `kemper`, `clean|crunch|drive`, `song|basis|unterricht` and the performance name
  as a hashtag (`CantStop`). A second import only adds the tags when name and chain are the same. Songs become,
  through `PresetsHost.onImportSongs` → `RecorderHost.addPieces`, pieces with parts, each part with its preset; a
  title that already exists stays unchanged. `basis`, `song` and `unterricht` are pinned on import (the stored tag
  names are German in this release: `basis` is a basic setup, `unterricht` a lesson).
- Checked on 2026-11-10 with the author's backup (Profiler Head, OS 5.4.1): 194 rigs, 32 own performances,
  81 presets, 20 pieces. None of the sounds has been heard on the Spark yet.

## Levels

The owner's wish (2026-11-14): every sound is about equally loud; a solo or lead sound may be a few dB louder, as is
usual, but no big jumps. This holds for every sound in the library, Kemper imports and Positive Grid's own alike.

- **Where the jumps come from:** the Kemper import gives every sound master 6, whatever its gain and amp model
  (`KemperTranslation`), so a clean sound and a high-gain sound land far apart. The library held 83 presets and
  5 recipes on 2026-11-14; two amp models carry most of them (94MatchDCV2 31, Plexi 26), 22 names contain "solo"
  or "lead".
- **The meter** (`SparkCore/Loudness`): integrated loudness after ITU-R BS.1770 in LUFS, K-weighted, in blocks of
  400 ms every 100 ms, with the absolute gate at −70 LUFS and the relative one 10 LU below the mean. Pauses between
  notes therefore do not count. The filters are computed for the sample rate at hand. A full-scale sine at 997 Hz
  reads −3.01 LUFS at 44.1, 48 and 96 kHz.
- **The measuring run** (`AmpBench --level-measure <plan.json> <results.json> [--level-seconds N] [--level-pause N]
  [--quit]`): the plan is a list of `{"label", "file"}`. The app connects to the amp, plays each sound on the
  temporary place (nothing is stored), waits 1.5 s, measures N seconds of the amp's USB audio through the
  recorder's shared input, rests (3 s by default) and writes the results after every sound (LUFS, peak, share of
  blocks kept, a problem if there was one). It ends at the first sound the amp does not answer. The owner plays the
  same thing throughout; the app switches.
- **Measured on the Spark MINI on 2026-11-15** (the owner playing one pattern; all values at that playing):
  - Two trials of four sounds repeated within 2 dB; a control sound read −42.9 and −42.8 LUFS at the start and in
    the middle of the long run.
  - 27 sounds as imported, all at master 6: clean sounds −51 to −40 LUFS, crunch −38 to −27, drive and solo −23 to
    −20. The spread is about 30 dB.
  - The amp hung in that run: sound 28 came back silent (it had gain 0), sound 29 was not answered, and the amp
    needed switching off and on. The run then had no rest between sounds and kept trying; both are changed. Whether
    the number of sounds or that one sound caused it is open.
  - Master, on one clean and one drive sound: about 20 dB per decade of master on the clean sound (0.3 → 1.0 gave
    +10 dB), about 11 dB per decade on the saturated one (0.1 → 0.6 gave +8.5 dB). Master alone therefore cannot
    close the spread.
- **The cause:** the import copied the Kemper's gain one to one. A Spark amp at gain 2 to 3 is nearly off, and at
  gain 0 it is silent; on the Kemper a clean profile sits there at full level.
- **The model** fitted to these measurements: loudness at master 0.6 = `Lmax(amp) − 45 · exp(−3.27 · gain)` in
  LUFS, gain from 0 to 1 plus what stands in front of the amp (compressor about 0.12, a drive pedal about 0.25, the
  booster 0.7 × its gain above 0.5). `Lmax` is −24.1 for 94MatchDCV2, −18.0 for Plexi, −16.0 for
  OverDrivenLuxVerb, −15.7 for Bogner, −29.0 for RolandJC120; guessed at −24 for the other clean amps and −18 for
  the rest. Master adds between 11 and 20 dB per decade, by how far the sound is from saturation. On the 27
  measured sounds the model is off by 1.6 dB RMS, 4 dB at worst.
- **What was done to the owner's library on 2026-11-15**, with scripts kept beside the backups in
  `~/Music/AmpBench/Levels`, not yet by the app:
  - Imported sounds: gain = max(Kemper gain / 10, 0.40 + 0.03 × Kemper gain); a slot called crunch gets at least
    0.55 with what stands in front, one called drive or heavy 0.62. The wah of the paid add-on, which the import had
    switched on in four sounds, is off: without a pedal it is a fixed filter, and the amp may refuse the model.
  - Every preset and recipe: master from the model for −30 LUFS, +3 dB when the name contains solo or lead; when
    full master does not reach it, more gain. The owner's own sounds got the master only.
  - After listening the owner found the drive sounds short of drive. The 27 sounds tagged `drive` got more gain,
    and where the drive place was free a pedal in front (KlonCentaurSilver before Plexi, DistortionTS9 elsewhere).
    "Two Princes" (BE101 with more gain, no pedal) fitted, "Dracula" (Plexi with the pedal) still had too little;
    the nine Plexi sounds from Kemper gain 7.7 on therefore moved to BE101 without the pedal. Not heard since.
  - Each sound's notes say what changed. Backups: `Presets-before-2026-11-15` and
    `Presets-before-more-drive-2026-11-15`.
- **Not checked:** no second measurement after the changes. The amps that were not measured (Twin, Bassman,
  Deluxe65, AC Boost, BE101, Checkmate, ODS50CN and those of the recipes) are estimates. Eleven drive sounds stand
  at the lowest master the scripts allow (1) and may be a little too loud. Whether master moves the speaker's level
  as it moves the USB level is open. Everything is now about 8 dB quieter than the drive sounds were.
- **Not built yet:** the rule in the app: the gain mapping and the master in the Kemper import instead of gain one
  to one and master 6, the Plexi and pedal findings in the amp choice, a way to match a library from the app, and
  all of it in the Linux app. To be done once the owner's ears and a second measurement confirm the rule.

## Timing review

The owner's wish (2026-11-23): be sure that a take recorded with the click lies exactly on its bars, then see the
own timing against the click note by note, including playing laid back on purpose. Decided with the owner on
2026-11-23; the terms are those of [GLOSSARY.md](../GLOSSARY.md). Status: the click latency per amp is built, and so are
the timing stamp of a take and a first review on quarters with one line in the area Record (`TimingReview` in
SparkCore; worst onset error on clean synthetic plucks 0.03 ms, the BlackHole loop at half a sample), and the timing
band on the Mac (`TimingBand` in SparkCore says what it shows, self-test scenario `timing`); the rest is spec.
The guiding rule is "no number rather than a wrong number".

### Problem Statement

The owner records with the click and wants to work on timing: be exactly on the beat, or deliberately behind it
(laid back). Two things stand in the way. First, the bars of a take are only as exact as the click latency they
rest on, and the amp's part of it was never measured, so the bars of every real take still carry the amp's
internal delay. Second, the app shows bars and a waveform but says nothing about where the notes were played: on a
3-minute waveform a pixel is about 100 ms wide, and 20 ms behind the beat cannot be seen at all. The owner wants
numbers they can trust and a picture in which the steady click and their own onsets stand side by side.

### Solution

First the click latency of the amp is measured once on the Mac, with an earbud held on the pickup or a cable. From
then on every new take recorded with the click on throughout gets a timing review: below the waveform a timing band,
showing the two bars around the playhead magnified around every beat, shows the fixed click lines with their beat numbers and the
player's onsets as strokes behind or before them, each with its offset in milliseconds. Per take the review gives
placement (where the player sits), spread (how steady, the main number) and review accuracy; per bar a colour shows
the steady and unsteady bars. Laid back is shown as placement, never as an error. Where a review would not be
exact, there is none, and one line says why. The loop probe proves the precision before the owner relies on it.
Live timing while playing comes next, then Linux and the iPad.

### User Stories

1. As the owner, I want to measure the amp's click latency once without a special cable, so that the bars of my
   takes no longer carry the amp's internal delay.
2. As the owner, I want the measured amp part to hold for every wired output of the Mac, so that I can hear the
   click on headphones or on the built-in speakers without measuring twice.
3. As the owner, I want the output's own part of the latency to come from what the device reports, so that
   switching between headphones and speakers stays exact.
4. As the owner, I want a measurement whose clicks spread more than 2 ms to be refused, so that a bad measurement
   never becomes the base of my bars.
5. As the owner, I want a hand-set correction to stay possible, so that the bars can still be corrected for a
   setup I cannot measure.
6. As the owner, I want a hand-set correction to enable no timing review, so that every number I see rests on a
   measurement.
7. As the owner, I want every new take to remember whether the click was on for its whole length, so that a take
   where I switched the click off is not judged against a click I did not hear.
8. As the owner, I want every new take to remember the click latency it was recorded with and whether it was
   measured, so that its review stays right after I measure again or change devices.
9. As the owner, I want every new take to remember whether the click went to a wired or a Bluetooth output, so
   that a take with an unsteady click path gets no review.
10. As the owner, I want a timing review for every take that qualifies to appear on its own below the waveform, so
    that I do not have to ask for it.
11. As the owner, I want to fold the timing band away, so that the waveform has the room when I only listen.
12. As the owner, I want a take that does not qualify to say in one line why ("recorded without the click", "click
    latency not measured", "click on a Bluetooth output", "recorded before the measurement", "accuracy not good
    enough"), so that I know what to change.
13. As the owner, I want takes from before the measurement to get no review, so that no old take shows a number
    that might be off.
14. As the owner, I want the click lines in the band to stand still with their beat numbers 1, 2, 3, 4, so that I
    see the steady click as the reference.
15. As the owner, I want my onsets as strokes beside the click lines, so that I see at a glance whether I am on,
    behind or ahead.
16. As the owner, I want each stroke to carry its offset in milliseconds, positive for later, so that laid back
    reads as "+18 ms" and not as a percentage of a beat.
17. As the owner, I want the band magnified around each beat to about ±60 ms, so that 10 to 40 ms are clearly
    visible even in a long take.
18. As the owner, I want the band to show the two bars around the playhead and to follow playback, a click into the
    waveform and a selection of bars, so that a stroke and the note I hear belong together.
19. As the owner, I want the onset of a strummed chord to be its first string, so that a slower strum does not
    count as playing later.
20. As the owner, I want only the first onset near a grid point to count, so that delay echoes and later strings
    of a chord do not count as notes.
21. As the owner, I want to choose the grid: quarters, eighths, sixteenths or triplets, so that the review matches
    what I practise.
22. As the owner, I want the grid to start at quarters, the beats the click plays while recording, and a piece to
    keep the grid I chose for it, so that the usual case needs no choice.
23. As the owner, I want an onset to belong to a grid point only within 35 % of the grid spacing, so that a late
    eighth is never counted as an early next one.
24. As the owner, I want onsets outside every catch window to be shown faint and not counted, so that fills and
    passing notes do not distort the numbers.
25. As the owner, I want onsets detected too unsure (quiet notes, legato, swells) to be shown faint and not counted,
    so that the numbers rest only on clear attacks.
26. As the owner, I want the placement of the take, so that I know where I sit against the click on average.
27. As the owner, I want the spread of the take as the main number, so that steady laid back playing counts as good
    timing.
28. As the owner, I want the review accuracy shown next to the numbers, for example ±1 ms, so that I can trust
    them.
29. As the owner, I want no review when its accuracy is worse than ±2 ms, so that I never practise against a wrong
    number.
30. As the owner, I want each bar coloured as steady or unsteady, so that I find the weak spots at once.
31. As the owner, I want the placement and spread of a bar when I point at it, so that I can compare bars.
32. As the owner, I want to loop or record again the unsteady bars with the bar tools I already have, so that
    practising follows straight from the review.
33. As the owner, I want a take recorded again for some bars to get its own review, so that I see whether the bars
    got better.
34. As the owner, I want a hint when the take's sound has a delay ("delay in the sound, echoes may count as
    notes"), so that I know to choose a dry sound for exact practice.
35. As the owner, I want the loop probe to show a placement of 0 ± 1 ms and a spread below 1 ms, both through the
    headphone output and through the speakers, so that the precision is proven before I rely on it.
36. As the owner, I want a check take of muted strums on the click to show a plausible placement, so that the
    whole path is confirmed with my real guitar.
37. As the owner, I want the band, its numbers and its reasons in English and German, so that the app reads the
    same as everywhere else.
38. As the owner, I want the band to follow the app's colours, with red only for recording, so that early and late
    do not look like an alarm.
39. As the owner, I want VoiceOver to read a bar's placement and spread, so that the review does not depend on
    seeing the strokes.
40. As the owner, I want the same view later on Linux and the iPad, so that the timing review is one piece on
    every device once it is precise on the Mac.

### Implementation Decisions

- **Order of work:** (1) the measurement with the owner on the MacBook, with today's "Record → Measure click
  latency", no new code; (2) the review module in SparkCore, test first with generated audio; (3) the click latency
  per amp and the timing stamp of a take; (4) the timing band in the area Record on the Mac; (5) acceptance with
  the owner: loop probe, check take, real playing including laid back. Steps 1 and 2 do not depend on each other.
- **Click latency per amp, not per pair:** until 2026-11-23 the correction was stored per pair of input and click
  output. It moved to the input (the amp, `AmpLatencies` in SparkCore): its measured part holds for every wired
  output of the computer, the output's part comes from the device's report as before. A measurement keeps its value,
  its spread and its date. A hand-set value is marked as hand-set; it still corrects the bars but enables no review.
  Values stored per pair before this change carry over as hand-set, except the one measured with the owner on
  2026-11-23 (the Spark MINI with the built-in headphone output), which carries over as measured with spread 1.2 ms;
  it is found by the shape of its pair key. The per-pair values stay stored, so an older build still finds them.
- **Bluetooth click outputs** are recognised by their transport type. Their bars are corrected as today, but their
  takes get no review.
- **Timing stamp of a take:** a new optional part of the take's library entry, written only by recordings made
  after this change: the click on for the whole take (switching the click off at any moment clears it), the click
  latency used (output part, input part, amp part, measured or hand-set, the measurement's spread) and the click
  output's kind (wired or Bluetooth). Older entries decode without it, the same way the sound of a take was added;
  a take without a stamp gets no review. A take rebuilt after a crash gets no stamp, since whether the click stayed
  on cannot be known. The stamp is saved before the recording's click state and latency are reset at the stop.
- **The review module (`TimingReview` in SparkCore):** one pure entry point. In: the take's samples and sample rate,
  its bars, its timing stamp, the chosen grid resolution and whether its sound has a delay. Out: either a review or
  "no review" with one reason. A review holds every onset (time, grid point, offset in ms, counted or why not), the
  placement, spread and number of counted onsets per take and per bar, the review accuracy and the hints. It knows
  nothing of devices, files or the UI, so the Linux port can follow it line by line.
- **Reasons for no review**, checked in this order: no bars; the click not on throughout; no timing stamp (recorded
  before this change); the amp part not measured; a Bluetooth click output; review accuracy worse than ±2 ms; too
  few counted onsets.
- **Onset:** the first attack of a note or strum, found in the recorded signal as the amp sends it over USB, with
  effects. For a strummed chord the first string counts. The detector must place a clean synthetic pluck within
  1 ms. An onset it is unsure about (low level against the take, slow rise) is kept but not counted.
- **Grid points:** quarter, eighth, sixteenth or triplet on the take's bars. The default is quarters, because the
  click plays only quarters while recording, whatever the metronome's pattern; a grid chosen for a take is kept by
  its piece and used for that piece's takes (quarters: owner, 2026-11-23; keeping the choice per piece is proposed,
  not yet confirmed). The catch window reaches 35 % of the grid
  spacing to each side; only the first onset in it counts.
- **Numbers:** offset in milliseconds, positive later than the click. Placement is the mean of the counted offsets.
  Spread is their standard deviation around the placement, the main number. Review accuracy combines the
  measurement's uncertainty, half the stored spread (which is the range from the earliest to the latest click), with
  the detector's uncertainty; above ±2 ms there is no review. There is no target
  placement: the owner decided against it, the review only shows where the player is.
- **Delay in the sound** is read from the take's sound snapshot by the layer that knows the preset format
  (SparkControl) and handed to the review as a flag. It gives a hint, not a refusal. A delay counts when it is
  switched on: a delay model of the catalog, or an unknown model on the delay place of a full chain. A take without
  a snapshot gets no hint. Built; whether a reverb tail needs a hint too is open and asked of the owner.
- **The timing band:** below the waveform in the area Record. The waveform has no zoom and always shows the whole
  take, so the band does not follow a zoom: it shows the two bars around the playhead, each beat magnified to about
  ±60 ms, follows playback and jumps to a click into the waveform or to selected bars (owner, 2026-11-23). The
  waveform stays as it is. Click lines fixed with their beat numbers, onsets as strokes with their offset, faint
  for onsets not counted, one colour per bar (steady or unsteady) from the design tokens, never red. Per take
  placement, spread and accuracy in the status line. It opens on its own for a take with a review and can be
  folded; without a review it is one line with the reason. All texts through `tr()` with German tables, as
  everywhere.
- **Devices:** the Mac first. Linux and the iPad get the same view and the same rules once the Mac is accepted, as
  one piece ("One-piece UI").

### Testing Decisions

- A good test checks what the review says about a signal, not how it finds it: given audio with known onsets on
  known bars, the offsets, placement, spread, counted onsets and reasons must come out right. No test looks into
  the detector's internals, so it can be improved without rewriting the tests.
- **Main seam, the review module:** every rule is tested there with generated audio, as all audio in this project
  is: plucks with known offsets (on, +20 ms laid back, −10 ms ahead) at several tempi and sample rates; strums
  of 10 to 40 ms that must count from the first string; delay echoes in the same catch window that must not count;
  an onset between two grid points; quiet and legato notes that must be faint; each reason for no review;
  accuracy just inside and just outside ±2 ms. The detector must hold 1 ms on clean plucks.
- **End-to-end seam, the BlackHole loop:** a real take with the click through the loop, then a review of it: placement
  0 ± 1 sample, spread close to 0. This covers the timing stamp, the bars and the review together and is the
  automatic form of the loop probe.
- **Prior art:** the click latency tests in `ClickSyncTests` (measurement found to a few samples, refused without
  signal or when uneven), the synthetic signals of `TunerAccuracyTests` and `LoudnessTests`, the BlackHole tests in
  `AudioPathTests`, and the decoding tests of older library entries (`LibraryTests`) for the optional stamp.
- **The band** has no test seam of its own; it shows what the review gives and is checked with the self-test and
  screenshots in both appearances, like the other views.
- **Acceptance with the owner:** the loop probe with an earbud on the pickup through the headphone output and
  through the speakers (placement 0 ± 1 ms, spread below 1 ms), then a check take of muted strums, then real
  playing on the beat and laid back.

### Out of Scope

- Live timing while playing (early or late after each note): the next step, on the same onset detection.
- Linux and the iPad until the Mac is accepted.
- Reviews of takes recorded before the timing stamp, and of takes without the click on throughout.
- Takes with the click on a Bluetooth output.
- A target placement per piece (decided against on 2026-11-23).
- Progress over several takes or days.
- Grades, scores or any verdict beyond placement, spread and the bar colour.
- Exporting the review or writing it into a file; the take's file stays untouched.
- Tempo changes within a take (the bars already keep tempo and meter fixed).

### Further Notes

- **Measured on 2026-11-23** on the Spark MINI, click on the headphone output, a wired headphone held on the neck
  pickup, a preset without noise gate: 25.4 ms from the click into the file, 21.7 ms of it not reported by the
  devices, spread 1.2 ms over 12 clicks. Every take before lay about 22 ms late against its bars. Found on the way:
  speakers on the headphone jack (shielded) reached the pickup at only about −74 dBFS, too weak; a noise gate turns
  the quiet input into exact zeros and hides weak clicks; once the MINI sent only zeros over USB until it was
  switched off and on again. The owner also hears the click on analog desktop speakers (Bose Companion 2
  Series III) on the same headphone output; they could not be measured this way, but an analog amplifier adds well
  below a millisecond, so the measured amp part holds for them as well.
- **Sound in the air** takes about 3 ms per metre. The measurement couples magnetically and leaves that path out, so
  a player 1.5 m from the speaker who plays exactly on the heard click shows a placement of about +4 ms. The review
  is right about it; the band could say so when the click output is a speaker.
- To be settled while building, with the owner where it is a matter of taste: the smallest number of counted onsets
  for a review; the line between a steady and an unsteady bar; whether a reverb tail needs a hint as well as a delay.

## Ordering presets: hashtags

- One system instead of folders: every preset has tags (`PresetFile.tags`, stored without "#", shown with "#").
  Edited in the line below the editor's head (typed with or without "#", several separated by blanks, × removes)
  or through the context menu "Tags" in the sidebar. The preset's notes are there too. A recipe becomes a
  preset file with an id of its own in the process (`PresetLibrary.updateDetails`), the sound stays unchanged.
- **Sidebar:** the section "Tags" with the pinned, the filtering and the 8 most frequent tags as chips, the
  rest under "+ N more". A click filters (several = all must match), a right click pins. Every pinned
  tag is a section of its own, a preset can stand in several; below them "All on this Mac". Pinned tags
  are in UserDefaults `Pinned Preset Tags`.
- **Search** finds name, origin, models, tags and notes; "#clean" searches tags only.
- Songs with key, tempo and parts are the pieces in the area Record; presets do not point back to them.

## Data model

- **Sound of a take:** `Recording.preset: PresetStamp?` with `slot` (from 1, nil = played temporarily), `name`,
  `stampedAt`, `sha256`, `device` (profile name, since phase 2) and, for a device that is only listened to,
  `listened` (label and value) instead of fingerprint and snapshot. The snapshot lies as a preset file in
  `Recordings/.presets/<take UUID>.json` (`PresetFile.snapshotData`), so that "Open in editor" uses the normal
  reading logic. Named after the UUID, not after the file name, so it stays with the take when it is renamed.
  Discarding and restoring keep it.
  - What sounds (`PresetsModel.heardPreset`, from memory only): the editor's state when it plays live on 7F (also
    during the A/B comparison), a tried-out preset, otherwise the stored slot. Without a connection no sound.
  - Take id and stamp already stand in the journal, the snapshot is written at the start: a take repaired after a
    crash keeps both.
- **Fingerprint** `SparkPreset.sha256Hex()`: SHA-256 over the canonical JSON of **the effect chain only** (models,
  on/off, values with marker). Name, description, BPM, uuid and trailer do not count, because the amp sends a slot
  with a longer trailer than the playing preset; otherwise the same sound would have two fingerprints.
- **Pieces = songs:** `Piece` with title, `artist`, `bpm`, `key`, `notes`, `preset` and `parts` (each with `preset`).
  A `PresetLink` names a preset through the stable `PresetFile.id`, with the file name in the folder Presets as a
  fallback, never through an absolute path. Practice time comes from the practice log, discarded takes count too.
- **Schema 2:** `LibraryDocument.currentSchema = 2`. A library with schema 1 gets a copy
  `Library.before-schema-2.from-1.json` before the first save. A version that only knows schema 1 opens schema 2
  read-only and can therefore never drop the new fields.
- **Folders:** `~/Music/AmpBench/Recordings` and `…/Presets` (`StudioFolders`). At the first start
  `~/Music/Spark Recorder` and `~/Music/Spark Presets` are copied (APFS clone) and never changed or deleted. The copy
  is made in a hidden folder beside them and renamed only when complete. If Spark Recorder still holds its
  library (process lock), the app takes over nothing, says so and quits. The settings of
  `local.sparkrecorder` and `local.sparkpresets` are taken over once, only for keys the app does not have yet
  (`SettingsTakeover`). A test folder (`--library`) skips all of that.

## Keyboard model

As data in `SparkCore/StudioKeymap.swift`, checked by `StudioKeymapTests` (no key used twice in one area,
single keys everywhere only R and Space, arrows never everywhere, Presets without letters as single keys). The
KeyRouter asks `StudioKeymap.isSingleKeyEverywhere`, and the list under ⌘/ is generated from it.

Basic rules: single keys never act while a text field is active, a sheet is open or a popover has the focus.
Space on a focused key with full keyboard access presses the key, except during a recording.

| Where | Shortcuts |
|---|---|
| everywhere | R, Space (in Metronome: start/stop), ⇧⌘1–⇧⌘4, ⌃⌘M (metronome), ⌘/, ⌘Z/⇧⌘Z (in the area in front), ⌘S (preset in the editor), ⌘1–⌘8 (connected, as many slots as the device has) |
| Record | L M K F B N T G, ⌘G, 1–5, - + 0, ← → (with ⇧), ⌫ ⌦ ⌘⌫, ⌘E, ⇧⌘R, ⌘F, Esc |
| Presets | ⌘N, ⇧⌘N, ⌘D, ⇧⌘S, ⌥⌘1–⌥⌘8, ⌘B, ⇧⌘L, ⌘R, ⌃1–⌃7, ⌃0, arrows on a knob, ⌘E, ⌘⌫, ⇧⌘R, ⌘L, ⌘F |
| Presets, library open | Esc, ↩, ⌘↩, ⌘K, ⇧⌘F, ⌘T, ⌘G, ⌘A; ⌘E and ⌘⌫ act on the selected sounds |
| Tuner | ⌘T (needle/strobe), ⌘↑/⌘↓ (concert pitch ±0.1 Hz), ⌘0 (440 Hz), ⌃1–⌃6 (tuning); no single keys |
| Metronome | ⌘T (tap), ⌘↑/⌘↓ (±1 BPM), ⇧⌘↑/⇧⌘↓ (±10 BPM); no single keys of its own, Space starts and stops |

Decided: ⌘E, ⌘⌫, ⇧⌘R act on the take or the preset depending on the area. ⌘S saves the preset in the editor
everywhere (the recorder saves by itself). ⌘1–⌘4 everywhere, but only with a connection. R everywhere, even though it
takes the type-select for "r" from the sidebar. Esc closes the library in the area Presets. ⇧⌘S only in
Presets, because it opens a sheet there. ⌘E stays Rename; the design canvas showed "Export ⌘E", which got no keycap.
⌘F in Presets opens the library with the keyboard in its search field (since 2026-11-14).

## Devices

AmpBench knows several devices from Positive Grid's catalog. Each has a `DeviceProfile` (SparkControl; Linux
`devices.py`): display name, how it is found (Bluetooth service and name, name from `02 11`), slots and banks,
transport (`sparkBLE`, `midi`, `textOnly`), abilities and peculiarities. The areas read slots and abilities
from the profile; another device (Spark 40, GO, 2, LIVE, NEO Core) joins as another profile, only after a
check with its owner.

| Profile | Slots | Abilities | Peculiarities | Checked |
|---|---|---|---|---|
| Spark MINI | 4 | everything: read, switch, play temporarily, change live, model change, store, buttons, tuner, tap, USB audio | keeps the temporary sound on disconnect? unchecked, counts as "no" | 1.11.2.75 |
| Spark NEO | 4 | like the MINI, without USB audio; tuner checked, tap unchecked | drops the temporary sound on disconnect | 1.16.1.60 |
| REACTOR 50 | 8 (Red 1–4, Green 1–4) | listening, buttons, tuner, tap, USB audio ("Reactor 50 USB Audio"), Text to Tone, a sound as live commands (`.liveSound`), reading its presets (`.reactorPresets`), switching, live changes and storing in its own format (`.switchSlot`, `.liveEdit`, `.store`) | no `.send`: never a Spark preset, no model change, no temporary place | listened to; live commands heard (2026-11-10); switch, names, store checked with the probe (2026-11-11) |
| REACTOR 100 | 8 | listening only; no USB audio name | | unchecked |
| unknown Spark (FFC0) | 4 | read and switch only | | – |

None of them confirms a parameter (`04 04`); the editor never waits for that, and reading back after a pause shows
whether it arrived. The pacing stays as for the MINI.

### Recognizing and switching

- **Scans only for FFC0 and FFD0.** The app never sees other Bluetooth devices. FFD0 is a REACTOR, recognized without
  a request. A Spark is provisionally recognized by its Bluetooth name and confirmed after connecting by the name
  from `02 11` ("Spark NEO", "Spark MINI"); an unknown name keeps the cautious profile.
- **Remembered by identifier.** Known devices and the one chosen last are in UserDefaults (`Known Devices`,
  `Chosen Device`) with their `CBPeripheral.identifier`, so that two equal devices stay distinguishable. The app
  connects only to the chosen one; without a choice to the first one found. A test library has settings of its own.
- **One control connection at a time.** The device choice ("Device", first section of the sidebar) ends the old
  connection, then makes the new one. When something unsaved plays temporarily on a device that loses it on
  disconnect, the app asks first ("The sound on the NEO is lost when you disconnect. Save it as a preset
  first?"), likewise for "Disconnect".
- **Bluetooth at start** only once a device was connected before (see "Bluetooth at start once known" above).
- **Names in logs:** over Bluetooth the REACTOR is called "Reactor 50 …" with an addition by its owner. The app
  shows it but writes it into no log (`DeviceProfile.loggableName`); take stamps carry the profile name.

### Spark NEO (checked with spark-probe on 2026-11-09, confirmed by ear by the owner)

A wireless headphone system: headphones plus a radio transmitter on the guitar. Bluetooth name "Spark NEO Control",
service FFC0 with FFC1 (read, write, write without response) and FFC2 (read, notify), name from `02 11` "Spark NEO",
firmware 1.16.1.60, 4 slots (factory presets CLEAN, CRUNCH, SOLO, HI GAIN). Preset format as on the MINI (7 effects,
399–424 bytes, encoded back byte for byte, trailer `CA C1 E8 00 00 CA 3F 00 00 00 xx`); all 16 models of the
factory presets are in the catalog.

- Heard: switching (`01 38` → `04 38`, then `03 10`), a whole preset on 7F (16 chunks, `05 01` each, then `04 01`),
  parameters (`01 04` with input byte, no confirmation, reading back shows the value), on/off (`04 15`),
  model change (`04 06`, its own start values equal to the MINI's, checked with the TS9), storing in slot 4 and
  playing the original back byte for byte.
- Reading sometimes needs the second attempt; the existing asking again is enough.
- **Texts only as long as heard:** the NEO has only played names up to 12 bytes (factory presets ≤ 7, the probe's
  copies "SOLO Test" and "HI GAIN Test") and never a description. The profile therefore has `checkedText`: before
  sending, `AmpGuard.prepared(_:for:)` shortens the name to 12 bytes (at a character boundary), leaves out the
  description and sets version "0.7" and icon "icon.png". The sound stays the same; a stored slot then carries the
  shortened name. Longer texts only after a check with the owner (headphones not on the ears).
- The middle button steps on (3 → 4 → 1) and reports `03 38` with the slot (`F0 01 50 02 03 38 00 00 02 F7`);
  the app follows as with the MINI's preset button. + and − report nothing.
- **Disconnecting drops the temporary sound**, after which the stored slot plays (heard and read back).
  The app then resets `tryingOut`/`isEditingLive`, reports it (also to the recorder; a running take keeps
  its stamp from the start) and reads again at the next connection, instead of sending the editor's state again by
  itself. Only a connection that comes back by itself gets the edited state again.
- USB-C: the headphones showed no audio or MIDI device on the Mac, only a USB 2.0 hub (Genesys 05e3:0608) with no
  device behind it, presumably for firmware updates (not tried). The area Record does not offer the NEO.
  A take with the NEO as the sound source through another input still carries the device name in its stamp.
- **Tuner** (`01 65`): checked, see "The amp's own tuner". Both commands confirmed, headphones silent,
  then sound again.
- **Radio transmitter** (USB-C on the Mac): shows up as "Low Latency MIC" (Telink, 248a:9218) with the classes 7/1
  and HID, without an audio device. Recording from the NEO therefore stays without USB. The cross-check (unplugging,
  device disappears) is not confirmed.
- Not checked: tap tempo and delay with sync = BPM, battery level, USB-C with a
  safe data cable and of the radio transmitter, texts longer than those of the factory presets (at most 7 bytes of
  name, no description), the NEO Core.
- A backup of all four slots from 2026-11-09: `~/Music/AmpBench/Sicherungen/Spark NEO 2026-11-09/`, outside the
  library, only for playing back, it is not changed.

### REACTOR 50 (listened to on 2026-11-09, first commands on 2026-11-10)

A combo amp, a product line of its own with an app of its own. The owner has the user manual (English, for the 50
and the 100).

- **USB-C:** a USB audio device with 1 input and 2 outputs, 48 kHz; the input carries the finished sound with all
  effects. Beside it a serial port "PG Virtual Com" (firmware program) and an Espressif JTAG
  interface (can reset the chip): **never open them, not even for listing.** No USB MIDI. Manual: plug in USB
  while the REACTOR is off. Read on the device on 2026-11-16 (macOS audio list only): it is called
  **"Reactor 50 USB Audio"**, without the owner's own name part, and the Mac takes its input as 16 bits mono. The
  profile names "reactor 50", so the recorder records from it (`InputPolicy.usbDevices(named:)` with the profiles'
  names); the deck showed "Ready" with it as input. No take recorded from it yet; latency not measured.
- **Bluetooth:** A2DP for music and BLE for control: service FFD0, manufacturer id 295D, FFC1 (write without
  response), FFC2 (read, notify). The messages are Spark frames (`F0 01 … F7`, 7-bit packing, texts and floats as
  on the MINI).
- **What it reports by itself** (`ReactorState`, Linux `devices.ReactorState`):

| Control | Message | Remark |
|---|---|---|
| Gain | `03 37` Amp.Preamp parameter 0 | 0–1, with it `03 1A 91 00 02 C3` |
| Bass, Middle, Treble | `03 37` Amp.Tonestack parameters 1, 2, 3 | up to ~8 messages per second |
| Master | `03 37` Amp.Poweramp parameter 0 | with it `03 1A` |
| Amp selector, Push/Smooth, Heat | `03 B1 <amp> <5 × switch + heat>` | amp 0–5 Clean, Warm, Grit, Crunch, Hi-Gain, Extreme; switch 0 Push, 1 Standard, 2 Smooth; heat 0–4 (middle 2). No `03 06` |
| FX Level | `03 37` parameter 0 of the selected effect | twice nothing came, later reliably; cause open |
| FX buttons | on/off `03 15 <model> C3/C2`; selection `03 B3 <chain place> C3` | places gate 0, comp 1, drive 2, (amp 3), mod 4, delay 5, reverb 6 |
| TAP | `03 63 CA <float>` = BPM | with it DelayEchoFilt parameter 4 = 1.0 |
| Preset (short) | `03 38 00 <slot>`, mostly twice | 0–7 absolute, in a circle within the bank. No preset content |
| Bank (short) | `03 38 00 <slot>`, once | each bank remembers its slot; once one change more came than counted |
| Volume | nothing | outside the preset |
| Hold Bank = tuner | `03 65 C3`, continuously `03 64 00 CA <float>` (−1 without a signal), `03 65 C2` | output silent |

  Models in the factory presets: bias.noisegate, BBEOpticalComp, DistortionTS9, DelayEchoFilt (in the catalog; their
  place comes from there), ChorusCloner, MonoReverb (not in the catalog; their place comes from `03 B3` after
  switching on), the amp as three blocks Amp.Preamp, Amp.Tonestack, Amp.Poweramp. It does not follow from this that
  a Spark preset fits.
- **In the app:** connect, subscribe to FFC2. After connecting, the app reads the eight slots (`02 01 00 <slot>`) and
  the playing slot (`02 10`), since 2026-11-10 (`.reactorPresets`, `SparkLink.loadReactorPresets`,
  `ReactorPreset`); when a slot does not answer, the rest stays unasked. The sidebar shows the slots like those
  of a Spark: the name, and below it the amp and the number of effects; the REACTOR panel names the preset of the
  chosen slot. `AmpBench --reactor-read <file>` shows a preset saved as a file. Otherwise no `.send`, so no
  preset, no live editor; `SparkLink.write` refuses that (test `testTheREACTORGetsNotASingleByte`, Linux
  `test_the_reactor_gets_not_a_single_byte`). Since 2026-11-10 the REACTOR 50 has `.liveSound`: the editor's "⋯ →
  Play on the REACTOR …" computes a `ReactorSound` from the open preset (the nearest of the six amps by Spark model,
  otherwise by gain; switch Standard, heat middle; gain, bass, middle, treble; effects on/off by the names of the
  factory presets; reverb level) and sends it after a question through `SparkLink.play`, one by one with a pause of
  250 ms: tone knobs and gain before the amp choice, never the master. The only way on which it gets anything (test
  `testTheREACTORGetsOnlyTheLiveCommandsOfASound`). The REACTOR 100 stays with listening. Linux cannot do it yet.
  Unchecked: the whole sequence on the device (so far only the single commands by hand), effects in slots with other
  models, Push/Smooth and Heat as a command, all amps except Clean. The area Presets shows the banks and a REACTOR
  panel with displays instead of knobs; after a slot change everything but the slot is unknown. Unknown messages
  (`03 1A` and others) are counted, not interpreted. A take records device, slot, amp, Push/Smooth/Heat, knobs and
  effects as `PresetStamp.listened`, without fingerprint and snapshot; the inspector shows "Read only".
- **Tuner:** the REACTOR panel shows on/off and the raw value from `03 64`. It is not attached to the display of the
  area Tuner: the scale of the value is unknown, and the display promises 0.1 cent.
- **AI Sound's "Listen":** the REACTOR has no temporary place, so a suggestion plays as its nearest REACTOR sound
  (`ReactorSound`, the same live commands as "Play on the REACTOR") on the slot it plays: amp, Push/Smooth, Heat,
  gain, tone, effects on/off and the reverb's level. The master is never set, nothing is stored, a slot change ends
  it (`PresetsModel.tryOutOnReactor`, since d099b66).
- **Text to Tone:** the editor's "⋯ → Copy text for REACTOR" (like `--recipe-prompt`); the REACTOR interprets the
  text itself.
- **Open:** the meaning of `03 1A 91 00 02 C3`; Power Control (50/25/1 W); PAIR; expression pedal; wah, EQ and
  FX loop; the additional bank change; why FX Level was silent twice; USB latency. Known since
  2026-11-10: it answers read requests (firmware 0.1.4.85), and `03 1A 91 00 <slot> C3` comes at the first change
  of a slot.

From the manual (not checked on the device): 8 slots. Tap Preset = next, hold = store. Tap Bank = change bank,
hold = tuner. Tap the FX buttons = select, hold = on/off. 8 effects (gate, wah/volume, comp,
drive, mod, delay, EQ, reverb) plus FX loop; chain gate → comp → drive → wah → EQ → [amp] → mod → delay → reverb →
FX loop. MIDI only over 5-pin DIN, channel 1: CC on/off 0 gate, 1 comp, 2 drive, 3 wah, 4 EQ, 5 delay, 6 mod,
7 reverb, 10 FX loop; CC 21–26 amp Clean to Extreme; CC 27 Push, 28 Smooth, 12 Heat+, 13 Heat−; Program Change
0–7 = Red 1–4, Green 1–4; CC 15 bank; CC 30 output, 31 line-out, 32 send volume; CC 35 tuner, CC 36 tap. MIDI In and
the REACTOR Control footswitch exclude each other. The owner wants to do without a MIDI interface.

### REACTOR: sending, later and only with the owner at the device

The owner wants to bring sounds from the app onto the REACTOR too (2026-11-10). "Play on the REACTOR" is built
(above under "In the app"). The probe sends exactly one message per run: `ask
<firmware|name|slot|current>` reads, `set-one <block> <index> <value>` sets a parameter, `switch-one <model>
on|off` switches an effect, `send-one <sub> <bytes>` tries a command known only from the device's own messages.
The way up to here, every step with the owner's consent:

1. One single read request (`02 11` name or `02 2F` firmware), device quiet, headphones not on the ears. If it
   answers in the Spark format, that is a finding, otherwise the end.
   **Done on 2026-11-10 with the owner's consent** (`spark-probe ask firmware`, one message with block header over
   FFC1): after 0.09 s `03 2F CE 00 01 04 55` came, without a block header, so firmware 0.1.4.85 in the Spark
   format. The REACTOR answers read requests.
2. At most `02 10` (current slot) and `02 01` (read a preset), to get to know the REACTOR's preset format. Reading
   only, evaluated together with the owner.
   **Done on 2026-11-10 with consent** (`ask slot`, `ask current`, one message each): the slot came as `03 10 00 06`.
   The playing preset came as `03 01` in four chunks, 1483 bytes, header per chunk `04 <chunk> <?>`. It is **not a
   Spark preset**, but a MessagePack-like format of its own:
   - Two heads of `C4 10 <16 bytes of id>`, name, version, description, picture file, tags: first
     "V30 Classic Mid Gain" (1.0, `icon.png`, classic/thrash/tight), then `CA` float 120.0 (BPM), then "80s Crunch"
     (0.1, `f_amp_JCM800.png`, rock/punchy/crunch). Presumably cabinet and amp.
   - Then `96`: six blocks `C4 02 <2 bytes of id> C3/C2 <list>` with the ids 05 02 (145 values), 05 03 (4),
     05 05 (110), 05 06 (11), 04 34 (30), 04 35 (30); then `9A`: ten blocks 03 09, 04 0A, 04 0B, 04 0C, 04 2C, 04 0D,
     04 2E, 04 32, 04 11, 04 12 with 1 to 8 values, probably the effects with on/off.
   - Values are `CD` plus 16 bits, plausible when read as half floats (`3C 00` = 1.0, `38 00` = 0.5).
   - No model names such as `Amp.Preamp` in the preset; those come only in its knob messages (`03 37`).
   Conclusion: building a preset for the REACTOR would mean understanding this format completely. The nearer way
   is through the messages it sends itself (amp choice `B1`, knobs `37`, on/off `15`): set the sound live, the owner
   stores it on the device. Whether it takes these as commands (`01 …`) is unchecked.
   **First write test on 2026-11-10 with consent** (`spark-probe set-one Amp.Tonestack 1 0.5`, one message `01 04`
   with input byte): after 0.09 s `03 1A 91 00 06 C3` came. The same message accompanies its own knob messages
   (there with 02 instead of 06); the REACTOR stood on slot 6, so the number is probably the slot and the message
   "slot changed". The owner heard a jump when touching the bass knob. Then `set-one Amp.Preamp 0 0.1` (gain): no
   response, but according to the owner the "80s Crunch" sounded clearly clean. **The REACTOR takes `01 04` for the
   amp knobs**; `03 1A` comes only at the first change of a slot. `switch-one MonoReverb off`, then `on` (one
   message `01 15` each): both acknowledged with `04 15` as on the Spark; the owner confirms: reverb is on.
   `set-one MonoReverb 0 0.5` (reverb level): sent, no response, listening test open.
   `send-one B1 00 07` (guessed from its message `03 B1`: amp 0 = Clean, 5 × switch 1 + heat 2): acknowledged with
   `04 B1`. So the amp choice is a command `01 B1 <amp> <5 × switch + heat>`; listening test open.
   Unchecked: amp choice with Push/Smooth/Heat (it reports `03 B1`, the command for it is unknown), slot change.
   **All eight slots read on 2026-11-10** (`spark-probe read-slot 0…7`, one request `02 01 00 <slot>` each,
   nothing switched). Findings on the format:
   - Chunks have a **header four bytes long**: count, number, length as 16 bits (350 = `01 5E`). The
     Spark parser assumes three and therefore leaves one byte per chunk; remove before reading.
   - The content is MessagePack: `00 <slot>`, then id (16 bytes), name, version, description, picture, number, tags
     for the **preset** (e.g. "Bright Teaching Clean"; the names are the owner's), `CA` tempo, the same for
     the **amp** ("Twin Clean", `f_amp_TwinReverb.png`), then 16 blocks `C4 02 <id> C3/C2 <values>`.
   - Always the same: `05 02` (145 values), `05 03` (4 values, probably gain, bass, middle, treble from 0 to 1),
     `05 05` (110, in it EQ bands with 1000 Hz and Q 0.707), `05 06` (11), `04 34` and `04 35` (30 each).
   - Ten effect blocks whose id names the model and changes from slot to slot (`03 09`, `04 0A`, `04 22`,
     `04 0C`, `04 0D`, `04 2C`, `04 19`, `04 32`, `04 11`, `04 12`, `04 16`, `04 10`, …), with on/off and 1 to 8
     values.
   - Values: `CD` plus 16 bits as a half float, whole numbers as one byte.
   - At the end four bytes of checksum: **CRC-32/MPEG-2** (polynomial 04C11DB7, start FFFFFFFF, not reflected, no
     final XOR), highest byte first, over everything after `00 <slot>` up to the checksum. Found on 2026-11-10,
     fits all eight presets read (`ReactorPreset.checksum(of:)`, `checksumOK`).
   The eight presets lie as a backup in `~/Music/AmpBench/REACTOR-Sicherung 2026-11-10`.
   Reading and showing have been built in the app since 2026-11-10 (above under "In the app"), not yet seen on the
   device.
   The owner wants reading, showing and storing of whole presets as on the Spark, and everything in one piece: no
   side paths beside what is known from the Spark; "Play on the REACTOR" alone
   is not enough (run from the app, hardly an audible difference).
3. Parameters, effects and amp choice one by one with consent: done, see above. The profile got `.liveSound` instead
   of `.send` for this; the test "writes nothing" still holds for everything else. Never a Spark preset to the
   REACTOR.
   Seen on the device (2026-11-10, the owner's picture): all eight names with amp and effects, Green 3 as playing.
   **Checked on 2026-11-11 with the owner at the device** (`spark-probe script`, several messages per connection):
   - **Slot switch** `01 38 00 <slot>` → `04 38`. A slot change discards unsaved live changes.
   - **The playing preset** (`02 01 01 00`) comes in the same format with `01 00` in front and shows live changes at
     once. That gave the names: set a marked value on parameter 0 by name, read back, see which block changed.
     `0309` bias.noisegate, `0416` BBEOpticalComp, `0422` DistortionTS9, `0431` JH.SupaFuzz, `0419` ChorusCloner,
     `0418` Tremolo, `042E` TremoloSquare, `041A` Flanger, `040F` ChorusAnalog, `0410` DelayEchoFilt, `0411` MonoReverb.
     Held FX keys reported, and marked values confirmed: `040A` SustainComp, `042A` RedComp, `042B` 4kComp, `0420`
     KlonCentaur, `040B` RCBooster; guessed and confirmed: `0426` DelayDM2. Still without a name: `0432`, `0425` (delays),
     `040C` (wah), `040D` (one value, probably the amp's place in the chain), `042C` (equalizer), `0412` (FX loop). The
     REACTOR reports a model's name only when its FX key is held or FX Level is turned on the device.
   - **Amp knobs:** gain = `0502` value 0 (Amp.Preamp 0), `0503` values 0–3 = Amp.Tonestack 0–3 (1 bass, 2 middle,
     3 treble), master = `0505` value 0 (Amp.Poweramp 0).
   - **Storing:** `01 01` without block header, the preset's bytes (`00 <slot>` … checksum) in chunks of 350 with the
     four-byte header (count, number, length in 16 bits). Every chunk is acknowledged with `04 01`, then
     `03 1A 91 00 <slot> C2` comes. Tried on Green 4: unchanged (read back the same), tempo 121 (stayed after a slot
     change), original back. Bytes written with `01 00` in front are acknowledged but change nothing: there is no
     known way to play a preset without storing it. All eight slots were the same as the backup afterwards.
   - **In the app** (`ReactorBridge`, `ReactorPreset.rewritten`, `SparkLink.storeOnReactor`): a slot opens in the editor
     as the seven places; live changes go by name (`01 04`, `01 15`) for the slot that plays; storing rewrites only
     the changed values in the bytes that were read, so an unchanged preset is written byte for byte. Models are not
     exchanged, wah, equalizer and FX loop stay as stored, a Spark preset is refused. Not yet tried from the app on
     the device.
4. Done on 2026-11-11, see above: the blocks are interpreted, a slot opens in the editor, a preset was written back
   unchanged and changed.
5. Still open, each only with consent at the device: editing and storing from the app; the names of the delays
   `0432` and `0425` (hold the Delay key on Red 1 and Green 4 while the probe waits, then confirm by a marked
   value); the other five amps, Push/Smooth and Heat as a command and where they sit in the preset; exchanging a
   model (`01 06` is untried, and a new block needs its values); wah, equalizer and FX loop; a way to play a preset
   without storing it; what `040D` and the last value of `0411` mean.
- MIDI (DIN, table above) stays the alternative in case an interface comes: a MIDI output chosen by the user,
  Program Change 0–7, the on/off CCs, tap. Volume CCs (30–32) never jump louder and only on explicit
  request.
- No capturing of the traffic of the REACTOR app on the phone.
- Never guide anyone to the following button combinations: REVB + TAP at power-on (factory reset), holding TAP + MOD
  (expression calibration), holding Preset (overwrites the slot), holding PAIR. In operating steps, say that
  Preset is only tapped. Never interrupt firmware updates and never trigger them from the app.

### Tools

- `spark-probe scan` shows the recognized profile, `--device <name>` chooses among several devices. Only `listen`
  connects to a device whose profile may not get anything.
- `spark-probe tuner <seconds>` switches the amp's own tuner on (`01 65 C3`), collects the values and
  switches it off (`01 65 C2`). With `--compare` it also hears the Spark's USB input (reading only, without a rate
  change, nothing stored): 8 s before, during, 8 s after, per note the median in cents and the median of the value.
  The app bundle has a microphone usage text for this.
- `spark-probe listen <seconds>` finds devices with FFC0 or FFD0, subscribes only to FFC2 and has no code that
  writes. At the end per parameter count, span, first and last value, otherwise messages with their time. The
  owner's addition to the REACTOR's name is cut off. The capture only runs from the line "Listening …" on, so the
  operating steps come only after it.
- From a Claude Code session in the desktop app, a bare spark-probe crashes at the Bluetooth access (TCC
  counts it as part of Claude). `Tools/probe-app.sh <arguments>` puts it into an app bundle (Info.plist from
  `Resources/SparkProbe-Info.plist` plus `CFBundleExecutable`, `CFBundlePackageType APPL`, `LSUIElement`, ad hoc
  signed) and starts it with `open -W -n --stdout … --stderr …`.

## Protecting the amp

On 2026-11-08 the amp howled after an AI Sound was kept, so loud that it hurt the ears – although the
knobs for guitar and music stood at zero. So the noise arose behind the volume controls.
The same sound had sounded normal when listened to shortly before. The only difference was the description: 136
instead of 82 bytes, 540 bytes in total in 22 chunks. Everything that had worked until then stayed at no more than
486 bytes, 20 chunks and texts under 128 bytes. Whether the long string or the larger message was to blame has
not been settled.

Since then every preset goes through `AmpGuard` (Mac, `Sources/SparkControl/AmpGuard.swift`) or `for_amp` and
`amp_problems` (Linux, `protocol.py`):

- **Adjusted:** values are limited to 0–1, the tempo to 40–250. The description is shortened to at most 80 bytes
  and further, until the preset is at most 486 bytes large. The sound stays unchanged. Live knobs
  are limited to 0–1 as well.
- **Refused, with a message in the window:** a preset is not sent when it does not have exactly 7 effects, when a
  value is not a number, when a name is longer than 31 bytes (id 36) or when it is too large despite shortening.
- **Log:** every transmission is in the system log:
  `log show --predicate 'subsystem == "local.ampbench" AND category == "amp"' --info --last 1h`.
- **Tests:** `AmpGuardTests` and `AmpDescriptionLimitTests` (Mac), `test_core.py` (Linux). They check the preset of
  2026-11-08 and the largest preset the catalog yields. It fits with its full name, only the description gets
  shorter.

The volume controls do not protect against such a fault. Therefore no limit is raised by trying it on the
speaker, not even quietly. If such a noise occurs: switch off at once (power button, if need be
disconnect power and USB).

For every device, without exception:

- The limits hold for the NEO just the same and are raised for no device. On the NEO the speaker sits on the ear:
  never send a new variant of the data format to the NEO (longer texts, new fields, unknown commands), not even
  to try it out and not "quietly". A check that sends something new needs the owner's consent, and the
  headphones are not on the ears then. If it howls: power off at once or take the headphones off.
- No series of model changes: at most 8 with a pause of 1 s, stop at the first `03` echo instead of `04` (about 40
  fast changes once made the MINI hang).
- Before any work on a device, back up all slots (`spark-probe backup <folder>`), overwrite a slot only with consent.
- Only one control connection: the app, spark-probe and the phone app block each other. Before every probe run,
  have the app and the phone app disconnect.
- REACTOR: over BLE only what was checked with the owner (read requests, slot switch, live commands by name, its
  own presets back); nothing over USB serial, JTAG or MIDI. The profile has no `.send`; a Spark preset and every
  other message are refused. Every command new to it is first sent once with the probe, with the owner's okay.
- Models that only one device knows enter the catalog only after a check on the device (`spark-probe
  catalog-check`, in batches of eight). `checkedOn` in the catalog is a list (MINI 1.11.2.75, NEO 1.16.1.60).

## Checks

- `swift test`: all unit tests with synthetic data, among them stamp, journal, schema 2, taking over folders and
  settings (also "Spark Recorder still runs"), fingerprint and keyboard model. One audio timing test
  (`testLoopStaysInsideItsRange`) occasionally fails in the full run under load and passes alone.
  - Since 2026-11-08 four checks in `AudioPathTests` fail, also alone: the test signal through BlackHole does not
    arrive (0 Hz measured instead of 1000 Hz, playback does not end). SparkCore has been unchanged since the recipes,
    and in the morning of the same day everything passed. BlackHole 2ch stood at 192 kHz then. Presumably the Mac's
    audio environment, not the code; not investigated further. In the evening of the same day `swift test` passed
    completely again (417 tests, also these four and the timing test). No cause has been found, it is only one run;
    keep watching.
- Tuner, all with synthetic signals (`TunerAccuracyTests`, `TunerBehaviorTests`, `TunerModelTests`,
  `TunerBlocksTests`):
  - Sine 30 Hz to 1.4 kHz at 44.1 and 48 kHz (and 96 kHz at four points): every value after 0.8 s ≤ 0.1 cent.
  - Sawtooth with decay and a Karplus-Strong string (loop tuned exactly, checked independently by DFT peak to
    ≤ 0.05 cent), noise −30 dB below the first half second: ≤ 0.5 cent, as long as the string lies at least
    10 dB above the noise, from 0.6 s on (below 50 Hz from 1 s on).
  - Held sawtooth with noise: spread ≤ ±0.2 cent. No octave error in the 7 s decay of B0, E1, B1,
    E2, A2 into the noise (one lock, no false trigger), not even with a fundamental half as strong as the
    octave. First value of a low E 78–80 ms after the attack, B0 after 102–105 ms (limit 120 ms, counted in
    samples of the stream).
  - Measured on 2026-11-08: sine at most 0.002 cent off; Karplus-Strong in noise at most 0.44 cent at
    B0, 0.17 at E1 and ≤ 0.07 from E2 on; held tone in noise ±0.011 cent.
  - New attack of another string: under 150 ms. A turned peg (20 cents/s): at most 150 ms behind,
    0.25 s after the stop ≤ 0.5 cent. Holding, attack click, threshold, DC offset, tunings, names, concert pitch,
    texts; the ring buffer (mean of the channels, overflow, epoch) and that the recorder only writes to it while it
    is attached.
  - Model with a fake input: listens only while active; without a Spark nothing is opened; settings stay.
  - The amp's own tuner: `AmpTunerInterpreterTests` (median of jumping values, outliers at the attack, E without
    octave, concert pitch, neighboring note, in tune, holding), `AmpTunerLinkTests` (one message on, one off;
    disconnecting switches off first; after a break as wanted; off without an answer; quitting waits; the REACTOR
    gets nothing; values keep no request alive), `TunerModelTests` (on only while the area is in front; off when
    the amp is gone; "Automatic" takes the NEO's tuner, USB for a plugged-in MINI, and follows the device). Window
    picture `docs/pictures/tuner-amp-*` with a made-up amp looked at.
- Devices (synthetic, `SimulatedDevice` and `fake_amp.py`): `DeviceProfileTests` (profiles, recognition, names in
  logs, banks, USB names), `ReactorDecoderTests` (the byte sequences of the table above, also the NEO's button),
  `SparkLinkTests` (NEO found, named and read; falling back on disconnect and reading again; middle button;
  parameters without waiting; a silent REACTOR gets one read request and nothing on send and store requests; a
  REACTOR slot is switched, edited live by name and stored and read back (`ReactorBridgeTests` for the bytes);
  an unknown Spark only reads and switches; a change of device disconnects first and remembers the identifier; the
  question before the loss), `StudioKeymapTests` (⌘1–⌘8 and ⌥⌘1–⌥⌘8 with no key used twice). Linux:
  `tests/test_devices.py` the same, plus the text for REACTOR byte for byte as on the Mac.
- Window pictures with the device choice (NEO) and the REACTOR panel in light and dark (`docs/pictures/devices-*`),
  with simulated devices, looked at.
- `SoundRecipeTests` and `ToneDescriptionTests`: recipes in both directions, all errors at once, corrections
  with a hint, stable uuid, reading in the presets folder, text for REACTOR. They also check that the examples in
  `docs/ai/examples` are valid and that `docs/ai/spark-catalog.*` matches the catalog in the code.
- UI self-test `main` in the app's window: the same results as formerly in Spark Recorder. 3 FAIL come from this
  test environment (the BlackHole test signal does not arrive), single VoiceOver checks sometimes fail, sometimes
  not.
- Scenario `sound`: stamp in the journal, snapshot at the start, "To the amp" fails in the middle of the recording
  through the app's real path (Presets offline, like a lost connection), the recording continues and ends with its
  sound.
- `--menu-dump`: no key twice in one area, ⌘N acts only in the area Presets; the menu Tuner has
  its keys only in its area (checked on 2026-11-08; compare with `LC_ALL=C`, otherwise `sort` takes ⌃1 and ⇧⌘1
  for equal).
- Window pictures of the tuner from the self-test `pictures` (a synthetic string through the real chain: A2 −3.4
  cents, G3 +1.8 cents in the strobe, E2 in tune), looked at in light and dark and at 1120 × 720.
- Moving into the libraries (21b14cc): window pictures before and after differ only where two
  runs of the same state differ as well.
- Window pictures of both areas looked at in light and dark and at 1120 × 720 (docs/pictures).
- The library, with about a hundred made-up sounds (`--made-up-sounds`): `LibraryQueryTests` (origins in both
  languages, scopes, filters, every word of the search, "#tag", the mark `#listen` as a plain tag in the file,
  groups and `leaving`, close sounds and backups left out), `LibraryBrowserTests` (the made-up library written once,
  filters → query, a sound in two tag groups selected once, close groups, gone sounds leave the selection), the
  iPad UI test `testTheLibraryFindsASound`, `--menu-dump` without a key twice. Linux: `tests/test_library_query.py`
  (the same cases, pieces by id or file name) and `tests/test_library_view.py` (short sidebar, search and real
  keys, filters and groups, close sounds, marks and tags for several, renaming, the Trash naming pieces and its
  undo, German, no shortcut twice). Pictures looked at in dark, light, German and at the smallest window on both.
  The Linux tests also run on a Mac headless (linux/README.md, "Code"); there two timing tests
  (`test_the_tuner_listens_only_while_its_area_shows`, `test_demo_engine_records_a_real_take`) sometimes fail in a
  full run under load and pass alone (2026-11-15).
- Icon: looked at in 1024 and 32 px.

## Open and next

- **Timing review** (the owner's wish, 2026-11-23): first measure the amp's click latency with the owner, then the
  review module test first, the click latency per amp with a timing stamp per take, the timing band on the Mac and
  the loop probe as acceptance. Live timing, Linux and the iPad after that. See "Timing review".
- **Levels:** the owner's verdict on the corrected sounds (which still lack drive, which are too loud); a second
  measurement in batches of about ten sounds with rests; then the rule into the import and the Linux app (see
  "Levels").
- **Reading back after storing** compared, on the Mac until 2026-11-09, the whole preset including the checksum
  byte; a newly built preset would therefore never have counted as arrived. Now as under Linux without the checksum
  byte (`PresetEditor.sameContent`). Not yet stored on the device with the app.
- **Checking phase 2 on the device**, step by step with the owner, questions in the chat. Confirmed on 2026-11-09:
  the app finds the NEO, shows "Spark NEO" and 1.16.1.60 and reads four slots; switching MINI ↔ NEO. Still open: the
  editor on the NEO (parameters, on/off, one model change) and that disconnecting resets the display; storing from
  the editor (with consent and a backup); whether the MINI keeps the temporary sound on disconnect (then adjust the
  profile); listening to the REACTOR (gain to master, amp, Push/Smooth, Heat, FX buttons, FX Level, TAP, Preset,
  Bank, tuner; clarifying FX Level and the additional bank change along the way); recording the REACTOR (read the
  USB audio name and put it into the profile, level, latency, a take with a listened stamp).
- **REACTOR like a Spark** (the owner's wish, everything in one piece): built on 2026-11-11 (slot opens in the
  editor, live changes, "Store on slot"). Open: trying it from the app on the device; the points of step 5 under
  "REACTOR: sending"; knobs turned on the REACTOR following in the editor; a library or Spark preset onto the
  REACTOR, after which "Play on the REACTOR" goes away as a menu item of its own. Take all of it over into the
  Linux app.
- **Linux:** the device choice as the menu "Amp → Device", without a lamp in the sidebar; no REACTOR panel (the
  sidebar shows its banks, the listening happens in the core). The UI tests with PySide6 run only on the Linux
  laptop.

- **The amp's own tuner in the app:** used by the owner on 2026-11-09: on the NEO after choosing it in the input,
  on the MINI with "Automatic", after Presets had started the connection. From this came "Automatic" as the default
  and the Bluetooth start from the tuner. Still to confirm: a start straight into the tuner finds the device;
  leaving the area and quitting with ⌘Q give the sound back; whether the amp leaves it on after a lost
  connection. Built under Linux (2026-11-10), not yet checked on a real device there.
- **Tuner with a real guitar:** over USB on the MINI the level lay at −31 to −36 dBFS in the comparison on
  2026-11-09, so the threshold of −60 dBFS fits; the values over USB stayed steady within a few cents. Still open:
  against a reference tuner (strobe or clip-on with 0.1 cent) on all strings, also Drop D and a bass down to B0;
  whether "In tune" comes steadily enough with real strings (which sound a little sharp at the attack), and how
  VoiceOver spreads the announcements. The latency of the callback (buffer size) and of the 5 ms reading interval
  adds to the measured 80 ms (low E).
- **Tuner in the Linux app:** built since 2026-11-10 (`linux/ampbench/pitch.py`, `tuning.py`, `tuner.py`,
  `ui/tuner_view.py`), a port with numpy; a selection of the Mac's accuracy and behavior tests runs there with the
  same synthetic signals (sine, sawtooth, Karplus-Strong) and the same limits. The tuner reads the recorder's input
  along (`CaptureEngine.attach`, `RecorderModel.share`), and `LinkCore.want_amp_tuner` switches the amp's own tuner
  as on the Mac. Not checked: with a real guitar on the laptop, and the amp's own tuner on a real MINI or NEO
  under Linux.

- **Check on the amp**, see Status. `--live-selftest` has so far only run in Spark Presets, not in AmpBench.
- **Sound recipes:** in the editor "Export as recipe" and "Copy text for REACTOR" (so far only `--recipe-from`
  and `--recipe-prompt` on the command line). Add other Spark amps with their additional models to the
  catalog as soon as one is there to check. REACTOR takes only text as long as Positive Grid publishes no format or
  interface; try a text recipe there.
- **AI Sound:** runs over the Ollama Cloud API; open are a test against the real cloud (all tests run with
  a fake chat), and whether gpt-oss:120b follows the examples and quick keys well. Since 2026-11-10 also in the
  Linux app (`linux/ampbench/sound_ai.py`, `ai_key.py`, `ui/ai_sound_dialog.py`): the same rules, the same
  knowledge, the same variants and quick keys, the key through `secret-tool` in the desktop's keyring,
  otherwise in `~/.config/ampbench/ollama-key` (0600); a key from the Spark Studio name (`service spark-studio`,
  `~/.config/spark-studio/ollama-key`) is copied over once. A running request cannot be cancelled there, its
  answer is only discarded after "Cancel request".
  The delay's "Tap" key (2026-11-15, Mac/iPad `EditorModel.tap`, Linux `MainWindow._tap_tempo`) rests on the same
  assumption: it sets `bpm` and the tempo switch to BPM. Not heard on the amp yet.
  Unchecked on the amp: that a delay with sync = BPM comes as a quarter note on `bpm`; the rule
  "dotted eighth = song tempo × 4/3" in the prompt rests on that.
- **Audio tests through BlackHole**, keep watching: on 2026-11-08 green in the morning, four failures at noon,
  green again in the evening, with no change to SparkCore in between. See Checks.
- **Trailer:** whether loudness and extra gain in the trailer are audible is not checked. If so, they belong in
  the fingerprint, and old stamps are recomputed.
- **Small screens:** 720 pt of content plus toolbar and menu bar just fit screens 800 pt high, not with the Dock
  at the bottom. Proposal: let the library shrink, not the deck.
- **Library of the presets:** groups have been pinned hashtags since 2026-11-10 (section "Ordering presets").
  Favorites, sorting and filters are in the library since 2026-11-14 (next entry). Open: assigning by dragging,
  rating, export, a version history per preset; filtering pieces by key and tempo.
- **The library as an overlay** (the owner's wish, 2026-11-14), built on the Mac and the iPad on 2026-11-14 with
  about a hundred made-up sounds; see MANUAL.md "The library" and DESIGN.md. Decisions: a table rather than a wall
  of cards (keyboard, multiple selection, sorting, VoiceOver from the system); the mark "to listen" is the tag
  `#listen`, not a new field, because older versions and the Linux app rewrite a preset file with the fields they
  know and would drop a new one; favorites are the existing field `favorite`; recently used sounds are kept per
  device in the preferences. Grouping by piece was left out: the pieces live in the Mac's recordings, and a Kemper
  song's sounds already share a tag. The Linux app has the same view since 2026-11-15 (`linux/ampbench/library_query.py`,
  `ui/library_overlay.py`, `ui/library_controller.py`), tested headless with made-up sounds, not yet on the laptop.
  Open: group titles in the iPad's table (iPadOS draws sections without their header); scrolling the
  table to a sound chosen from "Close sounds"; trying it with the real 92 sounds and the amp; the 81 Kemper sounds
  imported before 2026-11-14 carry no `#listen` yet (filter Kemper import, `⌘A`, `⌘K`).
- **Kemper import:** the author's backup is in the real library since 2026-11-14 (81 presets, 20 pieces, kinds as
  guessed). Listen to the translated sounds on the Spark and improve the amp rules after that (above all
  Dream Weaver, Divided by 13, Naylor). The Linux app can do the import and hashtags since 2026-11-10
  (`linux/ampbench/kemper.py`; tags and pinned tags are in the library since 2026-11-15); on the author's backup both apps
  print the same `--kemper-list` line for line. Linux edits tags through a dialog (Ctrl+T), not in a line
  below the name.
- **Setlists and stage mode** build on the pieces: order by drag and drop, a large full-screen mode with
  switching by arrow keys, Space and numbers, next song or part by key. Optionally "Setlist to the amp":
  up to four presets into the slots, with a question and a backup as when storing in a slot.
- **Old apps:** Spark Recorder and Spark Presets are removed from the project, their installed copies have been in
  the Trash since 2026-11-07 and are taken out of the Dock. The old folders `~/Music/Spark Recorder` and
  `~/Music/Spark Presets` are there unchanged; the app no longer reads them. Whether and when they are deleted is
  for the owner to decide.
