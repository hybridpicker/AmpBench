"""The building blocks of docs/DESIGN.md, drawn with QPainter: fronts, displays, keys, lamps, knobs, pedals."""
from __future__ import annotations

import math

from PySide6.QtCore import QPointF, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import (QBrush, QColor, QFontDatabase, QFontMetrics, QLinearGradient, QPainter, QPainterPath, QPen,
                           QRadialGradient)
from PySide6.QtWidgets import QAbstractButton, QFrame, QSizePolicy, QWidget

from . import theme
from .theme import c


def vgradient(rect: QRectF, top: str, bottom: str) -> QLinearGradient:
    g = QLinearGradient(rect.topLeft(), rect.bottomLeft())
    g.setColorAt(0, c(top))
    g.setColorAt(1, c(bottom))
    return g


def spaced(text: str) -> str:
    return text.upper()


class Front(QFrame):
    """A hardware front: dark gradient, a dark edge and a thin light edge on top."""

    def __init__(self, radius: float = 14, parent=None):
        super().__init__(parent)
        self.radius = radius

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        p.setPen(QPen(c(theme.FRONT_EDGE), 1))
        p.setBrush(vgradient(r, theme.FRONT_TOP, theme.FRONT_BOTTOM))
        p.drawRoundedRect(r, self.radius, self.radius)
        p.setPen(QPen(c("#FFFFFF", 0.07), 1))
        p.drawLine(QPointF(r.left() + self.radius, r.top() + 1), QPointF(r.right() - self.radius, r.top() + 1))


class Display(QFrame):
    """The amber display: nearly black glass with a dark edge."""

    def __init__(self, radius: float = 10, parent=None):
        super().__init__(parent)
        self.radius = radius

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        p.setPen(QPen(c(theme.DISPLAY_EDGE), 1))
        p.setBrush(c(theme.DISPLAY))
        p.drawRoundedRect(r, self.radius, self.radius)
        shade = QLinearGradient(r.topLeft(), r.topLeft() + QPointF(0, 10))
        shade.setColorAt(0, c("#000000", 0.45))
        shade.setColorAt(1, c("#000000", 0))
        p.setPen(Qt.NoPen)
        p.setBrush(shade)
        p.drawRoundedRect(r.adjusted(1, 1, -1, -1), self.radius, self.radius)


class Engraving(QWidget):
    """Engraved capitals on a front, such as SPARK or PEGEL."""

    def __init__(self, text: str, color: str = theme.ENGRAVING, parent=None):
        super().__init__(parent)
        self.text, self.color = text.upper(), color
        self.setFont(theme.sans(10, bold=True, spacing=0.09))
        self.setFixedHeight(16)

    def sizeHint(self):
        return QSize(QFontMetrics(self.font()).horizontalAdvance(self.text) + 4, 16)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setFont(self.font())
        p.setPen(c(self.color))
        p.drawText(self.rect(), Qt.AlignLeft | Qt.AlignVCenter, self.text)


class Lamp(QWidget):
    """A state with its word, never color alone."""
    TONES = {"on": theme.ON, "amber": theme.LISTENING, "hot": theme.AMBER_HOT, "rec": theme.RECORD}

    def __init__(self, text: str = "", tone: str = "on", lit: bool = False, size: int = 7, parent=None):
        super().__init__(parent)
        self.text, self.tone, self.lit, self.size = text, tone, lit, size
        self.setFont(theme.sans(10, bold=True, spacing=0.09))
        self.setFixedHeight(16)

    def set_state(self, lit: bool, text: str | None = None, tone: str | None = None) -> None:
        self.lit = lit
        if text is not None:
            self.text = text
        if tone is not None:
            self.tone = tone
        self.updateGeometry()
        self.update()

    def sizeHint(self):
        width = self.size + 6 + QFontMetrics(self.font()).horizontalAdvance(self.text.upper()) + 2
        return QSize(width, 16)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        color = c(self.TONES.get(self.tone, theme.ON))
        cy = self.height() / 2
        if self.lit:
            glow = QRadialGradient(QPointF(self.size / 2 + 1, cy), self.size * 1.6)
            glow.setColorAt(0, c(color.name(), 0.55))
            glow.setColorAt(1, c(color.name(), 0))
            p.setPen(Qt.NoPen)
            p.setBrush(glow)
            p.drawEllipse(QPointF(self.size / 2 + 1, cy), self.size * 1.6, self.size * 1.6)
        p.setPen(Qt.NoPen)
        p.setBrush(color if self.lit else c(theme.LAMP_OFF))
        p.drawEllipse(QPointF(self.size / 2 + 1, cy), self.size / 2, self.size / 2)
        p.setFont(self.font())
        p.setPen(c(theme.TEXT if self.lit else theme.LAMP_OFF_TEXT))
        p.drawText(QRectF(self.size + 7, 0, self.width(), self.height()), Qt.AlignLeft | Qt.AlignVCenter,
                   self.text.upper())


