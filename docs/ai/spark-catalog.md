# Spark model catalog

Written by `AmpBench --catalog-export docs/ai` from `Sources/SparkControl/Catalog`. Do not edit by hand.
The same data as JSON is in [spark-catalog.json](spark-catalog.json). How to build a sound from it is in
[SOUND-GUIDE.md](SOUND-GUIDE.md).

Checked on: Spark MINI, firmware 1.11.2.75 (every model marked checkedOnAmp accepted, start values read back); Spark NEO, firmware 1.16.1.60 (the 16 models of its factory presets; a model change to DistortionTS9 set the MINI's start values).
Knobs go from 0 to 10, like the editor. The amp stores them as 0 to 1. Values in brackets are the start values a Spark MINI sets.
Models marked *pack* need a paid add-on and are refused by an amp without it.
The texts are English; the JSON file also holds the German of the editor in its `de` objects.

## 1. Noise Gate (`gate`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `bias.noisegate` | Noise Gate | Cuts noise when you are not playing | – | `threshold` [2], `decay` [5] |

## 2. Compressor (`compressor`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `LA2AComp` | Studio Compressor | Optical studio compressor, soft | Teletronix LA-2A | `mode` Comp./Limit [Comp.], `gain` [7], `reduction` [7] |
| `BlueComp` | Sustainer | Compressor for long sustain | Boss CS-3 | `level` [4.9], `tone` [5.2], `attack` [4.9], `sustain` [6.4] |
| `Compressor` | Compressor | Simple, snappy compressor | MXR Dyna Comp | `level` [6.4], `sensitivity` [6.5] |
| `BassComp` | Bass Compressor | Compressor for bass | – | `compression` [3.7], `gain` [5.3] |
| `BBEOpticalComp` | Opto Compressor | Optical compressor, transparent | BBE Opto Stomp | `level` [6.5], `compression` [4], `pad` 0 dB/−15 dB [0 dB] |
| `JH.Vox846` | JH Wah *pack* | Wah with auto mode | Vox V846 | `shape` (1 · 2 · 3 · 4 · 5 · Auto), `sync` Free/BPM, `time`, `note` (1/8 · 1/4 · 1/2 · 1 bar), `sensitivity` |

## 3. Drive (`drive`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `Booster` | Booster | Clean volume boost | – | `gain` [7.7] |
| `KlonCentaurSilver` | Transparent Drive | Light, open drive | Klon Centaur | `level` [5], `treble` [5], `gain` [5] |
| `DistortionTS9` | Mid Drive | Mid-focused overdrive that pushes the amp | Ibanez TS9 | `drive` [5.7], `tone` [5], `level` [6.2] |
| `Overdrive` | Overdrive | Classic overdrive | – | `level` [5.9], `tone` [7], `drive` [5.3] |
| `Fuzz` | Germanium Fuzz | Round, old fuzz | Fuzz Face | `level` [4.4], `fuzz` [8.4] |
| `ProCoRat` | Filter Distortion | Hard distortion with a filter | ProCo RAT | `distortion` [7.1], `filter` [5], `level` [6.6] |
| `BassBigMuff` | Bass Sustain Fuzz | Thick fuzz for bass | Electro-Harmonix Bass Big Muff | `level` [3.3], `tone` [7.7], `sustain` [8.8] |
| `GuitarMuff` | Sustain Fuzz | Thick, singing fuzz | Electro-Harmonix Big Muff | `level` [5.1], `tone` [5], `sustain` [7.5] |
| `MaestroBassmaster` | Brass Bass | Bass fuzz with a brass character | Maestro Bass Brassmaster | `brass` [4], `sensitivity` [7.6], `bass` [2] |
| `SABdriver` | Amp-in-a-Box | Drive like a small amp | – | `level` [4], `tone` [4.5], `drive` [8], `filter` LP/HP [HP] |
| `JH.AxisFuzz` | JH Axis Fuzz *pack* | Fuzz of the late 60s | Roger Mayer Axis Fuzz | `level`, `drive` |
| `JH.SupaFuzz` | JH Super Fuzz *pack* | Wide fuzz with a filter | Univox Super-Fuzz | `level`, `filter` |
| `JH.Octavia` | JH Octave Fuzz *pack* | Fuzz with an octave above | Roger Mayer Octavia | `level`, `fuzz` |
| `JH.FuzzTone` | JH Fuzz Tone *pack* | Early, scratchy fuzz | Maestro Fuzz-Tone | `level`, `attack` |

## 4. Amp (`amp`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `RolandJC120` | Solid Clean (clean) | Solid-state clean, crystal clear and dry | Roland JC-120 | `gain` [7.1], `treble` [3.5], `middle` [3.3], `bass` [5.3], `master` [8.5] |
| `Twin` | US Clean (clean) | Big clean combo with lots of headroom | Fender Twin Reverb | `gain` [7], `treble` [3.7], `middle` [4.5], `bass` [5.5], `master` [8] |
| `ADClean` | Brit Clean (clean) | British clean channel, warm and round | Orange AD30, Clean | `gain` [6.8], `treble` [5.7], `middle` [5.3], `bass` [3.4], `master` [6.8] |
| `94MatchDCV2` | Boutique Clean (clean) | Class A clean with bite | Matchless DC-30 | `gain` [5], `treble` [3.5], `middle` [4.2], `bass` [4.4], `master` [7.1] |
| `ODS50CN` | Silk Clean (clean) | Silky clean tone that breaks up softly | Dumble ODS 50 | `gain` [7.1], `treble` [3.8], `middle` [5.3], `bass` [5.3], `master` [6] |
| `Bassman` | Tweed 4×10 (bright) | Tweed combo, crisp and open | Fender Bassman ’59 | `gain` [5.8], `treble` [6.6], `middle` [4.7], `bass` [3.6], `master` [7.2] |
| `AC Boost` | Brit Chime (bright) | Chiming class A tone | Vox AC30 Top Boost | `gain` [4.9], `treble` [4.7], `middle` [5], `bass` [5.9], `master` [6] |
| `Checkmate` | Vintage Combo (bright) | Small tube combo from the 60s | Teisco Checkmate 20 | `gain` [7.5], `treble` [5.2], `middle` [3.7], `bass` [5.1], `master` [4.4] |
| `TwoStoneSP50` | Studio Glass (bright) | Modern boutique tone, very clear | Two-Rock Studio Pro 50 | `gain` [5.8], `treble` [5.1], `middle` [6.1], `bass` [5], `master` [6.5] |
| `Deluxe65` | US Deluxe (crunch) | Small US combo that breaks up early | Fender Deluxe | `gain` [6.8], `treble` [4], `middle` [2], `bass` [5.8], `master` [7] |
| `Plexi` | Plexi Crunch (crunch) | Classic British rock crunch | Marshall Super Lead ’Plexi’ | `gain` [7.3], `treble` [4.3], `middle` [4.7], `bass` [5.9], `master` [3.4] |
| `OverDrivenJM45` | Brit 45 (crunch) | Early British tube crunch | Marshall JTM45 | `gain` [6.5], `treble` [6.6], `middle` [5.6], `bass` [3.2], `master` [5.4] |
| `OverDrivenLuxVerb` | US Crunch (crunch) | Cranked US combo | Fender Deluxe Reverb | `gain` [2.6], `treble` [2.3], `middle` [2.8], `bass` [3.8], `master` [8.3] |
| `BluesJrTweed` | Blues Combo (crunch) | Small blues combo, mid-focused | Fender Blues Junior | `gain` [6.6], `treble` [4.5], `middle` [5], `bass` [6], `master` [7.5] |
| `Bogner` | Boutique Lead (highGain) | Singing lead channel with depth | Bogner Ecstasy 101 | `gain` [6.6], `treble` [6], `middle` [5.5], `bass` [3.6], `master` [5.4] |
| `OrangeAD30` | Brit 30 Drive (highGain) | British drive channel, raw and thick | Orange AD30 | `gain` [6.8], `treble` [3.6], `middle` [4], `bass` [6], `master` [3.3] |
| `AmericanHighGain` | US Lead (highGain) | American high gain with punch | Mesa/Boogie | `gain` [6.2], `treble` [4.3], `middle` [5.6], `bass` [5], `master` [7.8] |
| `SLO100` | Super Lead (highGain) | Fluid, creamy lead | Soldano SLO-100 | `gain` [5.9], `treble` [3.8], `middle` [5.3], `bass` [4.5], `master` [4.9] |
| `YJM100` | Shred 100 (highGain) | British lead for fast lines | Marshall YJM100 | `gain` [6], `treble` [5], `middle` [3.8], `bass` [6.2], `master` [6.1] |
| `Rectifier` | Rectified (metal) | Deep, wide modern metal tone | Mesa/Boogie Rectifier | `gain` [6.7], `treble` [5.8], `middle` [5.6], `bass` [6], `master` [7.8] |
| `EVH` | Brown Lead (metal) | Hot, warm hard rock tone | EVH 5150 III | `gain` [5], `treble` [7], `middle` [6.3], `bass` [3.3], `master` [8.8] |
| `6505Plus` | Thrash Head (metal) | Aggressive metal channel | Peavey 6505+ | `gain` [6.6], `treble` [5], `middle` [4], `bass` [5], `master` [7] |
| `SwitchAxeLead` | Switch Lead (metal) | Mid-focused 80s lead | Hughes & Kettner Switchblade | `gain` [6], `treble` [5], `middle` [5.1], `bass` [6], `master` [6.6] |
| `Invader` | Rock Verb (metal) | British rock with full bass | Orange Rockerverb 50 | `gain` [6], `treble` [5.1], `middle` [3.9], `bass` [6.2], `master` [5.8] |
| `BE101` | Modern Brit (metal) | Modern British high gain, tight | Friedman BE-100 | `gain` [5.7], `treble` [5.6], `middle` [6.5], `bass` [4], `master` [8.2] |
| `Acoustic` | Pure Acoustic (acoustic) | Neutral acoustic sound | – | `gain` [6.4], `treble` [4.8], `middle` [5.1], `bass` [5.3], `master` [5.2] |
| `AcousticAmpV2` | Acoustic Combo (acoustic) | Acoustic amp with warmth | Fishman Loudbox | `gain` [4.1], `treble` [4.1], `middle` [1.4], `bass` [6.6], `master` [8.5] |
| `FatAcousticV2` | Full Acoustic (acoustic) | Full sound like a jumbo guitar | – | `gain` [5.3], `treble` [4.7], `middle` [4.8], `bass` [7.1], `master` [4.6] |
| `FlatAcoustic` | Flat Acoustic (acoustic) | Flat, unobtrusive acoustic sound | – | `gain` [6.7], `treble` [4.5], `middle` [5.6], `bass` [7.1], `master` [5.4] |
| `GK800` | Bass 800 (bass) | Solid-state bass, present and tight | Gallien-Krueger 800RB | `gain` [5.5], `treble` [4.2], `middle` [3.7], `bass` [6], `master` [8.9] |
| `Sunny3000` | Bass Vintage (bass) | 70s tube bass, fat | Sunn 300T | `gain` [5], `treble` [6], `middle` [4.2], `bass` [5.1], `master` [7.5] |
| `W600` | Bass Studio (bass) | Clean, modern bass | Eden WTP600 | `gain` [5], `treble` [3.7], `middle` [2.7], `bass` [6.3], `master` [8.7] |
| `Hammer500` | Bass Modern (bass) | Modern bass with punch | Aguilar Tone Hammer 500 | `gain` [5.4], `treble` [5.2], `middle` [2.9], `bass` [6.8], `master` [7.5] |
| `JH.JTM45` | JH 45/100 *pack* (crunch) | British tube crunch of the late 60s | Marshall JTM45/100 | `gain`, `treble`, `middle`, `bass`, `volume` |
| `JH.SuperLead100` | JH Super Lead *pack* (crunch) | British 100-watt rock | Marshall Super Lead 100 | `gain`, `treble`, `middle`, `bass`, `volume` |
| `JH.DualShowman` | JH Showman *pack* (crunch) | Big US clean with lots of headroom | Fender Dual Showman | `gain`, `treble`, `middle`, `bass`, `volume` |
| `JH.Sunn100` | JH 100S *pack* (crunch) | Loud US tube amp | Sunn 100S | `gain`, `treble`, `middle`, `bass`, `volume` |
| `JH.Bassman50Silver` | JH Bassman *pack* (crunch) | Silverface combo, open | Fender Bassman 50 | `gain`, `treble`, `middle`, `bass`, `volume` |
| `JH.SoundCity100` | JH City 100 *pack* (crunch) | British 100-watt amp, raw | Sound City One Hundred | `gain`, `treble`, `middle`, `bass`, `volume` |

## 5. Modulation (`modulation`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `Tremolo` | Tremolo | Volume pulses as in an old combo | – | `speed` [4.5], `depth` [7], `level` [6] |
| `ChorusAnalog` | Chorus | Shimmering, wide sound | – | `effect` [7.6], `rate` [2.8], `depth` [7.5], `tone` [5.7] |
| `Flanger` | Flanger | Jet-like whoosh | – | `rate` [4.1], `mix` [6.6], `depth` [6.5] |
| `Phaser` | Phaser | Swirling phases | MXR Phase 90 | `speed` [5.5], `intensity` [6.2] |
| `Vibrato01` | Vibrato | Pitch wavers slightly | – | `speed` [8.1], `depth` [5.3], `knob3` [5] |
| `UniVibe` | Rotary Vibe | Pulsing vibe of the late 60s | Shin-ei Uni-Vibe | `speed` [5], `mode` Vibrato/Chorus [Chorus], `intensity` [7] |
| `Cloner` | Clone Chorus | Simple, thick chorus | Electro-Harmonix Small Clone | `rate` [2.5], `depth` Low/High [High] |
| `MiniVibe` | Mini Vibe | Compact vibe | Voodoo Lab Micro Vibe | `speed` [3.1], `intensity` [2.6], `knob3` [6], `knob4` [5] |
| `Tremolator` | Sync Tremolo | Tremolo, in the preset's tempo if you like | – | `depth` [6.6], `speed` [5], `sync` Free/BPM [Free] |
| `TremoloSquare` | Square Tremolo | Hard, choppy tremolo | – | `speed` [1], `depth` [5], `level` [6], `knob4` [0] |
| `GuitarEQ6` | Guitar EQ | Graphic EQ with six bands | – | `level` [5], `hz100` [5], `hz200` [5], `hz400` [5], `hz800` [5], `hz1600` [5], `hz3200` [5] |
| `BassEQ6` | Bass EQ | Graphic EQ for bass with six bands | – | `level` [5], `hz50` [5], `hz120` [5], `hz400` [5], `hz800` [5], `hz4500` [5], `hz10000` [5] |
| `JH.VoodooVibeJr` | JH Vibe *pack* | Vibe with a chorus blend | Roger Mayer Voodoo-Vibe | `speed`, `sweep`, `intensity`, `mix` |

## 6. Delay (`delay`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `DelayMono` | Digital Delay | Clean digital echo | Boss DD-3 | `effect` [3.8], `feedback` [4], `time` [5.5], `range` (50 ms · 200 ms · 500 ms · 1 s) [500 ms], `sync` Free/BPM [BPM] |
| `DelayEchoFilt` | Filter Echo | Echo with a tone filter | – | `time` [5.5], `feedback` [4.6], `level` [7], `tone` [4.6], `sync` Free/BPM [BPM] |
| `VintageDelay` | Analog Delay | Warm, dark bucket-brigade echo | – | `time` [5.5], `intensity` [6.5], `echo` [7.1], `sync` Free/BPM [BPM] |
| `DelayReverse` | Reverse Delay | Echo that runs backwards | – | `mix` [7.3], `decay` [3.9], `filter` [6.8], `time` [5.7], `sync` Free/BPM [BPM] |
| `DelayMultiHead` | Multi Head | Tape echo with several heads | – | `time` [5.5], `intensity` [6.1], `echo` [5.4], `heads` (1 · 2 · 3 · 4) [3], `sync` Free/BPM [BPM] |
| `DelayRe201` | Tape Echo | Tape echo with wow and flutter | Roland RE-201 | `sustain` [7.2], `level` [6], `tone` [5], `time` [5.5], `sync` Free/BPM [BPM] |

## 7. Reverb (`reverb`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `bias.reverb` | Reverb | Room, chamber, hall or plate | – | `level` [3], `damping` [4], `lowCut` [4], `highCut` [5], `density` [4], `length` [5], `type` (Room A · Room B · Chamber · Natural hall · Medium hall · Wide hall · Short plate · Rich plate · Long plate) [Natural hall] |
