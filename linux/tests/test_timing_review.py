"""What the timing review says about generated takes: plucks and strums at known places on known bars.

Ported from Tests/SparkCoreTests/TimingReviewTests.swift and TimingReviewBarsTests.swift; the same signals (a plucked
string after Karplus and Strong over a faint noise floor) and the same expectations.
"""
from functools import lru_cache

import numpy as np
import pytest

from ampbench import i18n, timing_review as tr_
from ampbench.beat_grid import BeatGrid
from ampbench.click_timing import AmpPart, ClickLatency, TimingStamp
from ampbench.tuner_signal import karplus_strong

MEASURED = TimingStamp(True, ClickLatency(0.004, 0.003, AmpPart(0.0217, True, 0.0012, "2026-11-23T12:00:00Z")))


@lru_cache(maxsize=None)
def pluck(frequency: float, rate: float, seed: int) -> np.ndarray:
    return karplus_strong(frequency, rate, 0.6, amplitude=0.5, ring_time=0.5, seed=seed).astype(np.float32)


def take(notes, seconds: float, rate: float) -> np.ndarray:
    """Notes are (time, frequency, amplitude, attack seconds); each starts exactly at its time."""
    samples = (np.random.default_rng(5).normal(0, 0.0003, int(seconds * rate))).astype(np.float32)
    for number, (time, frequency, amplitude, attack) in enumerate(notes):
        sound = pluck(frequency, rate, number % 4 + 1) * np.float32(amplitude / 0.5)
        if attack > 0:
            sound = sound * np.minimum(np.arange(len(sound)) / (attack * rate), 1).astype(np.float32)
        start = int(round(time * rate))
        end = min(start + len(sound), len(samples))
        samples[start:end] += sound[: end - start]
    return samples


def note(time, frequency=196.0, amplitude=0.5, attack=0.0):
    return (time, frequency, amplitude, attack)


def plucks_on_bars(bpm, rate, bars=4, offset=lambda beat: 0.0):
    grid = BeatGrid(bpm, 4, 0.15)
    beats = bars * 4
    notes = [note(grid.offset + b * grid.seconds_per_beat + offset(b)) for b in range(beats)]
    return take(notes, grid.offset + beats * grid.seconds_per_beat + 0.3, rate), grid


def reviewed(samples, rate, grid, stamp=MEASURED, resolution=tr_.QUARTERS, **kw) -> tr_.TimingReview:
    outcome = tr_.review(samples, rate, grid, stamp, resolution, **kw)
    assert outcome.review is not None, f"no review: {outcome.reason}"
    return outcome.review


# MARK: Onsets

@pytest.mark.parametrize("rate", [44_100.0, 48_000.0, 96_000.0])
def test_plucks_at_known_offsets_come_out_within_1_millisecond(rate):
    for bpm in (72.0, 120.0, 168.0):
        for offset in (0.0, 0.020, -0.010):
            samples, grid = plucks_on_bars(bpm, rate, offset=lambda _: offset)
            review = reviewed(samples, rate, grid)
            counted = [o for o in review.onsets if o.is_counted]
            assert len(counted) == 16, (rate, bpm, offset)
            for onset in counted:
                assert onset.offset == pytest.approx(offset, abs=0.001), (rate, bpm, onset.grid_point)
            assert review.placement == pytest.approx(offset, abs=0.001)


def test_a_strum_counts_from_its_first_string():
    strings = [82.4, 110, 146.8, 196, 246.9, 329.6]
    rate = 48_000.0
    grid = BeatGrid(100, 4, 0.15)
    for strum in (0.010, 0.025, 0.040):
        notes = []
        for beat in range(8):
            first = grid.offset + beat * grid.seconds_per_beat
            order = strings if beat % 2 == 0 else list(reversed(strings))
            notes += [note(first + strum * i / 5, f, 0.25) for i, f in enumerate(order)]
        review = reviewed(take(notes, grid.offset + 8 * grid.seconds_per_beat + 0.3, rate), rate, grid)
        assert review.counted == 8, strum
        assert all(o.offset == pytest.approx(0, abs=0.001) for o in review.onsets if o.is_counted)


