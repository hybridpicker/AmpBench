"""Recording from a Spark's USB input through PipeWire.

The Mac app records on its own AUHAL unit with real-time C code. Here ``ampbench-rt`` (native/ampbench-rt.c, built by
install.sh) captures the device in its own process and delivers raw 32-bit samples; a reader thread of this app writes
them to the WAV file as 24-bit audio, watches the level and never waits for the user interface. If the app stalls, the
pipe buffers it and the file is still complete; if the app dies, the file is repaired on the next start
(``wav.repair``). The same helper plays the click on the input's clock, so the bars of a take lie on input frames; the
reader counts every frame it reads, which is how a gate frame and the file's first frame are known exactly. Without
the helper (not built) ``pw-record`` records as before, and there is no click.

Like the Mac app it only uses a USB device whose name holds one of the profiles' USB audio names (devices.py, today
"spark" and "reactor 50"). There is no microphone fallback.
"""
from __future__ import annotations

import json
import math
import os
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
from .i18n import tr

CHUNK_SECONDS = 0.02
OVERVIEW_BIN = 0.05  # seconds per bin of the live waveform
MIN_FREE_BYTES = 500 * 1024 * 1024
MAX_FILE_BYTES = 3_900_000_000  # just below the 4 GB limit of the WAV format
CLIP_LEVEL = 0.999
SILENCE_DB = -70.0
HELPER_FIRST_FRAMES = 3.0  # seconds the helper may take to deliver its first frames


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


@dataclass(frozen=True)
class OutputDevice:
    """A sink the click can go to."""
    node_name: str
    serial: int
    description: str
    bus: str
    api: str
    is_default: bool = False

    @property
    def title(self) -> str:
        return self.description or self.node_name

    @property
    def target(self) -> str:
        return str(self.serial) if self.serial else self.node_name

    @property
    def kind(self) -> str:
        """Wired, or Bluetooth: its delay is not steady enough for a timing review."""
        from .click_timing import BLUETOOTH, WIRED
        return BLUETOOTH if self.api.startswith("bluez") or self.bus == "bluetooth" \
            or self.node_name.startswith("bluez_") else WIRED

    @property
    def is_spark(self) -> bool:
        haystack = f"{self.node_name} {self.description}".lower()
        return any(part in haystack for part in profiles.recordable_usb_names())


