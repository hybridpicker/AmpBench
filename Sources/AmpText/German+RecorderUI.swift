/// The German texts of the area Record: the deck, the waveform panel, the library, the menus and the command line.
extension German {
    static let recorderUI: [String: String] = {
        var merged: [String: String] = [:]
        for part in [recorderUI1, recorderUI2, recorderUI3] {
            merged.merge(part) { first, _ in first }
        }
        return merged
    }()

    private static let recorderUI1: [String: String] = [
        "%+.1f dB":
            "%+.1f dB",
        "%.1f dBFS":
            "%.1f dBFS",
        "%.1f min":
            "%.1f Min.",
        "%.1f ms":
            "%.1f ms",
        "%.1f s":
            "%.1f s",
        "%.1f seconds":
            "%.1f Sekunden",
        "%@ (missing)":
            "%@ (fehlt)",
        "%@ of %@":
            "%@ von %@",
        "%@ of audio were lost because the disk was not fast enough.":
            "Es gingen %@ Audio verloren, weil die Festplatte nicht schnell genug war.",
        "%@ recorded again, as a separate take. “%@” stays unchanged.":
            "%@ neu aufgenommen, als eigene Aufnahme. „%@“ bleibt unverändert.",
        "%d added":
            "%d neu aufgenommen",
        "%d beats per minute":
            "%d Schläge pro Minute",
        "%d damaged":
            "%d beschädigt",
        "%d h %d min":
            "%d Std. %d Min.",
        "%d markers":
            "%d Marker",
        "%d min":
            "%d Min.",
        "%d minutes":
            "%d Minuten",
        "%d missing":
            "%d fehlen",
        "%d of 5 stars":
            "%d von 5 Sternen",
        "%d percent":
            "%d Prozent",
        "%d recognized after renaming":
            "%d umbenannt erkannt",
        "%d repaired":
            "%d repariert",
        "%d semitones":
            "%d Halbtöne",
        "%d stars":
            "%d Sterne",
        "%d takes are in the Trash.":
            "%d Aufnahmen liegen im Papierkorb.",
        "%d takes selected":
            "%d Aufnahmen markiert",
        "%d takes · %d open · %@ in 30 days":
            "%d Aufnahmen · %d offen · %@ in 30 Tagen",
        "%d takes · practiced %@":
            "%d Takes · geübt %@",
        "%d ★ and up":
            "ab %d ★",
        "1 marker":
            "1 Marker",
        "1 take · %d open · %@ in 30 days":
            "1 Aufnahme · %d offen · %@ in 30 Tagen",
        "1 take · practiced %@":
            "1 Take · geübt %@",
        "30 days":
            "30 Tage",
        "7 days":
            "7 Tage",
        "90 days":
            "90 Tage",
        "A major":
            "A-Dur",
        "A piece collects your takes. The dot on the left chooses the piece for new takes; a click on the title changes it. You assign finished takes in the list's right-click menu or on the right under Details.":
            "Ein Stück sammelt deine Takes. Der Punkt links wählt das Stück für neue Aufnahmen, ein Klick auf den Titel ändert ihn. Fertige Aufnahmen ordnest du im Rechtsklick-Menü der Liste oder rechts unter Details zu.",
        "A piece needs a title.":
            "Ein Stück braucht einen Titel.",
        "A set":
            "A gesetzt",
        "AAC …":
            "AAC …",
        "AAC, 192 kbit/s …":
            "AAC, 192 kbit/s …",
        "AAC, 256 kbit/s …":
            "AAC, 256 kbit/s …",
        "Add a marker at the current position (M), also while recording":
            "Marker an der aktuellen Stelle setzen (M), auch während der Aufnahme",
        "Add marker  (M)":
            "Marker setzen  (M)",
        "Add part":
            "Teil hinzufügen",
        "Again":
            "Nochmal",
        "All measurements were forgotten. Outputs on the same device are blocked again.":
            "Alle Messungen wurden vergessen. Ausgaben auf dasselbe Gerät sind wieder gesperrt.",
        "All pieces":
            "Alle Stücke",
        "All stars":
            "Alle Sterne",
        "All tags":
            "Alle Tags",
        "All takes":
            "Alle Takes",
        "allowed":
            "erlaubt",
        "Amp over Bluetooth: %@":
            "Verstärker über Bluetooth: %@",
        "Amp over Bluetooth: %@.":
            "Verstärker über Bluetooth: %@.",
        "An error occurred while writing (error %@). The take has gaps.":
            "Beim Schreiben ist ein Fehler aufgetreten (Fehler %@). Die Aufnahme enthält Lücken.",
        "Another app changed the device's sample rate. The recording up to that point is saved.":
            "Eine andere App hat die Abtastrate des Geräts geändert. Die Aufnahme bis dahin ist gespeichert.",
        "Artist":
            "Interpret",
        "Assign to piece":
            "Stück zuordnen",
        "Automatic":
            "Automatisch",
        "Back 5 seconds  (←)":
            "5 Sekunden zurück  (←)",
        "Bar %d":
            "Takt %d",
        "Bar %d · Beat %d":
            "Takt %d · Schlag %d",
        "Bar %d, beat %d":
            "Takt %d, Schlag %d",
        "Bar — · Beat —":
            "Takt — · Schlag —",
        "Bars":
            "Takte",
        "Bars %d–%d":
            "Takte %d–%d",
        "Before bar %d":
            "Vor Takt %d",
        "Before the first bar":
            "Vor dem ersten Takt",
        "Best take":
            "Bester Take",
        "Best take, remove mark":
            "Bester Take, Markierung entfernen",
        "Both takes must exist to compare them.":
            "Zum Vergleichen müssen beide Aufnahmen vorhanden sein.",
        "Buffer %@ of %@":
            "Puffer %@ von %@",
        "Calculating waveform …":
            "Wellenform wird berechnet …",
        "Cancel":
            "Abbrechen",
        "Cancel count-in":
            "Einzähler abbrechen",
        "Cancel count-in (R)":
            "Einzähler abbrechen (R)",
        "Check folder":
            "Ordner prüfen",
        "Check input":
            "Eingang prüfen",
        "CHECKING":
            "PRÜFEN",
        "Chord changes, slow":
            "Akkordwechsel langsam",
        "Chorus":
            "Refrain",
        "Click":
            "Klick",
        "Click and type to change the title":
            "Klicken und tippen ändert den Titel",
        "Click off":
            "Klick aus",
        "Click on":
            "Klick an",
        "Click on or off  (N)":
            "Klick an oder aus  (N)",
        "Click on or off (N). It can only be heard while playing and recording.":
            "Klick an oder aus (N). Er ist nur beim Abspielen und Aufnehmen zu hören.",
        "Click output":
            "Klick-Ausgang",
        "Clicking connects.":
            "Klicken verbindet.",
        "Clicking disconnects, so the Spark app on the phone can use the amp.":
            "Klicken trennt, damit die Spark-App am Handy den Verstärker nutzen kann.",
        "Clipping":
            "Übersteuert",
        "Clipping, reset":
            "Übersteuert, zurücksetzen",
        "Close message":
            "Meldung schließen",
        "Compare":
            "Vergleichen",
        "Compare the two selected takes directly":
            "Die zwei markierten Takes direkt vergleichen",
        "Compare two takes":
            "Zwei Takes vergleichen",
        "Compensation %+.1f ms":
            "Ausgleich %+.1f ms",
        "Connect the Spark, then press R and start playing. Files in the folder are recognized automatically.":
            "Schließ den Spark an, dann drück R und spiel los. Dateien im Ordner werden automatisch erkannt.",
        "Connected":
            "Verbunden",
        "Connects to the amp.":
            "Verbindet mit dem Verstärker.",
        "Count in 1 bar":
            "1 Takt einzählen",
        "Count in 2 bars":
            "2 Takte einzählen",
        "Count-in":
            "Einzähler",
        "COUNT-IN %d":
            "EINZÄHLER %d",
        "Count-in before recording":
            "Einzähler vor der Aufnahme",
        "Count-in, volume and click output":
            "Einzähler, Lautstärke und Klickausgang",
        "Counts in and records the selected bars again at this take's tempo. That becomes a separate take; the original stays unchanged.":
            "Zählt ein und nimmt die gewählten Takte im Tempo dieser Aufnahme neu auf. Das wird eine eigene Aufnahme, das Original bleibt unverändert.",
        "Create":
            "Anlegen",
        "Create a new piece":
            "Neues Stück anlegen",
        "Create a new piece and assign this take":
            "Neues Stück anlegen und diese Aufnahme zuordnen",
        "Create a new piece for this take":
            "Neues Stück für diese Aufnahme anlegen",
        "Current piece":
            "Aktuelles Stück",
        "Date":
            "Datum",
        "Day":
            "Tag",
        "Details":
            "Details",
        "Device":
            "Gerät",
        "Discard":
            "Verwerfen",
        "Disconnects.":
            "Trennt die Verbindung.",
        "Dropouts":
            "Aussetzer",
        "Dropouts in the recording":
            "Aussetzer in der Aufnahme",
        "E minor scale":
            "Tonleiter E-Moll",
        "Edit":
            "Bearbeiten",
        "End = playback position":
            "Ende = Abspielposition",
        "End comparison":
            "Vergleich beenden",
        "Enter a title above and press Return. New takes then go into this piece.":
            "Gib oben einen Titel ein und drück den Zeilenschalter. Neue Aufnahmen landen dann in diesem Stück.",
        "Export":
            "Export",
        "Export (%@)":
            "Exportieren (%@)",
        "Export after the recording has ended.":
            "Exportiere nach dem Ende der Aufnahme.",
        "Export as":
            "Exportieren",
        "Exported to “%@”, but the level exceeded full scale. Lower the gain.":
            "Exportiert nach „%@“, aber der Pegel hat die Vollaussteuerung überschritten. Senke die Anhebung.",
        "Exported to “%@”.":
            "Exportiert nach „%@“.",
        "Fade in":
            "Einblenden",
        "Fade out":
            "Ausblenden",
        "Faster  (+)":
            "Schneller  (+)",
        "Favorite":
            "Favorit",
        "Favorite  (F)":
            "Favorit  (F)",
        "Favorite (F)":
            "Favorit (F)",
        "Favorites only":
            "Nur Favoriten",
        "File":
            "Datei",
        "File damaged":
            "Datei beschädigt",
        "File missing":
            "Datei fehlt",
        "First assign the take to a piece, then you can mark it as the best take.":
            "Ordne die Aufnahme zuerst einem Stück zu, dann kannst du sie als besten Take markieren.",
        "First bar":
            "Erster Takt",
        "First select the take that should go to the Trash.":
            "Markiere zuerst die Aufnahme, die in den Papierkorb soll.",
        "Folder checked: %@.":
            "Ordner geprüft: %@.",
        "For this, run a cable from the headphone output to the amp's guitar input, with a 3.5 mm plug at the Mac and a 6.3 mm plug at the amp. Without a cable, headphones held directly on the pickup work too, with the strings muted. Choose a preset without delay, reverb and noise gate and set the output to medium volume. The measurement takes about ten seconds; nothing is saved.":
            "Steck dafür ein Kabel vom Kopfhörerausgang in den Gitarreneingang des Amps, mit 3,5-mm-Klinke am Mac und 6,3-mm-Klinke am Amp. Ohne Kabel geht auch ein Kopfhörer direkt auf dem Tonabnehmer, bei abgedämpften Saiten. Wähle ein Preset ohne Delay, Hall und Noise Gate und dreh den Ausgang auf mittlere Lautstärke. Die Messung dauert rund zehn Sekunden, es wird nichts gespeichert.",
        "Forget measurements":
            "Messungen vergessen",
        "Forward 5 seconds  (→)":
            "5 Sekunden vor  (→)",
        "Grid":
            "Raster",
        "Input":
            "Eingang",
        "input %@ [%@]: %@ ch, %@ bit, current %@ Hz, max %@ Hz":
            "Eingang %@ [%@]: %@ Kanäle, %@ Bit, aktuell %@ Hz, höchstens %@ Hz",
        "Input closed":
            "Eingang geschlossen",
        "Input level":
            "Eingangspegel",
        "Inspector section":
            "Bereich des Inspektors",
        "Intro":
            "Intro",
        "It can only be heard while playing and recording. While playing it is on the playback output, while recording on the click output. A count-in always sounds.":
            "Er ist nur beim Abspielen und Aufnehmen zu hören. Beim Abspielen liegt er auf dem Ausgang der Wiedergabe, beim Aufnehmen auf dem Klick-Ausgang. Ein Einzähler klingt immer.",
        "Jump to %@":
            "Zu %@ springen",
        "Jump to this marker":
            "Zu diesem Marker springen",
        "Jump with the arrow keys; the L key sets the loop":
            "Mit Pfeiltasten springen, Taste L setzt die Schleife",
        "Keep":
            "Behalten",
        "Keep  (K)":
            "Behalten  (K)",
        "Keep take (K)":
            "Take behalten (K)",
        "Keeps the last minutes in memory. Nothing is saved by itself. Off by default.":
            "Hält die letzten Minuten im Arbeitsspeicher. Nichts wird von selbst gespeichert. Standardmäßig aus.",
        "Kept":
            "Behalten",
        "Key":
            "Tonart",
        "L key: the first press sets A, the second sets B, the third clears. Or drag in the waveform.":
            "Taste L: erster Druck setzt A, zweiter setzt B, dritter löscht. Oder in der Wellenform ziehen.",
        "Label":
            "Beschriftung",
        "Label of %@":
            "Beschriftung von %@",
        "Last 2 minutes":
            "Letzte 2 Minuten",
        "Last 30 seconds":
            "Letzte 30 Sekunden",
        "Last bar":
            "Letzter Takt",
        "Last minute":
            "Letzte Minute",
        "Length":
            "Dauer",
        "Length %@":
            "Länge %@",
        "Length of the Retro buffer":
            "Länge des Retro-Puffers",
        "Level":
            "Pegel",
        "Library":
            "Bibliothek",
        "Library view":
            "Ansicht der Bibliothek",
        "Listen":
            "Anhören",
        "LISTENING":
            "HÖRT MIT",
        "Loop":
            "Schleife",
        "Loop A, B, off  (L)":
            "Schleife A, B, aus  (L)",
        "Loop bars":
            "Takte loopen",
        "Loop from %@ to %@":
            "Schleife von %@ bis %@",
        "Loop off":
            "Schleife aus",
        "Loop selected bars":
            "Gewählte Takte loopen",
        "Loop start at %@":
            "Schleifenanfang bei %@",
        "Mark as best":
            "Als besten markieren",
        "Mark as best take":
            "Als besten Take markieren",
        "Mark as favorite":
            "Als Favorit markieren",
        "Marker":
            "Marker",
        "Marker %d":
            "Marker %d",
        "Marker at %@":
            "Marker bei %@",
        "Markers":
            "Marker",
        "Measure":
            "Messen",
        "Measure click latency":
            "Klick-Latenz messen",
        "Measure click latency …":
            "Klick-Latenz messen …",
        "Measure feedback":
            "Rückkopplung messen",
        "Measure feedback …":
            "Rückkopplung messen …",
        "Measure latency with a cable …":
            "Latenz mit Kabel messen …",
    ]

