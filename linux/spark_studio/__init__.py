"""Spark Studio for Linux: the Presets area of the Mac app, for Omarchy and other Linux desktops."""
from __future__ import annotations

from pathlib import Path


def _read(name: str) -> str | None:
    here = Path(__file__).resolve().parent
    for candidate in (here / name, here.parent / name, here.parent.parent / name):
        if candidate.is_file():
            return candidate.read_text(encoding="utf-8").strip()
    return None


# VERSION is the one version file of the whole repository. The Mac build and the Linux install both read it,
# and ``sync.sh`` writes BUILD (the commit) next to it, so ``--version`` reads the same on both machines.
VERSION = _read("VERSION") or "0.0.0"
BUILD = _read("BUILD") or "dev"


def version_line() -> str:
    return f"Spark Studio {VERSION} ({BUILD})"
