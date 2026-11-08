# Spark Studio for Linux

The area **Presets** of Spark Studio, for Omarchy and other Linux desktops: read the amp's four slots over Bluetooth LE,
edit a preset with knobs and the signal chain, hear every change live on the amp, keep presets on the computer and
store them in a slot, with a backup and a read-back. Sound recipes (docs/ai) open like presets.

It uses the same files as the Mac app: presets in `~/Music/Spark Studio/Presets` (one JSON file each, the same format), sound
recipes, and the model catalog `docs/ai/spark-catalog.json`, which the Mac app writes from its Swift catalog. So both
apps know the same amps, effects and start values.

**Not here yet:** the area *Aufnahme* (recording, library of takes, click, pieces). It needs a PipeWire capture path
that replaces the Mac's CoreAudio code and comes next.

## Install and keep in step with the Mac

Do not install by hand. From the Mac:

```bash
./sync.sh          # build and install on the Mac, ship and install on the Omarchy laptop, compare versions
./sync.sh --check  # only compare what is installed
```

`sync.sh` installs the Mac app (`build.sh --install`), checks that `docs/ai/spark-catalog.json` matches the Mac
catalog, ships the Linux sources over SSH (`linux-host`, or `$SPARK_LINUX_HOST`) and runs `linux/install.sh` there.
That installs without root into `~/.local/share/spark-studio` (app and Python environment), `~/.local/bin/spark-studio`
and the menu entry, after the tests pass. Both apps then print the same line, for example
`Spark Studio 1.0.0 (22ba606)`: `VERSION` in the repository root, and the commit, with a short digest behind it for
changes that are not committed yet.

To change the version, edit `VERSION`, then run `./sync.sh`.

## On the laptop

```bash
spark-studio                         # the window; it looks for the amp at once
spark-studio --demo                  # a simulated amp and a temporary folder, to look around
spark-studio --recipe-check my.json  # check a sound recipe, like the Mac app's --recipe-check
spark-studio --version
```

Bluetooth goes through BlueZ (`bleak`). Like on the Mac, the app only looks for devices that offer the Spark control
service and takes the amp's one control connection: "Trennen" lets the Spark app on the phone take it again.

## Code

`spark_studio/protocol.py`, `catalog.py`, `recipe.py`, `factory.py`, `editor.py` and `library.py` are ports of
`Sources/SparkControl`; the Swift code is the reference, change both together. `link.py` is the port of `SparkLink.swift`
(with a simulated amp in `fake_amp.py`), `qtlink.py` and `ui/` are the window. Tests: `linux/tests`, run by the install
(`cd linux && QT_QPA_PLATFORM=offscreen python -m pytest`). They read real presets from the amp as fixtures.
