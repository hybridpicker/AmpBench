"""The library of the area Aufnahme: the takes table, the pieces, the statistics and the inspector."""
from __future__ import annotations

import math
from datetime import datetime, timedelta
from pathlib import Path

from PySide6.QtCore import QPointF, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QPainter, QPainterPath, QPen
from PySide6.QtWidgets import (QAbstractItemView, QComboBox, QFrame, QGridLayout, QHBoxLayout, QHeaderView, QLabel,
                               QLineEdit, QListWidget, QListWidgetItem, QMenu, QPlainTextEdit, QScrollArea, QSizePolicy,
                               QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget)

from .. import store as storemod
from . import theme
from .theme import c
from .widgets import HardwareKey, SegmentTabs

STAR = theme.STAR
MONTHS = ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sep.", "Okt.", "Nov.", "Dez."]


def clock(seconds: float, tenths: bool = False) -> str:
    seconds = max(seconds, 0.0)
    text = f"{int(seconds) // 60:02d}:{int(seconds) % 60:02d}"
    return text + (f",{int(seconds * 10) % 10}" if tenths else "")


def long_date(date: datetime) -> str:
    local = date.astimezone()
    return f"{local.day}. {MONTHS[local.month - 1]} {local.year}, {local.strftime('%H:%M:%S')}"


def caption(text: str) -> QLabel:
    label = QLabel(text.upper())
    label.setFont(theme.sans(11, bold=True, spacing=0.09))
    label.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
    return label


def minutes_text(minutes: float) -> str:
    if minutes < 1:
        return f"{round(minutes * 60)} Sek."
    hours, rest = divmod(round(minutes), 60)
    return f"{hours} Std. {rest} Min." if hours else f"{rest} Min."


def field_style() -> str:
    return (f"QComboBox {{ background: {theme.FIELD}; border: 1px solid {theme.FIELD_EDGE}; border-radius: 8px; "
            f"padding: 5px 10px; color: {theme.FIELD_TEXT}; }} QComboBox::drop-down {{ border: none; width: 24px; }} "
            f"QComboBox::down-arrow {{ image: url({theme.arrow_path()}); width: 16px; height: 16px; }} "
            f"QComboBox QAbstractItemView {{ background: #26262A; selection-background-color: {theme.AMBER_DIM}; "
            f"selection-color: #000; }}")


def combo() -> QComboBox:
    box = QComboBox()
    box.setStyleSheet(field_style())
    box.setFocusPolicy(Qt.NoFocus)
    return box


