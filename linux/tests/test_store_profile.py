"""What one device remembers about its sound store, and the store's commands. Every test has a profile of its own in
a temporary folder, so the real store, its settings and the keyring are never read or touched."""
import io
import json
import stat

import pytest

pytest.importorskip("cryptography")

from ampbench import app, store_profile  # noqa: E402
from ampbench.age import AgeError, AgeIdentity  # noqa: E402
from ampbench.store_places import FolderPlace, HTTPPlace, SSHPlace, StoreError  # noqa: E402
from ampbench.store_profile import (FOLDER, HTTP, SSH, ProfileError, StoreProfile, StoreSecrets,  # noqa: E402
                                    StoreSettings)


@pytest.fixture(autouse=True)
def nothing_real(monkeypatch, tmp_path):
    """No secret-tool and no home folder: a slip in a test cannot reach the user's keyring, settings or trash."""
    def refuse(*arguments, **_):
        raise AssertionError(f"a test started a program: {arguments}")
    monkeypatch.setattr(store_profile.subprocess, "run", refuse)
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "home" / "share"))
    monkeypatch.delenv("XDG_STATE_HOME", raising=False)


@pytest.fixture
def profile(tmp_path):
    return StoreProfile.testing(tmp_path / "profile")


# MARK: Settings

def test_settings_name_their_place_without_a_secret():
    assert StoreSettings(FOLDER, folder_path="/made/up/AmpBench-Store").summary == "Folder “AmpBench-Store”"
    assert StoreSettings(FOLDER).summary == "Folder"
    assert StoreSettings(SSH, host="made-up-host", path="store").summary == "Server made-up-host (SSH)"
    settings = StoreSettings(HTTP, url="https://player@store.example:8443/dav/", user="player")
    assert settings.summary == "Server store.example (HTTPS)"
    assert StoreSettings(HTTP, url="nonsense").summary == "Server (HTTPS)"


def test_settings_give_their_place_or_say_what_is_wrong(tmp_path):
    place = StoreSettings(FOLDER, folder_path=str(tmp_path / "store")).place()
    assert isinstance(place, FolderPlace) and place.folder == tmp_path / "store"
    assert StoreSettings(FOLDER, folder_path="~/store").place().folder == tmp_path / "home" / "store"
    place = StoreSettings(SSH, host="made-up-host", path="~/store").place()
    assert isinstance(place, SSHPlace) and (place.host, place.path) == ("made-up-host", "~/store")
    place = StoreSettings(HTTP, url=" https://store.example/dav \n", user="player").place("made-up word")
    assert isinstance(place, HTTPPlace) and place.base == "https://store.example/dav"
    for settings, kind in [(StoreSettings(FOLDER), StoreError.INCOMPLETE_SETTINGS),
                           (StoreSettings(FOLDER, folder_path=""), StoreError.INCOMPLETE_SETTINGS),
                           (StoreSettings(SSH, host="made-up-host"), StoreError.INCOMPLETE_SETTINGS),
                           (StoreSettings(SSH, host="a b", path="store"), StoreError.INVALID_HOST),
                           (StoreSettings(SSH, host="made-up-host", path="a;b"), StoreError.INVALID_PATH),
                           (StoreSettings(HTTP), StoreError.INCOMPLETE_SETTINGS),
                           (StoreSettings(HTTP, url="store.example/dav"), StoreError.INVALID_URL),
                           (StoreSettings(HTTP, url="http://store.example/dav"), StoreError.INSECURE_URL)]:
        with pytest.raises(StoreError) as caught:
            settings.place()
        assert caught.value.kind == kind, settings


def test_settings_are_kept_as_the_mac_names_them():
    settings = StoreSettings(HTTP, url="https://store.example/dav/", user="player")
    assert settings.to_json() == {"kind": "http", "url": "https://store.example/dav/", "user": "player"}
    assert StoreSettings(FOLDER, folder_path="/made/up").to_json() == {"kind": "folder", "folderPath": "/made/up"}
    assert StoreSettings.from_json(settings.to_json()) == settings
    for other in [None, {}, {"kind": "ftp"}, {"kind": "ssh", "host": 5}, "folder"]:
        assert StoreSettings.from_json(other) is None


