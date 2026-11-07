# Spark Studio – the design language

Spark Recorder and Spark Presets share one look. This document is the only place where design decisions are written
down. The values live in code once, in `Sources/SparkDesign/Theme.swift`; both apps use the building blocks of
`Sources/SparkDesign` and draw nothing of their own that one of these blocks already draws.

> **The rule:** new views use the building blocks of SparkDesign. A new color or a new button style goes into
> SparkDesign and this document first, then into the app.

## Three principles

1. **The instrument stays dark.** The deck, the waveform's transport, pedals, amp, the control field and every display
   are hardware. They look the same in light and dark mode, like a real device on a light or a dark desk, and never
   use system colors.
2. **The desk follows the system.** Library, lists, fields, sidebar, sheets and menus are macOS: system font, system
   colors, system spacing, system controls. The one exception is the selection in lists: an amber tint with a 3 pt
   amber bar on the left, instead of the system's blue.
3. **Keys instead of buttons, lamps instead of icons.** Every action on the device is a hardware key with its shortcut
   engraved as a keycap. Every state is a lamp with a word beside it, never color alone. Amber is the only signal
   color. Red belongs to recording only (the record key, the REC lamp) and, as text color, to "Verwerfen". There is
   never a red key.

## Values

`Theme.device` (fixed) and `Theme.desk` (light / dark). Every value below is a `Swatch` or `DeskSwatch`, which is a
SwiftUI `ShapeStyle`, so `.fill(Theme.device.amber)` and `.foregroundStyle(Theme.desk.wave)` work directly; `.color`
gives a `Color` where one is needed, such as in a `Canvas`.

### Device, the same in light and dark

| Use | Value |
| --- | --- |
| Front | gradient `#27272B` → `#18181B`, edge `#060607`, light edge on top `rgba(255,255,255,.07)` |
| Engraved line between modules | 1 pt `#000` with 1 pt `rgba(255,255,255,.05)` beside it |
| Board under the pedals | `#0F0F12`; raised panels `#2A2A2F` → `#19191C` |
| Display | `#0C0B09`, edge `#2A2824`, inner shadow, radius 10 (7 for small ones) |
| Text on a display | amber `#F7C45C`, dim `#A8906A`, hot `#FFA02E` (changed, playing slot, loop on) |
| Text on the front | `#E8E8EA`, dim `#B2B2B8`, engraving `#96969E` |
| Recording | `#E4332A`; as text `#FF5A50` |
| Listening, Retro | `#F99A22` |
| Connected, on, live | `#4BD36A` |
| Lamp off | dot `#3A3028`, word `#9E9186` |
| Level meter | green `#3FBF5A` up to −18 dB, amber `#F2B233` up to −6 dB, red `#E4332A` above, off `#2A2824`; segments 6 pt with 2 pt gaps |
| Key | `#333338` → `#28282C`, edge `#0E0E10`, light edge on top, height 28 (small 24), radius 6, text 12 semibold `#E8E8EA` |
| Main key | `#FFD36F` → `#EFB64A`, text `#1A1206` |
| Switched-on key | `#F0A93A` → `#D98F22`, text `#1A1206` |
| Danger key | a normal key with text `#FF8A80` |
| Keycap | SF Mono 9.5 bold `#96969E` on `rgba(0,0,0,.35)`, radius 4; on amber keys `#2E2004` on `rgba(0,0,0,.12)` |
| Knob | body radial `#3A3A40` → `#1B1B1F`, amber pointer, ring in the accent color from 225° over 270° |
| Pedal | body `#2A2A2F` → `#141417` for every pedal, nameplate 22 pt in the place's color with `#111` capitals |
| Field on the front | `#111113`, edge `#0A0A0C`, text `#D6D6DA` |
| Switch | off `#3A3A40`, on `#D98F22`, thumb `#C9C9CE` |

### Desk, light / dark