def test_only_the_first_onset_in_a_catch_window_counts():
    rate = 44_100.0
    grid = BeatGrid(90, 4, 0.15)
    notes = []
    for beat in range(8):
        time = grid.offset + beat * grid.seconds_per_beat + 0.012
        notes += [note(time), note(time + 0.120)]  # a delay echo 120 ms later, inside the window of 233 ms
    review = reviewed(take(notes, grid.offset + 8 * grid.seconds_per_beat + 0.3, rate), rate, grid)
    assert review.counted == 8
    assert sum(o.status == tr_.LATER_IN_WINDOW for o in review.onsets) == 8
    assert review.placement == pytest.approx(0.012, abs=0.001)


def test_an_onset_outside_every_catch_window_does_not_count():
    rate = 48_000.0
    grid = BeatGrid(120, 4, 0.15)
    between = grid.offset + 2.5 * grid.seconds_per_beat
    notes = [note(grid.offset + b * grid.seconds_per_beat) for b in range(8)] + [note(between, 330)]
    review = reviewed(take(notes, grid.offset + 8 * grid.seconds_per_beat + 0.3, rate), rate, grid)
    assert review.counted == 8
    outside = [o for o in review.onsets if o.status == tr_.OUTSIDE_WINDOWS]
    assert len(outside) == 1 and outside[0].time == pytest.approx(between, abs=0.001) and outside[0].offset is None


# MARK: Grid resolution

def notes_on_points(bpm, points_per_beat, rate, offset):
    grid = BeatGrid(bpm, 4, 0.15)
    spacing = grid.seconds_per_beat / points_per_beat
    strings = [196.0, 293.7, 246.9, 329.6]
    notes = [note(grid.offset + p * spacing + offset(p), strings[p % 4]) for p in range(8 * points_per_beat)]
    return take(notes, grid.offset + 8 * grid.seconds_per_beat + 0.3, rate), grid


def test_eighths_and_triplets_are_matched_to_their_own_grid_points():
    rate = 48_000.0
    for resolution in (tr_.EIGHTHS, tr_.TRIPLETS, tr_.SIXTEENTHS):
        samples, grid = notes_on_points(90, resolution, rate, lambda p: 0.008 if p % resolution == 0 else 0.015)
        review = reviewed(samples, rate, grid, resolution=resolution)
        assert review.resolution == resolution and review.counted == 8 * resolution
        counted = [o for o in review.onsets if o.is_counted]
        assert [o.grid_point for o in counted] == list(range(8 * resolution))
        for onset in counted:
            expected = 0.008 if onset.grid_point % resolution == 0 else 0.015
            assert onset.offset == pytest.approx(expected, abs=0.001)


def test_on_quarters_the_eighths_between_the_beats_do_not_count():
    samples, grid = notes_on_points(90, 2, 44_100.0, lambda _: 0.005)
    review = reviewed(samples, 44_100.0, grid)
    assert review.counted == 8
    assert sum(o.status == tr_.OUTSIDE_WINDOWS for o in review.onsets) == 8
    assert review.placement == pytest.approx(0.005, abs=0.001)


def test_a_late_eighth_is_never_counted_as_an_early_next_one():
    rate = 48_000.0
    samples, grid = notes_on_points(100, 2, rate, lambda p: 0 if p % 2 == 0 else 0.095)
    review = reviewed(samples, rate, grid, resolution=tr_.EIGHTHS)
    assert review.counted == 16
    for onset in (o for o in review.onsets if o.is_counted):
        assert onset.offset == pytest.approx(0 if onset.grid_point % 2 == 0 else 0.095, abs=0.001)
    too_late, _ = notes_on_points(100, 2, rate, lambda p: 0 if p % 2 == 0 else 0.115)
    late = reviewed(too_late, rate, grid, resolution=tr_.EIGHTHS)
    assert late.counted == 8
    assert sum(o.status == tr_.OUTSIDE_WINDOWS for o in late.onsets) == 8
    assert all(o.grid_point % 2 == 0 and abs(o.offset) < 0.001 for o in late.onsets if o.is_counted)


