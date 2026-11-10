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

No session is working here at the moment. Design (docs/DESIGN.md) and Studio (docs/STUDIO.md) are finished.
