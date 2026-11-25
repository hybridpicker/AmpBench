"""The look at a finished take against its click: every onset with its offset, the placement and the spread.

A port of Sources/SparkCore/TimingReview.swift and TimingReview+Bars.swift, rule for rule: the onset detector, the
grid points, the catch windows, the numbers, the bars and the reasons for no review. It knows nothing of devices or
the window. Times are seconds in the file, offsets seconds with positive meaning later than the click.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .beat_grid import BeatGrid
from .click_timing import AIRPLAY, BLUETOOTH, TimingStamp
from .i18n import number, tr

CATCH_WINDOW = 0.35  # the share of the grid spacing a catch window reaches to each side of its grid point
MINIMUM_COUNTED = 8  # two bars of quarters (owner, 2026-11-24)
WORST_ACCURACY = 0.002
DETECTOR_UNCERTAINTY = 0.0005

QUARTERS, EIGHTHS, TRIPLETS, SIXTEENTHS = 1, 2, 3, 4  # grid points per beat, as the Mac stores them
RESOLUTIONS = (QUARTERS, EIGHTHS, TRIPLETS, SIXTEENTHS)


def resolution_name(resolution: int) -> str:
    return {QUARTERS: tr("Quarters"), EIGHTHS: tr("Eighths"), TRIPLETS: tr("Triplets"),
            SIXTEENTHS: tr("Sixteenths")}[resolution]


def resolution_notes(resolution: int, count: int) -> str:
    """How many notes the review counted, on this grid: "16 notes on eighths"."""
    return {QUARTERS: tr("{} notes on quarters", count), EIGHTHS: tr("{} notes on eighths", count),
            TRIPLETS: tr("{} notes on triplets", count), SIXTEENTHS: tr("{} notes on sixteenths", count)}[resolution]


# MARK: Onsets and the outcome

COUNTED, LATER_IN_WINDOW, OUTSIDE_WINDOWS, UNSURE = "counted", "laterInWindow", "outsideWindows", "unsure"


@dataclass
class Onset:
    time: float
    grid_point: int | None  # from the first beat of the bars, 0 on; None outside every window
    offset: float | None
    status: str

    @property
    def is_counted(self) -> bool:
        return self.status == COUNTED


DELAY_IN_THE_SOUND = "delayInTheSound"


def hint_text(hint: str) -> str:
    return tr("Delay in the sound: echoes may count as notes. For exact practice choose a dry sound.")


STEADY, UNSTEADY = "steady", "unsteady"
TIMES_THE_TAKE = 1.5
SMALLEST_UNSTEADY = 0.008


def steadiness(spread: float, take_spread: float) -> str:
    """A bar is unsteady when it spreads more than 1.5 times as much as the whole take and by more than 8 ms."""
    return UNSTEADY if spread > TIMES_THE_TAKE * take_spread and spread > SMALLEST_UNSTEADY else STEADY


def steadiness_word(value: str) -> str:
    return tr("steady") if value == STEADY else tr("unsteady")


@dataclass
class Bar:
    number: int
    counted: int
    placement: float | None = None
    spread: float | None = None
    steadiness: str | None = None

    @property
    def text(self) -> str:
        """What pointing at the bar shows and a screen reader reads."""
        if self.placement is None:
            return tr("Bar {}: no counted notes", self.number)
        if self.spread is None or self.steadiness is None:
            return tr("Bar {}: placement {} ms, a single note, too few to judge", self.number,
                      signed(self.placement * 1000))
        return tr("Bar {}, {}: placement {} ms, spread {} ms, {} notes", self.number, steadiness_word(self.steadiness),
                  signed(self.placement * 1000), number(self.spread * 1000, 1), self.counted)


@dataclass
class TimingReview:
    resolution: int
    onsets: list[Onset]
    placement: float
    spread: float
    counted: int
    hints: list[str]
    accuracy: float
    bars: list[Bar] = field(default_factory=list)


NO_BARS = "noBars"
RECORDED_BEFORE_THE_STAMP = "recordedBeforeTheStamp"
CLICK_NOT_ON_THROUGHOUT = "clickNotOnThroughout"
AMP_PART_NOT_MEASURED = "ampPartNotMeasured"
CLICK_ON_BLUETOOTH = "clickOnBluetooth"
CLICK_ON_AIRPLAY = "clickOnAirPlay"
ACCURACY_NOT_GOOD_ENOUGH = "accuracyNotGoodEnough"
TOO_FEW_ONSETS = "tooFewOnsets"
REASONS = (NO_BARS, RECORDED_BEFORE_THE_STAMP, CLICK_NOT_ON_THROUGHOUT, AMP_PART_NOT_MEASURED, CLICK_ON_BLUETOOTH,
           CLICK_ON_AIRPLAY, ACCURACY_NOT_GOOD_ENOUGH, TOO_FEW_ONSETS)


def reason_text(reason: str) -> str:
    """The one line the window shows instead of a review."""
    return {
        NO_BARS: tr("No timing review: recorded without the click."),
        RECORDED_BEFORE_THE_STAMP: tr("No timing review: recorded before the measurement."),
        CLICK_NOT_ON_THROUGHOUT: tr("No timing review: the click was not on for the whole take."),
        AMP_PART_NOT_MEASURED: tr("No timing review: click latency not measured."),
        CLICK_ON_BLUETOOTH: tr("No timing review: the click went to a Bluetooth output."),
        CLICK_ON_AIRPLAY: tr("No timing review: the click went to an AirPlay output."),
        ACCURACY_NOT_GOOD_ENOUGH: tr("No timing review: accuracy not good enough. Measure the click latency again."),
        TOO_FEW_ONSETS: tr("No timing review: too few clear notes."),
    }[reason]


@dataclass
class Outcome:
    review: TimingReview | None = None
    reason: str | None = None


def accuracy(stamp: TimingStamp) -> float | None:
    """Half the measurement's spread (the range from its earliest to its latest click) plus the detector's
    uncertainty; both are bounds, so they add up. None when the amp part was not measured."""
    amp = stamp.latency.amp
    if amp is None or not amp.measured:
        return None
    return amp.spread / 2 + DETECTOR_UNCERTAINTY


def accuracy_text(value: float) -> str:
    return tr("Accuracy ±{} ms", number(value * 1000, 1))


def signed(value: float, digits: int = 1) -> str:
    """With its sign, "+" from zero up (as %+.1f on the Mac), in the language's decimals."""
    return ("+" if value >= 0 else "-") + number(abs(value), digits)


