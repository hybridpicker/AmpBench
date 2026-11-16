"""The area "Metronome": one dark front, like the tuner. On top the tempo large in amber, the bar and the trainer; below
it one lamp per beat, lit when its click is heard, a click sets it to accent, normal, soft or silent; at the bottom the
modules tempo, bar, sound, trainer and piece. A port of Sources/SparkMetronomeUI/MetronomeView.swift; the sound comes
from ampbench/metronome.py."""
from __future__ import annotations

import time

from PySide6.QtCore import QObject, QRectF, QSettings, Qt, QTimer, Signal
from PySide6.QtGui import QPainter, QPen
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QVBoxLayout, QWidget

from .. import metronome as m
from ..editor import TapTempo
from ..i18n import tr
from . import theme
from .theme import c
from .widgets import (DevicePopup, DeviceSlider, DeviceSwitch, Display, DisplayStepper, Engraving, Front, HardwareKey,
                      SegmentTabs)

SUBDIVISIONS = (1, 2, 3, 4)


class MetronomeArea(QObject):
    """The metronome's state: settings, playing, pieces. ``busy`` says whether a recording or a take is playing."""
    changed = Signal()

    def __init__(self, store=None, busy=lambda: False, settings: QSettings | None = None, player_command=None,
                 parent=None):
        super().__init__(parent)
        self._qsettings = settings or QSettings("local.ampbench", "AmpBench")
        self.settings = m.load_settings(self._qsettings)
        self.store = store
        self._busy = busy
        self._command = player_command
        self.player: m.Player | None = None
        self.problem: str | None = None
        self._tap = TapTempo()
        self.chosen_piece: str | None = None

    # Playing

    @property
    def is_running(self) -> bool:
        return self.player is not None and self.player.is_running

    def toggle(self) -> None:
        self.stop() if self.is_running else self.start()

    def start(self) -> None:
        if self.is_running:
            return
        if self._busy():
            self.problem = tr("A recording or a take is playing. The metronome starts once it is over.")
            self.changed.emit()
            return
        self.player = m.Player(self.settings, command=self._command)
        try:
            self.player.start()
            self.problem = None
        except OSError as error:
            self.player = None
            self.problem = tr("The metronome could not start: {}", error)
        self.changed.emit()

    def stop(self) -> None:
        if self.player is not None:
            self.player.stop()
        self.player = None
        self.changed.emit()

    def check_busy(self) -> None:
        """Called when the recorder changes: a recording or a take with its own timing stops the metronome."""
        if self.is_running and self._busy():
            self.stop()
            self.problem = tr("The metronome stopped: a recording or a take started.")
            self.changed.emit()

    @property
    def playing_bpm(self) -> float:
        return self.player.playing_bpm if self.is_running else self.settings.bpm

    def heard(self) -> m.Pulse | None:
        return self.player.heard_pulse() if self.is_running else None

    # Changing

    def update(self, change) -> None:
        change(self.settings)
        s = self.settings
        s.bpm = float(round(min(max(s.bpm, m.BPM_RANGE[0]), m.BPM_RANGE[1])))
        s.beats_per_bar = int(min(max(s.beats_per_bar, 1), m.MAX_BEATS))
        m.save_settings(self._qsettings, s)
        if self.player is not None:
            self.player.configure(s)
        self.changed.emit()

    def set_bpm(self, bpm: float) -> None:
        self.update(lambda s: setattr(s, "bpm", bpm))

    def nudge(self, delta: float) -> None:
        self.set_bpm(self.settings.bpm + delta)

    def tap(self) -> None:
        bpm = self._tap.tap(time.monotonic())
        if bpm:
            self.set_bpm(bpm)

    def cycle_level(self, beat: int) -> None:
        def change(s):
            s.pattern = s.pattern.setting(m.Pattern.next_level(s.levels[beat]), beat, s.beats_per_bar)
        self.update(change)

    # Pieces: the recorder's, with their tempo and meter, as on the Mac.

    def pieces(self) -> list[dict]:
        if self.store is None:
            return []
        return [p for p in self.store.document.get("pieces", []) if isinstance(p, dict) and p.get("id")]

    def load_piece(self, piece_id: str) -> None:
        piece = next((p for p in self.pieces() if p["id"] == piece_id), None)
        if piece is None or not piece.get("bpm"):
            return

        def change(s):
            s.bpm = float(piece["bpm"])
            meter = piece.get("meter")
            if isinstance(meter, dict):
                s.beats_per_bar = int(meter.get("beatsPerBar", s.beats_per_bar))
                s.pattern = m.pattern_from_json(meter.get("pattern"))
        self.update(change)

    def keep_in_piece(self, piece_id: str) -> None:
        piece = next((p for p in self.pieces() if p["id"] == piece_id), None)
        if piece is None:
            return
        piece["bpm"] = self.settings.bpm
        piece["meter"] = {"beatsPerBar": self.settings.beats_per_bar, "pattern": m.pattern_json(self.settings.pattern)}
        self.store.save()
        self.changed.emit()


