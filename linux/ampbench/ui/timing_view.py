"""The timing review in the area Record: the band below the waveform and the line below the transport.

The views of the Mac's WavePanel (TimingBandView, TimingBandCanvas, TimingLine): the band shows the two bars around the
playhead, each beat magnified to about ±60 ms, the click lines fixed with their beat numbers and the onsets as strokes
beside them; each bar tinted steady or unsteady, with its word, never red. ``timing_band.TimingBand`` says where
everything sits; this only draws it.
"""
from __future__ import annotations

from PySide6.QtCore import QPointF, QRectF, Qt, Signal
from PySide6.QtGui import QFontMetrics, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QHBoxLayout, QLabel, QToolTip, QVBoxLayout, QWidget

from .. import timing_review as review_mod
from ..beat_grid import BeatGrid
from ..i18n import tr
from ..timing_band import TimingBand, pair_at, pair_showing
from . import theme
from .theme import c
from .widgets import DevicePopup, Engraving, HardwareKey

WAVE_BG = "#121214"
LANE_TOP, LANE_HEIGHT = 14, 30
BAND_HEIGHT = 62
BAR_STEADY = (theme.WAVE, 0.07)
BAR_UNSTEADY = ("#F7C45C", 0.16)
BAR_UNSTEADY_TEXT = "#F7C45C"
BAND_LABEL = "#A3A3A8"


