# Spark Studio

Spark Recorder und Spark Presets werden eine App: ein Prozess, ein Icon, ein Fenster mit festem Deck oben und zwei
Bereichen darunter (Aufnahme, Presets). Jeder Take kennt sein Preset, BPM gibt es nur einmal, Stück und Song werden
eins. Der Weg dorthin steht in docs/spark-studio-prompt.md (Stufen 0–3). Dieses Dokument hält fest, was entschieden
ist, und wird mit jeder Stufe fortgeschrieben. Am Ende ersetzt es den Prompt und docs/spark-presets-next-prompt.md.

## Stand

| Stufe | Inhalt | Stand |
|---|---|---|
| 0 | Datenmodell, Tastaturmodell, Layout, dieses Dokument | fertig, nur Code ohne Verhalten |
| 1 | Ein Bundle, zwei Fenster | wartet auf den Design-Meilenstein 1 (Target `SparkDesign` committet) |
| 2 | Ein Fenster, zwei Bereiche | offen |
| 3 | Stücke = Songs, gemeinsamer Ordner, alte Apps entfernen | offen |

Am Gerät ist für Studio noch nichts geprüft. Stufe 0 ändert kein Verhalten der beiden Apps.

## Architektur (Ziel)

```
SparkStudio (executable, eigene Info.plist: Mikrofon + Bluetooth)
  ├── SparkRecorderUI   (library: RecorderScreen = Deck, Welle, Bibliothek; KeyRouter)  ← aus Sources/SparkRecorder
  ├── SparkPresetsUI    (library: PresetsScreen = Seitenleiste, Editor; SparkLink)      ← aus Sources/SparkPresets
  ├── SparkDesign       (Bausteine, docs/DESIGN.md)
  ├── SparkCore         (Aufnahme, Bibliothek, PresetStamp, StudioKeymap)
  └── SparkControl      (Protokoll, Katalog, Preset-Bibliothek, Fingerabdruck)
```

- Ein AppDelegate nach Recorder-Vorbild baut die Fenster selbst (die SwiftUI-Szene öffnete nicht zuverlässig). Davon
  hängen Dock-REC und „Aufnahme läuft weiter, wenn das Fenster zu ist“ ab. Bis Stufe 3 bleiben SparkRecorder und
  SparkPresets als dünne Hüllen um dieselben Bibliotheken bestehen.
- Bluetooth verbindet nicht beim Start, sondern beim ersten Öffnen des Bereichs Presets oder mit „Verbinden“ im Deck,
  und trennt auf Wunsch wieder, damit die Spark-App am Handy benutzbar bleibt (der Amp nimmt nur eine
  Steuerverbindung). Ein Bluetooth-Fehler wird gemeldet und beendet nie eine laufende Aufnahme.

## Datenmodell (Stufe 0, in Code)

Alles additiv: fehlende Felder bekommen Standardwerte, `LibraryDocument.currentSchema` bleibt 1, alte Bibliotheken
und Presets laden unverändert (Tests: `PresetStampTests`, `PresetFingerprintTests`).

- `Recording.preset: PresetStamp?` (SparkCore/PresetStamp.swift): `slot` (1–4, nil = Mac oder vorübergehender Platz),
  `name`, `stampedAt`, `sha256`.
- Schnappschuss des Sounds: `<Bibliothek>/.presets/<Take-UUID>.json`, geschrieben mit
  `LibraryStore.writePresetSnapshot(_:for:)`. Inhalt ist eine gewöhnliche Preset-Datei (`PresetFile`, Format 2) aus
  `PresetFile.snapshotData(for:origin:)`, sodass „Im Editor öffnen“ und Übernehmen in die Bibliothek einfach die
  normale Leselogik benutzen.
  - **Abweichung vom Prompt:** benannt nach der Take-UUID statt nach dem Dateinamen, wie `.wellenformen/<id>.peaks`.
    Ein Umbenennen im Finder oder in der App lässt den Schnappschuss so am Take.
  - Der Ordner ist versteckt, `scan()` übersieht ihn. Verwerfen und Wiederherstellen behalten die UUID, der
    Schnappschuss bleibt liegen und gilt wieder. Nichts wird gelöscht.
