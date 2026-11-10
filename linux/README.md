# AmpBench for Linux

AmpBench for Omarchy and other Linux desktops, with the same areas as on the Mac: **Record** (recording from
the Spark's USB input through PipeWire, the library of takes, pieces), **Presets** (read the amp's slots over
Bluetooth LE, edit a preset with knobs and the signal chain, hear every change live on the amp, keep presets on the
computer and store them in a slot, with a backup and a read-back; sound recipes open like presets) and
**Tuner**. Since 2026-11-10 it has every function the Mac app has for a Spark; only the REACTOR's presets and
live commands are not here yet.

The UI is English by default and German when the system language is German; the menu "Language" switches it, as on
the Mac. This page quotes the English labels.

It uses the same files as the Mac app: presets in `~/Music/AmpBench/Presets` (one JSON file each, the same format), sound
recipes, and the model catalog `docs/ai/spark-catalog.json`, which the Mac app writes from its Swift catalog. So both
apps know the same amps, effects and start values.

**Hashtags and the Kemper import** work as on the Mac: every preset can carry tags (Preset ⇒ "Edit tags …",
Ctrl+T, or the context menu), the sidebar filters by tag chips and shows pinned tags as sections of their own, and
Preset ⇒ "Import from Kemper …" reads a Kemper backup (`.kpabackup`) or rig (`.kipr`) into presets and pieces.
`kemper.py` is the port of `Sources/SparkControl/Kemper`; on the same backup both apps print the same
`--kemper-list`.

**The area Tuner** (Ctrl+Shift+3) works as on the Mac: a chromatic tuner with string detection for guitar and
bass, 30 Hz to 1.4 kHz, to a tenth of a cent, A4 from 430.0 to 450.0 Hz, the tunings Standard, Drop D, DADGAD, Open G,
half a step down and chromatic, needle or strobe (Ctrl+T in this area). Ctrl+↑ and Ctrl+↓ move the concert pitch by a
tenth of a hertz, Ctrl+0 sets it back to 440 Hz. It reads the Spark input along with the recorder instead of
opening it twice, and only while its area shows. The amp's own tuner as input switches a MINI's or NEO's tuner on
over Bluetooth (the amp is silent then) and off when the area is left, before a disconnect and on quit; "Automatic"
takes USB when the amp has it, otherwise the amp's own tuner. `pitch.py` and `tuning.py` port the Mac's pitch tracker
and tunings with numpy (about 7 % of one core on the laptop); `tuner.py` is the engine and model, `ui/tuner_view.py`
the front.

**AI Sound** (Preset ⇒ "AI Sound from a description …", Ctrl+Alt+N) works as on the Mac: a description in your own
words goes to Ollama's cloud API, three different suggestions arrive one by one, "Listen" plays one on the amp's
temporary place, "warmer", "more gain", "less reverb" and "brighter" adjust it, "Keep" puts it into the library
as a recipe. Only the rules, the catalog, the wish and, for an adjustment, the recipe leave the computer; a wish with
an e-mail address, a phone number or a key is refused before anything is sent. The API key is kept in the desktop's
keyring through `secret-tool`, otherwise in `~/.config/ampbench/ollama-key` (mode 0600); a key stored while the
app was called Spark Studio is taken over once. The last 8 wishes are kept under `AI Sound History` in
`~/.config/local.ampbench/AmpBench.conf` and can be cleared in the window. "Cancel request" stops retries and
further rounds at once; a request already on its way runs to its end (at most 120 s) and its answer is discarded.
`sound_ai.py` is the port of SoundAI, `ai_key.py` the key store, `ui/ai_sound_dialog.py` the window.

**Not here yet:** reading a REACTOR's presets, and the REACTOR live commands.

## Install

On the Linux machine itself, from a checkout of this repository:

```bash
linux/install.sh "$(git rev-parse --short HEAD)"   # the argument is the build id shown by --version
```

It needs `python3` and installs without root into `~/.local/share/ampbench` (app and Python environment),
`~/.local/bin/ampbench` and the menu entry, after the tests pass. A failing test stops the install and leaves the
installed version as it is.

## Keep in step with the Mac

To keep a Mac and a Linux laptop on one version, do not install by hand. From the Mac:

```bash
./sync.sh          # build and install on the Mac, ship and install on the Linux laptop, compare versions
./sync.sh --check  # only compare what is installed
```

`sync.sh` installs the Mac app (`build.sh --install`), checks that `docs/ai/spark-catalog.json` matches the Mac
catalog, ships the Linux sources over SSH (to the host in `$SPARK_LINUX_HOST`) and runs `linux/install.sh` there.
Both apps then print the same line, for example
`AmpBench 1.0.0 (22ba606)`: `VERSION` in the repository root, and the commit, with a short digest behind it for
changes that are not committed yet.

To change the version, edit `VERSION`, then run `./sync.sh`.

## On the laptop

```bash
ampbench                         # the window; it looks for the amp at once
ampbench --demo                  # a simulated amp and a temporary folder, to look around
ampbench --recipe-check my.json  # check a sound recipe, like the Mac app's --recipe-check
ampbench --kemper-list backup.kpabackup  # what a Kemper import would make, reads only
ampbench --version
```

Bluetooth goes through BlueZ (`bleak`). Like on the Mac, the app only looks for devices that offer the Spark control
service and takes the amp's one control connection: "Disconnect" lets the Spark app on the phone take it again.

## Code

`ampbench/protocol.py`, `catalog.py`, `recipe.py`, `factory.py`, `editor.py`, `library.py`, `kemper.py`, `pitch.py`
and `tuning.py` are ports of
`Sources/SparkControl`; the Swift code is the reference, change both together. `link.py` is the port of `SparkLink.swift`
(with a simulated amp in `fake_amp.py`), `qtlink.py` and `ui/` are the window. Tests: `linux/tests`, run by the install
(`cd linux && QT_QPA_PLATFORM=offscreen python -m pytest`). They read real presets from the amp as fixtures.
