"""The recording model: which Spark is the input, starting and stopping a take, and the library behind it.

The flow follows AppModel.startRecording / stopRecording of the Mac app: a journal is written before the first sample,
the take is added to the library only when it is safely on disk, and the journal goes last.

The click (Mac: ClickEngine on the input's clock) is played by the capture helper. With a count-in the file starts
``COUNT_IN_PRE_ROLL`` before bar 1; with the click on and no count-in it starts at once and bar 1 is the click's
first beat. Either way the take's bars (``grid``) come from the click's anchor frame, the file's first frame and the
click latency, and the take's timing stamp says whether the click stayed on and which latency the bars rest on.
"""
from __future__ import annotations

import json
import os
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QObject, QSettings, QTimer, Signal

from . import capture, click_timing as ct, latency_probe, protocol, store as storemod
from .beat_grid import BeatGrid
from .capture import CaptureEngine, InputDevice, OutputDevice
from .i18n import number, tr

COUNT_IN_PRE_ROLL = 0.15  # seconds of the file before bar 1 after a count-in
ANCHOR_WAIT = 1.0  # seconds the click may take to place its first beat once the input delivers
INPUT_WAIT = 3.0  # seconds a freshly opened input may take to deliver its first frames
AMP_LATENCIES_KEY = "clickLatencyAmpParts"


