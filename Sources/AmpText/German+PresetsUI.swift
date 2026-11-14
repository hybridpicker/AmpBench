/// The German texts of the area Presets (Sources/SparkPresetsUI): sidebar, editor, REACTOR panel, sheets, menus
/// and the Bluetooth link. Split in two so the compiler stays fast.
extension German {
    static let presetsUI: [String: String] = presetsUIFirst.merging(presetsUISecond) { first, _ in first }

    private static let presetsUIFirst: [String: String] = [
        "%1$@ on the %2$@. AmpBench shows what is stored there and does not switch.":
            "%1$@ am %2$@. AmpBench zeigt, was dort gespeichert ist, und schaltet nicht um.",
        "%1$@ · %2$d BPM · read from the %3$@. The knobs below show what was turned on the device since the slot change.":
            "%1$@ · %2$d BPM · vom %3$@ gelesen. Die Regler unten zeigen, was seit dem Platzwechsel am Gerät gedreht wurde.",
        "%1$@ · place %2$d of %3$d":
            "%1$@ · Platz %2$d von %3$d",
        "%@ has not been read.":
            "%@ ist nicht gelesen.",
        "%@ is being read …":
            "%@ wird gelesen …",
        "%@ is disconnected and plays its stored slot again. The temporary sound is gone there. On the next connection AmpBench reads what plays.":
            "%@ ist getrennt und spielt wieder seinen gespeicherten Platz. Der vorübergehende Sound ist dort weg. Beim nächsten Verbinden liest AmpBench nach, was spielt.",
        "%@ of 10":
            "%@ von 10",
        "%@ on or off":
            "%@ an oder aus",
        "%@ plays no sound from AmpBench. It is only read.":
            "%@ spielt keinen Sound von AmpBench. Er wird nur mitgelesen.",
        "%@, before overwriting":
            "%@, vor dem Überschreiben",
        "%@.\n\nTurn Volume down on the device first: another amp can be louder. The master is not changed. The slot’s current sound is then altered until you change the slot; nothing is stored.":
            "%@.\n\nDreh vorher Volume am Gerät herunter: Ein anderer Amp kann lauter sein. Der Master wird nicht verändert. Der jetzige Sound des Platzes ist danach verstellt, bis du den Platz wechselst; gespeichert wird nichts.",
        "%@: %@":
            "%@: %@",
        "%@: %@, playing":
            "%@: %@, spielt",
        "%@: being written …":
            "%@: wird geschrieben …",
        "%d messages without a known meaning (%@) are only counted.":
            "%d Meldungen ohne bekannte Bedeutung (%@) sind nur gezählt.",
        "%d of %d characters":
            "%d von %d Zeichen",
        "%d of 5":
            "%d von 5",
        "%d percent":
            "%d Prozent",
        "%d presets":
            "%d Presets",
        "%d songs could not be created as pieces.":
            "%d Songs ließen sich nicht als Stücke anlegen.",
        "%d songs, %d setups, %d rigs":
            "%d Songs, %d Setups, %d Rigs",
        "**Dragging** up or down turns a control, a **double tap** sets the default value.":
            "**Ziehen** nach oben oder unten dreht einen Regler, ein **Doppeltipp** stellt den Standardwert ein.",
        "**Scrolling** turns finely, **dragging** coarsely, a **double-click** sets the default value.":
            "**Scrollen** dreht fein, **Ziehen** grob, **Doppelklick** setzt den Standardwert.",
        "1 preset":
            "1 Preset",
        "A backup from the USB stick (.kpabackup) or a single rig (.kipr). AmpBench only reads.":
            "Ein Backup vom USB-Stick (.kpabackup) oder ein einzelnes Rig (.kipr). AmpBench liest nur.",
        "A template is only a start. Everything can be changed afterwards.":
            "Eine Vorlage ist nur ein Anfang. Alles lässt sich danach ändern.",
        "A · Saved":
            "A · Gespeichert",
        "Add #tag":
            "#tag hinzufügen",
        "Add a description":
            "Beschreibung hinzufügen",
        "Add tags":
            "Tags hinzufügen",
        "adjusted: %@":
            "angepasst: %@",
        "Advanced":
            "Erweitert",
        "Again":
            "Nochmal",
        "AI Sound":
            "KI-Sound",
        "AI Sound from a description …":
            "KI-Sound aus Beschreibung …",
        "AI Sound needs an Ollama API key. You get one for free with an Ollama account.":
            "Für KI-Sound braucht AmpBench einen Ollama-API-Schlüssel. Du bekommst ihn kostenlos mit einem Ollama-Konto.",
        "AI Sound …":
            "KI-Sound …",
        "Allow access in System Settings → Privacy & Security → Bluetooth.":
            "Erlaube den Zugriff unter Systemeinstellungen → Datenschutz & Sicherheit → Bluetooth.",
        "Amp":
            "Verstärker",
        "Amp selection":
            "Amp-Wahl",
        "AmpBench cannot do that with %@ yet; it is not checked there.":
            "Das kann AmpBench mit %@ noch nicht; es ist dort nicht geprüft.",
        "AmpBench sends nothing to %@. It is only read.":
            "An %@ sendet AmpBench nichts. Er wird nur mitgelesen.",
        "AmpBench sends nothing to the REACTOR by itself. To set a sound, choose a preset on this Mac on the left, then “⋯ → Play on the REACTOR …” in the editor. It does not report Volume, Power Control, Wah, EQ and FX loop, or they are not checked.":
            "Von sich aus sendet AmpBench nichts an den REACTOR. Einen Sound stellst du so ein: links ein Preset auf dem Mac wählen, dann im Editor „⋯ → Auf den REACTOR spielen …“. Volume, Power Control, Wah, EQ und FX-Loop meldet er nicht oder sind nicht geprüft.",
        "AmpBench sends nothing to the REACTOR, not even a read request. It does not report Volume, Power Control, Wah, EQ and FX loop, or they are not checked.":
            "AmpBench sendet nichts an den REACTOR, auch keine Leseanfrage. Volume, Power Control, Wah, EQ und FX-Loop meldet er nicht oder sind nicht geprüft.",
        "Asked for recently":
            "Zuletzt gewünscht",
        "At most %d characters. The name also applies on the amp once the preset is on a slot.":
            "Höchstens %d Zeichen. Der Name gilt auch auf dem Verstärker, sobald das Preset auf einem Platz liegt.",
        "Backups":
            "Sicherungen",
        "Blues crunch for my Telecaster":
            "Blues-Crunch für meine Telecaster",
        "Bluetooth is off":
            "Bluetooth ist aus",
        "Bluetooth is starting":
            "Bluetooth startet",
        "Cancel":
            "Abbrechen",
        "Cancel request":
            "Anfrage abbrechen",
        "Cancelled.":
            "Abgebrochen.",
        "Chain":
            "Kette",
        "Changed":
            "Geändert",
        "Checking %@ …":
            "Prüfe %@ …",
        "Choose a Kemper backup (.kpabackup) or a rig (.kipr).":
            "Wähle ein Kemper-Backup (.kpabackup) oder ein Rig (.kipr).",
        "Choose a Kemper backup or rig":
            "Kemper-Backup oder Rig wählen",
        "Choose a slot on the amp or a preset on this Mac on the left, or create a new one.":
            "Wähle links einen Platz am Verstärker oder ein Preset auf dem Mac, oder lege ein neues an.",
        "Choose device …":
            "Gerät wählen …",
        "Choose file …":
            "Datei wählen …",
        "Chooses another model for %@":
            "Wählt ein anderes Modell für %@",
        "Chosen on the %@: %@":
            "Am %@ gewählt: %@",
        "Chosen on the %@: %@ “%@”":
            "Am %@ gewählt: %@ „%@“",
        "Chosen on the %@: %@. The content of the preset is unknown.":
            "Am %@ gewählt: %@. Der Inhalt des Presets ist unbekannt.",
        "Clean amp, all effects off":
            "Clean-Amp, alle Effekte aus",
        "Clean funk with bite":
            "Cleaner Funk mit Biss",
        "Clear history":
            "Verlauf löschen",
        "Clicking plays the preset for listening, without overwriting a slot":
            "Klicken spielt das Preset zum Anhören, ohne einen Platz zu überschreiben",
        "Clicking plays this slot and opens it for editing":
            "Klicken spielt diesen Platz und öffnet ihn zum Bearbeiten",
        "Clicking plays this slot and opens it for editing (⌘%d)":
            "Klicken spielt diesen Platz und öffnet ihn zum Bearbeiten (⌘%d)",
        "Close":
            "Schließen",
        "Compare with the saved state":
            "Mit gespeichertem Stand vergleichen",
        "Compares with the saved state (⌘B)":
            "Vergleicht mit dem gespeicherten Stand (⌘B)",
        "Connect":
            "Verbinden",
        "Connect the amp to hear it.":
            "Verbinde den Verstärker, um es zu hören.",
        "Connect to Ollama Cloud":
            "Mit Ollama Cloud verbinden",
        "Connect to the amp":
            "Mit dem Verstärker verbinden",
        "connected":
            "verbunden",
        "Connected":
            "Verbunden",
        "connected · read only, AmpBench sends nothing":
            "verbunden · nur mitlesen, AmpBench sendet nichts",
        "connected · reading along, sound on request":
            "verbunden · liest mit, Sound auf Wunsch",
        "Connecting":
            "Verbinde",
        "Connecting …":
            "Verbinde …",
        "Connects to the amp. The Spark app on the phone must not be connected then.":
            "Verbindet mit dem Verstärker. Die Spark-App am Handy darf dabei nicht verbunden sein.",
        "Content unknown":
            "Inhalt unbekannt",
        "Copy text for REACTOR":
            "Text für REACTOR kopieren",
        "Create a key at ollama.com/settings/keys":
            "Schlüssel auf ollama.com/settings/keys erstellen",
        "Create suggestions":
            "Vorschläge erstellen",
        "Describe the sound in your own words – a song, a band, a mood. You get three different suggestions, listen to them on the amp, refine them and keep only what you like.":
            "Beschreibe den Sound mit eigenen Worten – ein Song, eine Band, eine Stimmung. Du bekommst drei verschiedene Vorschläge, hörst sie am Verstärker an, besserst nach und behältst nur, was dir gefällt.",
        "Describes the sound in English for “Text to Tone” in the REACTOR app. The REACTOR interprets the text itself.":
            "Beschreibt den Sound auf Englisch für „Text to Tone“ in der REACTOR-App. Der REACTOR deutet den Text selbst.",
        "Description":
            "Beschreibung",
        "Device":
            "Gerät",
        "Discard":
            "Verwerfen",
        "Discard changes":
            "Änderungen verwerfen",
        "Disconnect":
            "Trennen",
        "Disconnect from the amp":
            "Vom Verstärker trennen",
        "Disconnect the Spark app on the phone":
            "Spark-App am Handy trennen",
        "Disconnect without saving":
            "Ohne Sichern trennen",
        "disconnected":
            "getrennt",
        "Disconnected":
            "Getrennt",
        "Disconnects from the amp, so the Spark app on the phone can use it.":
            "Trennt vom Verstärker, damit die Spark-App am Handy ihn nutzen kann.",
        "Duplicate":
            "Duplizieren",
        "Duplicate current":
            "Aktuelles duplizieren",
        "e.g. “U2 – Where the streets have no name”":
            "z. B. „U2 – Where the streets have no name“",
        "edited state":
            "bearbeiteter Stand",
        "Effects":
            "Effekte",
        "Empty":
            "Leer",
        "Empty preset":
            "Leeres Preset",
        "Every change can be heard on the amp at once, without overwriting a slot.":
            "Jede Änderung ist sofort am Verstärker hörbar, ohne einen Platz zu überschreiben.",
        "Every rig becomes the closest Spark sound: a matching amp, gain and EQ, and the effects the Spark knows. A Kemper profile is a recording of the real amp, so listen to every sound on the amp. Nothing is sent to the Kemper.":
            "Jeder Rig wird zum nächstliegenden Spark-Sound: passender Amp, Gain und EQ, die Effekte, die der Spark kennt. Ein Kemper-Profil ist eine Aufnahme des echten Amps, darum jeden Sound am Verstärker anhören. Zum Kemper wird nichts gesendet.",
        "Every sound is an approximation: listen to it on the amp.":
            "Jeder Sound ist eine Annäherung: am Verstärker anhören.",
        "filter on":
            "Filter an",
        "Firmware %@ · connected":
            "Firmware %@ · verbunden",
        "First save or discard the changes to “%@”.":
            "Sichere oder verwirf zuerst die Änderungen an „%@“.",
        "From template …":
            "Aus Vorlage …",
        "Hear changes live":
            "Änderungen live hören",
        "Hide notes":
            "Notizen ausblenden",
        "Holding Bank switches it on.":
            "Bank halten schaltet es an.",
        "Ideas to click":
            "Ideen zum Anklicken",
        "Import":
            "Übernehmen",
        "Import from Kemper":
            "Vom Kemper übernehmen",
        "Import from Kemper …":
            "Vom Kemper übernehmen …",
        "It plays on the amp.":
            "Es spielt am Verstärker.",
        "It then plays its stored slot again. When saved, the sound goes to this Mac under “On this Mac”.":
            "Er spielt dann wieder seinen gespeicherten Platz. Gesichert landet der Sound auf dem Mac unter „Auf dem Mac“.",
        "Keep":
            "Behalten",
        "Keep searching":
            "Weiter suchen",
        "Kemper import: %d new presets, %d existing ones updated.":
            "Kemper-Import: %d neue Presets, %d schon vorhandene ergänzt.",
        "Kemper import: %d new presets.":
            "Kemper-Import: %d neue Presets.",
        "Kind":
            "Art",
        "Kind of “%@”":
            "Art von „%@“",
        "Listen":
            "Anhören",
        "Listen to the suggestions":
            "Hör dir die Vorschläge an",
        "Live on the amp":
            "Live am Verstärker",
        "LOADED":
            "GELADEN",
        "LOADING":
            "LÄDT",
        "Make this suggestion %@, the rest stays":
            "Diesen Vorschlag %@ machen, der Rest bleibt",
        "Model":
            "Modell",
        "Model: %@":
            "Modell: %@",
        "Modeled on: %@":
            "Vorbild: %@",
        "More actions":
            "Weitere Aktionen",
        "Move to Trash":
            "In den Papierkorb legen",
        "Name":
            "Name",
        "nearby":
            "in der Nähe",
        "New":
            "Neu",
        "New preset":
            "Neues Preset",
        "New preset from template …":
            "Neues Preset aus Vorlage …",
        "New suggestions":
            "Neue Vorschläge",
        "New, not saved yet":
            "Neu, noch nicht gesichert",
        "Newly created":
            "Neu erstellt",
        "no Bluetooth access":
            "kein Bluetooth-Zugriff",
        "No Bluetooth access":
            "Kein Bluetooth-Zugriff",
        "no Bluetooth LE":
            "kein Bluetooth LE",
        "No Bluetooth LE":
            "Kein Bluetooth LE",
        "No device chosen":
            "Kein Gerät gewählt",
        "No device found yet":
            "Noch kein Gerät gefunden",
    ]