class HardwareKey(QAbstractButton):
    """The one kind of button on a device: a key with its shortcut engraved as a keycap."""

    def __init__(self, text: str = "", style: str = "normal", keycap: str = "", parent=None):
        super().__init__(parent)
        self.setText(text)
        self.style_name, self.keycap = style, keycap
        self.setFont(theme.sans(12, bold=True))
        self.setCursor(Qt.PointingHandCursor)
        self.setFocusPolicy(Qt.TabFocus)
        self.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Fixed)

    def set_style(self, style: str) -> None:
        self.style_name = style
        self.update()

    def sizeHint(self):
        fm = QFontMetrics(self.font())
        width = fm.horizontalAdvance(self.text()) + 26
        if self.keycap:
            width += QFontMetrics(theme.mono(9, True)).horizontalAdvance(self.keycap) + 16
        return QSize(max(width, 34), 28)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        enabled = self.isEnabled()
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        top, bottom, ink, cap_ink, cap_bg = theme.KEY_TOP, theme.KEY_BOTTOM, theme.TEXT, theme.ENGRAVING, c("#000000", .35)
        if self.style_name == "primary":
            top, bottom, ink, cap_ink, cap_bg = theme.MAIN_TOP, theme.MAIN_BOTTOM, theme.KEY_INK, "#2E2004", c("#000000", .12)
        elif self.style_name == "on" or self.isChecked():
            top, bottom, ink, cap_ink, cap_bg = theme.ON_TOP, theme.ON_BOTTOM, theme.KEY_INK, "#2E2004", c("#000000", .12)
        elif self.style_name == "danger":
            ink = theme.DANGER_TEXT
        if self.isDown():
            top, bottom = bottom, top
        p.setOpacity(1.0 if enabled else 0.4)
        p.setPen(QPen(c(theme.KEY_EDGE), 1))
        p.setBrush(vgradient(r, top, bottom))
        p.drawRoundedRect(r, 6, 6)
        p.setPen(QPen(c("#FFFFFF", 0.12), 1))
        p.drawLine(QPointF(r.left() + 6, r.top() + 1), QPointF(r.right() - 6, r.top() + 1))
        if self.hasFocus():
            p.setPen(QPen(c(theme.AMBER), 1.5))
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(r.adjusted(-1, -1, 1, 1), 7, 7)
        p.setFont(self.font())
        p.setPen(c(ink))
        text_rect = QRectF(r)
        if self.keycap:
            cap_font = theme.mono(9, True)
            cap_w = QFontMetrics(cap_font).horizontalAdvance(self.keycap) + 10
            cap = QRectF(r.right() - cap_w - 6, r.center().y() - 8, cap_w, 16)
            p.setPen(Qt.NoPen)
            p.setBrush(cap_bg)
            p.drawRoundedRect(cap, 4, 4)
            p.setFont(cap_font)
            p.setPen(c(cap_ink))
            p.drawText(cap, Qt.AlignCenter, self.keycap)
            text_rect = QRectF(r.left(), r.top(), cap.left() - r.left(), r.height())
            p.setFont(self.font())
            p.setPen(c(ink))
            p.drawText(text_rect, Qt.AlignCenter, self.text())
        else:
            p.drawText(text_rect, Qt.AlignCenter, self.text())


