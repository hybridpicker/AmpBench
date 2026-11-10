"""The waveform of the area Record: a ruler, the wave, loop, markers and the playhead."""
from __future__ import annotations

from PySide6.QtCore import QPointF, QRectF, Qt, Signal
from PySide6.QtGui import QPainter, QPen
from PySide6.QtWidgets import QWidget

from ..peaks import Waveform
from . import theme
from ..i18n import tr
from .theme import c

WAVE_BG = "#121214"
MARKER = "#E58CD9"
RULER_HEIGHT = 30


def time_label(seconds: float) -> str:
    return f"{int(seconds) // 60:02d}:{int(seconds) % 60:02d}"


class WaveView(QWidget):
    seek_requested = Signal(float)
    loop_changed = Signal(object)  # (a, b) or None
    marker_moved = Signal(str, float)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.waveform: Waveform | None = None
        self.duration = 0.0
        self.position = 0.0
        self.loop: tuple[float, float] | None = None
        self.loop_start_only: float | None = None
        self.markers: list[dict] = []
        self.live_columns: list[float] = []  # peak per column while recording
        self.live_seconds = 0.0
        self.message = tr("Choose a take.")
        self.setMinimumHeight(190)
        self.setMouseTracking(True)
        self._press: float | None = None
        self._drag: tuple[float, float] | None = None

    # Data

    def set_take(self, waveform: Waveform | None, duration: float, markers: list[dict]) -> None:
        self.waveform, self.duration, self.markers = waveform, duration, markers
        self.loop, self.loop_start_only = None, None
        self.position = 0.0
        self.update()

    def set_position(self, position: float) -> None:
        if abs(position - self.position) > 0.005:
            self.position = position
            self.update()

    def _x(self, seconds: float) -> float:
        return seconds / max(self.duration, 0.001) * self.width()

    def _time(self, x: float) -> float:
        return min(max(x / max(self.width(), 1) * self.duration, 0.0), self.duration)

    # Mouse: a click seeks, dragging chooses a loop

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton and self.duration > 0:
            self._press = event.position().x()
            self._drag = None

    def mouseMoveEvent(self, event):
        if self._press is not None and abs(event.position().x() - self._press) > 6:
            a, b = sorted((self._time(self._press), self._time(event.position().x())))
            self._drag = (a, b)
            self.update()

    def mouseReleaseEvent(self, event):
        if event.button() != Qt.LeftButton or self._press is None:
            return
        if self._drag and self._drag[1] - self._drag[0] >= 0.1:
            self.loop, self.loop_start_only = self._drag, None
            self.loop_changed.emit(self.loop)
        elif self.duration > 0:
            self.seek_requested.emit(self._time(event.position().x()))
        self._press, self._drag = None, None
        self.update()

    # Painting

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.fillRect(self.rect(), c(theme.DESK))
        self._ruler(p)
        area = QRectF(0, RULER_HEIGHT, self.width(), self.height() - RULER_HEIGHT)
        p.setPen(Qt.NoPen)
        p.setBrush(c(WAVE_BG))
        p.drawRoundedRect(area, 8, 8)
        if self.duration <= 0 or (self.waveform is None and not self.live_columns):
            p.setPen(c(theme.DESK_MUTED))
            p.setFont(theme.sans(14))
            p.drawText(area, Qt.AlignCenter, self.message)
            return
        mid = area.center().y()
        half = area.height() / 2 - 8
        p.setPen(QPen(c(theme.WAVE), 1.4))
        width = int(area.width())
        if self.waveform is not None:
            for x, (low, high) in enumerate(self.waveform.columns(width)):
                top, bottom = mid - min(high, 1.0) * half, mid - max(low, -1.0) * half
                p.drawLine(QPointF(x + 0.5, top), QPointF(x + 0.5, max(bottom, top + 1)))
        bin_width = max(area.width() * 0.05 / max(self.duration, 0.001), 1.0)
        for i, peak in enumerate(self.live_columns):
            x = i * area.width() * 0.05 / max(self.duration, 0.001)
            if x > area.width():
                break
            p.drawLine(QPointF(x + bin_width / 2, mid - peak * half), QPointF(x + bin_width / 2, mid + peak * half))
        loop = self._drag or self.loop
        if loop:
            region = QRectF(self._x(loop[0]), area.top(), self._x(loop[1]) - self._x(loop[0]), area.height())
            p.setPen(Qt.NoPen)
            p.setBrush(c("#F7C45C", 0.14))
            p.drawRect(region)
            p.setPen(QPen(c("#E6A23C"), 2))
            p.drawLine(region.topLeft(), region.bottomLeft())
            p.drawLine(region.topRight(), region.bottomRight())
            self._flag(p, region.left(), area.top(), "A", right=False)
            self._flag(p, region.right(), area.top(), "B", right=True)
        elif self.loop_start_only is not None:
            x = self._x(self.loop_start_only)
            p.setPen(QPen(c("#E6A23C"), 2))
            p.drawLine(QPointF(x, area.top()), QPointF(x, area.bottom()))
            self._flag(p, x, area.top(), "A", right=False)
        for marker in self.markers:
            x = self._x(float(marker.get("time", 0)))
            p.setPen(QPen(c(MARKER), 1.5))
            p.drawLine(QPointF(x, area.top()), QPointF(x, area.bottom()))
            label = marker.get("label", "")
            if label:
                p.setFont(theme.mono(11, True))
                p.setPen(c(MARKER))
                p.drawText(QPointF(x + 5, area.top() + 14), label)
        x = self._x(self.position)
        p.setPen(QPen(c("#FFFFFF"), 2))
        p.drawLine(QPointF(x, area.top()), QPointF(x, area.bottom()))

    def _flag(self, p: QPainter, x: float, y: float, text: str, right: bool) -> None:
        box = QRectF(x - 18 if right else x, y + 2, 18, 15)
        p.setPen(Qt.NoPen)
        p.setBrush(c("#E6A23C"))
        p.drawRoundedRect(box, 3, 3)
        p.setFont(theme.mono(10, True))
        p.setPen(c("#1A1206"))
        p.drawText(box, Qt.AlignCenter, text)

    def _ruler(self, p: QPainter) -> None:
        if self.duration <= 0:
            return
        p.setFont(theme.mono(11))
        seconds = max(self.duration, 1)
        step = 1
        for candidate in (1, 2, 5, 10, 15, 30, 60, 120, 300):
            step = candidate
            if self.width() / seconds * candidate >= 62:
                break
        t = 0
        while t <= self.duration:
            x = self._x(t)
            p.setPen(c("#FFFFFF", 0.35))
            p.drawLine(QPointF(x, RULER_HEIGHT - 8), QPointF(x, RULER_HEIGHT - 2))
            p.setPen(c(theme.DESK_TEXT, 0.8))
            p.drawText(QPointF(x + 4, RULER_HEIGHT - 12), time_label(t))
            t += step
