# Spark Studio

Spark Recorder und Spark Presets sind eine App: ein Prozess, ein Icon, ein Fenster mit festem Deck oben und den
Bereichen darunter (Aufnahme, Presets). Jeder Take kennt seinen Sound, das Tempo hat eine Quelle, Stück und Song sind
eins. Dieses Dokument ist die eine Stelle für Aufbau, Entscheidungen und das, was noch kommt. Es ersetzt die früheren
Arbeitsaufträge (spark-studio-prompt.md, spark-presets-next-prompt.md, beide in der Git-Geschichte). Gestaltung steht
in [DESIGN.md](DESIGN.md), Bedienung im [README](../README.md).

## Stand

| Stufe | Inhalt | Commit | Am Gerät |
|---|---|---|---|
| 0 | Datenmodell (Sound am Take, Teile, Tonart), Tastaturmodell, Layout | 66f5cdb | – (kein Verhalten) |
| 1 | Ein Bundle, zwei Fenster, Bluetooth auf Abruf | 308cc7f, 61d4bdb | vom Nutzer geprüft (2026-11-07) |
| 2 | Ein Fenster mit Bereichen, Sound am Take, ein Tempo | cc3ebb3 | offen |
| 3 | Stücke = Songs, `~/Music/Spark Studio`, alte Apps entfernt, neues Icon | 3960ccd | offen |
| – | Immer im Dark Mode, auf Wunsch des Nutzers | 6a85f45 | installiert, läuft |

Installiert ist Spark Studio seit 2026-11-07 in /Applications und im Dock. Beim ersten Start hat es
`~/Music/Spark Studio` angelegt und die alten Ordner übernommen; dass alle Aufnahmen und Presets dort angekommen sind,
ist noch nicht bestätigt.

Am Spark MINI noch zu prüfen: ein Take mit echtem Preset (Stempel, „Auf den Amp“, „Im Editor öffnen“), der
Tempo-Abgleich, das Lämpchen „BT“ und „Spielen“ bei Stücken und Teilen.

## Aufbau

```
SparkStudio  (App: ein Fenster, Bereiche, Verbindungen zwischen ihnen; Info.plist mit Mikrofon und Bluetooth)
  ├── SparkRecorderUI  Deck und Bereich Aufnahme; öffentlich nur RecorderHost, RecorderMenus, DeckBluetooth,
  │                    TakeSound, SoundActions, RecorderCommandLine
  ├── SparkPresetsUI   Bereich Presets mit Bluetooth-Link; öffentlich nur PresetsHost, PresetMenus, HeardSound
  ├── SparkDesign      Bausteine (DESIGN.md)
  ├── SparkCore        Aufnahme, Bibliothek, PresetStamp, Stücke, StudioFolders, StudioKeymap
  └── SparkControl     Protokoll, Katalog, Preset-Bibliothek, Fingerabdruck
```

- **Hosts statt öffentlicher Module.** Jede Bibliothek zeigt Studio genau einen Host. Der Rest bleibt `internal`.
  `RecorderSession` (früher der AppDelegate von Spark Recorder) übernimmt Studios Fenster: Dock-REC, „Aufnahme läuft
  weiter, wenn das Fenster zu ist“, Wiederherstellen nach einem Absturz und der UI-Selbsttest beziehen sich darauf.
- **Ein Fenster.** Deck oben fest (122 pt), darunter der Bereich, gewählt mit `SegmentTabs` in der Toolbar oder
  ⇧⌘1 / ⇧⌘2 (Menü Darstellung). Mindestinhalt 1120 × 720. Bereiche werden beim Wechsel neu aufgebaut, ihr Zustand
  liegt in den Modellen (auch welche Stücke aufgeklappt sind). Sheets des Recorders hängen am ganzen Fenster, seine
  Meldungen erscheinen im Bereich Presets oben über dem Inhalt.
- **Menüs folgen dem Bereich.** `AppCommands` und `PresetCommands` haben `isActive`. Ist ihr Bereich nicht vorn,
  geben sie gemeinsame Tasten (⌘E, ⌘⌫, ⇧⌘R) ab, ihre eigenen ruhen, ⌘Z geht an die Responder-Kette.
  - SwiftUI baut Menüs erst beim Aufklappen neu, eine Taste ginge sonst noch an den alten Stand. Studio stößt darum
    bei jedem Bereichswechsel das Update aller Menüs an (`Studio.refreshMenus`). `--menu-dump` prüft das mit einem
    echten Tastendruck.
  - Die Recorder-Gruppe „In den Papierkorb legen“ steht nach `.pasteboard`: Presets ersetzt `.undoRedo`, und SwiftUI
    lässt Gruppen weg, die an einer ersetzten hängen.
- **Immer dunkel.** Studio setzt beim Start `NSApp.appearance` auf Dunkel, auch für den Schreibtisch, unabhängig von
  der Systemeinstellung. Die hellen Werte aus DESIGN.md bleiben gültig; `--appearance light` und der Bild-Selbsttest
  zeichnen sie weiter.