class LEDSegments(QWidget):
    """A row of small segments, green up to 60 %, amber to 85 %, red above. Used as the transfer meter."""

    def __init__(self, segments: int = 36, height: int = 6, parent=None):
        super().__init__(parent)
        self.segments, self.fraction, self.indeterminate = segments, 0.0, False
        self.setFixedHeight(height)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self._phase = 0
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._tick)

    def set_fraction(self, fraction: float | None) -> None:
        self.indeterminate = fraction is None
        self.fraction = fraction or 0.0
        if self.indeterminate and not self._timer.isActive():
            self._timer.start(90)
        elif not self.indeterminate:
            self._timer.stop()
        self.update()

    def _tick(self):
        self._phase = (self._phase + 1) % self.segments
        self.update()

    def paintEvent(self, _):
        p = QPainter(self)
        gap = 2
        w = max((self.width() - gap * (self.segments - 1)) / self.segments, 2)
        lit = int(round(self.fraction * self.segments))
        p.setPen(Qt.NoPen)
        for i in range(self.segments):
            on = (abs(i - self._phase) < 3) if self.indeterminate else i < lit
            ratio = i / self.segments
            tone = theme.ON if ratio < 0.6 else theme.AMBER if ratio < 0.85 else theme.RECORD
            p.setBrush(c(tone) if on else c("#2A2824"))
            p.drawRoundedRect(QRectF(i * (w + gap), 0, w, self.height()), 1, 1)


class Knob(QWidget):
    """A rotary control: ring in the accent color from 225° over 270°, dark body, amber pointer, name and value."""
    changed = Signal(float)
    gesture_started = Signal()
    gesture_ended = Signal()

    def __init__(self, name: str, accent: QColor, start: float | None = None, display=None, size: int = 64, parent=None):
        super().__init__(parent)
        self.name, self.accent, self.start = name, accent, start
        self.display = display or (lambda v: f"{v * 10:.1f}".replace(".", ","))
        self.diameter = size
        self.value = 0.0
        self.locked = False
        self._drag = None
        self.setFixedSize(max(size + 24, 84), size + 50)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setCursor(Qt.SizeVerCursor)
        self.setToolTip("Scrollen dreht fein, Ziehen grob, Doppelklick setzt den Standardwert.")

    def set_value(self, value: float) -> None:
        self.value = min(max(value, 0.0), 1.0)
        self.update()

    def _set_from_user(self, value: float) -> None:
        if self.locked:
            return
        value = min(max(value, 0.0), 1.0)
        if value != self.value:
            self.value = value
            self.update()
            self.changed.emit(value)

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton and not self.locked:
            self.setFocus()
            self._drag = (event.position().y(), self.value)
            self.gesture_started.emit()

    def mouseMoveEvent(self, event):
        if self._drag:
            fine = 0.25 if event.modifiers() & Qt.ShiftModifier else 1.0
            self._set_from_user(self._drag[1] + (self._drag[0] - event.position().y()) / 170 * fine)

    def mouseReleaseEvent(self, event):
        if self._drag:
            self._drag = None
            self.gesture_ended.emit()

    def mouseDoubleClickEvent(self, event):
        if self.start is not None and not self.locked:
            self.gesture_started.emit()
            self._set_from_user(self.start)
            self.gesture_ended.emit()

    def wheelEvent(self, event):
        if self.locked:
            return
        self.gesture_started.emit()
        self._set_from_user(self.value + event.angleDelta().y() / 120 * 0.01)
        self.gesture_ended.emit()
        event.accept()

    def keyPressEvent(self, event):
        step = 0.1 if event.modifiers() & Qt.ShiftModifier else 0.01
        delta = {Qt.Key_Up: step, Qt.Key_Right: step, Qt.Key_Down: -step, Qt.Key_Left: -step}.get(event.key())
        if delta is None:
            return super().keyPressEvent(event)
        self.gesture_started.emit()
        self._set_from_user(self.value + delta)
        self.gesture_ended.emit()

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        d = self.diameter
        box = QRectF((self.width() - d) / 2, 4, d, d)
        draw_knob(p, box, self.value, self.accent, ring=5.0)
        if self.hasFocus():
            p.setPen(QPen(c(theme.AMBER), 1.5))
            p.setBrush(Qt.NoBrush)
            p.drawEllipse(box.adjusted(-3, -3, 3, 3))
        p.setFont(theme.sans(10, bold=True, spacing=0.09))
        p.setPen(c(theme.ENGRAVING))
        p.drawText(QRectF(0, d + 10, self.width(), 14), Qt.AlignCenter, self.name.upper())
        p.setFont(theme.mono(13, True))
        p.setPen(c(theme.AMBER if not self.locked else theme.AMBER_DIM))
        p.drawText(QRectF(0, d + 25, self.width(), 18), Qt.AlignCenter, self.display(self.value))


