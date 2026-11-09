# Spark Studio

Spark Recorder und Spark Presets sind eine App: ein Prozess, ein Icon, ein Fenster mit festem Deck oben und den
Bereichen darunter (Aufnahme, Presets, Stimmgerät). Jeder Take kennt seinen Sound, das Tempo hat eine Quelle, Stück und Song sind
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
| – | Klangrezepte, KI-Katalog in `docs/ai`, Text für REACTOR | 7bd22b1, b530b84 | installiert (2026-11-08), kein Rezept am Amp gehört |
| – | KI-Sound im Bereich Presets: Beschreibung → Ollama Cloud API → drei Rezepte, Nachbessern, Verlauf | – | installiert (2026-11-08), nicht gegen die Cloud und nicht am Amp geprüft |
| – | Bereich Stimmgerät (⇧⌘3): MPM plus Phasen-Ausgleichsrechnung, liest den Eingang der Aufnahme mit | – | installiert (2026-11-08), nur mit synthetischen Signalen geprüft, nicht mit Gitarre |

Installiert ist Spark Studio seit 2026-11-07 in /Applications und im Dock. Beim ersten Start hat es
`~/Music/Spark Studio` angelegt und die alten Ordner übernommen; dass alle Aufnahmen und Presets dort angekommen sind,
ist noch nicht bestätigt.

Am Spark MINI noch zu prüfen: ein Take mit echtem Preset (Stempel, „Auf den Amp“, „Im Editor öffnen“), der
Tempo-Abgleich, das Lämpchen „BT“ und „Spielen“ bei Stücken und Teilen. Außerdem die vier Beispiel-Rezepte, die seit
2026-11-08 in `~/Music/Spark Studio/Presets` liegen: erscheinen sie mit Zauberstab, klingen sie wie beschrieben, und
wird ein gespeichertes Rezept zur normalen Preset-Datei.

## Aufbau

```
SparkStudio  (App: ein Fenster, Bereiche, Verbindungen zwischen ihnen; Info.plist mit Mikrofon und Bluetooth)
  ├── SparkRecorderUI  Deck und Bereich Aufnahme; öffentlich nur RecorderHost, RecorderMenus, DeckBluetooth,
  │                    TakeSound, SoundActions, RecorderCommandLine
  ├── SparkPresetsUI   Bereich Presets mit Bluetooth-Link; öffentlich nur PresetsHost, PresetMenus, HeardSound
  ├── SparkTunerUI     Bereich Stimmgerät; öffentlich nur TunerHost, TunerMenus. Kein Bluetooth, kein Ton
  ├── SparkDesign      Bausteine (DESIGN.md)
  ├── SparkCore        Aufnahme, Bibliothek, PresetStamp, Stücke, StudioFolders, StudioKeymap,
  │                    Tonhöhenerkennung (PitchDetector, PitchTracker, Tuning, TunerEngine, AudioTap, SharedInput)
  └── SparkControl     Protokoll, Katalog, Preset-Bibliothek, Fingerabdruck
```

- **Hosts statt öffentlicher Module.** Jede Bibliothek zeigt Studio genau einen Host. Der Rest bleibt `internal`.
  `RecorderSession` (früher der AppDelegate von Spark Recorder) übernimmt Studios Fenster: Dock-REC, „Aufnahme läuft
  weiter, wenn das Fenster zu ist“, Wiederherstellen nach einem Absturz und der UI-Selbsttest beziehen sich darauf.
- **Ein Fenster.** Deck oben fest (122 pt), darunter der Bereich, gewählt mit `SegmentTabs` in der Toolbar oder
  ⇧⌘1 / ⇧⌘2 / ⇧⌘3 (Menü Darstellung). Mindestinhalt 1120 × 720. Bereiche werden beim Wechsel neu aufgebaut, ihr Zustand
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

## Stimmgerät

