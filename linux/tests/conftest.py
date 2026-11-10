import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ampbench import i18n  # noqa: E402

# Tests compare texts, so they run in English whatever the machine speaks.
i18n.set_language(i18n.ENGLISH)
