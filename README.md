# Spark Recorder

A native macOS recorder for guitar practice: record, listen right away, decide, keep practicing, in a few seconds and
without the mouse. It was built for the Positive Grid Spark Mini but works with any input device macOS offers.

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
| `Space` | Play or pause |
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
| `N` / `T` | Metronome on or off / tap tempo |
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
on outputs of the same hardware as the input, and on speakers while recording from the built-in microphone. The click
picks a safe output on its own. "Aufnahme → Rückkopplung messen" plays quiet clicks and checks whether they arrive at the
input. Only a measurement can unlock a pair of devices, and it counts for exactly that pair.

The click has no code path into the recording, so the app cannot write it to a file.

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

The app also has a self-test that drives its real window with key events. It only runs with a separate test library,
which keeps it away from your recordings, and it only uses BlackHole and a silent virtual output:

```bash
"build/Spark Recorder.app/Contents/MacOS/SparkRecorder" --library /tmp/spark-test --ui-selftest main /tmp/spark-results
```

Other scenarios are `legacy`, `crash-start`, `crash-verify`, `realwindow` and `pictures`.

These headless commands check the audio path without the UI:

```bash
SparkRecorder --list
SparkRecorder --record "BlackHole" 5 /tmp/test.wav
SparkRecorder --play-tone "BlackHole" 5 1000 0.25
SparkRecorder --inspect /tmp/test.wav
```
