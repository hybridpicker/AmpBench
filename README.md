# Spark Recorder

A native macOS recorder for guitar practice: record, listen right away, decide, keep practicing, in a few seconds and
without the mouse. It was built for the Positive Grid Spark Mini.

It only records from a USB device with "Spark" in its name. Without one it records nothing: no microphone, no other input
and no automatic fallback. Pulling the cable closes the input, and plugging it back in starts nothing by itself.

Everything stays on this Mac. The app makes no network connections and has no telemetry.

## Build and run

```bash
./build.sh            # builds "build/Spark Recorder.app"
./build.sh --install  # also copies it to /Applications and adds it to the Dock
```

Requires macOS 14 or later and the Swift toolchain from Xcode. There are no external dependencies. The build signs with
an Apple Development certificate if one exists, because macOS then keeps the microphone permission across rebuilds.
Without one it uses an ad-hoc signature. `SPARK_SIGN_IDENTITY` overrides the choice, and `-` forces ad-hoc.

## Keyboard

| Key | Action |
|---|---|
| `R` | Start or stop recording, also "Nochmal" |
| `Space` | Play or pause. It does nothing while a recording runs, and after stopping it plays the new take |
| `L` | Loop: first press sets A, second sets B, third removes it |
| `M` | Marker, also during a recording |
| `K` | Keep the take |
| `⌘⌫` | Discard the take: it goes to the Trash, and `⌘Z` brings it back |
| `←` `→` | Jump 5 seconds, with `⇧` 1 second |
| `-` `+` | Slower or faster |
| `0` | Reset tempo and pitch |
| `1` – `5` | Rate |
| `F` | Favorite |
| `B` | Switch take while comparing |
| `N` / `T` | Click on or off, heard only while playing or recording / tap tempo |
| `G` | Save the retro buffer ("Das eben war gut") |
| `⌘F` / `⌘E` | Search / rename |
| `Esc` | Leave a text field |

Single keys do nothing while you type in a text field, and no single key can delete anything. `⌘/` shows this list.

## Where things are

```
~/Music/Spark Recorder/
  *.wav                  Recordings. They are the originals and are never rewritten.
  Bibliothek.json        Metadata: names, ratings, tags, notes, takes, markers, edits. Plain, readable JSON.
  Bibliothek.backup.json The previous version of that file.
  Exporte/               Default folder for exports. It is not part of the library.
  .wellenformen/         Waveform cache. Safe to delete, it is rebuilt when needed.
  .aufnahme-laeuft.json  Exists only during a recording, for crash recovery.
```

Files placed in the folder are picked up on the next start or with "Ordner prüfen". Files renamed in the Finder keep
their metadata. A missing file keeps its entry and is marked. Older recordings are adopted unchanged, with no gain and
with an unknown source, because what happened to them before is not known.

## Recording safety

- The input runs on its own AUHAL unit. The realtime code is in C (`Sources/CSparkRT`) and does not lock, allocate or
  block. Playback, analysis and the UI have no way to stall it.
- Audio is written continuously. If the app crashes, the next start repairs the file's header and adds the take, with
  its markers. Repair only changes size fields in the header, and the audio bytes stay as they were. A file that cannot
  be repaired stays where it is and gets reported.
- A lost device or a sample rate changed by another app ends the recording safely and keeps what was recorded. If the
  input just stops delivering, the app warns but keeps the file open, in case the device returns.
- Recordings stop safely when the disk is nearly full and just below the 4 GB limit of the WAV format.
- A running recording continues when the window closes. The Dock icon then shows REC and brings the window back.

## Feedback and the click

Whether the amp's USB input also carries its USB output is not assumed. While recording, playback and click are blocked
on outputs of the same hardware as the input. The click
picks a safe output on its own. "Aufnahme → Rückkopplung messen" plays quiet clicks and checks whether they arrive at the
input. Only a measurement can unlock a pair of devices, and it counts for exactly that pair.

The click has no code path into the recording, so the app cannot write it to a file.

While playing, the click is mixed into what plays and goes to the playback output. It follows the take's bars, or the
metronome's tempo from the start of a take without bars, and it never reaches a file or an export. While recording, it
runs on its own unit on the click output. A count-in always sounds, even with the click switched off.

## Bars

