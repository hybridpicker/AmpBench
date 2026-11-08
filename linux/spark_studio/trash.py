"""The freedesktop trash (``~/.local/share/Trash``): files go there with a ``.trashinfo``, never away, and can come
back. Used for discarded takes and removed presets; the Mac app uses the Finder's Trash the same way."""
from __future__ import annotations

import os
import shutil
import urllib.parse
from datetime import datetime
from pathlib import Path


def trash_root() -> Path:
    base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(base) / "Trash"


def move(path: Path, root: Path | None = None) -> Path:
    """Moves ``path`` to the trash and returns where it is now."""
    root = root or trash_root()
    files, info = root / "files", root / "info"
    files.mkdir(parents=True, exist_ok=True)
    info.mkdir(parents=True, exist_ok=True)
    path = path.resolve()
    name, number = path.name, 1
    target = files / name
    while target.exists() or (info / f"{target.name}.trashinfo").exists():
        number += 1
        target = files / f"{path.stem} {number}{path.suffix}"
    stamp = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    (info / f"{target.name}.trashinfo").write_text(
        f"[Trash Info]\nPath={urllib.parse.quote(str(path))}\nDeletionDate={stamp}\n", encoding="utf-8")
    try:
        os.rename(path, target)
    except OSError:  # another file system
        shutil.move(str(path), str(target))
    return target


def restore(trashed: Path, destination: Path, root: Path | None = None) -> Path:
    """Puts a trashed file back. An existing file at ``destination`` is never overwritten."""
    root = root or trash_root()
    if not trashed.exists():
        raise FileNotFoundError("Die Datei liegt nicht mehr im Papierkorb.")
    target, number = destination, 1
    while target.exists():
        number += 1
        target = destination.with_name(f"{destination.stem} {number}{destination.suffix}")
    shutil.move(str(trashed), str(target))
    try:
        (root / "info" / f"{trashed.name}.trashinfo").unlink()
    except OSError:
        pass
    return target
