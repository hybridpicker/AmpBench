"""Synthetic signals for the tuner's tests and its demo. A port of Sources/SparkCore/TunerTestSignal.swift. Nothing
here is ever recorded: every sample is computed with a seeded generator, the same on every machine."""
from __future__ import annotations

import math

import numpy as np

MASK = (1 << 64) - 1


class SeededGenerator:
    """SplitMix64, so synthetic signals are the same everywhere (and the same as on the Mac)."""

    def __init__(self, seed: int):
        self.state = seed & MASK

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        value = self.state
        value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & MASK
        return value ^ (value >> 31)

    def uniform(self) -> float:
        return (self.next() >> 11) / float(1 << 53)

    def gaussian(self) -> float:
        first = max(self.uniform(), 1e-300)
        second = self.uniform()
        return math.sqrt(-2 * math.log(first)) * math.cos(2 * math.pi * second)


def sine(frequency: float, sample_rate: float, seconds: float, amplitude: float = 0.5, phase: float = 0.3) -> np.ndarray:
    count = int(seconds * sample_rate)
    return (amplitude * np.sin(2 * math.pi * frequency / sample_rate * np.arange(count) + phase)).astype(np.float32)


def sawtooth(frequency: float, sample_rate: float, seconds: float, amplitude: float = 0.4,
             decay: float | None = None) -> np.ndarray:
    """A band-limited sawtooth; with `decay` it rings out like a string, the higher harmonics faster."""
    count = int(seconds * sample_rate)
    index = np.arange(count)
    samples = np.zeros(count)
    harmonic = 1
    while harmonic * frequency < 0.45 * sample_rate:
        omega = 2 * math.pi * frequency * harmonic / sample_rate
        rate = (1 + 0.35 * (harmonic - 1)) / (decay * sample_rate) if decay else 0.0
        samples += (1 / harmonic) * np.exp(-rate * index) * np.sin(omega * index + 0.7 * harmonic)
        harmonic += 1
    return _normalized(samples, amplitude)


def _allpass_coefficient(phase_delay: float, omega: float) -> float:
    def delay(a: float) -> float:
        return (omega - 2 * math.atan2(a * math.sin(omega), 1 + a * math.cos(omega))) / omega

    low, high = -0.99, 0.99
    for _ in range(100):
        middle = (low + high) / 2
        if delay(middle) > phase_delay:
            low = middle
        else:
            high = middle
    return (low + high) / 2


def karplus_strong(frequency: float, sample_rate: float, seconds: float, amplitude: float = 0.5,
                   ring_time: float = 4.0, damping: float = 0.12, seed: int = 7) -> np.ndarray:
    """A plucked string after Karplus and Strong, tuned so its fundamental lies exactly at `frequency`."""
    delay = sample_rate / frequency
    omega = 2 * math.pi * frequency / sample_rate
    whole = int(math.floor(delay - 1 - 0.1))
    coefficient = _allpass_coefficient(delay - 1 - whole, omega)
    per_loop = 10 ** (-3 / (ring_time * frequency))
    damping = min(damping, max((1 - per_loop / 0.99999) / (2 * (1 - math.cos(omega))), 0))
    loss = (1 - 2 * damping) + 2 * damping * math.cos(omega)
    loop_gain = min(per_loop / loss, 0.99999)
    count = int(seconds * sample_rate)
    generator = SeededGenerator(seed)
    burst = [generator.uniform() * 2 - 1 for _ in range(whole)]
    for _ in range(2):
        burst = [0.25 * burst[(i + whole - 1) % whole] + 0.5 * burst[i] + 0.25 * burst[(i + 1) % whole]
                 for i in range(whole)]
    mean = sum(burst) / whole
    burst = [b - mean for b in burst]
    line = [0.0] * whole
    output = [0.0] * count
    previous = before_previous = allpass_in = allpass_out = 0.0
    position = 0
    for index in range(count):
        delayed = line[position]
        filtered = damping * delayed + (1 - 2 * damping) * previous + damping * before_previous
        before_previous, previous = previous, delayed
        shifted = coefficient * filtered + allpass_in - coefficient * allpass_out
        allpass_in, allpass_out = filtered, shifted
        value = (burst[index] if index < whole else 0.0) + loop_gain * shifted
        output[index] = value
        line[position] = value
        position = (position + 1) % whole
    return _normalized(np.array(output), amplitude)


def adding_noise(signal: np.ndarray, decibels: float, seed: int = 11) -> np.ndarray:
    """White noise `decibels` below the RMS of the signal's first half second."""
    head = signal[:max(min(len(signal), 24_000), 1)].astype(np.float64)
    rms = math.sqrt(float(np.dot(head, head)) / len(head))
    noise = rms * 10 ** (decibels / 20)
    generator = SeededGenerator(seed)
    return (signal + np.array([noise * generator.gaussian() for _ in range(len(signal))])).astype(np.float32)


def silence(sample_rate: float, seconds: float) -> np.ndarray:
    return np.zeros(int(seconds * sample_rate), dtype=np.float32)


def _normalized(samples: np.ndarray, peak: float) -> np.ndarray:
    largest = float(np.max(np.abs(samples))) if len(samples) else 0.0
    return (samples / largest * peak if largest > 0 else samples).astype(np.float32)