| Use | Light | Dark |
| --- | --- | --- |
| Wave | `#1F6F7E` | `#68C6D6` |
| Wave background | `#F7F7F8` | `#121214` |
| Loop area | `rgba(247,196,92,.14)` with edge `#E6A23C` and handles A and B | same |
| Marker | `#B23B8F` | `#E58CD9` |
| Bar lines / beat lines | black 50 % / 18 % | white 50 % / 18 % |
| Playhead | `#1D1D1F` | `#FFFFFF` |
| Selected row | `rgba(230,162,60,.18)`, bar `#E6A23C` | `rgba(247,196,92,.14)`, bar `#F7C45C` |
| Stars | `#F2B233` | `#F2B233` |
| Pill "Offen" | text `#7E5508` | text `#F7C45C` |
| Pill "Geändert" | text `#17652B` | text `#4BD36A` |
| Pill "Sicherung" | system secondary | system secondary |
| Chart bars / today | `#1F6F7E` / `#B7790F` | `#68C6D6` / `#F2B233` |

The seven chain colors of `ChainPlace.accent` stay, but only as the nameplate of a pedal, its lamp, the pointer of a
mini knob, the ring of a knob and the stripe on top of the control field. Pedal bodies are all the same dark.

### Type, grid, radii

- **Titles and preset names:** SF Pro Display 23–34 bold (`Theme.Fonts.title`).
- **Lists and fields:** SF Pro Text 13, the system's.
- **Numbers:** SF Mono for time, BPM, values, dates and durations, always with even digits (`Theme.Fonts.mono`).
- **Engraving:** 9.5–10 bold capitals with 0.09 em letter spacing (`PanelLabel`).
- **Grid** 4 pt. **Radii** 6 key, 10 display and field, 14 device and panel.
- System fonts only. No web fonts, nothing is downloaded.

## Building blocks

All in `Sources/SparkDesign`, each with a `#Preview` in light and dark and usable with VoiceOver.

| Block | What it is | Example |
| --- | --- | --- |
| `Theme` | all values | `Theme.device.amber`, `Theme.desk.wave`, `Theme.Fonts.mono(11)` |
| `PanelLabel` | engraving on a front | `PanelLabel("Pegel")` |
| `DeskCaption` | caption above a field on the desk | `DeskCaption("Notiz")` |
| `Lamp`, `LampDot` | a state with its word | `Lamp("Live", tone: .on, isOn: isHeard)` |
| `Display`, `DisplayGlass` | the amber display | `Display(isAlert: isRecording) { … }` |
| `HardwareKeyStyle` | the one button style on a device | `.buttonStyle(.hardwareKey(.primary, keycap: "K"))` |
| `Keycap`, `KeyBody` | the engraved shortcut, the body of a key | `Keycap("⌘Z")` |
| `RecordKey` | the round record key with count-in digit | `RecordKey(state: .countIn(2), action: toggle)` |
| `LEDMeter`, `LEDSegments` | level meter with scale, and the bare segment row | `LEDMeter(level: level, hold: peak)` |
| `Knob`, `KnobFace`, `MiniKnob` | rotary control with ring, name and value | `Knob(name: "Gain", value: v, accent: c, display: f, onChange: set)` |
| `DevicePopup` | a choice on a front: dark field, chevron, a real menu inside | `DevicePopup("Taktart", selection: $beats, options: …)` |
| `DeviceToggle`, `LeverSwitch` | on/off on a front | `DeviceToggle("Retro", isOn: $retro)` |
| `DeviceSlider` | a fader with amber fill | `DeviceSlider("Tempo", value: $tempo, in: 0.5...1.5, step: 0.05, valueText: …)` |
| `DisplayStepper` | a number in a small display with arrows | `DisplayStepper("Tempo", value: $bpm, in: 40...240, step: 1, text: "120", unit: "BPM")` |
| `Faceplate`, `FaceplateModule`, `EngravedDivider` | a front with modules and engraved lines | `Faceplate { HStack { a; EngravedDivider(); b } }` |
| `SegmentTabs` | tabs on the desk | `SegmentTabs("Ansicht", selection: $tab, options: …)` |
| `Pill` | a state in a list | `Pill("Offen")` |
| `PedalShell`, `Nameplate`, `AmpHeadShell`, `BrassPanel`, `Tolex`, `Grille`, `Footswitch`, `CableRail` | pedals and amp | `PedalShell(nameplate: "Drive", accent: c) { … }` |
| `.amberSelection()` | amber selection for a `List` or `Table` | `Table(…).amberSelection()` |
| `ScrollRouter` | hands the scroll wheel to the hovered control | used by `Knob`, `DeviceSlider`, `DisplayStepper` |

