"""Where the encrypted files of a sound store live: a folder, a server reached over SSH, or one that takes HTTPS GET
and PUT. A place only ever sees ciphertext and names that say nothing about the sounds.

A port of Sources/SoundStore/StoreLocation.swift, HTTPLocation.swift and SSHLocation.swift. Every place has
`read(names)`, which returns the files with these names (a name the store does not hold is simply absent), and
`write(files)`."""
from __future__ import annotations

import base64
import http.client
import os
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from .i18n import tr

MANIFEST = "manifest.age"
OBJECT_FOLDER = "objects"

_OBJECT_NAME = re.compile(rf"{OBJECT_FOLDER}/[0-9a-f]{{64}}\.age")


def object_name(hex_digits: str) -> str:
    return f"{OBJECT_FOLDER}/{hex_digits}.age"


def is_valid_name(name: str) -> bool:
    """The only names a store uses: the index and the objects it points to. Every place refuses other names, so no
    name can ever need quoting or leave the store's folder."""
    return name == MANIFEST or _OBJECT_NAME.fullmatch(name) is not None


class StoreError(Exception):
    """`kind` names the case, `detail` what it is about (a path, an HTTP status, what ssh said)."""
    INVALID_NAME, WRONG_KEY = "invalid_name", "wrong_key"
    DAMAGED_MANIFEST, NEWER_MANIFEST = "damaged_manifest", "newer_manifest"
    UNSAFE_PATH, MISSING_OBJECT, DAMAGED_OBJECT = "unsafe_path", "missing_object", "damaged_object"
    INVALID_HOST, INVALID_PATH, SSH = "invalid_host", "invalid_path", "ssh"
    INSECURE_URL, INVALID_URL, NOT_ALLOWED = "insecure_url", "invalid_url", "not_allowed"
    STORE_FULL, HTTP, NETWORK = "store_full", "http", "network"
    INCOMPLETE_SETTINGS = "incomplete_settings"

    def __init__(self, kind: str, detail=None):
        self.kind, self.detail = kind, detail
        super().__init__(self._text())

    def __eq__(self, other) -> bool:
        return isinstance(other, StoreError) and (self.kind, self.detail) == (other.kind, other.detail)

    def __hash__(self) -> int:
        return hash((self.kind, self.detail))

    def _text(self) -> str:
        kind, detail = self.kind, self.detail
        if kind == self.INVALID_NAME:
            return tr("The store was asked for a file name it does not use.")
        if kind == self.WRONG_KEY:
            return tr("This key does not open the store. Enter the key the store was set up with.")
        if kind == self.DAMAGED_MANIFEST:
            return tr("The store's index is damaged. Nothing was changed.")
        if kind == self.NEWER_MANIFEST:
            return tr("The store was written by a newer version of AmpBench (format {}). Update AmpBench on this "
                      "device.", detail)
        if kind == self.UNSAFE_PATH:
            return tr("The store's index names a file outside the sounds folder. Nothing was changed.")
        if kind == self.MISSING_OBJECT:
            return tr("The store has no data for “{}”. Nothing was changed.", detail)
        if kind == self.DAMAGED_OBJECT:
            return tr("The stored data for “{}” is damaged. Nothing was changed.", detail)
        if kind == self.INVALID_HOST:
            return tr("The server name may only hold letters, digits, dots, hyphens, underscores and @.")
        if kind == self.INVALID_PATH:
            return tr("The folder on the server may only hold letters, digits, dots, hyphens, underscores, slashes "
                      "and ~.")
        if kind == self.SSH:
            return tr("The server could not be reached over SSH: {}", detail)
        if kind == self.INSECURE_URL:
            return tr("The address must start with https://.")
        if kind == self.INVALID_URL:
            return tr("This is not a valid address.")
        if kind == self.NOT_ALLOWED:
            return tr("The server refused the user name or password (HTTP {}).", detail)
        if kind == self.STORE_FULL:
            return tr("The server has no space left for the store.")
        if kind == self.HTTP:
            return tr("The server answered with an error (HTTP {}).", detail)
        if kind == self.NETWORK:
            return tr("The server could not be reached: {}", detail)
        return tr("The store's settings are incomplete.")


def check_names(names) -> None:
    for name in names:
        if not is_valid_name(name):
            raise StoreError(StoreError.INVALID_NAME)


def write_atomically(path: Path, data: bytes) -> None:
    """Writes beside the file and renames, so nobody ever reads half a file. The hidden name keeps the library and
    the sync from taking the unfinished file for a sound."""
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_bytes(data)
        os.replace(temporary, path)
    except BaseException:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


# MARK: Folder

