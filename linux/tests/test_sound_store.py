"""The sound store's decisions (SyncPlan, ported from Tests/SoundStoreTests/SyncPlanTests.swift) and whole syncs
between two simulated devices over a folder place, all in temporary folders with made-up sounds."""
import json
import os

import pytest

pytest.importorskip("cryptography")

from ampbench import age  # noqa: E402
from ampbench.age import AgeIdentity  # noqa: E402
from ampbench.sound_store import (Entry, LocalSound, Manifest, SIZE_LIMIT, SoundStore, SyncPlan,  # noqa: E402
                                  is_safe_path)
from ampbench.store_places import MANIFEST, FolderPlace, StoreError, check_names, is_valid_name  # noqa: E402

EARLY, LATE, NOW = 1_000_000.0, 2_000_000.0, 3_000_000.0


def obj(letter: str) -> str:
    return "objects/" + letter * 64 + ".age"


def sound(letter: str, date: float = EARLY) -> LocalSound:
    return LocalSound(obj(letter), date, 10)


def entry(letter: str, date: float = EARLY, deleted: float | None = None, history: str = "") -> Entry:
    return Entry(obj(letter), date, 10, deleted, [obj(h) for h in history])


def plan(local: dict, remote: dict, base: dict) -> SyncPlan:
    return SyncPlan.make(local, Manifest(id="store", entries=remote), {p: obj(l) for p, l in base.items()}, now=NOW)


# MARK: The plan

def test_nothing_changed():
    p = plan({"a.json": sound("a")}, {"a.json": entry("a")}, {"a.json": "a"})
    assert p.unchanged == 1 and not p.changes_store
    assert not (p.uploads or p.downloads or p.removals or p.marked_deleted)
    assert p.base == {"a.json": obj("a")}
    assert p.manifest.entries == {"a.json": entry("a")}


def test_new_here_is_uploaded():
    p = plan({"a.json": sound("a", LATE)}, {}, {})
    assert p.uploads == ["a.json"]
    assert p.manifest.entries["a.json"] == entry("a", LATE)
    assert p.base == {"a.json": obj("a")}
    assert p.manifest.id == "store"


def test_new_in_the_store_is_downloaded():
    p = plan({}, {"a.json": entry("a")}, {})
    assert p.downloads == ["a.json"] and not p.changes_store
    assert p.base == {"a.json": obj("a")}


def test_changed_only_here_is_uploaded_and_the_old_content_becomes_history():
    # Even with an older date: only this side changed, so there is no conflict to decide by date.
    p = plan({"a.json": sound("b", EARLY)}, {"a.json": entry("a", LATE, history="z")}, {"a.json": "a"})
    assert p.uploads == ["a.json"] and not p.downloads
    assert p.manifest.entries["a.json"] == entry("b", EARLY, history="az")


def test_changed_only_in_the_store_is_downloaded():
    p = plan({"a.json": sound("a", LATE)}, {"a.json": entry("b", EARLY)}, {"a.json": "a"})
    assert p.downloads == ["a.json"] and not p.uploads and not p.preserved
    assert p.manifest.entries["a.json"] == entry("b", EARLY)
    assert p.base == {"a.json": obj("b")}


def test_changed_on_both_sides_to_the_same_content_is_nothing():
    p = plan({"a.json": sound("b", LATE)}, {"a.json": entry("b", EARLY)}, {"a.json": "a"})
    assert p.unchanged == 1 and not p.changes_store and not p.downloads
    assert p.base == {"a.json": obj("b")}


def test_conflict_the_newer_local_wins():
    p = plan({"a.json": sound("b", LATE)}, {"a.json": entry("c", EARLY)}, {"a.json": "a"})
    assert p.uploads == ["a.json"] and not p.downloads
    assert p.manifest.entries["a.json"] == entry("b", LATE, history="c")


def test_conflict_the_newer_remote_wins_and_the_local_loser_is_kept():
    p = plan({"a.json": sound("b", EARLY)}, {"a.json": entry("c", LATE, history="a")}, {"a.json": "a"})
    assert p.downloads == ["a.json"]
    assert p.preserved == ["a.json"], "the losing local content is uploaded before it is replaced"
    assert not p.uploads and p.changes_store
    assert p.manifest.entries["a.json"] == entry("c", LATE, history="ba")
    assert p.base == {"a.json": obj("c")}


def test_a_conflict_with_the_same_date_goes_to_the_store():
    p = plan({"a.json": sound("b", LATE)}, {"a.json": entry("c", LATE)}, {})
    assert p.downloads == ["a.json"] and p.preserved == ["a.json"]


