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
| – | Bereich Stimmgerät (⇧⌘3): MPM plus Phasen-Ausgleichsrechnung, liest den Eingang der Aufnahme mit | 2969085 | installiert (2026-11-08); über USB am MINI mit Gitarre gelaufen (2026-11-09), nicht gegen ein Referenzstimmgerät |
| – | Stimmgerät des Verstärkers (MINI, NEO) als Quelle, „Automatisch“, Bluetooth-Start aus dem Stimmgerät | 15d37b6, 90513b0, 52b85ac | Befehl und Skala mit spark-probe an MINI und NEO geprüft; in Studio vom Nutzer am NEO und MINI benutzt (2026-11-09) |
| – | Schutz des Verstärkers (`AmpGuard`) | 18daf05 | Beschreibung mit 80 Bytes am MINI gehört (2026-11-08) |
| – | Kemper-Import (Backup, Rigs, Performances → Presets und Stücke) und Hashtags mit angehefteten Abschnitten | 00cd11f | installiert (2026-11-10, nur Mac); mit dem Backup des Nutzers gelesen, kein Sound am Spark gehört |
| Phase 2 | Mehrere Geräte: Profile, Geräteauswahl, NEO-Eigenheiten, REACTOR mitlesen, Probe `listen`, Linux | 2fccff5 … 642d2d8 | NEO finden und lesen, Wechsel MINI ↔ NEO vom Nutzer bestätigt (2026-11-09); Rest siehe „Offen“ |

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
  ├── SparkTunerUI     Bereich Stimmgerät; öffentlich nur TunerHost, TunerMenus. Kein eigenes Bluetooth, kein Ton
  ├── SparkDesign      Bausteine (DESIGN.md)
  ├── SparkCore        Aufnahme, Bibliothek, PresetStamp, Stücke, StudioFolders, StudioKeymap,
  │                    Tonhöhenerkennung (PitchDetector, PitchTracker, Tuning, TunerEngine, AudioTap, SharedInput)
  └── SparkControl     Protokoll, Katalog, Preset-Bibliothek, Fingerabdruck, Geräteprofile (DeviceProfile),
                       REACTOR-Meldungen (ReactorState)