class RecorderModel(QObject):
    phase_changed = Signal(str)  # idle, countin, recording
    devices_changed = Signal()
    meter_changed = Signal()
    message = Signal(str, str)  # kind, text
    library_changed = Signal()
    take_added = Signal(str)
    monitoring_changed = Signal(bool)

    def __init__(self, store: storemod.LibraryStore, engine: CaptureEngine | None = None,
                 devices: Callable[[], list[InputDevice]] = capture.spark_inputs,
                 outputs: Callable[[], list[OutputDevice]] | None = None, settings: QSettings | None = None,
                 parent=None):
        super().__init__(parent)
        self.store = store
        self.engine = engine or CaptureEngine()
        self._devices_provider = devices
        # The real sinks go with the real inputs; a test or the demo that brings its own inputs brings its outputs.
        self._outputs_provider = outputs or (capture.list_outputs if devices is capture.spark_inputs else list)
        self.devices: list[InputDevice] = []
        self.outputs: list[OutputDevice] = []
        self.selected: InputDevice | None = None
        self.phase = "idle"
        self.is_monitoring = False
        self.usable = False
        self.active_journal: dict | None = None
        self.active_start: datetime | None = None
        self.active_source: dict | None = None
        self.auto_level = True
        self.current_piece_id: str | None = None
        self.sound_provider = None  # () -> (preset, slot or None, origin) or None
        self.on_click_settings_changed: Callable[[], None] | None = None  # saves the settings, set by the window
        # The metronome's settings (metronome.Settings): tempo, meter, count-in, click on, volume. Set by the window.
        self.click_settings: Callable[[], object] | None = None
        self.count_in_left = 0
        self.active_grid: BeatGrid | None = None
        self._click_bpm = 0.0
        self._click_beats = 4
        self._count_in_beats = 0
        self._latency = ct.ClickLatency()
        self._watch: ct.ClickWatch | None = None
        self._waiting_anchor: tuple | None = None  # (path, deadline, settings) while a count-in waits for its click
        self._measuring: dict | None = None  # the click latency measurement under way
        self._last_reported: float | None = None
        self.engine.on_lost = lambda: QTimer.singleShot(0, self._device_lost)
        self.engine.on_limit = lambda: QTimer.singleShot(0, lambda: self.stop(
            tr("The recording reached the size limit of a WAV file and was ended safely.")))
        self._timer = QTimer(self)
        self._timer.setInterval(33)
        self._timer.timeout.connect(self._tick)
        self._timer.timeout.connect(self.meter_changed.emit)
        self._timer.start()
        self._settings = settings or QSettings("local.ampbench", "AmpBench")
        try:
            self.amp_latencies = ct.AmpLatencies.from_json(json.loads(self._settings.value(AMP_LATENCIES_KEY, "{}")))
        except (TypeError, ValueError):
            self.amp_latencies = ct.AmpLatencies()

    # MARK: Library

    def start_library(self) -> None:
        """Opens the library, repairs a recording a crash left behind and finds files placed in the folder."""
        if not self.store.acquire_lock():
            self.usable = False
            self.message.emit("error", tr("The takes are already in use by another AmpBench that is running. "
                                          "Nothing is recorded here."))
            return
        try:
            outcome = self.store.load()
        except storemod.StoreError as error:
            self.usable = False
            self.message.emit("error", str(error))
            return
        if outcome in ("restored", "started_over"):
            self.message.emit("warning", tr("The library could not be read. The broken file is in the folder as "
                                            "Library.damaged-…."))
        self.usable = True
        recovery = self.store.recover_interrupted()
        if recovery.kind == "repaired":
            self.message.emit("info", tr("The interrupted recording “{}” was repaired ({} s) and is in the library.",
                                         recovery.file_name, f"{recovery.seconds:.0f}"))
        elif recovery.kind == "failed":
            self.message.emit("warning", tr("The interrupted recording “{}” could not be repaired. The file stays "
                                            "unchanged in the folder.", recovery.file_name))
        self.library_changed.emit()

    # MARK: Devices

    def refresh_devices(self) -> None:
        self.devices = self._devices_provider()
        remembered = self._settings.value("input")
        if self.selected is None or all(d.node_name != self.selected.node_name for d in self.devices):
            self.selected = next((d for d in self.devices if d.node_name == remembered), None) or \
                (self.devices[0] if self.devices else None)
        else:
            self.selected = next(d for d in self.devices if d.node_name == self.selected.node_name)
        self.outputs = self._outputs_provider() if self.engine.has_click else []
        self.devices_changed.emit()

    # MARK: The click output

    @property
    def chosen_click_output(self) -> str | None:
        """The sink chosen for the click by its node name, or None for automatic."""
        return self._settings.value("clickOutput") or None

    def choose_click_output(self, node_name: str | None) -> None:
        self._settings.setValue("clickOutput", node_name or "")
        self.devices_changed.emit()

    @property
    def click_output(self) -> OutputDevice | None:
        """Where the click goes while recording: never to the device being recorded."""
        return capture.safe_click_output(self.selected, self.outputs, self.chosen_click_output)

    @property
    def can_click(self) -> bool:
        return self.engine.has_click

    @property
    def is_click_running(self) -> bool:
        return self.engine.click.running

    @property
    def amp_part(self) -> ct.AmpPart | None:
        return self.amp_latencies.part(self.selected.node_name if self.selected else None)

    def save_amp_latencies(self) -> None:
        self._settings.setValue(AMP_LATENCIES_KEY, json.dumps(self.amp_latencies.to_json()))

    def set_amp_part_by_hand(self, seconds: float) -> None:
        """A hand-set part still corrects the bars, but enables no timing review."""
        if self.selected is None:
            return
        self.amp_latencies.set_by_hand(self.selected.node_name, seconds)
        self.save_amp_latencies()
        self.devices_changed.emit()

    @property
    def reported_latency(self) -> float | None:
        """What the devices report from the click into the file: now while a click runs, otherwise the last report
        (the helper only knows it while both streams run)."""
        click = self.engine.click
        if click.running and click.anchor is not None:
            self._last_reported = click.latency_in + click.latency_out
        return self._last_reported

    # MARK: Measuring the click latency

    @property
    def is_measuring(self) -> bool:
        return self._measuring is not None

    @property
    def can_measure_latency(self) -> bool:
        return (not self.is_recording and not self.is_measuring and self.selected is not None
                and self.click_output is not None and self.engine.has_click)

    def measure_latency(self) -> None:
        """Plays twelve clicks into the input (a cable or an earbud on the pickup) and measures how late they arrive
        in a file (Mac: AppModel.measureLatency, LatencyProbe.measure). About ten seconds; nothing is kept."""
        if not self.can_measure_latency:
            return
        output = self.click_output
        try:
            latency_probe.check_output(output.kind)
        except latency_probe.LatencyProbeError as error:
            self.message.emit("error", tr("The latency measurement failed: {}", error.text))
            return
        opened = not self.engine.is_open
        try:
            if opened:
                self.engine.open(self.selected)
            handle, name = tempfile.mkstemp(prefix="ampbench-latency-", suffix=".wav")
            os.close(handle)
            path = Path(name)
            # The file starts first, so the stretch before the first click shows the noise floor.
            self.engine.start_recording(path)
        except (OSError, RuntimeError) as error:
            self.message.emit("error", tr("The latency measurement failed: {}", error))
            if opened:
                self._close_unless_shared()
            return
        self._measuring = {"path": path, "opened": opened, "output": output, "stage": "settle",
                           "until": time.monotonic() + 0.3, "input": self.selected.node_name}
        self.devices_changed.emit()

    def _measure_tick(self) -> None:
        m = self._measuring
        now = time.monotonic()
        if m["stage"] == "settle" and self.engine.frames_read == 0 and now < m["until"] + INPUT_WAIT:
            return
        if m["stage"] == "settle" and now >= m["until"]:
            if not self.engine.click_start(latency_probe.BPM, 4, latency_probe.VOLUME, latency_probe.BEATS,
                                           m["output"].target):
                self._end_measuring(latency_probe.LatencyProbeError("clickDidNotStart"))
                return
            m.update(stage="anchor", until=now + ANCHOR_WAIT)
        elif m["stage"] == "anchor":
            if self.engine.click.anchor is not None:
                # The click stops after the last measured beat, so its echo cannot run into a new one.
                m.update(stage="listen", anchor=self.engine.click.anchor,
                         until=now + latency_probe.BEATS * 60 / latency_probe.BPM + latency_probe.MAXIMUM_LATENCY + 0.2)
            elif now >= m["until"] or not self.engine.click.running:
                self._end_measuring(latency_probe.LatencyProbeError("clickDidNotStart"))
        elif m["stage"] == "listen" and now >= m["until"]:
            click, first = self.engine.click, self.engine.file_first_frame
            reported = click.latency_out + click.latency_in
            self._last_reported = reported
            self.engine.click_stop()
            result = self.engine.stop_recording()
            if result is None or first is None or self.engine.format is None:
                self._end_measuring(latency_probe.LatencyProbeError("noSignal"))
                return
            try:
                samples, rate = latency_probe.loudest_channel(m["path"])
                interval = ct.beat_interval(latency_probe.BPM, rate)
                expected = [m["anchor"] + k * interval - first for k in range(latency_probe.BEATS)]
                lags, played = latency_probe.analyze(samples, rate, expected)
                measured = latency_probe.evaluate(lags, played, rate, reported)
            except latency_probe.LatencyProbeError as error:
                self._end_measuring(error)
                return
            except (OSError, ValueError) as error:
                self._end_measuring(error)
                return
            self.amp_latencies.store_measurement(m["input"], measured.correction, measured.spread,
                                                 datetime.now(timezone.utc))
            self.save_amp_latencies()
            self._end_measuring(None, measured)

    def _end_measuring(self, error, result=None) -> None:
        m, self._measuring = self._measuring, None
        if self.engine.click.running:
            self.engine.click_stop()
        if self.engine.is_recording:
            self.engine.stop_recording()
        try:
            m["path"].unlink()
        except OSError:
            pass
        if m["opened"] and not self.is_monitoring:
            self._close_unless_shared()
        if error is not None:
            text = error.text if isinstance(error, latency_probe.LatencyProbeError) else str(error)
            self.message.emit("error", tr("The latency measurement failed: {}", text))
        else:
            self.message.emit("info", tr(
                "Measured: {} ms from the click into the file, of which {} ms are not reported by the devices. "
                "Spread {} ms over {} clicks. The bars of new takes now rest on it. Unplug the cable again.",
                number(result.measured * 1000, 1), number(result.correction * 1000, 1),
                number(result.spread * 1000, 1), result.detected))
        self.devices_changed.emit()

    def select(self, device: InputDevice) -> None:
        if self.is_recording:
            return
        self.selected = device
        self._settings.setValue("input", device.node_name)
        if self.engine.is_open:
            self.engine.close()
            self.is_monitoring = False
            self.monitoring_changed.emit(False)
        self.devices_changed.emit()

    @property
    def is_recording(self) -> bool:
        """Also while counting in: the take has begun."""
        return self.phase in ("countin", "recording")

    @property
    def is_counting_in(self) -> bool:
        return self.phase == "countin"

    def _stamp_sound(self, take_id: str, now: datetime) -> dict | None:
        """The sound the take is recorded with, read from memory only, so nothing can delay a recording."""
        if self.sound_provider is None:
            return None
        try:
            heard = self.sound_provider()
            if heard is None:
                return None
            if isinstance(heard, dict):
                # A device that is only listened to (the REACTOR): what it reported, no preset, no fingerprint.
                stamp = {"name": heard["name"], "stampedAt": storemod.iso(now), "sha256": "",
                         "device": heard["device"],
                         "listened": [{"label": a, "value": b} for a, b in heard["listened"]]}
                if heard.get("slot") is not None:
                    stamp["slot"] = heard["slot"] + 1
                return stamp
            preset, slot, origin, *rest = heard
            storemod.write_snapshot(self.store, take_id, preset, origin)
            stamp = {"name": preset.name, "stampedAt": storemod.iso(now), "sha256": protocol.fingerprint(preset)}
            if slot is not None:
                stamp["slot"] = slot + 1
            if rest and rest[0]:
                stamp["device"] = rest[0]  # the device that played it, whichever input recorded
            return stamp
        except Exception:  # a missing sound must never stop a recording
            return None

    def _source_format(self, device: InputDevice) -> dict:
        return {"deviceName": device.title, "bits": device.bits, "sampleRate": device.rate, "channels": device.channels}

    # MARK: Checking the input

    # MARK: Sharing the input with the tuner

    def share(self, listener) -> str | None:
        """Lets the tuner read the input along with everything else; opens it when nothing holds it open. Returns
        why it could not, or None."""
        if not self.engine.is_open:
            self.refresh_devices()
            if self.selected is None:
                return "no_input"
            try:
                self.engine.open(self.selected)
            except RuntimeError as error:
                return str(error)
        self.engine.attach(listener)
        return None

    def stop_sharing(self, listener) -> None:
        self.engine.detach(listener)
        if not self.engine.has_listeners and not self.is_recording and not self.is_monitoring:
            self.engine.close()

    @property
    def is_held_open(self) -> bool:
        """A recording or the level check hold the input open too."""
        return self.is_recording or self.is_monitoring

    def is_sharing(self, listener) -> bool:
        return self.engine.is_open and listener in self.engine._listeners

    def _close_unless_shared(self) -> None:
        if not self.engine.has_listeners:
            self.engine.close()

    def toggle_monitoring(self) -> None:
        if self.is_recording or self.is_measuring:
            return
        if self.is_monitoring:
            self._close_unless_shared()
            self.is_monitoring = False
        else:
            self.refresh_devices()
            if self.selected is None:
                self._no_spark()
                return
            try:
                self.engine.open(self.selected)
            except RuntimeError as error:
                self.message.emit("error", str(error))
                return
            self.is_monitoring = True
        self.monitoring_changed.emit(self.is_monitoring)

    # MARK: Recording

    def toggle(self) -> None:
        self.stop() if self.is_recording else self.start()

    def _no_spark(self) -> None:
        self.message.emit("warning", tr("No Spark plugged in. AmpBench records only from a USB device with “Spark” in "
                                        "its name, never from the microphone."))

    def start(self) -> None:
        if self.is_measuring:
            return
        if self.is_recording or not self.usable:
            if not self.usable:
                self.message.emit("error", tr("The library cannot be used, nothing is recorded."))
            return
        self.refresh_devices()
        device = self.selected
        if device is None:
            self._no_spark()
            return
        folder = self.store.folder
        folder.mkdir(parents=True, exist_ok=True)
        if capture.free_bytes(folder) < capture.MIN_FREE_BYTES:
            self.message.emit("error", tr("There is not enough space on the drive for a recording."))
            return
        try:
            if not self.engine.is_open:
                self.engine.open(device)
            now = datetime.now(timezone.utc)
            path = self.store.unique_name(f"Take_{storemod.file_stamp(now)}")
            source = self._source_format(device)
            take_id = storemod.new_id()
            journal = {"fileName": path.name, "startedAt": storemod.iso(now), "source": source, "takeID": take_id,
                       "markers": []}
            if self.current_piece_id and storemod.piece(self.store, self.current_piece_id):
                journal["pieceID"] = self.current_piece_id
            stamp = self._stamp_sound(take_id, now)
            if stamp:
                journal["preset"] = stamp
            self.store.write_journal(journal)
        except (OSError, RuntimeError) as error:
            self.store.remove_journal()
            if not self.is_monitoring:
                self._close_unless_shared()
            self.message.emit("error", tr("The recording could not start: {}", error))
            return
        self.active_journal, self.active_start, self.active_source = journal, now, source
        self.active_grid = None
        self._count_in_beats = 0
        self._watch = None
        settings = self.click_settings() if self.click_settings else None
        if settings is not None and getattr(settings, "count_in_bars", 0) > 0:
            if self._start_click(settings, mute_after_count_in=not settings.click_enabled, purpose="count_in"):
                # The file starts once the click has placed its first beat (_tick), just before bar 1.
                self._count_in_beats = settings.count_in_bars * settings.beats_per_bar
                self._waiting_anchor = (path, time.monotonic() + ANCHOR_WAIT, settings)
                self._input_deadline = time.monotonic() + INPUT_WAIT
                self.count_in_left = self._count_in_beats
                self._set_phase("countin")
                return
        elif settings is not None and settings.click_enabled:
            self._start_click(settings, mute_after_count_in=False, purpose="click")
        self._begin_file(path, None, settings)

    def _begin_file(self, path: Path, gate: int | None, settings) -> None:
        try:
            self.engine.start_recording(path, gate)
        except (OSError, RuntimeError) as error:
            self._stop_click()
            self.store.remove_journal()
            self.active_journal = self.active_start = self.active_source = None
            if not self.is_monitoring:
                self._close_unless_shared()
            self._set_phase("idle")
            self.message.emit("error", tr("The recording could not start: {}", error))
            return
        # Heard from the first bar only when the click runs and stays on after the count-in.
        self._watch = ct.ClickWatch(bool(self.engine.click.running and settings is not None
                                         and settings.click_enabled))
        self._set_phase("countin" if gate is not None else "recording")

    def _set_phase(self, phase: str) -> None:
        was_monitoring = self.is_monitoring
        self.is_monitoring = False
        if phase != self.phase:
            self.phase = phase
            self.phase_changed.emit(phase)
        if was_monitoring:
            self.monitoring_changed.emit(False)

    # MARK: The click while recording

    def _start_click(self, settings, mute_after_count_in: bool, purpose: str) -> bool:
        """Starts the click on the input's clock. False, with a warning, when there is none."""
        count_in = purpose == "count_in"
        if getattr(self.engine, "helper_failed", False):
            self.message.emit("warning", tr("ampbench-rt got no sound from the input, so AmpBench records with "
                                            "pw-record until it is started again. The recording starts without a "
                                            "count-in.") if count_in else
                              tr("ampbench-rt got no sound from the input, so AmpBench records with pw-record until "
                                 "it is started again. The recording runs without a click."))
            return False
        if not self.engine.has_click:
            self.message.emit("warning", tr("The click needs ampbench-rt, which is not built here. The recording "
                                            "starts without a count-in.") if count_in else
                              tr("The click needs ampbench-rt, which is not built here. The recording runs without "
                                 "a click."))
            return False
        output = self.click_output
        if output is None:
            self.message.emit("warning", tr("No safe output found for the click. The recording starts without a "
                                            "count-in.") if count_in else
                              tr("No safe output found for the click. The recording runs without a click."))
            return False
        beats = settings.count_in_bars * settings.beats_per_bar if mute_after_count_in else -1
        if not self.engine.click_start(settings.bpm, settings.beats_per_bar, settings.volume, beats, output.target):
            self.message.emit("warning", tr("The click did not start. The recording starts without a count-in.")
                              if count_in else tr("The click did not start. The recording runs without a click."))
            return False
        self._click_bpm, self._click_beats = settings.bpm, settings.beats_per_bar
        self._click_output_kind = output.kind
        return True

    def _stop_click(self) -> None:
        self.engine.click_stop()
        self._waiting_anchor = None
        self.count_in_left = 0

    def _resolve_grid(self) -> None:
        """Works out where the bars lie in the file, once the click and the file have both started."""
        click = self.engine.click
        first = self.engine.file_first_frame
        if self.active_grid is not None or not click.running or click.anchor is None or first is None \
                or self.engine.format is None:
            return
        rate = self.engine.format.sample_rate
        self._latency = self.amp_latencies.click_latency(self.selected.node_name if self.selected else None,
                                                         click.latency_out, click.latency_in,
                                                         getattr(self, "_click_output_kind", ct.WIRED))
        self._last_reported = self._latency.reported
        offset = ct.grid_offset(click.anchor, self._count_in_beats, self._click_bpm, rate, first, self._latency)
        self.active_grid = BeatGrid(self._click_bpm, self._click_beats, offset)
        if self.active_journal is not None:
            self.active_journal["grid"] = self.active_grid.to_json()
            try:
                self.store.write_journal(self.active_journal)
            except OSError:
                pass

    def _tick(self) -> None:
        """Every frame of the window: the count-in waits for the click's first beat, then counts down."""
        if self._measuring is not None:
            self._measure_tick()
            return
        if self._waiting_anchor is not None:
            path, deadline, settings = self._waiting_anchor
            click = self.engine.click
            if click.anchor is not None and self.engine.format is not None:
                self._waiting_anchor = None
                gate = ct.gate_frame(click.anchor, self._count_in_beats, settings.bpm, self.engine.format.sample_rate,
                                     COUNT_IN_PRE_ROLL)
                self._begin_file(path, gate, settings)
            elif self.engine.frames_read == 0 and time.monotonic() < self._input_deadline:
                # The input has not delivered yet; the click's second counts from its first frames.
                self._waiting_anchor = (path, time.monotonic() + ANCHOR_WAIT, settings)
            elif not click.running or time.monotonic() > deadline:
                self._stop_click()
                self._count_in_beats = 0
                self.message.emit("warning", tr("The click did not start. The recording starts without a count-in."))
                self._begin_file(path, None, settings)
            return
        if not self.is_recording:
            return
        self._resolve_grid()
        if self.phase == "countin":
            fmt = self.engine.format
            if fmt and self.engine.recorded_frames > COUNT_IN_PRE_ROLL * fmt.sample_rate:
                self.count_in_left = 0
                self._set_phase("recording")
            elif self.engine.click.running:
                self.count_in_left = max(self._count_in_beats - self.engine.click.beats + 1, 1)
        if self._watch is not None and self.engine.click.failed:
            self._watch.click_switched(False)

    def toggle_click(self) -> None:
        """Switches the click on or off. While recording the running click stays, silent or not: the bars are
        counted from it."""
        if self.click_settings is None:
            return
        settings = self.click_settings()
        settings.click_enabled = not settings.click_enabled
        on = settings.click_enabled
        if self.on_click_settings_changed:
            self.on_click_settings_changed()
        if not self.is_recording:
            return
        if self._watch is not None:
            self._watch.click_switched(on)
        if self.engine.click.running:
            if self.phase == "countin" or self._waiting_anchor is not None:
                self.engine.click_mute_from(-1 if on else self._count_in_beats)
            else:
                self.engine.click_mute_from(-1 if on else 0)
        elif on and self._waiting_anchor is None:
            # Switched on in the middle of a take: bars from where it starts, as on the Mac, but no review.
            self._start_click(settings, mute_after_count_in=False, purpose="click")

    def stop(self, note: str | None = None) -> None:
        if not self.is_recording or self.active_journal is None:
            return
        if self.phase == "countin":  # the key reads "Cancel count-in" until bar 1 is near
            self._cancel_count_in()
            return
        self._resolve_grid()
        journal, started, source = self.active_journal, self.active_start, self.active_source
        result = self.engine.stop_recording()
        # Taken before the click stops and its latency is reset. A click that stopped on its own was not on throughout.
        watch, grid = self._watch, self.active_grid
        if watch is not None and not self.engine.click.running:
            watch.click_switched(False)
        timing = watch.stamp(self._latency) if watch is not None and grid is not None else None
        self._stop_click()
        self._close_unless_shared()
        self.active_journal = self.active_start = self.active_source = None
        self.active_grid, self._watch, self._latency, self._count_in_beats = None, None, ct.ClickLatency(), 0
        self.phase = "idle"
        self.phase_changed.emit(self.phase)
        if result is None:
            self.store.remove_journal()
            return
        if result.frames == 0:
            try:
                result.path.unlink()
            except OSError:
                pass
            self.store.remove_journal()
            self.message.emit("warning", note or tr("Nothing was recorded because the device delivered no data."))
            return
        fmt = self.engine.format
        peak_db = capture.to_db(result.peak) if result.peak > 0 else None
        recording = self.store.new_recording(
            take_id=journal["takeID"], file_name=journal["fileName"], started_at=started, seconds=result.seconds,
            fmt=fmt, source=source, piece_id=journal.get("pieceID"), peak_db=peak_db, auto_level=self.auto_level,
            markers=journal.get("markers"), preset=journal.get("preset"))
        if grid is not None:
            recording["grid"] = grid.to_json()
        if timing is not None:
            recording["timing"] = timing.to_json()
        self.store.add(recording)
        self.store.log_practice(started, result.seconds, journal.get("pieceID"))
        try:
            self.store.save()
            if result.finalized:  # the journal goes only after the take is safely in the library
                self.store.remove_journal()
        except OSError as error:
            self.message.emit("error", tr("The library could not be saved: {}", error))
        self.library_changed.emit()
        self.take_added.emit(recording["id"])
        self.message.emit("warning" if note else "success", note or tr("Take saved ({} s).", number(result.seconds, 1)))

    def _cancel_count_in(self) -> None:
        result = self.engine.stop_recording()
        self._stop_click()
        # What is in the file is at most the pre-roll before bar 1, nothing anybody played on purpose.
        if result is not None:
            try:
                result.path.unlink()
            except OSError:
                pass
        self.store.remove_journal()
        self.active_journal = self.active_start = self.active_source = None
        self.active_grid, self._watch, self._count_in_beats = None, None, 0
        self._close_unless_shared()
        self._set_phase("idle")
        self.message.emit("info", tr("The count-in was canceled."))

    def _device_lost(self) -> None:
        if self.is_recording:
            self.stop(tr("The device is gone. The recording was ended safely and what was there until then is kept."))
        elif self.is_monitoring:
            self.engine.close()
            self.is_monitoring = False
            self.monitoring_changed.emit(False)
            self.message.emit("warning", tr("The input was disconnected."))
        self.refresh_devices()

    def shutdown(self) -> None:
        if self._measuring is not None:
            self._measuring["opened"] = True
            self._end_measuring(RuntimeError(tr("AmpBench was closed.")))
        if self.is_recording:
            self.stop()
        self.engine.close()