def test_removed_here_and_unchanged_in_the_store_is_marked_deleted():
    p = plan({}, {"a.json": entry("a")}, {"a.json": "a"})
    assert p.marked_deleted == ["a.json"]
    assert p.manifest.entries["a.json"] == entry("a", deleted=NOW), "the object stays, so it can come back"
    assert not p.base and not p.downloads


def test_removed_here_but_changed_in_the_store_comes_back():
    p = plan({}, {"a.json": entry("b", LATE)}, {"a.json": "a"})
    assert p.downloads == ["a.json"] and not p.marked_deleted
    assert p.manifest.entries["a.json"].deleted is None


def test_removed_in_the_store_and_unchanged_here_is_removed_here():
    p = plan({"a.json": sound("a")}, {"a.json": entry("a", deleted=LATE)}, {"a.json": "a"})
    assert p.removals == ["a.json"] and not p.changes_store and not p.base
    assert p.manifest.entries["a.json"] == entry("a", deleted=LATE)


def test_removed_in_the_store_but_changed_here_lives_again():
    p = plan({"a.json": sound("b", LATE)}, {"a.json": entry("a", deleted=LATE)}, {"a.json": "a"})
    assert p.uploads == ["a.json"] and not p.removals
    assert p.manifest.entries["a.json"] == entry("b", LATE, history="a")


def test_removed_on_both_sides_stays_removed():
    p = plan({}, {"a.json": entry("a", deleted=LATE)}, {"a.json": "a"})
    assert not p.changes_store and not (p.removals or p.downloads or p.marked_deleted)
    assert p.manifest.entries["a.json"] == entry("a", deleted=LATE)
    assert not p.base


def test_first_run_is_the_union_and_never_removes():
    p = plan({"mine.json": sound("a"), "both.json": sound("b", LATE), "older.json": sound("c", EARLY),
              "same.json": sound("s"), "gone.json": sound("g")},
             {"theirs.json": entry("d"), "both.json": entry("e", EARLY), "older.json": entry("f", LATE),
              "same.json": entry("s"), "gone.json": entry("g", deleted=LATE), "old.json": entry("o", deleted=LATE)}, {})
    assert p.uploads == ["both.json", "gone.json", "mine.json"]
    assert p.downloads == ["older.json", "theirs.json"]
    assert p.preserved == ["older.json"]
    assert not p.removals, "without a memory of an earlier sync nothing is removed here"
    assert not p.marked_deleted and p.unchanged == 1
    assert p.manifest.entries["both.json"] == entry("b", LATE, history="e")
    assert p.manifest.entries["older.json"] == entry("f", LATE, history="c")
    assert p.manifest.entries["gone.json"].deleted is None
    assert p.manifest.entries["old.json"].deleted is not None
    assert set(p.base) == {"mine.json", "both.json", "older.json", "same.json", "gone.json", "theirs.json"}


def test_the_plan_leaves_what_it_was_given_alone():
    remote = Manifest(id="store", entries={"a.json": entry("a", LATE, history="z")})
    SyncPlan.make({"a.json": sound("b")}, remote, {"a.json": obj("a")}, now=NOW)
    assert remote.entries == {"a.json": entry("a", LATE, history="z")}


def test_history_keeps_the_newest_ten_without_repeats():
    e = entry("a")
    for letter in "bcdefabcdef0123456789":
        e.replace(obj(letter), LATE, 1)
    assert e.object == obj("9")
    assert e.history == [obj(letter) for letter in "876543210f"]
    e.replace(obj("9"), NOW, 1)
    assert len(e.history) == 10, "the same content again is not history"
    e.replace(obj("5"), NOW, 1)
    assert obj("5") not in e.history, "the current content is not its own history"
    assert e.history[0] == obj("9")


def test_only_paths_inside_the_folder_are_safe():
    for path in ["a.json", "Folder/a.json", "a b/ü – ß.json", "a..b.json"]:
        assert is_safe_path(path), path
    for path in ["", "/a.json", "../a.json", "a/../b.json", "a/./b", "a//b", "a/", ".hidden", "a/.hidden", "..", ".",
                 "a\\b", "a\0b"]:
        assert not is_safe_path(path), path


def test_only_the_stores_own_names_pass():
    assert is_valid_name("manifest.age") and is_valid_name(obj("a")) and is_valid_name("objects/" + "0f" * 32 + ".age")
    for name in ["", "manifest", "../manifest.age", "objects/../manifest.age", "objects/abc.age", obj("A"),
                 "objects/" + "a" * 64, "objects/" + "a" * 63 + "/.age", "objects/" + "a" * 62 + "$x.age",
                 "/" + obj("a"), obj("a") + " ", obj("a") + "\n", "other/" + "a" * 64 + ".age"]:
        assert not is_valid_name(name), name
    with pytest.raises(StoreError):
        check_names(["manifest.age", "../escape.age"])


