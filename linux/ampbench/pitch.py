"""Follows the pitch of one string from a mono stream, for the tuner. A port of Sources/SparkCore/PitchDetector.swift
and PitchTracker.swift; the Swift code is the reference and carries the long explanations, change both together.

Pure logic with numpy: it takes samples, so tests feed it synthetic signals without any audio hardware, and the tuner
engine feeds it from a thread of its own.

Every 5 ms the tracker measures the level and opens or closes the gate, estimates the period with the McLeod method
(`PeriodDetector`), locks onto a note after three estimates that agree, measures the phase of the fundamental at the
locked frequency (`PhaseEstimator`, which gives the fine value) and smooths with a median of five and an exponential
average.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from .tuning import PitchReading


@dataclass
class PeriodEstimate:
    lag: float
    clarity: float
    searched_up_to: int


class PeriodDetector:
    """The McLeod pitch method: the normalized square difference function of a block, computed through an FFT, and
    the first of its key maxima that comes close to the highest one, with parabolic interpolation."""

    def __init__(self, max_window: int):
        self.max_window = max(max_window, 64)
        size = 1
        while size < 2 * self.max_window:
            size <<= 1
        self.fft_size = size
        self.key_threshold = 0.9

    def estimate(self, samples: np.ndarray, min_lag: int, max_lag: int) -> PeriodEstimate | None:
        window = min(len(samples), self.max_window)
        upper = min(max_lag, window // 2)
        if window < 8 or upper <= min_lag + 2:
            return None
        x = np.asarray(samples[:window], dtype=np.float64)
        spectrum = np.fft.rfft(x, n=self.fft_size)
        correlation = np.fft.irfft(spectrum.real ** 2 + spectrum.imag ** 2, n=self.fft_size)
        energy = float(np.dot(x, x))
        if energy <= 1e-12 or correlation[0] <= 0:
            return None
        # n(τ) = 2 r(τ) / m(τ), with m(τ) the energy of both overlapping parts, updated lag by lag.
        early = x[0:upper]
        late = x[window - 1:window - 1 - upper:-1] if window - 1 - upper >= 0 else x[window - 1::-1][:upper]
        remaining = 2 * energy - np.cumsum(early * early + late * late)
        safe = np.where(remaining > 1e-12, remaining, 1.0)
        nsdf = np.empty(upper + 1)
        nsdf[0] = 1.0
        nsdf[1:] = np.where(remaining > 1e-12, 2 * correlation[1:upper + 1] / safe, 0.0)

        # Key maxima: the highest point of each positive lobe after the first negative stretch.
        not_positive = np.flatnonzero(nsdf[1:] <= 0)
        if len(not_positive) == 0:
            return None
        first = 1 + int(not_positive[0])
        rest = nsdf[first:]
        positive = (rest > 0).astype(np.int8)
        edges = np.flatnonzero(np.diff(np.concatenate(([0], positive, [0]))))
        keys: list[tuple[int, float]] = []
        best = 0.0
        for start, end in zip(edges[0::2], edges[1::2]):
            peak = int(start) + int(np.argmax(rest[start:end]))
            lag = first + peak
            if min_lag < lag < upper:
                keys.append((lag, float(rest[peak])))
                best = max(best, float(rest[peak]))
        if best <= 0:
            return None
        chosen = next((k for k in keys if k[1] >= self.key_threshold * best), None)
        if chosen is None:
            return None
        index = chosen[0]
        left, middle, right = nsdf[index - 1], nsdf[index], nsdf[index + 1]
        denominator = left - 2 * middle + right
        offset = max(-0.5, min(0.5, 0.5 * (left - right) / denominator)) if abs(denominator) > 1e-12 else 0.0
        height = middle - 0.25 * (left - right) * offset
        return PeriodEstimate(index + offset, min(float(height), 1.0), upper)


class PhaseEstimator:
    """The fine estimate: the phase of the fundamental, measured again and again, and a straight line through it.

    Each measurement demodulates a Hann-windowed block at a fixed reference frequency. For a tone at the reference
    plus δ the phase at the block's center grows exactly by δ per sample, also while the tone decays, so a weighted
    least-squares line through the phases over up to `max_span` gives the frequency to a fraction of a cent. The span
    shrinks at once when the pitch moves and grows again while it holds; whether it moves is judged against the
    measured noise (a probe halfway between the fundamental and its octave)."""

    def __init__(self, sample_rate: float, max_length: int):
        self.sample_rate = sample_rate
        self.reference = 0.0
        self.max_span = 0.6
        self.short_span = 0.08
        self.move_threshold = 1.2
        self.move_sigmas = 6.0
        self.prunes = 0
        self._max_length = max_length
        self._origin = 0
        self._cos = np.zeros(max_length)
        self._sin = np.zeros(max_length)
        self._probe_cos = np.zeros(max_length)
        self._probe_sin = np.zeros(max_length)
        self._windows: dict[int, np.ndarray] = {}
        capacity = 8192
        self._time = np.zeros(capacity)
        self._phase = np.zeros(capacity)
        self._weight = np.zeros(capacity)
        self._noise = np.zeros(capacity)
        self._lo = self._hi = 0
        self._moving = 0
        self._block_length = 0.0

    @property
    def max_length(self) -> int:
        return self._max_length

    @property
    def count(self) -> int:
        return self._hi - self._lo

    def reset(self, reference: float, origin: int) -> None:
        """Starts over at a new reference frequency. `origin` is the absolute sample that phase 0 refers to."""
        self.reference, self._origin = reference, origin
        self._lo = self._hi = 0
        self._moving = 0
        angle = 2 * math.pi * reference / self.sample_rate * np.arange(self._max_length)
        self._cos, self._sin = np.cos(angle), np.sin(angle)
        self._probe_cos, self._probe_sin = np.cos(1.5 * angle), np.sin(1.5 * angle)

    def clear(self) -> None:
        self.reference = 0.0
        self._lo = self._hi = 0
        self._moving = 0

    def _window(self, length: int) -> np.ndarray:
        # A periodic Hann window of length + 1 points; points 1…length are symmetric about the block's center
        # (length - 1) / 2, which keeps the phase free of any window term.
        window = self._windows.get(length)
        if window is None:
            window = 0.5 * (1 - np.cos(2 * math.pi * np.arange(1, length + 1) / (length + 1)))
            if len(self._windows) > 16:
                self._windows.clear()
            self._windows[length] = window
        return window

    def measure(self, samples: np.ndarray, start: int) -> None:
        """Measures the block `samples`, whose first sample is absolute sample `start`, and adds its phase."""
        length = min(len(samples), self._max_length)
        if self.reference <= 0 or length < 16:
            return
        weighted = np.asarray(samples[:length], dtype=np.float64) * self._window(length)
        in_phase = float(np.dot(weighted, self._cos[:length]))
        quadrature = float(np.dot(weighted, self._sin[:length]))
        probe_in = float(np.dot(weighted, self._probe_cos[:length]))
        probe_out = float(np.dot(weighted, self._probe_sin[:length]))
        magnitude = in_phase ** 2 + quadrature ** 2
        if magnitude <= 1e-18:
            return
        omega = 2 * math.pi * self.reference / self.sample_rate
        offset = float(start - self._origin)
        # The sum ran over e^{-iωk}; shifting it to absolute time adds -ω·(start - origin).
        phase = math.atan2(-quadrature, in_phase) - math.remainder(omega * offset, 2 * math.pi)
        center = offset + (length - 1) / 2
        if self.count:
            slope = self._slope()
            predicted = self._phase[self._hi - 1] + (slope or 0.0) * (center - self._time[self._hi - 1])
            phase += 2 * math.pi * round_half_away((predicted - phase) / (2 * math.pi))
        # A complex noise sample of power p beside a tone of power m scatters the phase by about p / (2m).
        noise = (probe_in ** 2 + probe_out ** 2) / (2 * magnitude)
        self._append(center, phase, magnitude, noise)
        self._prune(center - self.max_span * self.sample_rate)
        self._block_length = float(length)
        self._watch_for_movement(center, float(length))

    def _append(self, time: float, phase: float, weight: float, noise: float) -> None:
        if self._hi == len(self._time):
            n = self.count
            for array in (self._time, self._phase, self._weight, self._noise):
                array[:n] = array[self._lo:self._hi].copy()
            self._lo, self._hi = 0, n
        i = self._hi
        self._time[i], self._phase[i], self._weight[i], self._noise[i] = time, phase, weight, noise
        self._hi += 1

    @property
    def frequency(self) -> float | None:
        slope = self._slope()
        return None if slope is None else self.reference + slope * self.sample_rate / (2 * math.pi)

    @property
    def expected_error(self) -> float | None:
        """The expected error of `frequency` in cents, from the measured noise of the phases."""
        if self.count < 3 or self.reference <= 0:
            return None
        length = float(self._time[self._hi - 1] - self._time[self._lo])
        if length <= 0:
            return None
        variance = float(self._noise[self._lo:self._hi].mean())
        independent = 1 + length / max(self._block_length, 1.0)
        slope_error = math.sqrt(variance * 12 / independent) / length
        return 1200 / math.log(2) * slope_error * self.sample_rate / (2 * math.pi) / self.reference

    @property
    def span(self) -> float:
        """How long the line runs, in seconds."""
        if not self.count:
            return 0.0
        return float(self._time[self._hi - 1] - self._time[self._lo]) / self.sample_rate

    def _slope(self, since: float = -math.inf) -> float | None:
        """The weighted least-squares slope of the phases since `since`, in radians per sample."""
        lo = self._lo
        if since > -math.inf:
            lo += int(np.searchsorted(self._time[self._lo:self._hi], since, side="left"))
        if self._hi - lo < 3:
            return None
        t, p, w = self._time[lo:self._hi], self._phase[lo:self._hi], self._weight[lo:self._hi]
        weight_sum = float(w.sum())
        if weight_sum <= 0:
            return None
        mean_time, mean_phase = float((w * t).sum() / weight_sum), float((w * p).sum() / weight_sum)
        dt = t - mean_time
        variance = float((w * dt * dt).sum())
        return float((w * dt * (p - mean_phase)).sum() / variance) if variance > 0 else None

    def _prune(self, before: float) -> None:
        first = int(np.searchsorted(self._time[self._lo:self._hi], before, side="left"))
        if first > 0:
            self._lo += first

    def _watch_for_movement(self, now: float, block_length: float) -> None:
        """When a quick line over the last moments disagrees with the long one several times in a row, by more than
        its own noise allows, the pitch is moving: the long line is dropped so the reading follows at once."""
        short_length = self.short_span * self.sample_rate
        short_start = now - short_length
        first_recent = self._lo + int(np.searchsorted(self._time[self._lo:self._hi], short_start, side="left"))
        recent = self._hi - first_recent
        long = self._slope() if self.span > self.short_span * 2 and recent >= 3 else None
        short = self._slope(short_start) if long is not None else None
        if long is None or short is None:
            self._moving = 0
            return
        long_frequency = self.reference + long * self.sample_rate / (2 * math.pi)
        short_frequency = self.reference + short * self.sample_rate / (2 * math.pi)
        if long_frequency <= 0 or short_frequency <= 0:
            return
        phase_variance = float(self._noise[first_recent:self._hi].mean())
        independent = 1 + short_length / block_length
        slope_error = math.sqrt(phase_variance * 12 / independent) / short_length
        error_cents = 1200 / math.log(2) * slope_error * self.sample_rate / (2 * math.pi) / long_frequency
        if abs(1200 * math.log2(short_frequency / long_frequency)) > max(self.move_threshold,
                                                                         self.move_sigmas * error_cents):
            self._moving += 1
            if self._moving >= 3:
                self.prunes += 1
                self._prune(short_start)
                self._moving = 0
        else:
            self._moving = 0


def round_half_away(value: float) -> int:
    return int(math.copysign(math.floor(abs(value) + 0.5), value))


def cents_between(frequency: float, reference: float) -> float:
    return 1200 * math.log2(frequency / reference)


def is_harmonic(cents: float) -> bool:
    """Octaves up and down, the twelfth and the fifth: what overtones and undertones of a string are mistaken for."""
    ratios = [2, 3, 4, 1.5, 0.5, 1 / 3.0, 0.25, 2 / 3.0]
    return any(abs(cents - 1200 * math.log2(r)) < 50 for r in ratios)


def agreeing_median(values: list[float], within: float) -> float | None:
    """The median when all values lie within `within` cents of it, else None."""
    median = sorted(values)[len(values) // 2]
    return median if all(abs(cents_between(v, median)) <= within for v in values) else None


@dataclass
class Settings:
    lowest: float = 28.0            # the tuner's range is 30 Hz to 1.4 kHz; the bounds leave room at both ends
    highest: float = 1500.0
    gate_on: float = -60.0          # dBFS RMS, with hysteresis
    gate_off: float = -66.0
    attack_blank: float = 0.02      # what is left out after an attack, in seconds
    hop: float = 0.005
    min_clarity: float = 0.8        # the least clarity of an estimate that locks a note ...
    keep_clarity: float = 0.5       # ... and that keeps a locked note
    hold: float = 1.5               # how long the last value stays, in seconds
    phase_periods: float = 12.0
    max_phase_window: float = 0.45
    span_periods: float = 60.0
    span_range: tuple[float, float] = (0.6, 2.0)
    attack_ratio: float = 2.0


class PitchTracker:
    def __init__(self, sample_rate: float, settings: Settings | None = None):
        self.sample_rate = float(sample_rate)
        self.settings = settings or Settings()
        s = self.settings
        self.reading: PitchReading | None = None
        self.has_signal = False
        self.level_db = -120.0
        self.time = 0
        self.attack_count = 0
        self.lock_count = 0
        self.phase_restarts = 0
        self.locked_frequency: float | None = None

        self._hop = max(round(s.hop * sample_rate), 16)
        self._min_lag = max(int(sample_rate / s.highest), 2)
        self._max_lag = math.ceil(sample_rate / s.lowest)
        # Two periods of the lowest note, so its octave below has been searched for every note above 2 × lowest.
        self._coarse_window = 2 * self._max_lag + 4
        self._phase_window = int(s.max_phase_window * sample_rate)
        size = 1
        while size < self._coarse_window + self._phase_window + 8 * self._hop:
            size <<= 1
        self._history = np.zeros(size)
        self._mask = size - 1
        self._detector = PeriodDetector(self._coarse_window)
        self._phase = PhaseEstimator(sample_rate, self._phase_window)
        self._next_hop = self._hop
        self._hop_index = 0
        self._levels: list[float] = []
        self._analysis_start = 0
        self._last_attack = -(1 << 60)
        self._candidates: list[float] = []
        self._foreign: list[float] = []
        self._missed = 0
        self._last_coarse: float | None = None
        self._recent: list[float] = []
        self._smoothed: float | None = None
        self._held_since: int | None = None
        self._best_uncertainty = math.inf
        self._note_level = -140.0
        # A first-order high-pass at about 10 Hz: a DC offset would keep the NSDF from ever turning negative.
        self._pole = 1 - 2 * math.pi * 10 / sample_rate
        self._blocker_in = 0.0
        self._blocker_out = 0.0

    @property
    def seconds(self) -> float:
        return self.time / self.sample_rate

    @property
    def phase_span(self) -> float:
        return self._phase.span

    @property
    def expected_error(self) -> float | None:
        return None if self.locked_frequency is None else self._phase.expected_error

    def reset(self) -> None:
        """Forgets everything, as after a gap in the stream."""
        self.time = 0
        self._next_hop = self._hop
        self._hop_index = 0
        self._levels.clear()
        self.has_signal = False
        self.level_db = -120.0
        self.reading = None
        self._unlock()
        self._held_since = None
        self._last_attack = -(1 << 60)
        self._blocker_in = self._blocker_out = 0.0
        self._history[:] = 0

    def process(self, samples) -> None:
        data = np.asarray(samples, dtype=np.float64)
        offset = 0
        while offset < len(data):
            chunk = min(len(data) - offset, self._hop)
            self._filter_into_history(data[offset:offset + chunk])
            self.time += chunk
            offset += chunk
            while self.time >= self._next_hop:
                self._analyze(self._next_hop)
                self._next_hop += self._hop

    def _filter_into_history(self, x: np.ndarray) -> None:
        """y[n] = x[n] − x[n−1] + pole · y[n−1] for a whole chunk at once: y[k] = pole^k · (pole · y₀ + Σ d[j] ·
        pole^−j). A chunk is at most one hop, so pole^−j stays near 1."""
        n = len(x)
        d = np.diff(x, prepend=self._blocker_in)
        k = np.arange(n)
        y = self._pole ** k * (self._pole * self._blocker_out + np.cumsum(d * self._pole ** (-k.astype(np.float64))))
        self._blocker_in, self._blocker_out = float(x[-1]), float(y[-1])
        position = self.time & self._mask
        first = min(n, len(self._history) - position)
        self._history[position:position + first] = y[:first]
        if first < n:
            self._history[:n - first] = y[first:]

    # MARK: One step

    def _analyze(self, end: int) -> None:
        s = self.settings
        self._hop_index += 1
        period = self.sample_rate / self.locked_frequency if self.locked_frequency else 0.0
        level_length = min(max(int(0.02 * self.sample_rate), int(2 * period)), int(0.1 * self.sample_rate))
        mean_square = self._sum_of_squares(end, level_length) / level_length
        self.level_db = 10 * math.log10(mean_square) if mean_square > 1e-14 else -140.0
        rms = math.sqrt(mean_square)
        self._levels.append(rms)
        if len(self._levels) > 17:
            del self._levels[:len(self._levels) - 17]

        if not self.has_signal:
            if self.level_db > s.gate_on:
                self.has_signal = True
                self._attack(end)
            else:
                self._hold_or_forget(end)
                return
        elif self.level_db < s.gate_off:
            self.has_signal = False
            self._unlock()
            self._hold_or_forget(end)
            return
        elif len(self._levels) >= 17 and end - self._last_attack > int(0.05 * self.sample_rate):
            # The level 25 to 80 ms ago, whose windows do not overlap the current one.
            before = max(self._levels[0:12])
            if rms > s.attack_ratio * before:
                self._attack(end)

        available = end - self._analysis_start
        if available <= 0:
            return
        if self.locked_frequency is None or self._hop_index % 4 == 0:
            self._coarse(end, available)
        if self.locked_frequency is not None:
            self._fine(end, available, self.locked_frequency)
        elif self.reading is not None:
            self._hold_or_forget(end)

    def _attack(self, end: int) -> None:
        self.attack_count += 1
        self._last_attack = end
        self._analysis_start = end - self._hop + int(self.settings.attack_blank * self.sample_rate)
        self._unlock()

    def _unlock(self) -> None:
        self.locked_frequency = None
        self._candidates.clear()
        self._foreign.clear()
        self._missed = 0
        self._last_coarse = None
        self._phase.clear()

    def _hold_or_forget(self, end: int) -> None:
        """Keeps the last value for a while, then lets it go."""
        current = self.reading
        if current is None:
            return
        if not current.is_held:
            self.reading = PitchReading(current.frequency, True, current.uncertainty)
            self._held_since = end
            self._recent.clear()
            self._smoothed = None
        elif self._held_since is not None and (end - self._held_since) / self.sample_rate > self.settings.hold:
            self.reading = None
            self._held_since = None

    # MARK: Coarse

    def _coarse(self, end: int, available: int) -> None:
        s = self.settings
        length = min(available, self._coarse_window)
        if length < 4 * self._min_lag:
            return
        estimate = self._detector.estimate(self._copy(end, length), self._min_lag, self._max_lag)
        if estimate is None:
            self._miss(length >= self._coarse_window)
            return
        # Not yet: the block has not seen the octave below, so this could be an overtone.
        if not (2 * estimate.lag <= estimate.searched_up_to or estimate.searched_up_to >= self._max_lag):
            return
        needed = s.min_clarity if self.locked_frequency is None else s.keep_clarity
        if estimate.clarity < needed or estimate.lag >= self._max_lag - 1:
            self._miss(True)
            return
        frequency = self.sample_rate / estimate.lag
        self._last_coarse = frequency
        self._missed = 0
        if self.locked_frequency is None:
            self._candidates.append(frequency)
            del self._candidates[:-3]
            if len(self._candidates) == 3:
                median = agreeing_median(self._candidates, 30)
                if median is not None:
                    self._lock(median, end)
            return
        distance = cents_between(frequency, self.locked_frequency)
        if abs(distance) < 70 or is_harmonic(distance):
            # The locked note, or an overtone or undertone of it, such as the octave while a low string rings out.
            self._foreign.clear()
        else:
            self._foreign.append(frequency)
            if len(self._foreign) >= 3:
                median = agreeing_median(self._foreign[-3:], 30)
                if median is not None:
                    self._lock(median, end)

    def _miss(self, certain: bool) -> None:
        if not certain:
            return
        if self.locked_frequency is None:
            self._candidates.clear()
        else:
            self._missed += 1
            # About 80 ms without a pitch: the tone has ended or turned into noise.
            if self._missed >= 4:
                self._unlock()

    def _lock(self, frequency: float, end: int) -> None:
        s = self.settings
        self.lock_count += 1
        self.locked_frequency = frequency
        self._candidates.clear()
        self._foreign.clear()
        self._missed = 0
        self._recent.clear()
        self._smoothed = None
        self._held_since = None
        self._best_uncertainty = math.inf
        self._note_level = self.level_db
        self._phase.max_span = min(max(s.span_periods / frequency, s.span_range[0]), s.span_range[1])
        self._phase.reset(frequency, self._analysis_start)
        self._emit(frequency)

    # MARK: Fine

    def _fine(self, end: int, available: int, locked: float) -> None:
        s = self.settings
        period = self.sample_rate / locked
        length = min(available, int(s.phase_periods * period), self._phase_window)
        if length >= int(3 * period):
            self._phase.measure(self._copy(end, length), end - length)
        value = locked
        measured = self._phase.frequency
        if measured is not None and self._phase.span >= 0.02:
            from_reference = cents_between(measured, self._phase.reference) if measured > 0 else math.inf
            if abs(from_reference) > 25 or math.isnan(measured):
                # The line lost the tone, such as after a slip of the phase: start over from the coarse value.
                self.phase_restarts += 1
                self._phase.reset(self._last_coarse or locked, self._analysis_start)
                value = self._last_coarse or locked
            else:
                value = measured
                if abs(from_reference) > 12:
                    # A peg being turned far: measure around the new pitch.
                    self.phase_restarts += 1
                    self._phase.reset(measured, self._analysis_start)
        elif self._last_coarse is not None:
            value = self._last_coarse
        self.locked_frequency = value
        self._note_level = max(self._note_level, self.level_db)
        uncertainty = self._phase.expected_error if measured is not None and self._phase.span >= 0.02 else None
        if uncertainty is not None and uncertainty > max(0.5, 3 * self._best_uncertainty) \
                and self.level_db < self._note_level - 20 and self.reading is not None and not self.reading.is_held:
            # The string fades into the noise: its last precise value stays rather than the noise's.
            return
        if uncertainty is not None:
            self._best_uncertainty = min(self._best_uncertainty, uncertainty)
        self._emit(value, uncertainty)

    # MARK: Smoothing

    def _emit(self, frequency: float, uncertainty: float | None = None) -> None:
        self._recent.append(frequency)
        del self._recent[:-5]
        median = sorted(self._recent)[len(self._recent) // 2]
        if self._smoothed is not None:
            distance = abs(cents_between(median, self._smoothed))
            weight = 0.7 if distance > 2 else 0.35 if distance > 0.6 else 0.12
            self._smoothed = self._smoothed + weight * (median - self._smoothed)
        else:
            self._smoothed = median
        self._held_since = None
        self.reading = PitchReading(self._smoothed, False, uncertainty)

    # MARK: Helpers

    def _sum_of_squares(self, end: int, count: int) -> float:
        start = (end - count) & self._mask
        if start + count <= len(self._history):
            part = self._history[start:start + count]
        else:
            part = np.concatenate((self._history[start:], self._history[:start + count - len(self._history)]))
        return float(np.dot(part, part))

    def _copy(self, end: int, count: int) -> np.ndarray:
        """The `count` samples before `end`."""
        start = (end - count) & self._mask
        if start + count <= len(self._history):
            return self._history[start:start + count]
        return np.concatenate((self._history[start:], self._history[:start + count - len(self._history)]))
