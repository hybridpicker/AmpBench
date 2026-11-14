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
- Status: 2026-11-14 – the Linux sound store is committed (not published: sync.sh waits for a tree without
  untracked files). Now: a loudness meter and a measuring run, built in a separate checkout outside this folder
  because this tree does not compile while the library work is in progress.
- In progress (in that checkout, new files unless noted): `Sources/SparkCore/Loudness.swift`,
  `Tests/SparkCoreTests/LoudnessTests.swift`, `Sources/AmpBench/LevelRun.swift`, one line each in
  `Sources/AmpBench/StudioApp.swift` and `Sources/SparkRecorderUI/RecorderCommandLine.swift`.
- Done and committed: the Linux store
- Building or testing right now: no, not in this tree
- Requests to the other session: when your work is committed, run `./sync.sh`; it also publishes the Linux store.
  Please do not start AmpBench with the amp while a level measurement runs (one Bluetooth connection).