# MARK: Profile

def test_a_new_device_has_no_store(profile, tmp_path):
    assert profile.settings is None and profile.last_sync is None
    assert not profile.has_key and profile.identity is None and profile.password is None
    with pytest.raises(ProfileError) as caught:
        profile.sync(tmp_path / "sounds", lambda path: None)
    assert caught.value.kind == ProfileError.NOT_SET_UP
    assert not (tmp_path / "profile").exists(), "looking at a profile writes nothing"


def test_settings_are_kept_and_hold_no_secret(profile):
    settings = StoreSettings(HTTP, url="https://store.example/dav/", user="player")
    profile.save(settings, "made-up word")
    profile.create_key()
    assert StoreProfile.testing(profile.settings_file.parent).settings == settings
    text = profile.settings_file.read_text()
    assert "AGE-SECRET-KEY" not in text and "made-up word" not in text
    assert stat.S_IMODE(profile.settings_file.stat().st_mode) == 0o600
    assert profile.password == "made-up word"


def test_a_store_without_a_key_does_not_sync(profile, tmp_path):
    profile.save(StoreSettings(FOLDER, folder_path=str(tmp_path / "store")))
    for action in (lambda: profile.sync(tmp_path / "sounds", lambda path: None), lambda: profile.verify(tmp_path / "sounds")):
        with pytest.raises(ProfileError) as caught:
            action()
        assert caught.value.kind == ProfileError.NO_KEY
    assert not (tmp_path / "store").exists()


def test_the_key_is_made_once_and_kept_in_a_file_only_the_user_reads(profile):
    identity = profile.create_key()
    assert profile.has_key and profile.identity == identity
    file = profile.secrets.file(StoreSecrets.KEY)
    assert file.read_text() == identity.text and stat.S_IMODE(file.stat().st_mode) == 0o600
    assert file.name.startswith("."), "hidden, so neither the library nor a sync takes it for a sound"
    assert profile.key_place == "in a file only you can read"
    with pytest.raises(ProfileError) as caught:
        profile.create_key()
    assert caught.value.kind == ProfileError.KEY_EXISTS
    assert profile.identity == identity


def test_a_key_from_another_device_replaces_the_memory_of_the_old_store(profile):
    profile.create_key()
    profile.state_file.write_text('{"store": "old", "objects": {}}')
    other = AgeIdentity.generate()
    assert profile.use_key(f"  {other.text.lower()}\n") == other
    assert profile.identity == other and profile.secrets.file(StoreSecrets.KEY).read_text() == other.text
    assert not profile.state_file.exists()
    with pytest.raises(AgeError):
        profile.use_key("AGE-SECRET-KEY-1NONSENSE")
    assert profile.identity == other


def test_two_devices_sync_through_their_profiles(tmp_path):
    mac, laptop = StoreProfile.testing(tmp_path / "mac"), StoreProfile.testing(tmp_path / "laptop")
    settings = StoreSettings(FOLDER, folder_path=str(tmp_path / "store"))
    mac.save(settings)
    laptop.save(settings)
    laptop.use_key(mac.create_key().text)
    (tmp_path / "mac-sounds").mkdir()
    (tmp_path / "mac-sounds" / "Lead.json").write_text("first")
    assert mac.sync(tmp_path / "mac-sounds", lambda path: None).uploaded == ["Lead.json"]
    assert mac.last_sync is not None and mac.state_file.exists()
    assert laptop.sync(tmp_path / "laptop-sounds", lambda path: None).downloaded == ["Lead.json"]
    assert laptop.verify(tmp_path / "laptop-sounds").is_in_step

    # A sound removed on one device goes through the given removal on the other.
    (tmp_path / "mac-sounds" / "Lead.json").unlink()
    mac.sync(tmp_path / "mac-sounds", lambda path: None)
    removed = []
    assert laptop.sync(tmp_path / "laptop-sounds", removed.append).removed_locally == ["Lead.json"]
    assert removed == [tmp_path / "laptop-sounds" / "Lead.json"]