# MARK: The index as the Mac writes it

def test_the_index_is_the_json_the_mac_writes():
    # Byte for byte what JSONEncoder gives with sorted keys and ISO 8601 dates: no blanks, "\/", whole seconds
    # (cut off, not rounded), no "deleted" while the sound lives.
    manifest = Manifest(id="969BC737-EBAB-45F6-BF2F-3D43E5FFF6B0", entries={
        "Kemper/Jä z.json": Entry("objects/aa.age", 1_000_000.999, 3),
        "Gone.json": Entry("objects/bb.age", -0.5, 0, deleted=1_700_000_000.9996, history=["objects/cc.age"])})
    assert manifest.encode().decode("utf-8") == (
        '{"entries":{"Gone.json":{"deleted":"2023-11-14T22:13:20Z","history":["objects\\/cc.age"],'
        '"modified":"1969-12-31T23:59:59Z","object":"objects\\/bb.age","size":0},'
        '"Kemper\\/Jä z.json":{"history":[],"modified":"1970-01-12T13:46:40Z","object":"objects\\/aa.age","size":3}},'
        '"id":"969BC737-EBAB-45F6-BF2F-3D43E5FFF6B0","version":1}')
    again = Manifest.decode(manifest.encode())
    assert again.id == manifest.id and again.entries["Kemper/Jä z.json"] == Entry("objects/aa.age", 1_000_000.0, 3)
    assert again.entries["Gone.json"].deleted == 1_700_000_000.0
    made = Manifest().id
    assert len(made) == 36 and made == made.upper() and made != Manifest().id, "a UUID as the Mac writes it"


def test_the_index_reads_what_other_versions_may_write():
    text = ('{"version":1,"entries":{"a.json":{"object":"objects/x.age","modified":"2026-11-14T13:00:00+01:00",'
            '"size":2,"unknown":true}},"more":1}')
    manifest = Manifest.decode(text.encode())
    assert manifest.id == "" and manifest.entries["a.json"].history == []
    assert manifest.entries["a.json"].modified == Manifest.decode(
        text.replace("13:00:00+01:00", "12:00:00Z").encode()).entries["a.json"].modified
    for broken in ['', '[]', '{"entries":{}}', '{"version":"1","entries":{}}', '{"version":1}',
                   '{"version":1,"entries":{"a":{"object":"o","modified":"yesterday","size":1}}}',
                   '{"version":1,"entries":{"a":{"object":"o","modified":"2026-11-14T12:00:00","size":1}}}',
                   '{"version":1,"entries":{"a":{"object":"o","modified":"2026-11-14T12:00:00Z","size":"1"}}}',
                   '{"version":1,"entries":{"a":{"modified":"2026-11-14T12:00:00Z","size":1}}}',
                   '{"version":1,"entries":{"a":{"object":"o","modified":"2026-11-14T12:00:00Z","size":1,"history":[1]}}}']:
        with pytest.raises(ValueError):
            Manifest.decode(broken.encode())
    # A newer format is not read at all, only its number.
    assert Manifest.decode(b'{"version":2,"entries":"something else"}').version == 2


# MARK: Two devices and one store

class Devices:
    def __init__(self, root):
        self.root = root
        self.store_folder = root / "Store"
        self.identity = AgeIdentity.generate()

    def folder(self, device: str):
        return self.root / device / "Presets"

    def state(self, device: str):
        return self.root / device / "state.json"

    def device(self, name: str, identity=None, place=None, remove=None) -> SoundStore:
        arguments = [self.folder(name), place or FolderPlace(self.store_folder), identity or self.identity,
                     self.state(name)]
        return SoundStore(*arguments, remove) if remove else SoundStore(*arguments)

    def write(self, text: str, path: str, on: str, modified: float | None = None) -> None:
        file = self.folder(on) / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(text.encode("utf-8"))
        if modified is not None:
            os.utime(file, (modified, modified))

    def sounds(self, on: str) -> dict[str, str]:
        return {path: data.decode("utf-8") for path, data in all_files(self.folder(on)).items()}

    def stored(self) -> dict[str, bytes]:
        return all_files(self.store_folder)

    def manifest(self) -> Manifest:
        return Manifest.decode(age.decrypt(self.stored()[MANIFEST], self.identity))


