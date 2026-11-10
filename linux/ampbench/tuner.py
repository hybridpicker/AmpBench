"""The tuner's engine and model. A port of Sources/SparkCore/TunerEngine.swift and Sources/SparkTunerUI/TunerModel.swift.

The engine runs the `PitchTracker` on a thread of its own; the input's reader thread only hands samples to it. The
model listens only while the area Stimmgerät shows. It reads the recorder's input along with it (`RecorderModel.share`)
instead of opening a second one. It sends nothing to the amp, plays no sound, stores no audio, with one exception the
user picks: the source "Stimmgerät des Verstärkers" switches the amp's own tuner on while the area shows and off when
it is left. "Automatisch", the default, takes the Spark's USB input when the connected amp has one, and the amp's own
tuner otherwise.
"""
from __future__ import annotations

import collections
import threading
import time
from dataclasses import dataclass

from PySide6.QtCore import QObject, QSettings, QTimer, Signal

from . import tuning as tun
from .i18n import tr
from .pitch import PitchTracker


@dataclass
class Snapshot:
    reading: tun.PitchReading | None = None
    has_signal: bool = False
    level_db: float = -120.0
    time: float = 0.0
    sample_rate: float = 0.0
    is_receiving: bool = False


class TunerEngine:
    """Reads samples handed over by the input on its own thread, every 5 ms, and runs the tracker there. The UI takes
    the latest `Snapshot` whenever it redraws. Only reads: opens no device, sends nothing, writes nothing."""

    def __init__(self):
        self._queue: collections.deque = collections.deque(maxlen=400)
        self._lock = threading.Lock()
        self._latest = Snapshot()
        self._thread: threading.Thread | None = None
        self._running = False
        self._wake = threading.Event()

    # The input's reader thread calls this: it only hands on.
    def feed(self, samples, sample_rate: float) -> None:
        if self._running:
            self._queue.append((samples, sample_rate))
            self._wake.set()

    @property
    def snapshot(self) -> Snapshot:
        with self._lock:
            return self._latest

    @property
    def is_running(self) -> bool:
        return self._running

    def start(self) -> None:
        if self._running:
            return
        self._queue.clear()
        self._running = True
        self._thread = threading.Thread(target=self._loop, name="spark-tuner", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._running = False
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout=1)
            self._thread = None
        self._queue.clear()
        self._publish(Snapshot())

    def _loop(self) -> None:
        tracker: PitchTracker | None = None
        quiet_since: float | None = None
        while self._running:
            self._wake.wait(0.005)
            self._wake.clear()
            received = 0
            while self._queue:
                samples, rate = self._queue.popleft()
                if tracker is None or tracker.sample_rate != rate:
                    tracker = PitchTracker(rate)  # a new stream or another rate: the old pitch means nothing
                tracker.process(samples)
                received += len(samples)
            now = time.monotonic()
            if received:
                quiet_since = None
            elif quiet_since is None:
                quiet_since = now
            # No samples for a quarter second: the input has stopped, so nothing is heard.
            receiving = quiet_since is None or now - quiet_since < 0.25
            if tracker is None:
                self._publish(Snapshot())
                continue
            if not receiving and tracker.time > 0:
                tracker.reset()
            self._publish(Snapshot(tracker.reading, tracker.has_signal, tracker.level_db, tracker.seconds,
                                   tracker.sample_rate, receiving and tracker.time > 0))

    def _publish(self, snapshot: Snapshot) -> None:
        with self._lock:
            self._latest = snapshot


def clamp_a4(value: float) -> float:
    """Tenths of a hertz within 430 to 450."""
    low, high = tun.A4_RANGE
    return tun.round_half_away(min(max(value, low), high) * 10) / 10


