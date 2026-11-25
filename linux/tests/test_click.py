"""The click while recording and the bars of a take: ClickTiming, BeatGrid and the recorder with the click.

The end-to-end tests record through ampbench/fake_rt.py, whose clicks come back into its input a known time after
they left, like the BlackHole loop on the Mac: a note played exactly on the click. The bars of the take must then lie
on those clicks.
"""
import time

import numpy as np
import pytest
from PySide6.QtCore import QSettings

from ampbench import click_timing as ct, metronome, wav
from ampbench.beat_grid import BeatGrid, mix_click
from ampbench.capture import InputDevice, OutputDevice, safe_click_output
from ampbench.demo_input import click_engine, demo_devices, demo_engine, demo_outputs
from ampbench.recorder import COUNT_IN_PRE_ROLL, RecorderModel
from ampbench.store import LibraryStore

RATE = 48000
LOOP = 0.0254  # click out to the file, as measured on the MINI
REPORTED = (0.002, 0.0017)  # input, output


# MARK: Where the bars lie

def test_bar_one_lies_where_a_note_on_its_click_lands():
    latency = ct.ClickLatency(output=0.0017, input=0.002, amp=ct.AmpPart(0.0217, True, 0.0012, "2026-11-23"))
    assert latency.total == pytest.approx(0.0254)
    offset = ct.grid_offset(anchor_frame=10_000, beats_before=4, bpm=120, input_rate=RATE, file_first_frame=96_000,
                            latency=latency)
    # bar 1 at the click: 10 000 + 4 × 24 000 = 106 000, i.e. 10 000 frames into the file, plus the latency
    assert offset == pytest.approx(10_000 / RATE + 0.0254)
    gate = ct.gate_frame(anchor_frame=10_000, beats_before=4, bpm=120, input_rate=RATE, pre_roll=0.15)
    assert gate == 106_000 - 7200


def test_latency_and_stamp_read_like_the_macs():
    mac = {"clickOnThroughout": True, "latency": {"output": 0.0017, "input": 0.002, "outputKind": "wired",
                                                  "amp": {"seconds": 0.0217, "origin": {"measured": {
                                                      "spread": 0.0012, "date": "2026-11-23T12:00:00Z"}}}}}
    stamp = ct.TimingStamp.from_json(mac)
    assert stamp.click_on_throughout and stamp.latency.amp.measured and stamp.latency.amp.spread == 0.0012
    assert ct.TimingStamp.from_json(stamp.to_json()) == stamp
    by_hand = ct.ClickLatency(amp=ct.AmpPart(0.02, False))
    assert by_hand.to_json()["amp"]["origin"] == {"setByHand": {}}
    assert not ct.ClickLatency.from_json(by_hand.to_json()).amp.measured


def test_a_stamp_that_cannot_be_read_never_passes_for_one_with_the_click_on():
    stamp = ct.TimingStamp.from_json({"clickOnThroughout": "yes", "latency": "broken"})
    assert not stamp.click_on_throughout and stamp.latency.amp is None
    assert ct.TimingStamp.from_json(None) is None


def test_a_hand_set_amp_part_is_clamped_and_about_zero_forgets_it():
    amps = ct.AmpLatencies()
    amps.set_by_hand("spark", 0.9)
    assert amps.part("spark") == ct.AmpPart(0.3, False)
    amps.set_by_hand("spark", 0.00001)
    assert amps.part("spark") is None
    amps.store_measurement("spark", 0.0217, 0.0012, ct.datetime(2026, 11, 23, 12))
    again = ct.AmpLatencies.from_json(amps.to_json())
    assert again.part("spark").measured and again.part("spark").seconds == 0.0217


def test_click_watch_stays_off_once_switched_off():
    watch = ct.ClickWatch(True)
    watch.click_switched(True)
    assert watch.on_throughout
    watch.click_switched(False)
    watch.click_switched(True)
    assert not watch.stamp(ct.ClickLatency()).click_on_throughout


# MARK: BeatGrid

