# Building Spark sounds with an AI assistant

This folder lets Claude or any other AI assistant build guitar sounds for Positive Grid Spark amps. The sounds can be
checked without the amp and then played in Spark Studio. The assistant writes a **sound recipe**, a small JSON file that
names a model and settings for each place of the signal chain. Spark Studio reads recipes from its presets folder like
any preset. It plays them on the amp's temporary place and stores them in a slot only when you ask.

| File | What it is |
|---|---|
| [spark-catalog.json](spark-catalog.json) | Every amp and effect model: id, place, character, parameters with keys, ranges and the amp's start values. Generated, do not edit. |
| [spark-catalog.md](spark-catalog.md) | The same as tables, for reading. |
| [recipe.schema.json](recipe.schema.json) | JSON Schema of a recipe. |
| [examples/](examples) | Recipes that pass the check: blues crunch, glassy clean, modern metal, ambient. |
| this guide | How to choose models and values. |

## Workflow

1. Read `spark-catalog.json`. Use only model ids and parameter keys from it, with their exact spelling.
2. Write the recipe. Start from the closest example and change it, rather than writing every value from scratch.
3. Check it. With Spark Studio installed:
   ```bash
   "/Applications/Spark Studio.app/Contents/MacOS/SparkStudio" --recipe-check my-sound.json
   ```
   In this repository, `swift run SparkStudio --recipe-check my-sound.json` does the same. The check prints every value the amp will
   get, lists what it corrected, and exits with 1 when a recipe cannot be read.
4. Put the file into `~/Music/Spark Studio/Presets`. It shows up in Studio's area Presets when the window comes to the
   front, marked with a wand. Clicking it plays it on the amp's temporary place without overwriting a slot. Saving it
   in the editor turns it into an ordinary preset file. A recipe with errors is listed under "Nicht lesbar".
5. Describe in `notes` what to adjust by ear. The assistant cannot hear the result, the player can.

The reverse works too. This command describes a saved preset as a recipe, so an assistant can read a sound and change it:

```bash
"/Applications/Spark Studio.app/Contents/MacOS/SparkStudio" --recipe-from "~/Music/Spark Studio/Presets/Jazz.json"
```

## The format

```json
{
  "format": "spark-sound-recipe",
  "version": 1,
  "name": "Texas Blues",
  "description": "Edge-of-breakup combo pushed by a mid drive",
  "bpm": 96,
  "tags": ["Blues", "Crunch"],
  "notes": "Too fizzy: lower drive.drive to 2.",
  "chain": {
    "drive": { "model": "DistortionTS9", "settings": { "drive": 3, "tone": 5.5, "level": 7 } },
    "amp": { "model": "Bassman", "settings": { "gain": 5, "treble": 6, "middle": 6.5, "bass": 4.5, "master": 7 } },
    "reverb": { "model": "bias.reverb", "settings": { "level": 2.5, "type": "Raum B" } }
  }
}
```

- **`chain`** has up to seven places: `gate`, `compressor`, `drive`, `amp`, `modulation`, `delay`, `reverb`. Each place
  holds exactly one model. A place left out is switched off.
- **`on`** defaults to true. Set it to false to keep a model in the preset but silent.
- **`settings`** maps parameter keys to values. A key left out keeps the amp's start value from the catalog.
  - Knobs take a number from 0 to 10, like the editor. Values outside are clamped, and the check says so.
  - Switches take `true` or `false`, or one of the labels in the catalog's `off` and `on`, such as `"BPM"`.
  - Choices take one of the option labels, such as `"Saal weit"` for the reverb type. Labels are German, copy them from
    the catalog.
- **`name`** may have at most 31 bytes, and umlauts count twice. Longer names are cut.
- **`bpm`** goes from 40 to 250. Delays and modulations whose `sync` is on follow it.
- An unknown model, a model at the wrong place or an unknown key is an error, so a typo never goes unnoticed.

## The chain

The order is fixed: gate, compressor, drive, amp, modulation, delay, reverb. Some things follow from that.

- **EQ is a modulation.** `GuitarEQ6` and `BassEQ6` sit at the modulation place. A preset has either an EQ there or
  a chorus, phaser or tremolo, never both.