    private static let recorderUI2: [String: String] = [
        "Measured: %.1f ms from the click into the file, of which %.1f ms are not reported by the devices. Spread %.1f ms over %d clicks. The bars of new takes now rest on it. Unplug the cable again.":
            "Gemessen: %.1f ms vom Klick bis in die Datei, davon %.1f ms nicht von den Geräten gemeldet. Streuung %.1f ms über %d Klicks. Die Takte neuer Aufnahmen liegen jetzt darauf. Zieh das Kabel wieder ab.",
        "Measured: The sound from “%@” arrives at the input “%@”. Output to it stays blocked during a recording.":
            "Gemessen: Der Ton von „%@“ kommt am Eingang „%@“ an. Ausgabe dorthin bleibt während einer Aufnahme gesperrt.",
        "Measured: The sound from “%@” does not arrive at the input “%@”. Playback and click to it are now allowed during a recording too.":
            "Gemessen: Der Ton von „%@“ kommt am Eingang „%@“ nicht an. Wiedergabe und Klick dorthin sind jetzt auch während einer Aufnahme erlaubt.",
        "Metronome settings":
            "Metronom-Einstellungen",
        "Microphone access is missing. Allow it under System Settings → Privacy & Security → Microphone.":
            "Der Mikrofonzugriff fehlt. Erlaube ihn unter Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon.",
        "microphone permission: %@":
            "Mikrofonzugriff: %@",
        "min":
            "Min.",
        "Minimum rating":
            "Mindestbewertung",
        "Minutes":
            "Minuten",
        "Minutes per day":
            "Minuten pro Tag",
        "Minutes per piece":
            "Minuten pro Stück",
        "Move %d takes to Trash":
            "%d Aufnahmen in den Papierkorb legen",
        "Move selected takes to the Trash":
            "Markierte Aufnahmen in den Papierkorb legen",
        "Move selected takes to the Trash (⌘⌫). Can be undone with ⌘Z.":
            "Markierte Aufnahmen in den Papierkorb legen (⌘⌫). Lässt sich mit ⌘Z rückgängig machen.",
        "Move to Trash":
            "In den Papierkorb legen",
        "Move to Trash (⌘⌫). Can be undone with ⌘Z.":
            "In den Papierkorb legen (⌘⌫). Lässt sich mit ⌘Z rückgängig machen.",
        "Name":
            "Name",
        "Name of the part":
            "Name des Teils",
        "New":
            "Neu",
        "New piece":
            "Neues Stück",
        "New piece …":
            "Neues Stück …",
        "New takes go into this piece. A click undoes that.":
            "Neue Aufnahmen landen in diesem Stück. Klick hebt das auf.",
        "New takes in":
            "Neue Aufnahmen in",
        "New takes then go into this piece.":
            "Neue Aufnahmen landen dann in diesem Stück.",
        "New: %@":
            "Neu: %@",
        "no":
            "nein",
        "No clipping":
            "Keine Übersteuerung",
        "No count-in":
            "Kein Einzähler",
        "No data":
            "Keine Daten",
        "No input":
            "Ohne Eingang",
        "No markers yet. The M key adds one, also while recording.":
            "Noch keine Marker. Taste M setzt einen, auch während der Aufnahme.",
        "no matching output device":
            "Kein passendes Ausgabegerät",
        "no matching Spark input on USB":
            "Kein passender Spark-Eingang über USB",
        "None":
            "Kein Stück",
        "No pieces yet":
            "Noch keine Stücke",
        "No recording without a Spark":
            "Ohne Spark keine Aufnahme",
        "No safe output found for the click. The recording runs without a click.":
            "Kein sicherer Ausgang für den Klick gefunden. Die Aufnahme läuft ohne Klick.",
        "No safe output found for the click. The recording starts without a count-in.":
            "Kein sicherer Ausgang für den Klick gefunden. Die Aufnahme startet ohne Einzähler.",
        "No safe output found for the click. Without a count-in, bars cannot be recorded again.":
            "Kein sicherer Ausgang für den Klick gefunden. Ohne Einzähler lassen sich keine Takte neu aufnehmen.",
        "No signal":
            "Kein Signal",
        "No signal: nothing is arriving right now":
            "Kein Signal: Es kommt gerade nichts an",
        "No sound":
            "Kein Sound",
        "NO SPARK":
            "KEIN SPARK",
        "No Spark":
            "Kein Spark",
        "No Spark connected":
            "Kein Spark verbunden",
        "no Spark connected":
            "kein Spark verbunden",
        "No Spark connected, recording not possible":
            "Kein Spark verbunden, Aufnahme nicht möglich",
        "No Spark connected. Without a Spark the app records nothing.":
            "Kein Spark verbunden. Ohne Spark nimmt die App nichts auf.",
        "No take selected":
            "Keine Aufnahme ausgewählt",
        "No takes in this piece yet":
            "Noch keine Takes",
        "No takes yet":
            "Noch keine Aufnahmen",
        "No takes yet. Connect the Spark, then press R to record the first one.":
            "Noch keine Aufnahmen. Schließ den Spark an, dann nimmst du mit R die erste auf.",
        "No takes yet. Press R to record the first one.":
            "Noch keine Aufnahmen. Mit R nimmst du die erste auf.",
        "No waveform available":
            "Keine Wellenform verfügbar",
        "none":
            "keiner",
        "Not a favorite":
            "Kein Favorit",
        "Not a preset: the device does not send its content. Shown is what it had reported when the take started.":
            "Kein Preset: Das Gerät schickt seinen Inhalt nicht. Gezeigt ist, was es beim Start des Takes gemeldet hatte.",
        "not allowed":
            "nicht erlaubt",
        "Note":
            "Notiz",
        "Notes":
            "Notizen",
        "Notes on the piece":
            "Notizen zum Stück",
        "Nothing was recorded because the device delivered no data.":
            "Es wurde nichts aufgenommen, weil das Gerät keine Daten geliefert hat.",
        "Nothing was recorded in this period.":
            "In diesem Zeitraum wurde nichts aufgenommen.",
        "of %d":
            "von %d",
        "Off · N":
            "Aus · N",
        "On · N":
            "An · N",
        "Only time that was recorded counts. Discarded takes count too, because you practiced anyway.":
            "Gezählt wird nur Zeit, die aufgenommen wurde. Auch verworfene Takes zählen mit, denn geübt hast du trotzdem.",
        "Open":
            "Offen",
        "Open in editor":
            "Im Editor öffnen",
        "Opens the input only to check the level. Nothing is saved. Ends by itself after two minutes.":
            "Öffnet den Eingang nur zum Pegel prüfen. Es wird nichts gespeichert. Endet nach zwei Minuten von selbst.",
        "Opens the sound in the Presets area as a new preset that you can save.":
            "Öffnet den Sound im Bereich Presets als neues Preset, das du sichern kannst.",
        "Output":
            "Ausgabe",
        "output %@: %@ ch":
            "Ausgabe %@: %@ Kanäle",
        "Output blocked":
            "Ausgabe gesperrt",
        "Output blocked while recording. %@":
            "Ausgabe bei Aufnahme gesperrt. %@",
        "Outro":
            "Outro",
        "Part":
            "Teil",
        "Part %d":
            "Teil %d",
        "Parts":
            "Teile",
        "Pause":
            "Pause",
        "Peak":
            "Spitze",
        "Peak after editing: %@":
            "Spitze nach Bearbeitung: %@",
        "Period":
            "Zeitraum",
        "Piece":
            "Stück",
        "Piece for new takes":
            "Stück für neue Aufnahmen",
        "Piece for new takes, undo":
            "Stück für neue Aufnahmen, aufheben",
        "Piece restored":
            "Stück wiederhergestellt",
        "Pieces":
            "Stücke",
        "Pitch":
            "Ton",
        "Pitch shift":
            "Tonhöhe",
        "Play":
            "Abspielen",
        "play failed: %@":
            "Wiedergabe fehlgeschlagen: %@",
        "Play on amp":
            "Spielen",
        "Play or pause  (Space)":
            "Abspielen oder anhalten  (Leertaste)",
        "Play or pause (Space)":
            "Abspielen oder anhalten (Leertaste)",
        "Playback":
            "Wiedergabe",
        "played temporarily":
            "vorübergehend gespielt",
        "Plays the selected bars in a loop. Dragging in the waveform selects whole bars, freely with ⌥.":
            "Spielt die gewählten Takte in Schleife. In der Wellenform ziehen wählt ganze Takte, mit ⌥ frei.",
        "Plays the sound on the amp, in the temporary slot. No slot is overwritten.":
            "Spielt den Sound am Verstärker, auf dem vorübergehenden Platz. Kein Platz wird überschrieben.",
        "Plays this sound on the amp, in the temporary slot. No slot is overwritten.":
            "Spielt diesen Sound am Verstärker, auf dem vorübergehenden Platz. Kein Platz wird überschrieben.",
        "Position":
            "Position",
        "Position in the recording":
            "Position in der Aufnahme",
        "Practice band":
            "Übungsband",
        "Practice time from all takes of this piece, including discarded ones":
            "Übungszeit aus allen Aufnahmen dieses Stücks, auch verworfenen",
        "Press R and start playing. Files in the folder are recognized automatically.":
            "Drück R und spiel los. Dateien im Ordner werden automatisch erkannt.",
        "Put new takes into %@":
            "Neue Aufnahmen in %@ legen",
        "Put new takes into this piece":
            "Neue Aufnahmen in dieses Stück legen",
        "Quality":
            "Qualität",
        "R key":
            "Taste R",
        "R · RECORD":
            "R · AUFNAHME",
        "Raise automatically: %@":
            "Automatisch anheben: %@",
        "Raise the level of new takes automatically":
            "Pegel neuer Aufnahmen automatisch anheben",
        "Raises the peak to %d dBFS, by at most %d dB. The dynamics stay the same; the noise floor rises with it.":
            "Hebt die Spitze auf %d dBFS an, höchstens um %d dB. Die Dynamik bleibt gleich, das Grundrauschen steigt mit.",
        "Rating":
            "Bewertung",
        "Rating  (1 to 5)":
            "Bewertung  (1 bis 5)",
        "Read from device":
            "Mitgelesen",
        "READY":
            "BEREIT",
        "Record":
            "Aufnahme",
        "Record again (R). This take stays as “Open”.":
            "Neu aufnehmen (R). Dieser Take bleibt als „Offen“ erhalten.",
        "Record bars again":
            "Takte neu aufnehmen",
        "Record selected bars again":
            "Gewählte Takte neu aufnehmen",
        "recorded in the last %d days":
            "aufgenommen in den letzten %d Tagen",
        "RECORDING":
            "AUFNAHME",
        "Recording in progress":
            "Aufnahme läuft",
        "Recording state":
            "Aufnahmezustand",
        "Remove %@":
            "%@ entfernen",
        "Remove %@, the takes stay":
            "%@ entfernen, die Takes bleiben",
        "Remove favorite":
            "Favorit entfernen",
        "Remove part":
            "Teil entfernen",
        "Remove piece":
            "Stück entfernen",
        "Remove piece. The takes stay in the list, and it can be undone.":
            "Stück entfernen. Die Takes bleiben in der Liste, und es lässt sich rückgängig machen.",
        "Rename":
            "Umbenennen",
        "Rename piece":
            "Stück umbenennen",
        "Rename this take":
            "Aufnahme umbenennen",
        "Rename …":
            "Umbenennen …",
        "Repaired after an interruption":
            "Nach einer Unterbrechung repariert",
        "Reset all filters":
            "Alle Filter zurücksetzen",
        "Reset edits":
            "Bearbeitungen zurücksetzen",
        "Reset tempo and pitch":
            "Tempo und Tonhöhe zurücksetzen",
        "Reset tempo and pitch  (0)":
            "Tempo und Tonhöhe zurücksetzen  (0)",
        "Reset tempo and pitch (0)":
            "Tempo und Tonhöhe zurücksetzen (0)",
        "Restore last discarded":
            "Zuletzt Verworfenes wiederherstellen",
        "Restored":
            "Wiederhergestellt",
        "Retro":
            "Retro",
        "Retro recording can only be turned on after the running recording.":
            "Die Retro-Aufnahme lässt sich erst nach der laufenden Aufnahme einschalten.",
        "Retro recording off. The buffer in memory was cleared.":
            "Retro-Aufnahme aus. Der Puffer im Arbeitsspeicher wurde gelöscht.",
        "Retro recording on. The input is listening; the buffer stays in memory.":
            "Retro-Aufnahme an. Der Eingang hört mit, der Puffer bleibt im Arbeitsspeicher.",
        "Right now there is no output that is certain not to reach the recording.":
            "Es gibt gerade keinen Ausgang, der die Aufnahme sicher nicht erreicht.",
        "Saved, but the signal clipped. Play more quietly or lower the level on the device.":
            "Gespeichert, aber das Signal hat übersteuert. Spiel leiser oder senke den Pegel am Gerät.",
        "Saves the whole buffer as a new take (⌘G or G).":
            "Speichert den ganzen Puffer als neue Aufnahme (⌘G oder G).",
        "Saving continuously":
            "Gespeichert wird laufend",
        "Search":
            "Suchen",
        "Search takes":
            "Aufnahmen suchen",
        "seconds: %@, peak: %@, dropped: %@, write error: %@":
            "Sekunden: %@, Spitze: %@, verloren: %@, Schreibfehler: %@",
        "Select a take below.":
            "Wähle unten eine Aufnahme aus.",
        "Sets the click to this piece's tempo":
            "Stellt den Klick auf das Tempo dieses Stücks",
        "Show in Finder":
            "Im Finder zeigen",
        "Show library folder in Finder":
            "Bibliotheksordner im Finder zeigen",
        "Show takes":
            "Takes zeigen",
        "Shows all keyboard shortcuts (⌘/)":
            "Zeigt alle Tastenkürzel (⌘/)",
        "Signal clipping":
            "Übersteuerung",
        "Signal present":
            "Signal vorhanden",
        "Silence":
            "Stille",
        "Since the last slot change nothing was turned on the device; the preset's content is unknown.":
            "Seit dem letzten Platzwechsel wurde am Gerät nichts gedreht; der Inhalt des Presets ist unbekannt.",
        "Slot %d":
            "Platz %d",
        "Slower  (-)":
            "Langsamer  (-)",
        "So that the bars are right to the millisecond, the app measures how long a click takes from “%@” into the recording from “%@”. The amp delays the guitar internally, and the devices do not report that.":
            "Damit die Takte auf die Millisekunde stimmen, misst die App, wie lange ein Klick von „%@“ bis in die Aufnahme von „%@“ braucht. Der Amp verzögert die Gitarre intern, und das melden die Geräte nicht.",
        "Solo":
            "Solo",
        "Solo ideas":
            "Solo Ideen",
        "Solo only from bar 13, just chords before.":
            "Solo erst ab Takt 13, vorher nur Akkorde.",
        "Soon":
            "Gleich",
        "Sound":
            "Sound",
        "Sound for %@":
            "Sound für %@",
        "Sound of the piece":
            "Sound des Stücks",
        "Sound read from device: %@, %@":
            "Sound mitgelesen: %@, %@",
        "Sound: %@, %@":
            "Sound: %@, %@",
        "Source":
            "Quelle",
        "Source %@. File %@.":
            "Quelle %@. Datei %@.",
        "Spark connected":
            "Spark verbunden",
        "Spark devices without input: %@":
            "Spark-Geräte ohne Eingang: %@",
        "AmpBench is already running with this library. Quit the other instance.":
            "Spark Recorder läuft bereits mit dieser Bibliothek. Beende die andere Instanz.",
        "Spark without input: The Spark Mini is connected but is not providing an audio input to the Mac right now.":
            "Spark ohne Eingang: Der Spark Mini ist verbunden, stellt dem Mac aber gerade keinen Audioeingang bereit.",
        "Start = playback position":
            "Anfang = Abspielposition",
        "start failed: %@":
            "Start fehlgeschlagen: %@",
        "Start recording":
            "Aufnahme starten",
        "Start recording (R)":
            "Aufnahme starten (R)",
        "START …":
            "START …",
        "Starting in a moment":
            "Gleich geht's los",
        "Statistics":
            "Statistik",
        "Status":
            "Status",
        "Stop checking":
            "Prüfen beenden",
        "Stop checking input":
            "Eingang prüfen beenden",
        "Stop loop":
            "Loop aus",
        "Stop recording":
            "Aufnahme stoppen",
        "Stop recording (R)":
            "Aufnahme stoppen (R)",
        "Switch to the other take  (B)":
            "Zum anderen Take wechseln  (B)",
        "Switch to this take (B key)":
            "Zu diesem Take wechseln (Taste B)",
        "System output":
            "Systemausgang",
        "Tag":
            "Tag",
        "Tags":
            "Tags",
    ]

