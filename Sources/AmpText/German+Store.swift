extension German {
    static let store: [String: String] = [
        // Key
        "This is not a valid key. A key starts with AGE-SECRET-KEY-1.":
            "Das ist kein gültiger Schlüssel. Ein Schlüssel beginnt mit AGE-SECRET-KEY-1.",
        "This is not a valid public key. It starts with age1.":
            "Das ist kein gültiger öffentlicher Schlüssel. Er beginnt mit age1.",
        "The encrypted file is damaged or incomplete.": "Die verschlüsselte Datei ist beschädigt oder unvollständig.",
        "The file was encrypted for a different key.": "Die Datei wurde für einen anderen Schlüssel verschlüsselt.",
        "The keychain could not be used (error %d).": "Der Schlüsselbund ließ sich nicht verwenden (Fehler %d).",

        // Store
        "The store was asked for a file name it does not use.":
            "Der Store wurde nach einem Dateinamen gefragt, den er nicht verwendet.",
        "This key does not open the store. Enter the key the store was set up with.":
            "Dieser Schlüssel öffnet den Store nicht. Gib den Schlüssel ein, mit dem der Store eingerichtet wurde.",
        "The store's index is damaged. Nothing was changed.":
            "Das Verzeichnis des Stores ist beschädigt. Nichts wurde geändert.",
        "The store was written by a newer version of AmpBench (format %d). Update AmpBench on this device.":
            "Der Store wurde von einer neueren Version von AmpBench geschrieben (Format %d). Aktualisiere AmpBench auf diesem Gerät.",
        "The store's index names a file outside the sounds folder. Nothing was changed.":
            "Das Verzeichnis des Stores nennt eine Datei außerhalb des Sound-Ordners. Nichts wurde geändert.",
        "The store has no data for “%@”. Nothing was changed.":
            "Der Store hat keine Daten für „%@“. Nichts wurde geändert.",
        "The stored data for “%@” is damaged. Nothing was changed.":
            "Die gespeicherten Daten für „%@“ sind beschädigt. Nichts wurde geändert.",
        "The store's settings are incomplete.": "Die Einstellungen des Stores sind unvollständig.",

        // Places
        "The server name may only hold letters, digits, dots, hyphens, underscores and @.":
            "Der Servername darf nur Buchstaben, Ziffern, Punkte, Bindestriche, Unterstriche und @ enthalten.",
        "The folder on the server may only hold letters, digits, dots, hyphens, underscores, slashes and ~.":
            "Der Ordner auf dem Server darf nur Buchstaben, Ziffern, Punkte, Bindestriche, Unterstriche, Schrägstriche und ~ enthalten.",
        "The server could not be reached over SSH: %@": "Der Server war über SSH nicht erreichbar: %@",
        "A store over SSH works only on the Mac. Use a folder or an HTTPS address on this device.":
            "Ein Store über SSH funktioniert nur am Mac. Verwende auf diesem Gerät einen Ordner oder eine HTTPS-Adresse.",
        "The address must start with https://.": "Die Adresse muss mit https:// beginnen.",
        "This is not a valid address.": "Das ist keine gültige Adresse.",
        "The server refused the user name or password (HTTP %d).":
            "Der Server hat Benutzername oder Passwort abgelehnt (HTTP %d).",
        "The server has no space left for the store.": "Der Server hat keinen Platz mehr für den Store.",
        "The server answered with an error (HTTP %d).": "Der Server hat mit einem Fehler geantwortet (HTTP %d).",
        "Folder": "Ordner",
        "Folder “%@”": "Ordner „%@“",
        "Server %@ (SSH)": "Server %@ (SSH)",
        "Server %@ (HTTPS)": "Server %@ (HTTPS)",
        "Server (HTTPS)": "Server (HTTPS)",

        // Report
        "The store is up to date: %d sounds.": "Der Store ist aktuell: %d Sounds.",
        "%d stored": "%d gespeichert",
        "%d fetched": "%d geholt",
        "%d removed in the store": "%d im Store entfernt",
        "%d removed here": "%d hier entfernt",
        "Store: %@.": "Store: %@.",

        // The app: sidebar, sheet, menus
        "Sound store":
            "Sound-Store",
        "Sound store …":
            "Sound-Store …",
        "Sync the sound store now":
            "Sound-Store jetzt abgleichen",
        "Sync":
            "Abgleichen",
        "Set up":
            "Einrichten",
        "not set up":
            "nicht eingerichtet",
        "syncing …":
            "gleicht ab …",
        "last sync failed":
            "letzter Abgleich fehlgeschlagen",
        "not synced yet":
            "noch nicht abgeglichen",
        "in step · %@":
            "abgeglichen · %@",
        "Opens the sound store’s settings.":
            "Öffnet die Einstellungen des Sound-Stores.",
        "Stores this device’s sounds encrypted and fetches the sounds of your other devices.":
            "Speichert die Sounds dieses Geräts verschlüsselt und holt die Sounds deiner anderen Geräte.",
        "Keeps your sounds encrypted in a place you choose: a folder, your own server or a cloud drive.":
            "Bewahrt deine Sounds verschlüsselt an einem Ort deiner Wahl auf: in einem Ordner, auf deinem eigenen Server oder in einem Cloud-Laufwerk.",
        "Your sounds are encrypted on this device and kept in a place you choose. Whoever runs that place sees only unreadable files. Other devices with the same key get the same sounds.":
            "Deine Sounds werden auf diesem Gerät verschlüsselt und an einem Ort deiner Wahl aufbewahrt. Wer diesen Ort betreibt, sieht nur unlesbare Dateien. Andere Geräte mit demselben Schlüssel bekommen dieselben Sounds.",
        "Place":
            "Ort",
        "Server (SSH)":
            "Server (SSH)",
        "No folder chosen":
            "Kein Ordner gewählt",
        "Choose folder …":
            "Ordner wählen …",
        "Any folder works, also one that a cloud drive keeps in step: iCloud Drive, Google Drive, Dropbox or a network share.":
            "Jeder Ordner geht, auch einer, den ein Cloud-Laufwerk abgleicht: iCloud Drive, Google Drive, Dropbox oder eine Netzwerkfreigabe.",
        "Server, as ssh knows it":
            "Server, wie ssh ihn kennt",
        "Folder on the server":
            "Ordner auf dem Server",
        "Uses this Mac’s ssh with your own keys and ~/.ssh/config. AmpBench stores no login.":
            "Verwendet das ssh dieses Mac mit deinen eigenen Schlüsseln und ~/.ssh/config. AmpBench speichert keine Anmeldung.",
        "Address":
            "Adresse",
        "User name":
            "Benutzername",
        "Password":
            "Passwort",
        "A WebDAV folder or any HTTPS address that takes GET and PUT, such as Nextcloud or your own server. The password is kept in the keychain.":
            "Ein WebDAV-Ordner oder jede HTTPS-Adresse, die GET und PUT annimmt, etwa Nextcloud oder dein eigener Server. Das Passwort liegt im Schlüsselbund.",
        "Store key":
            "Store-Schlüssel",
        "Copy":
            "Kopieren",
        "Hide":
            "Verbergen",
        "Whoever has this key can read your sounds, and without it nobody can, not even you. Keep a copy in your password manager, and enter it on your other devices. Never put it into a file that is shared or published.":
            "Wer diesen Schlüssel hat, kann deine Sounds lesen, und ohne ihn kann es niemand, auch du nicht. Bewahre eine Kopie in deinem Passwortmanager auf und gib ihn auf deinen anderen Geräten ein. Lege ihn nie in eine Datei, die geteilt oder veröffentlicht wird.",
        "This device has its key, in the keychain.":
            "Dieses Gerät hat seinen Schlüssel, im Schlüsselbund.",
        "Show key …":
            "Schlüssel zeigen …",
        "Your other devices need the same key. Show it here and enter it there.":
            "Deine anderen Geräte brauchen denselben Schlüssel. Zeige ihn hier und gib ihn dort ein.",
        "Create a new key":
            "Neuen Schlüssel erzeugen",
        "for a new store":
            "für einen neuen Store",
        "Use this key":
            "Diesen Schlüssel verwenden",
        "Enter the key of a store you already have, as shown on the device that made it.":
            "Gib den Schlüssel eines Stores ein, den du schon hast, so wie ihn das Gerät zeigt, das ihn angelegt hat.",
        "Disconnect this device …":
            "Dieses Gerät trennen …",
        "Disconnect this device from the sound store?":
            "Dieses Gerät vom Sound-Store trennen?",
        "The sounds on this device and in the store stay as they are, and the key stays in the keychain. This device just no longer syncs.":
            "Die Sounds auf diesem Gerät und im Store bleiben, wie sie sind, und der Schlüssel bleibt im Schlüsselbund. Dieses Gerät gleicht nur nicht mehr ab.",
        "Save and sync":
            "Sichern und abgleichen",
        "The sound store could not be synced: %@":
            "Der Sound-Store ließ sich nicht abgleichen: %@",
        "The sound store is not set up on this device.":
            "Der Sound-Store ist auf diesem Gerät nicht eingerichtet.",
        "This device has no key for the sound store. Create one, or enter the key of your store.":
            "Dieses Gerät hat keinen Schlüssel für den Sound-Store. Erzeuge einen, oder gib den Schlüssel deines Stores ein.",
        "This device already has a key. Replacing it would lock it out of its store; enter another key on purpose if that is what you want.":
            "Dieses Gerät hat schon einen Schlüssel. Ihn zu ersetzen würde es aus seinem Store aussperren; gib bewusst einen anderen Schlüssel ein, wenn du das willst.",
        "The sound store is set up: %@.":
            "Der Sound-Store ist eingerichtet: %@.",
        "This device has no key yet: --store-key new makes one, --store-key set takes one you have.":
            "Dieses Gerät hat noch keinen Schlüssel: --store-key new erzeugt einen, --store-key set übernimmt einen, den du hast.",
        "A new key is in the keychain. Its public half: %@":
            "Ein neuer Schlüssel liegt im Schlüsselbund. Seine öffentliche Hälfte: %@",
        "The key is in the keychain. Its public half: %@":
            "Der Schlüssel liegt im Schlüsselbund. Seine öffentliche Hälfte: %@",
        "Write the key itself down: --store-key show prints it, and so does “Show key” in the app. Without it nobody can read the store.":
            "Schreib dir den Schlüssel selbst auf: --store-key show gibt ihn aus, „Schlüssel zeigen“ in der App ebenso. Ohne ihn kann niemand den Store lesen.",
        "stored":
            "gespeichert",
        "fetched":
            "geholt",
        "removed here":
            "hier entfernt",
        "removed in the store":
            "im Store entfernt",
        "Place: %@":
            "Ort: %@",
        "Key: in the keychain":
            "Schlüssel: im Schlüsselbund",
        "Key: none on this device":
            "Schlüssel: keiner auf diesem Gerät",
        "Last sync: %@":
            "Letzter Abgleich: %@",
        "Last sync: never":
            "Letzter Abgleich: nie",
        "Sounds folder: %@":
            "Sound-Ordner: %@",
    ]
}