class FolderPlace:
    """A folder as a store: any synced folder (a cloud drive), a mounted share or a stick."""

    def __init__(self, folder: Path):
        self.folder = Path(folder)

    def read(self, names: list[str]) -> dict[str, bytes]:
        check_names(names)
        found = {}
        for name in names:
            path = self.folder / name
            if path.exists():
                found[name] = path.read_bytes()
        return found

    def write(self, files: dict[str, bytes]) -> None:
        check_names(files)
        for name, data in files.items():
            path = self.folder / name
            path.parent.mkdir(parents=True, exist_ok=True)
            write_atomically(path, data)


# MARK: HTTPS

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect is an answer like any other. Following one could carry the password to another server or to an
    address without TLS."""

    def redirect_request(self, *_):
        return None


class HTTPPlace:
    """A server that takes HTTPS GET and PUT below one address: WebDAV (Nextcloud, a NAS) or a plain web server
    with PUT switched on. Nothing is listed, so the server needs no PROPFIND."""
    TIMEOUT = 30

    def __init__(self, base: str, user: str | None = None, password: str | None = None):
        self.base = base.strip()
        self._user = user or None
        self._password = password
        self._opener = urllib.request.build_opener(_NoRedirect)

    @staticmethod
    def parts(url: str) -> urllib.parse.SplitResult | None:
        """The address taken apart, or None when it is no address with a server name."""
        try:
            parts = urllib.parse.urlsplit(url)
            _ = parts.port
        except ValueError:
            return None
        return parts if parts.scheme and parts.hostname else None

    @classmethod
    def is_allowed(cls, url: str) -> bool:
        """The password and the ciphertext travel only over TLS. A server on this machine is the exception, for
        tests."""
        parts = cls.parts(url)
        if parts is None:
            return False
        scheme = parts.scheme.lower()
        return scheme == "https" or (scheme == "http" and parts.hostname in ("localhost", "127.0.0.1"))

    def url_for(self, name: str) -> str:
        parts = urllib.parse.urlsplit(self.base)
        return urllib.parse.urlunsplit(parts._replace(path=parts.path.rstrip("/") + "/" + name))

    def read(self, names: list[str]) -> dict[str, bytes]:
        check_names(names)
        self._check_base()
        found = {}
        for name in names:
            data, status = self._send("GET", self.url_for(name))
            if status == 200:
                found[name] = data
            elif status not in (404, 410):
                raise self.error_for(status)
        return found

    def write(self, files: dict[str, bytes]) -> None:
        check_names(files)
        self._check_base()
        made: set[str] = set()
        for name, data in files.items():
            url = self.url_for(name)
            status = self._send("PUT", url, data)[1]
            # WebDAV answers 409 (some servers 404) while the collection is missing. It is made once, then retried.
            parent = url[:url.rindex("/") + 1]
            if status in (404, 409) and parent not in made:
                made.add(parent)
                if parent != self.base and self.base not in made:
                    made.add(self.base)
                    self._send("MKCOL", self.base)
                self._send("MKCOL", parent)
                status = self._send("PUT", url, data)[1]
            if not 200 <= status < 300:
                raise self.error_for(status)

    def _check_base(self) -> None:
        if not self.is_allowed(self.base):
            raise StoreError(StoreError.INSECURE_URL)

    def _send(self, method: str, url: str, body: bytes | None = None) -> tuple[bytes, int]:
        headers = {}
        if body is not None:
            headers["Content-Type"] = "application/octet-stream"
        if self._user:
            token = base64.b64encode(f"{self._user}:{self._password or ''}".encode("utf-8")).decode("ascii")
            headers["Authorization"] = f"Basic {token}"
        try:
            request = urllib.request.Request(url, data=body, headers=headers, method=method)
            with self._opener.open(request, timeout=self.TIMEOUT) as response:
                return response.read(), response.status
        except urllib.error.HTTPError as error:
            with error:
                return error.read(), error.code
        except (http.client.InvalidURL, ValueError):
            raise StoreError(StoreError.INVALID_URL) from None
        except (urllib.error.URLError, http.client.HTTPException, OSError) as error:
            # Only the reason, never the address: it may carry a name the user does not want in a message.
            reason = getattr(error, "reason", None) or error
            raise StoreError(StoreError.NETWORK, str(reason)[:300]) from None

    @staticmethod
    def error_for(status: int) -> StoreError:
        if status in (401, 403):
            return StoreError(StoreError.NOT_ALLOWED, status)
        if status == 507:
            return StoreError(StoreError.STORE_FULL)
        return StoreError(StoreError.HTTP, status)


# MARK: SSH

def run_process(executable: str, arguments: list[str], data: bytes | None) -> tuple[int, bytes, bytes]:
    """Starts the program with this standard input and returns its status and what it wrote."""
    # Without this a Mac's tar packs a "._name" file beside every file, for attributes nobody needs there.
    environment = {**os.environ, "COPYFILE_DISABLE": "1"}
    result = subprocess.run([executable, *arguments], input=data, capture_output=True, env=environment,
                            stdin=None if data is not None else subprocess.DEVNULL, timeout=SSHPlace.TIMEOUT)
    return result.returncode, result.stdout, result.stderr


class SSHPlace:
    """A folder on a server reached with the system's `ssh`, under the name and key of the user's own SSH
    configuration. The app holds no SSH secret: the connection never asks (`BatchMode`), it works or reports why not.

    One connection per call. Files travel as a tar stream, so a first backup of hundreds of sounds is one connection
    too. `runner` runs a program; tests replace it and never start ssh."""
    SSH = "ssh"
    TAR = "tar"
    # A remote command is one argument for the server's shell, which Linux limits to 128 KiB.
    NAMES_PER_READ = 500
    # ssh gives up on a server that does not answer after 10 s; this only ends a transfer that hangs for good.
    TIMEOUT = 600

    def __init__(self, host: str, path: str, runner=None):
        if not self.is_valid_host(host):
            raise StoreError(StoreError.INVALID_HOST)
        if not self.is_valid_path(path):
            raise StoreError(StoreError.INVALID_PATH)
        self.host, self.path = host, path
        self._run = runner or run_process

    # Host and path go into a command line unquoted, so only characters that mean nothing to ssh or a shell pass.
    @staticmethod
    def is_valid_host(host: str) -> bool:
        return not host.startswith("-") and re.fullmatch(r"[A-Za-z0-9._@-]+", host) is not None

    @staticmethod
    def is_valid_path(path: str) -> bool:
        return not path.startswith("-") and ".." not in path and re.fullmatch(r"[A-Za-z0-9._/~-]+", path) is not None

    @staticmethod
    def ssh_arguments(host: str, command: str) -> list[str]:
        return ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", host, command]

    @staticmethod
    def write_command(path: str) -> str:
        """Unpacks the stream on standard input into the folder, which it creates."""
        # Only the owner may read the folder: the files are encrypted, but who else is on the server need not see
        # how many there are and when they change.
        return f"umask 077; mkdir -p {path} && chmod 700 {path} && tar -xf - -C {path}"

    @staticmethod
    def read_command(path: str, names: list[str]) -> str:
        """Packs those of the names that exist. A missing folder is a store with nothing in it, not an error. Only
        options every tar knows, so the server may be Linux or a Mac."""
        return (f"cd {path} 2>/dev/null || exit 0; for f in {' '.join(names)}; do [ -f \"$f\" ] && echo \"$f\"; done"
                " | tar -cf - -T -")

    def read(self, names: list[str]) -> dict[str, bytes]:
        check_names(names)
        found = {}
        for start in range(0, len(names), self.NAMES_PER_READ):
            batch = names[start:start + self.NAMES_PER_READ]
            archive = self._remote(self.read_command(self.path, batch), None)
            if not archive:
                continue
            folder = Path(tempfile.mkdtemp(prefix="ampbench-store-"))
            try:
                self._local(self.TAR, ["-xf", "-", "-C", str(folder)], archive)
                inside = folder.resolve()
                for name in batch:
                    path = folder / name
                    # Only plain files inside the folder: a link in a stream from the server must not make the app
                    # read something else.
                    if path.is_symlink() or not path.is_file() or inside not in path.resolve().parents:
                        continue
                    found[name] = path.read_bytes()
            finally:
                shutil.rmtree(folder, ignore_errors=True)
        return found

    def write(self, files: dict[str, bytes]) -> None:
        check_names(files)
        if not files:
            return
        folder = Path(tempfile.mkdtemp(prefix="ampbench-store-"))
        try:
            FolderPlace(folder).write(files)
            archive = self._local(self.TAR, ["-cf", "-", "-C", str(folder), *sorted(files)], None)
            self._remote(self.write_command(self.path), archive)
        finally:
            shutil.rmtree(folder, ignore_errors=True)

    def _remote(self, command: str, data: bytes | None) -> bytes:
        return self._local(self.SSH, self.ssh_arguments(self.host, command), data)

    def _local(self, executable: str, arguments: list[str], data: bytes | None) -> bytes:
        try:
            status, output, errors = self._run(executable, arguments, data)
        except subprocess.TimeoutExpired:
            raise StoreError(StoreError.SSH, f"{executable}: timeout") from None
        except OSError as error:
            raise StoreError(StoreError.SSH, f"{executable}: {error.strerror or error}") from None
        if status != 0:
            raise StoreError(StoreError.SSH, self.message(errors, status))
        return output

    @staticmethod
    def message(errors: bytes, status: int) -> str:
        """What ssh said, short enough for a message line."""
        text = errors.decode("utf-8", "replace").strip()
        return text[:300] if text else f"exit {status}"