def all_files(folder) -> dict[str, bytes]:
    return {str(path.relative_to(folder)).replace(os.sep, "/"): path.read_bytes()
            for path in folder.rglob("*") if path.is_file()} if folder.exists() else {}


class MemoryPlace:
    """A place in memory that counts what goes through it."""

    def __init__(self):
        self.files: dict[str, bytes] = {}
        self.writes: list[list[str]] = []

    def read(self, names):
        check_names(names)
        return {name: data for name, data in self.files.items() if name in names}

    def write(self, files):
        check_names(files)
        self.files.update(files)
        self.writes.append(sorted(files))


@pytest.fixture
def devices(tmp_path):
    return Devices(tmp_path)


def test_round_trip_from_one_device_to_the_other(devices):
    devices.write('{"name":"Made-up Lead"}', "Lead.json", on="Mac")
    devices.write('{"name":"Made-up Jazz"}', "Kemper/Jazz.json", on="Mac")
    first = devices.device("Mac").sync()
    assert first.uploaded == ["Kemper/Jazz.json", "Lead.json"]
    assert first.summary == "Store: 2 stored."
    assert devices.device("Mac").status() == (2, 0)

    fetched = devices.device("Laptop").sync()
    assert fetched.downloaded == ["Kemper/Jazz.json", "Lead.json"]
    assert fetched.summary == "Store: 2 fetched."
    assert devices.sounds("Laptop") == {"Lead.json": '{"name":"Made-up Lead"}', "Kemper/Jazz.json": '{"name":"Made-up Jazz"}'}

    before = devices.stored()
    for name in ["Mac", "Laptop", "Mac"]:
        again = devices.device(name).sync()
        assert again.is_empty and again.unchanged == 2, name
        assert again.summary == "The store is up to date: 2 sounds."
    assert devices.stored() == before, "a sync without changes writes nothing, not even the index"


def test_the_store_holds_only_ciphertext_under_names_that_say_nothing(devices):
    devices.write("the same made-up sound", "One.json", on="Mac")
    devices.write("the same made-up sound", "Two.json", on="Mac")
    devices.device("Mac").sync()
    stored = devices.stored()
    assert len(stored) == 2, "the manifest and one object: the same content is stored once"
    assert all(is_valid_name(name) for name in stored)
    for name, data in stored.items():
        assert data.startswith(b"age-encryption.org/v1\n"), name
        for plain in ["the same made-up sound", "One.json", "Two.json", devices.identity.text]:
            assert plain.encode() not in data, f"{plain} is readable in {name}"
    assert json.loads(devices.state("Mac").read_text())["store"] == devices.manifest().id
    assert devices.identity.text not in devices.state("Mac").read_text()


def test_object_names_come_from_the_key_and_the_content(devices):
    import hashlib
    import hmac
    store = devices.device("Mac")
    # As Sources/SoundStore/SoundStore.swift derives them: HMAC-SHA256 of the content under
    # SHA256("AmpBench store object" + the key's 32 bytes), in lower-case hex.
    key = hashlib.sha256(b"AmpBench store object" + devices.identity.secret).digest()
    assert store.object_name(b"first") == "objects/" + hmac.new(key, b"first", hashlib.sha256).hexdigest() + ".age"
    assert store.object_name(b"first") != store.object_name(b"second")
    assert devices.device("Mac", identity=AgeIdentity.generate()).object_name(b"first") != store.object_name(b"first")
    devices.write("first", "Lead.json", on="Mac", modified=1_700_000_000.75)
    store.sync()
    index = devices.manifest()
    assert index.entries["Lead.json"] == Entry(store.object_name(b"first"), 1_700_000_000.0, 5)
    assert json.loads(devices.state("Mac").read_text()) == {"store": index.id, "objects": {"Lead.json": store.object_name(b"first")}}


def test_an_edit_travels_and_the_old_content_stays_in_the_store(devices):
    devices.write("first", "Lead.json", on="Mac")
    devices.device("Mac").sync()
    devices.device("Laptop").sync()
    before = len(devices.stored())
    devices.write("second", "Lead.json", on="Laptop")
    assert devices.device("Laptop").sync().uploaded == ["Lead.json"]
    assert devices.device("Mac").sync().downloaded == ["Lead.json"]
    assert devices.sounds("Mac") == {"Lead.json": "second"}
    assert len(devices.stored()) == before + 1, "the first content is still an object in the store"
    entry = devices.manifest().entries["Lead.json"]
    assert entry.history == [devices.device("Mac").object_name(b"first")]