- **Bluetooth auf Abruf.** Beim Start kein `CBCentralManager`, also keine Bluetooth-Abfrage. Verbunden wird beim
  ersten Zeigen des Bereichs Presets (nur beim ersten, sonst hielte „Trennen“ nicht), mit der Taste „Verbinden“ unten
  in der Seitenleiste, mit dem Lämpchen „BT“ im Deck oder über das Menü. Zustand `.off` heißt „Getrennt“. Ein
  Bluetooth-Fehler wird gemeldet und beendet nie eine Aufnahme.

### Einen Bereich hinzufügen

Für eine weitere App, etwa ein Stimmgerät oder Setlists:

1. Neue Bibliothek `Sources/Spark<Name>UI` mit einem `<Name>Host` (Inhalt als `AnyView`, Menüs als `Commands` mit
   `isActive`), abhängig von SparkDesign und was sie braucht. Target in Package.swift, Abhängigkeit von SparkStudio.
2. Neuer Fall in `StudioArea` (Sources/SparkStudio/Studio.swift). ⇧⌘ plus die nächste Ziffer und der Tab folgen daraus.
3. Eine Zeile im `switch` von `StudioWindowView` und eine in `StudioCommands`.
4. Ein Scope in `StudioKeymap` mit allen Tasten des Bereichs. `StudioKeymapTests` meldet jede Doppelbelegung.
5. Einzeltasten bleiben dem Bereich Aufnahme vorbehalten, außer R und Leertaste.

## Datenmodell

- **Sound am Take:** `Recording.preset: PresetStamp?` mit `slot` (1–4, nil = vorübergehend gespielt), `name`,
  `stampedAt`, `sha256`. Der Schnappschuss liegt als Preset-Datei in `Aufnahmen/.presets/<Take-UUID>.json`
  (`PresetFile.snapshotData`), damit „Im Editor öffnen“ die normale Leselogik benutzt. Benannt nach der UUID, nicht
  nach dem Dateinamen, so bleibt er beim Umbenennen am Take. Verwerfen und Wiederherstellen behalten ihn.
  - Was klingt (`PresetsModel.heardPreset`, nur aus dem Speicher): der Editor-Stand, wenn er live auf 7F spielt (auch
    beim A/B-Vergleich), ein ausprobiertes Preset, sonst der gespeicherte Platz. Ohne Verbindung kein Sound.
  - Take-ID und Stempel stehen schon im Journal, der Schnappschuss wird beim Start geschrieben: Ein nach einem
    Absturz reparierter Take behält beides.
- **Fingerabdruck** `SparkPreset.sha256Hex()`: SHA-256 über das kanonische JSON **nur der Effektkette** (Modelle,
  an/aus, Werte mit Marker). Name, Beschreibung, BPM, uuid und Trailer zählen nicht, weil der Amp einen Platz mit
  längerem Trailer schickt als das spielende Preset; sonst hätte derselbe Sound zwei Fingerabdrücke.
- **Stücke = Songs:** `Piece` mit Titel, `artist`, `bpm`, `key`, `notes`, `preset` und `parts` (je mit `preset`).
  Ein `PresetLink` nennt ein Preset über die stabile `PresetFile.id`, als Rückfall über den Dateinamen im Ordner
  Presets, nie über einen absoluten Pfad. Übungszeit kommt aus dem Übungsprotokoll, verworfene Takes zählen mit.
- **Schema 2:** `LibraryDocument.currentSchema = 2`. Eine Bibliothek mit Schema 1 bekommt vor dem ersten Speichern
  eine Kopie `Bibliothek.vor-Schema-2.aus-1.json`. Eine Version, die nur Schema 1 kennt, öffnet Schema 2 nur lesend und
  kann die neuen Felder darum nie verwerfen.
- **Ordner:** `~/Music/Spark Studio/Aufnahmen` und `…/Presets` (`StudioFolders`). Beim ersten Start werden
  `~/Music/Spark Recorder` und `~/Music/Spark Presets` kopiert (APFS-Klon) und nie verändert oder gelöscht. Die Kopie
  entsteht in einem versteckten Ordner daneben und wird erst fertig umbenannt. Hält Spark Recorder noch seine
  Bibliothek (Prozess-Lock), übernimmt Studio nichts, sagt es und beendet sich. Die Einstellungen von
  `local.sparkrecorder` und `local.sparkpresets` übernimmt Studio einmal, nur für Schlüssel, die es noch nicht hat
  (`SettingsTakeover`). Ein Testordner (`--library`) überspringt all das.

## Tastaturmodell

Als Daten in `SparkCore/StudioKeymap.swift`, geprüft von `StudioKeymapTests` (keine Doppelbelegung in einem Bereich,
Einzeltasten überall nur R und Leertaste, Pfeile nie überall, Presets ohne Buchstaben als Einzeltasten). Der KeyRouter
fragt `StudioKeymap.isSingleKeyEverywhere`, die Liste unter ⌘/ wird daraus erzeugt.

Grundregeln: Einzeltasten wirken nie, solange ein Textfeld aktiv, ein Sheet offen ist oder ein Popover den Fokus hat.
Leertaste auf einer fokussierten Taste bei voller Tastatursteuerung drückt die Taste, außer während einer Aufnahme.