def _label(text: str, font, color: str) -> QLabel:
    label = QLabel(text)
    label.setFont(font)
    label.setStyleSheet(f"background: transparent; color: {color};")
    return label


def _divider() -> QFrame:
    line = QFrame()
    line.setFixedWidth(1)
    line.setStyleSheet(f"background: {theme.FRONT_EDGE};")
    return line


def _module(title: str, *widgets: QWidget) -> QWidget:
    box = QWidget()
    column = QVBoxLayout(box)
    column.setContentsMargins(16, 0, 16, 0)
    column.setSpacing(8)
    column.addWidget(Engraving(title))
    for widget in widgets:
        column.addWidget(widget)
    column.addStretch(1)
    return box


def _row(*widgets: QWidget) -> QWidget:
    box = QWidget()
    row = QHBoxLayout(box)
    row.setContentsMargins(0, 0, 0, 0)
    row.setSpacing(6)
    for widget in widgets:
        row.addWidget(widget)
    row.addStretch(1)
    return box


class BeatRow(QWidget):
    """One lamp per beat and small dots for the subdivisions; a click on a lamp changes its level."""
    SIZES = {m.ACCENT: 46, m.NORMAL: 38, m.SOFT: 30, m.MUTE: 30}

    def __init__(self, area: MetronomeArea, parent=None):
        super().__init__(parent)
        self.area = area
        self.pulse: m.Pulse | None = None
        self.setFixedHeight(74)
        self.setAccessibleName(tr("Beats"))

    def _layout(self) -> list[tuple[int, float]]:
        beats, sub = self.area.settings.beats_per_bar, self.area.settings.pattern.subdivision
        unit = 48 + (sub - 1) * 12 + 10
        start = (self.width() - beats * unit + 10) / 2
        return [(b, start + b * unit) for b in range(beats)]

    def mousePressEvent(self, event):
        for beat, x in self._layout():
            if x <= event.position().x() <= x + 48:
                self.area.cycle_level(beat)
                return

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        levels, sub = self.area.settings.levels, self.area.settings.pattern.subdivision
        pulse = self.pulse
        for beat, x in self._layout():
            level = levels[beat]
            size = self.SIZES[level]
            lit = pulse is not None and pulse.beat == beat and pulse.sub == 0 and level != m.MUTE
            color = theme.AMBER_HOT if level == m.ACCENT else theme.AMBER
            box = QRectF(x + (48 - size) / 2, 13 + (48 - size) / 2, size, size)
            p.setPen(Qt.NoPen)
            p.setBrush(c(color) if lit else c(theme.LAMP_OFF))
            p.drawEllipse(box)
            pen = QPen(c(theme.LAMP_OFF_TEXT) if level == m.MUTE else c(color, 0.6), 1.5)
            if level == m.MUTE:
                pen.setStyle(Qt.DashLine)
            p.setPen(pen)
            p.setBrush(Qt.NoBrush)
            p.drawEllipse(box.adjusted(0.75, 0.75, -0.75, -0.75))
            p.setFont(theme.mono(11, bold=True))
            p.setPen(c("#1A1206") if lit else c(theme.LAMP_OFF_TEXT))
            p.drawText(box, Qt.AlignCenter, str(beat + 1))
            for index in range(1, sub):
                dot = QRectF(x + 48 + 6 + (index - 1) * 12, 34, 6, 6)
                on = pulse is not None and pulse.beat == beat and pulse.sub == index
                p.setPen(Qt.NoPen)
                p.setBrush(c(theme.AMBER) if on else c(theme.LAMP_OFF))
                p.drawEllipse(dot)