Ein chromatisches Stimmgerät mit Saitenerkennung für Gitarre und Bass, 30 Hz bis 1,4 kHz (H0 bis über E6), Anzeige
auf 0,1 Cent, Kammerton A4 430,0–450,0 Hz in Zehntel-Hertz (UserDefaults `tunerA4`), Stimmungen Standard, Drop D,
DADGAD, Open G, Halbton tiefer und Chromatisch (`tunerTuning`), Zeiger oder Stroboskop (`tunerStrobe`).

### Woher das Audio kommt, und warum so

- **Mitlesen statt zweiter Audio-Unit.** Die `CaptureEngine` der Aufnahme schreibt jeden Block zusätzlich in einen
  `AudioTap`: einen lock-freien Ringpuffer (ein Schreiber, ein Leser, `CSparkRT/tap.c`) mit dem Mittel aller Kanäle.
  Im Callback wird dabei nichts alloziert, nichts gesperrt und nichts geloggt; der Puffer ist beim Anlegen angefasst,
  damit keine Seite nachgeladen wird. Läuft der Leser hinterher, werden die neuesten Frames verworfen und gezählt.
- **Warum nicht eine eigene Unit auf dem Spark:** `CaptureEngine.open` stellt das Gerät auf seine höchste Rate und
  beim Schließen zurück. Zwei Units auf demselben Gerät könnten so die Rate unter einer laufenden Aufnahme ändern –
  die Aufnahme bricht dann mit „Abtastrate geändert“ ab. Mitlesen kann das nicht: Es gibt nur die eine Unit.
- **Regeln für die gemeinsame Nutzung** (`AppModel.startTuning/stopTuning`, über `SharedInput`): Das Stimmgerät
  öffnet den Eingang nur, wenn er zu ist, und schließt ihn nur, wenn ihn sonst nichts braucht (`isTuning` steht in
  jeder Schließ-Bedingung neben Aufnahme, Retro und Eingang prüfen). Eine laufende Aufnahme und der Retro-Puffer
  werden nie umgestellt oder beendet. Schaltet die Aufnahme Retro ein oder aus, öffnet sie den Eingang neu; der Tap
  bleibt an der Engine und liest weiter (eine kurze Lücke für das Stimmgerät, keine für die Aufnahme). Solange das
  Stimmgerät hört, gilt der Eingang als offen (`isListening`): das Deck zeigt den Pegel, die Messungen sind gesperrt.
- **Andere Eingänge** (USB-Interface, Mikrofon des Macs) bekommen eine eigene `CaptureEngine` mit
  `InputPolicy.listenOnly`, ohne Ratenwechsel (`raiseRate: false`) und ohne je aufzunehmen. Ein Spark-Gerät öffnet
  das Stimmgerät nie selbst; mit einer Testbibliothek gibt es nur den Eingang des Decks.
- **Nur solange der Bereich vorn ist:** Studio schaltet das Stimmgerät an, wenn der Bereich gewählt ist und das
  Fenster sichtbar ist (nicht geschlossen, nicht im Dock, nicht verdeckt), sonst aus. Dann wird der Tap gelöst und
  der Eingang geschlossen, außer die Aufnahme hält ihn ohnehin offen. Ausnahme ist nur die synthetische Saite der
  Fensterbilder, die kein Gerät öffnet.
- **Kein Kontakt zum Amp, kein Ton:** SparkTunerUI hängt nicht von SparkControl oder SparkPresetsUI ab, kann also
  weder Bluetooth noch den Link benutzen. Es gibt keine Ausgabe. Sollte je etwas zum Amp gehen, dann nur über den
  bestehenden Link und `AmpGuard`.
- **Datenschutz:** Audio wird nur im Speicher ausgewertet und nie gespeichert, gesendet oder geloggt; der Ringpuffer
  wird beim Freigeben genullt. Kein Netz. Alle Tests nutzen synthetische Signale (`TunerTestSignal`).

