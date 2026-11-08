import json
import os
import struct
import time
from datetime import datetime, timezone

import pytest

from spark_studio import capture, store, wav
from spark_studio.demo_input import demo_devices, demo_engine

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
    assert (tmp_path / "Bibliothek.backup.json").exists()


def test_the_document_reads_like_the_macs(tmp_path):
    lib = store.LibraryStore(tmp_path)
    lib.load()
    lib.save()
    text = (tmp_path / "Bibliothek.json").read_text()
    assert '"schemaVersion" : 2' in text


def test_an_unreadable_library_is_kept_and_the_backup_used(tmp_path):
    lib = store.LibraryStore(tmp_path)
    lib.load()
    lib.document["practiceLog"].append({"id": "1", "date": "2026-11-01T10:00:00Z", "seconds": 5})
    lib.save()
    lib.save()
    (tmp_path / "Bibliothek.json").write_text("{ kaputt")
    other = store.LibraryStore(tmp_path)
    assert other.load() == "restored"
    assert any(p.name.startswith("Bibliothek.defekt-") for p in tmp_path.iterdir())


def test_a_newer_schema_is_never_overwritten(tmp_path):
    original = json.dumps({"schemaVersion": 9, "recordings": []})
    (tmp_path / "Bibliothek.json").write_text(original)
    lib = store.LibraryStore(tmp_path)
    with pytest.raises(store.StoreError):
        lib.load()
    assert (tmp_path / "Bibliothek.json").read_text() == original


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