def list_outputs() -> list[OutputDevice]:
    """All audio sinks PipeWire knows, the system's default output marked."""
    try:
        dump = json.loads(subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=5).stdout or "[]")
    except (OSError, ValueError, subprocess.SubprocessError):
        return []
    try:
        default = subprocess.run(["pactl", "get-default-sink"], capture_output=True, text=True,
                                 timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        default = ""
    outputs = []
    for item in dump:
        props = (item.get("info") or {}).get("props") or {}
        if item.get("type") != "PipeWire:Interface:Node" or props.get("media.class") != "Audio/Sink":
            continue
        name = props.get("node.name", "")
        outputs.append(OutputDevice(name, int(props.get("object.serial", 0)),
                                    props.get("node.description") or props.get("node.nick") or name,
                                    props.get("device.bus", ""), props.get("device.api", ""), name == default))
    return outputs


def same_hardware(input_device: InputDevice | None, output: OutputDevice) -> bool:
    """Whether the click could end up in the recording because output and input are one device (FeedbackGuard on
    the Mac): the amp reports both under its name."""
    if input_device is None:
        return False
    if output.is_spark and input_device.is_spark:
        return True
    a = input_device.description.lower().strip()
    return bool(a) and a == output.description.lower().strip()


def safe_click_output(input_device: InputDevice | None, outputs: list[OutputDevice],
                      preferred: str | None = None) -> OutputDevice | None:
    """A sink for the click that cannot reach the recording: the chosen one, else the system's default, else the
    first safe one."""
    safe = [o for o in outputs if not same_hardware(input_device, o)]
    for wanted in ([o for o in safe if o.node_name == preferred] if preferred else []) + \
            [o for o in safe if o.is_default] + safe:
        return wanted
    return None


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


def helper_path() -> Path | None:
    """The native helper: ``AMPBENCH_RT`` when set, otherwise ``bin/ampbench-rt`` in the installed app."""
    given = os.environ.get("AMPBENCH_RT")
    path = Path(given) if given else Path(__file__).resolve().parent.parent / "bin" / "ampbench-rt"
    return path if path.is_file() and os.access(path, os.X_OK) else None


@dataclass
class ClickState:
    """What the helper reported about its click and the devices. Written by the event thread."""
    id: int = 0
    running: bool = False
    anchor: float | None = None  # the input frame of beat 0
    beats: int = 0  # beats started
    late: int = 0
    failed: str | None = None
    latency_in: float = 0.0  # seconds, as the devices report them
    latency_out: float = 0.0
    lost: int = 0


class CaptureEngine:
    """Opens an input, meters it all the time and records on request."""

    def __init__(self, command: Callable[[InputDevice], list[str]] | None = None, speaks_rt: bool = False):
        # Without a command: the installed helper, else pw-record. A given command speaks the helper's protocol
        # (stdin commands, "@" events) only when ``speaks_rt`` says so, as ampbench/fake_rt.py does.
        if command is None:
            self._helper = helper_path()
            self._command = self._rt_command if self._helper else self._pw_record
            self.has_click = self._helper is not None
        else:
            self._helper, self._command, self.has_click = None, command, speaks_rt
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
        # Readers along with the recording, such as the tuner: each gets mono samples from −1 to 1 and the rate,
        # on the reader thread, so it must only hand them on.
        self._listeners: list[Callable] = []
        self.click = ClickState()
        # Input frames read since the input was opened, and where the running recording starts.
        self.frames_read = 0
        self._gate: int | None = None
        self.file_first_frame: int | None = None
        self._events: threading.Thread | None = None
        self._click_id = 0
        self.helper_failed = False

    def attach(self, listener: Callable) -> None:
        with self._lock:
            if listener not in self._listeners:
                self._listeners.append(listener)

    def detach(self, listener: Callable) -> None:
        with self._lock:
            if listener in self._listeners:
                self._listeners.remove(listener)

    @property
    def has_listeners(self) -> bool:
        return bool(self._listeners)

    @staticmethod
    def _pw_record(device: InputDevice) -> list[str]:
        return ["pw-record", "--target", str(device.serial or device.node_name), "--rate", str(device.rate),
                "--channels", str(device.channels), "--format", "s32", "--latency", "20ms", "--raw", "-"]

    def _end_if_silent(self, process: subprocess.Popen) -> None:
        if self._process is process and self.frames_read == 0:
            try:
                process.terminate()
            except OSError:
                pass

    def _rt_command(self, device: InputDevice) -> list[str]:
        return [str(self._helper), "--target", str(device.serial or device.node_name), "--rate", str(device.rate),
                "--channels", str(device.channels)]

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
        self.frames_read = 0
        self.click = ClickState()
        helper = self.has_click
        try:
            self._process = subprocess.Popen(self._command(device), stdout=subprocess.PIPE,
                                             stdin=subprocess.PIPE if helper else subprocess.DEVNULL,
                                             stderr=subprocess.PIPE if helper else subprocess.DEVNULL, bufsize=0)
        except OSError as error:
            self._process = None
            raise RuntimeError(tr("pw-record cannot be started: {}", error)) from error
        self._thread = threading.Thread(target=self._read, args=(self._process, self.format), name="spark-capture",
                                        daemon=True)
        self._thread.start()
        if helper:
            self._events = threading.Thread(target=self._read_events, args=(self._process,), name="spark-events",
                                            daemon=True)
            self._events.start()
            # A helper that never delivers is ended, so the reader falls back to pw-record.
            watchdog = threading.Timer(HELPER_FIRST_FRAMES, self._end_if_silent, args=(self._process,))
            watchdog.daemon = True
            watchdog.start()

    def close(self) -> None:
        process, self._process = self._process, None
        self.click.running = False
        if process is not None:
            if process.stdin:
                try:
                    process.stdin.close()
                except OSError:
                    pass
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None
        if self._events is not None:
            self._events.join(timeout=2)
            self._events = None
        self.meter.level = 0.0

    # Recording

    def start_recording(self, path: Path, gate_frame: int | None = None) -> None:
        """Starts writing with the next frame read, or at ``gate_frame`` when that still lies ahead (after a
        count-in)."""
        if not self.is_open or self.format is None:
            raise RuntimeError(tr("The input is not open."))
        with self._lock:
            self._take_peak = 0.0
            self.meter.reset_take()
            self.file_first_frame = None
            self._gate = gate_frame
            self._writer = wav.WAVWriter(path, self.format)

    @property
    def recorded_frames(self) -> int:
        writer = self._writer
        return writer.frames if writer is not None else 0

    # The click, on the input's clock

    def _send(self, line: str) -> bool:
        process = self._process
        if process is None or process.stdin is None:
            return False
        try:
            process.stdin.write((line + "\n").encode())
            process.stdin.flush()
            return True
        except (OSError, ValueError):
            return False

    def click_start(self, bpm: float, beats_per_bar: int, volume: float, mute_from: int, target: str) -> bool:
        """Starts the click on ``target`` (a sink's serial or node name). Its beat 0 lands on ``click.anchor``."""
        if not self.has_click or not self.is_open:
            return False
        self._click_id += 1
        self.click = ClickState(self._click_id, running=True, latency_in=self.click.latency_in)
        ok = self._send(f"click {self._click_id} {bpm:.6f} {max(int(beats_per_bar), 1)} {min(max(volume, 0.0), 1.0):.4f} "
                        f"{int(mute_from)} {target or '-'}")
        self.click.running = ok
        return ok

    def click_tempo(self, bpm: float, beats_per_bar: int, volume: float) -> None:
        self._send(f"tempo {bpm:.6f} {max(int(beats_per_bar), 1)} {min(max(volume, 0.0), 1.0):.4f}")

    def click_mute_from(self, beat: int) -> None:
        """Silences the click from this beat on, -1 lets it sound. It keeps counting either way."""
        self._send(f"mute {int(beat)}")

    def click_stop(self) -> None:
        if self.click.running:
            self._send("stop")
        self.click = ClickState(latency_in=self.click.latency_in)

    def _read_events(self, process: subprocess.Popen) -> None:
        for raw in process.stderr:
            line = raw.decode(errors="replace").strip()
            if not line.startswith("@"):
                continue
            parts = line[1:].split()
            try:
                self._event(parts)
            except (IndexError, ValueError):
                continue

    def _event(self, parts: list[str]) -> None:
        kind, click = parts[0], self.click
        if kind == "anchor" and int(parts[1]) == click.id:
            click.anchor = float(parts[2])
        elif kind == "beats" and int(parts[1]) == click.id:
            click.beats, click.late = int(parts[2]), int(parts[3])
        elif kind == "latency":
            click.latency_in, click.latency_out = float(parts[1]), float(parts[2])
        elif kind == "lost":
            click.lost = int(parts[1])
        elif kind == "state" and parts[1] == "click" and int(parts[2]) == click.id and click.running \
                and parts[3] in ("error", "unconnected"):
            click.failed = " ".join(parts[4:]) or parts[3]
            click.running = False

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
            first_frame = self.frames_read
            self.frames_read += len(data) // frame_bytes
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
            listeners = list(self._listeners)
            if listeners:
                import numpy as np
                frames = np.frombuffer(data, dtype="<i4").reshape(-1, fmt.channels)
                mono = frames.mean(axis=1) / 2147483648.0
                for listener in listeners:
                    listener(mono, fmt.sample_rate)
            with self._lock:
                writer = self._writer
                if writer is not None and self._gate is not None:
                    # After a count-in the file starts exactly on the gate frame.
                    skip = self._gate - first_frame
                    if skip >= len(data) // frame_bytes:
                        writer = None
                    else:
                        if skip > 0:
                            data, first_frame = data[skip * frame_bytes:], self._gate
                        self._gate = None
                if writer is not None:
                    if self.file_first_frame is None:
                        self.file_first_frame = first_frame
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
        if self._process is process and self.has_click and self.frames_read == 0:
            # The helper never delivered: record with pw-record for the rest of the session, without the click,
            # rather than not at all.
            self._helper, self.has_click, self._command = None, False, self._pw_record
            self.helper_failed = True
            self._process = None
            try:
                self.open(self.device)
                return
            except RuntimeError:
                pass
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