def test_another_place_forgets_what_was_in_step(profile, tmp_path):
    profile.create_key()
    first = StoreSettings(FOLDER, folder_path=str(tmp_path / "one"))
    profile.save(first)
    profile.sync(tmp_path / "sounds", lambda path: None)
    assert profile.state_file.exists()
    profile.save(first)
    assert profile.state_file.exists(), "the same place again keeps it"
    profile.save(StoreSettings(FOLDER, folder_path=str(tmp_path / "two")))
    assert not profile.state_file.exists()
    with pytest.raises(StoreError):
        profile.save(StoreSettings(HTTP, url="http://store.example/"), "made-up word")
    assert profile.settings.folder_path == str(tmp_path / "two") and profile.password is None


def test_disconnecting_forgets_the_place_and_keeps_the_key(profile, tmp_path):
    identity = profile.create_key()
    profile.save(StoreSettings(HTTP, url="https://store.example/dav/", user="player"), "made-up word")
    profile.state_file.write_text("{}")
    profile.last_sync = profile.last_sync or __import__("datetime").datetime.now().astimezone()
    profile.disconnect()
    assert profile.settings is None and profile.last_sync is None and profile.password is None
    assert not profile.state_file.exists()
    assert profile.identity == identity


def test_the_real_profile_lives_in_the_config_and_state_folders(tmp_path, monkeypatch):
    home = tmp_path / "home"
    profile = StoreProfile.standard()
    assert profile.settings_file == home / ".config" / "ampbench" / "sound-store.json"
    assert profile.state_file == home / ".local" / "state" / "ampbench" / "store-state.json"
    assert profile.secrets.file(StoreSecrets.KEY) == home / ".config" / "ampbench" / "store-key"
    assert profile.secrets.file(StoreSecrets.PASSWORD) == home / ".config" / "ampbench" / "store-password"
    assert profile.secrets.service == "ampbench"
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    assert StoreProfile.standard().state_file == tmp_path / "state" / "ampbench" / "store-state.json"


# MARK: Secrets

class FakeKeyring:
    """What `secret-tool` does, in a dictionary."""

    def __init__(self, works: bool = True):
        self.items: dict[tuple, str] = {}
        self.calls: list[list[str]] = []
        self.works = works

    def run(self, command, input=None, **_):
        self.calls.append(command)
        action, attributes = command[1], tuple(argument for argument in command[2:] if not argument.startswith("--"))
        result = type("Result", (), {"returncode": 0, "stdout": ""})()
        if not self.works:
            result.returncode = 1
        elif action == "store":
            self.items[attributes] = input
        elif action == "lookup":
            result.stdout = self.items.get(attributes, "")
            result.returncode = 0 if attributes in self.items else 1
        elif action == "clear":
            self.items.pop(attributes, None)
        return result


def test_secrets_go_to_the_keyring_under_their_own_attributes(tmp_path, monkeypatch):
    keyring = FakeKeyring()
    monkeypatch.setattr(store_profile.shutil, "which", lambda name: "/made/up/secret-tool")
    monkeypatch.setattr(store_profile.subprocess, "run", keyring.run)
    secrets = StoreSecrets(tmp_path)
    assert secrets.write(StoreSecrets.KEY, "made-up key") == "keyring"
    assert secrets.write(StoreSecrets.PASSWORD, "made-up word") == "keyring"
    assert keyring.items == {("service", "ampbench", "account", "store-key"): "made-up key",
                             ("service", "ampbench", "account", "store-password"): "made-up word"}
    assert not any("made-up" in argument for call in keyring.calls for argument in call), "never as an argument"
    assert not list(tmp_path.iterdir()), "and not in a file as well"
    assert secrets.read(StoreSecrets.KEY) == "made-up key" and not secrets.in_file(StoreSecrets.KEY)
    assert secrets.write(StoreSecrets.KEY, None) == ""
    assert secrets.read(StoreSecrets.KEY) == "" and secrets.read(StoreSecrets.PASSWORD) == "made-up word"


