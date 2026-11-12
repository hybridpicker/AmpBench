"""German texts of the window (`ui/`). Key: the English text in the code."""

GERMAN_UI: dict[str, str] = {
    # The "+" menu of the sidebar, word for word as on the Mac
    "Empty preset":
        "Leeres Preset",
    "From template …":
        "Aus Vorlage …",
    "AI Sound …":
        "KI-Sound …",
    "Duplicate current":
        "Aktuelles duplizieren",
    # AI Sound (sound_ai.py, ui/ai_sound_dialog.py), word for word as on the Mac
    "Connect the amp to hear the suggestion.":
        "Verbinde den Verstärker, um den Vorschlag zu hören.",
    "Blues crunch for my Telecaster":
        "Blues-Crunch für meine Telecaster",
    "Clean funk with bite":
        "Cleaner Funk mit Biss",
    "Warm jazz sound":
        "Warmer Jazz-Sound",
    "AI Sound":
        "KI-Sound",
    "Paste the API key":
        "API-Schlüssel einfügen",
    "Cancel":
        "Abbrechen",
    "Connect":
        "Verbinden",
    "e.g. “U2 – Where the streets have no name”":
        "z. B. „U2 – Where the streets have no name“",
    "Load models":
        "Modelle laden",
    "Asks ollama.com for the models it offers right now (without the key).":
        "Fragt ollama.com nach den Modellen, die es gerade gibt (ohne Schlüssel).",
    "Remove key":
        "Schlüssel entfernen",
    "Create suggestions":
        "Vorschläge erstellen",
    "{} of {} characters":
        "{} von {} Zeichen",
    "Clear history":
        "Verlauf löschen",
    "Loading the models from ollama.com …":
        "Lade die Modelle von ollama.com …",
    "Other description":
        "Andere Beschreibung",
    "New suggestions":
        "Neue Vorschläge",
    "Cancel request":
        "Anfrage abbrechen",
    "Close":
        "Schließen",
    "“{}” – every suggestion appears as soon as it is ready. “Listen” plays it on the amp, nothing is stored. The buttons below refine only that suggestion. Only “Keep” puts it into your library.":
        "„{}“ – jeder Vorschlag erscheint, sobald er fertig ist. „Anhören“ spielt ihn am Verstärker, gespeichert wird nichts. Die Knöpfe darunter bessern nur diesen Vorschlag nach. Erst „Behalten“ legt ihn in deine Bibliothek.",
    "Suggestion {}":
        "Vorschlag {}",
    "Listen":
        "Anhören",
    "Keep":
        "Behalten",
    "Connect to Ollama Cloud":
        "Mit Ollama Cloud verbinden",
    "AI Sound needs an Ollama API key. You get one for free with an Ollama account.":
        "Für KI-Sound braucht AmpBench einen Ollama-API-Schlüssel. Du bekommst ihn kostenlos mit einem Ollama-Konto.",
    "The key is kept in your desktop's keyring (otherwise in a file only you can read) and is sent only to Ollama (ollama.com) when you have a sound created.":
        "Der Schlüssel liegt im Schlüsselbund deines Desktops (sonst in einer Datei, die nur du lesen kannst) und wird nur an Ollama (ollama.com) gesendet, wenn du einen Sound erzeugen lässt.",
    "Describe the sound in your own words – a song, a band, a mood. You get three different suggestions, listen to them on the amp, refine them and keep only what you like.":
        "Beschreibe den Sound mit eigenen Worten – ein Song, eine Band, eine Stimmung. Du bekommst drei verschiedene Vorschläge, hörst sie am Verstärker an, besserst nach und behältst nur, was dir gefällt.",
    "Ideas to click":
        "Ideen zum Anklicken",
    "Model":
        "Modell",
    "Advanced":
        "Erweitert",
    "Only your text goes to Ollama (ollama.com) – no presets, names or device data.":
        "Nur dein Text geht an Ollama (ollama.com) – keine Presets, Namen oder Gerätedaten.",
    "Asked for recently":
        "Zuletzt gewünscht",
    "The list could not be loaded: {}":
        "Die Liste ließ sich nicht laden: {}",
    "Available: {}":
        "Verfügbar: {}",
    "Listen to the suggestions":
        "Hör dir die Vorschläge an",
    "Create a key at ollama.com/settings/keys":
        "Schlüssel auf ollama.com/settings/keys erstellen",
    "Cancelled.":
        "Abgebrochen.",
    "Again":
        "Nochmal",
    "playing":
        "spielt",
    "Tip: {}":
        "Tipp: {}",
    "Make this suggestion {}, the rest stays":
        "Diesen Vorschlag {} machen, der Rest bleibt",
    "being adjusted …":
        "wird angepasst …",
    "adjusted: {}":
        "angepasst: {}",
    "{}: being written …":
        "{}: wird geschrieben …",
    "No suggestion came back. Try again.":
        "Es kam kein Vorschlag zurück. Versuch es noch einmal.",
    "AI Sound from a description …":
        "KI-Sound aus Beschreibung …",
    "“{}” is ready.":
        "„{}“ ist bereit.",
    "Note: {}":
        "Hinweis: {}",

    # The deck
    "Ready": "Bereit",
    "R · RECORD": "R · AUFNAHME",
    "Clipping": "Übersteuert",
    "No signal": "Kein Signal",
    "Check input": "Eingang prüfen",
    "Stop checking": "Prüfung beenden",
    "Checking input": "Prüfe Eingang",
    "Connected": "Verbunden",
    "Input": "Eingang",
    "Level": "Pegel",
    "Source": "Quelle",
    "File": "Datei",
    "Click": "Klick",
    "Click, count-in and\nRetro recording follow.": "Klick, Einzähler und\nRetro-Aufnahme folgen.",
    "Recording": "Aufnahme",
    "{}-bit": "{} Bit",
    "Mono": "Mono",
    "Stereo": "Stereo",
    "{} channels": "{} Kanäle",
    "{} s": "{} Sek.",
    "{} min": "{} Min.",
    "{} h {} min": "{} Std. {} Min.",

    # Areas, menus and the window
    "View": "Darstellung",
    "Record": "Aufnahme",
    "Presets": "Presets",
    "Language": "Sprache",
    "System": "System",
    "The language changes after you restart AmpBench.": "Die Sprache wechselt nach einem Neustart von AmpBench.",
    "New from template …": "Neu aus Vorlage …",
    "New from template": "Neu aus Vorlage",
    "Template:": "Vorlage:",
    "Duplicate": "Duplizieren",
    "Save": "Sichern",
    "Save as …": "Sichern unter …",
    "Save as": "Sichern unter",
    "Rename …": "Umbenennen …",
    "Rename": "Umbenennen",
    "Save as recipe …": "Als Rezept speichern …",
    "Save as recipe": "Als Rezept speichern",
    "Open recipe …": "Rezept öffnen …",
    "Open recipe": "Rezept öffnen",
    "Sound recipe (*.json)": "Sound-Rezept (*.json)",
    "Import from Kemper …": "Vom Kemper übernehmen …",
    "Import from Kemper": "Vom Kemper übernehmen",
    "Edit tags …": "Tags bearbeiten …",
    "Edit tags": "Tags bearbeiten",
    "Show in file manager": "Im Dateimanager zeigen",
    "Move to Trash": "In den Papierkorb legen",
    "Quit": "Beenden",
    "Edit": "Bearbeiten",
    "Undo": "Rückgängig",
    "Redo": "Wiederholen",
    "Compare with the saved state": "Mit dem gesicherten Stand vergleichen",
    "Discard changes": "Änderungen verwerfen",
    "Search takes": "Aufnahmen durchsuchen",
    "Amp": "Verstärker",
    "Connect to the amp": "Mit dem Verstärker verbinden",
    "Disconnect": "Trennen",
    "Read the amp again": "Verstärker neu lesen",
    "Live on the amp": "Live am Verstärker",
    "Device": "Gerät",
    "Play {}": "{} spielen",
    "Store on {} …": "Auf {} speichern …",
    "Store on {} … (now “{}”)": "Auf {} speichern … (jetzt „{}“)",
    "Chain": "Kette",
    "Select {}": "{} wählen",
    "Selected unit on or off": "Gewählte Einheit ein oder aus",
    "Needle or strobe": "Zeiger oder Stroboskop",
    "Concert pitch higher": "Kammerton höher",
    "Concert pitch lower": "Kammerton tiefer",
    "Concert pitch 440 Hz": "Kammerton 440 Hz",
    "Help": "Hilfe",
    "Keyboard shortcuts": "Tastenkürzel",
    "Ctrl+/  Keyboard shortcuts": "Strg+/  Tastenkürzel",
    "About AmpBench": "Über AmpBench",
    "AmpBench {} ({}) for Linux": "AmpBench {} ({}) für Linux",
    "The Presets area of the Mac app: read the amp, edit presets, hear them live and save them.":
        "Der Bereich Presets der Mac-App: Verstärker lesen, Presets bearbeiten, live hören und sichern.",
    "Catalog: {}": "Katalog: {}",

    # Keyboard shortcuts
    "Space": "Leertaste",
    "Ctrl+F": "Strg+F",
    "K / Backspace": "K / Rücktaste",
    "Ctrl+1 – 4": "Strg+1 – 4",
    "Ctrl+Z / Shift+Ctrl+Z": "Strg+Z / Umschalt+Strg+Z",
    "Ctrl+Z": "Strg+Z",
    "Ctrl+S": "Strg+S",
    "Shift+Ctrl+S": "Umschalt+Strg+S",
    "Ctrl+N / Shift+Ctrl+N": "Strg+N / Umschalt+Strg+N",
    "Ctrl+D": "Strg+D",
    "Ctrl+Alt+1 – 4": "Strg+Alt+1 – 4",
    "Ctrl+B": "Strg+B",
    "Shift+Ctrl+L": "Umschalt+Strg+L",
    "Ctrl+R": "Strg+R",
    "Ctrl+E": "Strg+E",
    "Ctrl+Backspace": "Strg+Rücktaste",
    "Shift+Ctrl+R": "Umschalt+Strg+R",
    "⇧Ctrl+R": "⇧Strg+R",
    "Ctrl+/": "Strg+/",
    "Ctrl+0": "Strg+0",
    "Ctrl+T": "Strg+T",
    "Arrows on a knob": "Pfeile am Regler",
    "Start or stop recording": "Aufnahme starten oder beenden",
    "Start or stop recording (R)": "Aufnahme starten oder beenden (R)",
    "Play or pause; while recording: stop and play":
        "Abspielen oder anhalten, während der Aufnahme: beenden und abspielen",
    "Loop A, B, clear / add a marker": "Schleife A, B, löschen / Marker setzen",
    "Rating / favorite": "Bewertung / Favorit",
    "Search": "Suchen",
    "Keep take / move to Trash": "Take behalten / in den Papierkorb",
    "Jump 5 seconds, with Shift 1 second": "5 Sekunden springen, mit Umschalt 1 Sekunde",
    "Slower, faster / reset tempo and pitch": "Langsamer, schneller / Tempo und Ton zurücksetzen",
    "Play a slot on the amp": "Platz am Verstärker spielen",
    "Undo / Redo": "Rückgängig / Wiederholen",
    "Save preset": "Preset sichern",
    "Save under a new name": "Sichern unter neuem Namen",
    "New preset / from template": "Neues Preset / aus Vorlage",
    "Store on slot 1 to 4": "Auf Platz 1 bis 4 speichern",
    "Compare with the saved state (A/B)": "Mit dem gesicherten Stand vergleichen (A/B)",
    "Live on the amp on or off": "Live am Verstärker ein oder aus",
    "Select a unit of the chain": "Einheit der Kette wählen",
    "Turn the knob, with Shift in large steps": "Regler drehen, mit Umschalt in großen Schritten",
    "This list": "Diese Liste",

    # The editor of the area Presets
    "Clean": "Clean",
    "Bright": "Brillant",
    "Crunch": "Crunch",
    "High Gain": "High Gain",
    "Metal": "Metal",
    "Acoustic": "Akustik",
    "Bass": "Bass",
    "Disconnected": "Getrennt",
    "Searching …": "Suche …",
    "Connecting …": "Verbinde …",
    "Bluetooth off": "Bluetooth aus",
    "No Bluetooth": "Kein Bluetooth",
    "Starting …": "Starte …",
    "connected": "verbunden",
    "No device found yet": "Noch kein Gerät gefunden",
    "Choose a slot or a preset on the left, or create a new one (Ctrl+N).":
        "Wähle links einen Platz oder ein Preset, oder lege ein neues an (Strg+N).",
    "Changed": "Geändert",
    "Live": "Live",
    "A · Saved": "A · Gespeichert",
    "Add a description": "Beschreibung hinzufügen",
    "Transfer": "Übertragung",
    "ON": "AN",
    "OFF": "AUS",
    "{} · place {} of {}": "{} · Platz {} von {}",
    "Modeled on: {}": "Vorbild: {}",
    "Add-on pack": "Zusatzpaket",
    "<b>Scrolling</b> turns finely, <b>dragging</b> coarsely, a <b>double-click</b> sets the default value.":
        "<b>Scrollen</b> dreht fein, <b>Ziehen</b> grob, <b>Doppelklick</b> setzt den Standardwert.",
    "Scrolling turns finely, dragging coarsely, a double-click sets the default value.":
        "Scrollen dreht fein, Ziehen grob, Doppelklick setzt den Standardwert.",
    "Every change can be heard on the amp at once, without overwriting a slot.":
        "Jede Änderung ist sofort am Verstärker hörbar, ohne einen Platz zu überschreiben.",
    "Slot {} · {}": "Platz {} · {}",
    "On this computer": "Auf diesem Computer",
    "New, not saved yet": "Neu, noch nicht gesichert",
    "Trying out: {}": "Probiert: {}",
    "Try out": "Ausprobieren",
    "To the amp": "Auf den Verstärker",
    "Discard": "Verwerfen",
    "“{}” has unsaved changes.": "„{}“ hat ungesicherte Änderungen.",
    "Copy text for REACTOR": "Text für REACTOR kopieren",

    # Messages of the window
    "The amp answers slowly. Changes now go at a gentler pace.":
        "Der Verstärker antwortet langsam. Änderungen gehen jetzt gemächlicher.",
    "The sound on the {} is lost when it disconnects. Save it as a preset first?":
        "Der Sound auf dem {} geht beim Trennen verloren. Vorher als Preset sichern?",
    "{} is disconnected and plays its stored slot again. The temporary sound is gone there. On the next connection AmpBench reads what plays.":
        "{} ist getrennt und spielt wieder seinen gespeicherten Platz. Der vorübergehende Sound ist dort weg. Beim nächsten Verbinden liest AmpBench nach, was spielt.",
    "The take keeps the sound it started with.": "Der Take behält den Sound, mit dem er begann.",
    "The connection was gone. The edited state plays on the amp again.":
        "Die Verbindung war weg. Der bearbeitete Stand spielt wieder am Verstärker.",
    "The preset “{}” no longer exists.": "Das Preset „{}“ gibt es nicht mehr.",
    "Live: changes go to the amp at once.": "Live: Änderungen gehen sofort zum Verstärker.",
    "Live off. Changes stay in the editor until you try them out.":
        "Live aus. Änderungen bleiben im Editor, bis du sie ausprobierst.",
    "The sound could not be described as text: {}": "Der Sound ließ sich nicht als Text beschreiben: {}",
    "The text for REACTOR is copied. Paste it into “Text to Tone” in the REACTOR app; the REACTOR interprets it itself.":
        "Der Text für REACTOR ist kopiert. Füge ihn in der REACTOR-App bei „Text to Tone“ ein; der REACTOR deutet ihn selbst.",
    "For this a preset must be open and a device connected that may store.":
        "Dazu muss ein Preset offen und ein Gerät verbunden sein, das speichern darf.",
    "Store “{}” on slot {}?": "„{}“ auf Platz {} speichern?",
    "The current preset “{}” is saved first and is then on this computer.":
        "Das jetzige Preset „{}“ wird vorher gesichert und liegt dann auf diesem Computer.",
    "The slot is overwritten.": "Der Platz wird überschrieben.",
    "Stored on slot {} and read back.": "Auf Platz {} gespeichert und zurückgelesen.",
    "“{}” is saved to this computer.": "„{}“ auf diesem Computer gesichert.",
    "Tags belong to a preset on this computer. Save it first.":
        "Tags gehören zu einem Preset auf diesem Computer. Sichere es zuerst.",
    "Tags for “{}”, with or without #, separated by spaces.":
        "Tags für „{}“, mit oder ohne #, durch Leerzeichen getrennt.",
    "Already in use: {}": "Schon vergeben: {}",
    "Choose a Kemper backup or rig": "Kemper-Backup oder Rig wählen",
    "There are no rigs in the file.": "In der Datei sind keine Rigs.",
    "Kemper import: {} new presets.": "Kemper-Import: {} neue Presets.",
    "Kemper import: {} new presets, {} existing ones updated.":
        "Kemper-Import: {} neue Presets, {} schon vorhandene ergänzt.",
    "1 piece added under Record.": "1 Stück unter Aufnahme angelegt.",
    "{} pieces added under Record.": "{} Stücke unter Aufnahme angelegt.",
    "Already there and unchanged: {}.": "Schon da und unverändert: {}.",
    "Every sound is an approximation: listen to it on the amp.":
        "Jeder Sound ist eine Annäherung: am Verstärker anhören.",
    "Name:": "Name:",
    "New name:": "Neuer Name:",
    "Only saved presets can be renamed. The name field changes the name of the open preset.":
        "Nur gesicherte Presets lassen sich umbenennen. Den Namen des offenen Presets ändert das Namensfeld.",
    "Move “{}” to Trash?": "„{}“ in den Papierkorb legen?",

    # The area Record
    "Play": "Abspielen",
    "Pause": "Pause",
    "Loop": "Schleife",
    "A set": "A gesetzt",
    "Marker": "Marker",
    "Markers": "Marker",
    "Tempo": "Tempo",
    "Pitch": "Ton",
    "Takes": "Aufnahmen",
    "Pieces": "Stücke",
    "Statistics": "Statistik",
    "Choose a take.": "Wähle eine Aufnahme.",
    "Calculating waveform …": "Die Wellenform wird berechnet …",
    "No waveform: the file cannot be read.": "Keine Wellenform: Die Datei lässt sich nicht lesen.",
    "Kept.": "Behalten.",
    "First select the take that should go to the Trash.": "Markiere zuerst die Aufnahme, die in den Papierkorb soll.",
    "“{}” is in the Trash.": "„{}“ liegt im Papierkorb.",
    "{} takes are in the Trash.": "{} Aufnahmen liegen im Papierkorb.",
    "The start must be before the end.": "Der Anfang muss vor dem Ende liegen.",
    "Rename marker": "Marker umbenennen",
    "New piece": "Neues Stück",
    "New piece …": "Neues Stück …",
    "Title:": "Titel:",
    "The piece “{}” is deleted. The takes stay.": "Das Stück „{}“ ist gelöscht. Die Takes bleiben.",
    "This piece has no takes yet.": "Dieses Stück hat noch keine Takes.",
    "The settings of this sound are missing from the folder .presets.":
        "Die Einstellungen dieses Sounds fehlen im Ordner .presets.",
    "Piece": "Stück",
    "None": "Kein Stück",
    "No piece": "Ohne Stück",
    "Export": "Exportieren",
    "WAV, 24-bit (*.wav)": "WAV, 24 Bit (*.wav)",
    "WAV, 24-bit …": "WAV, 24 Bit …",
    "Exported: {}": "Exportiert: {}",
    "The export failed.": "Der Export ist fehlgeschlagen.",
    "Name": "Name",
    "Date": "Datum",
    "Length": "Dauer",
    "Rating": "Bewertung",
    "New takes in": "Neue Aufnahmen in",
    "All stars": "Alle Sterne",
    "{} ★ and up": "ab {} ★",
    "All takes": "Alle Takes",
    "Open": "Offen",
    "Kept": "Behalten",
    "Trash": "Papierkorb",
    "1 take · {} open · {} in 30 days": "1 Aufnahme · {} offen · {} in 30 Tagen",
    "{} takes · {} open · {} in 30 days": "{} Aufnahmen · {} offen · {} in 30 Tagen",
    "({} shown)": "({} gezeigt)",
    "All pieces": "Alle Stücke",
    "All tags": "Alle Tags",
    "Missing": "Fehlt",
    "Damaged": "Beschädigt",
    "Details": "Details",
    "Title, also the file name": "Titel, auch der Dateiname",
    "Mark as best take": "Als besten Take markieren",
    "Best take": "Bester Take",
    "Tags, separated by commas": "Tags, durch Kommas getrennt",
    "Note": "Notiz",
    "Sound": "Sound",
    "Open in editor": "Im Editor öffnen",
    "Peak": "Spitze",
    "unknown": "unbekannt",
    "The original always stays unchanged. Edits take effect when listening, and only the export writes a new file.":
        "Das Original bleibt immer unverändert. Bearbeitungen wirken beim Anhören, und erst der Export schreibt eine neue Datei.",
    "Trim": "Zuschnitt",
    "Start = playback position": "Anfang = Abspielposition",
    "End = playback position": "Ende = Abspielposition",
    "Raise automatically": "Automatisch anheben",
    "Raise automatically: {}": "Automatisch anheben: {}",
    "Reset edits": "Bearbeitungen zurücksetzen",
    "No markers yet. The M key adds one, also while recording.":
        "Noch keine Marker. Taste M setzt einen, auch während der Aufnahme.",
    "Since the last slot change nothing was turned; the content is unknown.":
        "Seit dem letzten Platzwechsel wurde nichts gedreht; der Inhalt ist unbekannt.",
    "read from device": "mitgelesen",
    "from the computer or played temporarily": "vom Mac oder vorübergehend gespielt",
    "Delete": "Löschen",
    "New piece: enter a title": "Neues Stück: Titel eingeben",
    "Create": "Anlegen",
    "A piece collects your takes. The dot on the left chooses the piece for new takes.":
        "Ein Stück sammelt deine Takes. Der Punkt links wählt das Stück für neue Aufnahmen.",
    "Artist": "Interpret",
    "Key": "Tonart",
    "Play on amp": "Spielen",
    "Notes": "Notizen",
    "Parts": "Teile",
    "Add part: intro, verse, solo …": "Teil hinzufügen: Intro, Strophe, Solo …",
    "Add part": "Teil hinzufügen",
    "Show takes": "Takes zeigen",
    "Listen to best take": "Besten Take anhören",
    "Delete piece": "Stück löschen",
    "1 take · practiced {}": "1 Take · geübt {}",
    "{} takes · practiced {}": "{} Takes · geübt {}",
    "No sound": "Kein Sound",
    "{} (missing)": "{} (fehlt)",
    "recorded in the last {} days": "aufgenommen in den letzten {} Tagen",
    "Minutes per day": "Minuten pro Tag",
    "Minutes per piece": "Minuten pro Stück",
    "Nothing was recorded in this period.": "In diesem Zeitraum wurde nichts aufgenommen.",
    "Only time that was recorded counts. Discarded takes count too.":
        "Gezählt wird nur Zeit, die aufgenommen wurde. Auch verworfene Takes zählen mit.",

    # The sidebar of the area Presets
    "Show only presets with #{}. Right-click: pin as a section.":
        "Nur Presets mit #{} zeigen. Rechtsklick: als Abschnitt anheften.",
    "Tag {}, {} presets": "Tag {}, {} Presets",
    "filter on": "Filter an",
    "Unpin section": "Abschnitt lösen",
    "Pin as a section": "Als Abschnitt anheften",
    "+ {} more": "+ {} weitere",
    "Show all": "Alle zeigen",
    "Content unknown": "Inhalt unbekannt",
    "On the {}": "Am {}",
    "Tags": "Tags",
    "All on this computer": "Alle auf diesem Computer",
    "Nothing saved yet.": "Noch nichts gesichert.",
    "No preset has all the chosen tags.": "Kein Preset hat alle gewählten Tags.",
    "Nothing found.": "Nichts gefunden.",
    "Nothing found": "Nichts gefunden",
    "Backups": "Sicherungen",
    "Sound recipe, read as a preset": "Sound-Rezept, als Preset gelesen",

    # The Kemper import
    "Without: {}": "Ohne: {}",
    "Every rig becomes the closest Spark sound: a matching amp, gain and EQ, and the effects the Spark knows. A Kemper profile is a recording of the real amp, so listen to every sound on the amp. Nothing is sent to the Kemper.":
        "Jeder Rig wird zum nächstliegenden Spark-Sound: passender Amp, Gain und EQ, die Effekte, die der Spark kennt. Ein Kemper-Profil ist eine Aufnahme des echten Amps, darum jeden Sound am Verstärker anhören. Zum Kemper wird nichts gesendet.",
    "Kind of “{}”": "Art von „{}“",
    "Single rigs ({})": "Einzelne Rigs ({})",
    "{} songs, {} setups, {} rigs": "{} Songs, {} Setups, {} Rigs",
    "Import": "Übernehmen",

    # The area Tuner
    "Deviation": "Abweichung",
    "Strobe": "Stroboskop",
    "ALL NOTES, WITH NAME AND OCTAVE": "ALLE TÖNE, MIT NAME UND OKTAVE",
    "–.–": "–,–",
    "–.––": "–,––",
    "CENTS": "CENT",
    "Signal": "Signal",
    "Too low": "Zu tief",
    "In tune": "Gestimmt",
    "Too high": "Zu hoch",
    "Listening": "Hört",
    "Measuring": "Misst",
    "Shared": "Geteilt",
    "AMP MUTED WHILE IT MEASURES": "VERSTÄRKER STUMM, SOLANGE ES MISST",
    "Tuning": "Stimmung",
    "Concert pitch": "Kammerton",
    "IN TENTHS OF A HERTZ": "IN ZEHNTEL HERTZ",
    "Display": "Anzeige",
    "SWITCHING THE TUNER ON …": "SCHALTE DAS STIMMGERÄT EIN …",
    "MEASURING …": "MISST …",
    "PLAY A STRING": "SPIELE EINE SAITE",
    "NO AMP CONNECTED": "KEIN VERSTÄRKER VERBUNDEN",
    "OPENING THE INPUT …": "ÖFFNE DEN EINGANG …",
    "LISTENING …": "HÖRE ZU …",
    "NO SPARK CONNECTED": "KEIN SPARK VERBUNDEN",
    "INPUT MISSING": "EINGANG FEHLT",
    "THE INPUT CANNOT BE OPENED": "EINGANG LÄSST SICH NICHT ÖFFNEN",
    "The {} tuner is on while this area is in front, and the amp is muted meanwhile. Its readings come over Bluetooth and are coarser than over USB, in whole cents.":
        "Das Stimmgerät des {} ist an, solange dieser Bereich vorn ist, und der Verstärker ist dabei stumm. Seine Werte kommen über Bluetooth und sind gröber als über USB, auf ganze Cent.",
    "The amp’s tuner is on while this area is in front, and the amp is muted meanwhile. Its readings come over Bluetooth and are coarser than over USB, in whole cents.":
        "Das Stimmgerät des Verstärkers ist an, solange dieser Bereich vorn ist, und der Verstärker ist dabei stumm. Seine Werte kommen über Bluetooth und sind gröber als über USB, auf ganze Cent.",
    "Without USB audio the {0} tuner can measure: choose “{0} tuner” under Input. The amp is then muted while this area is in front.":
        "Ohne USB-Ton misst das Stimmgerät des {0}: im Eingang „Stimmgerät des {0}“ wählen. Der Verstärker ist dann stumm, solange dieser Bereich vorn ist.",
    "The tuner listens only while this area is in front. It sends nothing to the amp, plays no sound and stores nothing.":
        "Das Stimmgerät hört nur, solange dieser Bereich vorn ist. Es sendet nichts an den Verstärker, gibt keinen Ton aus und speichert nichts.",
    "FROM THE AMP": "VOM VERSTÄRKER",
    "FROM THE AMP · {}": "VOM VERSTÄRKER · {}",
    "FROM THE AMP · A4 = {} HZ": "VOM VERSTÄRKER · A4 = {} HZ",
    "CONCERT PITCH A4 = {} HZ": "KAMMERTON A4 = {} HZ",
    "STRING {} · {}": "{}. SAITE · {}",
    "CHROMATIC · {}": "CHROMATISCH · {}",
    "NO STRING · {}": "KEINE SAITE · {}",
    "HELD": "GEHALTEN",
    "TARGET {} HZ · FROM THE AMP": "ZIEL {} HZ · VOM VERSTÄRKER",
    "TARGET {} HZ · A4 = {} HZ": "ZIEL {} HZ · A4 = {} HZ",
    "Automatic (USB audio, otherwise the amp’s tuner)": "Automatisch (USB-Ton, sonst Stimmgerät des Verstärkers)",
    "{} (as in the deck)": "{} (wie im Deck)",
    "Spark from the deck": "Spark aus dem Deck",
    "{} tuner (amp muted)": "Stimmgerät des {} (Verstärker stumm)",
    "STANDS STILL WHEN IN TUNE": "STEHT STILL, WENN GESTIMMT",
    "NEEDLE ±50 CENTS": "ZEIGER ±50 CENT",

    # Shared with the modules without a window (the same German as in de_core.py)
    "No Spark": "Kein Spark",
    "Slot {}": "Platz {}",
    "No name": "Ohne Namen",
    "Tuner": "Stimmgerät",
    "New preset": "Neues Preset",
    "seen": "gesehen",
    "The amp is not connected.": "Der Verstärker ist nicht verbunden.",
    "Recipe": "Rezept",
    "The library could not be saved: {}": "Die Bibliothek konnte nicht gespeichert werden: {}",
}
