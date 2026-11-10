import json
import os
import struct
import time
from datetime import datetime, timezone

import pytest

from ampbench import capture, store, wav
from ampbench.demo_input import demo_devices, demo_engine

FMT = wav.Format(48000, 2, 24)


def test_writer_finalizes_the_header(tmp_path):
    path = tmp_path / "a.wav"
    writer = wav.WAVWriter(path, FMT)
    writer.write(bytes(6 * 480))
    assert writer.close() == 480
    state, fmt, frames = wav.inspect(path)
    assert (state, fmt, frames) == ("ok", FMT, 480)
    assert path.stat().st_size == 44 + 6 * 480


def test_a_crashed_file_is_repaired_without_touching_the_audio(tmp_path):
    path = tmp_path / "crash.wav"
    writer = wav.WAVWriter(path, FMT)
    audio = bytes(range(256)) * 12  # 3072 bytes = 512 frames
    writer.write(audio)
    writer.flush()
    with open(path, "ab") as handle:  # a torn last frame
        handle.write(b"\x01\x02")
    state, _, frames = wav.inspect(path)
    assert state == "needs_repair" and frames == 512
    assert wav.repair(path, treat_trailing_data_as_audio=True) == 512
    assert wav.inspect(path)[0] == "ok"
    assert path.read_bytes()[44:] == audio


def test_empty_and_foreign_files(tmp_path):
    path = tmp_path / "empty.wav"
    wav.WAVWriter(path, FMT).file.close()
    assert wav.inspect(path)[0] == "empty"
    (tmp_path / "x.wav").write_bytes(b"not a wav file at all")
    assert wav.inspect(tmp_path / "x.wav")[0] == "unreadable"


def test_24_bit_conversion_keeps_the_top_three_bytes():
    sample = struct.pack("<i", 0x12345678)
    assert capture._to_24_bit(sample) == bytes([0x56, 0x34, 0x12])


def test_store_roundtrip_keeps_fields_it_does_not_know(tmp_path):
    lib = store.LibraryStore(tmp_path)
    lib.load()
    lib.document["recordings"].append({"id": "X", "fileName": "a.wav", "grid": {"bpm": 90}, "preset": {"slot": 2}})
    lib.document["pieces"].append({"id": "P", "name": "Blues", "parts": [{"name": "Solo"}]})
    lib.save()
    again = store.LibraryStore(tmp_path)
    again.load()
    assert again.document["recordings"][0]["grid"] == {"bpm": 90}
    assert again.document["pieces"][0]["parts"] == [{"name": "Solo"}]
    lib.save()
    assert (tmp_path / "Library.backup.json").exists()


def test_the_document_reads_like_the_macs(tmp_path):
    lib = store.LibraryStore(tmp_path)
    lib.load()
    lib.save()
    text = (tmp_path / "Library.json").read_text()
    assert '"schemaVersion" : 2' in text


def test_an_unreadable_library_is_kept_and_the_backup_used(tmp_path):
    lib = store.LibraryStore(tmp_path)
    lib.load()
    lib.document["practiceLog"].append({"id": "1", "date": "2026-11-01T10:00:00Z", "seconds": 5})
    lib.save()
    lib.save()
    (tmp_path / "Library.json").write_text("{ kaputt")
    other = store.LibraryStore(tmp_path)
    assert other.load() == "restored"
    assert any(p.name.startswith("Library.damaged-") for p in tmp_path.iterdir())


def test_a_newer_schema_is_never_overwritten(tmp_path):
    original = json.dumps({"schemaVersion": 9, "recordings": []})
    (tmp_path / "Library.json").write_text(original)
    lib = store.LibraryStore(tmp_path)
    with pytest.raises(store.StoreError):
        lib.load()
    assert (tmp_path / "Library.json").read_text() == original


def test_recovery_after_a_crash_adds_the_take(tmp_path):
    lib = store.LibraryStore(tmp_path)
    lib.load()
    started = datetime.now(timezone.utc)
    writer = wav.WAVWriter(tmp_path / "Aufnahme_x.wav", FMT)
    writer.write(bytes(6 * 4800))
    writer.flush()
    lib.write_journal({"fileName": "Aufnahme_x.wav", "startedAt": store.iso(started), "takeID": "T1",
                       "source": {"deviceName": "Spark", "bits": 16, "sampleRate": 48000, "channels": 2}, "markers": []})
    fresh = store.LibraryStore(tmp_path)
    fresh.load()
    outcome = fresh.recover_interrupted()
    assert outcome.kind == "repaired" and outcome.seconds == pytest.approx(0.1)
    take = fresh.document["recordings"][0]
    assert take["id"] == "T1" and take["recoveredAfterInterruption"] is True and take["status"] == "open"
    assert not fresh.journal_path.exists()


