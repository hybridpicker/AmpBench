---
name: spark-sound
description: Build or change a guitar sound for the Positive Grid Spark amp as a sound recipe that AmpBench reads, or describe one as text for REACTOR's Text to Tone. Use when the user asks for a sound, tone, preset or amp setting ("build me a blues sound", "make the preset warmer", "a sound like song X"; also in German: "bau mir einen Blues-Sound", "mach das Preset wärmer", "erstelle mir einen Sound wie …"), or wants to adjust a saved preset.
---

# Spark sound recipes

## Steps

1. Read `docs/ai/SOUND-GUIDE.md` and use `docs/ai/spark-catalog.json` for model ids and parameter keys. Never guess
   an id or a key; spelling and case matter.
2. Look at what is there: `ls ~/Music/AmpBench/Presets`. A preset with the song's or player's name may exist already
   (Kemper imports, earlier recipes). Read it with
   `swift run AmpBench --recipe-from "$HOME/Music/AmpBench/Presets/<name>.json"` for its tags and level, and say that
   it exists.
3. To change an existing sound, start from that export. To build a new one, start from the closest file in
   `docs/ai/examples/` or a player in `Sources/SparkControl/Library/SoundAIKnowledge.swift` (`archetypes`).
4. Write the recipe to a scratch file and check it with `swift run AmpBench --recipe-check <file>`. Fix every
   error. Read the warnings and resolve them unless they are intended. Run the check as a command of its own: it
   exits with 1 when a recipe cannot be read, so do not chain other tests behind it.
5. Only when the check passes, copy it to `~/Music/AmpBench/Presets/<name>.json` with `cp -n`. Never overwrite a file
   there without asking; pick a new name instead.
6. Tell the user, in their language:
   - which amp and effects you chose and why, and which one or two knobs to turn first by ear; you cannot hear it;
   - how to set the guitar when it matters (pickup, tone knob, picking);
   - what the Spark cannot do for this sound, if anything (see "What the Spark cannot do" in the guide);
   - where to find it: AmpBench reads the file when its window comes to the front. The sidebar shows only favorites
     and recently used sounds, so the new one is in the library: **⌘L** (Ctrl+L on Linux), type the name, click it.
     It plays on the amp's temporary place; no slot is overwritten. Marking it as a favorite keeps it in the sidebar.

## Values that matter most

- **Loudness.** Sounds in the owner's library are matched to about the same level (solo/lead a little louder). A
  Spark amp is nearly silent at gain 2 to 3. Clean: gain 4 to 5 and master 8 to 10 (RolandJC120, the quietest amp:
  gain 5 to 6, master 9 to 10). Crunch: master 3 to 5. High gain or a pedal into a crunch amp: master 1.5 to 3. The
  guide and `docs/STUDIO.md` (section Levels) have the numbers; they are estimates from one measurement.
- **Labels.** Choices take the catalog's English `label` or the German one under `de`; both are read.
- **Notes.** Recipe `notes` in the user's language: what to turn first, the guitar's side, approximations.

## What you cannot do from here

- You cannot play, select or activate a sound in AmpBench: there is no command for it, and `--library-select` only
  sets up snapshots. Do not send anything to the amp yourself; AmpBench paces model changes, because a quick series
  once made a Spark MINI hang. Tell the user the ⌘L way above instead.
- You cannot hear the result. Say so once, and give the knobs to try.

## REACTOR

Build and check the recipe the same way, then run `swift run AmpBench --recipe-prompt <file>` and give the user that
text to paste into the REACTOR app's Text to Tone. REACTOR cannot read recipe files; see the section Devices in the
guide.

## The AI Sound dialog in the app

AmpBench's own AI Sound (Presets area) asks Ollama Cloud with the prompt in
`Sources/SparkControl/Library/SoundAI.swift` and `SoundAIKnowledge.swift`; the Linux app has the same prompt in
`linux/ampbench/sound_ai.py`. When the user wants that changed, change both copies word for word and run
`swift test --filter SoundAI` and the Linux tests (`linux/tests/test_sound_ai.py`). A sound built here in Claude Code
does not go through that dialog.

## Rules

- Avoid models with `"pack": true` unless the user says the add-on is unlocked.
- A recipe holds a sound, never personal data. Data tier rule: only Tier 1 material (catalog, guide, sounds) belongs
  in recipes and prompts; real names of other people, recordings or other personal data stay out. A famous player
  the user names as a style is fine.
