"""The practice metronome, a port of Sources/CSparkRT/metronome.c and Sources/SparkCore/MetronomeSettings.swift.

Timing: a pulse lies at ``anchor + k * interval`` output frames, a product and never a running sum; a new anchor is set
only where the interval changes (a new tempo from the window or the trainer, a new subdivision), at that pulse's exact
position. Each click starts at the pulse's fraction of a frame: its oscillator and envelope begin already advanced by
the part of a frame between the pulse and its first sample. New settings take effect on the next beat.

The samples go to ``pw-cat`` through a pipe of one page, so writing blocks until PipeWire has taken the previous
block: the device's own clock paces the renderer, which can then neither run ahead nor drift away from it.
"""
from __future__ import annotations

import fcntl
import json
import math
import os
import subprocess
import threading
import time
from dataclasses import dataclass, field

import numpy as np

MUTE, SOFT, NORMAL, ACCENT = 0, 1, 2, 3
LEVEL_GAIN = (0.0, 0.4, 0.7, 1.0)
MAX_BEATS = 16
BPM_RANGE = (20.0, 400.0)
END_LEVEL = 0.0005

# accent, beat and subdivision frequency, decay, and an inharmonic partial (ratio, level, decay) for the wood sound
SOUNDS = (
    (1760.0, 1175.0, 1175.0, 0.012, 0.0, 0.0, 0.0),   # classic: the recorder's click
    (1650.0, 1250.0, 1250.0, 0.006, 2.76, 0.45, 0.003),
    (1000.0, 800.0, 800.0, 0.045, 0.0, 0.0, 0.0),
)


def _clamp(value, low, high):
    return min(max(value, low), high)


@dataclass
class Pattern:
    levels: list[int] = field(default_factory=list)
    subdivision: int = 1  # pulses per beat: 1, 2, 3 or 4
    subdivision_level: float = 0.6
    sound: int = 0  # 0 classic, 1 wood, 2 beep

    def levels_for(self, beats: int) -> list[int]:
        return [self.levels[i] if i < len(self.levels) else (ACCENT if i == 0 else NORMAL) for i in range(max(beats, 1))]

    def setting(self, level: int, beat: int, beats: int) -> "Pattern":
        levels = self.levels_for(max(beats, beat + 1))
        levels[beat] = level
        return Pattern(levels, self.subdivision, self.subdivision_level, self.sound)

    @staticmethod
    def next_level(level: int) -> int:
        """Click on a beat lamp: accent → normal → soft → silent → accent."""
        return {ACCENT: NORMAL, NORMAL: SOFT, SOFT: MUTE, MUTE: ACCENT}[level]