### Die Erkennung (`PitchTracker`, alle 5 ms, auf eigenem Thread in `TunerEngine`)

1. **Pegel und Anschlag:** RMS über 20 ms oder zwei Perioden, Schwelle −60 dBFS an, −66 aus. Ein Anschlag hebt den
   Pegel aufs Doppelte über die 25–80 ms davor; seine ersten 20 ms bleiben draußen. Ein Hochpass bei 10 Hz nimmt
   einen Gleichanteil weg, der die NSDF sonst nie negativ werden ließe.
2. **Grob: MPM (McLeod).** NSDF über FFT (vDSP), erstes Schlüsselmaximum ≥ 0,9 × das höchste, parabolische
   Interpolation. Ein Wert zählt erst, wenn der Block auch die Oktave darunter gesehen hat (zwei Perioden davon) –
   so kann der erste Wert einer tiefen Saite nicht ihr zweiter Oberton sein.
3. **Einrasten mit Oktavschutz:** drei übereinstimmende Werte (±30 Cent). Danach gelten Werte eine Oktave, Duodezime
   oder Quinte daneben als Ober- oder Untertöne und werden bis zum nächsten Anschlag ignoriert; ein anderer Ton
   braucht drei übereinstimmende Werte. Zum Halten reicht eine Klarheit von 0,5, zum Einrasten braucht es 0,8.
4. **Fein: Phase und Ausgleichsgerade.** Jeder Block (12 Perioden, höchstens 0,45 s, Hann-Fenster symmetrisch zur
   Blockmitte) wird bei der eingerasteten Frequenz demoduliert. Die Phase der Blockmitte wächst bei einem Ton um δ
   genau um δ pro Sample, auch beim Ausklingen; eine gewichtete Gerade durch die Phasen über bis zu 60 Perioden
   (0,6–2 s) gibt die Frequenz. Eine zweite Demodulation beim 1,5-Fachen misst das Rauschen daneben: daraus kommen
   die erwartete Streuung (`PitchReading.uncertainty`) und die Schwelle, ab der eine kurze Gerade (80 ms) „der Wirbel
   wird gedreht“ meldet und die lange verworfen wird. Ohne diese Schwelle jagte ein leiser Ton seinem eigenen Rauschen
   nach.
5. **Glättung:** Median aus fünf, dann exponentiell, langsam bei gehaltenem Ton (0,12), schnell bei Änderung (0,35
   ab 0,6 Cent, 0,7 ab 2 Cent). Verklingt die Saite ins Rauschen, bleibt ihr letzter genauer Wert stehen, nicht der
   verrauschte. Nach dem Ton bleibt der Wert 1,5 s als „gehalten“ stehen.
6. **Anzeige** (`TunerInterpreter`): nächste Saite der Stimmung bis ±300 Cent, sonst der nächste Ton chromatisch,
   mit etwas Hysterese an der Grenze. „Gestimmt“ bei |Abweichung| ≤ 0,5 Cent für 0,4 s und erwarteter Streuung
   ≤ 0,2 Cent. Deutsche Namen (H, B für B♭).

## Klangrezepte für KI-Assistenten

Ein Klangrezept (`"format": "spark-sound-recipe"`) beschreibt einen Sound geräteneutral: Modell und Werte je Platz,
Regler 0–10, Parameter über feste englische Schlüssel (`ParameterInfo.key`). `PresetLibrary` liest Rezepte im Ordner
Presets wie Presets (`SavedPreset.isRecipe`, Zauberstab in der Seitenleiste); erst Speichern schreibt sie als
Preset-Datei. Die uuid kommt aus dem SHA-256 der Datei, bleibt also beim erneuten Lesen gleich. Ein fehlerhaftes Rezept
steht unter „Nicht lesbar“, die Gründe nennt `SparkStudio --recipe-check`.