def draw_knob(p: QPainter, box: QRectF, value: float, accent: QColor, ring: float = 5.0, dim: bool = False) -> None:
    sweep = 270
    inset = ring / 2 + 0.5
    arc = box.adjusted(inset, inset, -inset, -inset)
    p.setBrush(Qt.NoBrush)
    p.setPen(QPen(c("#000000", 0.55), ring, Qt.SolidLine, Qt.RoundCap))
    p.drawArc(arc, 225 * 16, -sweep * 16)
    ring_color = QColor(accent)
    if dim:
        ring_color.setAlphaF(0.35)
    p.setPen(QPen(ring_color, ring, Qt.SolidLine, Qt.RoundCap))
    if value > 0.002:
        p.drawArc(arc, 225 * 16, int(-sweep * value * 16))
    body = box.adjusted(ring + 2, ring + 2, -ring - 2, -ring - 2)
    grad = QRadialGradient(body.center() - QPointF(0, body.height() * 0.18), body.width() * 0.7)
    grad.setColorAt(0, c("#3A3A40"))
    grad.setColorAt(1, c("#1B1B1F"))
    p.setPen(QPen(c("#0A0A0C"), 1))
    p.setBrush(grad)
    p.drawEllipse(body)
    angle = math.radians(225 - sweep * value)
    centre = body.center()
    r = body.width() / 2
    pointer = c(theme.AMBER if not dim else theme.AMBER_DIM)
    p.setPen(QPen(pointer, max(2.0, r / 9), Qt.SolidLine, Qt.RoundCap))
    p.drawLine(QPointF(centre.x() + r * 0.35 * math.cos(angle), centre.y() - r * 0.35 * math.sin(angle)),
               QPointF(centre.x() + r * 0.85 * math.cos(angle), centre.y() - r * 0.85 * math.sin(angle)))


class DeviceSwitch(QWidget):
    """A small on/off switch with its two words, such as Frei / BPM."""
    toggled = Signal(bool)

    def __init__(self, off: str, on: str, parent=None):
        super().__init__(parent)
        self.off_text, self.on_text, self.is_on, self.locked = off, on, False, False
        self.setFixedHeight(28)
        self.setCursor(Qt.PointingHandCursor)
        self.setFont(theme.sans(12, bold=True))

    def sizeHint(self):
        fm = QFontMetrics(self.font())
        return QSize(fm.horizontalAdvance(self.off_text) + fm.horizontalAdvance(self.on_text) + 80, 28)

    def set_on(self, on: bool) -> None:
        self.is_on = on
        self.update()

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton and not self.locked:
            self.is_on = not self.is_on
            self.update()
            self.toggled.emit(self.is_on)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        fm = QFontMetrics(self.font())
        p.setFont(self.font())
        left = fm.horizontalAdvance(self.off_text)
        p.setPen(c(theme.TEXT_DIM if self.is_on else theme.TEXT))
        p.drawText(QRectF(0, 0, left, self.height()), Qt.AlignVCenter | Qt.AlignLeft, self.off_text)
        track = QRectF(left + 10, 6, 40, 16)
        p.setPen(Qt.NoPen)
        p.setBrush(c(theme.SWITCH_ON if self.is_on else theme.SWITCH_OFF))
        p.drawRoundedRect(track, 8, 8)
        thumb_x = track.right() - 14 if self.is_on else track.left() + 2
        p.setBrush(c(theme.SWITCH_THUMB))
        p.drawEllipse(QRectF(thumb_x, track.top() + 2, 12, 12))
        p.setPen(c(theme.AMBER if self.is_on else theme.TEXT_DIM))
        p.drawText(QRectF(track.right() + 10, 0, 200, self.height()), Qt.AlignVCenter | Qt.AlignLeft, self.on_text)


