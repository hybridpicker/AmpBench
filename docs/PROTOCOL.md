# Amp control over Bluetooth

The amp's sounds are controlled over Bluetooth LE, not over USB: its USB side offers only audio and volume keys.
`spark-probe` is a test tool for that control channel, and the area Presets is built on the same protocol in
`Sources/SparkControl`.

Positive Grid does not document the protocol. Everything here follows community reverse engineering (see
[Sources and credits](../README.md#sources-and-credits)) and observation on the devices. What is known about the
Spark NEO and the REACTOR 50 beyond this page is in [STUDIO.md](STUDIO.md#devices).

## spark-probe

```bash
swift build --product spark-probe
.build/debug/spark-probe scan          # look for the amp, with the profile it is recognised as
.build/debug/spark-probe listen 60     # Spark or REACTOR: subscribe only, send nothing, sum up what came
.build/debug/spark-probe ask firmware  # exactly one read request (firmware, name, slot, current), print the answer
.build/debug/spark-probe read-slot 0 slot0.bin       # exactly one read request for a stored slot, answer into a file
.build/debug/spark-probe set-one Amp.Preamp 0 0.1    # exactly one parameter change
.build/debug/spark-probe switch-one MonoReverb on    # exactly one effect switch
.build/debug/spark-probe send-one B1 00 07           # exactly one set message, to try a command
.build/debug/spark-probe info          # firmware, name, current preset number, the playing and the 4 stored presets
.build/debug/spark-probe preset 2      # switch to stored preset 2, like the preset button
.build/debug/spark-probe watch 30      # print what the amp sends, e.g. when its preset button is pressed
.build/debug/spark-probe tuner 20      # the amp's own tuner on, sum up its readings, off; --compare also hears USB
.build/debug/spark-probe try 3         # play a renamed copy of stored preset 3 without storing it
.build/debug/spark-probe store-test 4 backup.json        # store a renamed copy in slot 4, then put the original back
.build/debug/spark-probe persist-test store 4 backup.json  # leave a renamed copy in slot 4 …
.build/debug/spark-probe persist-test check 4 backup.json  # … and after switching the amp off and on, check it
.build/debug/spark-probe live 4 script.txt  # play a copy of slot 4 without storing it and run live changes on it
.build/debug/spark-probe backup folder      # write the four stored presets to JSON files
.build/debug/spark-probe catalog-check amp Twin 8  # try 8 amp models from "Twin" on, on the temporary preset
```

`backup` names its files after the slot and the preset, such as `Platz 1 - Jazz.json` ("Platz" is German for slot;
the file names stay German in this release).

A `live` script has one command per line: `param <place> <index> <value>`, `toggle <place> on|off`,
`model <place> <model id>`, `sweep <place> <index> <from> <to> <steps> <ms>`, `wait <seconds>`, `read`, `resend`,
`say <text>` and `raw <command> <sub> <hex bytes>`. A place is 1 to 7 or a model id. After `read`, the probe compares
what the amp plays with what the script sent. The comments in `Sources/SparkProbe/LiveScript.swift` have the details.

`--raw` also prints every byte, `--no-header` sends without the block header, `--no-input` leaves the input byte out
of live changes, `--device <name>` picks one of several devices. The Spark app on the phone and AmpBench must be
disconnected, because the amp takes only one control connection. macOS asks once for Bluetooth access for the terminal
app. The tool shows only devices with "Spark" in their name and only counts the others; `listen` also finds a REACTOR
by its service FFD0 and prints its name without its owner's part. No other command connects to a device whose
profile may not get anything.

From a Claude Code session in the desktop app, the probe must run as its own app, or macOS ends it at the first
Bluetooth call (it counts as part of Claude, which has no Bluetooth usage text):

```bash
Tools/probe-app.sh listen 60      # builds .build/SparkProbe.app, opens it, prints its output when it ends
```

## What is checked on the amp

Every line below was checked with `spark-probe` on a Spark MINI with firmware 1.11.2.75.

| Message | What it does | On the Spark MINI |
|---|---|---|
| Service `FFC0`, write `FFC1`, notify `FFC2` | Control channel | Confirmed |
| Block header `01 FE 00 00 53 FE <len> 00…`, chunks `F0 01 <seq> <xor> <cmd> <sub> <7-bit data> F7` | Framing | Confirmed |
| `02 2F`, `02 11`, `02 10`, `02 01` | Read firmware, name, preset number, a preset (`00 <slot>`, or `01 00` for the playing one) | Confirmed |
| `01 01` | Send a preset in chunks of 25 bytes, one Bluetooth write each. `05 01` per chunk, `04 01` at the end | Confirmed |
| `01 38` | Switch preset, `7F` is the temporary one. Ack `04 38` | Confirmed |
| `01 04` | Set a parameter: `len A0+len <model id>`, index, `CA` float, input byte `00`. No ack | Confirmed and heard, with and without the input byte |
| `01 15` | Effect on or off: model id, `C2`/`C3`, `00`. Ack `04 15` | Confirmed by reading back |
| `01 06` | Change a model: old id, new id, `00`. Ack `04 06` | Confirmed by reading back. The amp loads its own start values for the new model |
| `03 38` | The amp's preset button | Confirmed |
| `03 37`, `03 15` | The amp reports parameter changes and on/off | Seen only as echoes of the probe's own changes, see below. The MINI's guitar and music volume knobs report nothing |
| `03 71` | Sent by the amp now and then, probably power and battery | Seen, not decoded |
| `03 64`, `03 65` | Probably tuner reading and tuner on/off | Seen, not checked |

The tuner messages were checked later on the MINI and the NEO (2026-11-09); see
[STUDIO.md](STUDIO.md#the-amps-own-tuner-mini-neo-checked-on-the-devices-on-2026-11-09).

More findings:

- **Stored presets survive switching the amp off.** A copy stored in slot 4 was still there after switching off and on.
- **The temporary preset ends with the connection.** After the control connection closes, the amp plays the stored
  preset that was selected last. A stored slot that was selected stays selected.
- **The preset's end holds a checksum.** After the effects come, on stored slots, two floats (loudness, 9990 meaning
  not set, and extra gain, 0.5) and a byte that is the sum of all bytes after the two place bytes, modulo 256. The
  playing preset has only the checksum. Every one of the 5 presets read matched this rule. `SparkPreset.encode`
  recomputes the byte, so an edited preset stays consistent, and a preset read from the amp still encodes back to
  exactly the same bytes. An earlier version sent renamed copies with a stale checksum, and the amp played them anyway.
- **The amp keeps two parameters in step with on and off itself:** parameter 2 of the noise gate and parameter 7 of
  the reverb. It also adds reverb parameter 7 when a stored preset without it is played on `7F`.
- **Speed:** 30 parameter changes in a row without any pause arrived. The last value is what plays.
- **Echoes:** In one session, after a fast series of changes, the amp started to answer every parameter change with
  `03 37` and an on/off change with `03 15` instead of `04 15`. A second request for the same change then got no
  answer at all. This did not happen again in a fresh session with the same steps, so its cause is unknown. Both
  forms count as a confirmation, and an answer that stays out is checked by reading the playing preset back.
- The amp sometimes ignores a request, so every request is sent a second time when no answer comes.
- **Too many model changes in a row made the amp hang.** About 40 model changes within two minutes, with no pause
  between them, first brought the echoes above and then silence. The amp no longer reacted to its power button,
  while its Bluetooth still took connections. Unplugging USB, holding POWER for more than 10 seconds and switching it
  on again brought it back, with all four stored presets unchanged. In batches of 8 with a second between changes and
  a new connection per batch, the remaining 34 changes went through without a single echo. `catalog-check` therefore
  works in such batches and stops at the first echo, and the editor spaces out model changes.

The limits AmpBench keeps on everything it sends (`AmpGuard`) are in [STUDIO.md](STUDIO.md#protecting-the-amp).

## Model catalog

`Sources/SparkControl/Catalog` describes every amp and effect model: its place in the chain, a name and a short
description written for this project, the device it is modeled after as a neutral hint, and what each parameter is
(knob, switch, selector with its values). Names and descriptions are this project's own, not those of the official
app. A model id the catalog does not know still works, with numbered knobs, and so do parameters beyond the ones the
catalog names.

`spark-probe catalog-check` checked the catalog on the Spark MINI: it chose every model on the temporary preset and
read back what the amp played. All 68 freely available models were accepted: 1 noise gate, 5 compressors, 10 drives,
33 amps, 12 modulation effects, 6 delays and the reverb with 9 types. `Models+Defaults.swift` holds the values the
amp chose for each, which the editor uses as start values, and their number is the number of parameters the amp
gives the model. Three models have more parameters than the community sources name (vibrato 3, mini vibe 4, square
tremolo 4), and they appear numbered. The models of the paid Jimi Hendrix add-on are in the catalog but hidden, and
the five that were tried were refused, because the add-on is not unlocked on this amp.

The order of reverb parameters 2 to 5 is disputed between sources. The catalog follows the two that agree (low cut,
high cut, density, length), and a listening test confirmed it: with everything else at its maximum, parameter 3 at 0
made the reverb dull but still long, parameter 5 at 0 made it short.

A test fails when `docs/ai` falls behind the catalog, so a new model goes into `Sources/SparkControl/Catalog` and then
through `--catalog-export` (see [DEVELOPMENT.md](DEVELOPMENT.md#command-line-modes)).
