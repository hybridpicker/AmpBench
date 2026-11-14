"""The German texts of the sound store (age.py, store_places.py, sound_store.py, store_profile.py, store_cli.py,
ui/store_view.py), keyed by the English text in the code. The wording is the Mac app's
(Sources/AmpText/German+Store.swift); texts both tables share, such as "Cancel", stay in de_ui.py."""

GERMAN_STORE: dict[str, str] = {
    "This is not a valid key. A key starts with AGE-SECRET-KEY-1.":
        "Das ist kein gültiger Schlüssel. Ein Schlüssel beginnt mit AGE-SECRET-KEY-1.",
    "This is not a valid public key. It starts with age1.":
        "Das ist kein gültiger öffentlicher Schlüssel. Er beginnt mit age1.",
    "The encrypted file is damaged or incomplete.": "Die verschlüsselte Datei ist beschädigt oder unvollständig.",
    "The file was encrypted for a different key.": "Die Datei wurde für einen anderen Schlüssel verschlüsselt.",
    "The store's settings are incomplete.": "Die Einstellungen des Stores sind unvollständig.",
    "The store was asked for a file name it does not use.":
        "Der Store wurde nach einem Dateinamen gefragt, den er nicht verwendet.",
    "This key does not open the store. Enter the key the store was set up with.":
        "Dieser Schlüssel öffnet den Store nicht. Gib den Schlüssel ein, mit dem der Store eingerichtet wurde.",
    "The store's index is damaged. Nothing was changed.":
        "Das Verzeichnis des Stores ist beschädigt. Nichts wurde geändert.",
    "The store was written by a newer version of AmpBench (format {}). Update AmpBench on this device.":
        "Der Store wurde von einer neueren Version von AmpBench geschrieben (Format {}). Aktualisiere AmpBench auf diesem Gerät.",
    "The store's index names a file outside the sounds folder. Nothing was changed.":
        "Das Verzeichnis des Stores nennt eine Datei außerhalb des Sound-Ordners. Nichts wurde geändert.",
    "The store has no data for “{}”. Nothing was changed.":
        "Der Store hat keine Daten für „{}“. Nichts wurde geändert.",
    "The stored data for “{}” is damaged. Nothing was changed.":
        "Die gespeicherten Daten für „{}“ sind beschädigt. Nichts wurde geändert.",
    "The server name may only hold letters, digits, dots, hyphens, underscores and @.":
        "Der Servername darf nur Buchstaben, Ziffern, Punkte, Bindestriche, Unterstriche und @ enthalten.",
    "The folder on the server may only hold letters, digits, dots, hyphens, underscores, slashes and ~.":
        "Der Ordner auf dem Server darf nur Buchstaben, Ziffern, Punkte, Bindestriche, Unterstriche, Schrägstriche und ~ enthalten.",
    "The server could not be reached over SSH: {}": "Der Server war über SSH nicht erreichbar: {}",
    "The address must start with https://.": "Die Adresse muss mit https:// beginnen.",
    "This is not a valid address.": "Das ist keine gültige Adresse.",
    "The server refused the user name or password (HTTP {}).":
        "Der Server hat Benutzername oder Passwort abgelehnt (HTTP {}).",
    "The server has no space left for the store.": "Der Server hat keinen Platz mehr für den Store.",
    "The server answered with an error (HTTP {}).": "Der Server hat mit einem Fehler geantwortet (HTTP {}).",
    "Store: {}.": "Store: {}.",
    "Checked: all {} sounds in the store can be read. {} differ from this device; a sync brings them in step.":
        "Geprüft: Alle {} Sounds im Store sind lesbar. {} weichen von diesem Gerät ab; ein Abgleich bringt sie in Einklang.",
    "The store is up to date: {} sounds.": "Der Store ist aktuell: {} Sounds.",
    "The store is damaged: {} of its sounds cannot be restored.":
        "Der Store ist beschädigt: {} seiner Sounds lassen sich nicht wiederherstellen.",
    "Checked: all {} sounds in the store can be read and equal the ones here.":
        "Geprüft: Alle {} Sounds im Store sind lesbar und gleich denen hier.",
    "{} stored": "{} gespeichert",
    "{} fetched": "{} geholt",
    "{} removed in the store": "{} im Store entfernt",
    "{} removed here": "{} hier entfernt",
    "Server {} (SSH)": "Server {} (SSH)",
    "Server {} (HTTPS)": "Server {} (HTTPS)",
    "Server (HTTPS)": "Server (HTTPS)",
    "Folder “{}”": "Ordner „{}“",
    "Folder": "Ordner",
    "The sound store is not set up on this device.": "Der Sound-Store ist auf diesem Gerät nicht eingerichtet.",
    "This device has no key for the sound store. Create one, or enter the key of your store.":
        "Dieses Gerät hat keinen Schlüssel für den Sound-Store. Erzeuge einen, oder gib den Schlüssel deines Stores ein.",
    "This device already has a key. Replacing it would lock it out of its store; enter another key on purpose if that is what you want.":
        "Dieses Gerät hat schon einen Schlüssel. Ihn zu ersetzen würde es aus seinem Store aussperren; gib bewusst einen anderen Schlüssel ein, wenn du das willst.",
    "The sound store is set up: {}.": "Der Sound-Store ist eingerichtet: {}.",
    "Place: {}": "Ort: {}",
    "Sounds folder: {}": "Sound-Ordner: {}",
    "This device has no key yet: --store-key new makes one, --store-key set takes one you have.":
        "Dieses Gerät hat noch keinen Schlüssel: --store-key new erzeugt einen, --store-key set übernimmt einen, den du hast.",
    "Write the key itself down: --store-key show prints it, and so does “Show key” in the app. Without it nobody can read the store.":
        "Schreib dir den Schlüssel selbst auf: --store-key show gibt ihn aus, „Schlüssel zeigen“ in der App ebenso. Ohne ihn kann niemand den Store lesen.",
    "stored": "gespeichert",
    "fetched": "geholt",
    "removed here": "hier entfernt",
    "removed in the store": "im Store entfernt",
    "missing in the store": "fehlt im Store",
    "damaged in the store": "im Store beschädigt",
    "differs here": "weicht hier ab",
    "only in the store": "nur im Store",
    "only here": "nur hier",
    "Key: none on this device": "Schlüssel: keiner auf diesem Gerät",
    "Last sync: {}": "Letzter Abgleich: {}",
    "Last sync: never": "Letzter Abgleich: nie",
    "The sound store could not be synced: {}": "Der Sound-Store ließ sich nicht abgleichen: {}",
    "Sound store": "Sound-Store",
    "not set up": "nicht eingerichtet",
    "syncing …": "gleicht ab …",
    "last sync failed": "letzter Abgleich fehlgeschlagen",
    "in step · {}": "abgeglichen · {}",
    "not synced yet": "noch nicht abgeglichen",
    "Opens the sound store’s settings.": "Öffnet die Einstellungen des Sound-Stores.",
    "Disconnect this device …": "Dieses Gerät trennen …",
    "Save and sync": "Sichern und abgleichen",
    "Choose folder …": "Ordner wählen …",
    "Server, as ssh knows it": "Server, wie ssh ihn kennt",
    "Folder on the server": "Ordner auf dem Server",
    "Address": "Adresse",
    "User name": "Benutzername",
    "Password": "Passwort",
    "Create a new key": "Neuen Schlüssel erzeugen",
    "Store key": "Store-Schlüssel",
    "Use this key": "Diesen Schlüssel verwenden",
    "Show key …": "Schlüssel zeigen …",
    "Copy": "Kopieren",
    "Hide": "Verbergen",
    "Disconnect this device from the sound store?": "Dieses Gerät vom Sound-Store trennen?",
    "Sync the sound store now": "Sound-Store jetzt abgleichen",
    "Sound store …": "Sound-Store …",
    "Sync": "Abgleichen",
    "Stores this device’s sounds encrypted and fetches the sounds of your other devices.":
        "Speichert die Sounds dieses Geräts verschlüsselt und holt die Sounds deiner anderen Geräte.",
    "Set up": "Einrichten",
    "Keeps your sounds encrypted in a place you choose: a folder, your own server or a cloud drive.":
        "Bewahrt deine Sounds verschlüsselt an einem Ort deiner Wahl auf: in einem Ordner, auf deinem eigenen Server oder in einem Cloud-Laufwerk.",
    "Your sounds are encrypted on this device and kept in a place you choose. Whoever runs that place sees only unreadable files. Other devices with the same key get the same sounds.":
        "Deine Sounds werden auf diesem Gerät verschlüsselt und an einem Ort deiner Wahl aufbewahrt. Wer diesen Ort betreibt, sieht nur unlesbare Dateien. Andere Geräte mit demselben Schlüssel bekommen dieselben Sounds.",
    "Place": "Ort",
    "Server (SSH)": "Server (SSH)",
    "No folder chosen": "Kein Ordner gewählt",
    "for a new store": "für einen neuen Store",
    "Enter the key of a store you already have, as shown on the device that made it.":
        "Gib den Schlüssel eines Stores ein, den du schon hast, so wie ihn das Gerät zeigt, das ihn angelegt hat.",
    "Your other devices need the same key. Show it here and enter it there.":
        "Deine anderen Geräte brauchen denselben Schlüssel. Zeige ihn hier und gib ihn dort ein.",
    "Whoever has this key can read your sounds, and without it nobody can, not even you. Keep a copy in your password manager, and enter it on your other devices. Never put it into a file that is shared or published.":
        "Wer diesen Schlüssel hat, kann deine Sounds lesen, und ohne ihn kann es niemand, auch du nicht. Bewahre eine Kopie in deinem Passwortmanager auf und gib ihn auf deinen anderen Geräten ein. Lege ihn nie in eine Datei, die geteilt oder veröffentlicht wird.",
    "The server could not be reached: {}": "Der Server war nicht erreichbar: {}",
    "in the desktop's keyring": "im Schlüsselbund des Desktops",
    "in a file only you can read": "in einer Datei, die nur du lesen kannst",
    "A new key is kept {}. Its public half: {}": "Ein neuer Schlüssel liegt {}. Seine öffentliche Hälfte: {}",
    "The key is kept {}. Its public half: {}": "Der Schlüssel liegt {}. Seine öffentliche Hälfte: {}",
    "Key: {}": "Schlüssel: {}",
    "This device has its key, {}.": "Dieses Gerät hat seinen Schlüssel, {}.",
    "The sounds on this device and in the store stay as they are, and the key stays where it is. This device just no longer syncs.":
        "Die Sounds auf diesem Gerät und im Store bleiben, wie sie sind, und der Schlüssel bleibt, wo er ist. Dieses Gerät gleicht nur nicht mehr ab.",
    "Any folder works, also one that a cloud drive keeps in step: Nextcloud, Google Drive, Dropbox or a network share.":
        "Jeder Ordner geht, auch einer, den ein Cloud-Laufwerk abgleicht: Nextcloud, Google Drive, Dropbox oder eine Netzwerkfreigabe.",
    "Uses this computer’s ssh with your own keys and ~/.ssh/config. AmpBench stores no login.":
        "Verwendet das ssh dieses Computers mit deinen eigenen Schlüsseln und ~/.ssh/config. AmpBench speichert keine Anmeldung.",
    "A WebDAV folder or any HTTPS address that takes GET and PUT, such as Nextcloud or your own server. The password is kept in your desktop's keyring, otherwise in a file only you can read.":
        "Ein WebDAV-Ordner oder jede HTTPS-Adresse, die GET und PUT annimmt, etwa Nextcloud oder dein eigener Server. Das Passwort liegt im Schlüsselbund deines Desktops, sonst in einer Datei, die nur du lesen kannst.",
}
