"""A folder of presets, one readable JSON file each, in the format the Mac app writes (PresetFile, format 2).

Files placed in the folder show up on the next reload. Sound recipes in the folder are read as presets too.
Removing moves a file to the trash, never deletes it.
"""
from __future__ import annotations

import json
import os
import uuid as uuidlib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import recipe
from .protocol import NAME_LIMIT, Preset

CURRENT_FORMAT = 2


class LibraryError(Exception):
    pass


@dataclass
class SavedPreset:
    path: Path
    preset: Preset
    id: str | None = None
    saved_at: datetime = field(default_factory=lambda: datetime.fromtimestamp(0, timezone.utc))
    origin: str = ""
    is_backup: bool = False
    favorite: bool = False
    rating: int = 0
    tags: list[str] = field(default_factory=list)
    notes: str = ""
    is_recipe: bool = False

    @property
    def name(self) -> str:
        return self.preset.name


def default_folder() -> Path:
    return Path.home() / "Music" / "Spark Studio" / "Presets"


def file_name_for(name: str) -> str:
    cleaned = "".join("-" if c in "/:\\" or c in "\n\r" else c for c in name).strip()
    if cleaned.startswith("."):
        cleaned = "-" + cleaned[1:]
    return cleaned or "Preset"


def _iso(date: datetime) -> str:
    return date.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_date(text: str | None) -> datetime:
    if not text:
        return datetime.fromtimestamp(0, timezone.utc)
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return datetime.fromtimestamp(0, timezone.utc)


def tag_text(tag: str) -> str:
    """One tag as it is kept: trimmed, without leading "#" (the window shows it, the file does not keep it)."""
    return tag.strip().lstrip("#").strip()


def parse_tags(text: str) -> list[str]:
    """Tags typed in one line, with or without "#", separated by blanks or commas."""
    return normalized_tags(text.replace(",", " ").split())


def normalized_tags(tags: list[str]) -> list[str]:
    seen, result = set(), []
    for tag in (tag_text(t) for t in tags):
        if tag and tag.casefold() not in seen:
            seen.add(tag.casefold())
            result.append(tag)
    return result