def test_recovery_trashes_an_empty_file(tmp_path):
    trashed = []
    lib = store.LibraryStore(tmp_path, trash=trashed.append)
    lib.load()
    wav.WAVWriter(tmp_path / "leer.wav", FMT).file.close()
    lib.write_journal({"fileName": "leer.wav", "startedAt": store.iso(datetime.now(timezone.utc)), "takeID": "T"})
    assert lib.recover_interrupted().kind == "empty"
    assert trashed and not lib.recording("T")


def test_only_one_instance_uses_a_library(tmp_path):
    first, second = store.LibraryStore(tmp_path), store.LibraryStore(tmp_path)
    assert first.acquire_lock() and not second.acquire_lock()


def test_unique_names_and_auto_level(tmp_path):
    lib = store.LibraryStore(tmp_path)
    (tmp_path / "Aufnahme.wav").write_bytes(b"x")
    assert lib.unique_name("Aufnahme").name == "Aufnahme 2.wav"
    assert store.auto_level_gain(-10.0) == 9.0 and store.auto_level_gain(-0.5) == 0.0 and store.auto_level_gain(-80) == 30.0


def test_demo_engine_records_a_real_take(tmp_path):
    engine = demo_engine()
    device = demo_devices()[0]
    engine.open(device)
    time.sleep(0.4)
    assert engine.meter.level > 0.05, "the meter moves while the input is only checked"
    path = tmp_path / "t.wav"
    engine.start_recording(path)
    time.sleep(1.0)
    result = engine.stop_recording()
    engine.close()
    assert result.finalized and 0.7 < result.seconds < 1.6
    state, fmt, frames = wav.inspect(path)
    assert state == "ok" and fmt == wav.Format(48000, 2, 24) and frames == result.frames
    assert 0.3 < result.peak <= 0.51


def test_spark_filter_never_accepts_other_inputs():
    microphone = capture.InputDevice("alsa_input.pci.mic", 5, "Internal Microphone", "", 48000, 2, False)
    assert not microphone.is_spark


# The names on disk were German until the app went public: they are carried over once, by renaming only.

OLD_TAKE = {"id": "T1", "fileName": "Aufnahme_2026-01-02_10-00-00.wav", "tags": ["Neuaufnahme", "Blues"], "rating": 4,
            "status": "kept", "duration": 0.1}


def old_folder(folder):
    """A recordings folder as an older version left it, with synthetic content."""
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Bibliothek.json").write_text(store.dumps({"schemaVersion": 2, "recordings": [OLD_TAKE]}))
    (folder / "Bibliothek.backup.json").write_text(store.dumps({"schemaVersion": 2, "recordings": []}))
    (folder / ".wellenformen").mkdir()
    (folder / ".wellenformen" / "T1.lpeaks").write_bytes(b"peaks")
    (folder / "Exporte").mkdir()
    (folder / "Exporte" / "Mix.m4a").write_bytes(b"mix")
    (folder / "Bibliothek.defekt-2026-01-01_09-00-00.json").write_text("{ kaputt")
    (folder / "Bibliothek.vor-Schema-2.aus-1.json").write_text("{}")
    writer = wav.WAVWriter(folder / OLD_TAKE["fileName"], FMT)
    writer.write(bytes(6 * 4800))
    writer.close()


def test_old_names_in_a_folder_become_the_english_ones(tmp_path):
    old_folder(tmp_path)
    before = (tmp_path / "Bibliothek.json").read_text()
    lib = store.LibraryStore(tmp_path)
    assert lib.load() == "loaded"
    assert (tmp_path / "Library.json").read_text() == before
    assert (tmp_path / "Library.backup.json").exists()
    assert (tmp_path / ".waveforms" / "T1.lpeaks").read_bytes() == b"peaks"
    assert (tmp_path / "Exports" / "Mix.m4a").read_bytes() == b"mix"
    for gone in ("Bibliothek.json", "Bibliothek.backup.json", ".wellenformen", "Exporte"):
        assert not (tmp_path / gone).exists()
    # Files an older version set aside keep their names, and so does the take itself.
    assert (tmp_path / "Bibliothek.defekt-2026-01-01_09-00-00.json").read_text() == "{ kaputt"
    assert (tmp_path / "Bibliothek.vor-Schema-2.aus-1.json").exists()
    assert (tmp_path / OLD_TAKE["fileName"]).exists()
    assert store.LibraryStore(tmp_path).carry_over_names() == []