class MetronomeView(QWidget):
    def __init__(self, area: MetronomeArea, parent=None):
        super().__init__(parent)
        self.area = area
        outer = QVBoxLayout(self)
        outer.setContentsMargins(24, 24, 24, 24)
        outer.setSpacing(14)
        outer.addStretch(1)
        front = Front()
        front.setMaximumWidth(1040)
        inner = QVBoxLayout(front)
        inner.setContentsMargins(18, 18, 18, 12)
        inner.setSpacing(12)

        top = QHBoxLayout()
        top.setSpacing(12)
        tempo_box = Display()
        tempo_box.setFixedHeight(128)
        tempo_column = QVBoxLayout(tempo_box)
        tempo_column.setContentsMargins(18, 8, 18, 10)
        tempo_row = QHBoxLayout()
        self.bpm_label = _label("", theme.mono(64, bold=True), theme.AMBER)
        tempo_row.addWidget(self.bpm_label)
        tempo_row.addWidget(_label("BPM", theme.mono(15, bold=True), theme.AMBER_DIM), 0, Qt.AlignBottom)
        tempo_row.addStretch(1)
        tempo_column.addLayout(tempo_row, 1)
        self.trainer_line = _label("", theme.mono(11), theme.AMBER_DIM)
        tempo_column.addWidget(self.trainer_line)
        top.addWidget(tempo_box, 1)
        bar_box = Display()
        bar_box.setFixedSize(170, 128)
        bar_column = QVBoxLayout(bar_box)
        bar_column.setContentsMargins(18, 10, 18, 10)
        bar_column.addWidget(_label(tr("BAR"), theme.sans(9.5, bold=True, spacing=0.09), theme.AMBER_DIM))
        self.bar_label = _label("–", theme.mono(36, bold=True), theme.AMBER)
        bar_column.addWidget(self.bar_label)
        self.beat_label = _label("", theme.mono(11), theme.AMBER_DIM)
        bar_column.addWidget(self.beat_label)
        top.addWidget(bar_box)
        inner.addLayout(top)

        self.beats = BeatRow(area)
        inner.addWidget(self.beats)
        rule = QFrame()
        rule.setFixedHeight(1)
        rule.setStyleSheet(f"background: {theme.FRONT_EDGE};")
        inner.addWidget(rule)

        controls = QHBoxLayout()
        controls.setSpacing(0)
        self.bpm_stepper = DisplayStepper(int(m.BPM_RANGE[0]), int(m.BPM_RANGE[1]), signed=False)
        self.bpm_stepper.changed.connect(lambda v: area.set_bpm(v))
        self.tap_key = HardwareKey(tr("Tap"), keycap=tr("Ctrl+T"))
        self.tap_key.clicked.connect(area.tap)
        self.start_key = HardwareKey(tr("Start"), style="primary", keycap=tr("Space"))
        self.start_key.clicked.connect(area.toggle)
        controls.addWidget(_module(tr("Tempo"), _row(self.bpm_stepper, self.tap_key), self.start_key))
        controls.addWidget(_divider())

        self.beats_popup = DevicePopup(tr("Beats per bar"))
        self.beats_popup.chosen.connect(lambda v: area.update(lambda s: setattr(s, "beats_per_bar", int(v))))
        self.subdivision_tabs = SegmentTabs(["♩", "♪♪", "3", "16"])
        self.subdivision_tabs.changed.connect(
            lambda i: area.update(lambda s: setattr(s.pattern, "subdivision", SUBDIVISIONS[i])))
        controls.addWidget(_module(tr("Bar"), self.beats_popup, self.subdivision_tabs))
        controls.addWidget(_divider())

        self.sound_popup = DevicePopup(tr("Sound"))
        self.sound_popup.chosen.connect(lambda v: area.update(lambda s: setattr(s.pattern, "sound", int(v))))
        self.volume = DeviceSlider(0, 1, 0.05)
        self.volume.changed.connect(lambda v: area.update(lambda s: setattr(s, "volume", float(v))))
        self.sub_level = DeviceSlider(0, 1, 0.05)
        self.sub_level.changed.connect(lambda v: area.update(lambda s: setattr(s.pattern, "subdivision_level", float(v))))
        controls.addWidget(_module(tr("Sound"), self.sound_popup,
                                   _row(_label(tr("VOLUME"), theme.sans(8.5, bold=True), theme.ENGRAVING), self.volume),
                                   _row(_label(tr("SUBDIVISIONS"), theme.sans(8.5, bold=True), theme.ENGRAVING),
                                        self.sub_level)))
        controls.addWidget(_divider())

        self.trainer_switch = DeviceSwitch(tr("off"), tr("on"))
        self.trainer_switch.toggled.connect(lambda on: area.update(lambda s: setattr(s.trainer, "is_on", on)))
        self.step = DisplayStepper(1, 20, signed=False)
        self.step.changed.connect(lambda v: area.update(lambda s: setattr(s.trainer, "step_bpm", float(v))))
        self.every = DisplayStepper(1, 32, signed=False)
        self.every.changed.connect(lambda v: area.update(lambda s: setattr(s.trainer, "every_bars", int(v))))
        self.target = DisplayStepper(int(m.BPM_RANGE[0]), int(m.BPM_RANGE[1]), signed=False)
        self.target.changed.connect(lambda v: area.update(lambda s: setattr(s.trainer, "target_bpm", float(v))))
        small = theme.sans(8.5, bold=True)
        controls.addWidget(_module(tr("Tempo trainer"), self.trainer_switch,
                                   _row(_label(tr("± BPM"), small, theme.ENGRAVING), self.step,
                                        _label(tr("EVERY"), small, theme.ENGRAVING), self.every),
                                   _row(_label(tr("UP TO"), small, theme.ENGRAVING), self.target)))

        self.piece_box = QWidget()
        piece_row = QHBoxLayout(self.piece_box)
        piece_row.setContentsMargins(0, 0, 0, 0)
        piece_row.setSpacing(0)
        piece_row.addWidget(_divider())
        self.piece_popup = DevicePopup(tr("Piece"))
        self.piece_popup.chosen.connect(self._choose_piece)
        self.load_key = HardwareKey(tr("Load"))
        self.load_key.clicked.connect(lambda: area.chosen_piece and area.load_piece(area.chosen_piece))
        self.keep_key = HardwareKey(tr("Keep in piece"))
        self.keep_key.clicked.connect(lambda: area.chosen_piece and area.keep_in_piece(area.chosen_piece))
        piece_row.addWidget(_module(tr("Piece"), self.piece_popup, _row(self.load_key, self.keep_key)))
        controls.addWidget(self.piece_box)
        inner.addLayout(controls)

        outer.addWidget(front, 0, Qt.AlignHCenter)
        self.caption = _label("", theme.sans(12), theme.DESK_MUTED)
        self.caption.setWordWrap(True)
        self.caption.setAlignment(Qt.AlignCenter)
        self.caption.setFixedWidth(760)
        outer.addWidget(self.caption, 0, Qt.AlignHCenter)
        outer.addStretch(1)

        area.changed.connect(self.refresh)
        self._timer = QTimer(self)
        self._timer.setInterval(8)
        self._timer.timeout.connect(self._animate)
        self._timer.start()
        self.refresh()

    def _choose_piece(self, piece_id) -> None:
        self.area.chosen_piece = piece_id
        self.refresh()

    def _animate(self) -> None:
        if not self.area.is_running:
            return
        pulse = self.area.heard()
        if pulse is not None:
            self.beats.pulse = pulse
            self.bar_label.setText(str(pulse.bar + 1))
            self.beat_label.setText(tr("Beat {} of {}", pulse.beat + 1, self.area.settings.beats_per_bar))
            self.bpm_label.setText(str(round(self.area.playing_bpm)))
            self.beats.update()

    def refresh(self) -> None:
        a, s = self.area, self.area.settings
        running = a.is_running
        if not running:
            self.beats.pulse = None
            self.bar_label.setText("–")
            self.beat_label.setText(f"{s.beats_per_bar}/4")
        self.bpm_label.setText(str(round(a.playing_bpm)))
        t = s.trainer
        self.trainer_line.setText(
            tr("Trainer: {}{} BPM every {} bars, up to {}", "+" if t.target_bpm >= s.bpm else "−", int(abs(t.step_bpm)),
               t.every_bars, int(t.target_bpm)) if t.is_on else (tr("playing") if running else tr("stopped")))
        self.bpm_stepper.set_value(int(s.bpm))
        self.start_key.setText(tr("Stop") if running else tr("Start"))
        self.start_key.set_style("on" if running else "primary")
        self.beats_popup.set_options([(f"{n}/4", n) for n in range(1, m.MAX_BEATS + 1)], f"{s.beats_per_bar}/4")
        self.subdivision_tabs.set_index(SUBDIVISIONS.index(s.pattern.subdivision) if s.pattern.subdivision in SUBDIVISIONS else 0)
        sounds = [(tr("Classic"), 0), (tr("Wood"), 1), (tr("Beep"), 2)]
        self.sound_popup.set_options(sounds, sounds[s.pattern.sound][0])
        self.volume.set_value(s.volume)
        self.sub_level.set_value(s.pattern.subdivision_level)
        self.sub_level.setEnabled(s.pattern.subdivision > 1)
        self.trainer_switch.set_on(t.is_on)
        self.step.set_value(int(t.step_bpm))
        self.every.set_value(int(t.every_bars))
        self.target.set_value(int(t.target_bpm))
        pieces = a.pieces()
        self.piece_box.setVisible(bool(pieces))
        if pieces:
            if a.chosen_piece not in {p["id"] for p in pieces}:
                a.chosen_piece = pieces[0]["id"]
            options = [(f"{p.get('name', '?')} · {int(p['bpm'])}" if p.get("bpm") else p.get("name", "?"), p["id"])
                       for p in pieces]
            current = next(name for name, pid in options if pid == a.chosen_piece)
            self.piece_popup.set_options(options, current)
        self.caption.setText(a.problem or tr(
            "Plays on the system's output through PipeWire. Every click is placed on the output's own sample clock, "
            "to a fraction of a sample, and the lamps light when it is heard. Space starts and stops it; a recording "
            "or a playing take stops it."))
        self.beats.update()