A recording with a count-in or with the click switched on knows its bars. The window shows the current bar and beat
while recording, and the waveform shows bar lines, also afterwards. Tempo and meter stay fixed during a recording, because
the bars rest on them.

## Timing of click and bars

The bars are meant to be as exact as in a DAW, well under a millisecond on the app's side:

- The click runs on the input's clock. Its beats lie on input frames, and every output block is placed by its host
  time stamp, so click and input never drift apart, even on two devices with separate clocks and for any length of
  take. The file and the count-in gate are counted in the same input frames, so bar 1 lies exactly where it should.
- The latencies the devices report are added: output latency of the click device and input latency of the amp,
  each as device plus stream latency. The safety offset is already part of Core Audio's time stamps and is not added.
- What the amp does inside, in its converters and effects, no device reports. "Aufnahme → Klick-Latenz messen" plays
  clicks through a cable from the click output into the amp's guitar input, the way a played note travels, and
  measures where they land in a temporary file. It refuses a result when the clicks are missing or spread more than
  2 ms. The result counts for exactly that pair of devices and for recordings made afterwards. It can also be set by
  hand in the metronome details, in steps of 0.5 ms.

On the BlackHole loop test, every beat lands within one sample of the grid.

Dragging over the waveform of such a take selects whole bars, and `⌥` selects freely. The bar controls below the transport
loop the chosen bars or record them again. Recording bars again counts in at the tempo and meter of the take, stops by
itself shortly after the last bar and creates a recording of its own, such as "Take Takt 5-8.wav". It keeps the bar
numbers and the piece of the take. The original stays as it is, and the two are not merged.

## Audio quality

- The device runs at its highest rate up to 192 kHz during a recording, and its previous rate comes back afterwards.
- Files are always WAV with 24 bits. A 16-bit source stays lossless and gains headroom for editing, but no extra detail.
  The window therefore shows source and file separately, and nothing is labeled "Hi-Res".
- On the tested amp, the USB descriptor offers one channel at 16 bits and 44.1 kHz for capture. Higher quality from the
  amp needs a different signal path, such as its line out into an audio interface.

## Edits

Trim, fades, gain and automatic level are stored in the library and applied when listening and exporting. Automatic
level raises the peak to -1 dBFS with one constant gain of at most 30 dB. Dynamics stay intact and the noise floor rises
with it. Only an export writes a new file, and it refuses to replace the original.

## Retro recording

Off by default. While on, the input stays open and the display says "HÖRT MIT". The last minutes are held in memory only
and never reach the disk on their own. "Das eben war gut" saves them. Turning it off, losing the device, closing the
window or quitting erases the buffer.

## Project layout

```
Sources/CSparkRT       Realtime capture and click (C)
Sources/SparkCore      Capture, library, repair, edits, playback, export, statistics (no UI)
Sources/SparkRecorder  The app (SwiftUI)
Tests/SparkCoreTests   Unit tests and audio tests with synthetic signals
Tools/make-icon.swift  Draws the app icon
```

## Tests

```bash
swift test
```

All audio is generated by the tests. No test reads a real recording. The audio path tests send a tone through the
virtual [BlackHole](https://github.com/ExistentialAudio/BlackHole) device, and they skip with a reason when BlackHole or
the microphone permission is missing.

The audio engine refuses every input outside its policy. The default is Spark only, and tests use a policy that allows
virtual test devices and nothing real, not even the amp.

The app also has a self-test that drives its real window with key events. It only runs with a separate test library,
which keeps it away from your recordings. A test library only hears BlackHole, and sound goes to a silent virtual output:

```bash
"build/Spark Recorder.app/Contents/MacOS/SparkRecorder" --library /tmp/spark-test --ui-selftest main /tmp/spark-results
```

Other scenarios are `legacy`, `crash-start`, `crash-verify`, `realwindow` and `pictures`. Two more cover the Spark-only
rule and take an extra option: `nospark` with `--test-input none`, and `reconnect` with `--test-input aggregate`.

These headless commands check the audio path without the UI:

```bash
SparkRecorder --list
SparkRecorder --record "Spark" 5 /tmp/test.wav
SparkRecorder --play-tone "BlackHole" 5 1000 0.25
SparkRecorder --inspect /tmp/test.wav
```
