"""The recordings library: ``Bibliothek.json`` and the WAV files next to it, in the Mac app's format.

The document is kept as plain dictionaries so that fields this app does not know (edits, grids, sound stamps, pieces)
survive a save untouched. A port of the parts of SparkCore/LibraryStore.swift that recording needs.
"""
from __future__ import annotations

import json
import os
import shutil
import uuid as uuidlib
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import trash as trashmod, wav

SCHEMA = 2
DOCUMENT, BACKUP, JOURNAL = "Bibliothek.json", "Bibliothek.backup.json", ".aufnahme-laeuft.json"
AUDIO_EXTENSIONS = {".wav", ".aif", ".aiff", ".caf", ".m4a", ".mp3", ".flac"}


class StoreError(Exception):
    pass


def iso(date: datetime) -> str:
    return date.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(text: str | None) -> datetime:
    if not text:
        return datetime.fromtimestamp(0, timezone.utc)
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return datetime.fromtimestamp(0, timezone.utc)


def file_stamp(date: datetime) -> str:
    return date.astimezone().strftime("%Y-%m-%d_%H-%M-%S")


def new_id() -> str:
    return str(uuidlib.uuid4()).upper()


def default_folder() -> Path:
    return Path.home() / "Music" / "Spark Studio" / "Aufnahmen"


def dumps(value) -> str:
    """Swift's JSONEncoder style (pretty printed, sorted keys, " : "), so both apps write alike."""
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : ")) + "\n"


@dataclass
class RecoveryOutcome:
    kind: str  # none, repaired, empty, failed
    file_name: str = ""
    seconds: float = 0.0


