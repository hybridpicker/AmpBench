"""German texts of the modules without a window. Key: the English text in the code."""

GERMAN_CORE: dict[str, str] = {
    # AI Sound (sound_ai.py, ui/ai_sound_dialog.py), word for word as on the Mac
    "First describe the sound you want.":
        "Beschreibe zuerst, welchen Sound du möchtest.",
    "The model did not answer. Try again.":
        "Das Modell hat nichts geantwortet. Versuch es noch einmal.",
    "The model gave free text instead of a sound recipe (JSON) – even when asked again. Try again or choose another model under “Advanced”.":
        "Das Modell hat kein Sound-Rezept (JSON) geliefert, sondern freien Text – auch nach einer Nachfrage. Versuch es noch einmal oder wähle unter „Erweitert“ ein anderes Modell.",
    "No connection to Ollama: {}":
        "Keine Verbindung zu Ollama: {}",
    "Leave that out – only the description of the sound goes to Ollama.":
        "Lass das weg – an Ollama geht nur die Beschreibung des Sounds.",
    "AI Sound: “{}”":
        "KI-Sound: „{}“",
    "Faithful":
        "Originalgetreu",
    "More punch":
        "Druckvoller",
    "Reduced":
        "Reduziert",
    "The model did not apply “{}” cleanly. AmpBench made the change itself ({}).":
        "Das Modell hat „{}“ nicht sauber umgesetzt. AmpBench hat selbst nachgestellt ({}).",
    "No Ollama API key. Get one at ollama.com/settings/keys and enter it.":
        "Kein Ollama-API-Schlüssel. Hole einen unter ollama.com/settings/keys und trage ihn ein.",
    "Ollama refused the API key. Check it at ollama.com/settings/keys and enter it again (Advanced → Remove key).":
        "Ollama hat den API-Schlüssel abgelehnt. Prüfe ihn unter ollama.com/settings/keys und trage ihn neu ein (Erweitert → Schlüssel entfernen).",
    "Ollama Cloud has no model “{}”. Choose another one under “Advanced”.":
        "Das Modell „{}“ gibt es bei Ollama Cloud nicht. Wähle unter „Erweitert“ ein anderes.",
    "Ollama is busy right now or your quota is used up. Wait a moment and try again.":
        "Ollama ist gerade ausgelastet oder dein Kontingent ist aufgebraucht. Warte kurz und versuch es noch einmal.",
    "Ollama answered with status {}: {}":
        "Ollama antwortete mit Status {}: {}",
    "Ollama answered with status {}.":
        "Ollama antwortete mit Status {}.",
    "Ollama answered without content. Try again.":
        "Ollama antwortete ohne Inhalt. Versuch es noch einmal.",
    "The answer from Ollama could not be read. Try again.":
        "Die Antwort von Ollama war nicht lesbar. Versuch es noch einmal.",
    "Ollama did not answer in time (time limit {} s). Try again or choose a faster model under “Advanced”.":
        "Ollama hat nicht rechtzeitig geantwortet (Zeitlimit {} s). Versuch es noch einmal oder wähle unter „Erweitert“ ein schnelleres Modell.",
    "Your wish contains an e-mail address.":
        "Dein Wunsch enthält eine E-Mail-Adresse.",
    "Describe the sound in at most {} characters.":
        "Beschreibe den Sound in höchstens {} Zeichen.",
    "Invalid JSON at “{}”: {}":
        "Ungültiges JSON bei „{}“: {}",
    "The field “{}” is missing in the JSON.":
        "Das Feld „{}“ fehlt im JSON.",
    "Wrong type at “{}”.":
        "Falscher Typ bei „{}“.",
    "warmer":
        "wärmer",
    "more gain":
        "mehr Gain",
    "less reverb":
        "weniger Hall",
    "brighter":
        "heller",
    "amp treble −1.5":
        "Höhen am Amp −1,5",
    "amp treble +1.5":
        "Höhen am Amp +1,5",
    "amp gain +1.5":
        "Gain am Amp +1,5",
    "reverb level −1.5":
        "Hall-Pegel −1,5",
    "The sound has no reverb.":
        "Der Sound hat keinen Hall.",
    "More gain is not possible.":
        "Mehr Gain geht nicht.",
    "Your wish contains something like a phone number.":
        "Dein Wunsch enthält etwas wie eine Telefonnummer.",
    "Your wish contains something that looks like a key or password.":
        "Dein Wunsch enthält etwas, das wie ein Schlüssel oder Passwort aussieht.",
    "AI Sound: “{}…”":
        "KI-Sound: „{}…“",
    "Invalid JSON: {}":
        "Ungültiges JSON: {}",
    "root":
        "Wurzel",
    # Catalog and sound recipes (catalog.py, recipe.py)
    "A knob needs a number from 0 to 10.":
        "Ein Regler braucht eine Zahl von 0 bis 10.",
    "{} is outside 0–10, set to {}.":
        "{} liegt außerhalb von 0–10, gesetzt auf {}.",
    "A switch needs true, false, “{}” or “{}”.":
        "Ein Schalter braucht true, false, „{}“ oder „{}“.",
    "A switch needs true or false.":
        "Ein Schalter braucht true oder false.",
    "A choice needs one of the names from the catalog.":
        "Eine Auswahl braucht einen der Namen aus dem Katalog.",
    "“{}” is no choice. Allowed: {}.":
        "„{}“ ist keine Auswahl. Erlaubt: {}.",
    "“{}”":
        "„{}“",
    "This parameter is not set.":
        "Dieser Parameter wird nicht gesetzt.",
    "format is not {}.":
        "format ist nicht {}.",
    "The recipe has version {}, AmpBench knows up to {}.":
        "Das Rezept hat Version {}, AmpBench kennt bis {}.",
    "The name is missing.":
        "Der Name fehlt.",
    "The name was longer than {} bytes and was shortened to “{}”.":
        "Der Name war länger als {} Bytes und wurde auf „{}“ gekürzt.",
    "“{}” is no place of the chain. Allowed: {}.":
        "„{}“ ist kein Platz der Kette. Erlaubt: {}.",
    "{}: There is no model “{}”. The model ids are in docs/ai/spark-catalog.json; upper and lower case matter.":
        "{}: Das Modell „{}“ gibt es nicht. Die Modell-ids stehen in docs/ai/spark-catalog.json, Groß- und Kleinschreibung zählen.",
    "{}: “{}” belongs in the place {}.":
        "{}: „{}“ gehört an den Platz {}.",
    "{}: “{}” belongs to a paid add-on. Without the add-on the amp does not take it.":
        "{}: „{}“ gehört zu einem Zusatzpaket. Ohne das Paket nimmt der Verstärker es nicht.",
    "{} {}: There is no “{}”. Allowed: {}.":
        "{} {}: „{}“ gibt es nicht. Erlaubt: {}.",
    "The tempo {} is outside {}–{} and was adjusted.":
        "Das Tempo {} liegt außerhalb von {}–{} und wurde angepasst.",
    "The description was longer than {} bytes and was shortened.":
        "Die Beschreibung war länger als {} Bytes und wurde gekürzt.",
    "The preset has {} places instead of 7.":
        "Das Preset hat {} statt 7 Plätze.",
    "{}: The catalog does not know the model “{}”.":
        "{}: Das Modell „{}“ kennt der Katalog nicht.",
    "{}: not readable":
        "{}: nicht in Ordnung",
    "Error: {}":
        "Fehler: {}",
    "{}: ok, “{}”":
        "{}: in Ordnung. „{}“",
    "Note: {}":
        "Hinweis: {}",
    "Knob {}":
        "Regler {}",
    "On/Off":
        "An/Aus",
    "Unknown model":
        "Unbekanntes Modell",
    # Devices (devices.py)
    "Reading, switching, trying out, live changes, model changes, saving and its own tuner, firmware 1.11.2.75.":
        "Lesen, Umschalten, Ausprobieren, Live-Ändern, Modellwechsel, Speichern und das eigene Stimmgerät, Firmware 1.11.2.75.",
    "Reading, switching, trying out, live changes, model changes, saving, the middle button and its own tuner, firmware 1.16.1.60. Disconnecting discards the temporary sound.":
        "Lesen, Umschalten, Ausprobieren, Live-Ändern, Modellwechsel, Speichern, die mittlere Taste und das eigene Stimmgerät, Firmware 1.16.1.60. Trennen verwirft den vorübergehenden Sound.",
    "Read only: knobs, amp choice, Push/Smooth, Heat, effects, TAP, preset, bank and tuner. Nothing was ever sent.":
        "Nur mitgelesen: Regler, Amp-Wahl, Push/Smooth, Heat, Effekte, TAP, Preset, Bank und Stimmgerät. Es wurde nie etwas gesendet.",
    "Not checked. Treated like the REACTOR 50: read only, send nothing.":
        "Nicht geprüft. Wie der REACTOR 50 behandelt: nur mitlesen, nichts senden.",
    "Not checked. Reading and switching only, until the device is checked with the user.":
        "Nicht geprüft. Nur Lesen und Umschalten, bis das Gerät mit dem Nutzer geprüft ist.",
    "Red":
        "Rot",
    "Green":
        "Grün",
    "Slot {}":
        "Platz {}",
    "Slot":
        "Platz",
    "{} of 5":
        "{} von 5",
    "on":
        "an",
    "off":
        "aus",
    "seen":
        "gesehen",
    # Templates (factory.py)
    "New preset":
        "Neues Preset",
    "Clear amp, a little compression and a small room":
        "Klarer Amp, etwas Kompression und ein kleiner Raum",
    "British crunch, pushed by the overdrive":
        "Britischer Crunch, vom Overdrive angeschoben",
    "Singing high gain with echo for solos":
        "Singender High Gain mit Echo für Soli",
    "Wide clean with chorus, long echo and lots of reverb":
        "Weiter Clean mit Chorus, langem Echo und viel Hall",
    "Dry, snappy clean with lots of compression":
        "Trockener, knackiger Clean mit viel Kompression",
    "{} copy":
        "{} Kopie",
    # Saved presets (library.py)
    "Recipe":
        "Rezept",
    "The name must not be empty.":
        "Der Name darf nicht leer sein.",
    "The name is too long. The amp takes at most {} characters.":
        "Der Name ist zu lang. Der Verstärker nimmt höchstens {} Zeichen.",
    "The trash cannot be reached, the file stays where it is.":
        "Der Papierkorb ist nicht erreichbar, die Datei bleibt wo sie ist.",
    # What may go to the amp (protocol.py)
    "At most {} characters (umlauts count double).":
        "Höchstens {} Zeichen (Umlaute zählen doppelt).",
    "The preset has {} effects instead of {}.":
        "Das Preset hat {} statt {} Effekte.",
    "The tempo is not a number.":
        "Das Tempo ist keine Zahl.",
    "“{}” has a value that is not a number.":
        "„{}“ hat einen Wert, der keine Zahl ist.",
    "The name":
        "Der Name",
    "The version":
        "Die Version",
    "The icon":
        "Das Symbol",
    "The identifier":
        "Die Kennung",
    "The effect name “{}”":
        "Der Effektname „{}“",
    "{} is too long with {} bytes (at most {}).":
        "{} ist mit {} Bytes zu lang (höchstens {}).",
    "The preset has {} bytes, more than the {} the amp safely takes.":
        "Das Preset ist mit {} Bytes größer als die {}, die der Verstärker sicher verträgt.",
    # The connection (link.py)
    "The amp is not connected.":
        "Der Verstärker ist nicht verbunden.",
    "The amp did not answer.":
        "Der Verstärker hat nicht geantwortet.",
    "The amp sent a preset that cannot be read ({}).":
        "Der Verstärker hat ein Preset geschickt, das nicht lesbar ist ({}).",
    "Not sent, so the amp plays nothing unknown: {}":
        "Nicht gesendet, damit der Verstärker nichts Unbekanntes spielt: {}",
    "When read back, the slot did not hold “{}”. The backup is in the library.":
        "Beim Zurücklesen enthielt der Platz nicht „{}“. Die Sicherung liegt in der Bibliothek.",
    "AmpBench sends nothing to {}. It is only read.":
        "An {} sendet AmpBench nichts. Er wird nur mitgelesen.",
    "AmpBench cannot do that with {} yet; it is not checked there.":
        "Das kann AmpBench mit {} noch nicht; es ist dort nicht geprüft.",
    "No Spark device found.":
        "Kein Spark-Gerät gefunden.",
    "The device does not offer the control service.":
        "Das Gerät bietet den Steuerdienst nicht an.",
    "this device":
        "diesem Gerät",
    "Connection failed: {}":
        "Verbindung fehlgeschlagen: {}",
    "The amp's tuner may still be on: switching it off got no answer three times.":
        "Das Stimmgerät des Verstärkers ist vielleicht noch an: Ausschalten blieb dreimal ohne Antwort.",
    "Reading {} …":
        "Lese {} …",
    "Switching to {} …":
        "Schalte auf {} …",
    "Sending “{}” …":
        "Sende „{}“ …",
    "Sending “{}” for editing …":
        "Sende „{}“ zum Bearbeiten …",
    "The value is not a number.":
        "Der Wert ist keine Zahl.",
    "Storing “{}” on {} …":
        "Speichere „{}“ auf {} …",
    "Checking {} …":
        "Prüfe {} …",
    # qtlink.py
    "The amp did not confirm the change.":
        "Der Verstärker hat die Änderung nicht bestätigt.",
    # The input (capture.py)
    "pw-record cannot be started: {}":
        "pw-record lässt sich nicht starten: {}",
    "The input is not open.":
        "Der Eingang ist nicht offen.",
    # Recording (recorder.py)
    "The recording reached the size limit of a WAV file and was ended safely.":
        "Die Aufnahme hat die Grenze des WAV-Formats erreicht und wurde sicher beendet.",
    "The takes are already in use by another AmpBench that is running. Nothing is recorded here.":
        "Die Aufnahmen werden schon von einer anderen AmpBench-Instanz benutzt. Hier wird nichts aufgenommen.",
    "The library could not be read. The broken file is in the folder as Library.damaged-….":
        "Die Bibliothek war nicht lesbar. Die kaputte Datei liegt als Library.damaged-… im Ordner.",
    "“{}” could not be renamed to “{}”: {}. Nothing was changed, the library stays closed.":
        "„{}“ ließ sich nicht in „{}“ umbenennen: {}. Nichts wurde verändert, die Bibliothek bleibt geschlossen.",
    "The interrupted recording “{}” was repaired ({} s) and is in the library.":
        "Die unterbrochene Aufnahme „{}“ wurde repariert ({} s) und liegt in der Bibliothek.",
    "The interrupted recording “{}” could not be repaired. The file stays unchanged in the folder.":
        "Die Datei „{}“ einer unterbrochenen Aufnahme ließ sich nicht reparieren. Sie liegt unverändert im Ordner.",
    "No Spark plugged in. AmpBench records only from a USB device with “Spark” in its name, never from the microphone.":
        "Kein Spark angeschlossen. AmpBench nimmt nur von einem USB-Gerät mit „Spark“ im Namen auf, nie vom Mikrofon.",
    "The library cannot be used, nothing is recorded.":
        "Die Bibliothek ist nicht benutzbar, es wird nichts aufgenommen.",
    "There is not enough space on the drive for a recording.":
        "Auf dem Laufwerk ist zu wenig Platz für eine Aufnahme.",
    "The recording could not start: {}":
        "Die Aufnahme konnte nicht starten: {}",
    "Nothing was recorded because the device delivered no data.":
        "Es wurde nichts aufgenommen, weil das Gerät keine Daten geliefert hat.",
    "The library could not be saved: {}":
        "Die Bibliothek konnte nicht gespeichert werden: {}",
    "Take saved ({} s).":
        "Aufnahme gespeichert ({} s).",
    "The device is gone. The recording was ended safely and what was there until then is kept.":
        "Das Gerät ist verschwunden. Die Aufnahme wurde sicher beendet und behalten, was bis dahin da war.",
    "The input was disconnected.":
        "Der Eingang wurde getrennt.",
    # Takes, files and the trash (store.py, wav.py, trash.py)
    "The library comes from a newer version of the app (schema {}). It stays unchanged.":
        "Die Bibliothek stammt aus einer neueren Version (Schema {}).",
    "The take was not found.":
        "Die Aufnahme wurde nicht gefunden.",
    "The file could not be moved to the trash.":
        "Die Datei konnte nicht in den Papierkorb gelegt werden.",
    "The file is no longer in the trash.":
        "Die Datei liegt nicht mehr im Papierkorb.",
    "This name cannot be used as a file name.":
        "Dieser Name ist als Dateiname nicht möglich.",
    "A file named “{}” already exists.":
        "Es gibt bereits eine Datei mit dem Namen „{}“.",
    "The piece was not found.":
        "Das Stück wurde nicht gefunden.",
    "The file is too short.":
        "Die Datei ist zu kurz.",
    "The file is not a WAV file.":
        "Die Datei ist keine WAV-Datei.",
    "The file could not be read.":
        "Die Datei konnte nicht gelesen werden.",
    "The file's format cannot be read.":
        "Das Format der Datei ist nicht lesbar.",
    "The file contains no audio data.":
        "Die Datei enthält keine Audiodaten.",
    "The file is larger than the WAV format allows.":
        "Die Datei ist zu groß für das WAV-Format.",
    # Tuner (tuner.py)
    "{} tuner":
        "Stimmgerät des {}",
    "Tuner":
        "Stimmgerät",
    "No Spark":
        "Kein Spark",
    "Automatic: {}":
        "Automatisch: {}",
    "No amp connected":
        "Kein Verstärker verbunden",
    # Notes and tunings (tuning.py)
    "B":
        "H",
    "B♭":
        "B",
    "C sharp":
        "Cis",
    "D sharp":
        "Dis",
    "F sharp":
        "Fis",
    "G sharp":
        "Gis",
    "A sharp":
        "Ais",
    "D flat":
        "Des",
    "E flat":
        "Es",
    "G flat":
        "Ges",
    "A flat":
        "As",
    "B flat":
        "B",
    "Half step down":
        "Halbton tiefer",
    "Chromatic":
        "Chromatisch",
    "All notes":
        "Alle Töne",
    "0 cents":
        "0 Cent",
    "minus {} cents":
        "minus {} Cent",
    "plus {} cents":
        "plus {} Cent",
    "string {}":
        "{}. Saite",
    "in tune":
        "gestimmt",
    "{} cents too low":
        "{} Cent zu tief",
    "{} cents too high":
        "{} Cent zu hoch",
    # Kemper import (kemper.py)
    "Effect {}":
        "Effekt {}",
    "No name":
        "Ohne Namen",
    "The Kemper file is damaged: {}":
        "Die Kemper-Datei ist beschädigt: {}",
    "no rig header":
        "kein Rig-Kopf",
    "database cannot be read":
        "Datenbank nicht lesbar",
    "database has an unknown schema":
        "Datenbank hat ein unbekanntes Schema",
    "not an archive":
        "kein Archiv",
    "empty archive":
        "leeres Archiv",
    "“{}” is not a Kemper file (expected: .kipr or .kpabackup).":
        "„{}“ ist keine Kemper-Datei (erwartet: .kipr oder .kpabackup).",
    "unknown amp, clean":
        "unbekannter Amp, clean",
    "unknown amp, crunch":
        "unbekannter Amp, Crunch",
    "unknown amp, distorted":
        "unbekannter Amp, verzerrt",
    "{} (place {} already taken)":
        "{} (Platz {} schon belegt)",
    "Reverb → Reverb":
        "Hall → Hall",
    "From the Kemper rig “{}”":
        "Aus dem Kemper-Rig „{}“",
    ", amp {}":
        ", Amp {}",
    ", profile by {}":
        ", Profil von {}",
    "Spark amp {} because of {}. Gain {} as on the Kemper; bass, middle and treble from the Kemper EQ, half of the presence in the treble.":
        "Spark-Amp {} wegen {}. Gain {} wie am Kemper; Bass, Mitten und Höhen aus dem Kemper-EQ, die Präsenz halb in den Höhen.",
    "Effects: {}.":
        "Effekte: {}.",
    "Not imported: {}.":
        "Nicht übernommen: {}.",
    "A profile is a recording of the real amp, the Spark computes with models: listen and adjust before you use it.":
        "Ein Profil ist eine Aufnahme des echten Amps, der Spark rechnet mit Modellen: vor dem Einsatz anhören und nachstellen.",
    "Song":
        "Song",
    "Basic setup":
        "Basis-Setup",
    "Lessons":
        "Unterricht",
    "Do not import":
        "Nicht übernehmen",
    "Kemper · {} · slot {}":
        "Kemper · {} · Platz {}",
    "From the Kemper performance {} “{}”.":
        "Aus der Kemper-Performance {} „{}“.",
    "{} rigs, {} performances, {} of your own":
        "{} Rigs, {} Performances, {} eigene",
    "without: {}":
        "ohne: {}",
    "Result: {} presets, {} pieces":
        "Ergebnis: {} Presets, {} Stücke",
    "not possible: {}":
        "nicht möglich: {}",
    # Command line (app.py)
    "AmpBench for Linux: presets, recording and tuner for Positive Grid amps":
        "AmpBench für Linux: Presets, Aufnahme und Stimmgerät für Positive-Grid-Verstärker",
}
