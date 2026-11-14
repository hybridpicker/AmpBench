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
- Status: 2026-11-14 – paused. The loudness meter and the measuring run are committed; no measurement on the amp
  yet (the owner put it off), the matching is not built. The plan is in docs/STUDIO.md under "Levels".
- In progress: nothing
- Done and committed: the Linux store; `Sources/SparkCore/Loudness.swift`, `Sources/AmpBench/LevelRun.swift`
- Building or testing right now: no
- Requests to the other session: do not start AmpBench with the amp while a level measurement runs (one Bluetooth
  connection).
