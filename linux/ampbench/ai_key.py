"""Where the Ollama API key is kept on Linux: the desktop's secret service through `secret-tool` (libsecret, the
GNOME keyring or KWallet), else a file only this user can read (~/.config/ampbench/ollama-key, mode 0600). The
key never goes into the settings, a log or the presets, only into the Authorization header of an AI Sound request."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

ATTRIBUTES = ["service", "ampbench", "account", "ollama"]
FILE = Path.home() / ".config" / "ampbench" / "ollama-key"
# Where the key was kept while the app was called Spark Studio. Read once, when the new place is empty.
OLD_ATTRIBUTES = ["service", "spark-studio", "account", "ollama"]
OLD_FILE = Path.home() / ".config" / "spark-studio" / "ollama-key"


def _secret_tool() -> str | None:
    return shutil.which("secret-tool")


def _read(attributes: list[str], file: Path) -> str:
    tool = _secret_tool()
    if tool:
        try:
            result = subprocess.run([tool, "lookup", *attributes], capture_output=True, text=True, timeout=5)
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            pass
    try:
        return file.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def load() -> str:
    key = _read(ATTRIBUTES, FILE)
    if key:
        return key
    # Carried over from the old name; the old entry stays where it is.
    key = _read(OLD_ATTRIBUTES, OLD_FILE)
    if key:
        save(key)
    return key


def save(key: str) -> str:
    """Stores the key and says where: "keyring" or "file". An empty key removes it everywhere."""
    key = key.strip()
    tool = _secret_tool()
    if not key:
        if tool:
            try:
                subprocess.run([tool, "clear", *ATTRIBUTES], capture_output=True, timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass
        try:
            FILE.unlink()
        except OSError:
            pass
        return ""
    if tool:
        try:
            result = subprocess.run([tool, "store", "--label=AmpBench: Ollama API key", *ATTRIBUTES],
                                    input=key, capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                try:
                    FILE.unlink()
                except OSError:
                    pass
                return "keyring"
        except (OSError, subprocess.TimeoutExpired):
            pass
    FILE.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(key)
    os.chmod(FILE, 0o600)
    return "file"
