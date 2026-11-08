"""The area Aufnahme below the deck: the waveform, the transport and the list of takes.

Stage 2 brings playback with loop, markers, tempo and pitch and the review of an open take (keep, discard, again).
The library views (ratings, tags, pieces, statistics, inspector) follow in the next stage.
"""
from __future__ import annotations

import threading
from pathlib import Path

from PySide6.QtCore import QObject, QTimer, Qt, Signal
from PySide6.QtWidgets import (QAbstractItemView, QHBoxLayout, QHeaderView, QLabel, QTableWidget, QTableWidgetItem,
                               QVBoxLayout, QWidget)

from .. import peaks, store as storemod
from ..player import PITCH_RANGE, TEMPO_RANGE, Player, Track
from . import theme
from .wave import WaveView, time_label
from .widgets import DeviceSlider, DisplayStepper, Engraving, HardwareKey


def clock(seconds: float, tenths: bool = False) -> str:
    seconds = max(seconds, 0.0)
    text = f"{int(seconds) // 60:02d}:{int(seconds) % 60:02d}"
    return text + (f",{int(seconds * 10) % 10}" if tenths else "")


class _Waves(QObject):
    ready = Signal(str, object)


class RecordingsPage(QWidget):
    message = Signal(str, str, object)  # kind, text, undo

    def __init__(self, recorder, parent=None):
        super().__init__(parent)
        self.recorder = recorder
        self.store = recorder.store
        self.player = Player()
        self.player.on_finished = lambda: QTimer.singleShot(0, self._finished)
        self.current_id: str | None = None
        self.loop_start: float | None = None
        self.undo_stack: list = []
        self._waves = _Waves()
        self._waves.ready.connect(self._wave_ready)
        self._build()
        self._timer = QTimer(self)
        self._timer.setInterval(40)
        self._timer.timeout.connect(self._tick)
        self._timer.start()
        recorder.library_changed.connect(self.refresh)
        recorder.phase_changed.connect(self._phase_changed)
        recorder.take_added.connect(lambda take_id: self.select(take_id))

    # MARK: Building

    def _build(self) -> None:
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        self.wave = WaveView()
        self.wave.seek_requested.connect(self._seek)
        self.wave.loop_changed.connect(self._loop_dragged)
        v.addWidget(self.wave)

        bar = QWidget()
        bar.setFixedHeight(56)
        bar.setStyleSheet(f"background: {theme.DESK}; border-top: 1px solid {theme.DESK_LINE}; "
                          f"border-bottom: 1px solid {theme.DESK_LINE};")
        row = QHBoxLayout(bar)
        row.setContentsMargins(22, 0, 22, 0)
        row.setSpacing(8)
        self.play_key = HardwareKey("Abspielen", keycap="␣")
        self.play_key.setMinimumWidth(128)
        self.play_key.clicked.connect(self.toggle_play)
        row.addWidget(self.play_key)
        self.time_label = QLabel("00:00,0 / 00:00")
        self.time_label.setFont(theme.mono(13, True))
        self.time_label.setStyleSheet(f"background: transparent; color: {theme.AMBER}; border: none;")
        row.addWidget(self.time_label)
        self.loop_key = HardwareKey("Schleife", keycap="L")
        self.loop_key.clicked.connect(self.toggle_loop)
        row.addWidget(self.loop_key)
        self.marker_key = HardwareKey("Marker", keycap="M")
        self.marker_key.clicked.connect(self.add_marker)
        row.addWidget(self.marker_key)
        row.addSpacing(8)
        tempo = Engraving("Tempo")
        row.addWidget(tempo)
        self.tempo_slider = DeviceSlider(TEMPO_RANGE[0], TEMPO_RANGE[1], 0.05)
        self.tempo_slider.setFixedWidth(110)
        self.tempo_slider.changed.connect(self.set_tempo)
        row.addWidget(self.tempo_slider)
        self.tempo_label = QLabel("100 %")
        self.tempo_label.setFont(theme.mono(12))
        self.tempo_label.setFixedWidth(46)
        self.tempo_label.setStyleSheet(f"background: transparent; color: {theme.TEXT_DIM}; border: none;")
        row.addWidget(self.tempo_label)
        row.addWidget(Engraving("Ton"))
        self.pitch_stepper = DisplayStepper(PITCH_RANGE[0], PITCH_RANGE[1])
        self.pitch_stepper.changed.connect(self.set_pitch)
        row.addWidget(self.pitch_stepper)
        self.reset_key = HardwareKey("↶", keycap="0")
        self.reset_key.clicked.connect(self.reset_tempo_pitch)
        self.reset_key.hide()
        row.addWidget(self.reset_key)
        row.addStretch(1)
        self.keep_key = HardwareKey("Behalten", "primary", "K")
        self.keep_key.clicked.connect(self.keep)
        self.discard_key = HardwareKey("Verwerfen", "danger", "⌫")
        self.discard_key.clicked.connect(self.discard)
        self.again_key = HardwareKey("Nochmal", keycap="R")
        self.again_key.clicked.connect(self.recorder.toggle)
        for key in (self.keep_key, self.discard_key, self.again_key):
            row.addWidget(key)
        v.addWidget(bar)

        self.table = QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(["Name", "Datum", "Dauer"])
        self.table.verticalHeader().hide()
        self.table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SingleSelection)
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.setShowGrid(False)
        self.table.setAlternatingRowColors(True)
        self.table.setFocusPolicy(Qt.NoFocus)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeToContents)
        self.table.horizontalHeader().setStretchLastSection(False)
        self.table.setStyleSheet(
            f"QTableWidget {{ background: {theme.DESK}; border: none; alternate-background-color: {theme.DESK_ALT}; }} "
            f"QHeaderView::section {{ background: {theme.DESK}; color: {theme.DESK_MUTED}; border: none; "
            f"border-bottom: 1px solid {theme.DESK_LINE}; padding: 8px; font-weight: bold; }} "
            f"QTableWidget {{ selection-background-color: rgba(247,196,92,46); selection-color: {theme.DESK_TEXT}; }} "
            f"QTableWidget::item:selected, QTableWidget::item:selected:!active {{ background: rgba(247,196,92,46); "
            f"color: {theme.DESK_TEXT}; border-left: 3px solid {theme.SELECTED_BAR}; }}")
        self.table.itemSelectionChanged.connect(self._selection_changed)
        v.addWidget(self.table, 1)
        self.footer = QLabel("")
        self.footer.setContentsMargins(22, 8, 22, 8)
        self.footer.setStyleSheet(f"color: {theme.DESK_MUTED}; border-top: 1px solid {theme.DESK_LINE};")
        v.addWidget(self.footer)
        self._update_keys()

    # MARK: The list

    @property
    def recordings(self) -> list[dict]:
        # Newest first; takes of the same second keep the order they were added in.
        ranked = sorted(enumerate(self.store.document["recordings"]), key=lambda p: (p[1].get("createdAt", ""), p[0]),
                        reverse=True)
        return [take for _, take in ranked]

    @property
    def current(self) -> dict | None:
        return self.store.recording(self.current_id) if self.current_id else None

    def refresh(self) -> None:
        recordings = self.recordings
        self.table.blockSignals(True)
        self.table.setRowCount(len(recordings))
        total = 0.0
        open_takes = 0
        for row, take in enumerate(recordings):
            open_takes += take.get("status") == "open"
            name = Path(take["fileName"]).stem + ("   · Offen" if take.get("status") == "open" else "")
            seconds = float(take.get("duration", 0))
            total += seconds
            date = storemod.parse_iso(take.get("createdAt")).astimezone()
            for column, text in enumerate((name, date.strftime("%d.%m.%y, %H:%M"), clock(seconds))):
                item = QTableWidgetItem(text)
                item.setData(Qt.UserRole, take["id"])
                if column:
                    item.setFont(theme.mono(13))
                self.table.setItem(row, column, item)
            self.table.setRowHeight(row, 36)
        ids = [t["id"] for t in recordings]
        if self.current_id not in ids:
            self.current_id = None
        self.table.blockSignals(False)
        self._select_row(ids.index(self.current_id) if self.current_id in ids else -1)
        self.footer.setText(f"{len(recordings)} Aufnahmen · {open_takes} offen · "
                            f"{int(total // 3600)} Std. {int(total // 60) % 60} Min.")
        self._update_keys()

    def _select_row(self, row: int) -> None:
        self.table.blockSignals(True)
        self.table.clearSelection()
        if row >= 0:
            self.table.selectRow(row)
        self.table.blockSignals(False)

    def _selection_changed(self) -> None:
        items = self.table.selectedItems()
        if items:
            self.select(items[0].data(Qt.UserRole))

    def select(self, take_id: str | None, play: bool = False) -> None:
        if take_id == self.current_id and not play:
            return
        self.player.stop()
        self.current_id = take_id
        self.loop_start = None
        take = self.current
        self.player.load(None)
        if take is None:
            self.wave.set_take(None, 0.0, [])
            self.wave.message = "Wähle eine Aufnahme."
        else:
            path = self.store.url(take)
            edit = take.get("edit") or {}
            gain = float(edit.get("gainDB", 0)) + (float(edit.get("autoLevelDB", 0)) if edit.get("autoLevelEnabled") else 0)
            self.player.load(Track(path, float(take.get("duration", 0)), gain, float(edit.get("trimStart", 0)),
                                   edit.get("trimEnd")))
            self.player.set_tempo(self.tempo_slider.value)
            self.wave.set_take(None, float(take.get("duration", 0)), take.get("markers", []))
            self.wave.message = "Die Wellenform wird berechnet …"
            cache = self.store.folder / ".wellenformen" / f"{take['id']}.lpeaks"
            threading.Thread(target=self._compute_wave, args=(take["id"], path, cache, float(take.get("duration", 0))),
                             daemon=True).start()
            if take["id"] in [t["id"] for t in self.recordings]:
                row = [t["id"] for t in self.recordings].index(take["id"])
                self._select_row(row)
        self._update_keys()
        if play:
            self.player.play()

    def _compute_wave(self, take_id: str, path: Path, cache: Path, duration: float) -> None:
        self._waves.ready.emit(take_id, peaks.cached(path, cache, duration))

    def _wave_ready(self, take_id: str, waveform) -> None:
        if take_id == self.current_id:
            take = self.current
            self.wave.waveform = waveform
            self.wave.message = "Keine Wellenform: Die Datei lässt sich nicht lesen." if waveform is None else ""
            self.wave.set_position(self.player.position)
            self.wave.update()

    # MARK: Playback

    def toggle_play(self) -> None:
        if self.recorder.is_recording:
            self.recorder.stop()
            take = self.recordings[0] if self.recordings else None
            if take:
                self.select(take["id"], play=True)
            return
        if self.current is None:
            return
        self.player.toggle()
        self._update_keys()

    def _finished(self) -> None:
        self._update_keys()

    def _seek(self, position: float) -> None:
        if self.current is not None:
            self.player.seek(position)
            self.wave.set_position(position)

    def jump(self, seconds: float) -> None:
        if self.current is not None:
            self._seek(self.player.position + seconds)

    def toggle_loop(self) -> None:
        """L: the first press sets A, the second sets B, the third clears the loop."""
        take = self.current
        if take is None:
            return
        if self.player.loop:
            self.player.set_loop(None)
            self.wave.loop, self.wave.loop_start_only, self.loop_start = None, None, None
        elif self.loop_start is None:
            self.loop_start = self.player.position
            self.wave.loop_start_only = self.loop_start
        else:
            a, b = sorted((self.loop_start, self.player.position))
            self.loop_start, self.wave.loop_start_only = None, None
            if b - a >= 0.1:
                self.wave.loop = (a, b)
                self.player.set_loop((a, b))
        self.wave.update()
        self._update_keys()

    def _loop_dragged(self, loop) -> None:
        self.loop_start = None
        self.player.set_loop(loop)
        self._update_keys()

    def add_marker(self) -> None:
        if self.recorder.is_recording:
            seconds = self.recorder.engine.meter.seconds
            journal = self.recorder.active_journal
            if journal is not None:
                journal.setdefault("markers", []).append({"id": storemod.new_id(), "time": seconds,
                                                          "label": f"Marker {len(journal['markers']) + 1}"})
                self.recorder.store.write_journal(journal)
            return
        take = self.current
        if take is None:
            return
        marker = {"id": storemod.new_id(), "time": self.player.position, "label": f"Marker {len(take.get('markers', [])) + 1}"}
        self.store.update(take["id"], lambda r: r.setdefault("markers", []).append(marker))
        self._save()
        self.wave.markers = take["markers"]
        self.wave.update()

    def set_tempo(self, tempo: float) -> None:
        self.player.set_tempo(tempo)
        self.tempo_slider.set_value(tempo)
        self.tempo_label.setText(f"{round(tempo * 100)} %")
        self._update_keys()

    def nudge_tempo(self, delta: float) -> None:
        self.set_tempo(min(max(round(self.player.tempo + delta, 2), TEMPO_RANGE[0]), TEMPO_RANGE[1]))

    def set_pitch(self, pitch: int) -> None:
        self.player.set_pitch(pitch)
        self.pitch_stepper.set_value(pitch)
        self._update_keys()

    def reset_tempo_pitch(self) -> None:
        self.set_tempo(1.0)
        self.set_pitch(0)

    # MARK: Review of an open take

    def _save(self) -> None:
        try:
            self.store.save()
        except OSError as error:
            self.message.emit("error", f"Die Bibliothek konnte nicht gespeichert werden: {error}", None)

    def keep(self) -> None:
        take = self.current
        if take is None or take.get("status") != "open":
            return
        take_id = take["id"]
        self.store.update(take_id, lambda r: r.update(status="kept"))
        self._save()
        self.refresh()
        self.message.emit("success", "Behalten.", lambda: self._set_status(take_id, "open"))

    def _set_status(self, take_id: str, status: str) -> None:
        self.store.update(take_id, lambda r: r.update(status=status))
        self._save()
        self.refresh()

    def discard(self) -> None:
        if self.recorder.is_recording:
            return
        take = self.current
        if take is None:
            self.message.emit("info", "Markiere zuerst die Aufnahme, die in den Papierkorb soll.", None)
            return
        order = [t["id"] for t in self.recordings]
        position = order.index(take["id"])
        self.player.stop()
        try:
            entry = self.store.trash_recording(take["id"])
        except storemod.StoreError as error:
            self.message.emit("error", str(error), None)
            return
        self._save()
        remaining = [i for i in order if i != take["id"]]
        self.current_id = None
        self.select(remaining[min(position, len(remaining) - 1)] if remaining else None)
        self.refresh()
        self.message.emit("info", f"„{Path(take['fileName']).stem}“ liegt im Papierkorb.", lambda: self._restore(entry))

    def _restore(self, entry: dict) -> None:
        try:
            recording = self.store.restore_trashed(entry)
        except storemod.StoreError as error:
            self.message.emit("error", str(error), None)
            return
        self._save()
        self.refresh()
        self.select(recording["id"])

    # MARK: State

    def _phase_changed(self, phase: str) -> None:
        if phase == "recording":
            self.player.stop()
            self.wave.live_columns = []
            self.wave.waveform = None
        else:
            self.wave.live_columns = []
        self._update_keys()

    def _tick(self) -> None:
        recorder = self.recorder
        if recorder.is_recording:
            meter = recorder.engine.meter
            self.wave.duration = max(meter.seconds * 1.04, 10.0)
            self.wave.live_columns = list(meter.overview)
            self.wave.message = ""
            self.wave.update()
            self.time_label.setText(f"{clock(meter.seconds, True)} / –")
            return
        position = self.player.position
        self.wave.set_position(position)
        take = self.current
        duration = float(take.get("duration", 0)) if take else 0.0
        self.time_label.setText(f"{clock(position, True)} / {clock(duration)}")
        self.play_key.setText("Pause" if self.player.is_playing else "Abspielen")
        self.play_key.set_style("on" if self.player.is_playing else "normal")

    def _update_keys(self) -> None:
        recording = self.recorder.is_recording
        take = self.current
        has = take is not None
        self.play_key.setEnabled(has or recording)
        self.loop_key.setEnabled(has)
        loop = self.player.loop
        if loop:
            self.loop_key.setText(f"{clock(loop[0])} – {clock(loop[1])}")
        else:
            self.loop_key.setText("A gesetzt" if self.loop_start is not None else "Schleife")
        self.loop_key.set_style("on" if loop else "normal")
        self.marker_key.setEnabled(has or recording)
        self.reset_key.setVisible(self.player.tempo != 1.0 or self.player.pitch != 0)
        review = has and take.get("status") == "open" and not recording
        for key in (self.keep_key, self.discard_key, self.again_key):
            key.setVisible(review)
        self.keep_key.setVisible(review)