def test_quiet_and_legato_notes_are_faint_and_not_counted():
    quiet, legato = {3, 9}, {6, 13}
    for rate in (44_100.0, 48_000.0):
        grid = BeatGrid(100, 4, 0.15)
        notes = []
        for beat in range(16):
            amplitude = 0.5 * 10 ** (-24 / 20) if beat in quiet else 0.5
            notes.append(note(grid.offset + beat * grid.seconds_per_beat, 196 if beat % 2 == 0 else 247, amplitude,
                              0.020 if beat in legato else 0.0))
        review = reviewed(take(notes, grid.offset + 16 * grid.seconds_per_beat + 0.3, rate), rate, grid)
        assert review.counted == 12, rate
        assert {o.grid_point for o in review.onsets if o.status == tr_.UNSURE} == quiet | legato
        assert {o.grid_point for o in review.onsets if o.is_counted} == set(range(16)) - quiet - legato
        assert review.placement == pytest.approx(0, abs=0.001)


def test_a_volume_swell_does_not_count():
    rate = 48_000.0
    grid = BeatGrid(90, 4, 0.15)
    swells = {4, 11}
    notes = [note(grid.offset + b * grid.seconds_per_beat, attack=0.3 if b in swells else 0) for b in range(16)]
    review = reviewed(take(notes, grid.offset + 16 * grid.seconds_per_beat + 0.3, rate), rate, grid)
    assert review.counted == 14
    assert not any(o.grid_point in swells for o in review.onsets if o.is_counted)


# MARK: Reading a take

def test_a_take_file_reads_as_the_same_take_in_memory_from_its_loudest_channel(tmp_path):
    from ampbench import wav
    rate = 48_000.0
    samples, grid = plucks_on_bars(100, rate, offset=lambda b: 0.006 if b % 2 == 0 else 0.014)
    stereo = np.stack([samples * 0.1, samples], axis=1)  # the guitar on the right
    ints = np.clip(np.round(stereo * (1 << 23)), -(1 << 23), (1 << 23) - 1).astype("<i4")
    raw = ints.view(np.uint8).reshape(-1, 4)[:, :3].tobytes()
    writer = wav.WAVWriter(tmp_path / "take.wav", wav.Format(int(rate), 2, 24))
    writer.write(raw)
    writer.close()
    from_file = tr_.review_file(tmp_path / "take.wav", grid, MEASURED).review
    memory = reviewed(samples, rate, grid)
    assert from_file.counted == 16
    assert from_file.placement == pytest.approx(memory.placement, abs=0.00002)
    assert from_file.spread == pytest.approx(memory.spread, abs=0.00002)
    assert from_file.placement == pytest.approx(0.010, abs=0.001)


# MARK: Numbers, accuracy and hints

def test_placement_is_the_mean_and_spread_the_standard_deviation():
    rate = 48_000.0
    offsets = [0.010, 0.020, 0.010, 0.020] * 4
    samples, grid = plucks_on_bars(100, rate, offset=lambda b: offsets[b])
    review = reviewed(samples, rate, grid)
    assert review.placement == pytest.approx(0.015, abs=0.0005)
    assert review.spread == pytest.approx(0.005, abs=0.0005)


def test_accuracy_just_inside_2_milliseconds_gets_a_review_and_just_outside_the_reason():
    samples, grid = plucks_on_bars(100, 48_000.0)

    def stamp(spread):
        return TimingStamp(True, ClickLatency(0.004, 0.003, AmpPart(0.02, True, spread)))
    inside = tr_.review(samples, 48_000.0, grid, stamp(0.003))
    assert inside.review is not None and inside.review.accuracy == pytest.approx(0.002)
    assert tr_.review(samples, 48_000.0, grid, stamp(0.0031)).reason == tr_.ACCURACY_NOT_GOOD_ENOUGH
    assert tr_.accuracy_text(0.0011) == "Accuracy ±1.1 ms"


def test_a_delay_in_the_sound_gives_a_hint_and_still_a_review():
    samples, grid = plucks_on_bars(100, 48_000.0)
    assert reviewed(samples, 48_000.0, grid, sound_has_delay=True).hints == [tr_.DELAY_IN_THE_SOUND]
    assert reviewed(samples, 48_000.0, grid).hints == []


