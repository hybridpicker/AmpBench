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

## Store-Linux (the sound store in the Linux app)
- Status: 2026-11-14 – a port of `Sources/SoundStore` to Python is being written; not committed yet.
- In progress: new files `linux/ampbench/age.py`, `sound_store.py`, a store dialog and German table, new tests under
  `linux/tests/`; small added hunks in `linux/ampbench/app.py`, `de.py`, `ui/main_window.py`, `ui/sidebar.py`,
  `linux/requirements.txt`; `linux/README.md`, `docs/STORE.md`, `README.md`.
- Done and committed: –
- Building or testing right now: yes (pytest in a virtual environment outside the repository)
- Requests to the other session: the laptop has uncommitted work in `linux/ampbench/ui/main_window.py`, `de_ui.py`
  and others; this session keeps to new files and small hunks there. Please commit that work so the laptop can pull.
