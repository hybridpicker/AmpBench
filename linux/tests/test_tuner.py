"""The tuner's precision and behaviour, with synthetic signals only (spark_studio/tuner_signal.py). A port of
Tests/SparkCoreTests/TunerAccuracyTests.swift and TunerBehaviorTests.swift. No test reads a recording or an input."""
import math

import numpy as np
import pytest

from spark_studio import tuner_signal as signals
from spark_studio.pitch import PitchTracker
from spark_studio.tuning import (Note, PitchReading, Tuning, TunerInterpreter, cents_text, hertz_text,
                                 spoken_cents)

RATE = 48_000.0


def track(signal, sample_rate=RATE, block=256):
    """Feeds a signal in blocks, as audio arrives, and notes the reading after each."""
    tracker = PitchTracker(sample_rate)
    timeline = []
    for start in range(0, len(signal), block):
        tracker.process(signal[start:start + block])
        timeline.append((tracker.seconds, tracker.reading))
    return tracker, timeline


def cents(value, reference):
    return 1200 * math.log2(value / reference)


def errors(timeline, truth, start, end):
    return [cents(r.frequency, truth) for t, r in timeline if start <= t <= end and r is not None and not r.is_held]


# MARK: Precision


@pytest.mark.parametrize("frequency", [30, 41.2, 82.41, 110, 196, 329.63, 659.26, 1318.51, 1400])
@pytest.mark.parametrize("rate", [44_100.0, 48_000.0])
def test_sine_within_a_tenth_of_a_cent(frequency, rate):
    truth = frequency * 2 ** (3.7 / 1200)
    _, timeline = track(signals.sine(truth, rate, 1.6), rate)
    found = errors(timeline, truth, 0.8, 1.6)
    assert found, "no reading"
    assert max(map(abs, found)) <= 0.1


@pytest.mark.parametrize("frequency", [30.87, 82.41, 196, 659.26, 1318.51])
def test_decaying_sawtooth_in_noise(frequency):
    truth = frequency * 2 ** (-6.2 / 1200)
    signal = signals.adding_noise(signals.sawtooth(truth, RATE, 3, decay=1.6), -30)
    _, timeline = track(signal)
    found = errors(timeline, truth, 0.6, 2.6)
    assert len(found) > 100
    assert max(map(abs, found)) <= 0.5


@pytest.mark.parametrize("frequency", [41.2, 82.41, 110, 246.94, 659.26])
def test_plucked_string_in_noise(frequency):
    truth = frequency * 2 ** (4.4 / 1200)
    clean = signals.karplus_strong(truth, RATE, 2.5, ring_time=2.5 if frequency > 600 else 4.0)
    _, timeline = track(signals.adding_noise(clean, -30))
    found = errors(timeline, truth, 1.0 if frequency < 50 else 0.6, 2.0)
    assert len(found) > 30
    assert max(map(abs, found)) <= 0.5


def test_held_tone_stays_within_two_tenths_of_a_cent():
    for frequency in (82.41, 196, 987.77):
        signal = signals.adding_noise(signals.sawtooth(frequency, RATE, 3), -30, seed=23)
        _, timeline = track(signal)
        found = errors(timeline, frequency, 1, 3)
        mean = sum(found) / len(found)
        assert max(abs(e - mean) for e in found) <= 0.2


def test_no_octave_error_while_a_low_string_rings_out():
    for frequency, ring in ((82.41, 5.0), (41.2, 6.0)):
        clean = signals.karplus_strong(frequency, RATE, 6, ring_time=ring, seed=3)
        tracker, timeline = track(signals.adding_noise(clean, -30, seed=5))
        assert tracker.lock_count == 1, "locked once and never jumped to another pitch"
        readings = [r for _, r in timeline if r is not None]
        assert readings and max(abs(cents(r.frequency, frequency)) for r in readings) < 50


def test_weak_fundamental_is_not_read_as_its_octave():
    t = np.arange(int(2 * RATE)) / RATE
    for frequency in (41.2, 110):
        signal = (0.1 * np.sin(2 * np.pi * frequency * t) + 0.2 * np.sin(2 * np.pi * 2 * frequency * t + 0.4)
                  + 0.12 * np.sin(2 * np.pi * 3 * frequency * t + 1.1)
                  + 0.08 * np.sin(2 * np.pi * 4 * frequency * t)) * np.exp(-t / 1.5)
        _, timeline = track(signal.astype(np.float32))
        readings = [r for _, r in timeline if r is not None]
        assert readings and all(abs(cents(r.frequency, frequency)) < 50 for r in readings)


# MARK: Response and behaviour


@pytest.mark.parametrize("rate", [44_100.0, 48_000.0])
def test_first_value_of_a_low_e_in_under_120_ms(rate):
    lead = 0.5
    signal = np.concatenate((signals.silence(rate, lead),
                             signals.adding_noise(signals.karplus_strong(82.41, rate, 1), -30)))
    _, timeline = track(signal, rate, block=128)
    first = next(((t, r) for t, r in timeline if r is not None), None)
    assert first is not None
    assert first[0] - lead < 0.12
    assert abs(cents(first[1].frequency, 82.41)) < 50


def test_new_attack_moves_to_the_new_note_quickly():
    first = signals.karplus_strong(82.41, RATE, 1.5)
    second = signals.karplus_strong(110, RATE, 1.5, seed=9)
    signal = np.concatenate((first, np.zeros(len(second), dtype=np.float32)))
    signal[len(first):] += second * 1.4
    tracker, timeline = track(signals.adding_noise(signal, -40))
    assert tracker.attack_count >= 2
    arrived = next((t for t, r in timeline if t > 1.5 and r is not None and abs(cents(r.frequency, 110)) < 5), 99)
    assert arrived - 1.5 < 0.15
    for t, r in timeline:
        if t > 1.5 and r is not None:
            assert abs(cents(r.frequency, 82.41)) < 50 or abs(cents(r.frequency, 110)) < 50


