"""Recording from a Spark's USB input through PipeWire.

The Mac app records on its own AUHAL unit with real-time C code. Here ``pw-record`` captures the device in its own
process and delivers raw 32-bit samples; a reader thread of this app writes them to the WAV file as 24-bit audio,
watches the level and never waits for the user interface. If the app stalls, the pipe buffers it and the file is still
complete; if the app dies, the file is repaired on the next start (``wav.repair``).

Like the Mac app it only uses a USB device whose name holds one of the profiles' USB audio names (devices.py, today
"spark"; the REACTOR's joins once read on the device). There is no microphone fallback.
"""
from __future__ import annotations

import json
import math
import re
import shutil
import subprocess
import threading
import time
from array import array
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import devices as profiles, wav

CHUNK_SECONDS = 0.02
OVERVIEW_BIN = 0.05  # seconds per bin of the live waveform
MIN_FREE_BYTES = 500 * 1024 * 1024
MAX_FILE_BYTES = 3_900_000_000  # just below the 4 GB limit of the WAV format
CLIP_LEVEL = 0.999
SILENCE_DB = -70.0


@dataclass(frozen=True)
class InputDevice:
    node_name: str
    serial: int
    description: str
    bus: str
    rate: int
    channels: int
    is_spark: bool
    bits: int = 24

    @property
    def title(self) -> str:
        return self.description or self.node_name


def list_inputs() -> list[InputDevice]:
    """All audio sources PipeWire knows, with the native format of each (from pactl)."""
    try:
        dump = json.loads(subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=5).stdout or "[]")
    except (OSError, ValueError, subprocess.SubprocessError):
        return []
    formats = _source_formats()
    devices = []
    for item in dump:
        props = (item.get("info") or {}).get("props") or {}
        if item.get("type") != "PipeWire:Interface:Node" or props.get("media.class") != "Audio/Source":
            continue
        name = props.get("node.name", "")
        description = props.get("node.description") or props.get("node.nick") or name
        bus = props.get("device.bus", "")
        rate, channels, bits = formats.get(name, (48000, 2, 24))
        haystack = f"{name} {description} {props.get('device.product.name', '')}".lower()
        devices.append(InputDevice(name, int(props.get("object.serial", 0)), description, bus, rate, channels,
                                   any(part in haystack for part in profiles.recordable_usb_names())
                                   and bus in ("usb", ""), bits))
    return devices


