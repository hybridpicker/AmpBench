"""The German texts, keyed by the English text in the code. A test checks that every `tr("…")` has an entry.

Two tables: `de_core.py` for everything without a window, `de_ui.py` for the window. A key in both must have the
same German text."""
from .de_core import GERMAN_CORE
from .de_ui import GERMAN_UI

GERMAN_TEXTS: dict[str, str] = {**GERMAN_UI, **GERMAN_CORE}