def test_each_reason_for_no_review_in_its_order():
    samples, grid = plucks_on_bars(100, 48_000.0)
    latency = MEASURED.latency
    cases = [
        (None, MEASURED, tr_.NO_BARS),
        (grid, None, tr_.RECORDED_BEFORE_THE_STAMP),
        (grid, TimingStamp(False, ClickLatency(amp=None, output_kind="bluetooth")), tr_.CLICK_NOT_ON_THROUGHOUT),
        (grid, TimingStamp(True, ClickLatency(0.004, 0.003, AmpPart(0.02, False), "bluetooth")),
         tr_.AMP_PART_NOT_MEASURED),
        (grid, TimingStamp(True, ClickLatency(0.004, 0.003, latency.amp, "bluetooth")), tr_.CLICK_ON_BLUETOOTH),
        (grid, TimingStamp(True, ClickLatency(0.004, 0.003, latency.amp, "airPlay")), tr_.CLICK_ON_AIRPLAY),
        (grid, TimingStamp(True, ClickLatency(0.004, 0.003, AmpPart(0.02, True, 0.01))), tr_.ACCURACY_NOT_GOOD_ENOUGH),
    ]
    for g, stamp, reason in cases:
        assert tr_.review(samples, 48_000.0, g, stamp).reason == reason
    quiet = np.random.default_rng(1).normal(0, 0.0003, len(samples)).astype(np.float32)
    assert tr_.review(quiet, 48_000.0, grid, MEASURED).reason == tr_.TOO_FEW_ONSETS


def test_a_review_needs_eight_counted_onsets():
    samples, grid = plucks_on_bars(100, 48_000.0, bars=2)
    assert reviewed(samples, 48_000.0, grid).counted == 8
    seven = samples.copy()
    seven[int((grid.offset + 7 * grid.seconds_per_beat - 0.05) * 48_000):] = 0
    assert tr_.review(seven, 48_000.0, grid, MEASURED).reason == tr_.TOO_FEW_ONSETS


def test_the_reasons_and_words_read_in_english_and_german():
    try:
        i18n.set_language(i18n.GERMAN)
        assert tr_.reason_text(tr_.AMP_PART_NOT_MEASURED) == "Keine Timing-Auswertung: Klick-Latenz nicht gemessen."
        assert tr_.steadiness_word(tr_.UNSTEADY) == "unruhig"
        assert tr_.accuracy_text(0.0011) == "Genauigkeit ±1,1 ms"
        assert tr_.Bar(2, 1, -0.0042).text == "Takt 2: Lage -4,2 ms, ein einzelner Ton, zu wenige für ein Urteil"
    finally:
        i18n.set_language(i18n.ENGLISH)
    assert tr_.reason_text(tr_.TOO_FEW_ONSETS) == "No timing review: too few clear notes."


# MARK: Bars

def test_every_bar_has_its_placement_and_spread_and_an_unsteady_one_stands_out():
    rate = 48_000.0
    # Bars 1, 2 and 4 steady around +10 ms (±2 ms), bar 3 swinging ±20 ms.
    wobble = {8: -0.010, 9: 0.030, 10: -0.010, 11: 0.030}
    samples, grid = plucks_on_bars(100, rate, offset=lambda b: wobble.get(b, 0.010 + (0.002 if b % 2 else -0.002)))
    review = reviewed(samples, rate, grid)
    # The file runs 0.3 s into bar 5, so it has that bar too, without notes, as on the Mac.
    assert [b.number for b in review.bars] == [1, 2, 3, 4, 5]
    assert [b.steadiness for b in review.bars] == [tr_.STEADY, tr_.STEADY, tr_.UNSTEADY, tr_.STEADY, None]
    assert review.bars[4].text == "Bar 5: no counted notes"
    third = review.bars[2]
    assert third.placement == pytest.approx(0.010, abs=0.001) and third.spread == pytest.approx(0.020, abs=0.001)
    assert third.text == "Bar 3, unsteady: placement +10.0 ms, spread 20.0 ms, 4 notes"


def test_a_take_uneven_throughout_has_no_weak_spot_and_a_few_milliseconds_are_none():
    assert tr_.steadiness(0.030, 0.025) == tr_.STEADY
    assert tr_.steadiness(0.007, 0.002) == tr_.STEADY
    assert tr_.steadiness(0.0081, 0.005) == tr_.UNSTEADY