class PresetLibrary:
    def __init__(self, folder: Path | None = None, trash=None):
        self.folder = folder or default_folder()
        self.items: list[SavedPreset] = []
        self.unreadable: list[str] = []
        self._trash = trash or _trash

    def reload(self) -> None:
        self.folder.mkdir(parents=True, exist_ok=True)
        items, unreadable = [], []
        for path in sorted(self.folder.glob("*.json")):
            if path.name.startswith("."):
                continue
            try:
                raw = path.read_bytes()
                data = json.loads(raw)
            except (OSError, ValueError):
                unreadable.append(path.name)
                continue
            try:
                if recipe.is_recipe(data):
                    conversion = recipe.to_preset(data, raw)
                    modified = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
                    items.append(SavedPreset(path, conversion.preset, None, modified, "Rezept",
                                             tags=normalized_tags(conversion.tags), notes=conversion.notes,
                                             is_recipe=True))
                else:
                    items.append(SavedPreset(
                        path, Preset.from_json(data["preset"]), data.get("id"), _parse_date(data.get("savedAt")),
                        data.get("origin", ""), bool(data.get("isBackup", False)), bool(data.get("favorite", False)),
                        min(max(int(data.get("rating", 0)), 0), 5), normalized_tags(data.get("tags", [])),
                        data.get("notes", "")))
            except (KeyError, ValueError, TypeError, recipe.RecipeError):
                unreadable.append(path.name)
        items.sort(key=lambda s: (s.name.casefold(), s.saved_at))
        self.items = items
        self.unreadable = sorted(unreadable)

    def existing(self, preset: Preset) -> SavedPreset | None:
        return next((item for item in self.items if item.preset.same_content(preset)), None)

    def save(self, preset: Preset, origin: str, is_backup: bool = False, date: datetime | None = None,
             tags: list[str] | None = None, notes: str = "") -> SavedPreset:
        date = date or datetime.now(timezone.utc)
        base = file_name_for(preset.name)
        if is_backup:
            base += f" – Sicherung {date.astimezone().strftime('%Y-%m-%d %H.%M')}"
        item = SavedPreset(self._unique(base), preset.copy(), str(uuidlib.uuid4()).upper(), date, origin,
                           is_backup=is_backup, tags=normalized_tags(tags or []), notes=notes)
        self._write(item)
        self.reload()
        return next(i for i in self.items if i.path == item.path)

    def replace(self, item: SavedPreset, preset: Preset, date: datetime | None = None) -> SavedPreset:
        """Writes new settings into a saved preset. A changed name renames the file too."""
        name = preset.name.strip()
        if not name:
            raise LibraryError("Der Name darf nicht leer sein.")
        if len(name.encode("utf-8")) > NAME_LIMIT:
            raise LibraryError(f"Der Name ist zu lang. Der Verstärker nimmt höchstens {NAME_LIMIT} Zeichen.")
        updated = SavedPreset(item.path, preset.copy(), item.id or str(uuidlib.uuid4()).upper(),
                              date or datetime.now(timezone.utc), item.origin if not item.is_recipe else "",
                              item.is_backup, item.favorite, item.rating, item.tags, item.notes)
        wanted = file_name_for(name)
        if wanted != item.path.stem:
            updated.path = self._unique(wanted)
        self._write(updated)
        if updated.path != item.path:
            item.path.unlink()
        self.reload()
        return next(i for i in self.items if i.path == updated.path)

    def rename(self, item: SavedPreset, name: str) -> SavedPreset:
        preset = item.preset.copy()
        preset.name = name.strip()
        return self.replace(item, preset, item.saved_at)

    def update_meta(self, item: SavedPreset, *, favorite=None, rating=None, tags=None, notes=None) -> SavedPreset:
        if favorite is not None:
            item.favorite = favorite
        if rating is not None:
            item.rating = min(max(rating, 0), 5)
        if tags is not None:
            item.tags = normalized_tags(tags)
        if notes is not None:
            item.notes = notes
        item.is_recipe = False
        if item.id is None:
            # A recipe becomes a preset file here; songs refer to it by this id.
            item.id = str(uuidlib.uuid4()).upper()
        self._write(item)
        self.reload()
        return next(i for i in self.items if i.path == item.path)

    def add_recipe(self, data: dict) -> Path:
        """Writes a sound recipe into the folder under a free file name; it shows as a recipe until saved."""
        path = self._unique(file_name_for(str(data.get("name", "")) or "Rezept"))
        temporary = path.with_name(f".{path.name}.tmp")
        temporary.write_text(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(temporary, path)
        self.reload()
        return path

    def tag_counts(self) -> list[tuple[str, int]]:
        """Every tag with how many presets carry it, most used first, then by name."""
        counts: dict[str, list] = {}
        for item in self.items:
            if item.is_backup:
                continue
            for tag in item.tags:
                entry = counts.setdefault(tag.casefold(), [tag, 0])
                entry[1] += 1
        return sorted(((tag, count) for tag, count in counts.values()), key=lambda e: (-e[1], e[0].casefold()))

    def import_kemper(self, sounds) -> tuple[list[SavedPreset], int]:
        """Writes the sounds of a Kemper import (kemper.Sound). A sound already here under the same name and with
        the same chain only gets the new tags, so importing twice adds nothing. Returns the saved preset per sound
        and how many are new."""
        from .protocol import fingerprint
        existing = {(i.name, fingerprint(i.preset)): i for i in self.items if not i.is_backup}
        written, new = [], 0
        for sound in sounds:
            key = (sound.preset.name, fingerprint(sound.preset))
            if key in existing:
                saved = self.update_meta(existing[key], tags=existing[key].tags + sound.tags)
            else:
                saved = self.save(sound.preset, sound.origin, tags=sound.tags, notes=sound.notes)
                new += 1
            existing[key] = saved
            written.append(saved)
        return written, new

    def trash(self, item: SavedPreset) -> None:
        self._trash(item.path)
        self.reload()

    def _write(self, item: SavedPreset) -> None:
        data = {"format": CURRENT_FORMAT, "id": item.id, "savedAt": _iso(item.saved_at), "origin": item.origin,
                "isBackup": item.is_backup, "favorite": item.favorite, "rating": item.rating, "tags": item.tags,
                "notes": item.notes, "preset": item.preset.to_json()}
        temporary = item.path.with_name(f".{item.path.name}.tmp")
        temporary.write_text(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(temporary, item.path)

    def _unique(self, base: str) -> Path:
        path = self.folder / f"{base}.json"
        number = 2
        while path.exists():
            path = self.folder / f"{base} {number}.json"
            number += 1
        return path


def _trash(path: Path) -> None:
    """Moves a file to the freedesktop trash; refuses to delete when that is not possible."""
    from . import trash
    try:
        trash.move(path)
    except OSError as error:
        raise LibraryError("Der Papierkorb ist nicht erreichbar, die Datei bleibt wo sie ist.") from error