class TimingBandView(QWidget):
    """Two bars of the review around the playhead. A click on a bar sends the playhead to its start."""
    seek_requested = Signal(float)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(BAND_HEIGHT + 8)
        self.setMouseTracking(True)
        self.review: review_mod.TimingReview | None = None
        self.grid: BeatGrid | None = None
        self.last_bar = 1
        self.position = 0.0
        self.chosen: tuple[int, int] | None = None  # bars chosen while the playhead stands elsewhere
        self._band: TimingBand | None = None
        self._key = None

    def show_review(self, review, grid: BeatGrid | None, last_bar: int | None) -> None:
        self.review, self.grid, self.last_bar = review, grid, last_bar or (grid.first_bar if grid else 1)
        self.chosen, self._key = None, None
        self.update()

    def set_position(self, position: float) -> None:
        if abs(position - self.position) > 0.003:
            self.position = position
            self.chosen = None
            self.update()

    def show_bar(self, bar: int) -> None:
        if self.grid is not None:
            self.chosen = pair_showing(bar, self.grid, self.last_bar)
            self.update()

    @property
    def shown_bars(self) -> tuple[int, int] | None:
        if self.grid is None:
            return None
        return self.chosen or pair_at(self.position, self.grid, self.last_bar)

    def band(self) -> TimingBand | None:
        if self.review is None or self.grid is None:
            return None
        bars, width = self.shown_bars, float(self.width() - 2)
        key = (id(self.review), bars, width)
        if key != self._key:
            self._band, self._key = TimingBand(self.review, self.grid, bars, width), key
            self.setAccessibleDescription(self._band.spoken)
        return self._band

    # Pointing and clicking

    def _span_at(self, x: float):
        band = self.band()
        if band is None:
            return None
        return next((s for s in band.bar_spans if s.reviewed and s.left <= x - 1 < s.left + s.width), None)

    def mouseMoveEvent(self, event):
        span = self._span_at(event.position().x())
        if span is not None:
            QToolTip.showText(event.globalPosition().toPoint(), span.reviewed.text, self)
        else:
            QToolTip.hideText()

    def mousePressEvent(self, event):
        span = self._span_at(event.position().x())
        if span is not None and event.button() == Qt.LeftButton and self.grid is not None:
            self.seek_requested.emit(max(self.grid.time_of_bar(span.bar), 0.0))

    # Painting

    def paintEvent(self, _):
        band = self.band()
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.fillRect(self.rect(), c(theme.DESK))
        if band is None:
            return
        p.translate(1, 4)
        size_h = BAND_HEIGHT
        path = QPainterPath()
        path.addRoundedRect(QRectF(0, 0, band.width, size_h), 6, 6)
        p.fillPath(path, c(WAVE_BG))
        p.setClipPath(path)
        self._bars(p, band)
        self._click_lines(p, band)
        self._strokes(p, band)
        x = band.x(self.position)
        if x is not None:
            p.fillRect(QRectF(x - 0.75, LANE_TOP, 1.5, LANE_HEIGHT), c("#FFFFFF"))

    def _bars(self, p: QPainter, band: TimingBand) -> None:
        number_font, label_font = theme.mono(10, True), theme.mono(9, True)
        numbers, labels = QFontMetrics(number_font), QFontMetrics(label_font)
        for span in band.bar_spans:
            if span.steadiness:
                color, alpha = BAR_UNSTEADY if span.steadiness == review_mod.UNSTEADY else BAR_STEADY
                p.fillRect(QRectF(span.left, 0, span.width, LANE_TOP + LANE_HEIGHT), c(color, alpha))
            if span.left > 0:
                p.fillRect(QRectF(span.left, 0, 1, LANE_TOP + LANE_HEIGHT), c("#FFFFFF", 0.5))
            beats = [pt for pt in band.points if pt.bar == span.bar and pt.number is not None]
            p.setFont(number_font)
            p.setPen(c(BAND_LABEL))
            for point in beats:
                p.drawText(QRectF(point.x - 12, 0, 24, 12), Qt.AlignCenter, str(point.beat))
            if not beats:
                continue
            first = beats[0]
            half = numbers.horizontalAdvance(str(first.beat)) / 2
            text = tr("Bar {}", span.bar)
            width = labels.horizontalAdvance(text)
            p.setFont(label_font)
            # On fine grids the first cell is too narrow for the label before the beat number: it goes after it.
            if span.left + 4 + width <= first.x - half - 3:
                p.drawText(QPointF(span.left + 4, 10), text)
                label_end = first.x
            else:
                start = first.x + half + 5
                p.drawText(QPointF(start, 10), text)
                label_end = start + width
            if span.steadiness is None or len(beats) < 2:
                continue
            word = review_mod.steadiness_word(span.steadiness)
            low, high = max(first.x, label_end) + 8, beats[1].x - 8
            if labels.horizontalAdvance(word) <= high - low:
                p.setPen(c(BAR_UNSTEADY_TEXT if span.steadiness == review_mod.UNSTEADY else BAND_LABEL))
                p.drawText(QRectF(low, 0, high - low, 12), Qt.AlignCenter, word)

    def _click_lines(self, p: QPainter, band: TimingBand) -> None:
        """The click line of every grid point; the click plays only the beats, so the points between are fainter.
        Thin lines part the cells of a bar."""
        cell = band.cell_width
        for index, point in enumerate(band.points):
            if index and not (point.beat == 1 and point.step == 0):  # bar lines are drawn with the bars
                p.fillRect(QRectF(index * cell, LANE_TOP, 1, LANE_HEIGHT), c("#FFFFFF", 0.06))
            color = c("#FFFFFF", 0.5) if point.step == 0 else c("#FFFFFF", 0.18)
            p.fillRect(QRectF(point.x - 0.5, LANE_TOP, 1, LANE_HEIGHT), color)

    def _strokes(self, p: QPainter, band: TimingBand) -> None:
        cell = band.cell_width
        font = theme.mono(10, True)
        metrics = QFontMetrics(font)
        p.setFont(font)
        for stroke in band.strokes:
            color = c(theme.WAVE) if stroke.is_counted else c(theme.WAVE, 0.35)
            width = 2 if stroke.is_counted else 1.5
            p.fillRect(QRectF(stroke.x - width / 2, LANE_TOP + 3, width, LANE_HEIGHT - 6), color)
            if stroke.is_past_the_cell:
                # A small arrow points on, out of the cell, to where the onset really lies.
                side = 1 if stroke.offset > 0 else -1
                mid = LANE_TOP + LANE_HEIGHT / 2
                arrow = QPainterPath(QPointF(stroke.x - side * 6, mid - 4))
                arrow.lineTo(QPointF(stroke.x - side * 2, mid))
                arrow.lineTo(QPointF(stroke.x - side * 6, mid + 4))
                arrow.closeSubpath()
                p.fillPath(arrow, color)
            # On fine grids the cell may be too narrow for "+18 ms": then "+18", or no number (still read aloud).
            text = next((t for t in (stroke.label, stroke.short_label) if t and metrics.horizontalAdvance(t) + 4 <= cell),
                        None)
            if text is None:
                continue
            w = metrics.horizontalAdvance(text)
            left = stroke.point * cell
            x = min(max(stroke.x, left + w / 2 + 2), left + cell - w / 2 - 2)
            p.setPen(QPen(c(theme.WAVE)))
            p.drawText(QRectF(x - w / 2 - 1, LANE_TOP + LANE_HEIGHT + 2, w + 2, 14), Qt.AlignCenter, text)