    private static let recorderUI3: [String: String] = [
        "Tags, separated by commas":
            "Tags, durch Kommas getrennt",
        "Take %@: %@":
            "Take %@: %@",
        "Take %d":
            "Take %d",
        "Take A":
            "Take A",
        "Take B":
            "Take B",
        "Take saved. %@.":
            "Aufnahme gespeichert. %@.",
        "Takes":
            "Aufnahmen",
        "Takes in this piece":
            "Takes",
        "Tap":
            "Tap",
        "Tap in the tempo":
            "Tempo eintippen",
        "Tap in the tempo (T)":
            "Tempo eintippen (T)",
        "Tap tempo  (T)":
            "Tap-Tempo  (T)",
        "Tempo":
            "Tempo",
        "Tempo in BPM":
            "Tempo in BPM",
        "That clips on export. Lower the level.":
            "Das übersteuert beim Export. Senke den Pegel.",
        "That was good":
            "Das eben war gut",
        "The %d selected takes go into this piece.":
            "Die %d markierten Aufnahmen kommen in dieses Stück.",
        "The app never puts the click into the file. Outputs of the same device are skipped until a measurement shows that they do not arrive at the input.":
            "Der Klick landet nie durch die App in der Datei. Ausgänge desselben Geräts werden übersprungen, bis eine Messung zeigt, dass sie nicht am Eingang ankommen.",
        "The app plays quiet clicks through “%@” for about three seconds and measures whether they arrive at the input “%@”. Nothing is saved.":
            "Die App spielt rund drei Sekunden lang leise Klicks über „%@“ und misst, ob sie am Eingang „%@“ ankommen. Es wird nichts gespeichert.",
        "The app records only from a Spark over USB. Connect the Spark and turn it on.":
            "Die App nimmt nur von einem Spark über USB auf. Verbinde den Spark und schalte ihn ein.",
        "The audio connection was interrupted.":
            "Die Audioverbindung wurde unterbrochen.",
        "The audio connection was interrupted. Listening was stopped and the buffer cleared.":
            "Die Audioverbindung wurde unterbrochen. Das Mithören wurde beendet und der Puffer gelöscht.",
        "The audio connection was interrupted. The recording up to that point is saved.":
            "Die Audioverbindung wurde unterbrochen. Die Aufnahme bis dahin ist gespeichert.",
        "The bars need a count-in, and the click could not start. Nothing was recorded.":
            "Die Takte brauchen einen Einzähler, und der Klick konnte nicht starten. Es wurde nichts aufgenommen.",
        "The buffer could not be saved: %@":
            "Der Puffer konnte nicht gespeichert werden: %@",
        "The buffer is cleared when the recording ends.":
            "Der Puffer wird beim Ende der Aufnahme gelöscht.",
        "The buffer is still empty.":
            "Der Puffer ist noch leer.",
        "The click can only be heard while playing and recording.":
            "Der Klick ist nur beim Abspielen und Aufnehmen zu hören.",
        "The click could not start: %@":
            "Der Klick konnte nicht starten: %@",
        "The click could not start: %@ The recording starts without a count-in.":
            "Der Klick konnte nicht starten: %@ Die Aufnahme startet ohne Einzähler.",
        "The click did not start. The recording starts without a count-in.":
            "Der Klick ist nicht angelaufen. Die Aufnahme startet ohne Einzähler.",
        "The context menu applies to all selected takes.":
            "Das Kontextmenü gilt für alle markierten Aufnahmen.",
        "The count-in was canceled.":
            "Der Einzähler wurde abgebrochen.",
        "The devices report %@ from the click into the file; the app always compensates for that. The compensation is added for what the amp delays internally. It applies to new takes with this click output.":
            "Die Geräte melden %@ vom Klick bis in die Datei, das gleicht die App immer aus. Der Ausgleich kommt für das, was der Amp intern verzögert, dazu. Er gilt für neue Aufnahmen mit diesem Klick-Ausgang.",
        "The disk is almost full. The recording was ended safely.":
            "Die Festplatte ist fast voll. Die Aufnahme wurde sicher beendet.",
        "The export failed: %@":
            "Der Export ist fehlgeschlagen: %@",
        "The file has 24 bits so there is headroom for editing. That does not add detail the source does not deliver.":
            "Die Datei hat 24 Bit, damit beim Bearbeiten Reserve bleibt. Details, die die Quelle nicht liefert, kommen dadurch nicht dazu.",
        "The file in the folder gets the same name.":
            "Die Datei im Ordner bekommt denselben Namen.",
        "The file is completely silent. The device delivered no signal.":
            "Die Datei ist komplett still. Das Gerät hat kein Signal geliefert.",
        "The file “%@” is damaged and cannot be read.":
            "Die Datei „%@“ ist beschädigt und lässt sich nicht lesen.",
        "The file “%@” is missing from the folder.":
            "Die Datei „%@“ fehlt im Ordner.",
        "The folder matches the library.":
            "Der Ordner stimmt mit der Bibliothek überein.",
        "The input could not be opened: %@":
            "Der Eingang konnte nicht geöffnet werden: %@",
        "The input delivers no data":
            "Der Eingang liefert keine Daten",
        "The input is no longer available. Listening was stopped and the buffer cleared.":
            "Der Eingang ist nicht mehr verfügbar. Das Mithören wurde beendet und der Puffer gelöscht.",
        "The input keeps listening for as long as this is on.":
            "Der Eingang hört dauerhaft mit, solange das eingeschaltet ist.",
        "The input was changed. Listening was stopped and the buffer cleared.":
            "Der Eingang wurde gewechselt. Das Mithören wurde beendet und der Puffer gelöscht.",
        "The interrupted recording “%@” contained no audio and is in the Trash.":
            "Die unterbrochene Aufnahme „%@“ enthielt keine Audiodaten und liegt im Papierkorb.",
        "The interrupted recording “%@” could not be repaired. The file stays unchanged in the folder.":
            "Die unterbrochene Aufnahme „%@“ ließ sich nicht reparieren. Die Datei bleibt unverändert im Ordner.",
        "The last %@ were saved as “%@”.":
            "Die letzten %@ wurden als „%@“ gespeichert.",
        "The last recording was interrupted and repaired: “%@” (%@).":
            "Die letzte Aufnahme wurde unterbrochen und repariert: „%@“ (%@).",
        "The latency measurement failed: %@":
            "Die Latenzmessung ist fehlgeschlagen: %@",
        "The library could not be saved: %@":
            "Die Bibliothek konnte nicht gespeichert werden: %@",
        "The library file was damaged and there was no backup. The takes were read in again; the old file is in the folder as “%@”.":
            "Die Bibliotheksdatei war beschädigt und es gab keine Sicherung. Die Aufnahmen wurden neu eingelesen, die alte Datei liegt als „%@“ im Ordner.",
        "The library file was damaged. The backup was loaded; the old file is in the folder as “%@”.":
            "Die Bibliotheksdatei war beschädigt. Die Sicherung wurde geladen, die alte Datei liegt als „%@“ im Ordner.",
        "The measurement failed: %@":
            "Die Messung ist fehlgeschlagen: %@",
        "The original always stays unchanged. Edits take effect when listening, and only the export writes a new file.":
            "Das Original bleibt immer unverändert. Bearbeitungen wirken beim Anhören und erst der Export schreibt eine neue Datei.",
        "The original stays unchanged. Edits are rendered into the new file.":
            "Das Original bleibt unverändert. Bearbeitungen werden in die neue Datei gerechnet.",
        "The output device is no longer available. Playback uses the system output until it is back.":
            "Das Ausgabegerät ist nicht mehr verfügbar. Die Wiedergabe nutzt den Systemausgang, bis es zurück ist.",
        "The piece “%@” is removed. Its takes stay in the list.":
            "Das Stück „%@“ ist entfernt. Seine Takes bleiben in der Liste.",
        "The recording could not start: %@":
            "Die Aufnahme konnte nicht starten: %@",
        "The recording reached the size limit of a WAV file and was ended safely.":
            "Die Aufnahme hat die Größengrenze einer WAV-Datei erreicht und wurde sicher beendet.",
        "The result applies to exactly these two devices and to takes recorded afterwards.":
            "Das Ergebnis gilt für genau diese beiden Geräte und für Aufnahmen, die danach entstehen.",
        "The run in bar 5 sits now.":
            "Der Lauf in Takt 5 sitzt jetzt.",
        "The selected take goes into this piece.":
            "Die markierte Aufnahme kommt in dieses Stück.",
        "The settings of this sound are missing from the folder .presets.":
            "Die Einstellungen dieses Sounds fehlen im Ordner .presets.",
        "The signal reached full scale. A click resets the display.":
            "Das Signal hat die Vollaussteuerung erreicht. Klick setzt die Anzeige zurück.",
        "The Spark Mini is connected but is not providing an audio input to the Mac right now.":
            "Der Spark Mini ist verbunden, stellt dem Mac aber gerade keinen Audioeingang bereit.",
        "There is already a piece with the title “%@”.":
            "Es gibt schon ein Stück mit dem Titel „%@“.",
        "There is no discarded take left in the Trash.":
            "Es liegt keine verworfene Aufnahme mehr im Papierkorb.",
        "There is not enough space on the volume for a recording.":
            "Auf dem Volume ist zu wenig Platz für eine Aufnahme.",
        "Time signature":
            "Taktart",
        "Title":
            "Titel",
        "Title of a new piece or exercise":
            "Titel eines neuen Stücks oder einer Übung",
        "Title of the piece":
            "Titel des Stücks",
        "Title of the take":
            "Titel der Aufnahme",
        "Title, also the file name":
            "Titel, auch der Dateiname",
        "to":
            "bis",
        "To metronome":
            "Ins Metronom",
        "To the amp":
            "Auf den Amp",
        "To the original":
            "Zum Original",
        "Trim":
            "Zuschnitt",
        "Turn click off":
            "Klick ausschalten",
        "Turn click on":
            "Klick einschalten",
        "Turn off Retro recording":
            "Retro-Aufnahme ausschalten",
        "Turn on Retro recording":
            "Retro-Aufnahme einschalten",
        "Turn the guitar down or unplug it first. The result applies only to these two devices.":
            "Dreh die Gitarre vorher leise oder steck sie aus. Das Ergebnis gilt nur für diese beiden Geräte.",
        "Undo":
            "Rückgängig",
        "unknown":
            "unbekannt",
        "unknown command":
            "Unbekannter Befehl",
        "Unnamed":
            "Ohne Namen",
        "usage: --inspect <file.wav>":
            "Aufruf: --inspect <datei.wav>",
        "usage: --play-tone <device name part> <seconds> [frequency] [amplitude]":
            "Aufruf: --play-tone <Teil des Gerätenamens> <Sekunden> [Frequenz] [Amplitude]",
        "usage: --record <device name part> <seconds> <output.wav>":
            "Aufruf: --record <Teil des Gerätenamens> <Sekunden> <ausgabe.wav>",
        "Verse":
            "Strophe",
        "Volume":
            "Lautstärke",
        "WAV, 24-bit …":
            "WAV, 24 Bit …",
        "Waveform of %@":
            "Wellenform von %@",
        "Waveform of the running recording":
            "Wellenform der laufenden Aufnahme",
        "While recording, the click goes to “%@”.":
            "Beim Aufnehmen geht der Klick auf „%@“.",
        "Whole buffer  (G)":
            "Ganzer Puffer  (G)",
        "With “Compare” you hear them one right after the other.":
            "Mit „Vergleichen“ hörst du sie direkt nacheinander.",
        "No piece":
            "Ohne Stück",
        "yes":
            "ja",
        "“%@” is in the Trash.":
            "„%@“ liegt im Papierkorb.",
        "“%@”: %@":
            "„%@“: %@",
        "“Check input” ended automatically after two minutes.":
            "„Eingang prüfen“ wurde nach zwei Minuten automatisch beendet.",
        "⌘/ Keyboard shortcuts":
            "⌘/ Tastenkürzel",
    ]
}