class Stars(QWidget):
    changed = Signal(int)

    def __init__(self, size: int = 18, parent=None):
        super().__init__(parent)
        self.rating, self.size = 0, size
        self.setFixedSize(size * 5 + 8, size + 4)
        self.setCursor(Qt.PointingHandCursor)

    def set_rating(self, rating: int) -> None:
        self.rating = rating
        self.update()

    def mousePressEvent(self, event):
        value = int(event.position().x() // (self.size + 2)) + 1
        self.rating = 0 if value == self.rating else min(value, 5)
        self.update()
        self.changed.emit(self.rating)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        for i in range(5):
            cx, cy = i * (self.size + 2) + self.size / 2 + 1, self.height() / 2
            path = QPainterPath()
            for k in range(10):
                radius = self.size / 2 if k % 2 == 0 else self.size / 4.2
                angle = -math.pi / 2 + k * math.pi / 5
                point = QPointF(cx + radius * math.cos(angle), cy + radius * math.sin(angle))
                path.moveTo(point) if k == 0 else path.lineTo(point)
            path.closeSubpath()
            p.setPen(Qt.NoPen)
            p.setBrush(c(STAR) if i < self.rating else c("#FFFFFF", 0.14))
            p.drawPath(path)


class Heart(QWidget):
    toggled = Signal(bool)

    def __init__(self, size: int = 20, parent=None):
        super().__init__(parent)
        self.on, self.size = False, size
        self.setFixedSize(size + 6, size + 6)
        self.setCursor(Qt.PointingHandCursor)

    def set_on(self, on: bool) -> None:
        self.on = on
        self.update()

    def mousePressEvent(self, event):
        self.on = not self.on
        self.update()
        self.toggled.emit(self.on)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        s = self.size
        x, y = 3, 4
        path = QPainterPath()
        path.moveTo(x + s / 2, y + s * 0.9)
        path.cubicTo(x - s * 0.2, y + s * 0.45, x + s * 0.15, y - s * 0.1, x + s / 2, y + s * 0.28)
        path.cubicTo(x + s * 0.85, y - s * 0.1, x + s * 1.2, y + s * 0.45, x + s / 2, y + s * 0.9)
        if self.on:
            p.setPen(Qt.NoPen)
            p.setBrush(c("#FF4D6A"))
        else:
            p.setPen(QPen(c(theme.DESK_MUTED), 1.5))
            p.setBrush(Qt.NoBrush)
        p.drawPath(path)


class TakesView(QWidget):
    """The takes: header with the piece for new recordings and the search, filters, and the table."""
    selection_changed = Signal(list)
    rate = Signal(str, int)
    favorite = Signal(str, bool)
    context = Signal(list, object)
    new_piece_requested = Signal()
    trash_requested = Signal()
    piece_for_new = Signal(object)

    COLUMNS = ["Name", "Datum", "Dauer", "Bewertung", "♥", "Stück"]

    def __init__(self, store, parent=None):
        super().__init__(parent)
        self.store = store
        self.sort_key, self.descending = "date", True
        self.rows: list[dict] = []
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)

        head = QHBoxLayout()
        head.setContentsMargins(16, 10, 16, 6)
        head.setSpacing(8)
        head.addWidget(caption("Neue Aufnahmen in"))
        self.piece_box = combo()
        self.piece_box.setMinimumWidth(150)
        self.piece_box.activated.connect(lambda i: self.piece_for_new.emit(self.piece_box.itemData(i)))
        head.addWidget(self.piece_box)
        plus = HardwareKey("+")
        plus.clicked.connect(self.new_piece_requested)
        head.addWidget(plus)
        head.addStretch(1)
        self.search = QLineEdit()
        self.search.setPlaceholderText("Suchen")
        self.search.setClearButtonEnabled(True)
        self.search.setFixedWidth(240)
        self.search.textChanged.connect(lambda _: self.refresh())
        head.addWidget(self.search)
        v.addLayout(head)

        filters = QHBoxLayout()
        filters.setContentsMargins(16, 0, 16, 8)
        filters.setSpacing(8)
        self.heart_filter = HardwareKey("♥")
        self.heart_filter.setCheckable(True)
        self.heart_filter.toggled.connect(lambda _: self.refresh())
        filters.addWidget(self.heart_filter)
        self.star_box, self.status_box, self.piece_filter, self.tag_box = combo(), combo(), combo(), combo()
        self.star_box.addItem("Alle Sterne", 0)
        for n in range(1, 6):
            self.star_box.addItem(f"ab {n} ★", n)
        for label, value in (("Alle Takes", "all"), ("Offen", "open"), ("Behalten", "kept")):
            self.status_box.addItem(label, value)
        for box in (self.star_box, self.status_box, self.piece_filter, self.tag_box):
            box.activated.connect(lambda _: self.refresh())
            filters.addWidget(box)
        filters.addStretch(1)
        trash = HardwareKey("Papierkorb")
        trash.clicked.connect(self.trash_requested)
        filters.addWidget(trash)
        v.addLayout(filters)

        self.table = QTableWidget(0, len(self.COLUMNS))
        self.table.setHorizontalHeaderLabels(self.COLUMNS)
        self.table.verticalHeader().hide()
        self.table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.ExtendedSelection)
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.setShowGrid(False)
        self.table.setAlternatingRowColors(True)
        self.table.setFocusPolicy(Qt.NoFocus)
        self.table.setContextMenuPolicy(Qt.CustomContextMenu)
        header = self.table.horizontalHeader()
        header.setSectionResizeMode(0, QHeaderView.Stretch)
        for column in range(1, len(self.COLUMNS)):
            header.setSectionResizeMode(column, QHeaderView.ResizeToContents)
        header.setSectionsClickable(True)
        header.setMinimumSectionSize(86)
        header.setDefaultAlignment(Qt.AlignLeft | Qt.AlignVCenter)
        header.sectionClicked.connect(self._header_clicked)
        self.table.setStyleSheet(
            f"QTableWidget {{ background: {theme.DESK}; border: none; alternate-background-color: {theme.DESK_ALT}; "
            f"selection-background-color: rgba(247,196,92,46); selection-color: {theme.DESK_TEXT}; }} "
            f"QHeaderView::section {{ background: {theme.DESK}; color: {theme.DESK_TEXT}; border: none; "
            f"border-bottom: 1px solid {theme.DESK_LINE}; padding: 8px; font-weight: bold; }} "
            f"QTableWidget::item:selected, QTableWidget::item:selected:!active {{ background: rgba(247,196,92,46); "
            f"color: {theme.DESK_TEXT}; }}")
        self.table.itemSelectionChanged.connect(lambda: self.selection_changed.emit(self.selected_ids))
        self.table.customContextMenuRequested.connect(self._context)
        v.addWidget(self.table, 1)
        self.footer = QLabel("")
        self.footer.setContentsMargins(16, 8, 16, 8)
        self.footer.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED}; "
                                  f"border-top: 1px solid {theme.DESK_LINE};")
        v.addWidget(self.footer)

    # MARK: State

    @property
    def selected_ids(self) -> list[str]:
        rows = sorted({i.row() for i in self.table.selectedItems()})
        return [self.rows[r]["id"] for r in rows if r < len(self.rows)]

    def select_ids(self, ids: list[str]) -> None:
        self.table.blockSignals(True)
        self.table.clearSelection()
        for row, take in enumerate(self.rows):
            if take["id"] in ids:
                self.table.selectRow(row) if len(ids) == 1 else self.table.item(row, 0).setSelected(True)
        self.table.blockSignals(False)

    def focus_search(self) -> None:
        self.search.setFocus()
        self.search.selectAll()

    def _header_clicked(self, column: int) -> None:
        key = ["name", "date", "duration", "rating", "favorite", "piece"][column]
        self.descending = not self.descending if key == self.sort_key else key in ("date", "duration", "rating", "favorite")
        self.sort_key = key
        self.refresh()

    def _context(self, pos) -> None:
        ids = self.selected_ids
        if not ids:
            row = self.table.rowAt(pos.y())
            if row < 0 or row >= len(self.rows):
                return
            ids = [self.rows[row]["id"]]
            self.select_ids(ids)
        self.context.emit(ids, self.table.viewport().mapToGlobal(pos))

    # MARK: Content

    def refresh(self, keep: list[str] | None = None) -> None:
        keep = keep if keep is not None else self.selected_ids
        document = self.store.document
        pieces = {p["id"]: p["name"] for p in document["pieces"]}
        self._fill_boxes(pieces)
        piece_filter = self.piece_filter.currentData()
        everything = document["recordings"]
        rows = storemod.query(
            everything, text=self.search.text(), min_rating=self.star_box.currentData() or 0,
            favorites=self.heart_filter.isChecked(), status=self.status_box.currentData() or "all",
            piece_id=False if piece_filter == "all" else None if piece_filter == "none" else piece_filter,
            tag=self.tag_box.currentData(), piece_names=pieces)
        keys = {"name": lambda t: t["fileName"].casefold(), "date": lambda t: t.get("createdAt", ""),
                "duration": lambda t: float(t.get("duration", 0)), "rating": lambda t: int(t.get("rating", 0)),
                "favorite": lambda t: bool(t.get("favorite")), "piece": lambda t: pieces.get(t.get("pieceID"), "").casefold()}
        indexed = sorted(enumerate(rows), key=lambda p: (keys[self.sort_key](p[1]), p[0]), reverse=self.descending)
        self.rows = [t for _, t in indexed]
        self.table.blockSignals(True)
        self.table.setRowCount(len(self.rows))
        for row, take in enumerate(self.rows):
            self._fill_row(row, take, pieces)
            self.table.setRowHeight(row, 38)
        self.table.blockSignals(False)
        self.select_ids(keep)
        open_count = sum(t.get("status") == "open" for t in everything)
        month = storemod.practice_seconds(self.store, since=datetime.now().astimezone() - timedelta(days=30)) / 60
        word = "Aufnahme" if len(everything) == 1 else "Aufnahmen"
        self.footer.setText(f"{len(everything)} {word} · {open_count} offen · {minutes_text(month)} in 30 Tagen"
                            + (f"   ({len(self.rows)} gezeigt)" if len(self.rows) != len(everything) else ""))

    def _fill_boxes(self, pieces: dict) -> None:
        def reset(box, items, current):
            box.blockSignals(True)
            box.clear()
            for label, value in items:
                box.addItem(label, value)
            index = box.findData(current)
            box.setCurrentIndex(max(index, 0))
            box.blockSignals(False)
        sorted_pieces = sorted(self.store.document["pieces"], key=lambda p: p["name"].casefold())
        reset(self.piece_filter, [("Alle Stücke", "all"), ("Ohne Stück", "none")] + [(p["name"], p["id"]) for p in sorted_pieces],
              self.piece_filter.currentData() or "all")
        reset(self.tag_box, [("Alle Tags", None)] + [(t, t) for t in storemod.all_tags(self.store.document["recordings"])],
              self.tag_box.currentData())
        current = self.piece_box.currentData() if hasattr(self, "_new_piece") is False else self._new_piece
        reset(self.piece_box, [("Kein Stück", None)] + [(p["name"], p["id"]) for p in sorted_pieces],
              getattr(self, "_new_piece", None))

    def set_piece_for_new(self, piece_id: str | None) -> None:
        self._new_piece = piece_id
        index = self.piece_box.findData(piece_id)
        self.piece_box.blockSignals(True)
        self.piece_box.setCurrentIndex(max(index, 0))
        self.piece_box.blockSignals(False)

    def _fill_row(self, row: int, take: dict, pieces: dict) -> None:
        stem = Path(take["fileName"]).stem
        open_take = take.get("status") == "open"
        health = take.get("health", "ok")
        suffix = "   · Offen" if open_take else ""
        if health == "missing":
            suffix += "   · Fehlt"
        elif health == "damaged":
            suffix += "   · Beschädigt"
        date = storemod.parse_iso(take.get("createdAt")).astimezone()
        cells = [stem + suffix, date.strftime("%d.%m.%y, %H:%M"), clock(float(take.get("duration", 0)))]
        for column, text in enumerate(cells):
            item = QTableWidgetItem(text)
            if column:
                item.setFont(theme.mono(13))
            if open_take and column == 0:
                item.setForeground(c(theme.AMBER))
            self.table.setItem(row, column, item)
        stars = Stars(15)
        stars.set_rating(int(take.get("rating", 0)))
        stars.changed.connect(lambda value, i=take["id"]: self.rate.emit(i, value))
        self.table.setCellWidget(row, 3, _centered(stars))
        heart = Heart(17)
        heart.set_on(bool(take.get("favorite")))
        heart.toggled.connect(lambda on, i=take["id"]: self.favorite.emit(i, on))
        self.table.setCellWidget(row, 4, _centered(heart))
        self.table.setItem(row, 5, QTableWidgetItem(pieces.get(take.get("pieceID"), "")))
        self.table.item(row, 0).setData(Qt.UserRole, take["id"])


