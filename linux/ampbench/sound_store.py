"""The sound store: keeps a folder of sounds and an encrypted store in step, in both directions.

Every file is encrypted on this device with the age format before it leaves, and so is the index. The store holds
`manifest.age` and `objects/<hex>.age`; without the key it shows neither names nor contents, only how many objects
there are and how large. Objects are never deleted, so an overwritten or removed sound stays restorable.

A port of Sources/SoundStore/SyncPlan.swift and SoundStore.swift, with the same index, the same object names and
the same decisions, so a Mac, an iPad and this computer share one store. docs/STORE.md describes the format."""
from __future__ import annotations

import hashlib
import hmac
import json
import math
import os
import unicodedata
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import age
from .i18n import tr
from .store_places import MANIFEST, StoreError, is_valid_name, object_name, write_atomically

CURRENT_VERSION = 1
HISTORY_LIMIT = 10
# Larger files are left alone: the store is for sounds, which are small, not for recordings.
SIZE_LIMIT = 8 * 1024 * 1024


# MARK: The index

@dataclass
class Entry:
    # The object with the current content, or the last one before the sound was removed.
    object: str
    # Seconds since 1970. The index keeps whole seconds; a file's own date may be finer.
    modified: float
    size: int
    # Set when the sound was removed. Its object stays in the store, so it can be brought back.
    deleted: float | None = None
    # Objects of earlier contents, newest first.
    history: list[str] = field(default_factory=list)

    def copy(self) -> "Entry":
        return Entry(self.object, self.modified, self.size, self.deleted, list(self.history))

    def replace(self, object: str, modified: float, size: int) -> None:
        """The content this entry had becomes history; `object` takes its place."""
        old = self.object
        self.object = object
        if old != object:
            self.remember(old)
        else:
            self.history = [name for name in self.history if name != object]
        self.modified, self.size, self.deleted = modified, size, None

    def remember(self, old: str) -> None:
        self.history = [old] + [name for name in self.history if name != old]
        self.history = [name for name in self.history if name != self.object][:HISTORY_LIMIT]


@dataclass
class Manifest:
    """The store's index: which sound is which object. It is the only index; nothing ever lists a directory, so a
    store needs no more than reading and writing a file by name."""
    version: int = CURRENT_VERSION
    # Made once when the store is first written. A device's memory of its last sync belongs to one store; with
    # another store, or the same one set up anew, that memory must not count.
    id: str = field(default_factory=lambda: str(uuid.uuid4()).upper())
    entries: dict[str, Entry] = field(default_factory=dict)

    def copy(self) -> "Manifest":
        return Manifest(self.version, self.id, {path: entry.copy() for path, entry in self.entries.items()})

    def encode(self) -> bytes:
        """The JSON the Mac writes: sorted keys, no blanks, dates in whole seconds, `/` written as `\\/`."""
        entries = {}
        for path, entry in self.entries.items():
            item = {"history": entry.history, "modified": _iso(entry.modified), "object": entry.object,
                    "size": entry.size}
            if entry.deleted is not None:
                item["deleted"] = _iso(entry.deleted)
            entries[path] = item
        text = json.dumps({"entries": entries, "id": self.id, "version": self.version}, sort_keys=True,
                          separators=(",", ":"), ensure_ascii=False)
        return text.replace("/", "\\/").encode("utf-8")

    @classmethod
    def decode(cls, data: bytes) -> "Manifest":
        """Raises ValueError for anything that is not an index."""
        try:
            raw = json.loads(data.decode("utf-8"))
            version = _integer(raw["version"])
            identifier = raw.get("id", "")
            if identifier is None:
                identifier = ""
            if not isinstance(identifier, str):
                raise ValueError("id")
            entries = {}
            # A newer format may hold entries this version cannot read. The version is checked before they are used.
            if version <= CURRENT_VERSION:
                if not isinstance(raw["entries"], dict):
                    raise ValueError("entries")
                for path, item in raw["entries"].items():
                    history = item.get("history")
                    history = [] if history is None else history
                    if not isinstance(item["object"], str) or not isinstance(history, list) \
                            or not all(isinstance(name, str) for name in history):
                        raise ValueError("entry")
                    deleted = item.get("deleted")
                    entries[path] = Entry(item["object"], _parse_iso(item["modified"]), _integer(item["size"]),
                                          None if deleted is None else _parse_iso(deleted), list(history))
            return cls(version, identifier, entries)
        except (KeyError, TypeError, AttributeError, UnicodeDecodeError, RecursionError) as error:
            raise ValueError(str(error)) from None


