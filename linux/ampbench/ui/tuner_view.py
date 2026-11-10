"""The area "Tuner": one dark front on the desk. On top the readout, the note large in amber and the deviation and
frequency in mono, with lamps for signal, too low, in tune and too high; below it the needle field or the strobe; at
the bottom the modules input, tuning, concert pitch and display. A port of Sources/SparkTunerUI/TunerView.swift and
the needle and strobe of Sources/SparkDesign/CentMeter.swift."""
from __future__ import annotations

import time

from PySide6.QtCore import QPointF, QRectF, Qt, QTimer
from PySide6.QtGui import QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QVBoxLayout, QWidget

from .. import tuning as tun
from ..i18n import tr
from ..tuner import TunerModel
from . import theme
from .theme import c
from .widgets import DevicePopup, Display, Engraving, Front, HardwareKey, Lamp, LEDSegments


class CentMeter(QWidget):
    """A needle over a scale of ±50 cents with a narrow window of ±0.5 cents in the middle, green when in tune."""
    RANGE = 50

    def __init__(self, parent=None):
        super().__init__(parent)
        self.readout: tun.TunerReadout | None = None
        self.setFixedHeight(96)
        self.setAccessibleName(tr("Deviation"))

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        _glass(p, self.rect())
        inset, baseline = 22.0, self.height() - 26.0
        width = self.width() - 2 * inset

        def x(cents: float) -> float:
            return inset + (cents + self.RANGE) / (2 * self.RANGE) * width

        r = self.readout
        in_tune = r is not None and r.is_in_tune and not r.is_held
        zone = max(x(0.5) - x(-0.5), 3)
        p.setPen(Qt.NoPen)
        p.setBrush(c(theme.ON, 0.45) if in_tune else c(theme.AMBER, 0.12))
        p.drawRoundedRect(QRectF(x(0) - zone / 2, 10, zone, baseline - 10), 1.5, 1.5)
        p.setFont(theme.mono(9.5))
        for tick in range(-self.RANGE, self.RANGE + 1):
            ten, five = tick % 10 == 0, tick % 5 == 0
            length = 30 if tick == 0 else 20 if ten else 13 if five else 7
            color = c(theme.AMBER) if tick == 0 else c(theme.AMBER_DIM) if five else c(theme.AMBER_DIM, 0.55)
            p.setPen(QPen(color, 1.5 if tick == 0 else 1.2 if ten else 1))
            p.drawLine(QPointF(x(tick), baseline - length), QPointF(x(tick), baseline))
            if ten:
                label = "0" if tick == 0 else f"−{-tick}" if tick < 0 else f"+{tick}"
                p.setPen(c(theme.AMBER if tick == 0 else theme.AMBER_DIM))
                p.drawText(QRectF(x(tick) - 20, baseline + 4, 40, 16), Qt.AlignCenter, label)
        if r is None:
            return
        clamped = min(max(r.cents, -self.RANGE), self.RANGE)
        nx = x(clamped)
        color = c(theme.AMBER_DIM if r.is_held else theme.AMBER)
        if not r.is_held:
            p.setPen(QPen(c(theme.AMBER, 0.25), 7, Qt.SolidLine, Qt.RoundCap))
            p.drawLine(QPointF(nx, 6), QPointF(nx, baseline + 2))
        p.setPen(QPen(color, 2.5, Qt.SolidLine, Qt.RoundCap))
        p.drawLine(QPointF(nx, 6), QPointF(nx, baseline + 2))
        if abs(r.cents) > self.RANGE:
            # Off the scale: an arrow at the end points on.
            d = 1 if r.cents > 0 else -1
            path = QPainterPath(QPointF(nx + d * 4, 8))
            path.lineTo(QPointF(nx + d * 12, 14))
            path.lineTo(QPointF(nx + d * 4, 20))
            p.setPen(QPen(color, 2, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
            p.drawPath(path)


class StrobeBand(QWidget):
    """Two rows of lit segments that drift right when the tone is too high and left when too low, faster the further
    off, and stand still when in tune. The lower row moves four times as fast, so a tenth of a cent still shows."""
    SPEED, PERIOD = 6.0, 18.0

    def __init__(self, parent=None):
        super().__init__(parent)
        self.readout: tun.TunerReadout | None = None
        self.setFixedHeight(96)
        self.setAccessibleName(tr("Strobe"))
        self._upper = self._lower = 0.0
        self._last: float | None = None

    def advance(self) -> None:
        now = time.monotonic()
        elapsed = min(max(now - self._last, 0.0), 0.1) if self._last is not None else 0.0
        self._last = now
        r = self.readout
        if r is None or r.is_held:
            still = (min(max(r.cents, -50), 50) / 50 * self.PERIOD / 2) if r else 0.0
            self._upper = self._lower = still
            return
        cents = min(max(r.cents, -50), 50)
        self._upper = (self._upper + cents * self.SPEED * elapsed) % self.PERIOD
        self._lower = (self._lower + cents * self.SPEED * 4 * elapsed) % self.PERIOD

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        _glass(p, self.rect())
        inset = 14.0
        row_height = (self.height() - 2 * inset - 10) / 2
        r = self.readout
        in_tune = r is not None and r.is_in_tune and not r.is_held
        color = c("#2A2824") if r is None else c(theme.AMBER_DIM if r.is_held else theme.AMBER)
        p.setPen(Qt.NoPen)
        for row, offset in enumerate((self._upper, self._lower)):
            top = inset + row * (row_height + 10)
            p.save()
            p.setClipRect(QRectF(inset, top, self.width() - 2 * inset, row_height))
            x = inset - self.PERIOD + offset % self.PERIOD
            while x < self.width() - inset:
                p.setBrush(color)
                p.drawRoundedRect(QRectF(x, top, self.PERIOD / 2, row_height), 1, 1)
                x += self.PERIOD
            p.restore()
        p.setPen(QPen(c(theme.ON) if in_tune else c(theme.AMBER_DIM, 0.6), 2 if in_tune else 1))
        p.drawLine(QPointF(self.width() / 2, 4), QPointF(self.width() / 2, self.height() - 4))


def _glass(p: QPainter, rect) -> None:
    r = QRectF(rect).adjusted(0.5, 0.5, -0.5, -0.5)
    p.setPen(QPen(c(theme.DISPLAY_EDGE), 1))
    p.setBrush(c(theme.DISPLAY))
    p.drawRoundedRect(r, 8, 8)


def _label(text: str, font, color: str) -> QLabel:
    label = QLabel(text)
    label.setFont(font)
    label.setStyleSheet(f"background: transparent; color: {color};")
    return label


class StringLamps(QWidget):
    """The tuning's strings, the one found lit."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.tuning = tun.Tuning("standard")
        self.found: int | None = None
        self.setFixedHeight(32)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        strings = self.tuning.strings
        if not strings:
            p.setFont(theme.sans(9.5, bold=True, spacing=0.09))
            p.setPen(c(theme.LAMP_OFF_TEXT))
            p.drawText(self.rect(), Qt.AlignLeft | Qt.AlignVCenter, tr("ALL NOTES, WITH NAME AND OCTAVE"))
            return
        width = self.width() / len(strings)
        for index, note in enumerate(strings):
            number = len(strings) - index
            lit = self.found == number
            cx = width * (index + 0.5)
            p.setPen(Qt.NoPen)
            p.setBrush(c(theme.AMBER) if lit else c(theme.LAMP_OFF))
            p.drawEllipse(QPointF(cx, 6), 3.5, 3.5)
            p.setFont(theme.sans(11, bold=True))
            p.setPen(c(theme.AMBER if lit else theme.TEXT_DIM))
            p.drawText(QRectF(cx - width / 2, 12, width, 18), Qt.AlignCenter, note.name(self.tuning.prefers_flats))


def _module(title: str, *widgets: QWidget, lamp: QWidget | None = None) -> QWidget:
    box = QWidget()
    column = QVBoxLayout(box)
    column.setContentsMargins(18, 0, 18, 0)
    column.setSpacing(8)
    head = QHBoxLayout()
    head.addWidget(Engraving(title))
    head.addStretch(1)
    if lamp is not None:
        head.addWidget(lamp)
    column.addLayout(head)
    for widget in widgets:
        column.addWidget(widget)
    column.addStretch(1)
    return box


def _divider() -> QFrame:
    line = QFrame()
    line.setFixedWidth(1)
    line.setStyleSheet(f"background: {theme.FRONT_EDGE};")
    return line


class TunerView(QWidget):
    def __init__(self, model: TunerModel, parent=None):
        super().__init__(parent)
        self.model = model
        outer = QVBoxLayout(self)
        outer.setContentsMargins(24, 24, 24, 24)
        outer.setSpacing(14)
        front = Front()
        front.setMaximumWidth(1040)
        inner = QVBoxLayout(front)
        inner.setContentsMargins(18, 18, 18, 12)
        inner.setSpacing(12)

        top = QHBoxLayout()
        top.setSpacing(12)
        note_box = Display()
        note_box.setFixedSize(272, 172)
        note_column = QVBoxLayout(note_box)
        note_column.setContentsMargins(18, 10, 18, 12)
        note_row = QHBoxLayout()
        self.note = _label("–", theme.sans(96, bold=True), theme.AMBER)
        self.octave = _label("", theme.mono(28, bold=True), theme.AMBER_DIM)
        note_row.addWidget(self.note)
        note_row.addWidget(self.octave, 0, Qt.AlignBottom)
        note_row.addStretch(1)
        note_column.addLayout(note_row, 1)
        self.string_line = _label("", theme.mono(11, bold=True), theme.AMBER_DIM)
        note_column.addWidget(self.string_line)
        top.addWidget(note_box)

        value_box = Display()
        value_box.setFixedHeight(172)
        value_row = QHBoxLayout(value_box)
        value_row.setContentsMargins(20, 14, 20, 14)
        values = QVBoxLayout()
        cents_row = QHBoxLayout()
        self.cents = _label(tr("–.–"), theme.mono(52, bold=True), theme.AMBER)
        cents_row.addWidget(self.cents)
        cents_row.addWidget(_label(tr("CENTS"), theme.sans(10, bold=True, spacing=0.09), theme.AMBER_DIM), 0, Qt.AlignBottom)
        cents_row.addStretch(1)
        values.addLayout(cents_row)
        hertz_row = QHBoxLayout()
        self.hertz = _label(tr("–.––"), theme.mono(20), theme.AMBER)
        hertz_row.addWidget(self.hertz)
        hertz_row.addWidget(_label("HZ", theme.sans(9.5, bold=True, spacing=0.09), theme.AMBER_DIM), 0, Qt.AlignBottom)
        hertz_row.addStretch(1)
        values.addLayout(hertz_row)
        values.addStretch(1)
        self.target_line = _label("", theme.mono(10.5), theme.AMBER_DIM)
        values.addWidget(self.target_line)
        value_row.addLayout(values, 1)
        lamps = QVBoxLayout()
        lamps.setSpacing(10)
        self.lamp_signal = Lamp(tr("Signal"), "amber", size=9)
        self.lamp_low = Lamp(tr("Too low"), "amber", size=9)
        self.lamp_in_tune = Lamp(tr("In tune"), "on", size=9)
        self.lamp_high = Lamp(tr("Too high"), "amber", size=9)
        for lamp in (self.lamp_signal, self.lamp_low, self.lamp_in_tune, self.lamp_high):
            lamps.addWidget(lamp)
        lamps.addStretch(1)
        value_row.addLayout(lamps)
        top.addWidget(value_box, 1)
        inner.addLayout(top)

        self.meter = CentMeter()
        self.strobe = StrobeBand()
        inner.addWidget(self.meter)
        inner.addWidget(self.strobe)
        rule = QFrame()
        rule.setFixedHeight(1)
        rule.setStyleSheet(f"background: {theme.FRONT_EDGE};")
        inner.addWidget(rule)

        controls = QHBoxLayout()
        controls.setSpacing(0)
        self.input_popup = DevicePopup(tr("Input"))
        self.input_popup.chosen.connect(model.choose)
        self.input_lamp = Lamp(tr("Listening"), "amber")
        self.level = LEDSegments(36, 6)
        self.mute_note = _label(tr("AMP MUTED WHILE IT MEASURES"), theme.sans(9, bold=True, spacing=0.09),
                                theme.LAMP_OFF_TEXT)
        controls.addWidget(_module(tr("Input"), self.input_popup, self.level, self.mute_note, lamp=self.input_lamp), 1)
        controls.addWidget(_divider())
        self.tuning_popup = DevicePopup(tr("Tuning"))
        self.tuning_popup.chosen.connect(model.set_tuning)
        self.strings = StringLamps()
        controls.addWidget(_module(tr("Tuning"), self.tuning_popup, self.strings), 1)
        controls.addWidget(_divider())
        pitch = QWidget()
        pitch_row = QHBoxLayout(pitch)
        pitch_row.setContentsMargins(0, 0, 0, 0)
        self.a4_down = HardwareKey("−")
        self.a4_down.clicked.connect(lambda: model.set_a4(model.a4 - 0.1))
        self.a4_label = _label("", theme.mono(15, bold=True), theme.AMBER)
        self.a4_up = HardwareKey("+")
        self.a4_up.clicked.connect(lambda: model.set_a4(model.a4 + 0.1))
        self.a4_reset = HardwareKey("440", keycap=tr("Ctrl+0"))
        self.a4_reset.clicked.connect(lambda: model.set_a4(tun.DEFAULT_A4))
        for widget in (self.a4_down, self.a4_label, self.a4_up, self.a4_reset):
            pitch_row.addWidget(widget)
        controls.addWidget(_module(tr("Concert pitch"), pitch,
                                   _label(tr("IN TENTHS OF A HERTZ"), theme.sans(9, bold=True, spacing=0.09),
                                          theme.LAMP_OFF_TEXT)))
        controls.addWidget(_divider())
        self.strobe_key = HardwareKey(tr("Strobe"), keycap=tr("Ctrl+T"))
        self.strobe_key.clicked.connect(lambda: model.set_strobe(not model.shows_strobe))
        self.display_note = _label("", theme.sans(9, bold=True, spacing=0.09), theme.LAMP_OFF_TEXT)
        controls.addWidget(_module(tr("Display"), self.strobe_key, self.display_note))
        inner.addLayout(controls)

        outer.addWidget(front, 0, Qt.AlignHCenter)
        self.caption = _label("", theme.sans(12), theme.DESK_MUTED)
        self.caption.setWordWrap(True)
        self.caption.setAlignment(Qt.AlignCenter)
        self.caption.setFixedWidth(700)
        self.caption.setMinimumHeight(40)
        outer.addWidget(self.caption, 0, Qt.AlignHCenter)
        outer.addStretch(1)

        model.changed.connect(self.refresh)
        self._animation = QTimer(self)
        self._animation.setInterval(16)
        self._animation.timeout.connect(self._animate)
        self.refresh()

    def showEvent(self, event):
        super().showEvent(event)
        self._animation.start()

    def hideEvent(self, event):
        super().hideEvent(event)
        self._animation.stop()

    def _animate(self) -> None:
        if self.model.shows_strobe:
            self.strobe.advance()
            self.strobe.update()

    # MARK: Text

    def _status_line(self) -> str:
        m = self.model
        if m.uses_amp:
            if m.status in ("idle", "opening"):
                return tr("SWITCHING THE TUNER ON …")
            if m.status in ("listening", "demo"):
                return tr("MEASURING …") if m.has_signal else tr("PLAY A STRING")
            return tr("NO AMP CONNECTED")
        if m.status in ("idle", "opening"):
            return tr("OPENING THE INPUT …")
        if m.status in ("listening", "demo"):
            return tr("LISTENING …") if m.has_signal else tr("PLAY A STRING")
        if m.status == "no_input":
            return tr("NO SPARK CONNECTED") if m.input_name == tr("No Spark") else tr("INPUT MISSING")
        return tr("THE INPUT CANNOT BE OPENED")

    def _caption(self) -> str:
        m = self.model
        if m.uses_amp:
            if m.amp_name:
                return tr("The {} tuner is on while this area is in front, and the amp is muted meanwhile. Its "
                          "readings come over Bluetooth and are coarser than over USB, in whole cents.", m.amp_name)
            return tr("The amp’s tuner is on while this area is in front, and the amp is muted meanwhile. Its "
                      "readings come over Bluetooth and are coarser than over USB, in whole cents.")
        if m.status == "no_input" and m.source != "automatic" and m.amp_name:
            return tr("Without USB audio the {0} tuner can measure: choose “{0} tuner” under Input. The amp is then "
                      "muted while this area is in front.", m.amp_name)
        return tr("The tuner listens only while this area is in front. It sends nothing to the amp, plays no sound "
                  "and stores nothing.")

    def refresh(self) -> None:
        m, r = self.model, self.model.readout
        live = r is not None and not r.is_held
        color = theme.AMBER if live else theme.AMBER_DIM
        for label in (self.note, self.cents, self.hertz):
            label.setStyleSheet(f"background: transparent; color: {color};")
        self.note.setText(r.note_name if r else "–")
        self.octave.setText(str(r.note.octave) if r and r.knows_octave else "")
        if r is None:
            self.string_line.setText(self._status_line())
        elif not r.knows_octave:
            self.string_line.setText(tr("FROM THE AMP · {}", r.note_name))
        else:
            target = f"{r.note_name}{r.note.octave}"
            self.string_line.setText(tr("STRING {} · {}", r.string, target) if r.string else
                                     tr("CHROMATIC · {}", target) if m.tuning.key == "chromatic"
                                     else tr("NO STRING · {}", target))
        self.cents.setText((tun.whole_cents_text(r.cents) if r.is_from_amp else tun.cents_text(r.cents)) if r
                           else ("–" if m.uses_amp else tr("–.–")))
        self.hertz.setText(tun.hertz_text(r.frequency) if r and r.knows_octave else tr("–.––"))
        a4 = tun.hertz_text(m.a4, 1)
        if r is None:
            self.target_line.setText(tr("FROM THE AMP · A4 = {} HZ", a4) if m.uses_amp
                                     else tr("CONCERT PITCH A4 = {} HZ", a4))
        else:
            held = " · " + tr("HELD") if r.is_held else ""
            target = tun.hertz_text(r.note.frequency(m.a4))
            if r.is_from_amp:
                self.target_line.setText((tr("TARGET {} HZ · FROM THE AMP", target) if r.knows_octave
                                          else tr("FROM THE AMP")) + held)
            else:
                self.target_line.setText(tr("TARGET {} HZ · A4 = {} HZ", target, a4) + held)
        self.lamp_signal.set_state(m.has_signal)
        self.lamp_low.set_state(live and r.direction == "low")
        self.lamp_in_tune.set_state(live and r.is_in_tune)
        self.lamp_high.set_state(live and r.direction == "high")
        self.meter.readout = self.strobe.readout = r
        self.meter.setVisible(not m.shows_strobe)
        self.strobe.setVisible(m.shows_strobe)
        self.meter.update()
        self.strobe.update()

        options = [(tr("Automatic (USB audio, otherwise the amp’s tuner)"), "automatic"),
                   (tr("{} (as in the deck)", m.deck_input_name) if m.deck_input_name else tr("Spark from the deck"),
                    "deck")]
        if m.amp_name:
            options.append((tr("{} tuner (amp muted)", m.amp_name), "amp"))
        self.input_popup.set_options(options, m.input_name)
        self.input_lamp.set_state(m.status == "listening",
                                  tr("Measuring") if m.uses_amp else tr("Shared") if m.is_shared_with_recording
                                  else tr("Listening"))
        self.level.set_fraction(m.level)
        self.level.setVisible(not m.uses_amp)
        self.mute_note.setVisible(m.uses_amp)
        self.tuning_popup.set_options([(t.title, t.key) for t in tun.Tuning.all()], m.tuning.title)
        self.strings.tuning, self.strings.found = m.tuning, r.string if r else None
        self.strings.update()
        self.a4_label.setText(f"{a4} HZ")
        self.a4_reset.setEnabled(m.a4 != tun.DEFAULT_A4)
        self.strobe_key.set_style("on" if m.shows_strobe else "normal")
        self.display_note.setText(tr("STANDS STILL WHEN IN TUNE") if m.shows_strobe else tr("NEEDLE ±50 CENTS"))
        self.caption.setText(self._caption())
        self.setAccessibleDescription(tun.spoken(r) if r and live else self._status_line())