def reason_before_listening(grid: BeatGrid | None, stamp: TimingStamp | None) -> str | None:
    """The reason known without the samples, so a window need not read the file for it."""
    if grid is None:
        return NO_BARS
    if stamp is None:
        return RECORDED_BEFORE_THE_STAMP
    if not stamp.click_on_throughout:
        return CLICK_NOT_ON_THROUGHOUT
    if stamp.latency.amp is None or not stamp.latency.amp.measured:
        return AMP_PART_NOT_MEASURED
    if stamp.latency.output_kind == BLUETOOTH:
        return CLICK_ON_BLUETOOTH
    if stamp.latency.output_kind == AIRPLAY:
        return CLICK_ON_AIRPLAY
    value = accuracy(stamp)
    # A tiny margin, so an accuracy that is 2 ms on paper is not refused for a rounding error.
    if value is None or value > WORST_ACCURACY + 1e-9:
        return ACCURACY_NOT_GOOD_ENOUGH
    return None


def review(samples: np.ndarray, sample_rate: float, grid: BeatGrid | None, stamp: TimingStamp | None,
           resolution: int = QUARTERS, sound_has_delay: bool = False, last_bar: int | None = None) -> Outcome:
    """The review of samples held in memory: (frames,) or (frames, channels)."""
    reason = reason_before_listening(grid, stamp)
    if reason:
        return Outcome(reason=reason)
    found = attacks(samples, sample_rate)
    return _judge(found, len(samples) / sample_rate, grid, stamp, resolution, sound_has_delay, last_bar)


