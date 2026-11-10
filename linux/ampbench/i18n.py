"""The app's texts: English in the code, German from the table in `de.py`.

`tr("Cancel")` returns the text in the app's language. The English text is the key. Arguments go through
`str.format`: `tr("Slot {} of {}", slot, name)` or `tr("{count} takes", count=n)`.
"""
from __future__ import annotations

import locale
import os

ENGLISH = "en"
GERMAN = "de"
LANGUAGES = (ENGLISH, GERMAN)
ENVIRONMENT_KEY = "AMPBENCH_LANGUAGE"
SETTINGS_KEY = "language"

_language: str | None = None


def language_for(preferred: str | None) -> str:
    """German for a German locale name such as `de_AT.UTF-8`, English for everything else."""
    name = (preferred or "").lower()
    return GERMAN if name == "de" or name.startswith(("de_", "de-", "de.", "de@")) else ENGLISH


def _system() -> str:
    for key in ("LC_ALL", "LC_MESSAGES", "LANGUAGE", "LANG"):
        value = os.environ.get(key)
        if value:
            return language_for(value.split(":")[0])
    try:
        return language_for(locale.getlocale()[0])
    except (ValueError, TypeError):
        return ENGLISH


def decide(override: str | None = None) -> str:
    """Environment, then the user's choice (`override`), then the system's language."""
    forced = os.environ.get(ENVIRONMENT_KEY)
    if forced in LANGUAGES:
        return forced
    if override in LANGUAGES:
        return override
    return _system()


def language() -> str:
    global _language
    if _language is None:
        _language = decide()
    return _language


def set_language(value: str) -> None:
    global _language
    if value not in LANGUAGES:
        raise ValueError(f"unknown language: {value}")
    _language = value


def german(english: str) -> str | None:
    from .de import GERMAN_TEXTS
    return GERMAN_TEXTS.get(english)


def tr(english: str, *args, **kwargs) -> str:
    text = (german(english) or english) if language() == GERMAN else english
    return text.format(*args, **kwargs) if args or kwargs else text


def number(value: float, digits: int = 1) -> str:
    """A number with the language's decimal sign: `1.5` in English, `1,5` in German."""
    text = f"{value:.{digits}f}"
    return text.replace(".", ",") if language() == GERMAN else text