def _centered(widget: QWidget) -> QWidget:
    holder = QWidget()
    holder.setStyleSheet("background: transparent;")
    layout = QHBoxLayout(holder)
    layout.setContentsMargins(4, 0, 4, 0)
    layout.addWidget(widget, 0, Qt.AlignCenter)
    return holder


class Inspector(QWidget):
    """Details, edits and markers of the take in focus."""
    changed = Signal(str, dict)  # take id, fields to set
    rename_requested = Signal(str)
    reveal_requested = Signal(str)
    new_piece_requested = Signal(str)
    best_take = Signal(str)
    send_to_amp = Signal(str)
    open_in_editor = Signal(str)
    trim_start_here = Signal(str)
    trim_end_here = Signal(str)
    export_requested = Signal(str, str)
    marker_selected = Signal(float)
    marker_deleted = Signal(str, str)
    marker_renamed = Signal(str, str, str)

    def __init__(self, store, parent=None):
        super().__init__(parent)
        self.store = store
        self.take_id: str | None = None
        self.setMinimumWidth(360)
        self.setStyleSheet(f"Inspector {{ border-left: 1px solid {theme.DESK_LINE}; }}")
        v = QVBoxLayout(self)
        v.setContentsMargins(16, 10, 16, 10)
        v.setSpacing(10)
        self.tabs = SegmentTabs(["Details", "Bearbeiten", "Marker"])
        self.tabs.changed.connect(lambda i: self.pages.setCurrentIndex(i) if hasattr(self, "pages") else None)
        v.addWidget(self.tabs, 0, Qt.AlignLeft)
        from PySide6.QtWidgets import QStackedWidget
        self.pages = QStackedWidget()
        self.pages.addWidget(self._details())
        self.pages.addWidget(self._edit())
        self.pages.addWidget(self._markers())
        v.addWidget(self.pages, 1)
        self.empty = QLabel("Wähle eine Aufnahme.")
        self.empty.setAlignment(Qt.AlignCenter)
        self.empty.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
        v.addWidget(self.empty, 1)
        self._loading = False
        self.show_take(None)

    # MARK: Pages

    def _scroll(self, inner: QWidget) -> QScrollArea:
        area = QScrollArea()
        area.setWidgetResizable(True)
        area.setFrameShape(QFrame.NoFrame)
        area.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        area.setWidget(inner)
        return area

    def _details(self) -> QWidget:
        inner = QWidget()
        v = QVBoxLayout(inner)
        v.setContentsMargins(0, 0, 8, 0)
        v.setSpacing(6)
        v.addWidget(caption("Titel, auch der Dateiname"))
        self.title = QLineEdit()
        self.title.editingFinished.connect(self._title_done)
        v.addWidget(self.title)
        row = QHBoxLayout()
        self.stars = Stars(24)
        self.stars.changed.connect(lambda n: self._emit({"rating": n}))
        self.heart = Heart(24)
        self.heart.toggled.connect(lambda on: self._emit({"favorite": on}))
        row.addWidget(self.stars)
        row.addStretch(1)
        row.addWidget(self.heart)
        v.addLayout(row)
        v.addWidget(caption("Stück"))
        piece_row = QHBoxLayout()
        self.piece_box = combo()
        self.piece_box.activated.connect(self._piece_chosen)
        plus = HardwareKey("+")
        plus.clicked.connect(lambda: self.take_id and self.new_piece_requested.emit(self.take_id))
        piece_row.addWidget(self.piece_box, 1)
        piece_row.addWidget(plus)
        v.addLayout(piece_row)
        self.best_key = HardwareKey("♛  Als besten Take markieren")
        self.best_key.clicked.connect(lambda: self.take_id and self.best_take.emit(self.take_id))
        v.addWidget(self.best_key, 0, Qt.AlignLeft)
        v.addWidget(caption("Tags, durch Kommas getrennt"))
        self.tags = QLineEdit()
        self.tags.editingFinished.connect(lambda: self._emit({"tags": storemod.parse_tags(self.tags.text())}))
        v.addWidget(self.tags)
        v.addWidget(caption("Notiz"))
        self.note = QPlainTextEdit()
        self.note.setFixedHeight(90)
        self.note.setStyleSheet(f"QPlainTextEdit {{ background: {theme.FIELD}; border: 1px solid {theme.FIELD_EDGE}; "
                                f"border-radius: 8px; padding: 6px; color: {theme.FIELD_TEXT}; }}")
        self.note.textChanged.connect(self._note_changed)
        v.addWidget(self.note)
        self.sound_box = QFrame()
        sv = QVBoxLayout(self.sound_box)
        sv.setContentsMargins(0, 6, 0, 0)
        sv.addWidget(caption("Sound"))
        self.sound_label = QLabel("")
        self.sound_label.setWordWrap(True)
        self.sound_label.setStyleSheet("background: transparent;")
        sv.addWidget(self.sound_label)
        keys = QHBoxLayout()
        self.amp_key = HardwareKey("Auf den Amp")
        self.amp_key.clicked.connect(lambda: self.take_id and self.send_to_amp.emit(self.take_id))
        self.editor_key = HardwareKey("Im Editor öffnen")
        self.editor_key.clicked.connect(lambda: self.take_id and self.open_in_editor.emit(self.take_id))
        keys.addWidget(self.amp_key)
        keys.addWidget(self.editor_key)
        keys.addStretch(1)
        sv.addLayout(keys)
        self.sound_missing = QLabel("Die Einstellungen dieses Sounds fehlen im Ordner .presets.")
        self.sound_missing.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
        sv.addWidget(self.sound_missing)
        v.addWidget(self.sound_box)
        line = QFrame()
        line.setFixedHeight(1)
        line.setStyleSheet(f"background: {theme.DESK_LINE};")
        v.addWidget(line)
        self.facts = QGridLayout()
        self.facts.setHorizontalSpacing(14)
        self.facts.setVerticalSpacing(4)
        self.fact_values: dict[str, QLabel] = {}
        for index, name in enumerate(["Datum", "Dauer", "Quelle", "Gerät", "Datei", "Spitze"]):
            key = QLabel(name)
            key.setFont(theme.sans(13, bold=True))
            key.setStyleSheet("background: transparent;")
            value = QLabel("")
            value.setFont(theme.sans(13))
            value.setStyleSheet("background: transparent;")
            value.setWordWrap(True)
            self.facts.addWidget(key, index, 0, Qt.AlignTop)
            self.facts.addWidget(value, index, 1)
            self.fact_values[name] = value
        v.addLayout(self.facts)
        keys = QHBoxLayout()
        reveal = HardwareKey("Im Dateimanager zeigen", keycap="⇧Strg+R")
        reveal.clicked.connect(lambda: self.take_id and self.reveal_requested.emit(self.take_id))
        rename = HardwareKey("Umbenennen …", keycap="Strg+E")
        rename.clicked.connect(lambda: self.take_id and self.rename_requested.emit(self.take_id))
        keys.addWidget(reveal)
        keys.addWidget(rename)
        keys.addStretch(1)
        v.addLayout(keys)
        v.addStretch(1)
        return self._scroll(inner)

    def _edit(self) -> QWidget:
        inner = QWidget()
        v = QVBoxLayout(inner)
        v.setContentsMargins(0, 0, 8, 0)
        v.setSpacing(8)
        info = QLabel("Das Original bleibt immer unverändert. Bearbeitungen wirken beim Anhören, und erst der Export "
                      "schreibt eine neue Datei.")
        info.setWordWrap(True)
        info.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
        v.addWidget(info)
        v.addWidget(caption("Zuschnitt"))
        self.trim_label = QLabel("")
        self.trim_label.setFont(theme.mono(13))
        self.trim_label.setStyleSheet("background: transparent;")
        v.addWidget(self.trim_label)
        row = QHBoxLayout()
        start = HardwareKey("Anfang = Abspielposition")
        start.clicked.connect(lambda: self.take_id and self.trim_start_here.emit(self.take_id))
        end = HardwareKey("Ende = Abspielposition")
        end.clicked.connect(lambda: self.take_id and self.trim_end_here.emit(self.take_id))
        row.addWidget(start)
        row.addWidget(end)
        row.addStretch(1)
        v.addLayout(row)
        v.addWidget(caption("Pegel"))
        gain_row = QHBoxLayout()
        from .widgets import DeviceSlider
        self.gain_slider = DeviceSlider(-12, 12, 0.5)
        self.gain_slider.changed.connect(self._gain_changed)
        self.gain_label = QLabel("0 dB")
        self.gain_label.setFont(theme.mono(13))
        self.gain_label.setFixedWidth(64)
        self.gain_label.setStyleSheet("background: transparent;")
        gain_row.addWidget(self.gain_slider, 1)
        gain_row.addWidget(self.gain_label)
        v.addLayout(gain_row)
        self.auto_key = HardwareKey("Automatisch anheben")
        self.auto_key.setCheckable(True)
        self.auto_key.toggled.connect(lambda on: self._emit_edit({"autoLevelEnabled": on}))
        v.addWidget(self.auto_key, 0, Qt.AlignLeft)
        self.auto_label = QLabel("")
        self.auto_label.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
        v.addWidget(self.auto_label)
        reset = HardwareKey("Bearbeitungen zurücksetzen")
        reset.clicked.connect(lambda: self.take_id and self._reset_edits())
        v.addWidget(reset, 0, Qt.AlignLeft)
        v.addWidget(caption("Export"))
        row = QHBoxLayout()
        wav = HardwareKey("WAV, 24 Bit …")
        wav.clicked.connect(lambda: self.take_id and self.export_requested.emit(self.take_id, "wav"))
        aac = HardwareKey("AAC, 192 kbit/s …")
        aac.clicked.connect(lambda: self.take_id and self.export_requested.emit(self.take_id, "aac"))
        row.addWidget(wav)
        row.addWidget(aac)
        row.addStretch(1)
        v.addLayout(row)
        v.addStretch(1)
        return self._scroll(inner)

    def _markers(self) -> QWidget:
        inner = QWidget()
        v = QVBoxLayout(inner)
        v.setContentsMargins(0, 0, 8, 0)
        self.marker_list = QListWidget()
        self.marker_list.setStyleSheet("QListWidget { background: transparent; border: none; } "
                                       "QListWidget::item { padding: 8px; }")
        self.marker_list.itemClicked.connect(lambda item: self.marker_selected.emit(item.data(Qt.UserRole + 1)))
        self.marker_list.setContextMenuPolicy(Qt.CustomContextMenu)
        self.marker_list.customContextMenuRequested.connect(self._marker_menu)
        v.addWidget(self.marker_list, 1)
        self.marker_hint = QLabel("Noch keine Marker. Taste M setzt einen, auch während der Aufnahme.")
        self.marker_hint.setWordWrap(True)
        self.marker_hint.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
        v.addWidget(self.marker_hint)
        return inner

    # MARK: Showing and changing

    def show_take(self, take: dict | None, pieces: list[dict] | None = None, sound: dict | None = None,
                  snapshot_exists: bool = False, is_best: bool = False) -> None:
        self.take_id = take["id"] if take else None
        has = take is not None
        self.pages.setVisible(has)
        self.tabs.setVisible(has)
        self.empty.setVisible(not has)
        if not has:
            return
        self._loading = True
        try:
            self.title.setText(Path(take["fileName"]).stem)
            self.stars.set_rating(int(take.get("rating", 0)))
            self.heart.set_on(bool(take.get("favorite")))
            self.piece_box.clear()
            self.piece_box.addItem("Kein Stück", None)
            for piece in sorted(pieces or [], key=lambda p: p["name"].casefold()):
                self.piece_box.addItem(piece["name"], piece["id"])
            self.piece_box.setCurrentIndex(max(self.piece_box.findData(take.get("pieceID")), 0))
            self.best_key.setVisible(bool(take.get("pieceID")))
            self.best_key.set_style("on" if is_best else "normal")
            self.best_key.setText("♛  Bester Take" if is_best else "♛  Als besten Take markieren")
            if not self.tags.hasFocus():
                self.tags.setText(", ".join(take.get("tags", [])))
            if not self.note.hasFocus() and self.note.toPlainText() != take.get("note", ""):
                self.note.setPlainText(take.get("note", ""))
            self._show_sound(sound, snapshot_exists)
            date = storemod.parse_iso(take.get("createdAt"))
            source = take.get("source") or {}
            channels = {1: "Mono", 2: "Stereo"}.get(int(take.get("channels", 0)), f"{take.get('channels', 0)} Kanäle")
            self.fact_values["Datum"].setText(long_date(date))
            self.fact_values["Dauer"].setText(clock(float(take.get("duration", 0)), True))
            self.fact_values["Quelle"].setText(
                f"{source['bits']} Bit · {float(source['sampleRate']) / 1000:g} kHz · "
                f"{ {1: 'Mono', 2: 'Stereo'}.get(int(source.get('channels', 0)), str(source.get('channels')) + ' Kanäle') }"
                if source else "unbekannt")
            self.fact_values["Gerät"].setText(source.get("deviceName", "unbekannt") if source else "unbekannt")
            self.fact_values["Datei"].setText(f"WAV {take.get('fileBits', 24)} Bit · "
                                              f"{float(take.get('sampleRate', 0)) / 1000:g} kHz · {channels}")
            peak = take.get("peakDB")
            self.fact_values["Spitze"].setText(f"{peak:.1f} dBFS".replace(".", ",") if peak is not None else "unbekannt")
            edit = take.get("edit") or {}
            end = edit.get("trimEnd")
            self.trim_label.setText(f"{clock(float(edit.get('trimStart', 0)), True)} – "
                                    f"{clock(float(end), True) if end else clock(float(take.get('duration', 0)), True)}")
            self.gain_slider.set_value(float(edit.get("gainDB", 0)))
            self.gain_label.setText(f"{float(edit.get('gainDB', 0)):+.1f} dB".replace(".", ","))
            self.auto_key.setChecked(bool(edit.get("autoLevelEnabled")))
            self.auto_label.setText(f"Automatisch anheben: {float(edit.get('autoLevelDB', 0)):+.1f} dB".replace(".", ",")
                                    if edit.get("autoLevelEnabled") else "")
            self.marker_list.clear()
            for marker in sorted(take.get("markers", []), key=lambda m: float(m.get("time", 0))):
                item = QListWidgetItem(f"{clock(float(marker['time']), True)}   {marker.get('label', '')}")
                item.setData(Qt.UserRole, marker["id"])
                item.setData(Qt.UserRole + 1, float(marker["time"]))
                self.marker_list.addItem(item)
            self.marker_hint.setVisible(not take.get("markers"))
        finally:
            self._loading = False

    def _show_sound(self, sound: dict | None, snapshot_exists: bool) -> None:
        self.sound_box.setVisible(sound is not None)
        if sound is None:
            return
        if sound.get("listened") is not None:
            # Read from what the device reported (the REACTOR), not a preset: nothing to send or open.
            values = "\n".join(f"{v['label']}: {v['value']}" for v in sound["listened"]) \
                or "Seit dem letzten Platzwechsel wurde nichts gedreht; der Inhalt ist unbekannt."
            self.sound_label.setText(f"{sound.get('name') or sound.get('device') or 'Gerät'} · mitgelesen\n{values}")
            self.amp_key.setVisible(False)
            self.editor_key.setVisible(False)
            self.sound_missing.setVisible(False)
            return
        place = f"Platz {sound['slot']}" if sound.get("slot") else "vom Mac oder vorübergehend gespielt"
        device = f" · {sound['device']}" if sound.get("device") else ""
        self.sound_label.setText(f"{sound.get('name') or 'Ohne Namen'}, {place}{device}")
        self.amp_key.setVisible(snapshot_exists)
        self.editor_key.setVisible(snapshot_exists)
        self.sound_missing.setVisible(not snapshot_exists)

    def _emit(self, fields: dict) -> None:
        if self.take_id and not self._loading:
            self.changed.emit(self.take_id, fields)

    def _emit_edit(self, fields: dict) -> None:
        if self.take_id and not self._loading:
            take = self.store.recording(self.take_id) or {}
            edit = dict(take.get("edit") or {})
            edit.update(fields)
            self.changed.emit(self.take_id, {"edit": edit})

    def _gain_changed(self, value: float) -> None:
        self.gain_label.setText(f"{value:+.1f} dB".replace(".", ","))
        self._emit_edit({"gainDB": value})

    def _reset_edits(self) -> None:
        take = self.store.recording(self.take_id) or {}
        edit = take.get("edit") or {}
        self.changed.emit(self.take_id, {"edit": {k: v for k, v in edit.items() if k in ("autoLevelEnabled", "autoLevelDB")}})

    def _title_done(self) -> None:
        if self.take_id and not self._loading:
            take = self.store.recording(self.take_id)
            if take and self.title.text().strip() != Path(take["fileName"]).stem:
                self.changed.emit(self.take_id, {"__rename__": self.title.text()})

    def _piece_chosen(self, index: int) -> None:
        piece_id = self.piece_box.itemData(index)
        self._emit({"pieceID": piece_id})

    def _note_changed(self) -> None:
        if self.take_id and not self._loading:
            self.changed.emit(self.take_id, {"note": self.note.toPlainText()})

    def _marker_menu(self, pos) -> None:
        item = self.marker_list.itemAt(pos)
        if item is None or not self.take_id:
            return
        menu = QMenu(self)
        menu.addAction("Umbenennen …", lambda: self.marker_renamed.emit(self.take_id, item.data(Qt.UserRole), ""))
        menu.addAction("Löschen", lambda: self.marker_deleted.emit(self.take_id, item.data(Qt.UserRole)))
        menu.exec(self.marker_list.mapToGlobal(pos))