def test_an_old_take_name_and_an_old_tag_load_as_before(tmp_path):
    old_folder(tmp_path)
    lib = store.LibraryStore(tmp_path)
    lib.load()
    take = lib.recording("T1")
    assert take == OLD_TAKE and lib.url(take).exists()
    assert store.query(lib.document["recordings"], tag="neuaufnahme") == [take]
    assert store.query(lib.document["recordings"], text="aufnahme_2026") == [take]
    assert store.all_tags(lib.document["recordings"]) == ["Blues", "Neuaufnahme"]
    lib.save()
    again = store.LibraryStore(tmp_path)
    again.load()
    assert again.recording("T1") == OLD_TAKE


def test_nothing_is_renamed_when_old_and_new_both_exist(tmp_path):
    old_folder(tmp_path)
    new = store.dumps({"schemaVersion": 2, "recordings": [], "pieces": [{"id": "P", "name": "New"}]})
    (tmp_path / "Library.json").write_text(new)
    (tmp_path / "Library.backup.json").write_text("new backup")
    (tmp_path / ".recording-in-progress.json").write_text("not json")
    (tmp_path / ".aufnahme-laeuft.json").write_text("old journal")
    (tmp_path / ".waveforms").mkdir()
    (tmp_path / "Exports").mkdir()
    old = {name: (tmp_path / name).read_text() for name in ("Bibliothek.json", "Bibliothek.backup.json")}

    lib = store.LibraryStore(tmp_path)
    assert lib.carry_over_names() == []
    assert lib.load() == "loaded" and lib.document["pieces"][0]["name"] == "New"
    assert {name: (tmp_path / name).read_text() for name in old} == old
    assert (tmp_path / "Library.json").read_text() == new
    assert (tmp_path / "Library.backup.json").read_text() == "new backup"
    assert (tmp_path / ".aufnahme-laeuft.json").read_text() == "old journal"
    assert (tmp_path / ".wellenformen" / "T1.lpeaks").exists() and not list((tmp_path / ".waveforms").iterdir())
    assert (tmp_path / "Exporte" / "Mix.m4a").exists() and not list((tmp_path / "Exports").iterdir())


def test_a_journal_under_its_old_name_still_leads_to_recovery(tmp_path):
    tmp_path.joinpath("Bibliothek.json").write_text(store.dumps({"schemaVersion": 2, "recordings": []}))
    writer = wav.WAVWriter(tmp_path / "Aufnahme_x.wav", FMT)
    writer.write(bytes(6 * 4800))
    writer.flush()
    (tmp_path / ".aufnahme-laeuft.json").write_text(store.dumps(
        {"fileName": "Aufnahme_x.wav", "startedAt": store.iso(datetime.now(timezone.utc)), "takeID": "T9"}))
    lib = store.LibraryStore(tmp_path)
    lib.load()
    outcome = lib.recover_interrupted()
    assert outcome.kind == "repaired" and outcome.file_name == "Aufnahme_x.wav"
    assert lib.recording("T9")["recoveredAfterInterruption"] is True
    assert not (tmp_path / ".aufnahme-laeuft.json").exists() and not lib.journal_path.exists()
    assert json.loads((tmp_path / "Library.json").read_text())["recordings"][0]["id"] == "T9"


def test_a_rename_that_fails_changes_nothing_and_keeps_the_library_closed(tmp_path, monkeypatch):
    old_folder(tmp_path)
    before = sorted(p.name for p in tmp_path.iterdir())
    content = (tmp_path / "Bibliothek.json").read_text()

    def refuse(source, target):
        raise PermissionError(13, "Permission denied")
    monkeypatch.setattr(store.os, "rename", refuse)
    lib = store.LibraryStore(tmp_path)
    with pytest.raises(store.StoreError) as error:
        lib.load()
    assert "Bibliothek.json" in str(error.value) and "Library.json" in str(error.value)
    assert sorted(p.name for p in tmp_path.iterdir()) == before
    assert (tmp_path / "Bibliothek.json").read_text() == content


def test_the_default_folder_is_recordings(tmp_path, monkeypatch):
    from pathlib import Path
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    assert store.default_folder() == tmp_path / "Music" / "AmpBench" / "Recordings"
