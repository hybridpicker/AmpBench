# Sessions in diesem Arbeitsbaum

Jede Session trägt sich ein, aktualisiert vor und nach jedem Commit und löscht ihren Block, wenn sie fertig ist.
Vor jedem Commit: diese Datei lesen. Fremde Dateien „in Arbeit“ nicht anfassen.

## Design (docs/spark-design-prompt.md)
- Stand: (noch nicht eingetragen – laut git status in Arbeit: Package.swift, Sources/SparkDesign/, Tests/SparkDesignTests/)
- In Arbeit: …
- Fertig und committet: …
- Baut oder testet gerade: ja/nein
- Bitten an die andere Session: …

## Studio (docs/spark-studio-prompt.md)
- Stand: 2026-11-07 19:00 – Stufe 0 fertig, wird committet (nur neue Dateien + additive Felder in SparkCore/Models.swift); Stufe 1 wartet auf Design-Meilenstein 1 (Target SparkDesign committet)
- In Arbeit: docs/STUDIO.md, docs/SESSIONS.md (mein Block), Sources/SparkCore/Models.swift (nur Recording/Piece-Felder), Sources/SparkCore/PresetStamp.swift, Sources/SparkCore/StudioKeymap.swift, Sources/SparkControl/Library/PresetFingerprint.swift, Tests/SparkCoreTests/PresetStampTests.swift, Tests/SparkCoreTests/StudioKeymapTests.swift, Tests/SparkControlTests/PresetFingerprintTests.swift
- Fertig und committet: –
- Baut oder testet gerade: nein
- Bitten an die andere Session: Package.swift, Sources/SparkRecorder, Sources/SparkPresets, Sources/SparkDesign, README.md fasse ich in Stufe 0 nicht an. Bitte deinen Block oben ausfüllen. Deine gestagten Löschungen (Theme.swift u. a.) bleiben unberührt, ich committe nur mit expliziten Pfaden. Frage: Das Canvas zeigt „Exportieren ⌘E“, ⌘E ist heute Umbenennen in beiden Apps (Regel: Kürzel nicht ändern). Vorschlag in docs/STUDIO.md: Exportieren ⇧⌘E. Bitte nicht ohne Rücksprache mit dem Nutzer umbelegen.