- **The wah of the paid add-on sits at the compressor place.** Models marked `"pack": true` need the add-on unlocked in
  the official Spark app, otherwise the amp refuses them. Avoid them unless the player says the add-on is unlocked.
- **There is one reverb model.** Its `type` chooses room, chamber, hall or plate. The gate has one model too.
- **Amps all have five knobs:** `gain`, `treble`, `middle`, `bass`, and `master` (pack amps call it `volume`).

## Choosing the amp

Pick the amp first, by its `group` and `inspiration` in the catalog, then build around it.

| Wanted | Group | Good first choices |
|---|---|---|
| Sparkling clean, jazz, funk | clean | `Twin`, `RolandJC120` (dry, very tight), `94MatchDCV2` (chimey) |
| Clean that breaks up when you dig in | clean, crunch | `ODS50CN`, `Deluxe65`, `BluesJrTweed` |
| British chime, 60s pop, indie | bright | `AC Boost`, `Bassman` |
| Classic rock rhythm | crunch | `Plexi`, `OverDrivenJM45` |
| Blues lead | crunch, bright | `Bassman` or `OverDrivenLuxVerb`, pushed by `DistortionTS9` |
| Singing lead, fusion | highGain | `SLO100`, `Bogner`, `ODS50CN` with a drive |
| 80s hard rock | metal, highGain | `EVH`, `SwitchAxeLead`, `YJM100` |
| Modern metal | metal | `6505Plus`, `Rectifier`, `BE101` |
| Acoustic guitar | acoustic | `AcousticAmpV2`, `FatAcousticV2` |
| Bass | bass | `GK800`, `Sunny3000`, `W600`, `Hammer500` |

Named rigs translate through `inspiration`. A Dumble rig points to `ODS50CN`, a Fender Twin to `Twin`, a Marshall
Plexi to `Plexi`, a Mesa to `AmericanHighGain` or `Rectifier`. This is a starting point, not a copy. Profiles from a
Kemper or similar devices cannot be converted. Only their names and descriptions help choose a model.

## Values that work

These are starting points from general guitar practice, not measurements of the Spark. The player fine-tunes by ear.

**Gain staging.**
- Clean: amp `gain` 2 to 4. Edge of breakup: 4.5 to 6. Crunch: 5 to 7. High gain: 5 to 7 on a high-gain amp is
  usually enough. Above 8 the sound gets fizzy and noisy.
- `master` sets loudness, not distortion. Keep it between 6 and 8, and keep presets of one set at a similar level by
  adjusting `master`.
- To tighten a high-gain amp, put a drive in front with almost no gain and a high level: `DistortionTS9` with `drive`
  0 to 1.5 and `level` 7 to 9, or `Booster`. This cuts the low end in front of the amp instead of adding distortion.
- To push a crunch amp into a lead, use the same drive with `drive` 2 to 4.

**EQ words.**

| The player says | Move |
|---|---|
| warmer, darker | `treble` down 1 to 2; for drives, `tone` down |
| brighter, more sparkle | `treble` up 1; reverb `highCut` up |
| muddy, boomy | `bass` down 1 to 2; a drive in front as above |
| thin, harsh | `bass` up, `treble` down; less `gain` |
| more cut in the band, more bite | `middle` up 1 to 2 |
| scooped, heavier rhythm | `middle` down to 3 or 4, but not below 3 or the guitar gets lost |
| fizzy | `gain` down first, then `treble` down |
| more sustain | compressor `BlueComp` with `sustain` 6 to 7, or more `gain` |
| more punch, funk spank | `LA2AComp` or `Compressor`, a clean amp, little reverb |

**Time effects.**
- Delay: `effect`, `level` or `mix` is how loud the echoes are. For rhythm keep it at 2 to 3; for leads use 3 to 4. `feedback` or
  `sustain` sets how many repeats; 2 to 4 gives a few, above 7 it runs away.
- With `sync` on, the echo follows the preset's `bpm`. Set `bpm` to the song's tempo.
- Reverb: `level` 1.5 to 3 for rhythm, 3 to 5 for clean and ambient. `length` 3 to 5 is a room, 7 to 9 a large hall.
  `type`: Raum A/B and Kammer are small, Saal natürlich, Saal mittel, Saal weit get larger, Platte kurz, Platte satt and Platte lang are
  plates, bright and smooth.
