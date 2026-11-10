# AmpBench

Spark Recorder and Spark Presets are one app: one process, one icon, one window with a fixed deck on top and the
areas below it (Record, Presets, Tuner). Every take knows its sound, the tempo has one source, piece and song are
one thing. This document is the one place for structure, decisions and what is still to come. It replaces the earlier
work briefs (ampbench-prompt.md, spark-presets-next-prompt.md, both in the Git history). The design is in
[DESIGN.md](DESIGN.md), how to use the app in the [manual](MANUAL.md) and the [README](../README.md).

The app was called "Spark Studio" until its first publication; identifiers such as `StudioArea` and `StudioKeymap`
keep that name. The UI is English by default and German as a second language; this document quotes the English
labels.

## Status

| Stage | Content | Commit | On the device |
|---|---|---|---|
| 0 | Data model (sound of a take, parts, key), keyboard model, layout | 66f5cdb | – (no behavior) |
| 1 | One bundle, two windows, Bluetooth on demand | 308cc7f, 61d4bdb | checked by the owner (2026-11-07) |
| 2 | One window with areas, sound of a take, one tempo | cc3ebb3 | open |
| 3 | Pieces = songs, `~/Music/AmpBench`, old apps removed, new icon | 3960ccd | open |
| – | Always in dark mode, at the owner's wish | 6a85f45 | installed, runs |
| – | Sound recipes, AI catalog in `docs/ai`, text for REACTOR | 7bd22b1, b530b84 | installed (2026-11-08), no recipe heard on the amp |
| – | AI Sound in the area Presets: description → Ollama Cloud API → three recipes, adjusting, history | ab015a2 | installed (2026-11-08), not checked against the cloud and not on the amp |
| – | Area Tuner (⇧⌘3): MPM plus a phase regression, reads the recorder's input along | 2969085 | installed (2026-11-08); ran over USB on the MINI with a guitar (2026-11-09), not against a reference tuner |
| – | The amp's own tuner (MINI, NEO) as a source, "Automatic", Bluetooth start from the tuner | 15d37b6, 90513b0, 52b85ac | command and scale checked with spark-probe on MINI and NEO; used in AmpBench by the owner on NEO and MINI (2026-11-09) |
| – | Protecting the amp (`AmpGuard`) | 18daf05 | description with 80 bytes heard on the MINI (2026-11-08) |
| – | Kemper import (backup, rigs, performances → presets and pieces) and hashtags with pinned sections | 00cd11f | installed (2026-11-10, Mac and Linux); read with the author's backup, no sound heard on the Spark |
| – | REACTOR 50: reads the eight presets after connecting (own format, checksum CRC-32/MPEG-2) and shows them like Spark slots; "Play on the REACTOR" with live commands; probe `ask`, `read-slot`, `set-one`, `switch-one`, `send-one` | 192963e … bbfe150 | seen and heard by the owner (2026-11-10): eight presets with names in the sidebar; gain, bass, reverb on/off and level, amp choice Clean. No preset written, no slot in the editor |
| – | Linux catches up: Kemper import and hashtags, area Tuner (numpy, the amp's own tuner), AI Sound (`secret-tool`) | 8707c5d, d5a5bc6, 42f6245 | installed on the Linux laptop (2026-11-10), 194 Linux tests green; not checked under Linux with guitar, amp and the real cloud |
| Phase 2 | Several devices: profiles, device choice, NEO's peculiarities, listening to the REACTOR, probe `listen`, Linux | 2fccff5 … 642d2d8 | finding and reading the NEO, switching MINI ↔ NEO confirmed by the owner (2026-11-09); the rest see "Open" |

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
  ├── SparkDesign      Building blocks (DESIGN.md)
  ├── SparkCore        Recording, library, PresetStamp, pieces, StudioFolders, StudioKeymap,
  │                    pitch detection (PitchDetector, PitchTracker, Tuning, TunerEngine, AudioTap, SharedInput)
  └── SparkControl     Protocol, catalog, preset library, fingerprint, device profiles (DeviceProfile),
                       REACTOR messages (ReactorState)
```

- **The link hangs on a transport layer.** `SparkLink` talks to `LinkTransport`: `CoreBluetoothTransport` in the
  app, `SimulatedDevice` in tests and window pictures (`--library … --demo-devices`). This way tests check the NEO's
  falling back and that the REACTOR gets no byte, without Bluetooth.

- **Hosts instead of public modules.** Every library shows the app exactly one host. The rest stays `internal`.
  `RecorderSession` (formerly Spark Recorder's AppDelegate) takes over the app's window: the Dock's REC, "the
  recording continues when the window is closed", restoring after a crash and the UI self-test refer to it.
- **One window.** The deck fixed on top (122 pt), below it the area, chosen with `SegmentTabs` in the toolbar or
  ⇧⌘1 / ⇧⌘2 / ⇧⌘3 (menu View). Smallest content 1120 × 720. Areas are rebuilt when switching, their state lives in
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
- **Bluetooth on demand.** No `CBCentralManager` at start, so no Bluetooth prompt. It connects when the area Presets
  first shows (only the first time, otherwise "Disconnect" would not hold), with the key "Connect" at the foot of
  the sidebar, with the lamp "BT" in the deck or through the menu. State `.off` reads "Disconnected". A Bluetooth
  error is reported and never ends a recording.

### Adding an area

For another app, such as a tuner or setlists:

1. A new library `Sources/Spark<Name>UI` with a `<Name>Host` (content as `AnyView`, menus as `Commands` with
   `isActive`), depending on SparkDesign and what it needs. A target in Package.swift, a dependency of AmpBench.
2. A new case in `StudioArea` (Sources/AmpBench/Studio.swift). ⇧⌘ plus the next digit and the tab follow from it.
3. One line in the `switch` of `StudioWindowView` and one in `StudioCommands`.
4. A scope in `StudioKeymap` with all keys of the area. `StudioKeymapTests` reports every key used twice.
5. Single keys stay reserved for the area Record, except R and Space.

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
  (whether the amp leaves it on without a connection is unchecked). A REACTOR never gets anything, not here either.
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
  `Aufnahmen/.presets/<take UUID>.json` (`PresetFile.snapshotData`), so that "Open in editor" uses the normal
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
  `Bibliothek.vor-Schema-2.aus-1.json` before the first save. A version that only knows schema 1 opens schema 2
  read-only and can therefore never drop the new fields.
- **Folders:** `~/Music/AmpBench/Aufnahmen` and `…/Presets` (`StudioFolders`). At the first start
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
| everywhere | R, Space, ⇧⌘1/⇧⌘2/⇧⌘3, ⌘/, ⌘Z/⇧⌘Z (in the area in front), ⌘S (preset in the editor), ⌘1–⌘8 (connected, as many slots as the device has) |
| Record | L M K F B N T G, ⌘G, 1–5, - + 0, ← → (with ⇧), ⌫ ⌦ ⌘⌫, ⌘E, ⇧⌘R, ⌘F, Esc |
| Presets | ⌘N, ⇧⌘N, ⌘D, ⇧⌘S, ⌥⌘1–⌥⌘8, ⌘B, ⇧⌘L, ⌘R, ⌃1–⌃7, ⌃0, arrows on a knob, ⌘E, ⌘⌫, ⇧⌘R |
| Tuner | ⌘T (needle/strobe), ⌘↑/⌘↓ (concert pitch ±0.1 Hz), ⌘0 (440 Hz), ⌃1–⌃6 (tuning); no single keys |

Decided: ⌘E, ⌘⌫, ⇧⌘R act on the take or the preset depending on the area. ⌘S saves the preset in the editor
everywhere (the recorder saves by itself). ⌘1–⌘4 everywhere, but only with a connection. R everywhere, even though it
takes the type-select for "r" from the sidebar. Esc belongs to the search field in the area Presets. ⇧⌘S only in
Presets, because it opens a sheet there. ⌘E stays Rename; the design canvas showed "Export ⌘E", which got no keycap.
Whether ⌘F focuses the presets' search field is not checked, so it is not in the list.

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
| REACTOR 50 | 8 (Red 1–4, Green 1–4) | listening, buttons, tuner, tap, USB audio (name not read yet), Text to Tone, a sound as live commands (`.liveSound`) | gets only a `ReactorSound`, no preset, no request | listened to; live commands heard (2026-11-10) |
| REACTOR 100 | 8 | like the 50 | | unchecked |
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
- **Bluetooth on demand** as before; no scan at start.
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

- **USB-C:** a USB audio device with 1 input and 2 outputs, 48 kHz, 24 bits; the input carries the finished sound
  with all effects. Beside it a serial port "PG Virtual Com" (firmware program) and an Espressif JTAG
  interface (can reset the chip): **never open them, not even for listing.** No USB MIDI. Manual: plug in USB
  while the REACTOR is off. The exact USB audio name has not been read yet; until then it is not
  in the profile, and the recorder does not record from the REACTOR (`InputPolicy.usbDevices(named:)` with the names
  of the profiles replaces the fixed "spark").
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
- **Text to Tone:** the editor's "⋯ → Copy text for REACTOR" (like `--recipe-prompt`); the REACTOR interprets the
  text itself.
- **Open:** the meaning of `03 1A 91 00 02 C3`; Power Control (50/25/1 W); PAIR; expression pedal; wah, EQ and
  FX loop; the additional bank change; why FX Level was silent twice; USB audio name and latency. Known since
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
4. Next: interpret the blocks (`05 03`, the effect ids), so that
   a REACTOR slot appears in the same editor as a Spark slot; then write a preset back unchanged, with a
   backup; then own sounds.
5. Still open, each only with consent at the device: hearing the sequence from the app; the other five amps,
   Push/Smooth and Heat as a command; effect knobs other than the reverb level (delay time, drive); switching the
   slot (`01 38`); understanding the preset format far enough that the app can read and show a slot. Writing a preset
   only when the format is completely understood and covered by a backup.
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
- REACTOR: send nothing, by no way (BLE, USB serial, JTAG, MIDI), until "sending" above is done with the owner.
  The profile has no `.send`, the link and the transport refuse every byte.
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
  parameters without waiting; the REACTOR gets no byte, not even on read, switch, send and store requests;
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
- Moving into the libraries (308cc7f): window pictures before and after differ only where two
  runs of the same state differ as well.
- Window pictures of both areas looked at in light and dark and at 1120 × 720 (docs/pictures).
- Icon: looked at in 1024 and 32 px.

## Open and next

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
- **REACTOR like a Spark** (the owner's wish, everything in one piece): interpret the blocks of the preset format, so
  that a REACTOR slot opens in the same editor; then, with consent at the device, write a preset back unchanged to
  its slot (a backup exists, the checksum is known, the write command is unchecked); then "Save to slot"
  for own sounds. As soon as that works, "Play on the REACTOR" goes away as a menu item of its own. Take reading
  and showing over into the Linux app.
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
  Unchecked on the amp: that a delay with sync = BPM comes as a quarter note on `bpm`; the rule
  "dotted eighth = song tempo × 4/3" in the prompt rests on that.
- **Audio tests through BlackHole**, keep watching: on 2026-11-08 green in the morning, four failures at noon,
  green again in the evening, with no change to SparkCore in between. See Checks.
- **Trailer:** whether loudness and extra gain in the trailer are audible is not checked. If so, they belong in
  the fingerprint, and old stamps are recomputed.
- **Small screens:** 720 pt of content plus toolbar and menu bar just fit screens 800 pt high, not with the Dock
  at the bottom. Proposal: let the library shrink, not the deck.
- **Library of the presets:** groups have been pinned hashtags since 2026-11-10 (section "Ordering presets").
  Open: assigning by dragging, favorites and rating in the UI, sorting, export, a version history per
  preset; filtering pieces by key and tempo.
- **Kemper import:** listen to the translated sounds on the Spark and improve the amp rules after that (above all
  Dream Weaver, Divided by 13, Naylor). The Linux app can do the import and hashtags since 2026-11-10
  (`linux/ampbench/kemper.py`, a sidebar with tag chips and pinned sections); on the author's backup both apps
  print the same `--kemper-list` line for line. Linux edits tags through a dialog (Ctrl+T), not in a line
  below the name.
- **Setlists and stage mode** build on the pieces: order by drag and drop, a large full-screen mode with
  switching by arrow keys, Space and numbers, next song or part by key. Optionally "Setlist to the amp":
  up to four presets into the slots, with a question and a backup as when storing in a slot.
- **Old apps:** Spark Recorder and Spark Presets are removed from the project, their installed copies have been in
  the Trash since 2026-11-07 and are taken out of the Dock. The old folders `~/Music/Spark Recorder` and
  `~/Music/Spark Presets` are there unchanged; the app no longer reads them. Whether and when they are deleted is
  for the owner to decide.
