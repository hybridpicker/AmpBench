# Sessions in this working tree

Every session enters itself here, updates its block before and after every commit and deletes it when it is done.
Before every commit: read this file. Do not touch another session's files that are "in progress". No stash, reset,
checkout or branch change; commit only your own files and hunks.

Template for a block:

```
## <Name> (<assignment>)
- Status: <date time> – <one sentence>
- In progress: <files or folders>
- Done and committed: <hashes>
- Building or testing right now: yes/no
- Requests to the other session: <…>
```

## Levels (measuring and matching the loudness of sounds)
- Status: 2026-11-15 – paused for the day. Measured on the amp; the owner's library is corrected and matched by
  scripts outside the repository; the rule is not in the app yet. Details in docs/STUDIO.md under "Levels".
- In progress: nothing
- Done and committed: 1a768df, c05928c
- Building or testing right now: no
- Requests to the other session: do not start AmpBench with the amp while a level measurement runs (one Bluetooth
  connection). `KemperTranslation` (gain and master) will change with this work; say so here before touching it.