class PiecesView(QWidget):
    """Pieces: songs and exercises with their takes, practice time and what it takes to play them."""
    created = Signal(str)
    changed = Signal(str, dict)
    deleted = Signal(str)
    chosen_for_new = Signal(object)
    show_takes = Signal(str)
    listen_to_best = Signal(str)
    play_sound = Signal(object)

    def __init__(self, store, parent=None):
        super().__init__(parent)
        self.store = store
        self.presets_provider = lambda: []
        self.selected_id: str | None = None
        self.new_piece_id: str | None = None
        self._loading = False
        v = QVBoxLayout(self)
        v.setContentsMargins(16, 12, 16, 8)
        v.setSpacing(8)
        add = QHBoxLayout()
        self.new_name = QLineEdit()
        self.new_name.setPlaceholderText("Neues Stück: Titel eingeben")
        self.new_name.returnPressed.connect(self._create)
        create = HardwareKey("Anlegen", "primary")
        create.clicked.connect(self._create)
        add.addWidget(self.new_name, 1)
        add.addWidget(create)
        v.addLayout(add)
        hint = QLabel("Ein Stück sammelt deine Takes. Der Punkt links wählt das Stück für neue Aufnahmen.")
        hint.setWordWrap(True)
        hint.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
        v.addWidget(hint)
        body = QHBoxLayout()
        self.list = QListWidget()
        self.list.setFixedWidth(280)
        self.list.setStyleSheet("QListWidget { background: transparent; border: none; } QListWidget::item { padding: 8px; }")
        self.list.currentRowChanged.connect(self._row_changed)
        body.addWidget(self.list)
        self.detail = QWidget()
        self._build_detail()
        body.addWidget(self.detail, 1)
        v.addLayout(body, 1)

    def _build_detail(self) -> None:
        d = QVBoxLayout(self.detail)
        d.setContentsMargins(12, 0, 0, 0)
        d.setSpacing(6)
        self.title = QLineEdit()
        self.title.setFont(theme.sans(18, bold=True))
        self.title.editingFinished.connect(lambda: self._set({"name": self.title.text().strip()}) if self.title.text().strip() else None)
        d.addWidget(self.title)
        self.summary = QLabel("")
        self.summary.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
        d.addWidget(self.summary)
        grid = QGridLayout()
        grid.setHorizontalSpacing(10)
        self.artist = QLineEdit()
        self.artist.editingFinished.connect(lambda: self._set({"artist": self.artist.text().strip()}))
        self.bpm = QLineEdit()
        self.bpm.setFixedWidth(70)
        self.bpm.editingFinished.connect(self._bpm_done)
        self.key = QLineEdit()
        self.key.setFixedWidth(120)
        self.key.editingFinished.connect(lambda: self._set({"key": self.key.text().strip() or None}))
        grid.addWidget(caption("Interpret"), 0, 0)
        grid.addWidget(self.artist, 1, 0)
        grid.addWidget(caption("Tempo"), 0, 1)
        grid.addWidget(self.bpm, 1, 1)
        grid.addWidget(caption("Tonart"), 0, 2)
        grid.addWidget(self.key, 1, 2)
        d.addLayout(grid)
        d.addWidget(caption("Sound"))
        sound = QHBoxLayout()
        self.sound_box = combo()
        self.sound_box.activated.connect(self._sound_chosen)
        play = HardwareKey("Spielen")
        play.clicked.connect(lambda: self.play_sound.emit(self._piece_link()))
        sound.addWidget(self.sound_box, 1)
        sound.addWidget(play)
        d.addLayout(sound)
        d.addWidget(caption("Notizen"))
        self.notes = QPlainTextEdit()
        self.notes.setFixedHeight(70)
        self.notes.setStyleSheet(f"QPlainTextEdit {{ background: {theme.FIELD}; border: 1px solid {theme.FIELD_EDGE}; "
                                 f"border-radius: 8px; padding: 6px; color: {theme.FIELD_TEXT}; }}")
        self.notes.textChanged.connect(lambda: None if self._loading else self._set({"notes": self.notes.toPlainText()}))
        d.addWidget(self.notes)
        d.addWidget(caption("Teile"))
        self.parts = QVBoxLayout()
        d.addLayout(self.parts)
        part_row = QHBoxLayout()
        self.part_name = QLineEdit()
        self.part_name.setPlaceholderText("Teil hinzufügen: Intro, Strophe, Solo …")
        self.part_name.returnPressed.connect(self._add_part)
        part_row.addWidget(self.part_name, 1)
        add_part = HardwareKey("Teil hinzufügen")
        add_part.clicked.connect(self._add_part)
        part_row.addWidget(add_part)
        d.addLayout(part_row)
        keys = QHBoxLayout()
        takes = HardwareKey("Takes zeigen")
        takes.clicked.connect(lambda: self.selected_id and self.show_takes.emit(self.selected_id))
        best = HardwareKey("Besten Take anhören")
        best.clicked.connect(lambda: self.selected_id and self.listen_to_best.emit(self.selected_id))
        remove = HardwareKey("Stück löschen", "danger")
        remove.clicked.connect(lambda: self.selected_id and self.deleted.emit(self.selected_id))
        for key in (takes, best, remove):
            keys.addWidget(key)
        keys.addStretch(1)
        d.addLayout(keys)
        d.addStretch(1)

    # MARK: Content

    def refresh(self) -> None:
        pieces = sorted(self.store.document["pieces"], key=lambda p: p["name"].casefold())
        self._loading = True
        self.list.blockSignals(True)
        self.list.clear()
        for piece in pieces:
            takes = [r for r in self.store.document["recordings"] if r.get("pieceID") == piece["id"]]
            marker = "●  " if piece["id"] == self.new_piece_id else "○  "
            item = QListWidgetItem(f"{marker}{piece['name']}\n      {len(takes)} {'Take' if len(takes) == 1 else 'Takes'} · "
                                   f"geübt {clock(storemod.practice_seconds(self.store, piece['id']))}")
            item.setData(Qt.UserRole, piece["id"])
            self.list.addItem(item)
            if piece["id"] == self.selected_id:
                self.list.setCurrentItem(item)
        self.list.blockSignals(False)
        self.detail.setVisible(bool(pieces) and self.selected_id is not None and storemod.piece(self.store, self.selected_id) is not None)
        self._show_detail()
        self._loading = False

    def _row_changed(self, row: int) -> None:
        item = self.list.item(row)
        self.selected_id = item.data(Qt.UserRole) if item else None
        item_ok = item is not None
        self.detail.setVisible(item_ok)
        self._loading = True
        self._show_detail()
        self._loading = False

    def mousePressEvent(self, event):
        item = self.list.itemAt(self.list.mapFromParent(event.position().toPoint()))
        if item is not None and event.position().x() - self.list.x() < 34:
            self.chosen_for_new.emit(None if item.data(Qt.UserRole) == self.new_piece_id else item.data(Qt.UserRole))
        super().mousePressEvent(event)

    def _show_detail(self) -> None:
        piece = storemod.piece(self.store, self.selected_id)
        if piece is None:
            return
        takes = [r for r in self.store.document["recordings"] if r.get("pieceID") == piece["id"]]
        self.title.setText(piece["name"])
        self.summary.setText(f"{len(takes)} {'Take' if len(takes) == 1 else 'Takes'} · geübt "
                             f"{clock(storemod.practice_seconds(self.store, piece['id']))}")
        self.artist.setText(piece.get("artist", ""))
        self.bpm.setText(f"{piece['bpm']:.0f}" if piece.get("bpm") else "")
        self.key.setText(piece.get("key") or "")
        if not self.notes.hasFocus():
            self.notes.setPlainText(piece.get("notes", ""))
        self.sound_box.blockSignals(True)
        self.sound_box.clear()
        self.sound_box.addItem("Kein Sound", None)
        link = piece.get("preset")
        names = []
        for preset in self.presets_provider():
            self.sound_box.addItem(preset.name, {"presetID": preset.id, "fileName": preset.path.name, "name": preset.name})
            names.append(preset.name)
        if link and link.get("name") not in names:
            self.sound_box.addItem(f"{link.get('name', '')} (fehlt)", link)
        if link:
            for i in range(self.sound_box.count()):
                data = self.sound_box.itemData(i)
                if data and data.get("name") == link.get("name"):
                    self.sound_box.setCurrentIndex(i)
        self.sound_box.blockSignals(False)
        while self.parts.count():
            item = self.parts.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        for part in piece.get("parts", []):
            self.parts.addWidget(self._part_row(piece, part))

    def _part_row(self, piece: dict, part: dict) -> QWidget:
        row = QWidget()
        h = QHBoxLayout(row)
        h.setContentsMargins(0, 0, 0, 0)
        name = QLabel(part.get("name", ""))
        name.setFont(theme.sans(14, bold=True))
        name.setMinimumWidth(110)
        name.setStyleSheet("background: transparent;")
        box = combo()
        box.addItem("Kein Sound", None)
        for preset in self.presets_provider():
            box.addItem(preset.name, {"presetID": preset.id, "fileName": preset.path.name, "name": preset.name})
        link = part.get("preset")
        if link:
            index = next((i for i in range(box.count()) if (box.itemData(i) or {}).get("name") == link.get("name")), -1)
            if index < 0:
                box.addItem(f"{link.get('name', '')} (fehlt)", link)
                index = box.count() - 1
            box.setCurrentIndex(index)
        box.activated.connect(lambda i, b=box, pid=part["id"]: self._part_sound(pid, b.itemData(i)))
        play = HardwareKey("Spielen")
        play.clicked.connect(lambda _=False, b=box: self.play_sound.emit(b.currentData()))
        remove = HardwareKey("✕")
        remove.clicked.connect(lambda _=False, pid=part["id"]: self._remove_part(pid))
        h.addWidget(name)
        h.addWidget(box, 1)
        h.addWidget(play)
        h.addWidget(remove)
        return row

    # MARK: Edits

    def _create(self) -> None:
        name = self.new_name.text().strip()
        if name:
            self.new_name.clear()
            self.created.emit(name)

    def _set(self, fields: dict) -> None:
        if self.selected_id and not self._loading:
            self.changed.emit(self.selected_id, fields)

    def _bpm_done(self) -> None:
        text = self.bpm.text().replace(",", ".").strip()
        try:
            self._set({"bpm": float(text) if text else None})
        except ValueError:
            self._show_detail()

    def _sound_chosen(self, index: int) -> None:
        self._set({"preset": self.sound_box.itemData(index)})

    def _piece_link(self):
        return self.sound_box.currentData()

    def _add_part(self) -> None:
        piece = storemod.piece(self.store, self.selected_id)
        name = self.part_name.text().strip()
        if piece is None or not name:
            return
        self.part_name.clear()
        parts = list(piece.get("parts", [])) + [{"id": storemod.new_id(), "name": name}]
        self._set({"parts": parts})

    def _remove_part(self, part_id: str) -> None:
        piece = storemod.piece(self.store, self.selected_id)
        if piece:
            self._set({"parts": [p for p in piece.get("parts", []) if p["id"] != part_id]})

    def _part_sound(self, part_id: str, link) -> None:
        piece = storemod.piece(self.store, self.selected_id)
        if piece:
            parts = []
            for part in piece.get("parts", []):
                part = dict(part)
                if part["id"] == part_id:
                    part["preset"] = link
                    if link is None:
                        part.pop("preset")
                parts.append(part)
            self._set({"parts": parts})