def test_bar_positions_and_the_last_bar():
    grid = BeatGrid(bpm=120, beats_per_bar=4, offset=0.2)
    assert grid.position(0.1) is None
    assert grid.position(0.2 - 0.0004).bar == 1, "a playhead a frame before the line counts as on it"
    assert (grid.position(0.75).bar, grid.position(0.75).beat) == (1, 2)
    assert grid.position(2.2).bar == 2
    assert grid.time_of_bar(3) == pytest.approx(4.2)
    assert grid.last_bar(4.2) == 2 and grid.last_bar(4.3) == 3
    assert grid.snapped_bars(0.5, 4.2, 10) == (1, 2)
    assert grid.loop_range(2, 3, 5.0) == pytest.approx((2.2, 5.0))


def test_a_grid_of_an_older_take_reads_with_its_defaults():
    grid = BeatGrid.from_json({"bpm": 90})
    assert (grid.beats_per_bar, grid.offset, grid.first_bar) == (4, 0, 1)
    assert BeatGrid.from_json({"beatsPerBar": 3}) is None
    assert BeatGrid.from_json(grid.to_json()) == grid


def test_the_playback_click_sits_on_the_grid_whatever_the_block():
    grid = BeatGrid(bpm=100, beats_per_bar=4, offset=0.1)
    whole = np.zeros(RATE * 3, dtype=np.float32)
    mix_click(whole, 0, RATE, grid, 0.8)
    pieces = np.zeros_like(whole)
    for start in range(0, len(pieces), 1000):
        mix_click(pieces[start:start + 1000], start, RATE, grid, 0.8)
    assert np.allclose(whole, pieces, atol=1e-6)
    onset = int(np.argmax(np.abs(whole) > 0.01))
    assert abs(onset - 0.1 * RATE) <= 2
    stereo = np.zeros((RATE, 2), dtype=np.float32)
    mix_click(stereo, 0, RATE, grid, 0.8)
    assert np.allclose(stereo[:, 0], whole[:RATE]) and np.allclose(stereo[:, 1], whole[:RATE])


def test_count_in_and_click_on_are_kept_with_the_metronome():
    s = metronome.Settings(bpm=97, count_in_bars=2, click_enabled=True)
    again = metronome.Settings.from_json(s.to_json())
    assert (again.count_in_bars, again.click_enabled, again.count_in_beats) == (2, True, 8)
    assert metronome.Settings.from_json({"countInBars": 7}).count_in_bars == 2


# MARK: The click output

def spark_in():
    return InputDevice("alsa_input.usb-Positive_Grid_Spark_MINI", 40, "Spark MINI", "usb", 48000, 2, True)


def test_the_click_never_goes_to_the_amp_it_records():
    amp = OutputDevice("alsa_output.usb-Positive_Grid_Spark_MINI", 41, "Spark MINI", "usb", "alsa", True)
    phones = OutputDevice("alsa_output.pci-0000_00_1f.3.analog-stereo", 42, "Built-in Audio", "pci", "alsa")
    buds = OutputDevice("bluez_output.AA_BB", 43, "Buds", "bluetooth", "bluez5")
    assert safe_click_output(spark_in(), [amp, phones], None) == phones, "the amp is the default, yet not safe"
    assert safe_click_output(spark_in(), [amp, phones, buds], buds.node_name) == buds
    assert safe_click_output(spark_in(), [amp, phones], amp.node_name) == phones, "a chosen amp is still skipped"
    assert safe_click_output(spark_in(), [amp], None) is None
    assert (phones.kind, buds.kind) == (ct.WIRED, ct.BLUETOOTH)


# MARK: Recording with the click

@pytest.fixture
def settings(tmp_path):
    return QSettings(str(tmp_path / "settings.ini"), QSettings.IniFormat)


def make_recorder(tmp_path, settings, engine, click: metronome.Settings):
    recorder = RecorderModel(LibraryStore(tmp_path / "lib"), engine, demo_devices, demo_outputs, settings=settings)
    recorder.start_library()
    recorder.refresh_devices()
    recorder.click_settings = lambda: click
    messages = []
    recorder.message.connect(lambda kind, text: messages.append((kind, text)))
    return recorder, messages