def test_without_a_keyring_secrets_go_to_files_only_the_user_reads(tmp_path, monkeypatch):
    keyring = FakeKeyring(works=False)
    monkeypatch.setattr(store_profile.shutil, "which", lambda name: "/made/up/secret-tool")
    monkeypatch.setattr(store_profile.subprocess, "run", keyring.run)
    secrets = StoreSecrets(tmp_path / "config")
    assert secrets.write(StoreSecrets.PASSWORD, "made-up word") == "file"
    file = tmp_path / "config" / "store-password"
    assert file.read_text() == "made-up word" and stat.S_IMODE(file.stat().st_mode) == 0o600
    assert secrets.read(StoreSecrets.PASSWORD) == "made-up word" and secrets.in_file(StoreSecrets.PASSWORD)
    secrets.write(StoreSecrets.PASSWORD, "")
    assert not file.exists()


def test_a_test_profile_never_asks_for_the_keyring(profile, monkeypatch):
    monkeypatch.setattr(store_profile.shutil, "which", lambda name: pytest.fail("looked for secret-tool"))
    profile.create_key()
    profile.set_password("made-up word")
    assert profile.has_key and profile.password == "made-up word"
    profile.set_password(None)
    assert profile.password is None


# MARK: Commands

def run(arguments: list[str], capsys, monkeypatch, stdin: str = "") -> tuple[int, str, str]:
    monkeypatch.setattr("sys.stdin", io.StringIO(stdin))
    status = app.main(arguments)
    captured = capsys.readouterr()
    return status, captured.out, captured.err


def test_the_commands_set_up_sync_and_verify_a_store(tmp_path, capsys, monkeypatch):
    sounds, place = tmp_path / "sounds", tmp_path / "place"
    sounds.mkdir()
    (sounds / "Lead.json").write_text("first")
    here = ["--store-profile", str(tmp_path / "profile"), "--presets-folder", str(sounds)]

    assert run([*here, "--store-status"], capsys, monkeypatch) == (0, "The sound store is not set up on this device.\n", "")
    status, out, err = run([*here, "--store-sync"], capsys, monkeypatch)
    assert (status, out) == (1, "") and err == "The sound store is not set up on this device.\n"

    status, out, _ = run([*here, "--store-setup", "folder", str(place)], capsys, monkeypatch)
    assert status == 0 and out.splitlines() == [
        "The sound store is set up: Folder “place”.",
        "This device has no key yet: --store-key new makes one, --store-key set takes one you have."]
    status, _, err = run([*here, "--store-key", "show"], capsys, monkeypatch)
    assert status == 1 and err.startswith("This device has no key for the sound store.")

    status, out, _ = run([*here, "--store-key", "new"], capsys, monkeypatch)
    identity = StoreProfile.testing(tmp_path / "profile").identity
    assert status == 0 and out.splitlines()[0] == f"A new key is kept in a file only you can read. Its public half: {identity.recipient}"
    assert "AGE-SECRET-KEY" not in out, "making a key prints only its public half"
    status, _, err = run([*here, "--store-key", "new"], capsys, monkeypatch)
    assert status == 1 and err.startswith("This device already has a key.")
    assert run([*here, "--store-key", "show"], capsys, monkeypatch) == (0, identity.text + "\n", "")

    status, out, _ = run([*here, "--store-sync"], capsys, monkeypatch)
    assert (status, out) == (0, "Store: 1 stored.\n  stored: Lead.json\n")
    assert run([*here, "--store-sync"], capsys, monkeypatch)[1] == "The store is up to date: 1 sounds.\n"
    assert run([*here, "--store-verify"], capsys, monkeypatch)[:2] == (
        0, "Checked: all 1 sounds in the store can be read and equal the ones here.\n")
    status, out, _ = run([*here, "--store-status"], capsys, monkeypatch)
    lines = out.splitlines()
    assert status == 0 and lines[0] == "Place: Folder “place”" and lines[1] == "Key: in a file only you can read"
    assert lines[2].startswith("Last sync: 20") and lines[2].endswith("Z") and lines[3] == f"Sounds folder: {sounds}"

    # A second device takes the key from standard input, also from a file as `age-keygen` writes it.
    other = ["--store-profile", str(tmp_path / "other"), "--presets-folder", str(tmp_path / "other-sounds")]
    run([*other, "--store-setup", "folder", str(place)], capsys, monkeypatch)
    status, out, _ = run([*other, "--store-key", "set"], capsys, monkeypatch, stdin=f"# created: today\n# public key: x\n{identity.text}\n")
    assert status == 0 and out == f"The key is kept in a file only you can read. Its public half: {identity.recipient}\n"
    assert run([*other, "--store-sync"], capsys, monkeypatch)[1] == "Store: 1 fetched.\n  fetched: Lead.json\n"
    assert (tmp_path / "other-sounds" / "Lead.json").read_text() == "first"

    # Removed on the first device: the second one moves it to the trash, never deletes it.
    (sounds / "Lead.json").unlink()
    assert run([*here, "--store-sync"], capsys, monkeypatch)[1] == "Store: 1 removed in the store.\n  removed in the store: Lead.json\n"
    assert run([*other, "--store-sync"], capsys, monkeypatch)[1] == "Store: 1 removed here.\n  removed here: Lead.json\n"
    assert (tmp_path / "home" / "share" / "Trash" / "files" / "Lead.json").read_text() == "first"

    # A damaged store: verify says so with its exit status.
    (sounds / "Lead.json").write_text("second")
    run([*here, "--store-sync"], capsys, monkeypatch)
    for file in (place / "objects").iterdir():
        file.write_bytes(b"damaged")
    status, out, _ = run([*here, "--store-verify"], capsys, monkeypatch)
    assert status == 1 and out == "The store is damaged: 1 of its sounds cannot be restored.\n  damaged in the store: Lead.json\n"


