"""Measures the real delay from the click output to the file, the way a DAW does with a loopback cable.

A port of LatencyProbe in Sources/SparkCore/ClickTiming.swift. The click plays into the input, through a cable from
the click output into the amp's guitar input or an earbud held on the pickup. That is the way a played note takes,
so the measured delay is what the bars of a recording need. A click is placed where it begins, by the timing
review's own onset detector, so a note played exactly on the click reviews as on it.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .click_timing import AIRPLAY, BLUETOOTH
from .i18n import number, tr
from .timing_review import attacks

MAXIMUM_LATENCY = 0.35
EARLY_TOLERANCE = 0.002
STABLE_SPREAD = 0.002
BEATS, BPM, VOLUME = 12, 100.0, 0.5  # what a measurement plays


class LatencyProbeError(Exception):
    def __init__(self, kind: str, spread_ms: float = 0.0):
        self.kind, self.spread_ms = kind, spread_ms
        super().__init__(self.text)

    @property
    def text(self) -> str:
        if self.kind == "clickDidNotStart":
            return tr("The click did not start.")
        if self.kind == "noSignal":
            return tr("No click arrived at the input. Is the cable in the guitar input, or do the headphones lie "
                      "directly on the pickup? Is the output loud enough?")
        if self.kind == "unstable":
            return tr("The clicks arrived unevenly (spread {} ms). Choose a preset without delay, reverb and noise "
                      "gate on the amp and measure again.", number(self.spread_ms, 1))
        if self.kind == "clickOnBluetooth":
            return tr("The click goes to a Bluetooth output, whose own delay would be taken for the amp's. Choose a "
                      "wired output for the click and measure again.")
        return tr("The click goes to an AirPlay output, whose own delay would be taken for the amp's. Choose a wired "
                  "output for the click and measure again.")


@dataclass(frozen=True)
class Result:
    measured: float  # seconds from the click's input frame to its arrival in the file
    reported: float  # what the devices report for the same way
    spread: float  # largest difference between single clicks, in seconds
    detected: int
    played: int

    @property
    def correction(self) -> float:
        """The part the devices do not report: the amp's."""
        return self.measured - self.reported


def check_output(kind: str) -> None:
    """Refuses a click output whose own delay is not steady: it would be stored as the amp's part, marked measured."""
    if kind == BLUETOOTH:
        raise LatencyProbeError("clickOnBluetooth")
    if kind == AIRPLAY:
        raise LatencyProbeError("clickOnAirPlay")


def analyze(samples: np.ndarray, sample_rate: float, expected: list[float]) -> tuple[list[float], int]:
    """Frames from each expected beat to its onset, for the beats that were found, and how many were played.
    ``expected`` are file frames where the clicks would be without any delay."""
    if not expected or sample_rate <= 0:
        return [], len(expected)
    samples = np.asarray(samples, dtype=np.float32)
    early = int(EARLY_TOLERANCE * sample_rate)
    quiet_end = min(max(int(expected[0]) - early, 0), len(samples))
    noise = float(np.abs(samples[:quiet_end]).max()) if quiet_end else 0.0
    onsets = [a.time * sample_rate for a in attacks(samples, sample_rate)]
    lags = []
    for index, beat in enumerate(expected):
        lower = max(int(np.floor(beat)) - early, 0)
        upper = int(beat + MAXIMUM_LATENCY * sample_rate)
        if index + 1 < len(expected):
            upper = min(upper, int(expected[index + 1]) - early)
        upper = min(upper, len(samples))
        if upper <= lower:
            continue
        peak = float(np.abs(samples[lower:upper]).max())
        onset = next((o for o in onsets if lower <= o < upper), None)
        if peak <= max(noise * 4, 0.003) or onset is None:
            continue
        lags.append(onset - beat)
    return lags, len(expected)


def evaluate(lags: list[float], played: int, sample_rate: float, reported: float) -> Result:
    """Turns single lags into one result, refusing a measurement that is not clean enough to trust."""
    needed = max(4, (played * 2 + 2) // 3)
    if len(lags) < needed:
        raise LatencyProbeError("noSignal")
    ordered = sorted(lags)
    median = ordered[len(ordered) // 2]
    inliers = [lag for lag in ordered if abs(lag - median) <= EARLY_TOLERANCE * sample_rate]
    spread = ((inliers[-1] - inliers[0]) if inliers else 0.0) / sample_rate
    if len(inliers) < needed or spread > STABLE_SPREAD:
        whole = (ordered[-1] - ordered[0]) / sample_rate
        raise LatencyProbeError("unstable", max(spread, whole) * 1000)
    mean = sum(inliers) / len(inliers)
    return Result(mean / sample_rate, reported, spread, len(inliers), played)


def loudest_channel(path) -> tuple[np.ndarray, float]:
    """A short measurement file's loudest channel, whole."""
    from .timing_review import TakeFile
    take = TakeFile(path)
    data = np.concatenate(list(take.blocks())) if take.frames else np.zeros((0, take.channels), dtype=np.float32)
    if not data.size:
        return np.zeros(0, dtype=np.float32), take.rate
    return data[:, int(np.argmax(np.abs(data).max(axis=0)))], take.rate