class Footswitch(QAbstractButton):
    """The round metal switch of a pedal."""

    def __init__(self, diameter: int = 40, parent=None):
        super().__init__(parent)
        self.setCheckable(True)
        self.setFixedSize(diameter + 8, diameter + 8)
        self.setCursor(Qt.PointingHandCursor)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(4, 4, -4, -4)
        p.setPen(Qt.NoPen)
        p.setBrush(c("#000000", 0.5))
        p.drawEllipse(r.translated(0, 2))
        on = self.isChecked()
        grad = QRadialGradient(r.center() - QPointF(0, r.height() * 0.2), r.width() * 0.7)
        grad.setColorAt(0, c("#F2F2F4" if on else "#8A8A90"))
        grad.setColorAt(1, c("#A9A9AF" if on else "#4A4A50"))
        p.setPen(QPen(c("#0C0C0E"), 1))
        p.setBrush(grad)
        p.drawEllipse(r)
        if self.hasFocus():
            p.setPen(QPen(c(theme.AMBER), 1.5))
            p.setBrush(Qt.NoBrush)
            p.drawEllipse(r.adjusted(-3, -3, 3, 3))


class Pedal(QWidget):
    """One place of the chain. Pedals share one dark body; the nameplate carries the place's color."""
    selected = Signal(int)
    toggled = Signal(int, bool)

    def __init__(self, index: int, place: str, parent=None):
        super().__init__(parent)
        self.index, self.place = index, place
        self.color = theme.place_color(place)
        self.is_amp = place == "amp"
        self.title = ""
        self.model_name = ""
        self.group = ""
        self.values: list[float] = []
        self.is_on = False
        self.is_current = False
        self.setMinimumHeight(250)
        self.setMaximumHeight(250)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setCursor(Qt.PointingHandCursor)
        self.foot = None
        if not self.is_amp:
            self.foot = Footswitch(40, self)
            self.foot.clicked.connect(lambda: self.toggled.emit(self.index, self.foot.isChecked()))

    def set_state(self, title: str, model_name: str, group: str, values: list[float], is_on: bool, is_current: bool):
        self.title, self.model_name, self.group = title, model_name, group
        self.values, self.is_on, self.is_current = values, is_on, is_current
        if self.foot:
            self.foot.setChecked(is_on)
        self.update()

    def resizeEvent(self, _):
        if self.foot:
            self.foot.move((self.width() - self.foot.width()) // 2, self.height() - self.foot.height() - 16)

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.selected.emit(self.index)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(4, 4, -4, -4)
        p.setPen(QPen(c("#060607"), 1))
        p.setBrush(vgradient(r, theme.PANEL_TOP, "#141417"))
        p.drawRoundedRect(r, 14, 14)
        p.setPen(QPen(c("#FFFFFF", 0.06), 1))
        p.drawLine(QPointF(r.left() + 12, r.top() + 1), QPointF(r.right() - 12, r.top() + 1))
        if self.is_current:
            p.setPen(QPen(c(theme.AMBER), 2.2))
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(r.adjusted(-1, -1, 1, 1), 15, 15)
        if self.is_amp:
            self._paint_amp(p, r)
        else:
            self._paint_pedal(p, r)

    def _paint_pedal(self, p: QPainter, r: QRectF) -> None:
        plate = QRectF(r.left() + 8, r.top() + 8, r.width() - 16, 26)
        color = QColor(self.color)
        if not self.is_on:
            color.setAlphaF(0.55)
        p.setPen(Qt.NoPen)
        p.setBrush(color)
        p.drawRoundedRect(plate, 5, 5)
        size = 11
        while size > 7:
            font = theme.sans(size, bold=True, spacing=0.12)
            if QFontMetrics(font).horizontalAdvance(self.title.upper()) <= plate.width() - 10:
                break
            size -= 1
        p.setFont(font)
        p.setPen(c("#111111"))
        p.drawText(plate, Qt.AlignCenter, self.title.upper())
        p.setFont(theme.sans(14, bold=self.is_on))
        p.setPen(c(theme.TEXT if self.is_on else theme.ENGRAVING))
        p.drawText(QRectF(r.left() + 6, r.top() + 44, r.width() - 12, 24), Qt.AlignCenter,
                   QFontMetrics(p.font()).elidedText(self.model_name, Qt.ElideRight, int(r.width() - 16)))
        self._mini_knobs(p, QRectF(r.left() + 6, r.top() + 84, r.width() - 12, 28), 14, dim=not self.is_on)
        lamp = QPointF(r.center().x(), r.top() + 128)
        p.setPen(Qt.NoPen)
        if self.is_on:
            glow = QRadialGradient(lamp, 9)
            glow.setColorAt(0, c(self.color.name(), 0.6))
            glow.setColorAt(1, c(self.color.name(), 0))
            p.setBrush(glow)
            p.drawEllipse(lamp, 9, 9)
        p.setBrush(self.color if self.is_on else c("#1B1B1F"))
        p.drawEllipse(lamp, 3.5, 3.5)

    def _mini_knobs(self, p: QPainter, area: QRectF, size: float, dim: bool) -> None:
        values = self.values[:5]
        if not values:
            return
        gap = 7
        total = len(values) * size + (len(values) - 1) * gap
        x = area.center().x() - total / 2
        for value in values:
            box = QRectF(x, area.center().y() - size / 2, size, size)
            p.setPen(Qt.NoPen)
            p.setBrush(c("#0A0A0C"))
            p.drawEllipse(box.adjusted(-1.5, -1.5, 1.5, 1.5))
            grad = QRadialGradient(box.center() - QPointF(0, size * 0.15), size * 0.7)
            grad.setColorAt(0, c("#3A3A40"))
            grad.setColorAt(1, c("#1B1B1F"))
            p.setBrush(grad)
            p.drawEllipse(box)
            angle = math.radians(225 - 270 * value)
            pointer = c(self.color.name(), 0.4 if dim else 1.0)
            p.setPen(QPen(pointer, 2, Qt.SolidLine, Qt.RoundCap))
            cx, cy = box.center().x(), box.center().y()
            p.drawLine(QPointF(cx + size * 0.12 * math.cos(angle), cy - size * 0.12 * math.sin(angle)),
                       QPointF(cx + size * 0.42 * math.cos(angle), cy - size * 0.42 * math.sin(angle)))
            x += size + gap

    def _paint_amp(self, p: QPainter, r: QRectF) -> None:
        brass = QRectF(r.left() + 8, r.top() + 8, r.width() - 16, 58)
        grad = vgradient(brass, "#4A3A1C", "#2B2110")
        p.setPen(QPen(c("#0A0A0C"), 1))
        p.setBrush(grad)
        p.drawRoundedRect(brass, 6, 6)
        p.setPen(Qt.NoPen)
        p.setBrush(c(theme.AMBER_HOT if self.is_on else theme.LAMP_OFF))
        p.drawEllipse(QPointF(brass.left() + 14, brass.top() + 15), 4, 4)
        size = 18
        while True:
            font = theme.sans(size, bold=True, italic=True)
            if "Noto Serif" in QFontDatabase.families():
                font.setFamily("Noto Serif")
            if size <= 11 or QFontMetrics(font).horizontalAdvance(self.model_name) <= brass.width() - 90:
                break
            size -= 1
        p.setFont(font)
        p.setPen(c(theme.AMBER if self.is_on else theme.AMBER_DIM))
        p.drawText(QRectF(brass.left() + 26, brass.top() + 4, brass.width() - 80, 24), Qt.AlignLeft | Qt.AlignVCenter,
                   QFontMetrics(font).elidedText(self.model_name, Qt.ElideRight, int(brass.width() - 90)))
        p.setFont(theme.sans(10, bold=True, spacing=0.09))
        p.setPen(c(theme.AMBER_DIM))
        p.drawText(QRectF(brass.right() - 56, brass.top() + 4, 46, 24), Qt.AlignRight | Qt.AlignVCenter, "AMP")
        self._mini_knobs(p, QRectF(brass.left(), brass.top() + 30, brass.width(), 24), 15, dim=not self.is_on)
        grille = QRectF(r.left() + 12, r.top() + 78, r.width() - 24, r.height() - 100)
        p.setPen(QPen(c("#0A0A0C"), 1))
        p.setBrush(c("#16161A"))
        p.drawRoundedRect(grille, 5, 5)
        p.setPen(QPen(c("#FFFFFF", 0.04), 1))
        y = grille.top() + 5
        while y < grille.bottom() - 4:
            p.drawLine(QPointF(grille.left() + 4, y), QPointF(grille.right() - 4, y))
            y += 5
        p.setFont(theme.sans(10, bold=True, spacing=0.12))
        p.setPen(c(theme.ENGRAVING))
        p.drawText(grille.adjusted(0, 0, -10, -6), Qt.AlignRight | Qt.AlignBottom, self.group.upper())
