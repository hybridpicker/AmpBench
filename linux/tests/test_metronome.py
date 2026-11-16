"""The practice metronome's renderer: the same checks as Tests/SparkCoreTests/MetronomeTests.swift."""
import json
import math
import time

import numpy as np

from ampbench import metronome as m


def run(settings, seconds, rate=48000, blocks=(512,), changes=()):
    r = m.Renderer(rate, settings)
    total, done, i, pending = int(seconds * rate), 0, 0, list(changes)
    parts = []
    while done < total:
        if pending and pending[0][0] <= done:
            r.configure(pending.pop(0)[1])
        n = min(blocks[i % len(blocks)], total - done)
        i += 1
        parts.append(r.render(n))
        done += n
    return np.concatenate(parts), r.events


def test_every_beat_lies_exactly_on_its_frame_for_hours():
    r = m.Renderer(44100, m.Settings(bpm=97, beats_per_bar=4))
    for _ in range(2 * 3600):
        r.advance(44100)
    interval = 44100 * 60 / 97
    assert len(r.events) > 11_000
    worst = max(abs(e.frame - i * interval) for i, e in enumerate(r.events))
    assert worst < 1e-6
    assert [e.beat for e in r.events[:6]] == [0, 1, 2, 3, 0, 1]


def test_the_sound_does_not_depend_on_the_block_size():
    s = m.Settings(bpm=133, beats_per_bar=7, pattern=m.Pattern(subdivision=3, sound=1))
    small, _ = run(s, 6, blocks=(64, 7, 333))
    large, _ = run(s, 6, blocks=(4096,))
    assert len(small) == len(large)
    assert float(np.max(np.abs(small - large))) < 1e-5


def test_a_click_starts_at_the_fraction_of_a_frame_where_its_beat_lies():
    rate = 48000
    samples, events = run(m.Settings(bpm=133, volume=1), 3)
    second = events[1]
    assert abs(second.frame - rate * 60 / 133) < 1e-9
    first = math.ceil(second.frame)
    for n in range(first, first + 40):
        t = (n - second.frame) / rate
        expected = 0.7 * math.sin(2 * math.pi * 1175 * t) * math.exp(-t / 0.012)
        assert abs(samples[n] - expected) < 2e-5
    assert abs(samples[first - 1]) < 1e-6


def test_subdivisions_lie_between_the_beats():
    _, events = run(m.Settings(bpm=100, beats_per_bar=3, pattern=m.Pattern(subdivision=3)), 10, blocks=(300,))
    interval = 48000 * 60 / 100 / 3
    for i, e in enumerate(events):
        assert abs(e.frame - i * interval) < 1e-9
        assert e.sub == i % 3 and e.beat == (i // 3) % 3


def test_accents_soft_and_muted_beats():
    s = m.Settings(bpm=120, volume=1, pattern=m.Pattern(levels=[m.ACCENT, m.NORMAL, m.SOFT, m.MUTE]))
    samples, events = run(s, 2.1)
    peak = [float(np.max(np.abs(samples[b * 24000:b * 24000 + 2000]))) for b in range(4)]
    assert abs(peak[0] - 1.0) < 0.02 and abs(peak[1] - 0.7) < 0.02 and abs(peak[2] - 0.4) < 0.02
    assert peak[3] < 1e-6
    assert sum(1 for e in events if e.bar == 0) == 4


def test_the_trainer_raises_the_tempo_on_bar_lines_up_to_its_target():
    trainer = m.Trainer(True, 5, 2, 112)
    s = m.Settings(bpm=100, beats_per_bar=4, trainer=trainer)
    _, events = run(s, 60, blocks=(480, 17))
    frame, expected = 0.0, []
    for bar in range(40):
        bpm = trainer.tempo_after(bar, 100)
        for _ in range(4):
            expected.append((frame, bpm))
            frame += 48000 * 60 / bpm
    for e, (position, bpm) in zip(events, expected):
        assert e.bpm == bpm
        assert abs(e.frame - position) < 1e-6
    assert events[-1].bpm == 112
    assert m.Trainer(True, 4, 1, 90).tempo_after(2, 100) == 92


def test_a_new_tempo_starts_on_the_next_beat():
    s = m.Settings(bpm=120, pattern=m.Pattern(subdivision=2))
    faster = m.Settings(bpm=150, pattern=m.Pattern(subdivision=2))
    _, events = run(s, 4, blocks=(256,), changes=[(36_100, faster)])
    assert abs(events[4].frame - 48000) < 1e-9
    assert events[3].bpm == 120 and events[4].bpm == 150
    assert abs(events[5].frame - events[4].frame - 48000 * 60 / 150 / 2) < 1e-9


def test_settings_read_the_macs_json():
    mac = {"bpm": 101, "beatsPerBar": 3, "volume": 0.5, "countInBars": 1, "clickEnabled": True,
           "pattern": {"levels": [3, 0, 2], "subdivision": 3, "subdivisionLevel": 0.4, "sound": 1},
           "trainer": {"isOn": True, "stepBPM": 2, "everyBars": 4, "targetBPM": 140}}
    s = m.Settings.from_json(json.loads(json.dumps(mac)))
    assert s.bpm == 101 and s.beats_per_bar == 3 and s.levels == [3, 0, 2]
    assert s.pattern.subdivision == 3 and s.pattern.sound == 1 and s.trainer.is_on
    assert m.Settings.from_json(s.to_json()) == s
    old = m.Settings.from_json({"bpm": 90, "beatsPerBar": 4})
    assert old.levels == [m.ACCENT, m.NORMAL, m.NORMAL, m.NORMAL] and not old.trainer.is_on


def test_a_beat_lamp_cycles_its_level():
    p = m.Pattern().setting(m.Pattern.next_level(m.ACCENT), 0, 4)
    assert p.levels_for(4) == [m.NORMAL] * 4
    assert m.Pattern.next_level(m.MUTE) == m.ACCENT


def test_the_player_streams_and_reports_pulses():
    player = m.Player(m.Settings(bpm=300), command=["cat"])
    player.latency = 0
    player.start()
    try:
        deadline = time.monotonic() + 3
        heard = None
        while heard is None and time.monotonic() < deadline:
            time.sleep(0.01)
            heard = player.heard_pulse(time.monotonic() + 10)
        assert heard is not None
        assert player.is_running
    finally:
        player.stop()
    assert not player.is_running