def review_file(path: Path, grid: BeatGrid | None, stamp: TimingStamp | None, resolution: int = QUARTERS,
                sound_has_delay: bool = False, last_bar: int | None = None) -> Outcome:
    """The same review of a take's WAV file, read in blocks."""
    reason = reason_before_listening(grid, stamp)
    if reason:
        return Outcome(reason=reason)
    take = TakeFile(path)
    found = attacks_in(take)
    return _judge(found, take.frames / take.rate, grid, stamp, resolution, sound_has_delay, last_bar)


def _judge(found: list["Attack"], duration: float, grid: BeatGrid, stamp: TimingStamp, resolution: int,
           sound_has_delay: bool, last_bar: int | None) -> Outcome:
    value = accuracy(stamp)
    points = GridPoints(grid, resolution, duration, last_bar)
    onsets = match([a.time for a in found], points)
    # The attacks come in the order of time, as the onsets do.
    for onset, attack in zip(onsets, found):
        if onset.status == COUNTED and not attack.is_clear:
            onset.status = UNSURE
    offsets = [o.offset for o in onsets if o.is_counted and o.offset is not None]
    numbers = _numbers(offsets)
    if len(offsets) < MINIMUM_COUNTED or numbers is None:
        return Outcome(reason=TOO_FEW_ONSETS)
    placement, spread = numbers
    return Outcome(review=TimingReview(resolution, onsets, placement, spread, len(offsets),
                                       [DELAY_IN_THE_SOUND] if sound_has_delay else [], value,
                                       bars_of(onsets, points, spread)))


def match(times: list[float], points: "GridPoints") -> list[Onset]:
    """Gives each onset its grid point: the nearest one, when it lies in its catch window and is the first there."""
    reach = points.spacing * CATCH_WINDOW
    taken: set[int] = set()
    onsets = []
    for time in sorted(times):
        point = points.nearest(time)
        offset = time - points.time(point)
        if not (0 <= point < points.count) or abs(offset) > reach:
            onsets.append(Onset(time, None, None, OUTSIDE_WINDOWS))
            continue
        first = point not in taken
        taken.add(point)
        onsets.append(Onset(time, point, offset, COUNTED if first else LATER_IN_WINDOW))
    return onsets


def _numbers(offsets: list[float]) -> tuple[float, float] | None:
    """The mean of some offsets and their standard deviation around it."""
    if not offsets:
        return None
    mean = sum(offsets) / len(offsets)
    return mean, math.sqrt(sum((o - mean) ** 2 for o in offsets) / len(offsets))


class GridPoints:
    """The grid points of a take's bars on one grid, numbered from the first beat of its bars, 0 on: those in the
    file, and for bars recorded again only those of the bars recorded."""

    def __init__(self, grid: BeatGrid, resolution: int, duration: float = math.inf, last_bar: int | None = None):
        self.grid = grid
        self.points_per_beat = resolution
        self.spacing = grid.seconds_per_beat / resolution
        in_file = int(math.floor((duration - grid.offset) / self.spacing)) + 1 if math.isfinite(duration) else 2 ** 62
        in_bars = (last_bar - grid.first_bar + 1) * grid.beats_per_bar * resolution if last_bar is not None \
            else 2 ** 62
        self.count = max(min(in_file, in_bars), 0)

    @property
    def points_per_bar(self) -> int:
        return self.grid.beats_per_bar * self.points_per_beat

    def time(self, point: int) -> float:
        return self.grid.offset + point * self.spacing

    def nearest(self, time: float) -> int:
        return _round_half_away((time - self.grid.offset) / self.spacing)

    def first_of_bar(self, bar: int) -> int:
        return (bar - self.grid.first_bar) * self.points_per_bar


def _round_half_away(value: float) -> int:
    """Swift's rounded(): halves away from zero, not to even."""
    return int(math.floor(value + 0.5)) if value >= 0 else -int(math.floor(-value + 0.5))