def test_a_conflict_keeps_the_newer_and_stores_the_other(devices):
    devices.write("first", "Lead.json", on="Mac")
    devices.device("Mac").sync()
    devices.device("Laptop").sync()
    devices.write("from the Mac, older", "Lead.json", on="Mac", modified=1_700_000_000)
    devices.write("from the laptop, newer", "Lead.json", on="Laptop", modified=1_700_000_500)
    devices.device("Laptop").sync()
    report = devices.device("Mac").sync()
    assert report.downloaded == ["Lead.json"]
    assert devices.sounds("Mac") == {"Lead.json": "from the laptop, newer"}

    objects = {name: data for name, data in devices.stored().items() if name != MANIFEST}
    assert len(objects) == 3
    assert sorted(age.decrypt(data, devices.identity).decode() for data in objects.values()) == [
        "first", "from the Mac, older", "from the laptop, newer"]
    assert devices.device("Laptop").sync().is_empty
    assert devices.sounds("Laptop") == {"Lead.json": "from the laptop, newer"}


def test_removing_travels_through_the_given_removal(devices, tmp_path):
    devices.write("first", "Lead.json", on="Mac")
    devices.write("stays", "Jazz.json", on="Mac")
    devices.device("Mac").sync()
    devices.device("Laptop").sync()
    stored = len(devices.stored())
    (devices.folder("Mac") / "Lead.json").unlink()
    removed = devices.device("Mac").sync()
    assert removed.marked_deleted == ["Lead.json"]
    assert removed.summary == "Store: 1 removed in the store."
    assert devices.device("Mac").status() == (1, 1)
    assert len(devices.stored()) == stored, "nothing is ever deleted in the store"

    trash = tmp_path / "Trash"
    trash.mkdir()
    report = devices.device("Laptop", remove=lambda path: path.rename(trash / path.name)).sync()
    assert report.removed_locally == ["Lead.json"]
    assert devices.sounds("Laptop") == {"Jazz.json": "stays"}
    assert sorted(all_files(trash)) == ["Lead.json"]
    assert devices.device("Mac").sync().is_empty
    assert devices.sounds("Mac") == {"Jazz.json": "stays"}


def test_a_removed_sound_comes_back_when_it_is_put_back(devices):
    devices.write("first", "Lead.json", on="Mac")
    devices.device("Mac").sync()
    devices.device("Laptop").sync()
    (devices.folder("Mac") / "Lead.json").unlink()
    devices.device("Mac").sync()
    devices.device("Laptop").sync()
    assert devices.sounds("Laptop") == {}
    devices.write("first", "Lead.json", on="Mac")
    assert devices.device("Mac").sync().uploaded == ["Lead.json"]
    assert devices.device("Laptop").sync().downloaded == ["Lead.json"]
    assert devices.sounds("Laptop") == {"Lead.json": "first"}
    assert devices.device("Mac").status() == (1, 0)


def test_an_edit_beats_a_removal_elsewhere(devices):
    devices.write("first", "Lead.json", on="Mac")
    devices.device("Mac").sync()
    devices.device("Laptop").sync()
    (devices.folder("Mac") / "Lead.json").unlink()
    devices.device("Mac").sync()
    devices.write("edited meanwhile", "Lead.json", on="Laptop")
    assert devices.device("Laptop").sync().uploaded == ["Lead.json"]
    devices.device("Mac").sync()
    assert devices.sounds("Mac") == {"Lead.json": "edited meanwhile"}


def test_a_wrong_key_changes_nothing_anywhere(devices):
    devices.write("first", "Lead.json", on="Mac")
    devices.device("Mac").sync()
    before = devices.stored()
    devices.write("mine", "Other.json", on="Laptop")
    stranger = devices.device("Laptop", identity=AgeIdentity.generate())
    for action in (stranger.sync, stranger.status, stranger.verify):
        with pytest.raises(StoreError) as caught:
            action()
        assert caught.value == StoreError(StoreError.WRONG_KEY)
        assert str(caught.value).startswith("This key does not open the store")
    assert devices.stored() == before
    assert devices.sounds("Laptop") == {"Other.json": "mine"}
    assert not devices.state("Laptop").exists()


def test_a_tampered_object_ends_the_sync_before_any_local_change(devices):
    devices.write("a", "A.json", on="Mac")
    devices.write("b", "B.json", on="Mac")
    devices.device("Mac").sync()
    name = devices.manifest().entries["B.json"].object
    damaged = bytearray((devices.store_folder / name).read_bytes())
    damaged[-1] ^= 1
    (devices.store_folder / name).write_bytes(bytes(damaged))
    before = devices.stored()
    devices.write("mine", "Lead.json", on="Laptop")
    with pytest.raises(StoreError) as caught:
        devices.device("Laptop").sync()
    assert caught.value == StoreError(StoreError.DAMAGED_OBJECT, "B.json")
    assert devices.sounds("Laptop") == {"Lead.json": "mine"}, "not even the intact sound was written"
    assert devices.stored() == before, "and nothing was uploaded"


