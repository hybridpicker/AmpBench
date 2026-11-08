"""A simulated Spark input for ``spark-studio --demo`` and the tests: a guitar-like decaying tone from a helper process
that speaks the same raw 32-bit stream as pw-record."""
from __future__ import annotations

import sys

from .capture import CaptureEngine, InputDevice

SCRIPT = r"""
import math, struct, sys, time
rate, channels = int(sys.argv[1]), int(sys.argv[2])
step = int(rate * 0.02)
t = 0
out = sys.stdout.buffer
while True:
    frames = bytearray()
    for i in range(step):
        n = t + i
        pluck = (n % (rate // 2)) / rate
        value = int(2**31 * 0.5 * math.exp(-pluck * 5) * math.sin(2 * math.pi * 220 * n / rate))
        frames += struct.pack("<i", max(min(value, 2**31 - 1), -2**31)) * channels
    t += step
    out.write(bytes(frames)); out.flush()
    time.sleep(0.02)
"""


def demo_devices() -> list[InputDevice]:
    return [InputDevice("demo.spark", 1, "Spark MINI (Demo)", "usb", 48000, 2, True, 24)]


def demo_engine() -> CaptureEngine:
    return CaptureEngine(lambda d: [sys.executable, "-c", SCRIPT, str(d.rate), str(d.channels)])
