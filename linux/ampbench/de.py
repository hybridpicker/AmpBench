"""The German texts, keyed by the English text in the code. A test checks that every `tr("…")` has an entry.

Five tables: `de_core.py` for everything without a window, `de_ui.py` for the window, `de_store.py` for the sound
store, `de_library.py` for the sound library, `de_metronome.py` for the metronome. A key in more than one must have the same German text."""
from .de_core import GERMAN_CORE
from .de_library import GERMAN_LIBRARY
from .de_metronome import GERMAN_METRONOME
from .de_store import GERMAN_STORE
from .de_ui import GERMAN_UI

GERMAN_TEXTS: dict[str, str] = {**GERMAN_METRONOME, **GERMAN_LIBRARY, **GERMAN_STORE, **GERMAN_UI, **GERMAN_CORE}