```

- **Der Link hängt an einer Transportschicht.** `SparkLink` spricht mit `LinkTransport`: `CoreBluetoothTransport` in der
  App, `SimulatedDevice` in Tests und Fensterbildern (`--library … --demo-devices`). So prüfen Tests das Zurückspringen
  des NEO und dass der REACTOR kein Byte bekommt, ohne Bluetooth.

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

Zweite Quelle, vom Nutzer gewählt: **das Stimmgerät des Verstärkers** (Spark MINI und NEO, unten), damit sich auch der
NEO stimmen lässt, der kein USB-Audio hat. Gröber, auf ganze Cent, und der Verstärker ist dabei stumm.

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
- **Kein eigener Kontakt zum Amp, kein Ton:** SparkTunerUI hängt nicht von SparkControl oder SparkPresetsUI ab, kann
  also weder Bluetooth noch den Link selbst benutzen. Es gibt keine Ausgabe. Das Stimmgerät des Verstärkers kommt nur
  über das Protokoll `AmpTuner` (SparkCore), das Studio mit dem bestehenden Link der Presets erfüllt.

### Das Stimmgerät des Verstärkers (MINI, NEO; 2026-11-09 am Gerät geprüft)

- **Protokoll:** `01 65 C3` schaltet es an, `01 65 C2` aus; MINI und NEO bestätigen mit `04 65` (der MINI ließ die
  Bestätigung fürs Ausschalten einmal von dreimal weg). Solange es an ist, ist der Ausgang stumm (MINI-Lautsprecher und
  NEO-Kopfhörer, vom Nutzer gehört), und es kommt etwa 15-mal je Sekunde `03 64 <ton> CA <float>`: Ton 0 (C) bis
  11 (H), Wert 0 bis 1 über einen Halbton, −1 ohne Signal. Nach dem Ausschalten kommen noch 3–5 Werte nach. Danach
  klingt der Verstärker wieder wie vorher (bei beiden gehört).
- **Skala:** Cent = (Wert − 0,5) · 100 (`SparkProtocol.tunerCents`). Am Rand 0/1 springt der Ton zum Nachbarn, das
  Fenster ist also ein Halbton. Geprüft mit `spark-probe --compare tuner` am MINI gegen die Tonhöhe, die Studio über
  USB misst: E +24 Cent → Median 0,63, A −32 Cent → 0,13 (Steigung 0,009 je Cent), gestimmte Saiten um 0,5. Die
  einzelnen Werte springen um etwa ±10 Cent, besonders beim Anschlag. Der USB-Ton des MINI läuft weiter, während das
  Stimmgerät an ist.
- **Anzeige** (`AmpTunerInterpreter`): Median der letzten 0,4 s, ganze Cent, ein neuer Ton erst nach drei Werten in
  Folge, „Gestimmt“ bei ±3 Cent für 0,5 s, nach dem Signal 1,5 s gehalten. Der Verstärker nennt nur den Ton, nicht
  die Oktave: Die Saite der Stimmung mit diesem Ton gibt sie, wenn es genau eine gibt; bei E in Standard (6. und 1.
  Saite) zeigt die Anzeige nur „E“ ohne Oktave und Hertz. Ein anderer Kammerton als 440 Hz verschiebt die Cent.
- **Wann es an ist:** Der Eingang steht von Haus aus auf **„Automatisch“** (`tunerSource`): Hat das verbundene Gerät
  USB-Audio und steckt es (MINI), hört das Stimmgerät über USB, genauer und ohne den Verstärker stummzuschalten;
  hat es keins (NEO) oder steckt kein Spark per USB, nimmt es das Stimmgerät des Verstärkers. Kommt oder geht ein
  Gerät, wechselt „Automatisch“ mit. Fest wählbar bleiben der Eingang des Decks, „Stimmgerät des Spark NEO/MINI“
  und andere Eingänge. Das Stimmgerät des Verstärkers ist nur an, solange der Bereich vorn und sichtbar ist.
  Zeigt Studio das Stimmgerät vor dem Bereich Presets, startet es die Bluetooth-Verbindung (einmal, wie Presets; nach
  „Trennen“ nicht). Verlassen, anderer Eingang, Trennen über das Deck
  oder einen Gerätewechsel, Beenden der App (`applicationShouldTerminate` wartet bis 1,5 s) schalten es zuerst aus.
  Ohne Bestätigung gilt es als aus, sobald keine Werte mehr kommen; sonst bis zu drei Versuche. Bricht die Verbindung
  ab, während es an ist, schaltet der Link es nach dem Wiederverbinden an oder aus, je nachdem was gewünscht ist (ob
  der Verstärker es ohne Verbindung anlässt, ist ungeprüft). Ein REACTOR bekommt nie etwas, auch hier nicht.
- Werte des Stimmgeräts halten keine laufende Anfrage am Leben (das Warten auf eine Antwort zählt sie nicht).
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
- Geprüft sind der Spark MINI und der Spark NEO (Abschnitt „Geräte“). Andere Spark-Verstärker sind nicht geprüft; der
  REACTOR nimmt Rezepte nur als Text.

## Kemper-Import

Presets ⇒ „Vom Kemper übernehmen …“ (Ablage-Menü und „+“ in der Seitenleiste) liest ein Kemper-Backup
(`.kpabackup`, vom USB-Stick) oder ein Rig (`.kipr`) und macht daraus Spark-Presets und Stücke. Nur lesend: zum
Kemper geht nie etwas, die Datei wird nicht verändert. `--kemper-list <Datei>` zeigt dasselbe auf der Kommandozeile.

- **Format** (`SparkControl/Kemper`): Ein `.kipr` ist ein MIDI-ähnlicher Rahmen (`KThd`/`MThd`, `KTrk`/`MTrk`) mit
  Kemper-SysEx (`00 20 33`): Funktion 02 setzt Parameter ab einer Nummer (14 Bit, 8192 = Mitte), 03 Zeichenketten.
  Ein Backup ist ein tar mit `Rigs/*.kipr` und `repository.kdb` (SQLite: `perflist`, `perfs`, `perfslots`,
  `perftracks`). Die Plätze einer Performance sind dieselben SysEx-Ereignisse ohne Rahmen, ihre Namen
  (Performance 0, Plätze 1–5) stehen als Funktion 07 in `perfs`. Seiten aus Kempers „MIDI Parameter Documentation“
  11.0: 4 Rig (Tempo = BPM × 64), 10 Amp (4 = Gain), 11 EQ (4–7), 50–53 Stomps A–D, 56 X, 58 MOD, 60 DLY, 61 REV,
  75 der alte Hall bis OS 5 (2 an, 3 Mix, 6 Zeit). Die Amp-Zeichenketten stehen in den Dateien sechs höher als in der
  Doku (16 Name, 21 Hersteller, 24 Modell). Effekttypen aus Anhang B (`KemperEffectType`).
- **Platzhalter:** Kempers eigenes „Crunch“ (Amp „Crunch Amp“, Datumsfeld „AmpCreationDateTag“) und Plätze ohne
  Amp-Namen zählen als leer. Unberührte Performances („New Performance“, „Example …“) bietet der Import nicht an.
- **Übersetzung** (`KemperTranslation`): Ein Profil ist eine Aufnahme eines echten Amps, der Spark rechnet mit
  Modellen. Darum: nächstliegender Spark-Amp nach Stichworten in Hersteller, Modell und Rig-Name (erste passende
  Regel, manche erst ab Gain 4; Kempers Decknamen wie „Mars“, „Fan“ stehen mit drin), sonst nach Gain. Gain wie am
  Kemper, Bass/Mitten/Höhen = 5 + Kemper-EQ (−5…+5), die halbe Präsenz in die Höhen, Master 6. Eingeschaltete
  Effekte auf ihre Spark-Plätze; DLY und REV vor einem Delay in MOD oder X. Delay- und Hallpegel = Kemper-Mix × 0,4, zwischen 1 und 4,5: Der Kemper legt sie zum trockenen Signal dazu, sein Mix steht oft ganz oben. Was der Spark nicht hat oder was einen
  belegten Platz träfe, steht unter „Ohne“ und in den Notizen des Presets. Jeder Sound braucht einen Hörtest.
- **Plan** (`KemperImportPlan`): je eigener Performance Song, Basis-Setup, Unterricht oder „Nicht übernehmen“
  (geraten aus dem Namen, im Fenster änderbar), einzelne Rigs zum Anhaken. Gleiche Titel bekommen die Nummer der
  Performance. Ein Sound heißt „Performance · Platz“; gleiche Spark-Sounds (gleicher Fingerabdruck der Kette) sind
  ein Preset mit den Tags aller Stellen.
- **Ergebnis:** Presets mit Tags `kemper`, `clean|crunch|drive`, `song|basis|unterricht` und dem Performance-Namen als
  Hashtag (`CantStop`). Ein zweiter Import ergänzt bei gleichem Namen und gleicher Kette nur die Tags. Songs werden
  über `PresetsHost.onImportSongs` → `RecorderHost.addPieces` Stücke mit Teilen, jedes Teil mit seinem Preset; ein
  schon vorhandener Titel bleibt unverändert. `basis`, `song` und `unterricht` werden beim Import angeheftet.
- Am 2026-11-10 mit dem Backup des Nutzers (Profiler Head, OS 5.4.1) geprüft: 194 Rigs, 32 eigene Performances,
  81 Presets, 20 Stücke. Am Spark angehört ist noch keiner der Sounds.

## Ordnung der Presets: Hashtags

- Ein System statt Ordnern: jedes Preset hat Tags (`PresetFile.tags`, ohne „#“ gespeichert, angezeigt mit „#“).
  Bearbeiten in der Zeile unter dem Editor-Kopf (Eingabe mit oder ohne „#“, mehrere durch Leerzeichen, × entfernt)
  oder per Kontextmenü „Tags“ in der Seitenleiste. Dort auch die Notizen des Presets. Ein Rezept wird dabei zur
  Preset-Datei mit eigener id (`PresetLibrary.updateDetails`), der Sound bleibt unverändert.
- **Seitenleiste:** Abschnitt „Tags“ mit den angehefteten, den gefilterten und den 8 häufigsten Tags als Chips, der
  Rest unter „+ N weitere“. Klick filtert (mehrere = alle müssen passen), Rechtsklick heftet an. Jedes angeheftete
  Tag ist ein eigener Abschnitt, ein Preset kann in mehreren stehen; darunter „Alle auf dem Mac“. Angeheftete Tags
  in UserDefaults `Pinned Preset Tags`.
- **Suche** findet Name, Herkunft, Modelle, Tags und Notizen; „#clean“ sucht nur in Tags.
- Songs mit Tonart, Tempo und Teilen sind die Stücke im Bereich Aufnahme; Presets verweisen nicht zurück auf sie.

## Datenmodell

- **Sound am Take:** `Recording.preset: PresetStamp?` mit `slot` (ab 1, nil = vorübergehend gespielt), `name`,
  `stampedAt`, `sha256`, `device` (Profilname, seit Phase 2) und bei einem nur mitgelesenen Gerät `listened`
  (Beschriftung und Wert) statt Fingerabdruck und Schnappschuss. Der Schnappschuss liegt als Preset-Datei in `Aufnahmen/.presets/<Take-UUID>.json`
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
| überall | R, Leertaste, ⇧⌘1/⇧⌘2/⇧⌘3, ⌘/, ⌘Z/⇧⌘Z (im Bereich vorn), ⌘S (Preset im Editor), ⌘1–⌘8 (verbunden, so viele Plätze das Gerät hat) |
| Aufnahme | L M K F B N T G, ⌘G, 1–5, - + 0, ← → (mit ⇧), ⌫ ⌦ ⌘⌫, ⌘E, ⇧⌘R, ⌘F, Esc |
| Presets | ⌘N, ⇧⌘N, ⌘D, ⇧⌘S, ⌥⌘1–⌥⌘8, ⌘B, ⇧⌘L, ⌘R, ⌃1–⌃7, ⌃0, Pfeile am Regler, ⌘E, ⌘⌫, ⇧⌘R |
| Stimmgerät | ⌘T (Zeiger/Stroboskop), ⌘↑/⌘↓ (Kammerton ±0,1 Hz), ⌘0 (440 Hz), ⌃1–⌃6 (Stimmung); keine Einzeltasten |

Entschieden: ⌘E, ⌘⌫, ⇧⌘R wirken auf Take oder Preset je nach Bereich. ⌘S sichert überall das Preset im Editor (der
Recorder speichert von selbst). ⌘1–⌘4 überall, aber nur bei Verbindung. R überall, auch wenn es der Seitenleiste die
Typ-Auswahl für „r“ nimmt. Esc gehört im Bereich Presets dem Suchfeld. ⇧⌘S nur in Presets, weil es dort ein Sheet
öffnet. ⌘E bleibt Umbenennen; das Design-Canvas zeigte „Exportieren ⌘E“, das hat keine Keycap bekommen. Ob ⌘F das
Suchfeld der Presets fokussiert, ist nicht geprüft, darum steht es nicht in der Liste.

## Geräte

Spark Studio kennt mehrere Geräte aus dem Positive-Grid-Katalog. Jedes hat ein `DeviceProfile` (SparkControl; Linux
`devices.py`): Anzeigename, wie es gefunden wird (Bluetooth-Dienst und -Name, Name aus `02 11`), Plätze und Bänke,
Transport (`sparkBLE`, `midi`, `textOnly`), Fähigkeiten und Eigenheiten. Die Bereiche lesen Plätze und Fähigkeiten
aus dem Profil; ein weiteres Gerät (Spark 40, GO, 2, LIVE, NEO Core) kommt als weiteres Profil dazu, erst nach einer
Prüfung mit dem Nutzer.

| Profil | Plätze | Fähigkeiten | Eigenheiten | Geprüft |
|---|---|---|---|---|
| Spark MINI | 4 | alles: lesen, umschalten, vorübergehend spielen, live ändern, Modellwechsel, speichern, Tasten, Stimmgerät, Tap, USB-Audio | behält den vorübergehenden Sound beim Trennen? ungeprüft, gilt als „nein“ | 1.11.2.75 |
| Spark NEO | 4 | wie MINI, ohne USB-Audio; Stimmgerät geprüft, Tap ungeprüft | verwirft den vorübergehenden Sound beim Trennen | 1.16.1.60 |
| REACTOR 50 | 8 (Rot 1–4, Grün 1–4) | nur mitlesen, Tasten, Stimmgerät, Tap, USB-Audio (Name noch nicht abgelesen), Text to Tone | darf nichts bekommen | nur mitgelesen |
| REACTOR 100 | 8 | wie der 50 | | ungeprüft |
| unbekanntes Spark (FFC0) | 4 | nur lesen und umschalten | | – |

Keines bestätigt einen Parameter (`04 04`); der Editor wartet darauf nie, ein Zurücklesen nach einer Pause zeigt, ob er
ankam. Die Drosselung bleibt wie beim MINI.

### Erkennen und wechseln

- **Suche nur nach FFC0 und FFD0.** Andere Bluetooth-Geräte sieht die App nie. FFD0 ist ein REACTOR, erkannt ohne
  Anfrage. Ein Spark wird am Bluetooth-Namen vorläufig erkannt und nach dem Verbinden am Namen aus `02 11` bestätigt
  („Spark NEO“, „Spark MINI“); ein unbekannter Name behält das vorsichtige Profil.
- **Gemerkt per Kennung.** Bekannte Geräte und das zuletzt gewählte stehen in UserDefaults (`Known Devices`,
  `Chosen Device`) mit ihrer `CBPeripheral.identifier`, damit zwei gleiche Geräte unterscheidbar bleiben. Verbunden
  wird nur mit dem gewählten; ohne Wahl mit dem ersten gefundenen. Eine Testbibliothek hat eigene Einstellungen.
- **Eine Steuerverbindung zur Zeit.** Die Geräteauswahl („Gerät“, erster Abschnitt der Seitenleiste) trennt die alte
  Verbindung, dann verbindet sie die neue. Spielt etwas Ungespeichertes vorübergehend auf einem Gerät, das es beim
  Trennen verliert, fragt Studio vorher („Der Sound auf dem NEO geht beim Trennen verloren. Vorher als Preset
  sichern?“), ebenso bei „Trennen“.
- **Bluetooth auf Abruf** wie bisher; beim Start keine Suche.
- **Namen in Logs:** Der REACTOR heißt per Bluetooth „Reactor 50 …“ mit einem Zusatz seines Besitzers. Die App zeigt
  ihn an, schreibt ihn aber in kein Log (`DeviceProfile.loggableName`); Take-Stempel tragen den Profilnamen.

### Spark NEO (2026-11-09 mit spark-probe geprüft, Hörbestätigung durch den Nutzer)

Kabelloses Kopfhörersystem: Kopfhörer plus Funksender an der Gitarre. Bluetooth-Name „Spark NEO Control“, Dienst FFC0
mit FFC1 (read, write, write without response) und FFC2 (read, notify), Name aus `02 11` „Spark NEO“, Firmware
1.16.1.60, 4 Plätze (Werkspresets CLEAN, CRUNCH, SOLO, HI GAIN). Preset-Format wie beim MINI (7 Effekte, 399–424
Bytes, Byte für Byte gleich zurückkodiert, Trailer `CA C1 E8 00 00 CA 3F 00 00 00 xx`); alle 16 Modelle der
Werkspresets stehen im Katalog.

- Gehört: Umschalten (`01 38` → `04 38`, danach `03 10`), ganzes Preset auf 7F (16 Teile, je `05 01`, dann `04 01`),
  Parameter (`01 04` mit Eingangsbyte, keine Bestätigung, Zurücklesen zeigt den Wert), an/aus (`04 15`),
  Modellwechsel (`04 06`, eigene Startwerte gleich den MINI-Werten, geprüft an TS9), Speichern auf Platz 4 und
  Zurückspielen des Originals Byte für Byte.
- Lesen braucht manchmal den zweiten Versuch; das bestehende Nachfragen reicht.
- **Texte nur so lang wie gehört:** Der NEO hat nur Namen bis 12 Bytes (Werkspresets ≤ 7, die Probe-Kopien „SOLO Test“
  und „HI GAIN Test“) und nie eine Beschreibung gespielt. Das Profil hat darum `checkedText`: Vor dem Senden kürzt
  `AmpGuard.prepared(_:for:)` den Namen auf 12 Bytes (an einer Zeichengrenze), lässt die Beschreibung weg und setzt
  Version „0.7“ und Icon „icon.png“. Der Klang bleibt gleich; ein gespeicherter Platz trägt dann den gekürzten Namen.
  Längere Texte erst nach einer Prüfung mit dem Nutzer (Kopfhörer nicht am Ohr).
- Die mittlere Taste schaltet weiter (3 → 4 → 1) und meldet `03 38` mit dem Platz (`F0 01 50 02 03 38 00 00 02 F7`);
  Studio folgt wie bei der Preset-Taste des MINI. + und − melden nichts.
- **Trennen verwirft den vorübergehenden Sound**, danach spielt der gespeicherte Platz (gehört und zurückgelesen).
  Studio setzt dann `tryingOut`/`isEditingLive` zurück, meldet es (auch der Aufnahme; ein laufender Take behält
  seinen Stempel vom Beginn) und liest beim nächsten Verbinden nach, statt den Editor-Stand von selbst neu zu senden.
  Nur eine Verbindung, die von selbst zurückkommt, bekommt den bearbeiteten Stand wieder.
- USB-C: Der Kopfhörer zeigte am Mac kein Audio- oder MIDI-Gerät, nur einen USB-2.0-Hub (Genesys 05e3:0608) ohne
  Gerät dahinter, vermutlich für Firmware-Updates (nicht ausprobiert). Der Bereich Aufnahme bietet den NEO nicht an.
  Ein Take mit dem NEO als Klanggeber über einen anderen Eingang trägt trotzdem den Gerätenamen im Stempel.
- **Stimmgerät** (`01 65`): geprüft, siehe „Das Stimmgerät des Verstärkers“. Beide Befehle bestätigt, Kopfhörer stumm,
  danach wieder Ton.
- **Funksender** (USB-C am Mac): meldet sich als „Low Latency MIC“ (Telink, 248a:9218) mit den Klassen 7/1 und HID,
  ohne Audio-Gerät. Aufnahme vom NEO bleibt darum ohne USB. Die Gegenprobe (Ausstecken, Gerät verschwindet) ist nicht
  bestätigt.
- Nicht geprüft: Tap-Tempo und Delay mit sync = BPM, Batteriestand, USB-C mit
  sicherem Datenkabel und des Funksenders, Texte länger als die der Werkspresets (höchstens 7 Bytes Name, keine
  Beschreibung), der NEO Core.
- Sicherung aller vier Plätze vom 2026-11-09: `~/Music/Spark Studio/Sicherungen/Spark NEO 2026-11-09/`, außerhalb der
  Bibliothek, nur zum Zurückspielen, wird nicht verändert.

### REACTOR 50 (2026-11-09 nur mitgehört, nie etwas gesendet)

Combo-Amp, eigene Produktlinie und eigene App. Handbuch beim Nutzer:
`~/Desktop/reactor/REACTOR_50_100_User_Manual_English_.pdf` (englisch, 50 und 100).

- **USB-C:** USB-Audiogerät mit 1 Eingang und 2 Ausgängen, 48 kHz, 24 Bit; der Eingang trägt den fertigen Klang mit
  allen Effekten. Daneben ein serieller Anschluss „PG Virtual Com“ (Firmware-Programm) und eine Espressif-JTAG-
  Schnittstelle (kann den Chip zurücksetzen): **nie öffnen, auch nicht zum Auflisten.** Kein USB-MIDI. Handbuch: USB
  anstecken, solange der REACTOR aus ist. Der genaue USB-Audioname ist noch nicht abgelesen; bis dahin steht er nicht
  im Profil, und die Aufnahme nimmt nicht vom REACTOR auf (`InputPolicy.usbDevices(named:)` mit den Namen der
  Profile ersetzt das feste „spark“).
- **Bluetooth:** A2DP für Musik und BLE für die Steuerung: Dienst FFD0, Hersteller-ID 295D, FFC1 (write without
  response), FFC2 (read, notify). Die Nachrichten sind Spark-Rahmen (`F0 01 … F7`, 7-Bit-Packung, Texte und Floats wie
  beim MINI).
- **Was er von sich aus meldet** (`ReactorState`, Linux `devices.ReactorState`):

| Bedienelement | Meldung | Bemerkung |
|---|---|---|
| Gain | `03 37` Amp.Preamp Parameter 0 | 0–1, dazu `03 1A 91 00 02 C3` |
| Bass, Middle, Treble | `03 37` Amp.Tonestack Parameter 1, 2, 3 | bis ~8 Meldungen pro Sekunde |
| Master | `03 37` Amp.Poweramp Parameter 0 | dazu `03 1A` |
| Amp-Wahlschalter, Push/Smooth, Heat | `03 B1 <amp> <5 × Schalter + Heat>` | Amp 0–5 Clean, Warm, Grit, Crunch, Hi-Gain, Extreme; Schalter 0 Push, 1 Standard, 2 Smooth; Heat 0–4 (Mitte 2). Kein `03 06` |
| FX Level | `03 37` Parameter 0 des ausgewählten Effekts | zweimal kam nichts, später zuverlässig; Ursache offen |
| FX-Knöpfe | an/aus `03 15 <modell> C3/C2`; Auswahl `03 B3 <kettenplatz> C3` | Plätze Gate 0, Comp 1, Drive 2, (Amp 3), Mod 4, Delay 5, Reverb 6 |
| TAP | `03 63 CA <float>` = BPM | dazu DelayEchoFilt Parameter 4 = 1,0 |
| Preset (kurz) | `03 38 00 <platz>`, meist doppelt | 0–7 absolut, im Kreis innerhalb der Bank. Kein Preset-Inhalt |
| Bank (kurz) | `03 38 00 <platz>`, einfach | jede Bank merkt sich ihren Platz; einmal kam ein Wechsel mehr als gezählt |
| Volume | nichts | außerhalb des Presets |
| Bank halten = Stimmgerät | `03 65 C3`, laufend `03 64 00 CA <float>` (−1 ohne Signal), `03 65 C2` | Ausgang stumm |

  Modelle in den Werkspresets: bias.noisegate, BBEOpticalComp, DistortionTS9, DelayEchoFilt (im Katalog; ihr Platz
  kommt daher), ChorusCloner, MonoReverb (nicht im Katalog; ihr Platz kommt aus `03 B3` nach dem Einschalten), der
  Amp als drei Blöcke Amp.Preamp, Amp.Tonestack, Amp.Poweramp. Daraus folgt nicht, dass ein Spark-Preset passt.
- **In Studio:** Verbinden, FFC2 abonnieren, nichts schreiben. Der Transport hält für ein Profil ohne `.send` gar
  kein Merkmal zum Schreiben, und `SparkLink.write` verweigert es zusätzlich (Test `testTheREACTORGetsNotASingleByte`,
  Linux `test_the_reactor_gets_not_a_single_byte`). Der Bereich Presets zeigt die Bänke und ein REACTOR-Feld mit
  Anzeigen statt Reglern; nach einem Platzwechsel ist alles außer dem Platz unbekannt. Unbekannte Meldungen
  (`03 1A` u. a.) werden gezählt, nicht gedeutet. Ein Take hält Gerät, Platz, Amp, Push/Smooth/Heat, Regler und
  Effekte als `PresetStamp.listened` fest, ohne Fingerabdruck und Schnappschuss; der Inspektor zeigt „Mitgelesen“.
- **Stimmgerät:** Das REACTOR-Feld zeigt an/aus und den Rohwert aus `03 64`. An die Anzeige des Bereichs
  Stimmgerät ist es nicht gehängt: Die Skala des Werts ist unbekannt, und die Anzeige verspricht 0,1 Cent.
- **Text to Tone:** Editor „⋯ → Text für REACTOR kopieren“ (wie `--recipe-prompt`); der REACTOR deutet den Text selbst.
- **Offen:** Bedeutung von `03 1A 91 00 02 C3`; Power Control (50/25/1 W); PAIR; Expression-Pedal; Wah, EQ und
  FX-Loop; der zusätzliche Bank-Wechsel; warum FX Level zweimal schwieg; ob der REACTOR auf irgendetwas antwortet;
  USB-Audioname und Latenz; Firmware.

Aus dem Handbuch (nicht am Gerät geprüft): 8 Plätze. Preset tippen = weiter, halten = speichern. Bank tippen = Bank
wechseln, halten = Stimmgerät. FX-Knöpfe tippen = auswählen, halten = an/aus. 8 Effekte (Gate, Wah/Volume, Comp,
Drive, Mod, Delay, EQ, Reverb) plus FX-Loop; Kette Gate → Comp → Drive → Wah → EQ → [Amp] → Mod → Delay → Reverb →
FX-Loop. MIDI nur über 5-Pol-DIN, Kanal 1: CC an/aus 0 Gate, 1 Comp, 2 Drive, 3 Wah, 4 EQ, 5 Delay, 6 Mod, 7 Reverb,
10 FX-Loop; CC 21–26 Amp Clean bis Extreme; CC 27 Push, 28 Smooth, 12 Heat+, 13 Heat−; Program Change 0–7 = Rot 1–4,
Grün 1–4; CC 15 Bank; CC 30 Ausgangs-, 31 Line-Out-, 32 Send-Lautstärke; CC 35 Stimmgerät, CC 36 Tap. MIDI In und
der REACTOR-Control-Fußschalter schließen sich aus. Der Nutzer möchte ohne MIDI-Interface auskommen.

### REACTOR: senden, später und nur mit dem Nutzer am Gerät

Der Nutzer will seine Sounds aus Studio auch auf den REACTOR bringen (2026-11-10). In Studio ist nichts davon
gebaut; `spark-probe ask <firmware|name|slot|current>` sendet genau eine Leseanfrage pro Lauf. Der Weg, jeder Schritt
mit seinem Okay:

1. Eine einzige Leseanfrage (`02 11` Name oder `02 2F` Firmware), Gerät leise, Kopfhörer nicht am Ohr. Antwortet er
   im Spark-Format, ist das ein Befund, sonst Schluss.
   **Erledigt am 2026-11-10 mit Okay des Nutzers** (`spark-probe ask firmware`, eine Nachricht mit Blockkopf über
   FFC1): Nach 0,09 s kam `03 2F CE 00 01 04 55`, ohne Blockkopf, also Firmware 0.1.4.85 im Spark-Format. Der
   REACTOR beantwortet Leseanfragen.
2. Höchstens `02 10` (aktueller Platz) und `02 01` (Preset lesen), um das REACTOR-Preset-Format kennenzulernen. Nur
   lesen, mit dem Nutzer auswerten.
3. Erst wenn das Format verstanden und mit Sicherung belegt ist: Umschalten (`01 38`) und Parameter, einzeln mit
   Okay. Nie ein Spark-Preset an den REACTOR. `AmpGuard` bekommt eigene REACTOR-Grenzen, bevor mehr als ein Umschalten
   gesendet wird. Dann bekommt das Profil `.send` und das Nötige, und der Test „schreibt nichts“ wird ersetzt.
- MIDI (DIN, Tabelle oben) bleibt die Alternative, falls ein Interface kommt: ein vom Nutzer gewählter MIDI-Ausgang,
  Program Change 0–7, die an/aus-CCs, Tap. Lautstärke-CCs (30–32) nie sprunghaft lauter und nur auf ausdrücklichen
  Wunsch.
- Kein Mitschneiden des Verkehrs der REACTOR-App am Handy.
- Nie zu folgenden Tastengriffen anleiten: REVB + TAP beim Einschalten (Werksreset), TAP + MOD halten
  (Expression-Kalibrierung), Preset halten (überschreibt den Platz), PAIR halten. Bei Bedienschritten sagen, dass
  Preset nur angetippt wird. Firmware-Updates nie unterbrechen und nie aus Studio anstoßen.

### Werkzeuge

- `spark-probe scan` zeigt das erkannte Profil, `--device <name>` wählt unter mehreren Geräten. Nur `listen` verbindet
  sich mit einem Gerät, dessen Profil nichts bekommen darf.
- `spark-probe tuner <sekunden>` schaltet das Stimmgerät des Verstärkers an (`01 65 C3`), sammelt die Werte und
  schaltet es aus (`01 65 C2`). Mit `--compare` hört es dazu den USB-Eingang des Spark (nur lesen, ohne Ratenwechsel,
  nichts gespeichert): 8 s vorher, währenddessen, 8 s nachher, je Ton Median in Cent und Median des Werts. Das
  App-Bündel hat dafür einen Mikrofon-Hinweis.
- `spark-probe listen <sekunden>` findet Geräte mit FFC0 oder FFD0, abonniert nur FFC2 und hat keinen Code, der
  schreibt. Am Ende je Parameter Anzahl, Spanne, erster und letzter Wert, sonst Meldungen mit Zeitpunkt. Der
  Namenszusatz des REACTOR wird weggekürzt. Die Aufnahme läuft erst ab der Zeile „Listening …“, darum die
  Bedienschritte erst danach.
- Aus einer Claude-Code-Sitzung im Desktop-Programm stürzt ein nackter spark-probe beim Bluetooth-Zugriff ab (TCC
  rechnet ihn Claude zu). `Tools/probe-app.sh <argumente>` legt ihn in ein App-Bündel (Info.plist aus
  `Resources/SparkProbe-Info.plist` plus `CFBundleExecutable`, `CFBundlePackageType APPL`, `LSUIElement`, ad hoc
  signiert) und startet es mit `open -W -n --stdout … --stderr …`.

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

Für jedes Gerät, ohne Ausnahme:

- Die Grenzen gelten für den NEO genauso und werden für kein Gerät angehoben. Beim NEO sitzt der Lautsprecher am Ohr:
  Am NEO nie eine neue Variante des Datenformats senden (längere Texte, neue Felder, unbekannte Befehle), auch nicht
  zum Ausprobieren und nicht „leise“. Eine Prüfung, die etwas Neues sendet, braucht das Okay des Nutzers, und der
  Kopfhörer liegt dabei nicht auf dem Ohr. Heult es: sofort Ein/Aus oder den Kopfhörer abnehmen.
- Keine Serien von Modellwechseln: höchstens 8 mit 1 s Pause, Abbruch beim ersten `03`-Echo statt `04` (etwa 40
  schnelle Wechsel haben den MINI einmal aufgehängt).
- Vor jeder Arbeit am Gerät alle Plätze sichern (`spark-probe backup <ordner>`), einen Platz nur mit Okay überschreiben.
- Nur eine Steuerverbindung: Studio, spark-probe und die Handy-App blockieren sich. Vor jedem Probe-Lauf Studio und
  die Handy-App trennen lassen.
- REACTOR: nichts senden, über keinen Weg (BLE, USB-Seriell, JTAG, MIDI), bis „senden“ oben mit dem Nutzer erledigt
  ist. Das Profil hat kein `.send`, der Link und der Transport verweigern jedes Byte.
- Modelle, die nur ein Gerät kennt, kommen erst nach einer Prüfung am Gerät in den Katalog (`spark-probe
  catalog-check`, in Achterpaketen). `checkedOn` im Katalog ist eine Liste (MINI 1.11.2.75, NEO 1.16.1.60).

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
  - Stimmgerät des Verstärkers: `AmpTunerInterpreterTests` (Median springender Werte, Ausreißer beim Anschlag, E ohne
    Oktave, Kammerton, Nachbarton, Gestimmt, Halten), `AmpTunerLinkTests` (eine Nachricht an, eine aus; Trennen schaltet
    zuerst aus; nach einem Abbruch wie gewünscht; Aus ohne Antwort; Beenden wartet; REACTOR bekommt nichts; Werte
    halten keine Anfrage am Leben), `TunerModelTests` (an nur, solange der Bereich vorn ist; aus, wenn der Verstärker
    weg ist; „Automatisch“ nimmt beim NEO sein Stimmgerät, beim gesteckten MINI USB und folgt dem Gerät). Fensterbild `docs/pictures/stimmgeraet-verstaerker-*` mit einem erfundenen Verstärker angesehen.
- Geräte (synthetisch, `SimulatedDevice` und `fake_amp.py`): `DeviceProfileTests` (Profile, Erkennung, Namen in
  Logs, Bänke, USB-Namen), `ReactorDecoderTests` (die Byte-Folgen der Tabelle oben, auch die NEO-Taste),
  `SparkLinkTests` (NEO gefunden, benannt und gelesen; Zurückspringen beim Trennen und Nachlesen; mittlere Taste;
  Parameter ohne Warten; REACTOR bekommt kein Byte, auch nicht auf Lese-, Umschalt-, Sende- und Speicheranfragen;
  unbekanntes Spark nur lesen und umschalten; Gerätewechsel trennt erst und merkt sich die Kennung; Nachfrage vor
  dem Verlust), `StudioKeymapTests` (⌘1–⌘8 und ⌥⌘1–⌥⌘8 ohne Doppelbelegung). Linux: `tests/test_devices.py`
  dasselbe, dazu der Text für REACTOR Byte für Byte wie auf dem Mac.
- Fensterbilder mit Geräteauswahl (NEO) und REACTOR-Feld in Hell und Dunkel (`docs/pictures/geraete-*`), mit
  simulierten Geräten, angesehen.
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

- **Zurücklesen nach dem Speichern** verglich auf dem Mac bis 2026-11-09 das ganze Preset samt Prüfsummenbyte; ein
  neu gebautes Preset hätte darum nie als angekommen gegolten. Jetzt wie unter Linux ohne das Prüfsummenbyte
  (`PresetEditor.sameContent`). Am Gerät mit Studio noch nicht gespeichert.
- **Phase 2 am Gerät prüfen**, Schritt für Schritt mit dem Nutzer, Fragen im Chat. Bestätigt am 2026-11-09: Studio
  findet den NEO, zeigt „Spark NEO“ und 1.16.1.60 und liest vier Plätze; Wechsel MINI ↔ NEO. Noch offen: Editor am NEO
  (Parameter, an/aus, ein Modellwechsel) und Trennen setzt die Anzeige zurück; Speichern aus dem Editor (mit Okay
  und Sicherung); ob der MINI beim Trennen den vorübergehenden Sound behält (dann Profil anpassen); REACTOR mitlesen
  (Gain bis Master, Amp, Push/Smooth, Heat, FX-Knöpfe, FX Level, TAP, Preset, Bank, Stimmgerät; dabei FX Level und
  den zusätzlichen Bank-Wechsel klären); REACTOR aufnehmen (USB-Audioname ablesen und ins Profil, Pegel, Latenz, ein
  Take mit mitgelesenem Stempel).
- **Linux:** Geräteauswahl als Menü „Verstärker → Gerät“, ohne Lämpchen in der Seitenleiste; kein REACTOR-Feld (die
  Seitenleiste zeigt seine Bänke, mitgelesen wird im Kern). Die UI-Tests mit PySide6 laufen nur auf linux-host.

- **Stimmgerät des Verstärkers in Studio:** Am 2026-11-09 vom Nutzer benutzt: am NEO nach Wahl im Eingang, am MINI
  mit „Automatisch“, nachdem Presets die Verbindung gestartet hatte. Daraus entstanden „Automatisch“ als Grundeinstellung
  und der Bluetooth-Start aus dem Stimmgerät. Noch zu bestätigen: Start direkt ins Stimmgerät findet das Gerät;
  Bereich verlassen und Beenden mit ⌘Q geben den Ton zurück; ob der Verstärker es nach einem Verbindungsabbruch
  anlässt. Linux hat es noch nicht (dort fehlt der Bereich Stimmgerät ganz).
- **Stimmgerät mit echter Gitarre:** Über USB am MINI lag der Pegel beim Vergleich am 2026-11-09 bei −31 bis −36 dBFS,
  die Schwelle −60 dBFS passt also; die Werte über USB blieben auf wenige Cent ruhig. Noch offen: gegen ein
  Referenzstimmgerät (Strobe oder Clip-on mit 0,1 Cent) an allen Saiten, auch Drop D und ein Bass bis H0; ob „Gestimmt“
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
- **Bibliothek der Presets:** Gruppen sind seit 2026-11-10 angeheftete Hashtags (Abschnitt „Ordnung der Presets“).
  Offen: Zuordnen durch Ziehen, Favoriten und Bewertung in der Oberfläche, Sortierung, Export, Versionsverlauf pro
  Preset; in Stücken nach Tonart und Tempo filtern.
- **Kemper-Import:** Die übersetzten Sounds am Spark anhören und die Amp-Regeln danach verbessern (vor allem
  Dream Weaver, Divided by 13, Naylor). Die Linux-App kann den Import und die Hashtags noch nicht.
- **Setlists und Auftrittsmodus** bauen auf den Stücken auf: Reihenfolge per Drag & Drop, großer Vollbildmodus mit
  Umschalten per Pfeiltasten, Leertaste und Zahlen, nächster Song oder Teil per Taste. Optional „Setlist auf den Amp“:
  bis zu vier Presets auf die Plätze, mit Nachfrage und Sicherung wie beim Speichern auf einen Platz.
- **Alte Apps:** Spark Recorder und Spark Presets sind aus dem Projekt entfernt, ihre installierten Kopien liegen seit
  2026-11-07 im Papierkorb und sind aus dem Dock genommen. Die alten Ordner `~/Music/Spark Recorder` und
  `~/Music/Spark Presets` sind unverändert da; Studio liest sie nicht mehr. Ob und wann sie gelöscht werden, entscheidet
  der Nutzer.