    private static let presetsUISecond: [String: String] = [
        "No presets yet. Save a slot, create a new one or import sounds from the Kemper.":
            "Noch keine Presets. Sichere einen Platz, lege ein neues an oder übernimm Sounds vom Kemper.",
        "No suggestion came back. Try again.":
            "Es kam kein Vorschlag zurück. Versuch es noch einmal.",
        "No tags yet. Add them in the editor below the name.":
            "Noch keine Tags. Im Editor unter dem Namen hinzufügen.",
        "Not on the amp":
            "Nicht am Verstärker",
        "not reported":
            "nicht gemeldet",
        "Not sent, so the amp plays nothing unknown: %@":
            "Nicht gesendet, damit der Verstärker nichts Unbekanntes spielt: %@",
        "not there":
            "nicht da",
        "Note …":
            "Notiz …",
        "Note: %@":
            "Hinweis: %@",
        "Notes":
            "Notizen",
        "Notes: where the sound comes from, what it suits, what to try":
            "Notizen: woher der Sound kommt, wofür er passt, was zu probieren ist",
        "off":
            "aus",
        "Off":
            "Aus",
        "on":
            "an",
        "On":
            "An",
        "On the %@":
            "Am %@",
        "On this Mac":
            "Auf dem Mac",
        "On · output muted":
            "An · Ausgang stumm",
        "Only your text goes to Ollama (ollama.com) – no presets, names or device data.":
            "Nur dein Text geht an Ollama (ollama.com) – keine Presets, Namen oder Gerätedaten.",
        "Other description":
            "Andere Beschreibung",
        "Other file …":
            "Andere Datei …",
        "Paste the API key":
            "API-Schlüssel einfügen",
        "Performances":
            "Performances",
        "pinned":
            "angeheftet",
        "Play %@":
            "%@ spielen",
        "Play on the REACTOR …":
            "Auf den REACTOR spielen …",
        "Play the edited state":
            "Bearbeiteten Stand spielen",
        "Played temporarily · %@":
            "Vorübergehend gespielt · %@",
        "playing":
            "spielt",
        "Playing now":
            "Spielt gerade",
        "Preset content unknown. Shown is what was turned or pressed on the device since the last slot change.":
            "Preset-Inhalt unbekannt. Angezeigt wird, was seit dem letzten Platzwechsel am Gerät gedreht oder gedrückt wurde.",
        "Preset name":
            "Name des Presets",
        "READ":
            "GELESEN",
        "Read only":
            "Nur mitlesen",
        "Read the amp again":
            "Verstärker neu lesen",
        "READING":
            "LIEST",
        "Reading %@ …":
            "Lese %@ …",
        "Reading along · sound on request":
            "Mitlesen · Sound auf Wunsch",
        "Reading the Kemper file …":
            "Lese die Kemper-Datei …",
        "Reading …":
            "Wird gelesen …",
        "Redo":
            "Wiederholen",
        "Redo (⇧⌘Z)":
            "Wiederholen (⇧⌘Z)",
        "Remove #%@":
            "#%@ entfernen",
        "Remove key":
            "Schlüssel entfernen",
        "Remove tag %@":
            "Tag %@ entfernen",
        "Rename":
            "Umbenennen",
        "Rename preset":
            "Preset umbenennen",
        "Rename …":
            "Umbenennen …",
        "running":
            "läuft",
        "Save":
            "Sichern",
        "Save as a new preset":
            "Als neues Preset sichern",
        "Save as a preset, then disconnect":
            "Als Preset sichern, dann trennen",
        "Save as a preset, then switch":
            "Als Preset sichern, dann wechseln",
        "Save as …":
            "Sichern unter …",
        "Save as, store on a slot, text for REACTOR, discard, duplicate":
            "Sichern unter, auf einem Platz speichern, Text für REACTOR, verwerfen, duplizieren",
        "Save to this Mac":
            "Auf dem Mac sichern",
        "Save to this Mac (⌘S)":
            "Auf dem Mac sichern (⌘S)",
        "Saved as a copy of “%@”":
            "Gesichert als Kopie von „%@“",
        "saved state":
            "gespeicherter Stand",
        "Search for devices":
            "Nach Geräten suchen",
        "Search for devices nearby":
            "Nach Geräten in der Nähe suchen",
        "Searching for %@ …":
            "Suche %@ …",
        "Searching for devices …":
            "Suche Geräte …",
        "Searching for the amp":
            "Suche den Verstärker",
        "Searching nearby …":
            "Suche in der Nähe …",
        "selected":
            "ausgewählt",
        "Selected device on or off":
            "Gewähltes Gerät an oder aus",
        "Sending “%@” for editing …":
            "Sende „%@“ zum Bearbeiten …",
        "Sending “%@” …":
            "Sende „%@“ …",
        "Set":
            "Einstellen",
        "Set on the %@: %@. Master and Volume stay as they are. The sound holds until the slot changes; storing happens only on the device, and that overwrites the slot.":
            "Am %@ eingestellt: %@. Master und Volume bleiben, wie sie sind. Der Sound gilt, bis der Platz wechselt; gespeichert wird nur am Gerät, und das überschreibt den Platz.",
        "Set this sound on the %@?":
            "Diesen Sound am %@ einstellen?",
        "Sets the closest amp, gain, tone controls and effects on the connected REACTOR. No preset is transferred, nothing is stored.":
            "Stellt am verbundenen REACTOR den nächstliegenden Amp, Gain, Klangregler und Effekte ein. Kein Preset wird übertragen, nichts gespeichert.",
        "Show in Finder":
            "Im Finder zeigen",
        "Shows the controls":
            "Zeigt die Regler",
        "Single rigs (%d of %d chosen)":
            "Einzelne Rigs (%d von %d gewählt)",
        "Slot":
            "Platz",
        "Slot %@":
            "Platz %@",
        "Slot %d":
            "Platz %d",
        "Slot %d holds “%@” completely. Storing arrived despite the break.":
            "Platz %d enthält „%@“ vollständig. Das Speichern ist trotz des Abbruchs angekommen.",
        "Slot %d holds “%@”, neither the new nor the previous preset. The backup of “%@” is on this Mac.":
            "Platz %d enthält „%@“, weder das neue noch das bisherige Preset. Die Sicherung von „%@“ liegt auf dem Mac.",
        "Slot %d still holds the previous “%@”. Nothing was stored.":
            "Platz %d enthält noch das bisherige „%@“. Gespeichert wurde nichts.",
        "Starting Bluetooth …":
            "Starte Bluetooth …",
        "Store on %@":
            "Auf %@ speichern",
        "Store on %@ …":
            "Auf %@ speichern …",
        "Store on %@ … (now “%@”)":
            "Auf %@ speichern … (jetzt „%@“)",
        "Store on slot":
            "Auf Platz speichern",
        "Store “%@” on %@?":
            "„%@“ auf %@ speichern?",
        "Storing “%@” on %@ …":
            "Speichere „%@“ auf %@ …",
        "Suggestion %d":
            "Vorschlag %d",
        "Switch without saving":
            "Ohne Sichern wechseln",
        "SWITCHED":
            "UMGESCHALTET",
        "SWITCHING":
            "SCHALTET",
        "Switching to %@ …":
            "Schalte auf %@ …",
        "Tag %@":
            "Tag %@",
        "Tags":
            "Tags",
        "Template":
            "Vorlage",
        "Temporary · %@":
            "Vorübergehend · %@",
        "The amp did not answer.":
            "Der Verstärker hat nicht geantwortet.",
        "The amp did not switch to slot %d: %@":
            "Der Verstärker hat nicht auf Platz %d umgeschaltet: %@",
        "The amp is busy right now. Try again in a moment.":
            "Der Verstärker ist gerade beschäftigt. Versuch es gleich noch einmal.",
        "The amp is not connected.":
            "Der Verstärker ist nicht verbunden.",
        "The amp is not connected. Connect it, then the sound plays on the temporary place.":
            "Der Verstärker ist nicht verbunden. Verbinde ihn, dann spielt der Sound auf dem vorübergehenden Platz.",
        "The amp must be switched on, and the Spark app on the phone must not be connected.":
            "Der Verstärker muss eingeschaltet sein, und die Spark-App am Handy darf nicht verbunden sein.",
        "The amp plays this state, changes can be heard at once.":
            "Der Verstärker spielt diesen Stand, Änderungen sind sofort hörbar.",
        "The amp sent a preset that cannot be read (%@).":
            "Der Verstärker hat ein Preset geschickt, das nicht lesbar ist (%@).",
        "The change did not arrive on the amp: %@":
            "Die Änderung kam nicht am Verstärker an: %@",
        "The connection broke while storing on %@. As soon as the amp is back, the app checks what is there. The backup of “%@” is on this Mac.":
            "Die Verbindung brach beim Speichern auf %@ ab. Sobald der Verstärker wieder da ist, prüft die App, was dort liegt. Die Sicherung von „%@“ ist auf dem Mac.",
        "The connection was gone. The edited state plays on the amp again.":
            "Die Verbindung war weg. Der bearbeitete Stand spielt wieder am Verstärker.",
        "The file could not be brought back: %@":
            "Die Datei konnte nicht zurückgeholt werden: %@",
        "The first change sends the preset to the amp, without overwriting a slot.":
            "Die erste Änderung schickt das Preset zum Verstärker, ohne einen Platz zu überschreiben.",
        "The folder “%@” cannot be read: %@":
            "Der Ordner „%@“ ist nicht lesbar: %@",
        "The key is kept in your macOS keychain and is sent only to Ollama (ollama.com) when you have a sound created.":
            "Der Schlüssel liegt in deinem macOS-Schlüsselbund und wird nur an Ollama (ollama.com) gesendet, wenn du einen Sound erzeugen lässt.",
        "The preset could not be saved: %@":
            "Das Preset konnte nicht gesichert werden: %@",
        "The recipe could not be read as a preset.":
            "Das Rezept ließ sich nicht als Preset lesen.",
        "The sound could not be described as text: %@":
            "Der Sound ließ sich nicht als Text beschreiben: %@",
        "The sound did not fully arrive on the %@: %@":
            "Der Sound kam nicht ganz am %@ an: %@",
        "The sound on the %@ is lost when it disconnects. Save it as a preset first?":
            "Der Sound auf dem %@ geht beim Trennen verloren. Vorher als Preset sichern?",
        "The Spark app on the phone can use it now":
            "Die Spark-App am Handy kann ihn jetzt nutzen",
        "The text for REACTOR is copied. Paste it into “Text to Tone” in the REACTOR app; the REACTOR interprets it itself and chooses its own models.":
            "Der Text für REACTOR ist kopiert. Füge ihn in der REACTOR-App bei „Text to Tone“ ein; der REACTOR deutet ihn selbst und wählt eigene Modelle.",
        "The value is not a number.":
            "Der Wert ist keine Zahl.",
        "There are no rigs in the file.":
            "In der Datei sind keine Rigs.",
        "This model has no adjustable controls.":
            "Dieses Modell hat keine einstellbaren Regler.",
        "This preset has %d effects instead of 7. The places are therefore numbered.":
            "Dieses Preset hat %d statt 7 Effekte. Die Plätze sind daher nummeriert.",
        "This preset is no longer on this Mac. Choose another sound.":
            "Dieses Preset ist nicht mehr auf dem Mac. Wähle einen anderen Sound.",
        "This sound’s settings cannot be read.":
            "Die Einstellungen dieses Sounds sind nicht lesbar.",
        "Tip: %@":
            "Tipp: %@",
        "Transfer":
            "Übertragung",
        "Tuner on the REACTOR":
            "Stimmgerät am REACTOR",
        "Unchanged":
            "Unverändert",
        "Undo":
            "Rückgängig",
        "Undo (⌘Z)":
            "Rückgängig (⌘Z)",
        "unknown":
            "unbekannt",
        "Unreadable":
            "Nicht lesbar",
        "Value %@":
            "Wert %@",
        "Warm jazz sound":
            "Warmer Jazz-Sound",
        "What is on %@ now is first read fresh from the amp and saved to this Mac. Then the slot is read back as a check.":
            "Was jetzt auf %@ liegt, wird vorher frisch vom Verstärker gelesen und auf dem Mac gesichert. Danach wird der Platz zur Kontrolle zurückgelesen.",
        "What is on %@ now, “%@”, is first read fresh from the amp and saved to this Mac. Then the slot is read back as a check.":
            "Was jetzt auf %@ liegt, „%@“, wird vorher frisch vom Verstärker gelesen und auf dem Mac gesichert. Danach wird der Platz zur Kontrolle zurückgelesen.",
        "When read back, the slot did not hold “%@”. The backup is in the library.":
            "Beim Zurücklesen enthielt der Platz nicht „%@“. Die Sicherung liegt in der Bibliothek.",
        "Without saving, the changes are lost.":
            "Ohne Sichern gehen die Änderungen verloren.",
        "without signal":
            "ohne Signal",
        "Without: %@":
            "Ohne: %@",
        "“%@” could not be changed: %@":
            "„%@“ ließ sich nicht ändern: %@",
        "“%@” could not be moved to the Trash: %@":
            "„%@“ konnte nicht in den Papierkorb: %@",
        "“%@” has unsaved changes.":
            "„%@“ hat ungesicherte Änderungen.",
        "“%@” is already saved to this Mac, as “%@”.":
            "„%@“ ist schon auf dem Mac gesichert, als „%@“.",
        "“%@” is in the Trash.":
            "„%@“ liegt im Papierkorb.",
        "“%@” is ready.":
            "„%@“ ist bereit.",
        "“%@” is saved to this Mac as a new preset.":
            "„%@“ ist als neues Preset auf dem Mac gesichert.",
        "“%@” is saved to this Mac.":
            "„%@“ ist auf dem Mac gesichert.",
        "“%@” is stored on %@ and checked. The previous “%@” is on this Mac as a backup.":
            "„%@“ ist auf %@ gespeichert und geprüft. Das bisherige „%@“ liegt als Sicherung auf dem Mac.",
        "“%@” plays for trying out. Nothing is stored, a preset change ends it.":
            "„%@“ spielt zum Ausprobieren. Gespeichert ist nichts, ein Preset-Wechsel beendet es.",
        "“%@” – every suggestion appears as soon as it is ready. “Listen” plays it on the amp, nothing is stored. The buttons below refine only that suggestion. Only “Keep” puts it into your library.":
            "„%@“ – jeder Vorschlag erscheint, sobald er fertig ist. „Anhören“ spielt ihn am Verstärker, gespeichert wird nichts. Die Knöpfe darunter bessern nur diesen Vorschlag nach. Erst „Behalten“ legt ihn in deine Bibliothek.",
    ]
}
