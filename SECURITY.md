# Security

## Reporting a problem

Please report security problems privately, not in a public issue: on GitHub, open the repository's **Security** tab
and choose **Report a vulnerability**. Say which version (`AmpBench --version`) and platform you use and how to
reproduce it. This is a one-person project, so an answer can take a few days.

Only the latest version on `main` is supported.

## What the app touches

- **Bluetooth LE** to the amp you choose, and nothing else on Bluetooth.
- **Audio input** from a USB device with "Spark" in its name; no other input and no fallback.
- **Network**: one HTTPS request to Ollama's cloud API, and only when you ask for an AI Sound. It carries your
  description of the sound. A description that looks like it holds an e-mail address or a phone number is refused
  before anything is sent. There is no telemetry and no update check.
- **The API key** for AI Sound is stored in the macOS Keychain, on Linux in the desktop's keyring. It is never written
  to a preset, a log or the library file.
- **Files**: recordings, the library and presets under `~/Music/AmpBench/`. A Kemper backup is only read.
- **The sound store**, only once you set it up: your presets go to the place you chose (a folder, a server over SSH
  or an HTTPS address), encrypted on the device with the age format. The place gets no names and no contents, only
  how many files there are, how large they are and when they changed. The store's key and a server password are in
  the keychain, on this device only; the place's address is in the app's preferences. None of it is written to a
  preset, a log or the repository. An HTTPS place must be `https://`. See [docs/STORE.md](docs/STORE.md).
- **On the iPad**: the audio input for the tuner only, never recorded or stored, and the same Bluetooth and network
  use as above.

## Risks worth knowing

- The amp's protocol is not documented by its maker. A wrong message can make an amp misbehave or get loud; the app
  limits what it sends (see "Protecting the amp" in [docs/STUDIO.md](docs/STUDIO.md)), but keep the volume low when
  you try something new.
- Preset and recipe files are plain JSON. Treat files from other people like any other download.
- Whoever has the sound store's key can read every sound in it, and without the key nobody can, you included. Keep
  a copy in a password manager. A device that syncs with a store takes its sounds: only use a key and a place you
  trust.

## Keeping secrets out of the repository

The repository is public and holds no key, password, host name or account id, and the app never writes one into a
file in it. Keys and passwords live in the keychain, the store's place in the app's preferences, the iPad build's
team id in `ios/Local.xcconfig` and the machines' names in `sync.local`; Git ignores both files. `./sync.sh` checks
every push for personal traces and runs `gitleaks`, which knows what an age key looks like.
