"""WAV files: a writer that survives a crash, and the repair of files whose sizes were never finalized.

A port of SparkCore/WAVFile.swift. Repair only changes header size fields and cuts a trailing partial frame; audio data
is never rewritten.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

MAX_DATA = 0xFFFFFFFF - 64


class WAVError(Exception):
    pass


@dataclass(frozen=True)
class Format:
    sample_rate: int
    channels: int
    bits: int

    @property
    def bytes_per_frame(self) -> int:
        return self.channels * ((self.bits + 7) // 8)


def header(fmt: Format, data_size: int = 0) -> bytes:
    """The 44 byte header of a PCM WAV file. ``data_size`` 0 is what a recording in progress carries."""
    block = fmt.bytes_per_frame
    return (b"RIFF" + struct.pack("<I", 36 + data_size if data_size else 0) + b"WAVE" + b"fmt "
            + struct.pack("<IHHIIHH", 16, 1, fmt.channels, fmt.sample_rate, fmt.sample_rate * block, block, fmt.bits)
            + b"data" + struct.pack("<I", data_size))


class WAVWriter:
    """Writes 24-bit (or 16-bit) PCM continuously. The sizes in the header are set when the file is closed; after a
    crash they stay 0 and ``repair`` fixes them."""

    def __init__(self, path: Path, fmt: Format):
        self.path, self.format = path, fmt
        self.file = open(path, "wb", buffering=1 << 16)
        self.file.write(header(fmt))
        self.frames = 0
        self.finalized = False

    @property
    def data_bytes(self) -> int:
        return self.frames * self.format.bytes_per_frame

    def write(self, pcm: bytes) -> None:
        frame = self.format.bytes_per_frame
        usable = len(pcm) - len(pcm) % frame
        self.file.write(pcm[:usable])
        self.frames += usable // frame

    def flush(self) -> None:
        self.file.flush()

    def close(self) -> int:
        """Finalizes the header. Returns the frames written."""
        if self.file.closed:
            return self.frames
        size = min(self.data_bytes, MAX_DATA)
        self.file.flush()
        self.file.seek(4)
        self.file.write(struct.pack("<I", 36 + size))
        self.file.seek(40)
        self.file.write(struct.pack("<I", size))
        self.file.flush()
        self.file.close()
        self.finalized = True
        return self.frames


@dataclass
class Layout:
    format: Format | None = None
    data_size_offset: int | None = None
    data_start: int | None = None
    declared: int = 0
    file_size: int = 0
    is_rf64: bool = False


def _layout(handle) -> Layout:
    layout = Layout()
    handle.seek(0, 2)
    layout.file_size = handle.tell()
    if layout.file_size < 12:
        raise WAVError("Die Datei ist zu kurz.")
    handle.seek(0)
    head = handle.read(12)
    magic = head[:4]
    if magic not in (b"RIFF", b"RF64") or head[8:12] != b"WAVE":
        raise WAVError("Die Datei ist keine WAV-Datei.")
    layout.is_rf64 = magic == b"RF64"
    offset = 12
    while offset + 8 <= layout.file_size:
        handle.seek(offset)
        chunk = handle.read(8)
        if len(chunk) < 8:
            break
        chunk_id, size = chunk[:4], struct.unpack("<I", chunk[4:])[0]
        if chunk_id == b"fmt ":
            body = handle.read(16)
            if len(body) < 16:
                raise WAVError("Die Datei ist zu kurz.")
            channels, rate = struct.unpack("<HI", body[2:8])
            bits = struct.unpack("<H", body[14:16])[0]
            layout.format = Format(rate, channels, bits)
        elif chunk_id == b"data":
            layout.data_size_offset, layout.data_start, layout.declared = offset + 4, offset + 8, size
            break
        offset += 8 + size + (size & 1)
    return layout


def inspect(path: Path):
    """("ok"|"needs_repair"|"empty"|"unreadable", format or message, frames)."""
    try:
        with open(path, "rb") as handle:
            layout = _layout(handle)
    except WAVError as error:
        return "unreadable", str(error), 0
    except OSError:
        return "unreadable", "Die Datei konnte nicht gelesen werden.", 0
    fmt = layout.format
    if fmt is None or fmt.channels <= 0 or fmt.bytes_per_frame <= 0 or fmt.sample_rate <= 0:
        return "unreadable", "Das Format der Datei ist nicht lesbar.", 0
    if layout.data_start is None:
        return "unreadable", "Die Datei enthält keine Audiodaten.", 0
    available = layout.file_size - layout.data_start
    frame = fmt.bytes_per_frame
    frames = available // frame
    if layout.is_rf64:
        return "ok", fmt, frames
    if available < frame:
        return "empty", fmt, 0
    if 0 < layout.declared <= available:
        return "ok", fmt, layout.declared // frame
    return "needs_repair", fmt, frames


def repair(path: Path, treat_trailing_data_as_audio: bool = False) -> int:
    """Fixes the header sizes in place and returns the number of recovered frames."""
    with open(path, "r+b") as handle:
        layout = _layout(handle)
        fmt = layout.format
        if fmt is None or layout.data_start is None or layout.data_size_offset is None:
            raise WAVError("Die Datei ist keine WAV-Datei.")
        available = layout.file_size - layout.data_start
        frame = fmt.bytes_per_frame
        finalized = 0 < layout.declared <= available
        if finalized and not treat_trailing_data_as_audio:
            return layout.declared // frame
        frames = available // frame
        data_bytes = frames * frame
        if data_bytes > MAX_DATA:
            raise WAVError("Die Datei ist zu groß für das WAV-Format.")
        handle.seek(layout.data_start + data_bytes)
        handle.truncate()
        handle.seek(4)
        handle.write(struct.pack("<I", 36 + data_bytes if layout.data_start == 44 else layout.data_start - 8 + data_bytes))
        handle.seek(layout.data_size_offset)
        handle.write(struct.pack("<I", data_bytes))
        return frames
