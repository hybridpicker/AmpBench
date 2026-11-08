"""The look of the editor: a knob, the pedals of the chain and a lamp."""
from __future__ import annotations

from PySide6.QtCore import QPointF, QRectF, Qt, Signal
from PySide6.QtGui import QColor, QFont, QPainter, QPen
from PySide6.QtWidgets import QSizePolicy, QWidget

from . import theme


class Lamp(QWidget):
    def __init__(self, color: str = theme.GOOD, parent=None):
        super().__init__(parent)
        self.color = QColor(color)
        self.lit = False
        self.setFixedSize(10, 10)

    def set_lit(self, lit: bool, color: str | None = None) -> None:
        self.lit = lit
        if color:
            self.color = QColor(color)
        self.update()

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setPen(Qt.NoPen)
        p.setBrush(self.color if self.lit else QColor(theme.LINE))
        p.drawEllipse(self.rect().adjusted(1, 1, -1, -1))


class Knob(QWidget):
    """A knob from 0 to 1, shown from 0 to 10. Drag up and down, wheel or arrow keys; double-click resets."""
    changed = Signal(float)
    gesture_started = Signal()
    gesture_ended = Signal()

    def __init__(self, label: str, color: QColor, start: float | None = None, parent=None):
        super().__init__(parent)
        self.label, self.color, self.start = label, color, start
        self.value = 0.0
        self._drag: tuple[float, float] | None = None
        self.setFixedSize(78, 104)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setCursor(Qt.SizeVerCursor)
        self.setToolTip(f"{label}: ziehen, Mausrad oder Pfeiltasten. Doppelklick setzt den Startwert.")

    def set_value(self, value: float) -> None:
        self.value = min(max(value, 0.0), 1.0)
        self.update()

    def _set_from_user(self, value: float) -> None:
        value = min(max(value, 0.0), 1.0)
        if value != self.value:
            self.value = value
            self.update()
            self.changed.emit(value)

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.setFocus()
            self._drag = (event.position().y(), self.value)
            self.gesture_started.emit()

    def mouseMoveEvent(self, event):
        if self._drag:
            fine = 0.25 if event.modifiers() & Qt.ShiftModifier else 1.0
            self._set_from_user(self._drag[1] + (self._drag[0] - event.position().y()) / 160 * fine)

    def mouseReleaseEvent(self, event):
        if self._drag:
            self._drag = None
            self.gesture_ended.emit()

    def mouseDoubleClickEvent(self, event):
        if self.start is not None:
            self.gesture_started.emit()
            self._set_from_user(self.start)
            self.gesture_ended.emit()

    def wheelEvent(self, event):
        steps = event.angleDelta().y() / 120
        self.gesture_started.emit()
        self._set_from_user(self.value + steps * (0.01 if event.modifiers() & Qt.ShiftModifier else 0.05))
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
        box = QRectF(9, 6, 60, 60)
        sweep = 270
        p.setPen(QPen(QColor(theme.LINE), 5, Qt.SolidLine, Qt.RoundCap))
        p.drawArc(box, int((225) * 16), int(-sweep * 16))
        p.setPen(QPen(self.color, 5, Qt.SolidLine, Qt.RoundCap))
        p.drawArc(box, int(225 * 16), int(-sweep * self.value * 16))
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(theme.PANEL_HI))
        p.drawEllipse(box.adjusted(10, 10, -10, -10))
        # pointer
        import math
        angle = math.radians(225 - sweep * self.value)
        centre = box.center()
        inner, outer = 9, 20
        p.setPen(QPen(QColor(theme.TEXT), 2.4, Qt.SolidLine, Qt.RoundCap))
        p.drawLine(QPointF(centre.x() + inner * math.cos(angle), centre.y() - inner * math.sin(angle)),
                   QPointF(centre.x() + outer * math.cos(angle), centre.y() - outer * math.sin(angle)))
        p.setPen(QColor(theme.TEXT))
        font = QFont(self.font())
        font.setPixelSize(13)
        font.setBold(True)
        p.setFont(font)
        p.drawText(QRectF(0, 68, 78, 16), Qt.AlignCenter, f"{self.value * 10:.1f}".replace(".", ","))
        font.setBold(False)
        font.setPixelSize(11)
        p.setFont(font)
        p.setPen(QColor(theme.MUTED))
        p.drawText(QRectF(0, 84, 78, 16), Qt.AlignCenter | Qt.TextSingleLine,
                   p.fontMetrics().elidedText(self.label, Qt.ElideRight, 76))
        if self.hasFocus():
            p.setPen(QPen(QColor(theme.ACCENT), 1.5))
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(self.rect().adjusted(1, 1, -1, -1), 8, 8)


class Pedal(QWidget):
    """One place of the chain: a colored tile with the model and a lamp that switches it on and off."""
    selected = Signal(int)
    toggled = Signal(int, bool)

    def __init__(self, index: int, place: str, parent=None):
        super().__init__(parent)
        self.index, self.place = index, place
        self.color = theme.place_color(place)
        self.model_name = ""
        self.is_on = False
        self.is_current = False
        self.setMinimumSize(96, 92)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setCursor(Qt.PointingHandCursor)

    def set_state(self, model_name: str, is_on: bool, is_current: bool) -> None:
        self.model_name, self.is_on, self.is_current = model_name, is_on, is_current
        self.update()

    def _lamp_rect(self) -> QRectF:
        return QRectF(self.width() - 26, 8, 18, 18)

    def mousePressEvent(self, event):
        if event.button() != Qt.LeftButton:
            return
        if self._lamp_rect().adjusted(-6, -6, 6, 6).contains(event.position()):
            self.toggled.emit(self.index, not self.is_on)
        else:
            self.selected.emit(self.index)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        rect = QRectF(self.rect()).adjusted(2, 2, -2, -2)
        body = QColor(theme.PANEL_HI if self.is_on else theme.PANEL)
        p.setPen(QPen(self.color if self.is_current else QColor(theme.LINE), 2 if self.is_current else 1))
        p.setBrush(body)
        p.drawRoundedRect(rect, 10, 10)
        stripe = QColor(self.color)
        if not self.is_on:
            stripe.setAlphaF(0.35)
        p.setPen(Qt.NoPen)
        p.setBrush(stripe)
        p.drawRoundedRect(QRectF(rect.left() + 10, rect.top() + 10, 26, 4), 2, 2)
        lamp = self._lamp_rect()
        p.setPen(QPen(QColor(theme.LINE), 1))
        p.setBrush(self.color if self.is_on else QColor(theme.BG))
        p.drawEllipse(lamp.adjusted(3, 3, -3, -3))
        font = QFont(self.font())
        font.setPixelSize(11)
        font.setBold(True)
        p.setFont(font)
        p.setPen(QColor(theme.MUTED))
        p.drawText(QRectF(rect.left() + 10, rect.top() + 20, rect.width() - 20, 16), Qt.AlignLeft | Qt.AlignVCenter,
                   catalog_short(self.place).upper())
        font.setPixelSize(13)
        p.setFont(font)
        p.setPen(QColor(theme.TEXT if self.is_on else theme.MUTED))
        text_rect = QRectF(rect.left() + 10, rect.top() + 38, rect.width() - 20, rect.height() - 44)
        p.drawText(text_rect, Qt.AlignLeft | Qt.AlignTop | Qt.TextWordWrap, self.model_name)


def catalog_short(place: str) -> str:
    from .. import catalog
    return catalog.PLACE_SHORT[place]