App-specific glue stays in the apps and only maps their data onto these blocks, such as
`Sources/SparkPresets/Design/ChainColors.swift` (chain colors as swatches) and `LoadMeter.swift` (the transfer meter,
a variant of `LEDSegments`).

## Spark Recorder

- **Deck:** one front with four engraved modules. AUFNAHME: the record key (84 pt) and a display with state, lamp,
  "R · AUFNAHME", the time (34 mono), and below it bar and beat or a hint, with the device name when there is room.
  PEGEL: lamps ÜBERSTEUERT (click resets) and KEIN SIGNAL, the LED meter with scale, source and file, and the key
  "Eingang prüfen". SPARK: one lamp for the connection, input and output as `DevicePopup`, Retro as `DeviceToggle`
  with the buffer length or the key "Das eben war gut". KLICK: beat dots and the lamp "AN · N" (a click switches it),
  BPM in a `DisplayStepper`, the time signature, Tap, the count-in and "⋯" for the details.
- **Recording:** the key glows and shows a stop square or the count-in beat, the display gets a red edge, the state
  turns red, the time white, and the lamp pulses unless "Reduce motion" is on.
- **Waveform:** a ruler on top with bar numbers, or seconds for takes without bars, the same above the comparison
  and above a recording in progress. Loop area with handles A and B, markers with their names.
- **Transport:** keys with keycaps, the time in amber, an engraved line, TEMPO as `DeviceSlider`, TON as
  `DisplayStepper`, and for an open take Behalten (main key), Verwerfen (red text), Nochmal. The bar controls of a take
  with bars are a second row on the same front.
- **Library:** `SegmentTabs`, the piece for new recordings and the search in one header; mono dates and durations,
  amber stars, "Offen" as a pill, amber selection; a status line with recordings, open takes, practice time of the
  last 30 days and "⌘/ Tastenkürzel". The inspector has `SegmentTabs`, system fields with `DeskCaption`, a two-column
  grid of facts and keys at the bottom. Statistics: bars in the wave color, today in amber.
- **Sheets:** the shortcut and measuring sheets carry their title engraved on a front strip; their text stays system
  text. The shortcut list shows each key as a keycap.
- The connection warnings that used to be extra lines ("Spark ohne Eingang", "Ausgabe bei Aufnahme gesperrt") are now
  the SPARK lamp ("Ohne Eingang", "Ausgabe gesperrt", amber) with the full explanation as tooltip and for VoiceOver,
  because the module has room for exactly three rows. The count-in choice has no engraving beside it, its values name
  themselves ("Kein Einzähler", "1 Takt einzählen").

## Where the apps differ from the canvas, and why

The canvas "Spark Apps Design" is intent, not a pixel specification. These differences are deliberate:

- **Contrast.** A few canvas colors are below 4.5 : 1 where they are used, so they were moved just enough to pass:
  engraving `#8E8E96` → `#96969E` (4.4 on a pedal), lamp-off word `#6B6058` → `#9E9186` (2.9), red text
  `#E4332A` → `#FF5A50` (4.0), keycap on amber `#5B4210` → `#2E2004` (3.0 on a switched-on key), amp group
  `#8A7554` → `#9A8462`, pill text in light mode `#D9A23B` → `#7E5508` (2.3 on white). `Tests/SparkDesignTests`
  checks every pair and fails below 4.5.
- **Playhead.** The canvas draws it white in both appearances; on the light wave background it would vanish, so it is
  `#1D1D1F` in light mode.
- **Keycaps show real shortcuts only.** The canvas shows "Eingang prüfen ⇧R" and "Exportieren ⌘E". `⇧R` is the record
  key (shift is ignored) and `⌘E` renames in both apps, so these keys carry no keycap. Shortcuts were not changed.
- **List selection** needs AppKit: SwiftUI cannot recolor the selection of a `List` or `Table` on macOS, so
  `.amberSelection()` turns the table's own highlight off and draws the amber tint and bar beneath the rows.
- **Window pictures** (`WindowPicture`, used by both apps' snapshot modes) are drawn with `cacheDisplay`, which
  leaves the window background transparent, so it is painted first. Translucent materials, such as the sidebar's,
  are missing from these pictures, not from the app.