- Fingerabdruck `SparkPreset.sha256Hex()` (SparkControl/Library/PresetFingerprint.swift): SHA-256 über das
  kanonische JSON (sortierte Schlüssel) **nur der Effektkette**: Modelle, an/aus, alle Werte mit Marker.
  - **Abweichung vom Prompt** („SHA-256 des Preset-JSON“): Name, Beschreibung, BPM, uuid und Trailer zählen nicht.
    Der Amp schickt einen Platz mit längerem Trailer als das gerade spielende Preset; über das ganze JSON hätte
    derselbe Sound je nach Herkunft zwei Fingerabdrücke. Ein Test hält das fest.
  - Ob die zwei Floats im Trailer (Lautheit 9990 = nicht gesetzt, Zusatzverstärkung 0.5) hörbar sind, ist nicht
    geprüft. Falls ja, kommen sie in den Fingerabdruck, und alte Stempel werden neu berechnet.
- `Piece` (Stück, später auch Song): `preset: PresetLink?`, `parts: [PiecePart]` (Intro, Strophe, Solo …, je mit
  `preset: PresetLink?`), `key: String?` (Tonart als Freitext, z. B. „A-Moll“).
  - **Abweichung vom Prompt:** `PresetLink` statt `presetURL`. Er nennt das Preset über die stabile `PresetFile.id`
    und als Rückfall über den Dateinamen relativ zum Preset-Ordner, dazu den Namen für die Anzeige. Ein absoluter
    Pfad bräche in Stufe 3, wenn der Ordner nach ~/Music/Spark Studio/Presets umzieht.
  - Interpret, BPM und Notizen kommen in Stufe 3 dazu, wenn Stücke und Songs zusammengelegt werden.
- Risiko: Eine **alte, installierte** Recorder-Version, die die Bibliothek speichert, verwirft die neuen Felder, weil
  sie sie nicht kennt. Neu gebaute Apps kennen sie (gleiches SparkCore). Ab Stufe 2 schreibt Studio Stempel; bis dahin
  ist das Risiko leer.

## Tastaturmodell

Als Daten in `SparkCore/StudioKeymap.swift`, geprüft von `StudioKeymapTests`: keine zwei Kürzel auf denselben Tasten in
einem überlappenden Bereich; als Einzeltasten gelten überall nur R, Leertaste und Esc; Pfeile nie überall; der Bereich
Presets hat keine Buchstaben oder Ziffern als Einzeltaste; jede Einzeltaste aus dem heutigen KeyRouter ist eingeplant.
Die Apps lesen die Liste noch nicht. Ab Stufe 1 folgt ihr die Tastenverteilung.

Grundregeln, wie heute im Recorder: Einzeltasten wirken nie, solange ein Textfeld aktiv ist, ein Sheet offen ist oder
ein Popover den Fokus hat. Esc verlässt ein Textfeld. Leertaste auf einer fokussierten Taste bei voller Tastatursteuerung
drückt die Taste, außer während einer Aufnahme.

### Überall

| Kürzel | Wirkung | Bedingung |
|---|---|---|
| `R` | Aufnahme starten oder stoppen, auch „Nochmal“ | kein Textfeld |
| `Leertaste` | Abspielen oder anhalten; während der Aufnahme stoppen und anhören | kein Textfeld |
| `Esc` | Textfeld verlassen | |
| `⇧⌘1` / `⇧⌘2` | Bereich Aufnahme / Presets | neu |
| `⌘0` | Spark Studio zeigen | heute „Spark Recorder zeigen“ |
| `⌘/` | Tastaturkürzel (eine Liste beider Bereiche) | |
| `⌘Z` / `⇧⌘Z` | Rückgängig / Wiederholen im aktiven Bereich, Textfeld zuerst | |
| `⌘S` / `⇧⌘S` | Preset im Editor sichern / sichern unter | Preset offen |
| `⌘1` – `⌘4` | Platz spielen | Bluetooth verbunden |

### Nur Bereich Aufnahme

| Kürzel | Wirkung |
|---|---|
| `L` `M` `K` `F` `B` `N` `T` | Schleife, Marker, Behalten, Favorit, Take wechseln, Klick, Tap-Tempo |
| `G`, `⌘G` | Retro-Puffer speichern (nur bei Retro an) |
| `1` – `5` | Bewerten |
| `-` `+` `0` | Langsamer, schneller, zurücksetzen |
| `←` `→`, mit `⇧` | 5 s, mit ⇧ 1 s springen |
| `⌫` `⌦` `⌘⌫` | Gewählte Takes verwerfen (Papierkorb, `⌘Z` holt sie zurück), nicht während der Aufnahme |
| `⌘E` / `⇧⌘R` / `⌘F` | Take umbenennen / im Finder zeigen / Aufnahmen suchen |

### Nur Bereich Presets