- Anleitung, Katalog, Schema und Beispiele: `docs/ai`. Der Katalog dort wird mit `--catalog-export docs/ai` aus dem
  Code geschrieben, `SoundRecipeTests` schlägt fehl, wenn er hinterherhinkt.
- Projekt-Skill `spark-sound` für Claude Code in diesem Repository.
- KI-Sound in der App: Beschreibungstext an Ollama Cloud (`https://ollama.com/api/chat`), Antwort über denselben
  `SoundRecipe`-Pfad geprüft und als Rezept geschrieben (`PresetLibrary.addRecipe`, `SoundAI`, `OllamaCloud`).
  - Der Systemprompt trägt neben dem Katalog typische Signalketten von Gitarristen und Stilen, die Regel Songtempo →
    Delay-Zeit, Hall nach Stil und drei gültige Beispiel-Rezepte (`SoundAIKnowledge.swift`). Tests prüfen, dass jede
    Modell-ID darin im Katalog steht und jedes Beispiel ohne Warnung liest.
  - Drei Varianten mit verschiedener Ausrichtung (originalgetreu, druckvoller, reduziert) laufen parallel und
    erscheinen einzeln, sobald sie fertig sind (`SoundAI.variants`). Gleicht eine fertige Variante einer anderen
    (gleicher Amp und gleicher Verzerrer), geht sie einmal mit der Bitte um einen anderen Amp zurück.
  - Schnellknöpfe „wärmer“, „mehr Gain“, „weniger Hall“, „heller“ schicken das Rezept mit einer Folgeanfrage zurück
    (`SoundAI.refine`). Die Antwort muss die Modelle behalten und sich in die verlangte Richtung bewegen, sonst geht
    sie einmal zurück; klappt es dann noch nicht, dreht Studio den naheliegenden Regler selbst und sagt das an.
  - Robust: Wiederholung bei Netzfehlern, 429 und 5xx (nach 1,5 s und 4 s), 120 s Zeitlimit je Anfrage, klare
    Meldungen für falschen Schlüssel, unbekanntes Modell, Zeitlimit und Antworten ohne JSON. Abbrechen stoppt alle
    Anfragen; das Schließen des Fensters auch.
  - Verlauf der letzten 8 Wünsche in UserDefaults (`AI Sound History`), löschbar im Fenster. Ein behaltener Sound trägt
    den Wunsch in der Beschreibung und die Tags „KI-Sound“ plus die gemachten Anpassungen.
  - Datenschutz: Es gehen nur Regeln, Katalog, der Wunschtext und bei einer Folgeanfrage das Rezept selbst hinaus,
    mit festem User-Agent `SparkStudio`. Ein Wunsch mit E-Mail-Adresse, Telefonnummer oder etwas Schlüsselartigem
    wird vor dem Senden abgelehnt (deterministische Muster, `SoundAI.privacyProblem`), höchstens 200 Zeichen. Der
    Schlüssel liegt im Schlüsselbund (nur dieser Mac, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) und steht nur
    im Authorization-Header. Netzverkehr nur auf Zuruf.
- REACTOR (eigene Produktlinie, laut Positive Grid nicht Spark-kompatibel, kein Dateiformat dokumentiert): Weg nur
  über Text. `--recipe-prompt` beschreibt ein Rezept oder Preset auf Englisch für „Text to Tone“
  (`SoundRecipe.toneDescription`).
