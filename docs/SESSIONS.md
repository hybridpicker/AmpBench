# Sessions in diesem Arbeitsbaum

Jede Session trägt sich ein, aktualisiert vor und nach jedem Commit und löscht ihren Block, wenn sie fertig ist.
Vor jedem Commit: diese Datei lesen. Fremde Dateien „in Arbeit“ nicht anfassen. Kein stash, reset, checkout oder
Branchwechsel, nur eigene Dateien und Hunks committen.

Vorlage für einen Block:

```
## <Name> (<Auftrag>)
- Stand: <Datum Uhrzeit> – <ein Satz>
- In Arbeit: <Dateien oder Ordner>
- Fertig und committet: <Hashes>
- Baut oder testet gerade: ja/nein
- Bitten an die andere Session: <…>
```

Zurzeit arbeitet keine Session hier. Design (docs/DESIGN.md) und Studio (docs/STUDIO.md) sind abgeschlossen.
