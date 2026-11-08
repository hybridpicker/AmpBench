"""The area Aufnahme below the deck: the waveform, the transport and the list of takes.

Stage 2 brings playback with loop, markers, tempo and pitch and the review of an open take (keep, discard, again).
The library views (ratings, tags, pieces, statistics, inspector) follow in the next stage.
"""
from __future__ import annotations

import subprocess
import threading
from pathlib import Path

from PySide6.QtCore import QObject, QSettings, QTimer, QUrl, Qt, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (QFileDialog, QHBoxLayout, QInputDialog, QLabel, QMenu, QSplitter, QStackedWidget,
                               QVBoxLayout, QWidget)

from .. import peaks, store as storemod
from ..player import PITCH_RANGE, TEMPO_RANGE, Player, Track
from . import theme
from .library_views import Inspector, PiecesView, StatsView, TakesView
from .wave import WaveView, time_label
from .widgets import DeviceSlider, DisplayStepper, Engraving, HardwareKey, SegmentTabs


def clock(seconds: float, tenths: bool = False) -> str:
    seconds = max(seconds, 0.0)
    text = f"{int(seconds) // 60:02d}:{int(seconds) % 60:02d}"
    return text + (f",{int(seconds * 10) % 10}" if tenths else "")


class _Waves(QObject):
    ready = Signal(str, object)
    exported = Signal(str, bool)


def _apply(recording: dict, fields: dict) -> None:
    for key, value in fields.items():
        if value is None:
            recording.pop(key, None)
        else:
            recording[key] = value