- Modulation: chorus `effect` 3 to 5 for a subtle widening, `rate` low for slow movement. Tremolo `speed` 4 to 6 for a
  surf pulse.

**Gate.** `threshold` 1.5 to 3 for crunch, 3 to 5 for high gain. Too high cuts off quiet notes and sustain. Switch it off for clean sounds.

## What an assistant should know

- **It cannot hear.** Every recipe is a reasoned first guess. Say in `notes` which one or two knobs to turn first.
- **Changes reach the amp slowly.** Spark Studio paces model changes, because a long series of them once made a Spark
  MINI hang. Never ask the player to step through many presets quickly.
- **Start values are from a Spark MINI.** They were read back from a Spark MINI with firmware 1.11.2.75. The models and
  their parameters are shared by the Spark family, but only the MINI was checked.
- **Other devices** are covered in the next section.
- **No personal data.** A recipe holds a sound, not people. Keep names of other players out of `notes` unless the
  player writes them.

## Devices

A recipe names models and settings, not the bytes of one amp. How it reaches a device depends on the device.

| Device | How a recipe gets there | Checked |
|---|---|---|
| Spark MINI | Spark Studio over Bluetooth: play on the temporary place, store in a slot | Yes, firmware 1.11.2.75 |
| Other Spark amps (Spark 40, GO, 2, LIVE) | Same way, if they know the model ids | No. Newer amps may know models the catalog lacks |
| Spark NEO | Spark Studio over Bluetooth, the same way as the MINI | Yes, firmware 1.16.1.60 (its factory models; storing and live changes heard) |
| REACTOR (50 and 100) | As text for its "Text to Tone", see below. Spark Studio listens to it over Bluetooth; for the REACTOR 50 its editor can also set the nearest amp, gain, tone and effect switches from a preset ("Auf den REACTOR spielen"), never a preset | Text route not tried on the amp; single live commands heard on 2026-11-10 |

### REACTOR

REACTOR is Positive Grid's combo amp with "Amp Intelligence". Its tones come from the REACTOR app, which builds them
from text, a photo or audio. Positive Grid calls it a separate product line, not compatible with Spark. As of
2026-11-08 its product page names no preset file format, no import or export and no interface for other software.
Spark Studio can therefore not send a recipe to it as a preset. A description as text travels well.
Its Bluetooth control speaks the Spark message format on another service. On 2026-11-10 the REACTOR 50 answered read
requests and took single live commands (amp selector, gain and tone knobs, effect switches), so Studio's editor can
set the nearest sound on it with "⋯ → Auf den REACTOR spielen". Its presets are a format of its own that is only
partly understood, so a Spark preset must never be sent to it. In the editor, "⋯ → Text für REACTOR
kopieren" puts the same text on the pasteboard.

```bash
"/Applications/Spark Studio.app/Contents/MacOS/SparkStudio" --recipe-prompt docs/ai/examples/texas-blues.json
```

```text
Guitar tone “Texas Blues: Edge-of-breakup combo pushed by a mid drive”, 96 BPM.
Drive pedal: Ibanez TS9 style pedal, drive 3/10, tone 5.5/10, level 7/10.
Amp: Fender Bassman ’59 style amp, gain 5/10, treble 6/10, middle 6.5/10, bass 4.5/10, master 7/10.
Reverb: room reverb, level 2.5/10, length 4/10.
Notes: ...
```

Paste that into the app's Text to Tone and refine there by typing, such as "less bass". The command also takes a saved
preset file, so every sound in Spark Studio can be described this way. The result is REACTOR's own reading of the
description, not a copy: it chooses from its own amp models, and its knobs are not calibrated like the Spark's. An
assistant writing for REACTOR should name the real amp and pedals the sound is modeled after, give the amp's five
knobs, and describe the character in words. It can skip the Spark model ids.

What REACTOR sends to Positive Grid when it analyzes a photo or a recording is not stated on the product page. Use
only your own material there.
