import time
from datetime import datetime, timedelta, timezone

import pytest

from ampbench import factory, protocol, store, wav
from ampbench.store import LibraryStore


def make_store(tmp_path):
    lib = LibraryStore(tmp_path / "lib")
    lib.load()
    return lib


def add(lib, name, **fields):
    path = lib.folder / f"{name}.wav"
    path.write_bytes(b"x" * 10)
    take = {"id": store.new_id(), "fileName": f"{name}.wav", "createdAt": store.iso(datetime.now(timezone.utc)),
            "duration": 10.0, "status": "kept", "rating": 0, "favorite": False, "tags": [], "note": "", "markers": []}
    take.update(fields)
    lib.document["recordings"].append(take)
    return take


def test_query_filters_and_search(tmp_path):
    lib = make_store(tmp_path)
    a = add(lib, "Blues in A", rating=4, tags=["Blues"], favorite=True)
    b = add(lib, "Tonleiter", rating=2, status="open", note="langsam üben")
    c = add(lib, "Solo", rating=5, pieceID="P1")
    rows = lib.document["recordings"]
    assert [t["fileName"] for t in store.query(rows, min_rating=4)] == ["Blues in A.wav", "Solo.wav"]
    assert store.query(rows, favorites=True) == [a]
    assert store.query(rows, status="open") == [b]
    assert store.query(rows, piece_id=None) == [a, b]
    assert store.query(rows, piece_id="P1") == [c]
    assert store.query(rows, tag="blues") == [a]
    assert store.query(rows, text="ÜBEN") == [b], "search covers the note, case-insensitively"
    assert store.query(rows, text="blues") == [a]
    assert store.query(rows, text="stück x", piece_names={"P1": "Stück X"}) == [c], "search covers the piece name"
    assert store.all_tags(rows) == ["Blues"]
    assert store.parse_tags(" Blues, blues ,, Jazz ") == ["Blues", "Jazz"]


def test_rename_renames_the_file_and_never_overwrites(tmp_path):
    lib = make_store(tmp_path)
    a = add(lib, "eins")
    add(lib, "zwei")
    store.rename_recording(lib, a["id"], "Neuer Name")
    assert a["fileName"] == "Neuer Name.wav" and (lib.folder / "Neuer Name.wav").exists()
    with pytest.raises(store.StoreError):
        store.rename_recording(lib, a["id"], "zwei")
    with pytest.raises(store.StoreError):
        store.rename_recording(lib, a["id"], "...")
    store.rename_recording(lib, a["id"], "a/b: c")
    assert a["fileName"] == "a-b- c.wav"


def test_pieces_and_practice_time(tmp_path):
    lib = make_store(tmp_path)
    piece = store.add_piece(lib, " Blues in A ")
    take = add(lib, "t", pieceID=piece["id"])
    lib.log_practice(datetime.now(timezone.utc), 120, piece["id"])
    lib.log_practice(datetime.now(timezone.utc) - timedelta(days=40), 600, piece["id"])
    lib.log_practice(datetime.now(timezone.utc), 30, None)
    assert piece["name"] == "Blues in A"
    assert store.practice_seconds(lib, piece["id"]) == 720
    assert store.practice_seconds(lib, since=datetime.now(timezone.utc) - timedelta(days=30)) == 150
    days = store.practice_by_day(lib, 30)
    assert len(days) == 30 and days[-1][1] == pytest.approx(2.5) and sum(m for _, m in days) == pytest.approx(2.5)
    removed = store.remove_piece(lib, piece["id"])
    assert "pieceID" not in take and store.piece(lib, piece["id"]) is None
    store.restore_piece(lib, removed)
    assert take["pieceID"] == piece["id"] and store.piece(lib, piece["id"])


def test_snapshot_of_a_take_sound_roundtrips(tmp_path):
    lib = make_store(tmp_path)
    preset = factory.templates()[1].preset
    store.write_snapshot(lib, "T1", preset, "Platz 2 · Spark MINI")
    back = store.read_snapshot(lib, "T1")
    assert protocol.fingerprint(back) == protocol.fingerprint(preset)
    assert store.read_snapshot(lib, "nope") is None


def test_a_take_is_stamped_with_the_sound_that_was_playing(tmp_path):
    from ampbench.demo_input import demo_devices, demo_engine
    from ampbench.recorder import RecorderModel
    recorder = RecorderModel(LibraryStore(tmp_path / "lib"), demo_engine(), demo_devices)
    recorder.start_library()
    recorder.refresh_devices()
    preset = factory.templates()[2].preset
    recorder.sound_provider = lambda: (preset, 2, "Platz 3 · Spark MINI")
    piece = store.add_piece(recorder.store, "Solo üben")
    recorder.current_piece_id = piece["id"]
    recorder.start()
    time.sleep(0.5)
    recorder.stop()
    take = recorder.store.document["recordings"][0]
    assert take["preset"]["slot"] == 3 and take["preset"]["name"] == preset.name
    assert take["preset"]["sha256"] == protocol.fingerprint(preset)
    assert take["pieceID"] == piece["id"]
    assert protocol.fingerprint(store.read_snapshot(recorder.store, take["id"])) == take["preset"]["sha256"]


def test_a_failing_sound_provider_never_stops_a_recording(tmp_path):
    from ampbench.demo_input import demo_devices, demo_engine
    from ampbench.recorder import RecorderModel
    recorder = RecorderModel(LibraryStore(tmp_path / "lib"), demo_engine(), demo_devices)
    recorder.start_library()
    recorder.refresh_devices()

    def broken():
        raise RuntimeError("bluetooth")
    recorder.sound_provider = broken
    recorder.start()
    assert recorder.is_recording
    time.sleep(0.3)
    recorder.stop()
    assert "preset" not in recorder.store.document["recordings"][0]
