"""The timing band below the waveform: a few bars of a take's timing review, each grid point magnified.

A port of Sources/SparkCore/TimingBand.swift. The band is a row of equal cells, one per grid point of the bars it
shows; the click line of a grid point stands fixed in the middle of its cell with its beat number, the onsets are
strokes beside it, as far off as they were played. Positions are pixels from the band's left edge.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

from .beat_grid import BeatGrid
from .i18n import tr
from .timing_review import EIGHTHS, QUARTERS, TRIPLETS, Bar, GridPoints, TimingReview

REACH = 0.060  # how far each side of its click line a cell reaches, less where grid points lie closer


@dataclass
class Point:
    bar: int
    beat: int  # from 1
    step: int  # 0 on the beat, 1 for the next grid point …
    x: float

    @property
    def number(self) -> int | None:
        return self.beat if self.step == 0 else None


@dataclass
class Stroke:
    x: float
    offset: float
    is_counted: bool
    label: str | None
    short_label: str | None
    is_past_the_cell: bool
    point: int  # index of its grid point in ``points``


@dataclass
class BarSpan:
    bar: int
    left: float
    width: float
    reviewed: Bar | None = None

    @property
    def steadiness(self) -> str | None:
        return self.reviewed.steadiness if self.reviewed else None


def label(offset: float) -> str:
    return tr("{} ms", short_label(offset))


def short_label(offset: float) -> str:
    value = int(math.floor(offset * 1000 + 0.5)) if offset >= 0 else -int(math.floor(-offset * 1000 + 0.5))
    return f"{value:+d}"


class TimingBand:
    def __init__(self, review: TimingReview, grid: BeatGrid, bars: tuple[int, int], width: float):
        first_bar, last_bar = bars
        self.bars, self.width, self.resolution = bars, width, review.resolution
        take = GridPoints(grid, review.resolution)
        per_beat, per_bar = take.points_per_beat, take.points_per_bar
        count = (last_bar - first_bar + 1) * per_bar
        self.cell_width = cell = width / max(count, 1)
        self.points = [Point(first_bar + i // per_bar, (i % per_bar) // per_beat + 1, (i % per_bar) % per_beat,
                             (i + 0.5) * cell) for i in range(count)]
        self.bar_spans = [BarSpan(bar, index * per_bar * cell, per_bar * cell,
                                  next((b for b in review.bars if b.number == bar), None))
                          for index, bar in enumerate(range(first_bar, last_bar + 1))]
        reach = min(REACH, take.spacing / 2)
        first_point = take.first_of_bar(first_bar)
        self.cell_reach, self._spacing = reach, take.spacing
        self._first_time = take.time(first_point)
        self.strokes = []
        for onset in review.onsets:
            point = onset.grid_point if onset.grid_point is not None else take.nearest(onset.time)
            index = point - first_point
            if not 0 <= index < count:
                continue
            offset = onset.offset if onset.offset is not None else onset.time - take.time(point)
            shift = min(max(offset / reach, -1.0), 1.0) * cell / 2
            self.strokes.append(Stroke((index + 0.5) * cell + shift, offset, onset.is_counted,
                                       label(offset) if onset.is_counted else None,
                                       short_label(offset) if onset.is_counted else None,
                                       abs(offset) > reach, index))

    def x(self, seconds: float) -> float | None:
        """Where a moment of the file lies in the band, only within a cell: the band shows no time between them."""
        raw = (seconds - self._first_time) / self._spacing
        index = int(math.floor(raw + 0.5)) if raw >= 0 else -int(math.floor(-raw + 0.5))
        offset = seconds - (self._first_time + index * self._spacing)
        if not 0 <= index < len(self.points) or abs(offset) > self.cell_reach:
            return None
        return (index + 0.5 + offset / self.cell_reach / 2) * self.cell_width

    @property
    def spoken(self) -> str:
        """What a screen reader reads: the bars shown, then every counted note by its place and offset."""
        a, b = self.bars
        shown = tr("Bar {}", a) if a == b else tr("Bars {}–{}", a, b)
        notes = [self._place(self.points[s.point], s.label) for s in self.strokes if s.label]
        if not notes:
            return tr("{}, no counted notes", shown)
        return tr("{}: {}", shown, ", ".join(notes))

    def _place(self, point: Point, offset: str) -> str:
        if point.step == 0:
            return tr("bar {} beat {} {}", point.bar, point.beat, offset)
        if self.resolution in (QUARTERS, EIGHTHS):
            return tr("bar {} beat {} and {}", point.bar, point.beat, offset)
        if self.resolution == TRIPLETS:
            return tr("bar {} beat {} triplet {} {}", point.bar, point.beat, point.step + 1, offset)
        return tr("bar {} beat {} sixteenth {} {}", point.bar, point.beat, point.step + 1, offset)


def pair_at(seconds: float, grid: BeatGrid, last_bar: int) -> tuple[int, int]:
    """The two bars the band shows with the playhead at ``seconds``: bars go in pairs from the take's first bar, so
    the band stands still while a pair plays and turns over at the next."""
    position = grid.position(seconds)
    return _pair(position.bar if position else grid.first_bar, grid.first_bar, last_bar)


def pair_showing(first_chosen: int, grid: BeatGrid, last_bar: int) -> tuple[int, int]:
    return _pair(first_chosen, grid.first_bar, last_bar)


def _pair(bar: int, first_bar: int, last_bar: int) -> tuple[int, int]:
    last = max(last_bar, first_bar)
    bar = min(max(bar, first_bar), last)
    start = first_bar + (bar - first_bar) // 2 * 2
    end = min(start + 1, last)
    return max(end - 1, first_bar), end
