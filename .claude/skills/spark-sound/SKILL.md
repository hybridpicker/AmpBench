---
name: spark-sound
description: Build or change a guitar sound for the Positive Grid Spark amp as a sound recipe that AmpBench reads, or describe one as text for REACTOR's Text to Tone. Use when the user asks for a sound, tone, preset or amp setting ("build me a blues sound", "make the preset warmer", "a sound like song X"; also in German: "bau mir einen Blues-Sound", "mach das Preset wärmer"), or wants to adjust a saved preset.
---

# Spark sound recipes

1. Read `docs/ai/SOUND-GUIDE.md` and use `docs/ai/spark-catalog.json` for model ids and parameter keys. Never guess
   an id or a key; spelling and case matter.
2. To change an existing sound, export it first:
   `swift run AmpBench --recipe-from "$HOME/Music/AmpBench/Presets/<name>.json"`.
   To build a new one, start from the closest file in `docs/ai/examples/`.
3. Write the recipe to a scratch file and check it with `swift run AmpBench --recipe-check <file>`. Fix every
   error. Read the warnings and resolve them unless they are intended.
4. Only when the check passes, copy it to `~/Music/AmpBench/Presets/<name>.json`. Never overwrite an existing file
   there without asking; pick a new name instead. AmpBench picks it up when its window comes to the front.
5. Tell the user, in their language, which amp and effects you chose and why, and which one or two knobs to turn first
   by ear. You cannot hear the result.

For REACTOR: build and check the recipe the same way, then run
`swift run AmpBench --recipe-prompt <file>` and give the user that text to paste into the REACTOR app's Text to
Tone. REACTOR cannot read recipe files; see the section Devices in the guide.

Rules:
- Avoid models with `"pack": true` unless the user says the add-on is unlocked.
- Do not send anything to the amp yourself. The user plays the recipe from AmpBench, where model changes are paced.
- A recipe holds a sound, never personal data. Data tier rule: only Tier 1 material (catalog, guide, sounds) belongs
  in recipes and prompts; real names of other people, recordings or other personal data stay out.
