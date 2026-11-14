"""The places a sound store can live in: a folder, an HTTPS address (against a server on this machine, started here)
and a server over SSH (with a runner that never starts ssh)."""
import base64
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from ampbench.store_places import FolderPlace, HTTPPlace, SSHPlace, StoreError, run_process

OBJECT_A = "objects/" + "a" * 64 + ".age"
OBJECT_B = "objects/" + "0f" * 32 + ".age"


def all_files(folder) -> dict[str, bytes]:
    return {str(path.relative_to(folder)): path.read_bytes() for path in folder.rglob("*") if path.is_file()}


# MARK: Folder

def test_a_folder_writes_and_reads_back(tmp_path):
    folder = tmp_path / "not there yet"
    place = FolderPlace(folder)
    assert place.read(["manifest.age", OBJECT_A]) == {}
    place.write({"manifest.age": b"\x01", OBJECT_A: b"\x02\x03"})
    place.write({"manifest.age": b"\x09"})
    assert place.read(["manifest.age", OBJECT_A, OBJECT_B]) == {"manifest.age": b"\x09", OBJECT_A: b"\x02\x03"}
    assert set(all_files(folder)) == {"manifest.age", OBJECT_A}, "no unfinished file stays behind"


def test_a_folder_refuses_other_names(tmp_path):
    place = FolderPlace(tmp_path / "store")
    with pytest.raises(StoreError) as caught:
        place.write({"../escape.age": b""})
    assert caught.value == StoreError(StoreError.INVALID_NAME)
    with pytest.raises(StoreError) as caught:
        place.read(["/etc/hosts"])
    assert caught.value == StoreError(StoreError.INVALID_NAME)
    assert not (tmp_path / "escape.age").exists()


# MARK: HTTPS

class State:
    """A made-up WebDAV server: files in a dictionary, a collection must exist before a PUT into it."""

    def __init__(self):
        self.files: dict[str, bytes] = {}
        self.collections: set[str] = set()
        self.requests: list[str] = []
        self.authorizations: set[str] = set()
        self.required_authorization: str | None = None
        self.needs_collections = True
        self.fail_put_with: int | None = None
        self.redirect_to: str | None = None


class Handler(BaseHTTPRequestHandler):
    state: State

    def log_message(self, *_):
        pass

    def _answer(self, status: int, body: bytes = b"", location: str | None = None) -> None:
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self) -> None:
        state, path, method = self.state, self.path, self.command
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        state.requests.append(f"{method} {path}")
        authorization = self.headers.get("Authorization")
        if authorization:
            state.authorizations.add(authorization)
        if state.required_authorization and authorization != state.required_authorization:
            return self._answer(401)
        if state.redirect_to:
            return self._answer(302, location=state.redirect_to)
        parent = path.rsplit("/", 1)[0]
        if method == "GET":
            return self._answer(200, state.files[path]) if path in state.files else self._answer(404)
        if method == "PUT":
            if state.fail_put_with:
                return self._answer(state.fail_put_with)
            if state.needs_collections and parent not in state.collections:
                return self._answer(409)
            status = 204 if path in state.files else 201
            state.files[path] = body
            return self._answer(status)
        if method == "MKCOL":
            collection = path.rstrip("/")
            if collection in state.collections:
                return self._answer(405)
            state.collections.add(collection)
            return self._answer(201)
        self._answer(405)

    do_GET = do_PUT = do_MKCOL = do_DELETE = _handle


@pytest.fixture
def server():
    state = State()
    handler = type("TestHandler", (Handler,), {"state": state})
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    state.base = f"http://127.0.0.1:{httpd.server_address[1]}/dav/sounds"
    yield state
    httpd.shutdown()
    httpd.server_close()


def test_puts_make_the_collections_once_and_gets_read_back(server):
    place = HTTPPlace(server.base)
    place.write({OBJECT_A: b"\x01\x02", OBJECT_B: b"\x03"})
    place.write({"manifest.age": b"\x04"})
    assert server.files == {f"/dav/sounds/{OBJECT_A}": b"\x01\x02", f"/dav/sounds/{OBJECT_B}": b"\x03",
                            "/dav/sounds/manifest.age": b"\x04"}
    made = [request for request in server.requests if request.startswith("MKCOL")]
    # As the Mac asks: the address itself as it was given, then the folder of the objects, each once.
    assert made == ["MKCOL /dav/sounds", "MKCOL /dav/sounds/objects/"]
    assert not server.authorizations
    assert place.read(["manifest.age", OBJECT_A, "objects/" + "b" * 64 + ".age"]) == {
        "manifest.age": b"\x04", OBJECT_A: b"\x01\x02"}
    place.write({"manifest.age": b"\x05"})
    assert server.requests[-1] == "PUT /dav/sounds/manifest.age" and server.files["/dav/sounds/manifest.age"] == b"\x05"