def test_an_object_swapped_for_another_is_noticed(devices):
    devices.write("a", "A.json", on="Mac")
    devices.write("b", "B.json", on="Mac")
    devices.device("Mac").sync()
    entries = devices.manifest().entries
    (devices.store_folder / entries["A.json"].object).write_bytes((devices.store_folder / entries["B.json"].object).read_bytes())
    with pytest.raises(StoreError) as caught:
        devices.device("Laptop").sync()
    assert caught.value == StoreError(StoreError.DAMAGED_OBJECT, "A.json")
    assert devices.sounds("Laptop") == {}


def test_a_missing_object_ends_the_sync(devices):
    devices.write("a", "A.json", on="Mac")
    devices.device("Mac").sync()
    (devices.store_folder / devices.manifest().entries["A.json"].object).unlink()
    with pytest.raises(StoreError) as caught:
        devices.device("Laptop").sync()
    assert caught.value == StoreError(StoreError.MISSING_OBJECT, "A.json")
    assert "A.json" in str(caught.value)


def seal(devices, place, text: str) -> None:
    place.files[MANIFEST] = age.encrypt(text.encode(), devices.identity.recipient)


def test_an_index_that_points_outside_the_folder_is_refused(devices):
    place = MemoryPlace()
    for path in ["../escaped.json", "/tmp/escaped.json", "a/../../escaped.json", ".hidden.json", "a\\\\b"]:
        seal(devices, place, '{"version":1,"id":"x","entries":{"%s":{"object":"%s","modified":"2026-11-14T12:00:00Z",'
                             '"size":1,"history":[]}}}' % (path, obj("a")))
        with pytest.raises(StoreError) as caught:
            devices.device("Laptop", place=place).sync()
        assert caught.value == StoreError(StoreError.UNSAFE_PATH), path
    assert not (devices.root / "Laptop" / "escaped.json").exists()
    assert devices.sounds("Laptop") == {} and not place.writes


def test_an_index_with_foreign_object_names_is_refused(devices):
    place = MemoryPlace()
    for name, history in [("manifest.age", "[]"), ("objects/../x.age", "[]"), (obj("a"), '["../x"]')]:
        seal(devices, place, '{"version":1,"id":"x","entries":{"a.json":{"object":"%s","modified":'
                             '"2026-11-14T12:00:00Z","size":1,"history":%s}}}' % (name, history))
        with pytest.raises(StoreError) as caught:
            devices.device("Laptop", place=place).sync()
        assert caught.value == StoreError(StoreError.DAMAGED_MANIFEST), name


def test_a_newer_format_is_refused_and_left_alone(devices):
    place = MemoryPlace()
    seal(devices, place, '{"version":2,"id":"x","entries":{"a.json":{"something":"new"}}}')
    before = dict(place.files)
    devices.write("mine", "Lead.json", on="Laptop")
    with pytest.raises(StoreError) as caught:
        devices.device("Laptop", place=place).sync()
    assert caught.value == StoreError(StoreError.NEWER_MANIFEST, 2)
    assert place.files == before and not place.writes
    seal(devices, place, "not an index")
    with pytest.raises(StoreError) as caught:
        devices.device("Laptop", place=place).sync()
    assert caught.value == StoreError(StoreError.DAMAGED_MANIFEST)
    place.files[MANIFEST] = b"not even an age file"
    with pytest.raises(StoreError) as caught:
        devices.device("Laptop", place=place).sync()
    assert caught.value == StoreError(StoreError.DAMAGED_MANIFEST)


def test_objects_are_written_before_the_index_and_only_when_needed(devices):
    place = MemoryPlace()
    devices.write("first", "Lead.json", on="Mac")
    devices.device("Mac", place=place).sync()
    assert len(place.writes) == 2
    assert all(name.startswith("objects/") for name in place.writes[0])
    assert place.writes[1] == [MANIFEST]
    devices.device("Mac", place=place).sync()
    assert len(place.writes) == 2, "a sync without changes writes nothing"
    devices.device("Laptop", place=place).sync()
    assert len(place.writes) == 2, "fetching writes nothing to the store"


