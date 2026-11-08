"""Waveform data: minimum and maximum per bin, computed once per take and cached next to the library.

ffmpeg turns any audio file into a low-rate mono stream, which is plenty for drawing a waveform. The cache has its own
name (``.lpeaks``), so it never gets in the way of the Mac app's own waveform files."""
from __future__ import annotations

import json
import subprocess
from array import array
from pathlib import Path

RATE = 4000
BINS_PER_SECOND = 100  # 10 ms per bin


class Waveform:
    def __init__(self, lows: list[float], highs: list[float], duration: float):
        self.lows, self.highs, self.duration = lows, highs, duration

    def __len__(self) -> int:
        return len(self.highs)

    def columns(self, count: int, start: float = 0.0, end: float | None = None) -> list[tuple[float, float]]:
        """``count`` (low, high) pairs covering the time span."""
        end = self.duration if end is None else end
        if count <= 0 or not self.highs or end <= start:
            return []
        per_second = len(self.highs) / max(self.duration, 1e-9)
        result = []
        for i in range(count):
            a = int((start + (end - start) * i / count) * per_second)
            b = max(int((start + (end - start) * (i + 1) / count) * per_second), a + 1)
            a, b = min(a, len(self.highs) - 1), min(b, len(self.highs))
            result.append((min(self.lows[a:b]), max(self.highs[a:b])))
        return result


def compute(path: Path, duration: float) -> Waveform | None:
    try:
        process = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(path), "-vn", "-ac", "1",
                                  "-ar", str(RATE), "-f", "f32le", "pipe:1"], capture_output=True, timeout=300)
    except (OSError, subprocess.SubprocessError):
        return None
    samples = array("f")
    samples.frombytes(process.stdout[: len(process.stdout) // 4 * 4])
    if not samples:
        return None
    size = RATE // BINS_PER_SECOND
    lows, highs = [], []
    for start in range(0, len(samples), size):
        part = samples[start:start + size]
        lows.append(min(part))
        highs.append(max(part))
    return Waveform(lows, highs, len(samples) / RATE if not duration else duration)


def cached(path: Path, cache: Path, duration: float) -> Waveform | None:
    """The waveform of a take, from the cache when it is still the file it was made from."""
    try:
        stat = path.stat()
        key = [stat.st_size, int(stat.st_mtime)]
        if cache.exists():
            data = json.loads(cache.read_text())
            if data.get("key") == key:
                return Waveform(data["lows"], data["highs"], data["duration"])
    except (OSError, ValueError, KeyError):
        pass
    waveform = compute(path, duration)
    if waveform is not None:
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps({"key": key, "duration": waveform.duration,
                                         "lows": [round(v, 4) for v in waveform.lows],
                                         "highs": [round(v, 4) for v in waveform.highs]}))
        except (OSError, UnboundLocalError):
            pass
    return waveform