def test_an_address_with_a_slash_at_its_end_is_the_same_place(server):
    place = HTTPPlace(server.base + "/")
    place.write({"manifest.age": b"\x01"})
    assert server.requests == ["PUT /dav/sounds/manifest.age", "MKCOL /dav/sounds/", "PUT /dav/sounds/manifest.age"]
    assert HTTPPlace(server.base).read(["manifest.age"]) == {"manifest.age": b"\x01"}


def test_a_plain_server_needs_no_collections(server):
    server.needs_collections = False
    HTTPPlace(server.base, user="").write({OBJECT_A: b"\x01"})
    assert server.requests == [f"PUT /dav/sounds/{OBJECT_A}"]
    assert not server.authorizations


def test_user_and_password_go_as_basic_authorization(server):
    server.needs_collections = False
    expected = "Basic " + base64.b64encode("player:made-up wörd".encode()).decode()
    server.required_authorization = expected
    place = HTTPPlace(server.base, "player", "made-up wörd")
    place.write({"manifest.age": b"\x01"})
    assert len(place.read(["manifest.age"])) == 1
    assert server.authorizations == {expected}
    wrong = HTTPPlace(server.base, "player", "other")
    with pytest.raises(StoreError) as caught:
        wrong.read(["manifest.age"])
    assert caught.value == StoreError(StoreError.NOT_ALLOWED, 401)
    with pytest.raises(StoreError) as caught:
        wrong.write({"manifest.age": b"\x02"})
    assert caught.value == StoreError(StoreError.NOT_ALLOWED, 401)
    assert "401" in str(caught.value) and "other" not in str(caught.value)
    assert server.files["/dav/sounds/manifest.age"] == b"\x01"


def test_a_full_server_and_other_errors_are_named(server):
    place = HTTPPlace(server.base)
    for status, expected in [(507, StoreError(StoreError.STORE_FULL)), (403, StoreError(StoreError.NOT_ALLOWED, 403)),
                             (500, StoreError(StoreError.HTTP, 500))]:
        server.fail_put_with = status
        with pytest.raises(StoreError) as caught:
            place.write({"manifest.age": b"\x01"})
        assert caught.value == expected


def test_a_redirect_is_not_followed(server):
    # Following it could carry the password to another server.
    server.redirect_to = "http://127.0.0.1:9/elsewhere"
    place = HTTPPlace(server.base, "player", "made-up word")
    for action in (lambda: place.read(["manifest.age"]), lambda: place.write({"manifest.age": b"\x01"})):
        with pytest.raises(StoreError) as caught:
            action()
        assert caught.value == StoreError(StoreError.HTTP, 302)
    assert all("/dav/sounds/" in request for request in server.requests)


def test_a_server_that_is_not_there_is_reported():
    # Port 9 (discard) on this machine: nothing listens there.
    with pytest.raises(StoreError) as caught:
        HTTPPlace("http://127.0.0.1:9/store").read(["manifest.age"])
    assert caught.value.kind == StoreError.NETWORK


def test_only_https_except_on_this_machine(server):
    for url in ["https://store.example/x", "http://localhost:8080/x", "http://127.0.0.1/x", "HTTPS://Store.Example/x"]:
        assert HTTPPlace.is_allowed(url), url
    for url in ["http://store.example/x", "http://localhost.example/x", "ftp://store.example/x", "file:///tmp/x",
                "store.example/x", "", "https://", "http://127.0.0.1.example/x"]:
        assert not HTTPPlace.is_allowed(url), url
    plain = HTTPPlace(server.base.replace("127.0.0.1", "store.example"), "u", "p")
    for action in (lambda: plain.read(["manifest.age"]), lambda: plain.write({"manifest.age": b""})):
        with pytest.raises(StoreError) as caught:
            action()
        assert caught.value == StoreError(StoreError.INSECURE_URL)
    assert not server.requests, "nothing may be sent without TLS, least of all the password"


def test_other_names_are_refused_before_anything_is_sent(server):
    with pytest.raises(StoreError) as caught:
        HTTPPlace(server.base).write({"../../etc/passwd": b""})
    assert caught.value == StoreError(StoreError.INVALID_NAME)
    assert not server.requests


# MARK: SSH

def test_host_and_path_take_only_harmless_characters():
    for host in ["server", "user@server.example", "my_host-2", "192.168.1.5"]:
        SSHPlace(host, "sounds")
    for host in ["", "-oProxyCommand=x", "a b", "a;b", "a$(b)", "a`b`", "a/b", "a'b", "a\nb", "server\n", "ä"]:
        with pytest.raises(StoreError) as caught:
            SSHPlace(host, "sounds")
        assert caught.value == StoreError(StoreError.INVALID_HOST), host
    for path in ["sounds", "~/ampbench-store", "/srv/store/a.b_c-d", "a/b/c"]:
        SSHPlace("server", path)
    for path in ["", "-rf", "a b", "a;b", "$(x)", "a/../b", "..", "a'b", "a\"b", "a&b", "a|b", "a*b", "a\\b", "a\nb",
                 "store\n"]:
        with pytest.raises(StoreError) as caught:
            SSHPlace("server", path)
        assert caught.value == StoreError(StoreError.INVALID_PATH), path


