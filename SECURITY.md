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

## Risks worth knowing

- The amp's protocol is not documented by its maker. A wrong message can make an amp misbehave or get loud; the app
  limits what it sends (see "Protecting the amp" in [docs/STUDIO.md](docs/STUDIO.md)), but keep the volume low when
  you try something new.
- Preset and recipe files are plain JSON. Treat files from other people like any other download.