- Geprüft ist nur der Spark MINI. Andere Spark-Verstärker, Spark NEO und REACTOR sind nicht geprüft, offene Punkte
  stehen unter „Offen und als Nächstes“.

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
| überall | R, Leertaste, ⇧⌘1/⇧⌘2/⇧⌘3, ⌘/, ⌘Z/⇧⌘Z (im Bereich vorn), ⌘S (Preset im Editor), ⌘1–⌘4 (verbunden) |
| Aufnahme | L M K F B N T G, ⌘G, 1–5, - + 0, ← → (mit ⇧), ⌫ ⌦ ⌘⌫, ⌘E, ⇧⌘R, ⌘F, Esc |
| Presets | ⌘N, ⇧⌘N, ⌘D, ⇧⌘S, ⌥⌘1–⌥⌘4, ⌘B, ⇧⌘L, ⌘R, ⌃1–⌃7, ⌃0, Pfeile am Regler, ⌘E, ⌘⌫, ⇧⌘R |
| Stimmgerät | ⌘T (Zeiger/Stroboskop), ⌘↑/⌘↓ (Kammerton ±0,1 Hz), ⌘0 (440 Hz), ⌃1–⌃6 (Stimmung); keine Einzeltasten |

Entschieden: ⌘E, ⌘⌫, ⇧⌘R wirken auf Take oder Preset je nach Bereich. ⌘S sichert überall das Preset im Editor (der
Recorder speichert von selbst). ⌘1–⌘4 überall, aber nur bei Verbindung. R überall, auch wenn es der Seitenleiste die
Typ-Auswahl für „r“ nimmt. Esc gehört im Bereich Presets dem Suchfeld. ⇧⌘S nur in Presets, weil es dort ein Sheet
öffnet. ⌘E bleibt Umbenennen; das Design-Canvas zeigte „Exportieren ⌘E“, das hat keine Keycap bekommen. Ob ⌘F das
Suchfeld der Presets fokussiert, ist nicht geprüft, darum steht es nicht in der Liste.

## Schutz des Verstärkers

Am 2026-11-08 heulte der Amp nach dem Behalten eines KI-Sounds so laut, dass es in den Ohren schmerzte – obwohl die
Regler für Gitarre und Music auf null standen. Der Lärm entstand also hinter den Lautstärkereglern.
Derselbe Sound hatte beim Anhören kurz vorher normal geklungen. Der einzige Unterschied war die Beschreibung: 136
statt 82 Bytes, insgesamt 540 Bytes in 22 Stücken. Alles, was bis dahin funktioniert hatte, blieb bei höchstens
486 Bytes, 20 Stücken und Texten unter 128 Bytes. Ob die lange Zeichenkette oder die größere Nachricht schuld war, ist
nicht geklärt.

Seitdem geht jedes Preset durch `AmpGuard` (Mac, `Sources/SparkControl/AmpGuard.swift`) bzw. `for_amp` und
`amp_problems` (Linux, `protocol.py`):

- **Angepasst:** Werte werden auf 0–1 begrenzt, das Tempo auf 40–250. Die Beschreibung wird auf höchstens 80 Bytes
  gekürzt und weiter, bis das Preset höchstens 486 Bytes groß ist. Der Klang bleibt dabei unverändert. Live-Regler
  werden ebenfalls auf 0–1 begrenzt.
- **Verweigert, mit Meldung im Fenster:** Ein Preset wird nicht gesendet, wenn es nicht genau 7 Effekte hat, wenn ein
  Wert keine Zahl ist, wenn ein Name länger als 31 Bytes ist (Kennung 36) oder wenn es trotz Kürzen zu groß ist.
- **Protokoll:** Jede Sendung steht im Systemprotokoll:
  `log show --predicate 'subsystem == "local.sparkstudio" AND category == "amp"' --info --last 1h`.
- **Tests:** `AmpGuardTests` und `AmpDescriptionLimitTests` (Mac), `test_core.py` (Linux). Sie prüfen das Preset vom
  2026-11-08 und das größte Preset, das der Katalog ergibt. Es passt mit vollem Namen, nur die Beschreibung wird kürzer.

Die Lautstärkeregler schützen vor so einem Fehler nicht. Deshalb wird keine Grenze angehoben, indem man es am
Lautsprecher ausprobiert, auch nicht leise. Tritt so ein Lärm auf: sofort ausschalten (Ein-/Aus-Taster, notfalls
Strom und USB trennen).

## Prüfungen

