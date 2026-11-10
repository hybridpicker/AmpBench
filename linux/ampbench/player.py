"""Playback of a take: ffmpeg decodes, applies gain, loop, tempo and pitch (rubberband), and pw-cat plays.

Tempo and pitch are independent, as in the Mac app (tempo 50–150 %, pitch ±12 semitones). Every change of position,
loop, tempo or pitch restarts the pipeline at the current position; the playhead follows the clock, which is exact
enough for practicing and never drifts far, because it is re-anchored at every restart."""
from __future__ import annotations

import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path

TEMPO_RANGE = (0.5, 1.5)
PITCH_RANGE = (-12, 12)
STARTUP = 0.12  # seconds from starting the pipeline until sound comes out


@dataclass
class Track:
    path: Path
    duration: float
    gain_db: float = 0.0
    trim_start: float = 0.0
    trim_end: float | None = None
    fade_in: float = 0.0
    fade_out: float = 0.0

    @property
    def end(self) -> float:
        return min(self.trim_end, self.duration) if self.trim_end else self.duration


def filters(track: Track, tempo: float, pitch: int, loop: tuple[float, float] | None, rate: int = 48000) -> str:
    chain = []
    if loop:
        a, b = loop
        chain.append(f"atrim=start={a:.4f}:end={b:.4f},asetpts=PTS-STARTPTS,aloop=loop=-1:size={int((b - a) * rate)}")
    elif track.trim_end:
        chain.append(f"atrim=end={track.end:.4f}")
    if track.gain_db:
        chain.append(f"volume={track.gain_db:.2f}dB")
    if tempo != 1.0 or pitch:
        chain.append(f"rubberband=tempo={tempo:.4f}:pitch={2 ** (pitch / 12):.6f}")
    return ",".join(chain) or "anull"


def command(track: Track, position: float, tempo: float, pitch: int, loop: tuple[float, float] | None,
            rate: int = 48000) -> tuple[list[str], list[str]]:
    start = loop[0] if loop else max(position, track.trim_start)
    decode = ["ffmpeg", "-nostdin", "-loglevel", "error", "-ss", f"{start:.4f}", "-i", str(track.path),
              "-vn", "-af", filters(track, tempo, pitch, loop, rate), "-ac", "2", "-ar", str(rate), "-f", "f32le",
              "pipe:1"]
    play = ["pw-cat", "-p", "--raw", "--rate", str(rate), "--channels", "2", "--format", "f32", "--latency", "40ms",
            "--media-role", "Music", "-"]
    return decode, play


class Player:
    """Plays one track at a time. Not tied to Qt: ``position`` is polled, ``on_finished`` is called from a thread."""

    def __init__(self, make_commands=command):
        self._make = make_commands
        self.track: Track | None = None
        self.tempo, self.pitch = 1.0, 0
        self.loop: tuple[float, float] | None = None
        self._anchor_time = 0.0
        self._anchor_pos = 0.0
        self._paused_at = 0.0
        self._procs: list[subprocess.Popen] = []
        self.is_playing = False
        self.on_finished = None
        self._generation = 0

    # State

    def load(self, track: Track | None) -> None:
        self.stop()
        self.track = track
        self.loop = None
        self._paused_at = track.trim_start if track else 0.0

    @property
    def position(self) -> float:
        if self.track is None:
            return 0.0
        if not self.is_playing:
            return self._paused_at
        elapsed = max(time.monotonic() - self._anchor_time - STARTUP, 0.0) * self.tempo
        if self.loop:
            a, b = self.loop
            return a + (elapsed % max(b - a, 0.05))
        return min(self._anchor_pos + elapsed, self.track.end)

    # Control

    def play(self, position: float | None = None) -> None:
        if self.track is None:
            return
        start = self._paused_at if position is None else position
        if start >= self.track.end - 0.05:
            start = self.track.trim_start
        self._start(start)

    def pause(self) -> None:
        if self.is_playing:
            self._paused_at = self.position
        self._kill()
        self.is_playing = False

    def stop(self) -> None:
        self.pause()

    def toggle(self) -> None:
        self.pause() if self.is_playing else self.play()

    def seek(self, position: float) -> None:
        if self.track is None:
            return
        position = min(max(position, self.track.trim_start), self.track.end)
        if self.is_playing:
            self._start(position)
        else:
            self._paused_at = position

    def set_tempo(self, tempo: float) -> None:
        tempo = round(min(max(tempo, TEMPO_RANGE[0]), TEMPO_RANGE[1]), 4)
        if tempo != self.tempo:
            self.tempo = tempo
            self._restart()

    def set_pitch(self, pitch: int) -> None:
        pitch = int(min(max(pitch, PITCH_RANGE[0]), PITCH_RANGE[1]))
        if pitch != self.pitch:
            self.pitch = pitch
            self._restart()

    def set_loop(self, loop: tuple[float, float] | None) -> None:
        if loop and loop[1] - loop[0] < 0.1:
            loop = None
        if loop != self.loop:
            keep = self.position
            self.loop = loop
            if self.is_playing:
                self._start(loop[0] if loop else keep)

    def set_gain(self, gain_db: float) -> None:
        if self.track and self.track.gain_db != gain_db:
            self.track.gain_db = gain_db
            self._restart()

    # The pipeline

    def _restart(self) -> None:
        if self.is_playing:
            self._start(self.position)

    def _start(self, position: float) -> None:
        self._kill()
        decode, play = self._make(self.track, position, self.tempo, self.pitch, self.loop)
        try:
            ffmpeg = subprocess.Popen(decode, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            sink = subprocess.Popen(play, stdin=ffmpeg.stdout, stderr=subprocess.DEVNULL)
            ffmpeg.stdout.close()
        except OSError:
            self.is_playing = False
            return
        self._procs = [ffmpeg, sink]
        self._anchor_time = time.monotonic()
        self._anchor_pos = self.loop[0] if self.loop else max(position, self.track.trim_start)
        self.is_playing = True
        threading.Thread(target=self._watch, args=(self._generation, sink), daemon=True).start()

    def _watch(self, generation: int, sink: subprocess.Popen) -> None:
        sink.wait()
        if generation == self._generation and self.is_playing:
            self.is_playing = False
            self._paused_at = self.track.end if self.track and not self.loop else self._paused_at
            if self.on_finished:
                self.on_finished()

    def _kill(self) -> None:
        self._generation += 1  # whatever ends now was stopped on purpose, not played to its end
        procs, self._procs = self._procs, []
        for proc in procs:
            try:
                proc.terminate()
            except OSError:
                pass
        for proc in procs:
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