class TimingLine(QWidget):
    """One line about the take's timing: placement and spread against the click, or why there is no review."""
    grid_chosen = Signal(int)
    fold_toggled = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setStyleSheet(f"background: {theme.DESK};")
        row = QHBoxLayout(self)
        row.setContentsMargins(22, 4, 22, 4)
        row.setSpacing(8)
        row.addWidget(Engraving(tr("Timing")))
        texts = QVBoxLayout()
        texts.setSpacing(0)
        self.text = QLabel("")
        self.text.setFont(theme.mono(12))
        self.hints = QLabel("")
        self.hints.setFont(theme.sans(11))
        self.hints.setStyleSheet(f"background: transparent; color: {theme.AMBER_DIM};")
        texts.addWidget(self.text)
        texts.addWidget(self.hints)
        row.addLayout(texts, 1)
        self.grid_popup = DevicePopup(tr("Grid"))
        self.grid_popup.setMinimumWidth(112)
        self.grid_popup.setFixedWidth(112)
        self.grid_popup.setToolTip(tr("The grid the notes are matched to. The click plays quarters; a piece keeps the "
                                      "grid chosen for one of its takes."))
        self.grid_popup.chosen.connect(lambda r: self.grid_chosen.emit(int(r)))
        row.addWidget(self.grid_popup)
        self.fold_key = HardwareKey(tr("Fold"))
        self.fold_key.clicked.connect(self.fold_toggled)
        row.addWidget(self.fold_key)

    def show_outcome(self, outcome, reviewing: bool, resolution: int, can_choose: bool, folded: bool) -> None:
        review = outcome.review if outcome else None
        if review is not None:
            text = tr("Placement {} ms · Spread {} ms · {} · {}", review_mod.signed(review.placement * 1000),
                      review_mod.number(review.spread * 1000, 1), review_mod.accuracy_text(review.accuracy),
                      review_mod.resolution_notes(review.resolution, review.counted))
        elif outcome is not None and outcome.reason:
            text = review_mod.reason_text(outcome.reason)
        else:
            text = tr("Reviewing the timing …") if reviewing else tr("The timing could not be reviewed.")
        self.text.setText(text)
        self.text.setFont(theme.mono(12, review is not None))
        self.text.setStyleSheet(f"background: transparent; color: {theme.AMBER if review else theme.TEXT_DIM};")
        hints = " ".join(review_mod.hint_text(h) for h in review.hints) if review and review.hints else ""
        self.hints.setText(hints)
        self.hints.setVisible(bool(hints))
        self.setAccessibleDescription(f"{text} {hints}".strip())
        self.grid_popup.setVisible(can_choose)
        self.grid_popup.set_options([(review_mod.resolution_name(r), r) for r in review_mod.RESOLUTIONS],
                                    review_mod.resolution_name(resolution))
        self.fold_key.setVisible(review is not None)
        self.fold_key.setText(tr("Unfold") if folded else tr("Fold"))
        self.fold_key.setToolTip(tr("Shows the timing band below the waveform") if folded else
                                 tr("Folds the timing band away, so the waveform has the room"))