@dataclass
class Trainer:
    is_on: bool = False
    step_bpm: float = 2.0
    every_bars: int = 4
    target_bpm: float = 140.0

    def tempo_after(self, bars: int, start: float) -> float:
        if not self.is_on or self.step_bpm == 0 or self.every_bars < 1:
            return start
        up = self.target_bpm >= start
        raw = start + (bars // self.every_bars) * (abs(self.step_bpm) if up else -abs(self.step_bpm))
        return min(raw, self.target_bpm) if up else max(raw, self.target_bpm)


@dataclass
class Settings:
    """The same JSON as the Mac's MetronomeSettings, so a piece's meter means the same on both."""
    bpm: float = 90.0
    beats_per_bar: int = 4
    volume: float = 0.6
    pattern: Pattern = field(default_factory=Pattern)
    trainer: Trainer = field(default_factory=Trainer)
    # The recording's click (area Record): bars counted in before a take, and the click on while recording.
    count_in_bars: int = 0
    click_enabled: bool = False

    @property
    def levels(self) -> list[int]:
        return self.pattern.levels_for(self.beats_per_bar)

    @property
    def count_in_beats(self) -> int:
        return self.count_in_bars * self.beats_per_bar

    def to_json(self) -> dict:
        return {"bpm": self.bpm, "beatsPerBar": self.beats_per_bar, "volume": self.volume,
                "countInBars": self.count_in_bars, "clickEnabled": self.click_enabled,
                "pattern": pattern_json(self.pattern),
                "trainer": {"isOn": self.trainer.is_on, "stepBPM": self.trainer.step_bpm,
                            "everyBars": self.trainer.every_bars, "targetBPM": self.trainer.target_bpm}}

    @classmethod
    def from_json(cls, data) -> "Settings":
        if not isinstance(data, dict):
            return cls()
        trainer = data.get("trainer") if isinstance(data.get("trainer"), dict) else {}
        return cls(bpm=float(data.get("bpm", 90)), beats_per_bar=int(data.get("beatsPerBar", 4)),
                   volume=float(data.get("volume", 0.6)), pattern=pattern_from_json(data.get("pattern")),
                   count_in_bars=min(max(int(data.get("countInBars", 0) or 0), 0), 2),
                   click_enabled=bool(data.get("clickEnabled", False)),
                   trainer=Trainer(bool(trainer.get("isOn", False)), float(trainer.get("stepBPM", 2)),
                                   int(trainer.get("everyBars", 4)), float(trainer.get("targetBPM", 140))))


def pattern_json(pattern: Pattern) -> dict:
    return {"levels": list(pattern.levels), "subdivision": pattern.subdivision,
            "subdivisionLevel": pattern.subdivision_level, "sound": pattern.sound}


def pattern_from_json(data) -> Pattern:
    if not isinstance(data, dict):
        return Pattern()
    levels = [int(v) for v in data.get("levels", []) if isinstance(v, (int, float)) and 0 <= int(v) <= ACCENT]
    return Pattern(levels, int(_clamp(int(data.get("subdivision", 1)), 1, 4)),
                   float(_clamp(float(data.get("subdivisionLevel", 0.6)), 0, 1)), int(_clamp(int(data.get("sound", 0)), 0, 2)))


@dataclass
class Config:
    """What the renderer plays, checked and in range; the trainer's direction follows from where its target lies."""
    bpm: float
    beats: int
    levels: list[int]
    subdivision: int
    subdivision_level: float
    volume: float
    sound: int
    trainer_step: float
    trainer_every: int
    trainer_target: float

    @classmethod
    def of(cls, s: Settings) -> "Config":
        bpm = _clamp(s.bpm, *BPM_RANGE)
        beats = int(_clamp(s.beats_per_bar, 1, MAX_BEATS))
        t = s.trainer
        step = 0.0
        if t.is_on and t.step_bpm and t.target_bpm != bpm:
            step = abs(t.step_bpm) if t.target_bpm > bpm else -abs(t.step_bpm)
        return cls(bpm, beats, s.pattern.levels_for(beats), int(_clamp(s.pattern.subdivision, 1, 8)),
                   _clamp(s.pattern.subdivision_level, 0, 1), _clamp(s.volume, 0, 1), int(_clamp(s.pattern.sound, 0, 2)),
                   step, max(int(t.every_bars), 1), _clamp(t.target_bpm, *BPM_RANGE))


@dataclass
class Pulse:
    bar: int
    beat: int
    sub: int
    bpm: float
    frame: float  # output frame since the start, with its fraction


class _Voice:
    __slots__ = ("start", "phase", "step", "env", "decay", "amp", "phase2", "step2", "env2", "decay2", "amp2")


class Renderer:
    """Places pulses and renders them, block by block, like the C renderer on the Mac."""

    def __init__(self, rate: float, settings: Settings):
        self.rate = float(rate)
        self.config = Config.of(settings)
        self._waiting: Config | None = None
        self.frame = 0
        self.bar = self.beat = self.sub = 0
        self.bars_since_step = 0
        self.voices: list[_Voice] = []
        self.events: list[Pulse] = []
        self._set_tempo(self.config.bpm, 0.0)

    def configure(self, settings: Settings) -> None:
        """Takes effect on the next beat; the trainer starts again from the new tempo. Thread-safe enough: one
        reference is swapped."""
        self._waiting = Config.of(settings)

    @property
    def bpm(self) -> float:
        return self._bpm

    def _set_tempo(self, bpm: float, anchor: float) -> None:
        self._bpm = bpm
        self.interval = self.rate * 60.0 / bpm / self.config.subdivision
        self.anchor = anchor
        self.k = 0

    def _apply_waiting(self) -> None:
        position = self.anchor + self.k * self.interval
        self.config, self._waiting = self._waiting, None
        self.bars_since_step = 0
        if self.beat >= self.config.beats:
            self.beat = 0
            self.bar += 1
        self._set_tempo(self.config.bpm, position)

    def _place(self, frames: int, with_sound: bool) -> None:
        end = self.frame + frames
        for _ in range(4096):
            if self._waiting is not None and self.sub == 0:
                self._apply_waiting()
            position = self.anchor + self.k * self.interval
            if math.ceil(position) >= end:
                break
            c = self.config
            sound = SOUNDS[c.sound]
            if self.sub == 0:
                level = c.levels[self.beat]
                amp, freq = LEVEL_GAIN[level], (sound[0] if level == ACCENT else sound[1])
            else:
                amp, freq = LEVEL_GAIN[NORMAL] * c.subdivision_level, sound[2]
            if with_sound:
                self._start_voice(position, amp * c.volume, freq, sound)
            self.events.append(Pulse(self.bar, self.beat, self.sub, self._bpm, position))
            self.k += 1
            self.sub += 1
            if self.sub < c.subdivision:
                continue
            self.sub = 0
            self.beat += 1
            if self.beat < c.beats:
                continue
            self.beat = 0
            self.bar += 1
            self.bars_since_step += 1
            if c.trainer_step and self.bars_since_step >= c.trainer_every:
                self.bars_since_step = 0
                nxt = self._bpm + c.trainer_step
                if (c.trainer_step > 0 and nxt > c.trainer_target) or (c.trainer_step < 0 and nxt < c.trainer_target):
                    nxt = c.trainer_target
                if nxt != self._bpm:
                    self._set_tempo(nxt, self.anchor + self.k * self.interval)

    def _start_voice(self, position: float, amp: float, freq: float, sound) -> None:
        if amp <= 0:
            return
        first = math.ceil(position)
        before = first - position
        tau, ratio2, level2, tau2 = sound[3], sound[4], sound[5], sound[6]
        v = _Voice()
        v.start = max(first - self.frame, 0)
        v.step = 2 * math.pi * freq / self.rate
        v.phase = v.step * before
        v.decay = math.exp(-1 / (tau * self.rate))
        v.env = math.exp(-before / (tau * self.rate))
        v.amp = amp
        v.amp2 = 0.0
        if ratio2:
            v.step2 = v.step * ratio2
            v.phase2 = v.step2 * before
            v.decay2 = math.exp(-1 / (tau2 * self.rate))
            v.env2 = math.exp(-before / (tau2 * self.rate))
            v.amp2 = amp * level2
        self.voices.append(v)

    def render(self, frames: int) -> np.ndarray:
        out = np.zeros(frames, dtype=np.float64)
        self._place(frames, True)
        alive = []
        for v in self.voices:
            start = min(v.start, frames)
            n = frames - start
            k = np.arange(n, dtype=np.float64)
            env = v.env * v.decay ** k
            env2 = v.env2 * v.decay2 ** k if v.amp2 else None
            # Ends on the sample where it fades out, whatever the block size.
            quiet = env < END_LEVEL if env2 is None else (env < END_LEVEL) & (env2 < END_LEVEL)
            stop = int(np.argmax(quiet)) if quiet.any() else n
            sample = np.sin(v.phase + v.step * k[:stop]) * env[:stop] * v.amp
            if env2 is not None:
                sample += np.sin(v.phase2 + v.step2 * k[:stop]) * env2[:stop] * v.amp2
            out[start:start + stop] += sample
            if stop == n:
                v.phase = math.fmod(v.phase + v.step * n, 2 * math.pi)
                v.env *= v.decay ** n
                if v.amp2:
                    v.phase2 = math.fmod(v.phase2 + v.step2 * n, 2 * math.pi)
                    v.env2 *= v.decay2 ** n
                v.start = 0
                alive.append(v)
        self.voices = alive
        self.frame += frames
        return np.clip(out, -1, 1).astype(np.float32)

    def advance(self, frames: int) -> None:
        """Places pulses without sound, for checking the timing of long runs quickly."""
        self._place(frames, False)
        self.frame += frames


class Player:
    """Streams the renderer to ``pw-cat``. Not tied to Qt: the window polls ``heard_pulse``."""
    RATE = 48000
    BLOCK = 256

    def __init__(self, settings: Settings, command=None):
        self.renderer = Renderer(self.RATE, settings)
        self._command = command or ["pw-cat", "-p", "--raw", "--rate", str(self.RATE), "--channels", "1",
                                    "--format", "f32", "--latency", "20ms", "--media-role", "Music", "-"]
        self._proc: subprocess.Popen | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._pulses: list[tuple[float, Pulse]] = []
        self.error: str | None = None
        # pw-cat's own buffer between the pipe and the speaker, added to every pulse's time.
        self.latency = 0.020

    @property
    def is_running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(self) -> None:
        self.stop()
        self._stop.clear()
        self._proc = subprocess.Popen(self._command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL)
        try:
            # One page: a write returns only once PipeWire took the block before, so the device paces us.
            fcntl.fcntl(self._proc.stdin.fileno(), 1031, 4096)  # F_SETPIPE_SZ
        except OSError:
            pass
        self._thread = threading.Thread(target=self._run, name="metronome", daemon=True)
        self._thread.start()

    def configure(self, settings: Settings) -> None:
        self.renderer.configure(settings)

    def _run(self) -> None:
        stdin = self._proc.stdin
        fd = stdin.fileno()
        try:
            while not self._stop.is_set():
                block = self.renderer.render(self.BLOCK)
                os.write(fd, block.tobytes())
                # What is still waiting in the pipe, in frames: the block just written is heard after it.
                waiting = _pipe_frames(fd)
                now = time.monotonic()
                block_end = self.renderer.frame
                events, self.renderer.events = self.renderer.events, []
                with self._lock:
                    for pulse in events:
                        ahead = (waiting - (block_end - pulse.frame)) / self.RATE
                        self._pulses.append((now + max(ahead, 0) + self.latency, pulse))
        except (BrokenPipeError, OSError, ValueError) as error:
            if not self._stop.is_set():
                self.error = str(error)

    def heard_pulse(self, now: float | None = None) -> Pulse | None:
        """The last pulse whose time to be heard has come; older ones are dropped."""
        now = time.monotonic() if now is None else now
        with self._lock:
            heard = None
            while self._pulses and self._pulses[0][0] <= now:
                heard = self._pulses.pop(0)[1]
            return heard

    @property
    def playing_bpm(self) -> float:
        return self.renderer.bpm

    def stop(self) -> None:
        self._stop.set()
        if self._proc is not None:
            try:
                self._proc.stdin.close()
            except OSError:
                pass
            try:
                self._proc.terminate()
                self._proc.wait(timeout=1)
            except (OSError, subprocess.TimeoutExpired):
                self._proc.kill()
        if self._thread is not None:
            self._thread.join(timeout=1)
        self._proc = None
        self._thread = None
        with self._lock:
            self._pulses = []


def _pipe_frames(fd: int) -> int:
    try:
        import termios
        buf = fcntl.ioctl(fd, termios.FIONREAD, b"\0\0\0\0")
        return int.from_bytes(buf, "little") // 4
    except (OSError, ImportError):
        return 0


def load_settings(qsettings) -> Settings:
    try:
        return Settings.from_json(json.loads(qsettings.value("metronome", "{}")))
    except (TypeError, ValueError):
        return Settings()


def save_settings(qsettings, settings: Settings) -> None:
    qsettings.setValue("metronome", json.dumps(settings.to_json()))
