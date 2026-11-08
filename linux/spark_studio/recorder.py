"""The recording model: which Spark is the input, starting and stopping a take, and the library behind it.

The flow follows AppModel.startRecording / stopRecording of the Mac app: a journal is written before the first sample,
the take is added to the library only when it is safely on disk, and the journal goes last.
"""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QObject, QSettings, QTimer, Signal

from . import capture, store as storemod
from .capture import CaptureEngine, InputDevice


class RecorderModel(QObject):
    phase_changed = Signal(str)  # idle, recording
    devices_changed = Signal()
    meter_changed = Signal()
    message = Signal(str, str)  # kind, text
    library_changed = Signal()
    monitoring_changed = Signal(bool)

    def __init__(self, store: storemod.LibraryStore, engine: CaptureEngine | None = None,
                 devices: Callable[[], list[InputDevice]] = capture.spark_inputs, parent=None):
        super().__init__(parent)
        self.store = store
        self.engine = engine or CaptureEngine()
        self._devices_provider = devices
        self.devices: list[InputDevice] = []
        self.selected: InputDevice | None = None
        self.phase = "idle"
        self.is_monitoring = False
        self.usable = False
        self.active_journal: dict | None = None
        self.active_start: datetime | None = None
        self.active_source: dict | None = None
        self.auto_level = True
        self.engine.on_lost = lambda: QTimer.singleShot(0, self._device_lost)
        self.engine.on_limit = lambda: QTimer.singleShot(0, lambda: self.stop("Die Aufnahme hat die Grenze des WAV-Formats erreicht und wurde sicher beendet."))
        self._timer = QTimer(self)
        self._timer.setInterval(33)
        self._timer.timeout.connect(self.meter_changed.emit)
        self._timer.start()
        self._settings = QSettings("local.sparkstudio", "Spark Studio")

    # MARK: Library

    def start_library(self) -> None:
        """Opens the library, repairs a recording a crash left behind and finds files placed in the folder."""
        if not self.store.acquire_lock():
            self.usable = False
            self.message.emit("error", "Die Aufnahmen werden schon von einer anderen Spark-Studio-Instanz benutzt. "
                                       "Hier wird nichts aufgenommen.")
            return
        try:
            outcome = self.store.load()
        except storemod.StoreError as error:
            self.usable = False
            self.message.emit("error", str(error))
            return
        if outcome in ("restored", "started_over"):
            self.message.emit("warning", "Die Bibliothek war nicht lesbar. Die kaputte Datei liegt als "
                                         "Bibliothek.defekt-… im Ordner.")
        self.usable = True
        recovery = self.store.recover_interrupted()
        if recovery.kind == "repaired":
            self.message.emit("info", f"Die unterbrochene Aufnahme „{recovery.file_name}“ wurde repariert "
                                      f"({recovery.seconds:.0f} s) und liegt in der Bibliothek.")
        elif recovery.kind == "failed":
            self.message.emit("warning", f"Die Datei „{recovery.file_name}“ einer unterbrochenen Aufnahme ließ sich "
                                         "nicht reparieren. Sie liegt unverändert im Ordner.")
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
        self.devices_changed.emit()

    def select(self, device: InputDevice) -> None:
        if self.phase == "recording":
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
        return self.phase == "recording"

    def _source_format(self, device: InputDevice) -> dict:
        return {"deviceName": device.title, "bits": device.bits, "sampleRate": device.rate, "channels": device.channels}

    # MARK: Checking the input

    def toggle_monitoring(self) -> None:
        if self.is_recording:
            return
        if self.is_monitoring:
            self.engine.close()
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
        self.message.emit("warning", "Kein Spark angeschlossen. Spark Studio nimmt nur von einem USB-Gerät mit "
                                     "„Spark“ im Namen auf, nie vom Mikrofon.")

    def start(self) -> None:
        if self.is_recording or not self.usable:
            if not self.usable:
                self.message.emit("error", "Die Bibliothek ist nicht benutzbar, es wird nichts aufgenommen.")
            return
        self.refresh_devices()
        device = self.selected
        if device is None:
            self._no_spark()
            return
        folder = self.store.folder
        folder.mkdir(parents=True, exist_ok=True)
        if capture.free_bytes(folder) < capture.MIN_FREE_BYTES:
            self.message.emit("error", "Auf dem Laufwerk ist zu wenig Platz für eine Aufnahme.")
            return
        try:
            if not self.engine.is_open:
                self.engine.open(device)
            now = datetime.now(timezone.utc)
            path = self.store.unique_name(f"Aufnahme_{storemod.file_stamp(now)}")
            source = self._source_format(device)
            take_id = storemod.new_id()
            journal = {"fileName": path.name, "startedAt": storemod.iso(now), "source": source, "takeID": take_id,
                       "markers": []}
            self.store.write_journal(journal)
            self.engine.start_recording(path)
        except (OSError, RuntimeError) as error:
            self.store.remove_journal()
            if not self.is_monitoring:
                self.engine.close()
            self.message.emit("error", f"Die Aufnahme konnte nicht starten: {error}")
            return
        self.active_journal, self.active_start, self.active_source = journal, now, source
        self.is_monitoring = False
        self.phase = "recording"
        self.phase_changed.emit(self.phase)
        self.monitoring_changed.emit(False)

    def stop(self, note: str | None = None) -> None:
        if not self.is_recording or self.active_journal is None:
            return
        journal, started, source = self.active_journal, self.active_start, self.active_source
        result = self.engine.stop_recording()
        self.engine.close()
        self.active_journal = self.active_start = self.active_source = None
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
            self.message.emit("warning", note or "Es wurde nichts aufgenommen, weil das Gerät keine Daten geliefert hat.")
            return
        fmt = self.engine.format
        peak_db = capture.to_db(result.peak) if result.peak > 0 else None
        recording = self.store.new_recording(
            take_id=journal["takeID"], file_name=journal["fileName"], started_at=started, seconds=result.seconds,
            fmt=fmt, source=source, piece_id=journal.get("pieceID"), peak_db=peak_db, auto_level=self.auto_level,
            markers=journal.get("markers"), preset=journal.get("preset"))
        self.store.add(recording)
        self.store.log_practice(started, result.seconds, journal.get("pieceID"))
        try:
            self.store.save()
            if result.finalized:  # the journal goes only after the take is safely in the library
                self.store.remove_journal()
        except OSError as error:
            self.message.emit("error", f"Die Bibliothek konnte nicht gespeichert werden: {error}")
        self.library_changed.emit()
        self.message.emit("warning" if note else "success", note or f"Aufnahme gespeichert ({result.seconds:.1f} s).")

    def _device_lost(self) -> None:
        if self.is_recording:
            self.stop("Das Gerät ist verschwunden. Die Aufnahme wurde sicher beendet und behalten, was bis dahin da war.")
        elif self.is_monitoring:
            self.engine.close()
            self.is_monitoring = False
            self.monitoring_changed.emit(False)
            self.message.emit("warning", "Der Eingang wurde getrennt.")
        self.refresh_devices()

    def shutdown(self) -> None:
        if self.is_recording:
            self.stop()
        self.engine.close()
