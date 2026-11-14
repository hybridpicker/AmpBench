"""Everything one device remembers about its sound store: where it is (a small settings file), the key and a
password (the desktop's keyring, else files only this user can read) and what was in step after the last sync (a
state file). Nothing of it is ever in the repository or in the presets folder.

A port of Sources/SoundStore/StoreSettings.swift and StoreProfile.swift. The Mac keeps the settings in its
preferences and the secrets in its keychain; here they are:

    ~/.config/ampbench/sound-store.json     the place and the time of the last sync, no secret
    keyring, else ~/.config/ampbench/store-key and store-password (mode 0600)
    ~/.local/state/ampbench/store-state.json   (or below $XDG_STATE_HOME)

A test gets a profile of its own (`StoreProfile.testing`), so tests and `--demo` never see or touch the real store."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .age import AgeError, AgeIdentity
from .i18n import tr
from .sound_store import SoundStore, SyncReport, VerifyReport
from .store_places import FolderPlace, HTTPPlace, SSHPlace, StoreError

FOLDER, SSH, HTTP = "folder", "ssh", "http"
KINDS = (FOLDER, SSH, HTTP)


# MARK: Where

@dataclass
class StoreSettings:
    """Where the store is, without any secret: this may sit in a settings file. The key and a password are kept by
    `StoreSecrets`, never here."""
    kind: str
    # A folder, as a path.
    folder_path: str | None = None
    # The server's name as `ssh` knows it, for example an entry of `~/.ssh/config`.
    host: str | None = None
    # The folder on the server, relative to the home folder or absolute.
    path: str | None = None
    # The HTTPS address the files live below.
    url: str | None = None
    user: str | None = None

    # The names the Mac's settings use, so the two read alike.
    _KEYS = {"folder_path": "folderPath", "host": "host", "path": "path", "url": "url", "user": "user"}

    def to_json(self) -> dict:
        data = {"kind": self.kind}
        for attribute, key in self._KEYS.items():
            if getattr(self, attribute) is not None:
                data[key] = getattr(self, attribute)
        return data

    @classmethod
    def from_json(cls, data) -> "StoreSettings | None":
        if not isinstance(data, dict) or data.get("kind") not in KINDS:
            return None
        values = {attribute: data.get(key) for attribute, key in cls._KEYS.items()}
        if not all(value is None or isinstance(value, str) for value in values.values()):
            return None
        return cls(data["kind"], **values)

    @property
    def summary(self) -> str:
        """The place in a few words, for the settings and messages. No user name, no password."""
        if self.kind == FOLDER:
            name = Path(self.folder_path).name if self.folder_path else ""
            return tr("Folder “{}”", name) if name else tr("Folder")
        if self.kind == SSH:
            return tr("Server {} (SSH)", self.host or "")
        parts = HTTPPlace.parts((self.url or "").strip())
        return tr("Server {} (HTTPS)", parts.hostname) if parts else tr("Server (HTTPS)")

    def place(self, password: str | None = None):
        """The place these settings describe. Raises StoreError for a server name, path or address that cannot be
        used."""
        if self.kind == FOLDER:
            if not self.folder_path:
                raise StoreError(StoreError.INCOMPLETE_SETTINGS)
            return FolderPlace(Path(os.path.expanduser(self.folder_path)))
        if self.kind == SSH:
            if not self.host or not self.path:
                raise StoreError(StoreError.INCOMPLETE_SETTINGS)
            return SSHPlace(self.host, self.path)
        if not self.url:
            raise StoreError(StoreError.INCOMPLETE_SETTINGS)
        url = self.url.strip()
        if HTTPPlace.parts(url) is None:
            raise StoreError(StoreError.INVALID_URL)
        if not HTTPPlace.is_allowed(url):
            raise StoreError(StoreError.INSECURE_URL)
        return HTTPPlace(url, self.user, password)


# MARK: Secrets

class StoreSecrets:
    """The store's two secrets, kept like the AI Sound key (ai_key.py): in the desktop's secret service through
    `secret-tool`, else in a file only this user can read. With `service=None` only the files are used, which is
    what a test profile wants."""
    KEY = "store-key"
    PASSWORD = "store-password"
    _LABELS = {KEY: "AmpBench: sound store key", PASSWORD: "AmpBench: sound store password"}

    def __init__(self, folder: Path, service: str | None = "ampbench", hidden: bool = False):
        self.folder = Path(folder)
        self.service = service
        self._prefix = "." if hidden else ""

    def file(self, account: str) -> Path:
        return self.folder / f"{self._prefix}{account}"

    def _tool(self) -> str | None:
        return shutil.which("secret-tool") if self.service else None

    def _attributes(self, account: str) -> list[str]:
        return ["service", self.service, "account", account]

    def read(self, account: str) -> str:
        tool = self._tool()
        if tool:
            try:
                result = subprocess.run([tool, "lookup", *self._attributes(account)], capture_output=True, text=True,
                                        timeout=5)
                if result.returncode == 0 and result.stdout.strip():
                    return result.stdout.strip()
            except (OSError, subprocess.TimeoutExpired):
                pass
        try:
            return self.file(account).read_text(encoding="utf-8").strip()
        except (OSError, UnicodeDecodeError):
            return ""

    def write(self, account: str, text: str | None) -> str:
        """Stores the secret and says where: "keyring" or "file". None or an empty text removes it everywhere."""
        tool = self._tool()
        file = self.file(account)
        if not text:
            if tool:
                try:
                    subprocess.run([tool, "clear", *self._attributes(account)], capture_output=True, timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            try:
                file.unlink()
            except OSError:
                pass
            return ""
        if tool:
            try:
                # On standard input, never an argument: other processes can read a command line.
                result = subprocess.run([tool, "store", f"--label={self._LABELS[account]}", *self._attributes(account)],
                                        input=text, capture_output=True, text=True, timeout=10)
                if result.returncode == 0:
                    try:
                        file.unlink()
                    except OSError:
                        pass
                    return "keyring"
            except (OSError, subprocess.TimeoutExpired):
                pass
        file.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(file, 0o600)
        return "file"

    def in_file(self, account: str) -> bool:
        return self.file(account).is_file()


# MARK: Profile

class ProfileError(Exception):
    NOT_SET_UP, NO_KEY, KEY_EXISTS = "not_set_up", "no_key", "key_exists"

    def __init__(self, kind: str):
        self.kind = kind
        super().__init__({
            self.NOT_SET_UP: tr("The sound store is not set up on this device."),
            self.NO_KEY: tr("This device has no key for the sound store. Create one, or enter the key of your store."),
            self.KEY_EXISTS: tr("This device already has a key. Replacing it would lock it out of its store; enter "
                                "another key on purpose if that is what you want."),
        }[kind])


def _state_home() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")


class StoreProfile:
    def __init__(self, settings_file: Path, state_file: Path, secrets: StoreSecrets):
        self.settings_file = Path(settings_file)
        self.state_file = Path(state_file)
        self.secrets = secrets
        self._lock = threading.Lock()

    @classmethod
    def standard(cls) -> "StoreProfile":
        """The real store of this device."""
        config = Path.home() / ".config" / "ampbench"
        return cls(config / "sound-store.json", _state_home() / "ampbench" / "store-state.json", StoreSecrets(config))

    @classmethod
    def testing(cls, folder: Path) -> "StoreProfile":
        """A store apart from the real one: its own settings, key and state, all hidden files in `folder`, and no
        keyring."""
        folder = Path(folder)
        return cls(folder / ".store-settings.json", folder / ".store-state.json",
                   StoreSecrets(folder, service=None, hidden=True))

    # MARK: Where

    def _load(self) -> dict:
        try:
            data = json.loads(self.settings_file.read_bytes())
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def _change(self, key: str, value) -> None:
        with self._lock:
            data = self._load()
            if value is None:
                data.pop(key, None)
            else:
                data[key] = value
            self.settings_file.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.settings_file.with_name(f".{self.settings_file.name}.tmp")
            # No secret in it, but a server's name is nobody else's business either.
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
            os.replace(temporary, self.settings_file)

    @property
    def settings(self) -> StoreSettings | None:
        return StoreSettings.from_json(self._load().get("settings"))

    @settings.setter
    def settings(self, value: StoreSettings | None) -> None:
        self._change("settings", value.to_json() if value else None)

    @property
    def last_sync(self) -> datetime | None:
        try:
            date = datetime.fromisoformat(str(self._load().get("lastSync", "")).replace("Z", "+00:00"))
        except ValueError:
            return None
        return date if date.tzinfo else None

    @last_sync.setter
    def last_sync(self, value: datetime | None) -> None:
        self._change("lastSync", value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if value else None)

    # MARK: Key

    @property
    def has_key(self) -> bool:
        return bool(self.secrets.read(StoreSecrets.KEY))

    @property
    def identity(self) -> AgeIdentity | None:
        """The key, or None when there is none or the kept text is no key."""
        try:
            return AgeIdentity(self.secrets.read(StoreSecrets.KEY))
        except AgeError:
            return None

    def create_key(self) -> AgeIdentity:
        """Makes a new key and keeps it. Refuses when there is one already: replacing a key would lock this device
        out of the store it was made for."""
        if self.has_key:
            raise ProfileError(ProfileError.KEY_EXISTS)
        identity = AgeIdentity.generate()
        self.secrets.write(StoreSecrets.KEY, identity.text)
        return identity

    def use_key(self, text: str) -> AgeIdentity:
        """Takes a key made on another device, as text."""
        identity = AgeIdentity(text)
        self.secrets.write(StoreSecrets.KEY, identity.text)
        # What was in step belonged to the store of the old key.
        self.forget_state()
        return identity

    @property
    def key_place(self) -> str:
        """Where the key is kept, in words for a message."""
        if self.secrets.in_file(StoreSecrets.KEY):
            return tr("in a file only you can read")
        return tr("in the desktop's keyring")

    @property
    def password(self) -> str | None:
        return self.secrets.read(StoreSecrets.PASSWORD) or None

    def set_password(self, text: str | None) -> None:
        self.secrets.write(StoreSecrets.PASSWORD, text or None)

    def forget_state(self) -> None:
        try:
            self.state_file.unlink()
        except OSError:
            pass

    def save(self, settings: StoreSettings, password: str | None = None) -> None:
        """Takes a place. Raises, with a clear text, for one that cannot be used, instead of at the first sync."""
        settings.place(password)
        if self.settings != settings:
            # Another place is another store: what was in step with the old one says nothing about it.
            self.forget_state()
        self.settings = settings
        if settings.kind == HTTP:
            self.set_password(password)

    def disconnect(self) -> None:
        """Forgets the place on this device. The store itself and the key stay as they are."""
        self.settings = None
        self.last_sync = None
        self.set_password(None)
        self.forget_state()

    # MARK: Syncing

    def _store(self, folder: Path, remove=None) -> SoundStore:
        settings = self.settings
        if settings is None:
            raise ProfileError(ProfileError.NOT_SET_UP)
        identity = self.identity
        if identity is None:
            raise ProfileError(ProfileError.NO_KEY)
        place = settings.place(self.password if settings.kind == HTTP else None)
        if remove is None:
            return SoundStore(folder, place, identity, self.state_file)
        return SoundStore(folder, place, identity, self.state_file, remove)

    def sync(self, folder: Path, remove) -> SyncReport:
        """Brings `folder` and the store in step. `remove` takes a sound away that was removed on another device;
        the app passes its trash, so nothing is deleted for good."""
        report = self._store(folder, remove).sync()
        self.last_sync = datetime.now(timezone.utc)
        return report

    def verify(self, folder: Path) -> VerifyReport:
        """Reads the whole store back and compares it with `folder`. Changes nothing."""
        return self._store(folder).verify()