def bars_of(onsets: list[Onset], points: GridPoints, take_spread: float) -> list[Bar]:
    """Every bar the take's grid points reach into, with the numbers of its counted onsets."""
    per_bar = points.points_per_bar
    if points.count <= 0 or per_bar <= 0:
        return []
    offsets: list[list[float]] = [[] for _ in range((points.count - 1) // per_bar + 1)]
    for onset in onsets:
        if onset.is_counted and onset.grid_point is not None and onset.offset is not None \
                and onset.grid_point // per_bar < len(offsets):
            offsets[onset.grid_point // per_bar].append(onset.offset)
    bars = []
    for index, values in enumerate(offsets):
        bar = Bar(points.grid.first_bar + index, len(values))
        numbers = _numbers(values)
        if numbers is not None:
            bar.placement = numbers[0]
            if len(values) >= 2:
                bar.spread = numbers[1]
                bar.steadiness = steadiness(numbers[1], take_spread)
        bars.append(bar)
    return bars


# MARK: The onset detector

LEVEL_SECONDS = 0.020
RISE_SHARE = 0.25
SLOWEST_RISE = 0.002  # the slowest rise of a clear attack
QUIET_SHARE = 0.125  # 18 dB below the take's median attack
STEP_SECONDS = 0.001
LOOK_BACK_STEPS = 25
RISE = 2.0
HOLD_STEPS = 15
PEAK_SECONDS = 0.001  # short, so the later strings of a strum do not raise the attack's peak
PEAK_SHARE = 0.3
BLOCK_FRAMES = 65_536


@dataclass
class Attack:
    time: float  # where the note begins, in seconds in the file
    level: float  # the loudest sample in the attack's first 20 ms
    rise: float  # seconds until the attack reaches a quarter of its level
    is_clear: bool = True


class _Samples:
    """Samples held in memory, read like a take file."""

    def __init__(self, samples: np.ndarray, rate: float):
        data = np.asarray(samples, dtype=np.float32)
        self.data = data[:, None] if data.ndim == 1 else data
        self.rate, self.frames, self.channels = rate, self.data.shape[0], self.data.shape[1]

    def blocks(self):
        for start in range(0, self.frames, BLOCK_FRAMES):
            yield self.data[start:start + BLOCK_FRAMES]

    def channel(self, channel: int, start: int, end: int) -> np.ndarray:
        return self.data[max(start, 0):max(end, 0), channel]


class TakeFile:
    """A take's WAV file (16, 24 or 32 bit PCM), read in blocks, never whole."""

    def __init__(self, path: Path):
        from . import wav
        self.path = Path(path)
        with open(self.path, "rb") as handle:
            layout = wav._layout(handle)
        if layout.format is None or layout.data_start is None:
            raise wav.WAVError(tr("The file is not a WAV file."))
        self.rate = float(layout.format.sample_rate)
        self.channels = layout.format.channels
        self.width = layout.format.bits // 8
        self.data_start = layout.data_start
        available = layout.file_size - layout.data_start
        size = min(layout.declared, available) if layout.declared else available
        self.frames = size // (self.width * self.channels)

    def _read(self, start: int, count: int) -> np.ndarray:
        frame_bytes = self.width * self.channels
        with open(self.path, "rb") as handle:
            handle.seek(self.data_start + start * frame_bytes)
            raw = handle.read(count * frame_bytes)
        raw = raw[: len(raw) - len(raw) % frame_bytes]
        if self.width == 3:
            b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
            values = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
            values = np.where(values >= 1 << 23, values - (1 << 24), values).astype(np.float32) / float(1 << 23)
        elif self.width == 2:
            values = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
        else:
            values = (np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2147483648.0).astype(np.float32)
        return values.reshape(-1, self.channels)

    def blocks(self):
        for start in range(0, self.frames, BLOCK_FRAMES):
            yield self._read(start, min(BLOCK_FRAMES, self.frames - start))

    def channel(self, channel: int, start: int, end: int) -> np.ndarray:
        start, end = max(start, 0), min(max(end, 0), self.frames)
        if end <= start:
            return np.zeros(0, dtype=np.float32)
        return self._read(start, end - start)[:, channel]


def attacks(samples: np.ndarray, sample_rate: float) -> list[Attack]:
    """The attacks in samples held in memory."""
    return attacks_in(_Samples(samples, sample_rate))


def attacks_in(take) -> list[Attack]:
    """The attacks in a take read twice: the loudness of every channel in steps of a millisecond, then the loudest
    channel around each attack."""
    rate = take.rate
    step = max(int(round(rate * STEP_SECONDS)), 1)
    # First reading: the loudest sample of every channel in each whole step.
    steps: list[np.ndarray] = []
    carry = np.zeros((0, take.channels), dtype=np.float32)
    for block in take.blocks():
        block = np.abs(np.concatenate([carry, block])) if carry.size else np.abs(block)
        whole = block.shape[0] // step
        if whole:
            steps.append(block[: whole * step].reshape(whole, step, take.channels).max(axis=1))
        carry = block[whole * step:]
    envelope_all = np.concatenate(steps) if steps else np.zeros((0, take.channels), dtype=np.float32)
    if take.frames == 0:
        return []
    peaks = envelope_all.max(axis=0) if envelope_all.size else np.zeros(take.channels, dtype=np.float32)
    if carry.size:
        peaks = np.maximum(peaks, carry.max(axis=0))
    channel = int(np.argmax(peaks))
    envelope = envelope_all[:, channel] if envelope_all.size else np.zeros(0, dtype=np.float32)
    loudest = float(envelope.max()) if envelope.size else 0.0
    floor = max(loudest * 0.02, 0.001)
    triggers = _triggers(envelope, step, floor)
    if not triggers:
        return []
    # Second reading: each attack placed in the samples around its trigger.
    peak_length, level_length = int(rate * PEAK_SECONDS), int(rate * LEVEL_SECONDS)
    found = []
    for start, background in triggers:
        end = min(start + 2 * step + peak_length + level_length, take.frames)
        window = np.abs(take.channel(channel, start, end))
        attack = _place(window, start, background, step, peak_length, level_length, floor, rate, take.frames)
        if attack is not None:
            found.append(attack)
    return _classified(found)


def _triggers(envelope: np.ndarray, step: int, floor: float) -> list[tuple[int, float]]:
    """Steps at least twice as loud as the loudest of the 25 before them (the one just before left out), and above
    the floor: where each attack's search starts, with that background."""
    count = envelope.shape[0]
    if count <= LOOK_BACK_STEPS:
        return []
    padded = np.concatenate([np.zeros(LOOK_BACK_STEPS, dtype=envelope.dtype), envelope])
    windows = np.lib.stride_tricks.sliding_window_view(padded, LOOK_BACK_STEPS).max(axis=1)
    # background[i] = max(envelope[max(i - 1 - 25, 0) : i - 1]), 0 for an empty stretch
    background = np.zeros(count, dtype=np.float32)
    background[1:] = windows[: count - 1]
    candidates = (envelope >= floor) & (envelope >= RISE * np.maximum(background, floor / RISE))
    candidates[0] = False
    triggers, index = [], 1
    for i in np.flatnonzero(candidates):
        if i < index:
            continue
        triggers.append(((int(i) - 1) * step, float(background[i])))
        index = int(i) + HOLD_STEPS
    return triggers


def _place(window: np.ndarray, start: int, background: float, step: int, peak_length: int, level_length: int,
           floor: float, rate: float, frames: int) -> Attack | None:
    end = min(start + 2 * step + peak_length, frames) - start
    if end <= 0 or end > window.shape[0]:
        return None
    head = window[:end]
    peak = float(head.max())
    threshold = max(peak * PEAK_SHARE, background * 1.5)
    above = np.flatnonzero(head >= threshold)
    if above.size == 0:
        return None
    first = int(above[0])
    before = max(background, floor * 0.05)
    while first > 0 and window[first - 1] > before:
        first -= 1
    level_end = min(first + level_length, window.shape[0])
    stretch = window[first:level_end]
    level = float(stretch.max()) if stretch.size else 0.0
    risen = np.flatnonzero(stretch >= level * RISE_SHARE)
    rise = int(risen[0]) if risen.size else 0
    # The note began somewhere between the last quiet sample and the first that stands out.
    return Attack((start + first - 0.5) / rate, level, rise / rate)


def _classified(found: list[Attack]) -> list[Attack]:
    """Marks the attacks too quiet against the take's typical one, or rising too slowly, as not clear."""
    if not found:
        return []
    typical = sorted(a.level for a in found)[len(found) // 2]
    for attack in found:
        attack.is_clear = attack.level >= typical * QUIET_SHARE and attack.rise <= SLOWEST_RISE
    return found