def test_the_commands_refuse_what_they_cannot_use(tmp_path, capsys, monkeypatch):
    here = ["--store-profile", str(tmp_path / "profile")]
    for arguments in (["--store-setup", "folder"], ["--store-setup", "ssh", "host"], ["--store-setup", "https"],
                      ["--store-setup", "dropbox", "x"], ["--store-key", "delete"]):
        status, out, _ = run([*here, *arguments], capsys, monkeypatch)
        assert status == 64 and out.startswith("usage: "), arguments
    assert run([*here, "--store-key", "set"], capsys, monkeypatch, stdin="")[0] == 64
    status, _, err = run([*here, "--store-key", "set"], capsys, monkeypatch, stdin="not a key\n")
    assert status == 1 and err == "This is not a valid key. A key starts with AGE-SECRET-KEY-1.\n"
    for arguments, text in ((["--store-setup", "ssh", "a b", "store"], "The server name may only"),
                            (["--store-setup", "ssh", "made-up-host", "a;b"], "The folder on the server may only"),
                            (["--store-setup", "https", "http://store.example/dav"], "The address must start with https://."),
                            (["--store-setup", "https", "store.example"], "This is not a valid address.")):
        status, _, err = run([*here, *arguments], capsys, monkeypatch)
        assert status == 1 and err.startswith(text), arguments
    assert StoreProfile.testing(tmp_path / "profile").settings is None


def test_the_password_comes_from_standard_input_and_stays_out_of_the_settings(tmp_path, capsys, monkeypatch):
    here = ["--store-profile", str(tmp_path / "profile")]
    status, out, _ = run([*here, "--store-setup", "https", "https://store.example/dav/", "player"], capsys, monkeypatch,
                         stdin="made-up word\n")
    assert status == 0 and out.startswith("The sound store is set up: Server store.example (HTTPS).")
    profile = StoreProfile.testing(tmp_path / "profile")
    assert profile.settings == StoreSettings(HTTP, url="https://store.example/dav/", user="player")
    assert profile.password == "made-up word"
    assert json.loads(profile.settings_file.read_text()) == {
        "settings": {"kind": "http", "url": "https://store.example/dav/", "user": "player"}}
    run([*here, "--store-setup", "ssh", "made-up-host", "~/store"], capsys, monkeypatch)
    assert StoreProfile.testing(tmp_path / "profile").settings == StoreSettings(SSH, host="made-up-host", path="~/store")
