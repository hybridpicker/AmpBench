import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ampbench import i18n  # noqa: E402

# The tests run on the owner's machine before every install (linux/install.sh), so nothing they set may reach the
# app's real settings: on Linux QSettings keeps them as INI files, and those go to a folder of the test run.
try:
    import tempfile

    from PySide6.QtCore import QSettings

    QSettings.setPath(QSettings.NativeFormat, QSettings.UserScope, tempfile.mkdtemp(prefix="ampbench-test-settings-"))
    QSettings.setPath(QSettings.IniFormat, QSettings.UserScope, tempfile.mkdtemp(prefix="ampbench-test-settings-"))
except ImportError:
    pass

# Tests compare texts, so they run in English whatever the machine speaks.
i18n.set_language(i18n.ENGLISH)