| Wo | Kürzel |
|---|---|
| überall | R, Leertaste, ⇧⌘1/⇧⌘2, ⌘/, ⌘Z/⇧⌘Z (im Bereich vorn), ⌘S (Preset im Editor), ⌘1–⌘4 (verbunden) |
| Aufnahme | L M K F B N T G, ⌘G, 1–5, - + 0, ← → (mit ⇧), ⌫ ⌦ ⌘⌫, ⌘E, ⇧⌘R, ⌘F, Esc |
| Presets | ⌘N, ⇧⌘N, ⌘D, ⇧⌘S, ⌥⌘1–⌥⌘4, ⌘B, ⇧⌘L, ⌘R, ⌃1–⌃7, ⌃0, Pfeile am Regler, ⌘E, ⌘⌫, ⇧⌘R |

Entschieden: ⌘E, ⌘⌫, ⇧⌘R wirken auf Take oder Preset je nach Bereich. ⌘S sichert überall das Preset im Editor (der
Recorder speichert von selbst). ⌘1–⌘4 überall, aber nur bei Verbindung. R überall, auch wenn es der Seitenleiste die
Typ-Auswahl für „r“ nimmt. Esc gehört im Bereich Presets dem Suchfeld. ⇧⌘S nur in Presets, weil es dort ein Sheet
öffnet. ⌘E bleibt Umbenennen; das Design-Canvas zeigte „Exportieren ⌘E“, das hat keine Keycap bekommen. Ob ⌘F das
Suchfeld der Presets fokussiert, ist nicht geprüft, darum steht es nicht in der Liste.

## Prüfungen

- `swift test`: alle Einheitentests mit synthetischen Daten, darunter Stempel, Journal, Schema 2, Ordner- und
  Einstellungsübernahme (auch „Spark Recorder läuft noch“), Fingerabdruck und Tastaturmodell. Ein Audio-Timing-Test
  (`testLoopStaysInsideItsRange`) schlägt im vollen Lauf unter Last gelegentlich fehl und besteht allein.
- UI-Selbsttest `main` im Studio-Fenster: dieselben Ergebnisse wie früher in Spark Recorder. 3 FAIL kommen aus dieser
  Testumgebung (das BlackHole-Testsignal kommt nicht an), einzelne VoiceOver-Prüfungen schlagen mal fehl, mal nicht.
- Szenario `sound`: Stempel im Journal, Schnappschuss beim Start, „Auf den Amp“ scheitert mitten in der Aufnahme über
  den echten Studio-Weg (Presets offline, wie ein Verbindungsabbruch), die Aufnahme läuft weiter und endet mit Sound.
- `--menu-dump`: keine Taste doppelt in einem Bereich, ⌘N nur im Bereich Presets wirksam.
- Verschieben in die Bibliotheken (308cc7f): Fensterbilder vorher und nachher unterscheiden sich nur dort, wo sich zwei
  Läufe desselben Stands auch unterscheiden.
- Fensterbilder beider Bereiche in Hell und Dunkel und bei 1120 × 720 angesehen (docs/pictures).
- Icon: bei 1024 und 32 px angesehen.

## Offen und als Nächstes

- **Am Amp prüfen**, siehe Stand. `--live-selftest` lief bisher nur in Spark Presets, nicht in Studio.
- **Trailer:** Ob Lautheit und Zusatzverstärkung im Trailer hörbar sind, ist nicht geprüft. Falls ja, gehören sie in
  den Fingerabdruck, und alte Stempel werden neu berechnet.
- **Kleine Bildschirme:** 720 pt Inhalt plus Toolbar und Menüleiste passen knapp auf 800 pt hohe Bildschirme, mit Dock
  unten nicht. Vorschlag: die Bibliothek schrumpfen lassen, nicht das Deck.
- **Bibliothek der Presets** (aus der früheren Roadmap): **Gruppen** nach Wunsch des Nutzers, etwa „Practice“, „U2“,
  „Country“, „Basis Setup“ (ein Preset in mehreren, als Abschnitte der Seitenleiste, zuordnen per Kontextmenü oder
  Ziehen); Favoriten, Tags und Bewertung (Felder gibt es seit Format 2, die Oberfläche fehlt), Filter und
  Sortierung, Import und Export, Versionsverlauf pro Preset.
- **Setlists und Auftrittsmodus** bauen auf den Stücken auf: Reihenfolge per Drag & Drop, großer Vollbildmodus mit
  Umschalten per Pfeiltasten, Leertaste und Zahlen, nächster Song oder Teil per Taste. Optional „Setlist auf den Amp“:
  bis zu vier Presets auf die Plätze, mit Nachfrage und Sicherung wie beim Speichern auf einen Platz.
- **Alte Apps:** Spark Recorder und Spark Presets sind aus dem Projekt entfernt, ihre installierten Kopien liegen seit
  2026-11-07 im Papierkorb und sind aus dem Dock genommen. Die alten Ordner `~/Music/Spark Recorder` und
  `~/Music/Spark Presets` sind unverändert da; Studio liest sie nicht mehr. Ob und wann sie gelöscht werden, entscheidet
  der Nutzer.