def _integer(value) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != int(value):
        raise ValueError("not a whole number")
    return int(value)


def _iso(seconds: float) -> str:
    """`2026-11-14T12:00:00Z`. Fractions are cut off, not rounded, as the Mac does."""
    return datetime.fromtimestamp(math.floor(seconds), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(text) -> float:
    if not isinstance(text, str) or "T" not in text.upper():
        raise ValueError("not a date")
    date = datetime.fromisoformat(text.upper())
    if date.tzinfo is None:
        raise ValueError("a date without a time zone")
    return date.timestamp()


def is_safe_path(path: str) -> bool:
    """A relative path that stays inside the sounds folder and names nothing hidden. A store someone tampered with
    must not be able to write anywhere else."""
    if not path or "\0" in path or "\\" in path:
        return False
    return all(part and not part.startswith(".") for part in path.split("/"))


# MARK: The plan

@dataclass
class LocalSound:
    """A file of the sounds folder as the sync sees it."""
    object: str
    modified: float
    size: int


@dataclass
class SyncPlan:
    """What one sync has to do, decided from three sides: the folder now, the store's index, and what was in sync
    after the last run (`base`). Pure, so every rule has a test.

    - Changed or new on one side only: that side wins.
    - Changed on both sides to different contents: the newer one wins, the other becomes history in the store. A
      local loser is uploaded first, so it is never lost.
    - Removed on one side and unchanged on the other: removed on both. Removed on one side but changed on the other:
      the change wins.
    - Without a base (first run): the union of both, conflicts by date."""
    manifest: Manifest
    # Paths whose local content becomes the store's current one.
    uploads: list[str] = field(default_factory=list)
    # Paths whose local content lost a conflict: uploaded as history before the download replaces it.
    preserved: list[str] = field(default_factory=list)
    # Paths to fetch from the store, with the manifest's entry.
    downloads: list[str] = field(default_factory=list)
    # Paths removed in the store and unchanged here: to remove here.
    removals: list[str] = field(default_factory=list)
    # Paths removed here: marked as deleted in the store.
    marked_deleted: list[str] = field(default_factory=list)
    unchanged: int = 0
    # What is in sync once the plan was carried out: path to object.
    base: dict[str, str] = field(default_factory=dict)

    @classmethod
    def make(cls, local: dict[str, LocalSound], remote: Manifest, base: dict[str, str],
             now: float | None = None) -> "SyncPlan":
        now = datetime.now(timezone.utc).timestamp() if now is None else now
        plan = cls(remote.copy())
        for path in sorted(set(local) | set(remote.entries)):
            mine = local.get(path)
            entry = remote.entries.get(path)
            theirs = entry.object if entry is not None and entry.deleted is None else None
            before = base.get(path)

            if mine is None and theirs is None:
                continue
            if theirs is None:
                if entry is not None and before == mine.object:
                    # Removed in the store, and this device still has exactly what it last synced.
                    plan.removals.append(path)
                else:
                    # New here, or changed here after it was removed elsewhere: the change wins.
                    updated = entry.copy() if entry is not None else Entry(mine.object, mine.modified, mine.size)
                    updated.replace(mine.object, mine.modified, mine.size)
                    plan.manifest.entries[path] = updated
                    plan.uploads.append(path)
                    plan.base[path] = mine.object
            elif mine is None:
                if before == theirs:
                    # Removed here, and the store still has what this device last synced.
                    plan.manifest.entries[path].deleted = now
                    plan.marked_deleted.append(path)
                else:
                    plan.downloads.append(path)
                    plan.base[path] = theirs
            else:
                updated = entry.copy()
                if mine.object == theirs:
                    plan.unchanged += 1
                    plan.base[path] = theirs
                elif before == mine.object:
                    plan.downloads.append(path)
                    plan.base[path] = theirs
                elif before == theirs or mine.modified > updated.modified:
                    updated.replace(mine.object, mine.modified, mine.size)
                    plan.manifest.entries[path] = updated
                    plan.uploads.append(path)
                    plan.base[path] = mine.object
                else:
                    updated.remember(mine.object)
                    plan.manifest.entries[path] = updated
                    plan.preserved.append(path)
                    plan.downloads.append(path)
                    plan.base[path] = theirs
        return plan

    @property
    def changes_store(self) -> bool:
        return bool(self.uploads or self.preserved or self.marked_deleted)


# MARK: Reports

@dataclass
class SyncReport:
    """What a sync did, by the sounds' paths below the folder."""
    uploaded: list[str] = field(default_factory=list)
    downloaded: list[str] = field(default_factory=list)
    removed_locally: list[str] = field(default_factory=list)
    marked_deleted: list[str] = field(default_factory=list)
    unchanged: int = 0

    @property
    def is_empty(self) -> bool:
        return not (self.uploaded or self.downloaded or self.removed_locally or self.marked_deleted)

    @property
    def summary(self) -> str:
        """One line for the message strip."""
        if self.is_empty:
            return tr("The store is up to date: {} sounds.", self.unchanged)
        parts = []
        if self.uploaded:
            parts.append(tr("{} stored", len(self.uploaded)))
        if self.downloaded:
            parts.append(tr("{} fetched", len(self.downloaded)))
        if self.marked_deleted:
            parts.append(tr("{} removed in the store", len(self.marked_deleted)))
        if self.removed_locally:
            parts.append(tr("{} removed here", len(self.removed_locally)))
        return tr("Store: {}.", ", ".join(parts))


@dataclass
class VerifyReport:
    """What reading the whole store back found."""
    # Sounds that were fetched, opened with the key and found whole.
    readable: int = 0
    # Named by the index, but their data is not in the store.
    missing: list[str] = field(default_factory=list)
    # In the store, but not readable with the key or not what the index says.
    damaged: list[str] = field(default_factory=list)
    # Whole in the store, with another content than the file here: changed since the last sync.
    differing: list[str] = field(default_factory=list)
    # Whole in the store, not on this device.
    not_here: list[str] = field(default_factory=list)
    # On this device, not in the store yet.
    not_stored: list[str] = field(default_factory=list)

    @property
    def is_restorable(self) -> bool:
        """True when every sound of the store can be restored."""
        return not (self.missing or self.damaged)

    @property
    def is_in_step(self) -> bool:
        """True when the store and this device also hold the same sounds."""
        return self.is_restorable and not (self.differing or self.not_here or self.not_stored)

    @property
    def summary(self) -> str:
        if not self.is_restorable:
            return tr("The store is damaged: {} of its sounds cannot be restored.",
                      len(self.missing) + len(self.damaged))
        if self.is_in_step:
            return tr("Checked: all {} sounds in the store can be read and equal the ones here.", self.readable)
        return tr("Checked: all {} sounds in the store can be read. {} differ from this device; a sync brings them "
                  "in step.", self.readable, len(self.differing) + len(self.not_here) + len(self.not_stored))


# MARK: The store

def _delete(path: Path) -> None:
    path.unlink()


class SoundStore:
    """`place` is where the encrypted files live (store_places.py), `state_file` where this device remembers what
    was in step after its last sync, `remove` what takes a sound away that was removed on another device; the app
    passes its trash, so nothing is deleted for good."""

    def __init__(self, folder: Path, place, identity: age.AgeIdentity, state_file: Path, remove=_delete):
        self.folder = Path(folder)
        self._place = place
        self._identity = identity
        self._state_file = Path(state_file)
        self._remove = remove
        self._name_key = hashlib.sha256(b"AmpBench store object" + identity.secret).digest()

    def object_name(self, content: bytes) -> str:
        """The object name for a content: the same content always has the same name, so it uploads once, and without
        the key the name says nothing about it."""
        return object_name(hmac.new(self._name_key, content, hashlib.sha256).hexdigest())

    # MARK: Sync

    def sync(self) -> SyncReport:
        files, large = self._scan()
        stored = self._read_manifest()
        remote = stored.copy() if stored is not None else Manifest()
        spelling, set_aside = _spellings(remote)

        # From here on a sound goes by the index's spelling of its path, whatever the file is called on this disk.
        local: dict[str, LocalSound] = {}
        contents: dict[str, bytes] = {}
        here: dict[str, Path] = {}
        for name, file, modified in files:
            path = spelling.get(_nfc(name), name)
            if path in here:
                continue  # two files whose names differ only in how an accent is written: the first one counts
            data = file.read_bytes()
            local[path] = LocalSound(self.object_name(data), modified, len(data))
            contents[path] = data
            here[path] = file
            spelling.setdefault(_nfc(name), path)
        # A file too large to sync is neither new nor removed: its path is left out of the decision altogether.
        too_large = {spelling.get(_nfc(name), name) for name in large} - set(here)
        for path in too_large:
            if path in remote.entries:
                set_aside[path] = remote.entries.pop(path)

        state = self._load_state()
        base = state[1] if stored is not None and state is not None and state[0] == remote.id else {}
        base = {spelling.get(_nfc(path), path): name for path, name in base.items()}
        plan = SyncPlan.make(local, remote, base)

        # Everything that will be written here is fetched, opened and checked first. A store that is damaged,
        # tampered with or incomplete then ends the sync before a single local file changed.
        fetched: dict[str, bytes] = {}
        wanted = {plan.manifest.entries[path].object for path in plan.downloads}
        objects = self._place.read(sorted(wanted))
        for path in plan.downloads:
            entry = plan.manifest.entries[path]
            if entry.object not in objects:
                raise StoreError(StoreError.MISSING_OBJECT, path)
            fetched[path] = self._open(objects[entry.object], entry.object, path)

        # Objects first, the index last: an index never points at something that is not there yet.
        sealed = {local[path].object: age.encrypt(contents[path], self._identity.recipient)
                  for path in plan.uploads + plan.preserved}
        if sealed:
            self._place.write(sealed)
        if plan.changes_store or stored is None:
            for path, entry in set_aside.items():
                plan.manifest.entries[path] = entry
            self._write_manifest(plan.manifest)

        for path in plan.downloads:
            # A new file gets the composed form of its name, which is what Linux tools and this app's library type.
            target = here.get(path) or self.folder / _nfc(path)
            target.parent.mkdir(parents=True, exist_ok=True)
            write_atomically(target, fetched[path])
            # The store's date, so that the file does not look newer than it is at the next conflict.
            try:
                whole, fraction = divmod(plan.manifest.entries[path].modified, 1)
                stamp = int(whole) * 1_000_000_000 + round(fraction * 1_000_000_000)
                os.utime(target, ns=(stamp, stamp))
            except (OSError, OverflowError, ValueError):
                pass
        for path in plan.removals:
            self._remove(here[path])
        for path in too_large:
            if path in base:
                plan.base[path] = base[path]
            else:
                plan.base.pop(path, None)
        self._save_state(plan.manifest.id, plan.base)

        return SyncReport(plan.uploads, plan.downloads, plan.removals, plan.marked_deleted, plan.unchanged)

    def status(self) -> tuple[int, int]:
        """How many sounds the store holds, and how many removed ones it still keeps. Also the check that the key
        fits."""
        manifest = self._read_manifest() or Manifest()
        deleted = sum(1 for entry in manifest.entries.values() if entry.deleted is not None)
        return len(manifest.entries) - deleted, deleted

    # MARK: Verify

    def verify(self) -> VerifyReport:
        """Reads every sound back from the store, opens it and compares it with the file here. Changes nothing, here
        or in the store. This is the proof that a backup can be restored, not only that it was written."""
        manifest = self._read_manifest() or Manifest()
        live = {path: entry for path, entry in manifest.entries.items() if entry.deleted is None}
        objects = self._place.read(sorted({entry.object for entry in live.values()}))
        report = VerifyReport()
        files = {_nfc(name): file for name, file, _ in reversed(self._scan()[0])}
        for path in sorted(live):
            entry = live[path]
            if entry.object not in objects:
                report.missing.append(path)
                continue
            try:
                plain = self._open(objects[entry.object], entry.object, path)
            except StoreError:
                report.damaged.append(path)
                continue
            report.readable += 1
            try:
                here = files.get(_nfc(path), self.folder / path).read_bytes()
            except OSError:
                report.not_here.append(path)
                continue
            if here != plain:
                report.differing.append(path)
        stored = {_nfc(path) for path in live}
        report.not_stored = sorted(name for name, _, _ in self._scan()[0] if _nfc(name) not in stored)
        return report

    def _open(self, sealed: bytes, name: str, path: str) -> bytes:
        """The content of an object, checked against its name: an object swapped for another one is noticed."""
        try:
            plain = age.decrypt(sealed, self._identity)
        except age.AgeError:
            raise StoreError(StoreError.DAMAGED_OBJECT, path) from None
        if self.object_name(plain) != name:
            raise StoreError(StoreError.DAMAGED_OBJECT, path)
        return plain

    # MARK: Manifest

    def _read_manifest(self) -> Manifest | None:
        sealed = self._place.read([MANIFEST]).get(MANIFEST)
        if sealed is None:
            return None
        try:
            plain = age.decrypt(sealed, self._identity)
        except age.AgeError as error:
            raise StoreError(StoreError.WRONG_KEY if error.kind == age.WRONG_KEY
                             else StoreError.DAMAGED_MANIFEST) from None
        try:
            manifest = Manifest.decode(plain)
        except ValueError:
            raise StoreError(StoreError.DAMAGED_MANIFEST) from None
        if manifest.version > CURRENT_VERSION:
            raise StoreError(StoreError.NEWER_MANIFEST, manifest.version)
        for path, entry in manifest.entries.items():
            if not is_safe_path(path):
                raise StoreError(StoreError.UNSAFE_PATH)
            if not all(is_valid_name(name) for name in [entry.object, *entry.history]) or entry.object == MANIFEST:
                raise StoreError(StoreError.DAMAGED_MANIFEST)
        return manifest

    def _write_manifest(self, manifest: Manifest) -> None:
        self._place.write({MANIFEST: age.encrypt(manifest.encode(), self._identity.recipient)})

    # MARK: Local side

    def _scan(self) -> tuple[list[tuple[str, Path, float]], set[str]]:
        """Every plain, visible file below the folder as (path, file, date), and the paths of those too large. Links
        are not followed, so nothing outside the folder is read."""
        files: list[tuple[str, Path, float]] = []
        too_large: set[str] = set()

        def walk(directory: Path, prefix: str) -> None:
            with os.scandir(directory) as children:
                for child in children:
                    path = prefix + child.name
                    if child.is_symlink() or not is_safe_path(path) or not _is_text(path):
                        continue
                    if child.is_dir(follow_symlinks=False):
                        walk(Path(child.path), path + "/")
                    elif child.is_file(follow_symlinks=False):
                        stat = child.stat(follow_symlinks=False)
                        if stat.st_size > SIZE_LIMIT:
                            too_large.add(path)
                        else:
                            files.append((path, Path(child.path), stat.st_mtime_ns / 1_000_000_000))

        if self.folder.is_dir():
            walk(self.folder, "")
        return files, too_large

    def _load_state(self) -> tuple[str, dict[str, str]] | None:
        """What the device remembers of its last sync with one store: the store's id, and path to object."""
        try:
            raw = json.loads(self._state_file.read_bytes())
            store, objects = raw["store"], raw["objects"]
        except (OSError, ValueError, KeyError, TypeError):
            return None
        if not isinstance(store, str) or not isinstance(objects, dict) \
                or not all(isinstance(name, str) for name in objects.values()):
            return None
        return store, objects

    def _save_state(self, store: str, objects: dict[str, str]) -> None:
        """Losing this file costs nothing but a first-run sync, so a failure to write it does not fail the sync."""
        try:
            self._state_file.parent.mkdir(parents=True, exist_ok=True)
            data = json.dumps({"store": store, "objects": objects}, sort_keys=True, ensure_ascii=False)
            write_atomically(self._state_file, data.encode("utf-8"))
        except OSError:
            pass


def _nfc(path: str) -> str:
    return unicodedata.normalize("NFC", path)


def _spellings(manifest: Manifest) -> tuple[dict[str, str], dict[str, Entry]]:
    """The Mac compares paths the way Swift compares text: "ö" as one character and as "o" with two dots are the
    same path, and its files carry the second form. Python compares bytes. So every path is looked up by its composed
    form: this gives the index's own spelling for it. Should an index hold one path in two spellings, the living one
    counts, and the other is taken out of `manifest` and returned, to be kept as it is."""
    spelling: dict[str, str] = {}
    shadowed: dict[str, Entry] = {}
    for path in sorted(manifest.entries, key=lambda path: (manifest.entries[path].deleted is not None, path)):
        if spelling.setdefault(_nfc(path), path) != path:
            shadowed[path] = manifest.entries[path]
    for path in shadowed:
        del manifest.entries[path]
    return spelling, shadowed


def _is_text(path: str) -> bool:
    """False for a file name that is not UTF-8: the index, which is JSON, could not carry it."""
    try:
        path.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True
