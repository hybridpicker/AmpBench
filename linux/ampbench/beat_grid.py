"""The bars of a take recorded with the click, and the click mixed into playback.

A port of Sources/SparkCore/BeatGrid.swift (BeatGrid, BarPosition, PlaybackClick). The JSON keys are those of the Mac
app, so a take's ``grid`` reads the same on both machines.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

# A playhead sent to a bar line lands up to a frame before it, because file positions are whole frames. Half a
# millisecond covers every sample rate and is far below anything a player could hear as early.
LINE_TOLERANCE = 0.0005


@dataclass(frozen=True)
class BarPosition:
    bar: int
    beat: int


@dataclass(frozen=True)
class BeatGrid:
    bpm: float
    beats_per_bar: int
    offset: float  # where the first beat of first_bar lies in the file, in seconds; negative before the file
    first_bar: int = 1  # a passage recorded again keeps the numbers of the bars it replaces

    def __post_init__(self):
        object.__setattr__(self, "beats_per_bar", max(int(self.beats_per_bar), 1))

    @classmethod
    def from_json(cls, data) -> "BeatGrid | None":
        if not isinstance(data, dict):
            return None
        try:
            return cls(float(data["bpm"]), int(data.get("beatsPerBar", 4)), float(data.get("offset", 0)),
                       int(data.get("firstBar", 1)))
        except (KeyError, TypeError, ValueError):
            return None

    def to_json(self) -> dict:
        return {"bpm": self.bpm, "beatsPerBar": self.beats_per_bar, "offset": self.offset, "firstBar": self.first_bar}

    @property
    def seconds_per_beat(self) -> float:
        return 60 / self.bpm

    @property
    def seconds_per_bar(self) -> float:
        return self.seconds_per_beat * self.beats_per_bar

    def beat_index(self, seconds: float) -> int | None:
        """How many beats have started since the first one, minus one. None before the first beat."""
        elapsed = seconds - self.offset + LINE_TOLERANCE
        if elapsed < 0:
            return None
        return int(math.floor(elapsed / self.seconds_per_beat))

    def position(self, seconds: float) -> BarPosition | None:
        index = self.beat_index(seconds)
        if index is None:
            return None
        return BarPosition(self.first_bar + index // self.beats_per_bar, index % self.beats_per_bar + 1)

    def time_of_bar(self, bar: int) -> float:
        return self.offset + (bar - self.first_bar) * self.seconds_per_bar

    def last_bar(self, duration: float) -> int:
        """The bar that holds the end of the file. A bar cut off by the end still counts."""
        position = self.position(max(duration - 2 * LINE_TOLERANCE, self.offset))
        return position.bar if position else self.first_bar

    def loop_range(self, first: int, last: int, duration: float) -> tuple[float, float] | None:
        """The time span of whole bars, limited to the file. None when nothing of them lies in the file."""
        lower = max(self.time_of_bar(first), 0.0)
        upper = min(self.time_of_bar(last + 1), duration)
        if upper - lower < 0.05:
            return None
        return lower, upper

    def snapped_bars(self, lower: float, upper: float, duration: float) -> tuple[int, int]:
        """The whole bars a dragged time span touches. An end exactly on a bar line does not include the next bar."""
        last = self.last_bar(duration)
        start = self.position(lower)
        first = min(start.bar if start else self.first_bar, last)
        end_position = self.position(upper - 2 * LINE_TOLERANCE)
        end = min(end_position.bar if end_position else first, last)
        return first, max(first, end)


# The click mixed into playback: computed from the file position alone, so it stays on the grid across chunk
# boundaries, seeks and loop jumps. The same sound as the recording's click (native/ampbench-rt.c).
_DECAY = 0.012
_END_LEVEL = 0.001
_ACCENT = 1760.0
_BEAT = 1175.0


def mix_click(samples: np.ndarray, first_frame: int, sample_rate: float, grid: BeatGrid, volume: float) -> None:
    """Adds the click to ``samples`` (frames, or frames × channels) in place; ``first_frame`` is the file frame of
    the first row."""
    count = samples.shape[0]
    if count == 0 or sample_rate <= 0 or volume <= 0 or grid.bpm <= 0:
        return
    tail = -math.log(_END_LEVEL) * _DECAY
    start = first_frame / sample_rate
    beat = max(int(math.floor((start - tail - grid.offset) / grid.seconds_per_beat)), 0)
    end_frame = first_frame + count
    while True:
        beat_frame = int(round((grid.offset + beat * grid.seconds_per_beat) * sample_rate))
        if beat_frame >= end_frame:
            break
        accent = beat % grid.beats_per_bar == 0
        frequency = _ACCENT if accent else _BEAT
        amplitude = volume * (1.0 if accent else 0.7)
        last = min(beat_frame + int(tail * sample_rate), end_frame - 1)
        first = max(beat_frame, first_frame)
        if first <= last:
            elapsed = (np.arange(first, last + 1) - beat_frame) / sample_rate
            value = np.sin(2 * np.pi * frequency * elapsed) * np.exp(-elapsed / _DECAY) * amplitude
            rows = slice(first - first_frame, last + 1 - first_frame)
            if samples.ndim == 1:
                samples[rows] += value.astype(samples.dtype)
            else:
                samples[rows] += value.astype(samples.dtype)[:, None]
        beat += 1