- `swift test`: alle Einheitentests mit synthetischen Daten, darunter Stempel, Journal, Schema 2, Ordner- und
  Einstellungsübernahme (auch „Spark Recorder läuft noch“), Fingerabdruck und Tastaturmodell. Ein Audio-Timing-Test
  (`testLoopStaysInsideItsRange`) schlägt im vollen Lauf unter Last gelegentlich fehl und besteht allein.
  - Seit 2026-11-08 schlagen in `AudioPathTests` vier Prüfungen fehl, auch allein: Das Testsignal über BlackHole kommt
    nicht an (gemessen 0 Hz statt 1000 Hz, das Abspielen endet nicht). SparkCore ist seit den Rezepten unverändert, am
    Morgen desselben Tages lief alles durch. BlackHole 2ch stand dabei auf 192 kHz. Vermutlich die Audio-Umgebung des
    Macs, nicht der Code; nicht weiter untersucht. Am Abend desselben Tages lief `swift test` wieder vollständig durch
    (417 Tests, auch diese vier und der Timing-Test). Eine Ursache ist nicht gefunden, es ist nur ein Lauf; weiter
    beobachten.
- Stimmgerät, alle mit synthetischen Signalen (`TunerAccuracyTests`, `TunerBehaviorTests`, `TunerModelTests`,
  `TunerBlocksTests`):
  - Sinus 30 Hz bis 1,4 kHz bei 44,1 und 48 kHz (und 96 kHz an vier Stellen): jeder Wert nach 0,8 s ≤ 0,1 Cent.
  - Sägezahn mit Ausklingen und Karplus-Strong-Saite (Schleife exakt gestimmt, per DFT-Spitze unabhängig auf
    ≤ 0,05 Cent nachgeprüft), Rauschen −30 dB unter der ersten halben Sekunde: ≤ 0,5 Cent, solange die Saite
    mindestens 10 dB über dem Rauschen liegt, ab 0,6 s (unter 50 Hz ab 1 s).
  - Gehaltener Sägezahn mit Rauschen: Streuung ≤ ±0,2 Cent. Kein Oktavfehler beim 7-s-Ausklingen von H0, E1, H1,
    E2, A2 ins Rauschen (ein Einrasten, keine Fehlauslösung), auch nicht bei einem Grundton halb so stark wie die
    Oktave. Erster Wert eines tiefen E 78–80 ms nach dem Anschlag, H0 nach 102–105 ms (Grenze 120 ms, gezählt in
    Samples des Stroms).
  - Gemessen am 2026-11-08: Sinus höchstens 0,002 Cent daneben; Karplus-Strong im Rauschen höchstens 0,44 Cent bei
    H0, 0,17 bei E1 und ≤ 0,07 ab E2; gehaltener Ton im Rauschen ±0,011 Cent.
  - Neuer Anschlag einer anderen Saite: unter 150 ms. Gedrehter Wirbel (20 Cent/s): höchstens 150 ms hinterher,
    0,25 s nach dem Stopp ≤ 0,5 Cent. Halten, Anschlag-Knack, Schwelle, Gleichanteil, Stimmungen, Namen, Kammerton,
    Texte; Ringpuffer (Mittel der Kanäle, Überlauf, Epoche) und dass die Aufnahme ihn nur angehängt beschreibt.
  - Modell mit gefälschtem Eingang: hört nur, solange aktiv; ohne Spark wird nichts geöffnet; Einstellungen bleiben.
- `SoundRecipeTests` und `ToneDescriptionTests`: Rezepte in beide Richtungen, alle Fehler auf einmal, Korrekturen
  mit Hinweis, stabile uuid, Lesen im Presets-Ordner, Text für REACTOR. Sie prüfen auch, dass die Beispiele in
  `docs/ai/examples` gültig sind und `docs/ai/spark-catalog.*` dem Katalog im Code entspricht.
