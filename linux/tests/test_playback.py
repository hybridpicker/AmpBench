import shutil
import sys
import time

import pytest

from spark_studio import peaks, player, store, trash, wav
from spark_studio.player import Player, Track


def test_filters_for_loop_tempo_pitch_and_gain():
    track = Track(path="x.wav", duration=30.0, gain_db=6.0)
    assert player.filters(track, 1.0, 0, None) == "volume=6.00dB"
    chain = player.filters(track, 0.8, 3, (2.0, 6.0))
    assert chain.startswith("atrim=start=2.0000:end=6.0000,asetpts=PTS-STARTPTS,aloop=loop=-1:size=192000")
    assert "volume=6.00dB" in chain and "rubberband=tempo=0.8000:pitch=1.189207" in chain
    assert player.filters(Track("x", 10), 1.0, 0, None) == "anull"
    assert "atrim=end=8.0000" in player.filters(Track("x", 10, trim_end=8.0), 1.0, 0, None)


def test_command_seeks_to_the_position_or_the_loop_start():
    track = Track("/a/b.wav", 30.0)
    decode, play = player.command(track, 12.5, 1.0, 0, None)
    assert decode[decode.index("-ss") + 1] == "12.5000" and "pw-cat" == play[0] and "--raw" in play
    decode, _ = player.command(track, 12.5, 1.0, 0, (3.0, 5.0))
    assert decode[decode.index("-ss") + 1] == "3.0000"


def fake(seconds):
    def make(track, position, tempo, pitch, loop):
        return ([sys.executable, "-c", f"import time; time.sleep({seconds})"], ["cat"])
    return make


def test_the_playhead_moves_and_stops_at_the_end():
    finished = []
    p = Player(fake(0.5))
    p.on_finished = lambda: finished.append(True)
    p.load(Track("x", 0.5))
    p.play()
    time.sleep(0.35)
    assert p.is_playing and 0.0 < p.position <= 0.5
    time.sleep(0.6)
    assert not p.is_playing and finished and p.position == pytest.approx(0.5)


def test_seek_pause_tempo_and_loop():
    p = Player(fake(5))
    p.load(Track("x", 20.0))
    p.seek(7.0)
    assert p.position == 7.0 and not p.is_playing
    p.play()
    time.sleep(0.4)
    p.pause()
    assert not p.is_playing and 7.0 <= p.position < 8.0
    p.set_tempo(2.0)
    assert p.tempo == 1.5, "tempo stays within 50 to 150 percent"
    p.set_pitch(40)
    assert p.pitch == 12
    p.set_loop((3.0, 3.05))
    assert p.loop is None, "a loop shorter than a tenth of a second is no loop"
    p.set_loop((3.0, 6.0))
    p.play()
    time.sleep(0.3)
    assert 3.0 <= p.position < 6.0
    p.stop()


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_peaks_of_a_real_file(tmp_path):
    path = tmp_path / "t.wav"
    writer = wav.WAVWriter(path, wav.Format(48000, 1, 24))
    import math
    frames = bytearray()
    for i in range(48000):
        value = int(0x7FFFFF * 0.5 * math.sin(2 * math.pi * 200 * i / 48000)) if i < 24000 else 0
        frames += value.to_bytes(4, "little", signed=True)[:3]
    writer.write(bytes(frames))
    writer.close()
    waveform = peaks.cached(path, tmp_path / "c.lpeaks", 1.0)
    assert waveform and 0.45 < max(waveform.highs) < 0.55
    columns = waveform.columns(10)
    assert columns[0][1] > 0.4 and columns[-1][1] < 0.01
    again = peaks.cached(path, tmp_path / "c.lpeaks", 1.0)
    assert again.highs == pytest.approx(waveform.highs, abs=1e-3), "second time from the cache"


def test_trash_and_restore(tmp_path):
    root = tmp_path / "Trash"
    file = tmp_path / "a.wav"
    file.write_bytes(b"audio")
    moved = trash.move(file, root)
    assert not file.exists() and moved.read_bytes() == b"audio"
    assert "Path=" in (root / "info" / f"{moved.name}.trashinfo").read_text()
    other = tmp_path / "a.wav"
    other.write_bytes(b"new")
    restored = trash.restore(moved, tmp_path / "a.wav", root)
    assert restored.name == "a 2.wav" and other.read_bytes() == b"new", "an existing file is never overwritten"


def test_discarding_a_take_keeps_its_metadata_and_can_be_undone(tmp_path):
    lib = store.LibraryStore(tmp_path / "lib", trash=lambda p: trash.move(p, tmp_path / "Trash"))
    lib.load()
    (tmp_path / "lib" / "a.wav").write_bytes(b"x" * 100)
    lib.document["recordings"].append({"id": "T", "fileName": "a.wav", "rating": 4, "note": "gut"})
    entry = lib.trash_recording("T")
    assert lib.recording("T") is None and lib.document["trashed"][0]["recording"]["rating"] == 4
    assert not (tmp_path / "lib" / "a.wav").exists()
    lib._trash = None
    recording = lib.restore_trashed(entry)
    assert recording["rating"] == 4 and (tmp_path / "lib" / "a.wav").read_bytes() == b"x" * 100
    assert lib.document["trashed"] == [] and lib.recording("T")