def test_the_commands_are_what_the_server_shall_run():
    assert SSHPlace.ssh_arguments("server", "true") == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--",
                                                        "server", "true"]
    assert SSHPlace.write_command("~/store") == "umask 077; mkdir -p ~/store && chmod 700 ~/store && tar -xf - -C ~/store"
    assert SSHPlace.read_command("~/store", ["manifest.age", OBJECT_A]) == (
        f"cd ~/store 2>/dev/null || exit 0; for f in manifest.age {OBJECT_A}; do [ -f \"$f\" ] && echo \"$f\"; done"
        " | tar -cf - -T -")


def local_server(log: list):
    """Runs what would go to the server in a local shell instead: the same commands and the same tar streams, no
    ssh."""
    def run(executable, arguments, data):
        if executable == SSHPlace.SSH:
            log.append(arguments)
            return run_process("/bin/sh", ["-c", arguments[-1]], data)
        assert executable == SSHPlace.TAR
        return run_process(executable, arguments, data)
    return run


needs_tar = pytest.mark.skipif(not shutil.which("tar"), reason="no tar here")


@needs_tar
def test_files_travel_as_tar_streams(tmp_path):
    remote = tmp_path / "remote" / "store"
    if not SSHPlace.is_valid_path(str(remote)):
        pytest.skip("the temporary folder's path has characters a store path may not have")
    log: list = []
    place = SSHPlace("made-up-host", str(remote), runner=local_server(log))
    assert place.read(["manifest.age", OBJECT_A]) == {}, "a folder that is not there is an empty store"
    large = bytes(range(256)) * 1200
    place.write({OBJECT_A: large, "manifest.age": b"\x01\x02\x03"})
    assert all_files(remote) == {OBJECT_A: large, "manifest.age": b"\x01\x02\x03"}
    assert remote.stat().st_mode & 0o777 == 0o700, "only the owner may look into the folder on the server"
    place.write({"manifest.age": b"\x04"})
    assert place.read(["manifest.age", OBJECT_A, OBJECT_B]) == {"manifest.age": b"\x04", OBJECT_A: large}
    assert place.read([OBJECT_B]) == {}
    assert len(log) == 5, "one connection per call"
    assert all(call[:6] == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", "made-up-host"] for call in log)


@needs_tar
def test_many_names_are_read_in_several_connections(tmp_path):
    remote = tmp_path / "remote"
    if not SSHPlace.is_valid_path(str(remote)):
        pytest.skip("the temporary folder's path has characters a store path may not have")
    log: list = []
    place = SSHPlace("made-up-host", str(remote), runner=local_server(log))
    names = [f"objects/{number:064x}.age" for number in range(SSHPlace.NAMES_PER_READ + 3)]
    place.write({names[0]: b"\x01", names[-1]: b"\x02"})
    assert place.read(names) == {names[0]: b"\x01", names[-1]: b"\x02"}
    assert len(log) == 3


@needs_tar
def test_a_link_in_the_servers_stream_is_not_followed(tmp_path):
    secret = tmp_path / "outside.txt"
    secret.write_text("not part of the store")
    packed = tmp_path / "packed"
    packed.mkdir()
    (packed / "manifest.age").symlink_to(secret)
    archive = subprocess.run(["tar", "-cf", "-", "-C", str(packed), "manifest.age"], capture_output=True, check=True).stdout

    def run(executable, arguments, data):
        return (0, archive, b"") if executable == SSHPlace.SSH else run_process(executable, arguments, data)
    assert SSHPlace("made-up-host", "store", runner=run).read(["manifest.age"]) == {}


def test_a_failed_connection_says_what_ssh_said():
    place = SSHPlace("made-up-host", "store", runner=lambda *_: (255, b"", b"ssh: connect to host made-up-host: refused\n"))
    with pytest.raises(StoreError) as caught:
        place.read(["manifest.age"])
    assert caught.value == StoreError(StoreError.SSH, "ssh: connect to host made-up-host: refused")
    assert "refused" in str(caught.value)
    silent = SSHPlace("made-up-host", "store", runner=lambda *_: (255, b"", b""))
    with pytest.raises(StoreError) as caught:
        silent.write({"manifest.age": b"\x01"}) if not shutil.which("tar") else silent.read(["manifest.age"])
    assert caught.value == StoreError(StoreError.SSH, "exit 255")

    def missing(*_):
        raise FileNotFoundError(2, "No such file or directory")
    with pytest.raises(StoreError) as caught:
        SSHPlace("made-up-host", "store", runner=missing).read(["manifest.age"])
    assert caught.value.kind == StoreError.SSH


def test_other_names_never_reach_a_command():
    calls = []
    place = SSHPlace("made-up-host", "store", runner=lambda *call: calls.append(call) or (0, b"", b""))
    for action in (lambda: place.read(["manifest.age; rm -rf ~"]), lambda: place.write({"$(x)": b""})):
        with pytest.raises(StoreError) as caught:
            action()
        assert caught.value == StoreError(StoreError.INVALID_NAME)
    assert not calls