- UI-Selbsttest `main` im Studio-Fenster: dieselben Ergebnisse wie früher in Spark Recorder. 3 FAIL kommen aus dieser
  Testumgebung (das BlackHole-Testsignal kommt nicht an), einzelne VoiceOver-Prüfungen schlagen mal fehl, mal nicht.
- Szenario `sound`: Stempel im Journal, Schnappschuss beim Start, „Auf den Amp“ scheitert mitten in der Aufnahme über
  den echten Studio-Weg (Presets offline, wie ein Verbindungsabbruch), die Aufnahme läuft weiter und endet mit Sound.
- `--menu-dump`: keine Taste doppelt in einem Bereich, ⌘N nur im Bereich Presets wirksam; das Menü Stimmgerät hat
  seine Tasten nur in seinem Bereich (2026-11-08 geprüft, zum Vergleichen `LC_ALL=C`, sonst hält `sort` ⌃1 und ⇧⌘1
  für gleich).
- Fensterbilder des Stimmgeräts aus dem Selbsttest `pictures` (synthetische Saite durch die echte Kette: A2 −3,4 Cent,
  G3 +1,8 Cent im Stroboskop, E2 gestimmt), in Hell und Dunkel und bei 1120 × 720 angesehen.
- Verschieben in die Bibliotheken (308cc7f): Fensterbilder vorher und nachher unterscheiden sich nur dort, wo sich zwei
  Läufe desselben Stands auch unterscheiden.
- Fensterbilder beider Bereiche in Hell und Dunkel und bei 1120 × 720 angesehen (docs/pictures).
- Icon: bei 1024 und 32 px angesehen.

## Offen und als Nächstes

- **Stimmgerät mit echter Gitarre:** gegen ein Referenzstimmgerät (Strobe oder Clip-on mit 0,1 Cent) an allen Saiten,
  auch Drop D und ein Bass bis H0; prüfen, ob die Schwelle −60 dBFS zum Pegel des Spark über USB passt, ob „Gestimmt“
  bei echten Saiten (die beim Anschlag etwas zu hoch klingen) ruhig genug kommt, und wie VoiceOver die Ansagen
  verteilt. Die Latenz des Callbacks (Puffergröße) und des 5-ms-Lesetakts kommt zu den gemessenen 80 ms (tiefes E) noch dazu.
- **Stimmgerät in der Linux-App:** noch nicht gebaut. `PitchTracker` ist reine Logik und lässt sich nach Python
  übertragen; PipeWire liefert den Eingang wie bei der Aufnahme.

- **Am Amp prüfen**, siehe Stand. `--live-selftest` lief bisher nur in Spark Presets, nicht in Studio.
- **Klangrezepte:** im Editor „Als Rezept exportieren“ und „Text für REACTOR kopieren“ (bisher nur `--recipe-from`
  und `--recipe-prompt` auf der Kommandozeile). Andere Spark-Verstärker mit ihren zusätzlichen Modellen in den
  Katalog aufnehmen, sobald eines zum Prüfen da ist. REACTOR nimmt nur Text, solange Positive Grid kein Format oder
  keine Schnittstelle veröffentlicht; ein Text-Rezept dort ausprobieren.
- **KI-Sound:** läuft über die Ollama Cloud API; offen sind ein Test gegen die echte Cloud (alle Tests laufen mit
  gefälschtem Chat), ob gpt-oss:120b die Beispiele und Schnellknöpfe gut befolgt, und der Nachbau im Linux-Port.
  Am Amp ungeprüft: dass ein Delay mit sync = BPM als Viertel auf `bpm` kommt; darauf beruht die Regel
  „punktierte Achtel = Songtempo × 4/3“ im Prompt.
- **Audio-Tests über BlackHole** beobachten: am 2026-11-08 morgens grün, mittags vier Fehler, abends wieder grün,
  ohne Änderung an SparkCore dazwischen. Siehe Prüfungen.
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