def test_another_store_does_not_inherit_the_memory_of_the_first(devices):
    first, second = MemoryPlace(), MemoryPlace()
    devices.write("first", "Lead.json", on="Mac", modified=1_700_000_000)
    devices.device("Mac", place=first).sync()
    devices.write("the other device's version", "Lead.json", on="Laptop", modified=1_600_000_000)
    devices.write("only there", "Extra.json", on="Laptop")
    devices.device("Laptop", place=second).sync()
    devices.write("the Mac's version", "Lead.json", on="Mac", modified=1_700_000_500)
    report = devices.device("Mac", place=second).sync()
    assert report.uploaded == ["Lead.json"], "a first run with this store: the newer wins"
    assert report.downloaded == ["Extra.json"]
    assert devices.sounds("Mac") == {"Lead.json": "the Mac's version", "Extra.json": "only there"}


def test_an_emptied_store_is_filled_again_and_nothing_is_removed_here(devices):
    place = MemoryPlace()
    devices.write("first", "Lead.json", on="Mac")
    devices.device("Mac", place=place).sync()
    place.files.clear()
    assert devices.device("Mac", place=place).sync().uploaded == ["Lead.json"]
    assert devices.sounds("Mac") == {"Lead.json": "first"}


def test_links_hidden_and_large_files_are_left_alone(devices, tmp_path):
    devices.write("first", "Lead.json", on="Mac")
    devices.write("hidden", ".hidden.json", on="Mac")
    devices.write("hidden", ".folder/inside.json", on="Mac")
    outside = tmp_path / "outside.json"
    outside.write_text("outside the folder")
    (devices.folder("Mac") / "link.json").symlink_to(outside)
    (devices.folder("Mac") / "linked").symlink_to(tmp_path, target_is_directory=True)
    large = devices.folder("Mac") / "Recording.wav"
    with open(large, "wb") as handle:
        handle.truncate(SIZE_LIMIT + 1)
    assert devices.device("Mac").sync().uploaded == ["Lead.json"]
    devices.device("Laptop").sync()
    assert devices.sounds("Laptop") == {"Lead.json": "first"}

    # A file that grows past the limit after it was stored is neither changed nor removed for the store.
    devices.write("small", "Grows.json", on="Mac")
    devices.device("Mac").sync()
    with open(devices.folder("Mac") / "Grows.json", "wb") as handle:
        handle.truncate(SIZE_LIMIT + 1)
    assert devices.device("Mac").sync().is_empty
    assert devices.device("Mac").status() == (2, 0)
    assert large.exists()


def test_a_fetched_sound_carries_the_stores_date(devices):
    devices.write("first", "Lead.json", on="Mac", modified=1_700_000_000.6)
    devices.device("Mac").sync()
    devices.device("Laptop").sync()
    assert (devices.folder("Laptop") / "Lead.json").stat().st_mtime_ns == 1_700_000_000 * 10**9


def test_a_missing_folder_is_an_empty_one(devices):
    report = devices.device("Nobody").sync()
    assert report.is_empty and report.summary == "The store is up to date: 0 sounds."
    assert set(devices.stored()) == {MANIFEST}, "the first sync makes the store, with its id"


# MARK: Reading back

def test_a_store_that_was_just_synced_reads_back_whole(devices):
    devices.write("lead", "Lead.json", on="Mac")
    devices.write("jazz", "Kemper/Jazz.json", on="Mac")
    devices.device("Mac").sync()
    report = devices.device("Mac").verify()
    assert report.readable == 2 and report.is_in_step
    assert report.summary == "Checked: all 2 sounds in the store can be read and equal the ones here."
    other = devices.device("Laptop").verify()
    assert other.is_restorable and other.not_here == ["Kemper/Jazz.json", "Lead.json"]
    assert other.summary == ("Checked: all 2 sounds in the store can be read. 2 differ from this device; a sync "
                             "brings them in step.")


def test_reading_back_finds_what_a_sync_would_not_notice(devices):
    for name in ["A", "B", "C"]:
        devices.write(name.lower(), f"{name}.json", on="Mac")
    devices.device("Mac").sync()
    entries = devices.manifest().entries
    (devices.store_folder / entries["A.json"].object).write_bytes(b"not an age file")
    (devices.store_folder / entries["B.json"].object).unlink()
    before, stored = devices.sounds("Mac"), devices.stored()
    report = devices.device("Mac").verify()
    assert not report.is_restorable and report.readable == 1
    assert report.damaged == ["A.json"] and report.missing == ["B.json"]
    assert report.summary == "The store is damaged: 2 of its sounds cannot be restored."
    assert devices.sounds("Mac") == before and devices.stored() == stored, "reading back must change nothing"
    assert devices.device("Mac").sync().is_empty, "a sync does not look at what it has no reason to fetch"

    devices.write("new", "New.json", on="Mac")
    devices.write("c, changed", "C.json", on="Mac")
    later = devices.device("Mac").verify()
    assert later.not_stored == ["New.json"] and later.differing == ["C.json"]


