# Spark model catalog

Written by `SparkStudio --catalog-export docs/ai` from `Sources/SparkControl/Catalog`. Do not edit by hand.
The same data as JSON is in [spark-catalog.json](spark-catalog.json). How to build a sound from it is in
[SOUND-GUIDE.md](SOUND-GUIDE.md).

Checked on: Spark MINI, firmware 1.11.2.75 (every model marked checkedOnAmp accepted, start values read back); Spark NEO, firmware 1.16.1.60 (the 16 models of its factory presets; a model change to DistortionTS9 set the MINI's start values).
Knobs go from 0 to 10, like the editor. The amp stores them as 0 to 1. Values in brackets are the start values a Spark MINI sets.
Models marked *pack* need a paid add-on and are refused by an amp without it.

## 1. Noise Gate (`gate`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `bias.noisegate` | Noise Gate | Schneidet Rauschen in Spielpausen ab | – | `threshold` [2], `decay` [5] |

## 2. Kompressor (`compressor`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `LA2AComp` | Studio-Kompressor | Optischer Studio-Kompressor, weich | Teletronix LA-2A | `mode` Kompr./Limit [Kompr.], `gain` [7], `reduction` [7] |
| `BlueComp` | Sustainer | Kompressor für langes Sustain | Boss CS-3 | `level` [4.9], `tone` [5.2], `attack` [4.9], `sustain` [6.4] |
| `Compressor` | Kompressor | Einfacher, knackiger Kompressor | MXR Dyna Comp | `level` [6.4], `sensitivity` [6.5] |
| `BassComp` | Bass-Kompressor | Kompressor für Bass | – | `compression` [3.7], `gain` [5.3] |
| `BBEOpticalComp` | Opto-Kompressor | Optischer Kompressor, transparent | BBE Opto Stomp | `level` [6.5], `compression` [4], `pad` 0 dB/−15 dB [0 dB] |
| `JH.Vox846` | JH Wah *pack* | Wah mit Auto-Modus | Vox V846 | `shape` (1 · 2 · 3 · 4 · 5 · Auto), `sync` Frei/BPM, `time`, `note` (1/8 · 1/4 · 1/2 · 1 Takt), `sensitivity` |

## 3. Verzerrer (`drive`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `Booster` | Booster | Sauberer Lautstärke-Schub | – | `gain` [7.7] |
| `KlonCentaurSilver` | Transparent Drive | Leichte, offene Verzerrung | Klon Centaur | `level` [5], `treble` [5], `gain` [5] |
| `DistortionTS9` | Mid Drive | Mittiger Overdrive, der den Amp anschiebt | Ibanez TS9 | `drive` [5.7], `tone` [5], `level` [6.2] |
| `Overdrive` | Overdrive | Klassischer Overdrive | – | `level` [5.9], `tone` [7], `drive` [5.3] |
| `Fuzz` | Germanium Fuzz | Runder, alter Fuzz | Fuzz Face | `level` [4.4], `fuzz` [8.4] |
| `ProCoRat` | Filter Distortion | Harte Verzerrung mit Filter | ProCo RAT | `distortion` [7.1], `filter` [5], `level` [6.6] |
| `BassBigMuff` | Bass Sustain Fuzz | Dichter Fuzz für Bass | Electro-Harmonix Bass Big Muff | `level` [3.3], `tone` [7.7], `sustain` [8.8] |
| `GuitarMuff` | Sustain Fuzz | Dichter, singender Fuzz | Electro-Harmonix Big Muff | `level` [5.1], `tone` [5], `sustain` [7.5] |
| `MaestroBassmaster` | Brass Bass | Bass-Fuzz mit Bläser-Charakter | Maestro Bass Brassmaster | `brass` [4], `sensitivity` [7.6], `bass` [2] |
| `SABdriver` | Amp-in-a-Box | Verzerrer wie ein kleiner Amp | – | `level` [4], `tone` [4.5], `drive` [8], `filter` LP/HP [HP] |
| `JH.AxisFuzz` | JH Axis Fuzz *pack* | Fuzz der späten 60er | Roger Mayer Axis Fuzz | `level`, `drive` |
| `JH.SupaFuzz` | JH Super Fuzz *pack* | Breiter Fuzz mit Filter | Univox Super-Fuzz | `level`, `filter` |
| `JH.Octavia` | JH Octave Fuzz *pack* | Fuzz mit Oktave darüber | Roger Mayer Octavia | `level`, `fuzz` |
| `JH.FuzzTone` | JH Fuzz Tone *pack* | Früher, kratziger Fuzz | Maestro Fuzz-Tone | `level`, `attack` |

## 4. Amp (`amp`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `RolandJC120` | Solid Clean (clean) | Transistor-Clean, glasklar und trocken | Roland JC-120 | `gain` [7.1], `treble` [3.5], `middle` [3.3], `bass` [5.3], `master` [8.5] |
| `Twin` | US Clean (clean) | Großer Clean-Combo mit viel Headroom | Fender Twin Reverb | `gain` [7], `treble` [3.7], `middle` [4.5], `bass` [5.5], `master` [8] |
| `ADClean` | Brit Clean (clean) | Britischer Clean-Kanal, warm und rund | Orange AD30, Clean | `gain` [6.8], `treble` [5.7], `middle` [5.3], `bass` [3.4], `master` [6.8] |
| `94MatchDCV2` | Boutique Clean (clean) | Class-A-Clean mit Biss | Matchless DC-30 | `gain` [5], `treble` [3.5], `middle` [4.2], `bass` [4.4], `master` [7.1] |
| `ODS50CN` | Silk Clean (clean) | Seidiger Clean-Ton, der weich anzerrt | Dumble ODS 50 | `gain` [7.1], `treble` [3.8], `middle` [5.3], `bass` [5.3], `master` [6] |
| `Bassman` | Tweed 4×10 (bright) | Tweed-Combo, knackig und offen | Fender Bassman ’59 | `gain` [5.8], `treble` [6.6], `middle` [4.7], `bass` [3.6], `master` [7.2] |
| `AC Boost` | Brit Chime (bright) | Glockiger Class-A-Ton | Vox AC30 Top Boost | `gain` [4.9], `treble` [4.7], `middle` [5], `bass` [5.9], `master` [6] |
| `Checkmate` | Vintage Combo (bright) | Kleiner Röhren-Combo aus den 60ern | Teisco Checkmate 20 | `gain` [7.5], `treble` [5.2], `middle` [3.7], `bass` [5.1], `master` [4.4] |
| `TwoStoneSP50` | Studio Glass (bright) | Moderner Boutique-Ton, sehr klar | Two-Rock Studio Pro 50 | `gain` [5.8], `treble` [5.1], `middle` [6.1], `bass` [5], `master` [6.5] |
| `Deluxe65` | US Deluxe (crunch) | Kleiner US-Combo, der früh bricht | Fender Deluxe | `gain` [6.8], `treble` [4], `middle` [2], `bass` [5.8], `master` [7] |
| `Plexi` | Plexi Crunch (crunch) | Klassischer britischer Rock-Crunch | Marshall Super Lead ’Plexi’ | `gain` [7.3], `treble` [4.3], `middle` [4.7], `bass` [5.9], `master` [3.4] |
| `OverDrivenJM45` | Brit 45 (crunch) | Früher britischer Röhren-Crunch | Marshall JTM45 | `gain` [6.5], `treble` [6.6], `middle` [5.6], `bass` [3.2], `master` [5.4] |
| `OverDrivenLuxVerb` | US Crunch (crunch) | Aufgerissener US-Combo | Fender Deluxe Reverb | `gain` [2.6], `treble` [2.3], `middle` [2.8], `bass` [3.8], `master` [8.3] |
| `BluesJrTweed` | Blues Combo (crunch) | Kleiner Blues-Combo, mittig | Fender Blues Junior | `gain` [6.6], `treble` [4.5], `middle` [5], `bass` [6], `master` [7.5] |
| `Bogner` | Boutique Lead (highGain) | Singender Lead-Kanal mit Tiefe | Bogner Ecstasy 101 | `gain` [6.6], `treble` [6], `middle` [5.5], `bass` [3.6], `master` [5.4] |
| `OrangeAD30` | Brit 30 Drive (highGain) | Britischer Zerrkanal, rau und dicht | Orange AD30 | `gain` [6.8], `treble` [3.6], `middle` [4], `bass` [6], `master` [3.3] |
| `AmericanHighGain` | US Lead (highGain) | Amerikanischer High Gain mit Druck | Mesa/Boogie | `gain` [6.2], `treble` [4.3], `middle` [5.6], `bass` [5], `master` [7.8] |
| `SLO100` | Super Lead (highGain) | Flüssiger, cremiger Lead | Soldano SLO-100 | `gain` [5.9], `treble` [3.8], `middle` [5.3], `bass` [4.5], `master` [4.9] |
| `YJM100` | Shred 100 (highGain) | Britischer Lead für schnelle Linien | Marshall YJM100 | `gain` [6], `treble` [5], `middle` [3.8], `bass` [6.2], `master` [6.1] |
| `Rectifier` | Rectified (metal) | Tiefer, breiter Modern-Metal-Ton | Mesa/Boogie Rectifier | `gain` [6.7], `treble` [5.8], `middle` [5.6], `bass` [6], `master` [7.8] |
| `EVH` | Brown Lead (metal) | Heißer, warmer Hard-Rock-Ton | EVH 5150 III | `gain` [5], `treble` [7], `middle` [6.3], `bass` [3.3], `master` [8.8] |
| `6505Plus` | Thrash Head (metal) | Aggressiver Metal-Kanal | Peavey 6505+ | `gain` [6.6], `treble` [5], `middle` [4], `bass` [5], `master` [7] |
| `SwitchAxeLead` | Switch Lead (metal) | Mittiger 80er-Lead | Hughes & Kettner Switchblade | `gain` [6], `treble` [5], `middle` [5.1], `bass` [6], `master` [6.6] |
| `Invader` | Rock Verb (metal) | Britischer Rock mit vollen Bässen | Orange Rockerverb 50 | `gain` [6], `treble` [5.1], `middle` [3.9], `bass` [6.2], `master` [5.8] |
| `BE101` | Modern Brit (metal) | Moderner britischer High Gain, straff | Friedman BE-100 | `gain` [5.7], `treble` [5.6], `middle` [6.5], `bass` [4], `master` [8.2] |
| `Acoustic` | Akustik pur (acoustic) | Neutraler Akustik-Klang | – | `gain` [6.4], `treble` [4.8], `middle` [5.1], `bass` [5.3], `master` [5.2] |
| `AcousticAmpV2` | Akustik-Combo (acoustic) | Akustik-Verstärker mit Wärme | Fishman Loudbox | `gain` [4.1], `treble` [4.1], `middle` [1.4], `bass` [6.6], `master` [8.5] |
| `FatAcousticV2` | Akustik voll (acoustic) | Voller Klang wie eine Jumbo-Gitarre | – | `gain` [5.3], `treble` [4.7], `middle` [4.8], `bass` [7.1], `master` [4.6] |
| `FlatAcoustic` | Akustik flach (acoustic) | Flacher, unauffälliger Akustik-Klang | – | `gain` [6.7], `treble` [4.5], `middle` [5.6], `bass` [7.1], `master` [5.4] |
| `GK800` | Bass 800 (bass) | Transistor-Bass, präsent und straff | Gallien-Krueger 800RB | `gain` [5.5], `treble` [4.2], `middle` [3.7], `bass` [6], `master` [8.9] |
| `Sunny3000` | Bass Vintage (bass) | Röhren-Bass der 70er, fett | Sunn 300T | `gain` [5], `treble` [6], `middle` [4.2], `bass` [5.1], `master` [7.5] |
| `W600` | Bass Studio (bass) | Sauberer, moderner Bass | Eden WTP600 | `gain` [5], `treble` [3.7], `middle` [2.7], `bass` [6.3], `master` [8.7] |
| `Hammer500` | Bass Modern (bass) | Moderner Bass mit Punch | Aguilar Tone Hammer 500 | `gain` [5.4], `treble` [5.2], `middle` [2.9], `bass` [6.8], `master` [7.5] |
| `JH.JTM45` | JH 45/100 *pack* (crunch) | Britischer Röhren-Crunch der späten 60er | Marshall JTM45/100 | `gain`, `treble`, `middle`, `bass`, `volume` |
| `JH.SuperLead100` | JH Super Lead *pack* (crunch) | Britischer 100-Watt-Rock | Marshall Super Lead 100 | `gain`, `treble`, `middle`, `bass`, `volume` |
| `JH.DualShowman` | JH Showman *pack* (crunch) | Großer US-Clean mit viel Headroom | Fender Dual Showman | `gain`, `treble`, `middle`, `bass`, `volume` |
| `JH.Sunn100` | JH 100S *pack* (crunch) | Lauter US-Röhren-Amp | Sunn 100S | `gain`, `treble`, `middle`, `bass`, `volume` |
| `JH.Bassman50Silver` | JH Bassman *pack* (crunch) | Silverface-Combo, offen | Fender Bassman 50 | `gain`, `treble`, `middle`, `bass`, `volume` |
| `JH.SoundCity100` | JH City 100 *pack* (crunch) | Britischer 100-Watt-Amp, rau | Sound City One Hundred | `gain`, `treble`, `middle`, `bass`, `volume` |

## 5. Modulation (`modulation`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `Tremolo` | Tremolo | Lautstärke pulsiert wie im alten Combo | – | `speed` [4.5], `depth` [7], `level` [6] |
| `ChorusAnalog` | Chorus | Schwebender, breiter Klang | – | `effect` [7.6], `rate` [2.8], `depth` [7.5], `tone` [5.7] |
| `Flanger` | Flanger | Düsenartiges Rauschen | – | `rate` [4.1], `mix` [6.6], `depth` [6.5] |
| `Phaser` | Phaser | Kreisende Phasen | MXR Phase 90 | `speed` [5.5], `intensity` [6.2] |
| `Vibrato01` | Vibrato | Tonhöhe schwankt leicht | – | `speed` [8.1], `depth` [5.3], `knob3` [5] |
| `UniVibe` | Rotary Vibe | Pulsierender Vibe der späten 60er | Shin-ei Uni-Vibe | `speed` [5], `mode` Vibrato/Chorus [Chorus], `intensity` [7] |
| `Cloner` | Clone Chorus | Einfacher, dichter Chorus | Electro-Harmonix Small Clone | `rate` [2.5], `depth` Wenig/Viel [Viel] |
| `MiniVibe` | Mini Vibe | Kompakter Vibe | Voodoo Lab Micro Vibe | `speed` [3.1], `intensity` [2.6], `knob3` [6], `knob4` [5] |
| `Tremolator` | Sync Tremolo | Tremolo, auf Wunsch im Tempo des Presets | – | `depth` [6.6], `speed` [5], `sync` Frei/BPM [Frei] |
| `TremoloSquare` | Square Tremolo | Hartes, zerhacktes Tremolo | – | `speed` [1], `depth` [5], `level` [6], `knob4` [0] |
| `GuitarEQ6` | Gitarren-EQ | Grafischer EQ mit sechs Bändern | – | `level` [5], `hz100` [5], `hz200` [5], `hz400` [5], `hz800` [5], `hz1600` [5], `hz3200` [5] |
| `BassEQ6` | Bass-EQ | Grafischer EQ für Bass mit sechs Bändern | – | `level` [5], `hz50` [5], `hz120` [5], `hz400` [5], `hz800` [5], `hz4500` [5], `hz10000` [5] |
| `JH.VoodooVibeJr` | JH Vibe *pack* | Vibe mit Chorus-Mischung | Roger Mayer Voodoo-Vibe | `speed`, `sweep`, `intensity`, `mix` |

## 6. Delay (`delay`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `DelayMono` | Digital Delay | Sauberes digitales Echo | Boss DD-3 | `effect` [3.8], `feedback` [4], `time` [5.5], `range` (50 ms · 200 ms · 500 ms · 1 s) [500 ms], `sync` Frei/BPM [BPM] |
| `DelayEchoFilt` | Filter Echo | Echo mit Klangfilter | – | `time` [5.5], `feedback` [4.6], `level` [7], `tone` [4.6], `sync` Frei/BPM [BPM] |
| `VintageDelay` | Analog Delay | Warmes, dunkles Eimerketten-Echo | – | `time` [5.5], `intensity` [6.5], `echo` [7.1], `sync` Frei/BPM [BPM] |
| `DelayReverse` | Reverse Delay | Rückwärts laufendes Echo | – | `mix` [7.3], `decay` [3.9], `filter` [6.8], `time` [5.7], `sync` Frei/BPM [BPM] |
| `DelayMultiHead` | Multi Head | Bandecho mit mehreren Köpfen | – | `time` [5.5], `intensity` [6.1], `echo` [5.4], `heads` (1 · 2 · 3 · 4) [3], `sync` Frei/BPM [BPM] |
| `DelayRe201` | Tape Echo | Bandecho mit Leiern | Roland RE-201 | `sustain` [7.2], `level` [6], `tone` [5], `time` [5.5], `sync` Frei/BPM [BPM] |

## 7. Hall (`reverb`)

| Model id | Name | Character | Modeled after | Parameters |
|---|---|---|---|---|
| `bias.reverb` | Hall | Raum, Kammer, Saal oder Platte | – | `level` [3], `damping` [4], `lowCut` [4], `highCut` [5], `density` [4], `length` [5], `type` (Raum A · Raum B · Kammer · Saal natürlich · Saal mittel · Saal weit · Platte kurz · Platte satt · Platte lang) [Saal natürlich] |