def _source_formats() -> dict[str, tuple[int, int, int]]:
    try:
        text = subprocess.run(["pactl", "list", "short", "sources"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    formats = {}
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) >= 4:
            match = re.search(r"(\w+)\s+(\d+)ch\s+(\d+)Hz", parts[3])
            if match:
                sample = match.group(1)
                bits = 16 if sample.startswith("s16") else 32 if sample.startswith(("s32", "float")) else 24
                formats[parts[1]] = (int(match.group(3)), int(match.group(2)), bits)
    return formats


def spark_inputs() -> list[InputDevice]:
    return [d for d in list_inputs() if d.is_spark]


def free_bytes(folder: Path) -> int:
    probe = folder
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    return shutil.disk_usage(probe).free


def to_db(level: float) -> float:
    return 20 * math.log10(level) if level > 0 else -120.0


@dataclass
class Result:
    path: Path
    frames: int
    seconds: float
    peak: float
    finalized: bool


@dataclass
class Meter:
    """What the display shows. Written by the reader thread, read by the UI."""
    level: float = 0.0
    hold: float = 0.0
    clipped: bool = False
    seconds: float = 0.0
    last_data: float = 0.0
    quiet_since: float | None = None
    hold_time: float = 0.0
    overview: list = field(default_factory=list)
    _bin_peak: float = 0.0
    _bin_frames: int = 0

    def reset_take(self) -> None:
        self.clipped = False
        self.seconds = 0.0
        self.overview = []
        self._bin_peak, self._bin_frames = 0.0, 0


class CaptureEngine:
    """Opens an input, meters it all the time and records on request."""

    def __init__(self, command: Callable[[InputDevice], list[str]] | None = None):
        self._command = command or self._pw_record
        self._process: subprocess.Popen | None = None
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._writer: wav.WAVWriter | None = None
        self._take_peak = 0.0
        self.meter = Meter()
        self.device: InputDevice | None = None
        self.format: wav.Format | None = None
        self.error: str | None = None
        self.lost = False
        self.on_lost: Callable[[], None] | None = None
        self.on_limit: Callable[[], None] | None = None

    @staticmethod
    def _pw_record(device: InputDevice) -> list[str]:
        return ["pw-record", "--target", str(device.serial or device.node_name), "--rate", str(device.rate),
                "--channels", str(device.channels), "--format", "s32", "--latency", "20ms", "--raw", "-"]

    @property
    def is_open(self) -> bool:
        return self._process is not None and not self.lost

    @property
    def is_recording(self) -> bool:
        return self._writer is not None

    def open(self, device: InputDevice) -> None:
        if self.is_open:
            return
        self.device, self.error, self.lost = device, None, False
        self.format = wav.Format(device.rate, device.channels, 24)
        self.meter = Meter(last_data=time.monotonic())
        try:
            self._process = subprocess.Popen(self._command(device), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                             bufsize=0)
        except OSError as error:
            self._process = None
            raise RuntimeError(f"pw-record lässt sich nicht starten: {error}") from error
        self._thread = threading.Thread(target=self._read, args=(self._process, self.format), name="spark-capture",
                                        daemon=True)
        self._thread.start()

    def close(self) -> None:
        process, self._process = self._process, None
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None
        self.meter.level = 0.0

    # Recording

    def start_recording(self, path: Path) -> None:
        if not self.is_open or self.format is None:
            raise RuntimeError("Der Eingang ist nicht offen.")
        with self._lock:
            self._take_peak = 0.0
            self.meter.reset_take()
            self._writer = wav.WAVWriter(path, self.format)

    def stop_recording(self) -> Result | None:
        with self._lock:
            writer, self._writer = self._writer, None
            peak = self._take_peak
        if writer is None:
            return None
        frames = writer.close()
        return Result(writer.path, frames, frames / writer.format.sample_rate, peak, writer.finalized)

    # The reader thread

    def _read(self, process: subprocess.Popen, fmt: wav.Format) -> None:
        frame_bytes = 4 * fmt.channels
        chunk = max(int(fmt.sample_rate * CHUNK_SECONDS), 64) * frame_bytes
        pending = b""
        last_flush = time.monotonic()
        stdout = process.stdout
        while True:
            try:
                data = stdout.read(chunk)
            except (OSError, ValueError):
                break
            if not data:
                break
            data = pending + data
            usable = len(data) - len(data) % frame_bytes
            data, pending = data[:usable], data[usable:]
            if not data:
                continue
            samples = array("i")
            samples.frombytes(data)
            top = max(max(samples), -min(samples)) / 2147483648.0
            now = time.monotonic()
            meter = self.meter
            meter.level, meter.last_data = top, now
            if top >= meter.hold or now - meter.hold_time > 1.5:
                meter.hold, meter.hold_time = top, now
            if top >= CLIP_LEVEL:
                meter.clipped = True
            if to_db(top) > SILENCE_DB:
                meter.quiet_since = None
            elif meter.quiet_since is None:
                meter.quiet_since = now
            with self._lock:
                writer = self._writer
                if writer is not None:
                    writer.write(_to_24_bit(data))
                    self._take_peak = max(self._take_peak, top)
                    meter.seconds = writer.frames / fmt.sample_rate
                    meter._bin_peak = max(meter._bin_peak, top)
                    meter._bin_frames += len(data) // frame_bytes
                    if meter._bin_frames >= fmt.sample_rate * OVERVIEW_BIN:
                        meter.overview.append(meter._bin_peak)
                        meter._bin_peak, meter._bin_frames = 0.0, 0
                    if now - last_flush > 1.0:
                        writer.flush()
                        last_flush = now
                    if writer.data_bytes >= MAX_FILE_BYTES and self.on_limit:
                        self.on_limit()
        # The stream ended: the device is gone, or the engine was closed.
        if self._process is process:
            self.lost = True
            self.meter.level = 0.0
            if self.on_lost:
                self.on_lost()


def _to_24_bit(data: bytes) -> bytes:
    """32-bit little endian samples to 24-bit: the top three bytes of each."""
    out = bytearray(len(data) // 4 * 3)
    out[0::3] = data[1::4]
    out[1::3] = data[2::4]
    out[2::3] = data[3::4]
    return bytes(out)