class TunerModel(QObject):
    """The tuner's state in the UI thread: where it listens, what it hears, and the settings."""
    changed = Signal()

    SOURCES = ("automatic", "deck", "amp")

    def __init__(self, recorder=None, link=None, settings: QSettings | None = None, parent=None):
        super().__init__(parent)
        self.recorder, self.link = recorder, link
        self._settings = settings or QSettings("local.ampbench", "AmpBench")
        self.tuning = tun.Tuning.named(self._settings.value("tunerTuning"))
        self.a4 = clamp_a4(float(self._settings.value("tunerA4", tun.DEFAULT_A4)))
        self.shows_strobe = str(self._settings.value("tunerStrobe", "false")).lower() == "true"
        source = self._settings.value("tunerSource")
        self.source = source if source in self.SOURCES else "automatic"
        self.current = "deck"   # what is used now; never "automatic"
        self.status = "idle"    # idle, opening, listening, no_input, failed, demo
        self.failure = ""
        self.readout: tun.TunerReadout | None = None
        self.has_signal = False
        self.level = 0.0
        self.is_shared_with_recording = False
        self.is_active = False
        self.engine = TunerEngine()
        self._interpreter = tun.TunerInterpreter(self.tuning, self.a4)
        self._amp_interpreter = tun.AmpTunerInterpreter(self.tuning, self.a4)
        self._amp_requested = False
        self._next_attempt = 0.0
        self._listener = self.engine.feed
        self._timer = QTimer(self)
        self._timer.setInterval(33)
        self._timer.timeout.connect(self._tick)
        self._demo_timer: QTimer | None = None
        if link is not None:
            link.tuner_reading.connect(self._amp_reading)

    # MARK: Settings

    def set_tuning(self, key: str) -> None:
        self.tuning = tun.Tuning.named(key)
        self._interpreter.tuning = self._amp_interpreter.tuning = self.tuning
        self._settings.setValue("tunerTuning", self.tuning.key)
        self.changed.emit()

    def set_a4(self, value: float) -> None:
        self.a4 = clamp_a4(value)
        self._interpreter.a4 = self._amp_interpreter.a4 = self.a4
        self._settings.setValue("tunerA4", self.a4)
        self.changed.emit()

    def set_strobe(self, on: bool) -> None:
        self.shows_strobe = on
        self._settings.setValue("tunerStrobe", "true" if on else "false")
        self.changed.emit()

    # MARK: Names

    @property
    def amp_name(self) -> str | None:
        return self.link.amp_tuner_device if self.link is not None else None

    @property
    def deck_input_name(self) -> str | None:
        if self.recorder is None:
            return None
        if self.recorder.selected is None:
            self.recorder.refresh_devices()
        return self.recorder.selected.title if self.recorder.selected else None

    @property
    def resolved(self) -> str:
        """What "Automatisch" stands for now."""
        if self.source != "automatic":
            return self.source
        if self.amp_name is None:
            return "deck"
        return "amp" if self.link.amp_tuner_preferred or self.deck_input_name is None else "deck"

    @property
    def uses_amp(self) -> bool:
        return self.current == "amp"

    @property
    def input_name(self) -> str:
        if self.source == "automatic":
            now = (tr("{} tuner", self.amp_name) if self.amp_name else tr("Tuner")) if self.resolved == "amp" \
                else (self.deck_input_name or tr("No Spark"))
            return tr("Automatic: {}", now)
        if self.source == "deck":
            return self.deck_input_name or tr("No Spark")
        return tr("{} tuner", self.amp_name) if self.amp_name else tr("No amp connected")

    # MARK: Listening only while the area shows

    def set_active(self, active: bool) -> None:
        if active == self.is_active:
            return
        self.is_active = active
        if active:
            self.engine.start()
            self._connect()
            self._timer.start()
        else:
            self._timer.stop()
            self._disconnect()
            self.engine.stop()
            self.readout, self.has_signal, self.level = None, False, 0.0
            if self.status != "demo":
                self.status = "idle"
        self.changed.emit()

    def choose(self, source: str) -> None:
        if source not in self.SOURCES or source == self.source:
            return
        self._settings.setValue("tunerSource", source)
        if not self.is_active or self.status == "demo":
            self.source = source
            self.changed.emit()
            return
        self._disconnect()
        self.source = source
        self._connect()
        self.changed.emit()

    def _connect(self) -> None:
        if not self.is_active or self.status == "demo":
            return
        self.current = self.resolved
        if self.current == "amp":
            if self.amp_name is None:
                self.status = "no_input"
                return
            self._amp_interpreter.reset()
            self._amp_requested = True
            self.link.want_amp_tuner(True)
            self.status = "listening" if self.link.core.is_amp_tuner_on else "opening"
            return
        if self.recorder is None:
            self.status = "no_input"
            return
        problem = self.recorder.share(self._listener)
        if problem is None:
            self.status = "listening"
        elif problem == "no_input":
            self.status = "no_input"
        else:
            self.status, self.failure = "failed", problem

    def _disconnect(self) -> None:
        if self._amp_requested:
            self._amp_requested = False
            if self.link is not None:
                self.link.want_amp_tuner(False)
            self._amp_interpreter.reset()
        if self.recorder is not None:
            self.recorder.stop_sharing(self._listener)

    def _amp_reading(self, reading) -> None:
        if self.current == "amp" and self.is_active:
            pitch_class, cents = reading
            self._amp_interpreter.add(pitch_class, cents, time.monotonic())

    # MARK: Every frame

    def _tick(self) -> None:
        now = time.monotonic()
        if self.status != "demo":
            self._keep_connected(now)
        self.is_shared_with_recording = self.current == "deck" and self.status == "listening" \
            and self.recorder is not None and self.recorder.is_held_open
        if self.current == "amp" and self.status != "demo":
            self.readout = self._amp_interpreter.readout(now) if self.status == "listening" else None
            self.has_signal = self.status == "listening" and self._amp_interpreter.has_signal
            self.level = 0.0
            self.changed.emit()
            return
        snapshot = self.engine.snapshot
        self.readout = self._interpreter.interpret(snapshot.reading, now)
        self.has_signal = snapshot.has_signal
        target = min(max((snapshot.level_db + 60) / 60, 0.0), 1.0) if snapshot.is_receiving else 0.0
        self.level = max(target, self.level * 0.85)
        self.changed.emit()

    def _keep_connected(self, now: float) -> None:
        """Notices a lost input and tries again once a second."""
        # "Automatisch" follows the devices: the NEO connected, the USB cable plugged in.
        if self.source == "automatic" and self.is_active and self.resolved != self.current and self.status != "opening":
            self._disconnect()
            self._connect()
            return
        if self.current == "amp":
            if self.status in ("listening", "opening"):
                if self.amp_name is None:
                    self._disconnect()
                    self.status = "no_input"
                elif self.link.core.is_amp_tuner_on:
                    self.status = "listening"
                elif self.status == "listening":
                    self.status = "opening"  # the connection came back: the link switches the tuner on again
            elif self.status in ("no_input", "failed") and self.amp_name is not None and now >= self._next_attempt:
                self._next_attempt = now + 1
                self._connect()
            return
        if self.status == "listening" and not (self.recorder is not None and self.recorder.is_sharing(self._listener)):
            self._disconnect()
            self.status = "no_input"
            self._next_attempt = now + 1
        elif self.status in ("no_input", "failed") and now >= self._next_attempt:
            self._next_attempt = now + 1
            self._connect()

    # MARK: Demo

    def start_demo(self, frequency: float) -> None:
        """Plays a synthetic string into the tuner, for screenshots and tests. Nothing is opened."""
        from . import tuner_signal
        self._disconnect()
        self.status = "demo"
        rate = 48_000.0
        samples = tuner_signal.adding_noise(tuner_signal.karplus_strong(frequency, rate, 6, ring_time=12), -45)
        position = [0]
        chunk = int(rate / 100)

        def step():
            if position[0] >= len(samples):
                return
            self.engine.feed(samples[position[0]:position[0] + chunk], rate)
            position[0] += chunk

        self._demo_timer = QTimer(self)
        self._demo_timer.setInterval(10)
        self._demo_timer.timeout.connect(step)
        self._demo_timer.start()

    def end_demo(self) -> None:
        if self._demo_timer is not None:
            self._demo_timer.stop()
            self._demo_timer = None
        self.status = "idle"
        if self.is_active:
            self._connect()
