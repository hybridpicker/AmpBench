"""The app was called "Spark Studio" until version 1.0. This carries its folder and settings over to the new name,
once, at the start: nothing is overwritten and nothing is deleted. A folder is renamed, a settings file is copied.

The names inside the folder were German until the app went public. The folder of the takes is renamed here; the
files inside it are renamed where a library is opened (store.LibraryStore.carry_over_names), because a recordings
folder can also be given on the command line."""
from __future__ import annotations

import os
import shutil
from pathlib import Path

OLD_NAME = "Spark Studio"
NEW_NAME = "AmpBench"


def carry_over(home: Path | None = None) -> list[str]:
    """Returns what was carried over, for the log: "folder", "settings", "recordings"."""
    home = home or Path.home()
    done: list[str] = []
    old_folder, new_folder = home / "Music" / OLD_NAME, home / "Music" / NEW_NAME
    if old_folder.is_dir() and not new_folder.exists():
        try:
            old_folder.rename(new_folder)
            done.append("folder")
        except OSError:
            pass
    old_settings = home / ".config" / "local.sparkstudio" / f"{OLD_NAME}.conf"
    new_settings = home / ".config" / "local.ampbench" / f"{NEW_NAME}.conf"
    if old_settings.is_file() and not new_settings.exists():
        try:
            new_settings.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(old_settings, new_settings)
            done.append("settings")
        except OSError:
            pass
    # After the folder above, so that takes from the time of Spark Studio are reached too. A rename that fails leaves
    # the folder as it is; store.default_folder() then keeps using it under its old name.
    old_takes, new_takes = new_folder / "Aufnahmen", new_folder / "Recordings"
    if old_takes.is_dir() and not os.path.lexists(new_takes):
        try:
            old_takes.rename(new_takes)
            done.append("recordings")
        except OSError:
            pass
    return done