| Kürzel | Wirkung |
|---|---|
| `⌘N` / `⇧⌘N` / `⌘D` | Neues Preset / aus Vorlage / duplizieren |
| `⌥⌘1` – `⌥⌘4` | Auf Platz speichern … (Nachfrage, Sicherung, Zurücklesen) |
| `⌘B` | A/B mit gespeichertem Stand |
| `⇧⌘L` | Änderungen live hören an/aus |
| `⌘R` | Verstärker neu lesen |
| `⌃1` – `⌃7`, `⌃0` | Gerät der Kette wählen, an/aus |
| `←` `→` `↑` `↓`, mit `⇧` | Regler mit Fokus, mit ⇧ große Schritte |
| `⌘E` / `⌘⌫` / `⇧⌘R` / `⌘F` | Preset umbenennen / in den Papierkorb / im Finder zeigen / suchen |

### Entschiedene Konflikte

- `⌘E`, `⌘⌫`, `⇧⌘R`, `⌘F` gibt es in beiden Apps: gleiche Taste, wirkt auf das Objekt des **aktiven Bereichs**.
- `←` `→`: Der KeyRouter springt heute im ganzen Fenster und würde einem fokussierten Regler die Pfeile nehmen. Er
  wirkt deshalb nur im Bereich Aufnahme (Prompt Stufe 1: nur wenn das Aufnahme-Fenster Hauptfenster ist).
- `⌘S`: Der Recorder speichert automatisch und hat nichts zu sichern. `⌘S` sichert deshalb überall das Preset im
  Editor, auch aus dem Bereich Aufnahme heraus (z. B. nach `⌘2` und einer Änderung).
- `⌘Z`: Im Recorder holt es verworfene Takes über den UndoManager des Fensters zurück, in Presets geht es an den
  Editor. Mit einem Fenster entscheidet der aktive Bereich. Offen bis Stufe 2: ob ein Verwerfen im Bereich Aufnahme
  auch nach einem Wechsel zu Presets noch mit `⌘Z` zurückkommt (Vorschlag: nein, nur im eigenen Bereich).
- `⌘1` – `⌘4` überall nur bei Verbindung, damit sie im Bereich Aufnahme nicht ins Leere gehen.
- `R` überall: Im Bereich Presets nimmt es der Seitenleiste die Typ-Auswahl für „r“. Bewusst so, damit Aufnehmen immer
  mit einer Taste geht.

### Offen

- Das Design-Canvas zeigt im Inspektor „Exportieren ⌘E“, `⌘E` ist aber heute Umbenennen (Recorder und Presets).
  Klärung mit der Design-Session bzw. dem Nutzer (Bitte steht in docs/SESSIONS.md). Vorschlag: `⌘E` bleibt
  Umbenennen, Exportieren bekommt `⇧⌘E`.

## Fenster und Layout

| | heute | Studio |
|---|---|---|
| Recorder | 1120×680 Inhalt; Deck ≈ 113 pt (92 + 2×10 Rand + 1 Linie) → Welle + Bibliothek ≈ 567 pt | Deck 122 pt → Bereich 598 pt (+31 pt) |
| Presets | 900×600 Inhalt (NavigationSplitView, Suche in der Seitenleiste) | Bereich 1120×598 (−2 pt Höhe, +220 pt Breite) |
| Studio | – | Mindestinhalt 1120×720 |

- Die Bereichs-Tabs liegen in der Fenster-Toolbar, also außerhalb des Inhalts; die Rechnung oben gilt für den Inhalt.
- Presets verliert 2 pt Höhe. Das ist in Stufe 2 mit `--snapshot --size 1120x598` (Bereich allein) und dem
  Studio-Fensterbild bei 1120×720 zu prüfen; der Editor hat heute Reserve (Pedale 146–150 pt, Reglerfeld flexibel).
- Offen: 720 pt Inhalt plus Toolbar (~52 pt) und Menüleiste passen nicht auf Bildschirme mit 800 pt Höhe
  (1280×800). Vorschlag: Mindesthöhe dort auf den Bildschirm begrenzen und die Bibliothek schrumpfen lassen, nicht
  das Deck.

## Offene Fragen

1. `⌘E` Umbenennen gegen „Exportieren ⌘E“ im Canvas (siehe oben).
2. Sind Lautheit und Zusatzverstärkung im Trailer hörbar (Fingerabdruck)? Am Amp prüfen.
3. Bis Stufe 3 gibt es zwei Ordner (~/Music/Spark Recorder, ~/Music/Spark Presets). Ein `PresetLink` löst sich bis
   dahin gegen ~/Music/Spark Presets auf.
4. Mindesthöhe auf kleinen Bildschirmen (siehe Layout).