# MARK: One name, two spellings

COMPOSED, DECOMPOSED = "Jäzz – ß.json", "Jäzz – ß.json"


def test_a_name_the_mac_spells_its_way_is_the_same_sound_here(devices):
    # The Mac's files carry "ä" as "a" with two dots, and so does the index it writes; Swift takes both for one path.
    devices.write("jazz", DECOMPOSED, on="Mac")
    devices.write("lead", "Lead.json", on="Mac")
    devices.device("Mac").sync()
    assert set(devices.manifest().entries) == {DECOMPOSED, "Lead.json"}

    # A device that has the sound already, under the name as Linux writes it: nothing to do, and no second entry.
    devices.write("jazz", COMPOSED, on="Laptop")
    report = devices.device("Laptop").sync()
    assert report.downloaded == ["Lead.json"] and not report.uploaded and report.unchanged == 1
    assert set(devices.sounds("Laptop")) == {COMPOSED, "Lead.json"}
    assert set(devices.manifest().entries) == {DECOMPOSED, "Lead.json"}
    assert devices.device("Laptop").sync().is_empty and devices.device("Mac").sync().is_empty
    assert devices.device("Laptop").verify().is_in_step

    # An edit here travels under the index's spelling, and the file keeps its name.
    devices.write("jazz, edited", COMPOSED, on="Laptop")
    assert devices.device("Laptop").sync().uploaded == [DECOMPOSED]
    assert set(devices.manifest().entries) == {DECOMPOSED, "Lead.json"}
    assert devices.device("Mac").sync().downloaded == [DECOMPOSED]
    assert devices.sounds("Mac") == {DECOMPOSED: "jazz, edited", "Lead.json": "lead"}

    # An edit and then a removal elsewhere reach the file here.
    devices.write("jazz, edited on the Mac", DECOMPOSED, on="Mac")
    devices.device("Mac").sync()
    assert devices.device("Laptop").sync().downloaded == [DECOMPOSED]
    assert devices.sounds("Laptop") == {COMPOSED: "jazz, edited on the Mac", "Lead.json": "lead"}
    (devices.folder("Mac") / DECOMPOSED).unlink()
    devices.device("Mac").sync()
    assert devices.device("Laptop").sync().removed_locally == [DECOMPOSED]
    assert devices.sounds("Laptop") == {"Lead.json": "lead"}


def test_a_fetched_sound_gets_the_composed_name(devices):
    devices.write("jazz", "Kemper/" + DECOMPOSED, on="Mac")
    devices.device("Mac").sync()
    devices.device("Laptop").sync()
    assert devices.sounds("Laptop") == {"Kemper/" + COMPOSED: "jazz"}
    assert devices.device("Laptop").sync().is_empty and devices.device("Laptop").verify().is_in_step
    (devices.folder("Laptop") / "Kemper" / COMPOSED).unlink()
    assert devices.device("Laptop").sync().marked_deleted == ["Kemper/" + DECOMPOSED]
    assert devices.device("Laptop").verify().is_in_step


def test_an_index_with_one_path_in_two_spellings_is_left_as_it_is(devices):
    place = MemoryPlace()
    store = devices.device("Laptop", place=place)
    place.files[store.object_name(b"jazz")] = age.encrypt(b"jazz", devices.identity.recipient)
    item = '{"object":"%s","modified":"2026-11-14T12:00:00Z","size":4,"history":[]%s}'
    seal(devices, place, '{"version":1,"id":"x","entries":{"%s":%s,"%s":%s}}' % (
        COMPOSED, item % (store.object_name(b"jazz"), ',"deleted":"2026-11-14T13:00:00Z"'),
        DECOMPOSED, item % (store.object_name(b"jazz"), "")))
    assert store.sync().downloaded == [DECOMPOSED], "the living one counts"
    assert devices.sounds("Laptop") == {COMPOSED: "jazz"} and not place.writes
    devices.write("jazz, edited", COMPOSED, on="Laptop")
    assert store.sync().uploaded == [DECOMPOSED]
    index = Manifest.decode(age.decrypt(place.files[MANIFEST], devices.identity))
    assert set(index.entries) == {COMPOSED, DECOMPOSED} and index.entries[COMPOSED].deleted is not None
