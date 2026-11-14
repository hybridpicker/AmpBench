"""The German texts, keyed by the English text in the code. A test checks that every `tr("…")` has an entry.

Three tables: `de_core.py` for everything without a window, `de_ui.py` for the window, `de_store.py` for the sound
store. A key in more than one must have the same German text."""
from .de_core import GERMAN_CORE
from .de_store import GERMAN_STORE
from .de_ui import GERMAN_UI

GERMAN_TEXTS: dict[str, str] = {**GERMAN_STORE, **GERMAN_UI, **GERMAN_CORE}