def test_follows_a_turning_peg_and_settles():
    target, count = 110.0, int(3 * RATE)
    t = np.arange(count) / RATE
    offset = np.where(t < 0.5, -20.0, np.where(t < 1.5, -20 + 20 * (t - 0.5), 0.0))
    truth = target * 2 ** (offset / 1200)
    phase = np.cumsum(2 * np.pi * truth / RATE)
    signal = (0.3 * np.sin(phase) + 0.1 * np.sin(2 * phase + 0.3) + 0.05 * np.sin(3 * phase)).astype(np.float32)
    _, timeline = track(signals.adding_noise(signal, -30))
    for time, reading in timeline:
        if 0.8 < time < 1.5 and reading is not None:
            assert abs(cents(reading.frequency, truth[int((time - 0.15) * RATE)])) < 2, f"lags behind at {time}"
    assert max(map(abs, errors(timeline, target, 2, 3))) <= 0.2


def test_last_value_stays_briefly_after_the_tone_ends():
    signal = np.concatenate((signals.karplus_strong(196, RATE, 1), signals.silence(RATE, 3)))
    _, timeline = track(signal)
    held = [r for t, r in timeline if 1.1 < t < 2.3]
    assert held and all(r is not None and r.is_held for r in held)
    assert abs(cents(held[-1].frequency, 196)) < 0.5
    assert all(r is None for t, r in timeline if t > 3)


def test_no_value_without_a_tone():
    generator = signals.SeededGenerator(1)
    noise = np.array([0.1 * generator.gaussian() for _ in range(int(2 * RATE))], dtype=np.float32)
    quiet = signals.sine(220, RATE, 1, amplitude=0.0005)
    for signal in (noise, signals.silence(RATE, 1), quiet):
        _, timeline = track(signal)
        assert all(r is None for _, r in timeline)
    tracker, _ = track(quiet)
    assert not tracker.has_signal, "−66 dBFS stays below the gate"


def test_offset_does_not_hide_the_pitch():
    signal = signals.sine(82.41, RATE, 1.5, amplitude=0.2) + 0.3
    _, timeline = track(signal)
    assert max(map(abs, errors(timeline, 82.41, 1, 1.5))) <= 0.1


# MARK: Tunings, notes, text


def test_every_string_of_every_tuning_is_found():
    for tuning in Tuning.all():
        if tuning.key == "chromatic":
            continue
        interpreter = TunerInterpreter(tuning)
        for index, note in enumerate(tuning.strings):
            readout = interpreter.interpret(PitchReading(note.frequency(440) * 2 ** (12 / 1200), uncertainty=0.05), 0)
            assert readout.note == note and readout.string == 6 - index
            assert readout.cents == pytest.approx(12) and readout.direction == "high"


def test_tunings_are_what_they_are_called():
    summaries = {t.key: t.summary for t in Tuning.all()}
    assert summaries == {"standard": "E A D G H E", "dropD": "D A D G H E", "dadgad": "D A D G A D",
                         "openG": "D G D G H D", "halfStepDown": "E♭ A♭ D♭ G♭ B E♭", "chromatic": "Alle Töne"}
    assert Tuning("standard").strings[0].frequency(440) == pytest.approx(82.4069, abs=1e-4)


def test_chromatic_names_in_german():
    interpreter = TunerInterpreter(Tuning("chromatic"))
    for frequency, name, octave in ((30.868, "H", 0), (246.94, "H", 3), (233.08, "A♯", 3), (440, "A", 4),
                                    (277.18, "C♯", 4), (1396.91, "F", 6)):
        readout = interpreter.interpret(PitchReading(frequency), 0)
        assert (readout.note_name, readout.note.octave) == (name, octave)
        assert abs(readout.cents) < 0.1
    assert Note(70).name(flats=True) == "B" and Note(63).spoken_name(flats=True) == "Es"
    assert Note(66).spoken_name() == "Fis"


def test_note_stays_put_at_the_border_between_two():
    interpreter = TunerInterpreter(Tuning("chromatic"))
    a = Note(57).frequency(440)
    assert interpreter.interpret(PitchReading(a * 2 ** (45 / 1200)), 0).note_name == "A"
    assert interpreter.interpret(PitchReading(a * 2 ** (55 / 1200)), 0.1).note_name == "A"
    assert interpreter.interpret(PitchReading(a * 2 ** (65 / 1200)), 0.2).note_name == "A♯"


def test_in_tune_needs_time_and_precision():
    interpreter = TunerInterpreter(Tuning("standard"))
    e = 82.4069
    near = PitchReading(e * 2 ** (0.3 / 1200), uncertainty=0.05)
    assert [interpreter.interpret(near, t).is_in_tune for t in (0, 0.3, 0.45)] == [False, False, True]
    assert not interpreter.interpret(PitchReading(e * 2 ** (0.8 / 1200), uncertainty=0.05), 0.5).is_in_tune
    rough = TunerInterpreter(Tuning("standard"))
    rough.interpret(PitchReading(e, uncertainty=0.6), 0)
    assert not rough.interpret(PitchReading(e, uncertainty=0.6), 1).is_in_tune


def test_text_of_the_numbers():
    assert [cents_text(v) for v in (0.34, -12.04, -0.04, 49.96)] == ["+0,3", "−12,0", "±0,0", "+50,0"]
    assert hertz_text(82.4069) == "82,41" and hertz_text(440, 1) == "440,0"
    assert spoken_cents(-2.25) == "minus 2,3 Cent"