class LibraryStore:
    def __init__(self, folder: Path | None = None, trash=None):
        self.folder = folder or default_folder()
        self.document: dict = self._fresh()
        self._trash = trash
        self._lock = None

    @staticmethod
    def _fresh() -> dict:
        return {"schemaVersion": SCHEMA, "recordings": [], "pieces": [], "practiceLog": [], "trashed": []}

    @property
    def document_path(self) -> Path:
        return self.folder / DOCUMENT

    @property
    def journal_path(self) -> Path:
        return self.folder / JOURNAL

    def url(self, recording: dict) -> Path:
        return self.folder / recording["fileName"]

    def acquire_lock(self) -> bool:
        """Only one app at a time uses the recordings library."""
        import fcntl
        self.folder.mkdir(parents=True, exist_ok=True)
        handle = open(self.folder / ".sperre", "w")
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            handle.close()
            return False
        self._lock = handle
        return True

    # Loading and saving

    def load(self) -> str:
        self.folder.mkdir(parents=True, exist_ok=True)
        try:
            self.document = self._read(self.document_path)
            return "loaded"
        except FileNotFoundError:
            try:
                self.document = self._read(self.backup_path)
                return "loaded"
            except (OSError, ValueError):
                self.document = self._fresh()
                return "fresh"
        except (OSError, ValueError):
            kept = f"Bibliothek.defekt-{file_stamp(datetime.now())}.json"
            os.replace(self.document_path, self.folder / kept)
            try:
                self.document = self._read(self.backup_path)
                return "restored"
            except (OSError, ValueError):
                self.document = self._fresh()
                return "started_over"

    @property
    def backup_path(self) -> Path:
        return self.folder / BACKUP

    def _read(self, path: Path) -> dict:
        document = json.loads(path.read_text(encoding="utf-8"))
        if int(document.get("schemaVersion", 1)) > SCHEMA:
            raise StoreError(f"Die Bibliothek stammt aus einer neueren Version (Schema {document['schemaVersion']}).")
        for key in ("recordings", "pieces", "practiceLog", "trashed"):
            document.setdefault(key, [])
        return document

    def save(self) -> None:
        """Saves atomically. The previous version becomes the backup, and a crash at any point leaves a readable file."""
        self.folder.mkdir(parents=True, exist_ok=True)
        self.document["schemaVersion"] = SCHEMA
        if self.document_path.exists():
            temporary = self.folder / f".{new_id()}.backup"
            shutil.copy2(self.document_path, temporary)
            os.replace(temporary, self.backup_path)
        temporary = self.folder / f".{new_id()}.tmp"
        temporary.write_text(dumps(self.document), encoding="utf-8")
        os.replace(temporary, self.document_path)

    # Journal

    def write_journal(self, journal: dict) -> None:
        temporary = self.folder / f".{new_id()}.tmp"
        temporary.write_text(dumps(journal), encoding="utf-8")
        os.replace(temporary, self.journal_path)

    def read_journal(self) -> dict | None:
        try:
            return json.loads(self.journal_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None

    def remove_journal(self) -> None:
        try:
            self.journal_path.unlink()
        except FileNotFoundError:
            pass

    # Recordings

    def recording(self, take_id: str) -> dict | None:
        return next((r for r in self.document["recordings"] if r["id"] == take_id), None)

    def add(self, recording: dict) -> None:
        stat = self.url(recording).stat()
        recording["fileSize"], recording["inode"] = stat.st_size, stat.st_ino
        self.document["recordings"].append(recording)

    def update(self, take_id: str, change) -> None:
        recording = self.recording(take_id)
        if recording is not None:
            change(recording)

    def trash_recording(self, take_id: str) -> dict:
        """Moves the take's file to the trash and keeps its metadata, so restoring brings back ratings and notes."""
        recording = self.recording(take_id)
        if recording is None:
            raise StoreError("Die Aufnahme wurde nicht gefunden.")
        path = self.url(recording)
        mover = self._trash or trashmod.move
        try:
            moved = mover(path) if path.exists() else None
        except OSError as error:
            raise StoreError("Die Datei konnte nicht in den Papierkorb gelegt werden.") from error
        entry = {"recording": recording, "trashPath": str(moved or ""), "trashedAt": iso(datetime.now(timezone.utc))}
        self.document["recordings"] = [r for r in self.document["recordings"] if r["id"] != take_id]
        self.document["trashed"].append(entry)
        return entry

    def restore_trashed(self, entry: dict) -> dict:
        recording = entry["recording"]
        destination = self.url(recording)
        if entry.get("trashPath"):
            try:
                restored = trashmod.restore(Path(entry["trashPath"]), destination)
            except (OSError, FileNotFoundError) as error:
                raise StoreError("Die Datei liegt nicht mehr im Papierkorb.") from error
            recording["fileName"] = restored.name
        self.document["trashed"] = [t for t in self.document["trashed"] if t is not entry and t != entry]
        self.document["recordings"].append(recording)
        return recording

    def log_practice(self, date: datetime, seconds: float, piece_id: str | None) -> None:
        if seconds <= 0:
            return
        entry = {"id": new_id(), "date": iso(date), "seconds": seconds}
        if piece_id:
            entry["pieceID"] = piece_id
        self.document["practiceLog"].append(entry)

    def unique_name(self, stem: str, ext: str = "wav") -> Path:
        candidate = self.folder / f"{stem}.{ext}"
        number = 2
        while candidate.exists():
            candidate = self.folder / f"{stem} {number}.{ext}"
            number += 1
        return candidate

    def new_recording(self, *, take_id: str, file_name: str, started_at: datetime, seconds: float, fmt: wav.Format,
                      source: dict | None, piece_id: str | None, peak_db: float | None, auto_level: bool = True,
                      markers: list | None = None, preset: dict | None = None, recovered: bool = False) -> dict:
        edit = {"autoLevelEnabled": auto_level, "autoLevelDB": auto_level_gain(peak_db) if auto_level else 0}
        recording = {
            "id": take_id, "fileName": file_name, "createdAt": iso(started_at), "duration": seconds,
            "sampleRate": fmt.sample_rate, "channels": fmt.channels, "fileBits": fmt.bits, "fileSize": 0, "inode": 0,
            "status": "open", "rating": 0, "favorite": False, "tags": [], "note": "", "markers": markers or [],
            "edit": edit, "health": "ok", "recoveredAfterInterruption": recovered,
        }
        if source:
            recording["source"] = source
        if piece_id:
            recording["pieceID"] = piece_id
        if peak_db is not None:
            recording["peakDB"] = peak_db
        if preset:
            recording["preset"] = preset
        return recording

    # Recovery after a crash

    def recover_interrupted(self) -> RecoveryOutcome:
        """Repairs the recording a previous run did not finish, and adds it to the library."""
        journal = self.read_journal()
        if journal is None:
            return RecoveryOutcome("none")
        path = self.folder / journal["fileName"]
        if not path.exists():
            self.remove_journal()
            return RecoveryOutcome("none")
        state, info, _ = wav.inspect(path)
        if state == "empty":
            self._trash_file(path)
            self.remove_journal()
            return RecoveryOutcome("empty", journal["fileName"])
        if state == "unreadable":
            self.remove_journal()
            return RecoveryOutcome("failed", journal["fileName"])
        try:
            wav.repair(path, treat_trailing_data_as_audio=True)
        except (wav.WAVError, OSError):
            self.remove_journal()
            return RecoveryOutcome("failed", journal["fileName"])
        state, fmt, frames = wav.inspect(path)
        if state != "ok":
            self.remove_journal()
            return RecoveryOutcome("failed", journal["fileName"])
        seconds = frames / fmt.sample_rate
        if any(r["fileName"] == journal["fileName"] for r in self.document["recordings"]):
            self.remove_journal()
            return RecoveryOutcome("repaired", journal["fileName"], seconds)
        started = parse_iso(journal.get("startedAt"))
        recording = self.new_recording(
            take_id=journal.get("takeID") or new_id(), file_name=journal["fileName"], started_at=started,
            seconds=seconds, fmt=fmt, source=journal.get("source"), piece_id=journal.get("pieceID"), peak_db=None,
            auto_level=False, markers=journal.get("markers"), preset=journal.get("preset"), recovered=True)
        self.add(recording)
        self.log_practice(started, seconds, journal.get("pieceID"))
        self.save()
        self.remove_journal()
        return RecoveryOutcome("repaired", journal["fileName"], seconds)

    def _trash_file(self, path: Path) -> None:
        try:
            (self._trash or trashmod.move)(path)
        except OSError as error:
            raise StoreError("Der Papierkorb ist nicht erreichbar, die Datei bleibt wo sie ist.") from error


def auto_level_gain(peak_db: float | None) -> float:
    """AutoLevel.gainDB: raises the peak to -1 dBFS, at most 30 dB, and not at all below 0.1 dB."""
    if peak_db is None:
        return 0.0
    gain = min(-1.0 - peak_db, 30.0)
    return gain if gain >= 0.1 else 0.0


# MARK: Names, pieces and the questions the library views ask


def sanitized_name(name: str) -> str | None:
    """A safe file name stem, or None when nothing usable remains."""
    cleaned = name.strip().replace("/", "-").replace(":", "-")
    cleaned = "".join(ch for ch in cleaned if ch not in "\n\r\0")
    cleaned = cleaned.lstrip(".").strip()
    return cleaned if cleaned and len(cleaned.encode("utf-8")) <= 200 else None


def rename_recording(store: LibraryStore, take_id: str, new_name: str) -> None:
    """Renames the file itself, so the file manager and the library agree. Existing files are never overwritten."""
    recording = store.recording(take_id)
    if recording is None:
        raise StoreError("Die Aufnahme wurde nicht gefunden.")
    stem = sanitized_name(new_name)
    if stem is None:
        raise StoreError("Dieser Name ist als Dateiname nicht möglich.")
    ext = Path(recording["fileName"]).suffix
    file_name = stem + ext
    if file_name == recording["fileName"]:
        return
    destination = store.folder / file_name
    same_file_new_case = file_name.lower() == recording["fileName"].lower()
    if destination.exists() and not same_file_new_case:
        raise StoreError(f"Es gibt bereits eine Datei mit dem Namen „{file_name}“.")
    os.rename(store.url(recording), destination)
    recording["fileName"] = file_name


def add_piece(store: LibraryStore, name: str) -> dict:
    piece = {"id": new_id(), "name": name.strip(), "createdAt": iso(datetime.now(timezone.utc)), "parts": [],
             "artist": "", "notes": ""}
    store.document["pieces"].append(piece)
    return piece


def piece(store: LibraryStore, piece_id: str | None) -> dict | None:
    return next((p for p in store.document["pieces"] if p["id"] == piece_id), None)


def remove_piece(store: LibraryStore, piece_id: str) -> dict:
    """Removes a piece; its takes stay and lose the assignment. Returns what it takes to bring it back."""
    removed = piece(store, piece_id)
    if removed is None:
        raise StoreError("Das Stück wurde nicht gefunden.")
    takes = [r["id"] for r in store.document["recordings"] if r.get("pieceID") == piece_id]
    for recording in store.document["recordings"]:
        if recording.get("pieceID") == piece_id:
            recording.pop("pieceID")
    store.document["pieces"] = [p for p in store.document["pieces"] if p["id"] != piece_id]
    return {"piece": removed, "takes": takes}


def restore_piece(store: LibraryStore, removed: dict) -> None:
    store.document["pieces"].append(removed["piece"])
    for take_id in removed["takes"]:
        store.update(take_id, lambda r: r.update(pieceID=removed["piece"]["id"]))


def practice_seconds(store: LibraryStore, piece_id: str | None = None, since: datetime | None = None) -> float:
    total = 0.0
    for entry in store.document["practiceLog"]:
        if piece_id is not None and entry.get("pieceID") != piece_id:
            continue
        if since is not None and parse_iso(entry.get("date")) < since:
            continue
        total += float(entry.get("seconds", 0))
    return total


def practice_by_day(store: LibraryStore, days: int = 30, today: datetime | None = None) -> list[tuple[datetime, float]]:
    """Minutes practiced on each of the last ``days`` local days, oldest first, today last."""
    today = (today or datetime.now()).astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
    buckets = {today - timedelta(days=i): 0.0 for i in range(days)}
    for entry in store.document["practiceLog"]:
        day = parse_iso(entry.get("date")).astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
        if day in buckets:
            buckets[day] += float(entry.get("seconds", 0)) / 60
    return sorted(buckets.items())


def query(recordings: list[dict], *, text: str = "", min_rating: int = 0, favorites: bool = False,
          status: str = "all", piece_id: str | None | bool = False, tag: str | None = None,
          piece_names: dict | None = None) -> list[dict]:
    """The library filter. ``piece_id`` False means all pieces, None means takes without a piece."""
    needle = text.strip().casefold()
    result = []
    for take in recordings:
        if min_rating and int(take.get("rating", 0)) < min_rating:
            continue
        if favorites and not take.get("favorite"):
            continue
        if status != "all" and take.get("status", "kept") != status:
            continue
        if piece_id is not False and take.get("pieceID") != piece_id:
            continue
        if tag and tag.casefold() not in [t.casefold() for t in take.get("tags", [])]:
            continue
        if needle:
            haystack = " ".join([take["fileName"], take.get("note", ""), *take.get("tags", []),
                                 (piece_names or {}).get(take.get("pieceID"), "")]).casefold()
            if needle not in haystack:
                continue
        result.append(take)
    return result


def all_tags(recordings: list[dict]) -> list[str]:
    seen: dict[str, str] = {}
    for take in recordings:
        for tag in take.get("tags", []):
            seen.setdefault(tag.casefold(), tag)
    return sorted(seen.values(), key=str.casefold)


def parse_tags(text: str) -> list[str]:
    seen, tags = set(), []
    for tag in (t.strip() for t in text.split(",")):
        if tag and tag.casefold() not in seen:
            seen.add(tag.casefold())
            tags.append(tag)
    return tags


# MARK: The sound a take was recorded with

def snapshot_path(store: LibraryStore, take_id: str) -> Path:
    return store.folder / ".presets" / f"{take_id}.json"


def write_snapshot(store: LibraryStore, take_id: str, preset, origin: str) -> None:
    folder = store.folder / ".presets"
    folder.mkdir(parents=True, exist_ok=True)
    data = {"format": 2, "id": new_id(), "savedAt": iso(datetime.now(timezone.utc)), "origin": origin,
            "isBackup": False, "favorite": False, "rating": 0, "tags": [], "notes": "", "preset": preset.to_json()}
    path = snapshot_path(store, take_id)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(dumps(data), encoding="utf-8")
    os.replace(temporary, path)


def read_snapshot(store: LibraryStore, take_id: str):
    from .protocol import Preset
    try:
        return Preset.from_json(json.loads(snapshot_path(store, take_id).read_text(encoding="utf-8"))["preset"])
    except (OSError, ValueError, KeyError):
        return None
