"""A simulated Spark input for ``ampbench --demo`` and the tests: a guitar-like decaying tone from a helper process
that speaks the same raw 32-bit stream as pw-record, or ampbench/fake_rt.py, which also plays a click and hears it
back like a cable from the headphone output to the pickup."""
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


def click_engine(loop: float | None = 0.0254, latency: tuple[float, float] = (0.002, 0.0017),
                 pluck: bool = False) -> CaptureEngine:
    """An input with the click: fake_rt, whose clicks come back ``loop`` seconds after they left (None: never)."""
    from pathlib import Path
    script = str(Path(__file__).resolve().parent / "fake_rt.py")

    def command(d: InputDevice) -> list[str]:
        args = [sys.executable, script, "--target", d.node_name, "--rate", str(d.rate), "--channels", str(d.channels),
                "--latency", f"{latency[0]}", f"{latency[1]}"]
        if loop is not None:
            args += ["--loop", f"{loop}"]
        if pluck:
            args += ["--pluck", "1"]
        return args
    return CaptureEngine(command, speaks_rt=True)


def demo_outputs():
    from .capture import OutputDevice
    return [OutputDevice("demo.headphones", 2, "Headphones (Demo)", "pci", "alsa", True),
            OutputDevice("demo.spark.out", 3, "Spark MINI (Demo)", "usb", "alsa", False)]