def run_for(recorder, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        recorder._tick()
        time.sleep(0.01)


def onsets(path, threshold=0.05):
    data = path.read_bytes()[44:]
    raw = np.frombuffer(data[: len(data) - len(data) % 6], dtype=np.uint8).reshape(-1, 6)[:, :3]
    left = (raw[:, 0].astype(np.int32) | (raw[:, 1].astype(np.int32) << 8) | (raw[:, 2].astype(np.int32) << 16))
    left = np.where(left >= 1 << 23, left - (1 << 24), left) / float(1 << 23)
    found, last = [], -10 ** 9
    for i in np.flatnonzero(np.abs(left) > threshold):
        if i - last > RATE // 10:
            found.append(i)
        last = i
    return found


def take_of(recorder):
    takes = recorder.store.document["recordings"]
    assert len(takes) == 1
    return takes[0], recorder.store.folder / takes[0]["fileName"]


def test_a_take_after_a_count_in_lies_on_its_bars(tmp_path, settings):
    click = metronome.Settings(bpm=120, beats_per_bar=4, count_in_bars=1, click_enabled=True, volume=0.8)
    recorder, messages = make_recorder(tmp_path, settings, click_engine(LOOP, REPORTED), click)
    recorder.amp_latencies.set_by_hand("demo.spark", LOOP - sum(REPORTED))
    recorder.start()
    assert recorder.is_counting_in and recorder.is_recording
    run_for(recorder, 0.3)
    assert recorder.count_in_left in (3, 4)
    run_for(recorder, 2.0 + 2.6)
    assert recorder.phase == "recording"
    recorder.stop()
    take, path = take_of(recorder)
    grid = BeatGrid.from_json(take["grid"])
    assert (grid.bpm, grid.beats_per_bar, grid.first_bar) == (120, 4, 1)
    assert grid.offset == pytest.approx(COUNT_IN_PRE_ROLL + LOOP, abs=1.5 / RATE)
    beats = [grid.offset + k * grid.seconds_per_beat for k in range(8)]
    found = onsets(path)
    assert len(found) >= 4
    for frame in found:
        nearest = min(beats, key=lambda b: abs(b * RATE - frame))
        assert abs(frame - nearest * RATE) <= 2, "every click lands on its beat, to the sample"
    stamp = ct.TimingStamp.from_json(take["timing"])
    assert stamp.click_on_throughout
    assert stamp.latency.total == pytest.approx(LOOP) and not stamp.latency.amp.measured
    assert stamp.latency.output_kind == ct.WIRED
    assert not [m for m in messages if m[0] in ("warning", "error")]


def test_a_count_in_without_the_click_falls_silent_and_still_gives_bars(tmp_path, settings):
    click = metronome.Settings(bpm=150, beats_per_bar=3, count_in_bars=1, click_enabled=False)
    recorder, _ = make_recorder(tmp_path, settings, click_engine(LOOP, REPORTED), click)
    recorder.start()
    run_for(recorder, 1.2 + 1.5)
    recorder.stop()
    take, path = take_of(recorder)
    assert BeatGrid.from_json(take["grid"]).beats_per_bar == 3
    assert onsets(path) == [], "after the count-in nothing sounds"
    assert not ct.TimingStamp.from_json(take["timing"]).click_on_throughout


def test_the_click_without_a_count_in_starts_with_the_take(tmp_path, settings):
    click = metronome.Settings(bpm=100, beats_per_bar=4, count_in_bars=0, click_enabled=True, volume=0.8)
    recorder, _ = make_recorder(tmp_path, settings, click_engine(LOOP, REPORTED), click)
    recorder.amp_latencies.set_by_hand("demo.spark", LOOP - sum(REPORTED))
    recorder.start()
    assert recorder.phase == "recording"
    run_for(recorder, 2.5)
    recorder.stop()
    take, path = take_of(recorder)
    grid = BeatGrid.from_json(take["grid"])
    assert -0.05 < grid.offset < 0.2
    for frame in onsets(path):
        k = round((frame / RATE - grid.offset) / grid.seconds_per_beat)
        assert abs(frame - (grid.offset + k * grid.seconds_per_beat) * RATE) <= 2


def test_switching_the_click_off_ends_click_on_throughout(tmp_path, settings):
    click = metronome.Settings(bpm=120, count_in_bars=0, click_enabled=True)
    recorder, _ = make_recorder(tmp_path, settings, click_engine(LOOP, REPORTED), click)
    recorder.start()
    run_for(recorder, 0.6)
    recorder.toggle_click()
    assert not click.click_enabled
    run_for(recorder, 1.2)
    recorder.stop()
    take, path = take_of(recorder)
    assert "grid" in take, "the click kept counting the bars"
    assert not ct.TimingStamp.from_json(take["timing"]).click_on_throughout
    assert all(frame < 0.9 * RATE for frame in onsets(path)), "silent once switched off"


def test_r_during_the_count_in_cancels_it(tmp_path, settings):
    click = metronome.Settings(bpm=60, count_in_bars=2)
    recorder, messages = make_recorder(tmp_path, settings, click_engine(LOOP, REPORTED), click)
    recorder.start()
    run_for(recorder, 0.4)
    recorder.toggle()
    assert recorder.phase == "idle" and not recorder.engine.click.running
    assert recorder.store.document["recordings"] == []
    assert list(recorder.store.folder.glob("*.wav")) == []
    assert recorder.store.read_journal() is None
    assert ("info", "The count-in was canceled.") in messages


def test_without_the_helper_a_count_in_becomes_a_plain_take(tmp_path, settings):
    click = metronome.Settings(count_in_bars=1, click_enabled=True)
    recorder, messages = make_recorder(tmp_path, settings, demo_engine(), click)
    assert not recorder.can_click
    recorder.start()
    assert recorder.phase == "recording"
    run_for(recorder, 0.4)
    recorder.stop()
    take, _ = take_of(recorder)
    assert "grid" not in take and "timing" not in take
    assert ("warning", "The click needs ampbench-rt, which is not built here. The recording starts without a "
                       "count-in.") in messages


def test_no_safe_output_means_no_count_in(tmp_path, settings):
    click = metronome.Settings(count_in_bars=1)
    recorder, messages = make_recorder(tmp_path, settings, click_engine(LOOP, REPORTED), click)
    recorder._outputs_provider = lambda: [o for o in demo_outputs() if "Spark" in o.description]
    recorder.refresh_devices()
    assert recorder.click_output is None
    recorder.start()
    assert recorder.phase == "recording"
    run_for(recorder, 0.3)
    recorder.stop()
    assert "grid" not in take_of(recorder)[0]
    assert any("No safe output" in text for _, text in messages)


def test_the_bars_survive_a_crash_but_not_the_stamp(tmp_path, settings):
    click = metronome.Settings(bpm=120, count_in_bars=0, click_enabled=True)
    recorder, _ = make_recorder(tmp_path, settings, click_engine(LOOP, REPORTED), click)
    recorder.start()
    run_for(recorder, 0.8)
    journal = recorder.store.read_journal()
    assert journal["grid"]["bpm"] == 120
    # The app dies here: the file stays open and unfinished, the journal stays.
    recorder.engine._writer.flush()
    recorder.engine._writer = None
    recorder.engine.close()
    again = LibraryStore(tmp_path / "lib")
    again.load()
    assert again.recover_interrupted().kind == "repaired"
    take = again.document["recordings"][0]
    assert take["grid"]["bpm"] == 120 and "timing" not in take
    assert wav.inspect(again.folder / take["fileName"])[0] == "ok"


# MARK: The deck and the window

@pytest.fixture(scope="module")
def qapp():
    from PySide6.QtWidgets import QApplication
    return QApplication.instance() or QApplication([])


def wait_for(condition, timeout=6000):
    from PySide6.QtTest import QTest
    end = time.monotonic() + timeout / 1000
    while time.monotonic() < end:
        if condition():
            return
        QTest.qWait(20)
    raise AssertionError("timed out")


def test_the_deck_sets_the_click_and_a_take_gets_its_bars(qapp, tmp_path, settings):
    from PySide6.QtCore import Qt
    from PySide6.QtTest import QTest
    from ampbench.fake_amp import FakeAmp
    from ampbench.library import PresetLibrary
    from ampbench.qtlink import QtLink
    from ampbench.ui.main_window import MainWindow
    recorder = RecorderModel(LibraryStore(tmp_path / "Recordings"), click_engine(LOOP, REPORTED), demo_devices,
                             demo_outputs, settings=settings)
    amp = FakeAmp()
    w = MainWindow(QtLink(lambda: amp), PresetLibrary(tmp_path / "Presets"), auto_connect=False, recorder=recorder)
    w.show()
    try:
        w.metronome.update(lambda s: (setattr(s, "bpm", 120), setattr(s, "beats_per_bar", 4),
                                      setattr(s, "count_in_bars", 0), setattr(s, "click_enabled", False)))
        assert w.deck.click_lamp.text == "Off · N"
        QTest.keyClick(w, Qt.Key_N)
        assert w.metronome.settings.click_enabled and w.deck.click_lamp.text == "On · N"
        w.deck.count_in_chosen.emit(1)
        assert w.metronome.settings.count_in_bars == 1
        assert w.deck.count_in_popup.text == "Count in 1 bar"
        w.deck.details.show_state(w.metronome.settings, recorder)
        assert w.deck.details.goes_to.text() == "While recording, the click goes to “Headphones (Demo)”."
        assert [w.deck.details.output.itemText(i) for i in range(w.deck.details.output.count())] == \
            ["Automatic", "Headphones (Demo)", "Spark MINI (Demo)"]
        QTest.keyClick(w, Qt.Key_R)
        wait_for(lambda: recorder.is_counting_in and w.deck.state_lamp.text.startswith("Count-in"))
        assert not w.deck.tempo.isEnabled(), "the tempo stays while a take runs"
        wait_for(lambda: recorder.phase == "recording", timeout=4000)
        wait_for(lambda: recorder.active_grid is not None and w.recordings.wave.grid == recorder.active_grid)
        wait_for(lambda: w.deck.beat_lamps.current >= 0)
        QTest.qWait(1200)
        QTest.keyClick(w, Qt.Key_R)
        wait_for(lambda: not recorder.is_recording and w.recordings.table.rowCount() == 1)
        take = recorder.store.document["recordings"][0]
        assert take["grid"]["bpm"] == 120 and take["timing"]["clickOnThroughout"]
        w.recordings.select(take["id"])
        assert w.recordings.wave.grid == BeatGrid.from_json(take["grid"])
        assert w.recordings.player.click is not None, "the click plays along on the take's bars"
        QTest.keyClick(w, Qt.Key_N)
        assert w.recordings.player.click is None
    finally:
        w.close()


def test_a_helper_that_never_delivers_gives_way_to_pw_record(tmp_path, settings, monkeypatch):
    import sys
    from ampbench import capture
    from ampbench.demo_input import SCRIPT
    monkeypatch.setattr(capture, "HELPER_FIRST_FRAMES", 0.3)
    hanging = [sys.executable, "-c", "import time; time.sleep(30)"]
    engine = capture.CaptureEngine(lambda d: hanging, speaks_rt=True)
    engine._pw_record = lambda d: [sys.executable, "-c", SCRIPT, str(d.rate), str(d.channels)]
    click = metronome.Settings(count_in_bars=0, click_enabled=True)
    recorder, messages = make_recorder(tmp_path, settings, engine, click)
    recorder.toggle_monitoring()
    end = time.monotonic() + 5
    while engine.frames_read == 0 and time.monotonic() < end:
        time.sleep(0.02)
    assert engine.frames_read > 0 and engine.helper_failed and not recorder.can_click
    recorder.start()
    run_for(recorder, 0.4)
    recorder.stop()
    assert "grid" not in take_of(recorder)[0]
    assert ("warning", "ampbench-rt got no sound from the input, so AmpBench records with pw-record until it is "
                       "started again. The recording runs without a click.") in messages
    recorder.shutdown()


def test_the_playback_click_follows_tempo_and_loop():
    from ampbench.player import ClickPlan
    grid = BeatGrid(bpm=120, beats_per_bar=4, offset=0.25)

    def clicks(plan, seconds):
        out = np.zeros((int(seconds * RATE), 2), dtype=np.float32)
        for start in range(0, len(out), 4096):
            plan.mix(out[start:start + 4096], start)
        found, last = [], -10 ** 9
        for i in np.flatnonzero(np.abs(out[:, 0]) > 0.01):
            if i - last > RATE // 20:
                found.append(i / RATE)
            last = i
        return found

    # From 1.0 s in the file at half tempo: the beat at 1.25 s is heard 0.5 s in, then one every second.
    assert clicks(ClickPlan(grid, 0.8, 1.0, 0.5, None), 3.2) == pytest.approx([0.5, 1.5, 2.5], abs=2 / RATE)
    # A loop from 1.1 to 2.1 s at full tempo: beats at 1.25, 1.75 in every lap of one second.
    assert clicks(ClickPlan(grid, 0.8, 1.1, 1.0, (1.1, 2.1)), 2.9) == \
        pytest.approx([0.15, 0.65, 1.15, 1.65, 2.15, 2.65], abs=2 / RATE)


# MARK: Measuring the click latency

def test_the_measurement_finds_the_amps_part_and_the_bars_then_rest_on_it(tmp_path, settings):
    click = metronome.Settings(bpm=120, count_in_bars=1, click_enabled=True)
    recorder, messages = make_recorder(tmp_path, settings, click_engine(LOOP, REPORTED), click)
    assert recorder.can_measure_latency and recorder.amp_part is None
    recorder.measure_latency()
    assert recorder.is_measuring and not recorder.can_measure_latency
    run_for(recorder, 0.3)
    recorder.start()
    assert not recorder.is_recording, "no take while measuring"
    end = time.monotonic() + 15
    while recorder.is_measuring and time.monotonic() < end:
        recorder._tick()
        time.sleep(0.01)
    assert not recorder.is_measuring
    part = recorder.amp_part
    assert part is not None and part.measured, messages
    assert part.seconds == pytest.approx(LOOP - sum(REPORTED), abs=0.0001)
    assert part.spread < 0.0001
    assert messages[-1][0] == "info" and messages[-1][1].startswith("Measured: 25.4 ms from the click into the file, "
                                                                    "of which 21.7 ms are not reported")
    assert list(tmp_path.glob("**/ampbench-latency-*")) == [] and recorder.store.document["recordings"] == []
    assert not recorder.engine.is_open, "the input it opened is closed again"
    # Kept with the input, it carries over to a new start of the app.
    again = RecorderModel(LibraryStore(tmp_path / "lib2"), click_engine(), demo_devices, demo_outputs,
                          settings=settings)
    again.refresh_devices()
    assert again.amp_part == part
    # A take now has bars where the notes on the click land, and a stamp a review can rest on.
    recorder.start()
    run_for(recorder, 2.0 + 2.4)
    recorder.stop()
    take, path = take_of(recorder)
    grid = BeatGrid.from_json(take["grid"])
    assert grid.offset == pytest.approx(COUNT_IN_PRE_ROLL + LOOP, abs=0.0002)
    stamp = ct.TimingStamp.from_json(take["timing"])
    assert stamp.latency.amp.measured
    from ampbench import timing_review
    assert timing_review.reason_before_listening(grid, stamp) is None


def test_a_measurement_without_a_signal_or_through_bluetooth_is_refused(tmp_path, settings):
    click = metronome.Settings()
    recorder, messages = make_recorder(tmp_path, settings, click_engine(loop=None), click)
    recorder.measure_latency()
    end = time.monotonic() + 15
    while recorder.is_measuring and time.monotonic() < end:
        recorder._tick()
        time.sleep(0.01)
    assert recorder.amp_part is None
    assert messages[-1][0] == "error" and "No click arrived at the input" in messages[-1][1]
    buds = OutputDevice("bluez_output.AA", 9, "Buds", "bluetooth", "bluez5", True)
    recorder._outputs_provider = lambda: [buds]
    recorder.refresh_devices()
    recorder.measure_latency()
    assert not recorder.is_measuring
    assert "Bluetooth output, whose own delay" in messages[-1][1]


def test_uneven_clicks_are_refused_and_a_clean_run_kept():
    from ampbench import latency_probe as lp
    with pytest.raises(lp.LatencyProbeError) as refused:
        lp.evaluate([1000, 1010, 1200, 1005, 1300, 1002, 1400, 1003, 1500, 1004, 1600, 1001], 12, 48_000, 0.004)
    assert refused.value.kind == "unstable"
    result = lp.evaluate([1219.0 + (k % 3) * 10 for k in range(12)], 12, 48_000, 0.0037)
    assert result.measured == pytest.approx(1229 / 48_000, abs=1e-6) and result.spread == pytest.approx(20 / 48_000)
    assert result.correction == pytest.approx(result.measured - 0.0037)
    with pytest.raises(lp.LatencyProbeError):
        lp.evaluate([1000.0] * 7, 12, 48_000, 0.0)


def test_a_take_on_the_click_shows_its_review_and_band_in_the_window(qapp, tmp_path, settings):
    from datetime import datetime, timezone
    from ampbench.fake_amp import FakeAmp
    from ampbench.library import PresetLibrary
    from ampbench.qtlink import QtLink
    from ampbench.ui.main_window import MainWindow
    recorder = RecorderModel(LibraryStore(tmp_path / "Recordings"), click_engine(LOOP, REPORTED), demo_devices,
                             demo_outputs, settings=settings)
    recorder.amp_latencies.store_measurement("demo.spark", LOOP - sum(REPORTED), 0.0012, datetime.now(timezone.utc))
    w = MainWindow(QtLink(lambda: FakeAmp()), PresetLibrary(tmp_path / "Presets"), auto_connect=False,
                   recorder=recorder)
    w.show()
    page = w.recordings
    try:
        w.metronome.update(lambda s: (setattr(s, "bpm", 160), setattr(s, "beats_per_bar", 4),
                                      setattr(s, "count_in_bars", 1), setattr(s, "click_enabled", True),
                                      setattr(s, "volume", 0.8)))
        recorder.start()
        wait_for(lambda: recorder.phase == "recording", timeout=5000)
        wait_for(lambda: recorder.engine.meter.seconds > 3.3, timeout=6000)
        recorder.stop()
        wait_for(lambda: page.timing_outcome is not None and page.timing_outcome.review is not None, timeout=8000)
        review = page.timing_outcome.review
        assert review.counted >= 8
        assert abs(review.placement) < 0.0005 and review.spread < 0.0005, "every note on its click"
        assert review.accuracy == pytest.approx(0.0011)
        assert page.timing_line.text.text().startswith("Placement +0.0 ms · Spread 0.0 ms · Accuracy ±1.1 ms · ")
        assert page.band.isVisible() and page.band.band().bars == (1, 2)
        page.toggle_timing_band()
        assert not page.band.isVisible() and page.timing_line.fold_key.text() == "Unfold"
        page.toggle_timing_band()
        page.set_timing_grid(2)
        take = recorder.store.document["recordings"][0]
        assert take["timingGrid"] == 2, "kept with the take, which has no piece"
        wait_for(lambda: page.timing_outcome and page.timing_outcome.review
                 and page.timing_outcome.review.resolution == 2, timeout=8000)
        assert page.timing_line.text.text().endswith(f"{page.timing_outcome.review.counted} notes on eighths")
    finally:
        w.close()


def test_a_take_without_a_measured_amp_says_why(qapp, tmp_path, settings):
    from ampbench.fake_amp import FakeAmp
    from ampbench.library import PresetLibrary
    from ampbench.qtlink import QtLink
    from ampbench.ui.main_window import MainWindow
    recorder = RecorderModel(LibraryStore(tmp_path / "Recordings"), click_engine(LOOP, REPORTED), demo_devices,
                             demo_outputs, settings=settings)
    w = MainWindow(QtLink(lambda: FakeAmp()), PresetLibrary(tmp_path / "Presets"), auto_connect=False,
                   recorder=recorder)
    w.show()
    try:
        w.metronome.update(lambda s: (setattr(s, "count_in_bars", 0), setattr(s, "click_enabled", True)))
        recorder.start()
        wait_for(lambda: recorder.engine.meter.seconds > 0.6)
        recorder.stop()
        wait_for(lambda: w.recordings.timing_outcome is not None)
        assert w.recordings.timing_line.text.text() == "No timing review: click latency not measured."
        assert not w.recordings.band.isVisible() and not w.recordings.timing_line.grid_popup.isVisible()
    finally:
        w.close()
