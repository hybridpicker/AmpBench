"""A stand-in for native/ampbench-rt for tests and the demo: the same arguments, the same stdout and event lines.

It delivers input frames in real time (quiet noise) and plays no sound. With ``--loop <seconds>`` every click that
sounds comes back into the input that much later, like the BlackHole loop on the Mac or an earbud held on the
pickup: a note played exactly on the click. ``--latency <input> <output>`` sets what the "devices" report.

    python -m ampbench.fake_rt --target x --rate 48000 --channels 2 [--loop 0.0254] [--latency 0.002 0.0017]
"""
from __future__ import annotations

import math
import os
import select
import sys
import time

import numpy as np

CHUNK = 0.01


def main(argv: list[str]) -> int:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--target")
    parser.add_argument("--rate", type=int, default=48000)
    parser.add_argument("--channels", type=int, default=2)
    parser.add_argument("--loop", type=float)
    parser.add_argument("--latency", type=float, nargs=2, default=(0.002, 0.004))
    parser.add_argument("--pluck")
    options = parser.parse_args(argv)
    rate, channels, loop, pluck = options.rate, options.channels, options.loop, options.pluck is not None
    latency_in, latency_out = options.latency
    out = sys.stdout.buffer
    events = sys.stderr

    def event(text: str) -> None:
        events.write("@" + text + "\n")
        events.flush()

    os.set_blocking(sys.stdin.fileno(), False)
    event("state capture streaming")
    event(f"format {rate} {channels}")
    event(f"latency {latency_in:.6f} {latency_out:.6f}")
    start = time.monotonic()
    frames = 0
    pending = b""
    click = None  # dict(id, bpm, beats, volume, mute, anchor, told)
    chunk = int(rate * CHUNK)
    noise = np.random.default_rng(7)
    decay = 0.012
    while True:
        # Commands
        ready, _, _ = select.select([sys.stdin], [], [], 0)
        if ready:
            try:
                data = os.read(sys.stdin.fileno(), 4096)
            except BlockingIOError:
                data = b""
            if ready and not data:
                return 0
            pending += data
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                words = line.decode().split()
                if not words:
                    continue
                if words[0] == "click" and len(words) >= 7:
                    click = {"id": int(words[1]), "bpm": float(words[2]), "beats": int(words[3]),
                             "volume": float(words[4]), "mute": int(words[5]), "anchor": frames + chunk // 2,
                             "told": -1, "anchor_told": False}
                    event(f"state click {click['id']} streaming")
                    event(f"latency {latency_in:.6f} {latency_out:.6f}")
                elif words[0] == "tempo" and click and len(words) >= 4:
                    click["bpm"], click["beats"], click["volume"] = float(words[1]), int(words[2]), float(words[3])
                elif words[0] == "mute" and click:
                    click["mute"] = int(words[1])
                elif words[0] == "stop":
                    click = None
        # Audio, paced by the clock
        due = int((time.monotonic() - start) * rate)
        if frames + chunk > due:
            time.sleep(max((frames + chunk - due) / rate, 0.001))
            continue
        block = noise.normal(0, 0.0005, chunk)
        if pluck:
            n = np.arange(frames, frames + chunk)
            age = (n % (rate // 2)) / rate
            block += 0.5 * np.exp(-age * 5) * np.sin(2 * np.pi * 220 * n / rate)
        if click is not None:
            interval = rate * 60 / click["bpm"]
            if loop is not None:
                # Every beat that sounds, back in the input ``loop`` seconds after the click left.
                first = max(int(math.floor((frames - click["anchor"] - loop * rate) / interval)) - 1, 0)
                k = first
                while True:
                    at = click["anchor"] + k * interval + loop * rate
                    if at >= frames + chunk:
                        break
                    muted = click["mute"] >= 0 and k >= click["mute"]
                    if not muted:
                        accent = k % click["beats"] == 0
                        frequency = 1760.0 if accent else 1175.0
                        n = np.arange(frames, frames + chunk)
                        t = (n - at) / rate
                        live = (t >= 0) & (t < 0.1)
                        block[live] += np.sin(2 * np.pi * frequency * t[live]) * np.exp(-t[live] / decay) \
                            * click["volume"] * (1.0 if accent else 0.7)
                    k += 1
            if not click["anchor_told"]:
                event(f"anchor {click['id']} {click['anchor']:.4f}")
                click["anchor_told"] = True
            started = int(math.floor((frames + chunk - click["anchor"]) / interval)) + 1 \
                if frames + chunk >= click["anchor"] else 0
            if started != click["told"]:
                event(f"beats {click['id']} {started} 0")
                click["told"] = started
        samples = np.clip(block, -1, 1)
        ints = (samples * 2147483647).astype("<i4")
        try:
            out.write(np.repeat(ints[:, None], channels, axis=1).tobytes())
            out.flush()
        except (BrokenPipeError, OSError):
            return 0
        frames += chunk


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