class StatsView(QWidget):
    """How much was recorded, per day and per piece. Discarded takes count too: the player practiced anyway."""

    def __init__(self, store, parent=None):
        super().__init__(parent)
        self.store = store
        self.days = 30
        self.setMinimumHeight(240)

    def sizeHint(self):
        return QSize(600, 300)

    def refresh(self) -> None:
        self.update()

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        data = storemod.practice_by_day(self.store, self.days)
        total = sum(minutes for _, minutes in data)
        p.setPen(c(theme.DESK_TEXT))
        p.setFont(theme.sans(26, bold=True))
        p.drawText(QRectF(24, 14, 400, 40), Qt.AlignLeft | Qt.AlignVCenter, minutes_text(total))
        p.setFont(theme.sans(13))
        p.setPen(c(theme.DESK_MUTED))
        p.drawText(QRectF(24, 52, 500, 20), Qt.AlignLeft, f"aufgenommen in den letzten {self.days} Tagen")
        p.setFont(theme.sans(14, bold=True))
        p.setPen(c(theme.DESK_TEXT))
        p.drawText(QRectF(24, 86, 300, 20), Qt.AlignLeft, "Minuten pro Tag")
        chart = QRectF(24, 112, self.width() - 48, max(self.height() - 190, 80))
        peak = max([m for _, m in data] + [1.0])
        width = chart.width() / len(data)
        for i, (day, minutes) in enumerate(data):
            height = minutes / peak * (chart.height() - 20)
            today = i == len(data) - 1
            p.setPen(Qt.NoPen)
            p.setBrush(c("#F2B233" if today else theme.WAVE, 1.0 if minutes else 0.25))
            p.drawRoundedRect(QRectF(chart.left() + i * width + 2, chart.bottom() - max(height, 2), width - 4, max(height, 2)), 2, 2)
            if minutes:
                p.setFont(theme.mono(10, True))
                p.setPen(c(theme.DESK_MUTED))
                p.drawText(QRectF(chart.left() + i * width - 4, chart.bottom() - height - 16, width + 8, 14), Qt.AlignCenter,
                           str(round(minutes)))
            if i % 5 == 0 or today:
                p.setFont(theme.mono(10))
                p.setPen(c(theme.DESK_MUTED))
                p.drawText(QRectF(chart.left() + i * width - 12, chart.bottom() + 4, width + 24, 14), Qt.AlignCenter,
                           day.strftime("%d.%m."))
        y = chart.bottom() + 30
        p.setFont(theme.sans(14, bold=True))
        p.setPen(c(theme.DESK_TEXT))
        p.drawText(QRectF(24, y, 300, 20), Qt.AlignLeft, "Minuten pro Stück")
        since = datetime.now().astimezone() - timedelta(days=self.days)
        rows = []
        for piece in self.store.document["pieces"]:
            seconds = storemod.practice_seconds(self.store, piece["id"], since)
            if seconds:
                rows.append((piece["name"], seconds / 60))
        p.setFont(theme.sans(13))
        if not rows:
            p.setPen(c(theme.DESK_MUTED))
            p.drawText(QRectF(24, y + 24, 600, 20), Qt.AlignLeft, "In diesem Zeitraum wurde nichts aufgenommen.")
        for i, (name, minutes) in enumerate(sorted(rows, key=lambda r: -r[1])[:6]):
            p.setPen(c(theme.DESK_TEXT))
            p.drawText(QRectF(24, y + 24 + i * 22, 220, 20), Qt.AlignLeft | Qt.AlignVCenter, name)
            p.setPen(c(theme.DESK_MUTED))
            p.drawText(QRectF(250, y + 24 + i * 22, 100, 20), Qt.AlignLeft | Qt.AlignVCenter, minutes_text(minutes))
        p.setPen(c(theme.DESK_MUTED))
        p.setFont(theme.sans(12))
        p.drawText(QRectF(24, self.height() - 26, self.width() - 48, 20), Qt.AlignLeft,
                   "Gezählt wird nur Zeit, die aufgenommen wurde. Auch verworfene Takes zählen mit.")