class RecordingsPage(QWidget):
    message = Signal(str, str, object)  # kind, text, undo
    send_sound = Signal(object)  # a preset to play on the amp
    open_sound = Signal(object)  # a preset to open in the editor
    play_link = Signal(object)  # a PresetLink of a piece or part

    def __init__(self, recorder, parent=None):
        super().__init__(parent)
        self.recorder = recorder
        self.store = recorder.store
        self.player = Player()
        self.player.on_finished = lambda: QTimer.singleShot(0, self._finished)
        self.current_id: str | None = None
        self.loop_start: float | None = None
        self.undo_stack: list = []
        self.presets_provider = lambda: []
        self._waves = _Waves()
        self._waves.ready.connect(self._wave_ready)
        self._waves.exported.connect(self._exported)
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

        splitter = QSplitter(Qt.Horizontal)
        splitter.setChildrenCollapsible(False)
        splitter.setHandleWidth(1)
        left = QWidget()
        lv = QVBoxLayout(left)
        lv.setContentsMargins(0, 0, 0, 0)
        lv.setSpacing(0)
        tabs_row = QHBoxLayout()
        tabs_row.setContentsMargins(16, 10, 16, 0)
        self.library_tabs = SegmentTabs(["Aufnahmen", "Stücke", "Statistik"])
        tabs_row.addWidget(self.library_tabs)
        tabs_row.addStretch(1)
        lv.addLayout(tabs_row)
        self.library_stack = QStackedWidget()
        self.takes = TakesView(self.store)
        self.pieces = PiecesView(self.store)
        self.stats = StatsView(self.store)
        for view in (self.takes, self.pieces, self.stats):
            self.library_stack.addWidget(view)
        lv.addWidget(self.library_stack, 1)
        self.library_tabs.changed.connect(self._library_tab)
        splitter.addWidget(left)
        self.inspector = Inspector(self.store)
        splitter.addWidget(self.inspector)
        splitter.setStretchFactor(0, 1)
        splitter.setSizes([760, 400])
        v.addWidget(splitter, 1)
        self.table = self.takes.table
        self._wire_library()
        self._update_keys()

    def _library_tab(self, index: int) -> None:
        self.library_stack.setCurrentIndex(index)
        self.refresh()

    def show_tab(self, index: int) -> None:
        self.library_tabs.set_index(index)
        self._library_tab(index)

    def _wire_library(self) -> None:
        t, i, p = self.takes, self.inspector, self.pieces
        t.selection_changed.connect(self._selection_changed)
        t.rate.connect(lambda take_id, n: self.update_take(take_id, {"rating": n}))
        t.favorite.connect(lambda take_id, on: self.update_take(take_id, {"favorite": on}))
        t.context.connect(self._context_menu)
        t.new_piece_requested.connect(lambda: self.new_piece([]))
        t.trash_requested.connect(self.discard)
        t.piece_for_new.connect(self.set_piece_for_new)
        i.changed.connect(self.update_take)
        i.rename_requested.connect(self.rename)
        i.reveal_requested.connect(self.reveal)
        i.new_piece_requested.connect(lambda take_id: self.new_piece([take_id]))
        i.best_take.connect(self.mark_best)
        i.send_to_amp.connect(lambda take_id: self._sound(take_id, self.send_sound))
        i.open_in_editor.connect(lambda take_id: self._sound(take_id, self.open_sound))
        i.trim_start_here.connect(lambda take_id: self._trim(take_id, "trimStart"))
        i.trim_end_here.connect(lambda take_id: self._trim(take_id, "trimEnd"))
        i.export_requested.connect(self.export)
        i.marker_selected.connect(self._seek)
        i.marker_deleted.connect(self.delete_marker)
        i.marker_renamed.connect(self.rename_marker)
        p.created.connect(self.create_piece)
        p.changed.connect(self.update_piece)
        p.deleted.connect(self.delete_piece)
        p.chosen_for_new.connect(self.set_piece_for_new)
        p.show_takes.connect(self._show_piece_takes)
        p.listen_to_best.connect(self._listen_to_best)
        p.play_sound.connect(self.play_link)
        p.presets_provider = lambda: self.presets_provider()
        saved = QSettings("local.sparkstudio", "Spark Studio").value("piece")
        self.set_piece_for_new(saved if storemod.piece(self.store, saved) else None, remember=False)

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
        ids = [t["id"] for t in self.store.document["recordings"]]
        if self.current_id not in ids:
            self.current_id = None
        self.takes.refresh([self.current_id] if self.current_id else [])
        self.pieces.new_piece_id = self.recorder.current_piece_id
        self.pieces.refresh()
        self.stats.refresh()
        self.takes.set_piece_for_new(self.recorder.current_piece_id)
        self._show_inspector()
        self._update_keys()

    def _show_inspector(self) -> None:
        take = self.current
        if take is None:
            self.inspector.show_take(None)
            return
        piece = storemod.piece(self.store, take.get("pieceID"))
        self.inspector.show_take(
            take, self.store.document["pieces"], take.get("preset"),
            storemod.snapshot_path(self.store, take["id"]).exists(),
            bool(piece and piece.get("bestTakeID") == take["id"]))

    def _selection_changed(self, ids: list) -> None:
        if len(ids) == 1:
            self.select(ids[0])
        elif not ids:
            pass

    def _track_for(self, take: dict) -> Track:
        edit = take.get("edit") or {}
        gain = float(edit.get("gainDB", 0)) + (float(edit.get("autoLevelDB", 0)) if edit.get("autoLevelEnabled") else 0)
        return Track(self.store.url(take), float(take.get("duration", 0)), gain, float(edit.get("trimStart", 0)),
                     edit.get("trimEnd"))

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
            self.player.load(self._track_for(take))
            self.player.set_tempo(self.tempo_slider.value)
            self.wave.set_take(None, float(take.get("duration", 0)), take.get("markers", []))
            self.wave.message = "Die Wellenform wird berechnet …"
            cache = self.store.folder / ".wellenformen" / f"{take['id']}.lpeaks"
            threading.Thread(target=self._compute_wave, args=(take["id"], path, cache, float(take.get("duration", 0))),
                             daemon=True).start()
            self.takes.select_ids([take_id])
        self._show_inspector()
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
        ids = self.takes.selected_ids or ([self.current_id] if self.current_id else [])
        if not ids:
            self.message.emit("info", "Markiere zuerst die Aufnahme, die in den Papierkorb soll.", None)
            return
        order = [t["id"] for t in self.takes.rows]
        positions = [order.index(i) for i in ids if i in order]
        self.player.stop()
        entries = []
        for take_id in ids:
            try:
                entries.append(self.store.trash_recording(take_id))
            except storemod.StoreError as error:
                self.message.emit("error", str(error), None)
        if not entries:
            return
        self._save()
        remaining = [i for i in order if i not in ids]
        self.current_id = None
        self.takes.refresh([])
        target = remaining[min(min(positions, default=0), len(remaining) - 1)] if remaining else None
        self.select(target)
        self.refresh()
        name = Path(entries[0]["recording"]["fileName"]).stem
        text = f"„{name}“ liegt im Papierkorb." if len(entries) == 1 else f"{len(entries)} Aufnahmen liegen im Papierkorb."
        self.message.emit("info", text, lambda: self._restore_all(entries))

    def _restore_all(self, entries: list) -> None:
        last = None
        for entry in entries:
            try:
                last = self.store.restore_trashed(entry)
            except storemod.StoreError as error:
                self.message.emit("error", str(error), None)
        self._save()
        self.refresh()
        if last:
            self.select(last["id"])

    def _restore(self, entry: dict) -> None:
        try:
            recording = self.store.restore_trashed(entry)
        except storemod.StoreError as error:
            self.message.emit("error", str(error), None)
            return
        self._save()
        self.refresh()
        self.select(recording["id"])

    # MARK: Changes to takes

    def update_take(self, take_id: str, fields: dict) -> None:
        """Applies what the inspector or the table changed, and saves."""
        if "__rename__" in fields:
            self._rename_to(take_id, fields["__rename__"])
            return
        if self.store.recording(take_id) is None:
            return
        self.store.update(take_id, lambda r: _apply(r, fields))
        self._save()
        if "edit" in fields and take_id == self.current_id:
            take = self.current
            self.player.set_gain(self._track_for(take).gain_db)
            if self.player.track:
                edit = take.get("edit") or {}
                self.player.track.trim_start = float(edit.get("trimStart", 0))
                self.player.track.trim_end = edit.get("trimEnd")
        self.takes.refresh()
        self.pieces.refresh()
        self._show_inspector()

    def rate(self, value: int) -> None:
        for take_id in self.takes.selected_ids or ([self.current_id] if self.current_id else []):
            self.update_take(take_id, {"rating": value})

    def toggle_favorite(self) -> None:
        for take_id in self.takes.selected_ids or ([self.current_id] if self.current_id else []):
            take = self.store.recording(take_id)
            if take:
                self.update_take(take_id, {"favorite": not take.get("favorite")})

    def rename(self, take_id: str | None = None) -> None:
        take = self.store.recording(take_id or self.current_id or "")
        if take is None:
            return
        name, ok = QInputDialog.getText(self, "Umbenennen", "Neuer Name:", text=Path(take["fileName"]).stem)
        if ok:
            self._rename_to(take["id"], name)

    def _rename_to(self, take_id: str, name: str) -> None:
        try:
            storemod.rename_recording(self.store, take_id, name)
        except (storemod.StoreError, OSError) as error:
            self.message.emit("error", str(error), None)
            self._show_inspector()
            return
        self._save()
        if take_id == self.current_id and self.player.track:
            self.player.track.path = self.store.url(self.store.recording(take_id))
        self.refresh()

    def reveal(self, take_id: str | None = None) -> None:
        take = self.store.recording(take_id or self.current_id or "")
        if take:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.store.folder)))

    def mark_best(self, take_id: str) -> None:
        take = self.store.recording(take_id)
        if take and take.get("pieceID"):
            self.update_piece(take["pieceID"], {"bestTakeID": take_id})

    def _trim(self, take_id: str, key: str) -> None:
        take = self.store.recording(take_id)
        if take is None:
            return
        edit = dict(take.get("edit") or {})
        position = round(self.player.position, 2)
        edit[key] = position
        if float(edit.get("trimStart", 0)) >= float(edit.get("trimEnd") or 1e9):
            self.message.emit("warning", "Der Anfang muss vor dem Ende liegen.", None)
            return
        self.update_take(take_id, {"edit": edit})

    def delete_marker(self, take_id: str, marker_id: str) -> None:
        self.store.update(take_id, lambda r: r.update(markers=[m for m in r.get("markers", []) if m["id"] != marker_id]))
        self._save()
        self._markers_changed(take_id)

    def rename_marker(self, take_id: str, marker_id: str, _label: str) -> None:
        take = self.store.recording(take_id)
        marker = next((m for m in (take or {}).get("markers", []) if m["id"] == marker_id), None)
        if marker is None:
            return
        label, ok = QInputDialog.getText(self, "Marker umbenennen", "Name:", text=marker.get("label", ""))
        if ok:
            marker["label"] = label.strip()
            self._save()
            self._markers_changed(take_id)

    def _markers_changed(self, take_id: str) -> None:
        if take_id == self.current_id:
            self.wave.markers = self.current.get("markers", [])
            self.wave.update()
        self._show_inspector()

    # MARK: Pieces

    def set_piece_for_new(self, piece_id, remember: bool = True) -> None:
        self.recorder.current_piece_id = piece_id
        if remember:
            QSettings("local.sparkstudio", "Spark Studio").setValue("piece", piece_id or "")
        self.takes.set_piece_for_new(piece_id)
        self.pieces.new_piece_id = piece_id
        self.pieces.refresh()

    def create_piece(self, name: str, assign: list[str] | None = None) -> dict:
        piece = storemod.add_piece(self.store, name)
        for take_id in assign or []:
            self.store.update(take_id, lambda r: r.update(pieceID=piece["id"]))
        self._save()
        self.pieces.selected_id = piece["id"]
        self.refresh()
        return piece

    def new_piece(self, take_ids: list[str]) -> None:
        name, ok = QInputDialog.getText(self, "Neues Stück", "Titel:")
        if ok and name.strip():
            piece = self.create_piece(name, take_ids)
            if not take_ids:
                self.set_piece_for_new(piece["id"])

    def update_piece(self, piece_id: str, fields: dict) -> None:
        item = storemod.piece(self.store, piece_id)
        if item is None:
            return
        for key, value in fields.items():
            if value is None:
                item.pop(key, None)
            else:
                item[key] = value
        self._save()
        self.refresh()

    def delete_piece(self, piece_id: str) -> None:
        item = storemod.piece(self.store, piece_id)
        if item is None:
            return
        removed = storemod.remove_piece(self.store, piece_id)
        if self.recorder.current_piece_id == piece_id:
            self.set_piece_for_new(None)
        self.pieces.selected_id = None
        self._save()
        self.refresh()

        def undo():
            storemod.restore_piece(self.store, removed)
            self._save()
            self.refresh()
        self.message.emit("info", f"Das Stück „{item['name']}“ ist gelöscht. Die Takes bleiben.", undo)

    def _show_piece_takes(self, piece_id: str) -> None:
        self.show_tab(0)
        index = self.takes.piece_filter.findData(piece_id)
        if index >= 0:
            self.takes.piece_filter.setCurrentIndex(index)
            self.takes.refresh()

    def _listen_to_best(self, piece_id: str) -> None:
        piece = storemod.piece(self.store, piece_id)
        takes = [t for t in self.recordings if t.get("pieceID") == piece_id]
        best = next((t for t in takes if piece and t["id"] == piece.get("bestTakeID")), takes[0] if takes else None)
        if best is None:
            self.message.emit("info", "Dieses Stück hat noch keine Takes.", None)
            return
        self.show_tab(0)
        self.select(best["id"], play=True)

    # MARK: Sound of a take

    def _sound(self, take_id: str, signal) -> None:
        preset = storemod.read_snapshot(self.store, take_id)
        if preset is None:
            self.message.emit("warning", "Die Einstellungen dieses Sounds fehlen im Ordner .presets.", None)
            return
        signal.emit(preset)

    # MARK: Context menu and export

    def _context_menu(self, ids: list[str], pos) -> None:
        menu = QMenu(self)
        if len(ids) == 1:
            menu.addAction("Umbenennen …", lambda: self.rename(ids[0]))
            menu.addAction("Im Dateimanager zeigen", lambda: self.reveal(ids[0]))
            menu.addSeparator()
        pieces = menu.addMenu("Stück")
        pieces.addAction("Kein Stück", lambda: [self.update_take(i, {"pieceID": None}) for i in ids])
        for piece in sorted(self.store.document["pieces"], key=lambda p: p["name"].casefold()):
            pieces.addAction(piece["name"], lambda pid=piece["id"]: [self.update_take(i, {"pieceID": pid}) for i in ids])
        pieces.addSeparator()
        pieces.addAction("Neues Stück …", lambda: self.new_piece(ids))
        menu.addSeparator()
        menu.addAction("In den Papierkorb legen", self.discard)
        menu.exec(pos)

    def export(self, take_id: str, kind: str) -> None:
        take = self.store.recording(take_id)
        if take is None:
            return
        folder = self.store.folder / "Exporte"
        folder.mkdir(exist_ok=True)
        ext, label = ("wav", "WAV, 24 Bit (*.wav)") if kind == "wav" else ("m4a", "AAC (*.m4a)")
        path, _ = QFileDialog.getSaveFileName(self, "Exportieren", str(folder / f"{Path(take['fileName']).stem}.{ext}"), label)
        if not path:
            return
        edit = take.get("edit") or {}
        track = self._track_for(take)
        command = ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", f"{track.trim_start:.3f}"]
        if track.trim_end:
            command += ["-to", f"{track.trim_end:.3f}"]
        command += ["-i", str(track.path), "-vn"]
        if track.gain_db:
            command += ["-af", f"volume={track.gain_db:.2f}dB"]
        command += (["-c:a", "pcm_s24le"] if kind == "wav" else ["-c:a", "aac", "-b:a", "192k"]) + [path]

        def work():
            ok = subprocess.run(command, capture_output=True).returncode == 0
            self._waves.exported.emit(path, ok)
        threading.Thread(target=work, daemon=True).start()

    def _exported(self, path: str, ok: bool) -> None:
        self.message.emit("success" if ok else "error",
                          f"Exportiert: {Path(path).name}" if ok else "Der Export ist fehlgeschlagen.", None)

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
