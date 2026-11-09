"""The sidebar of the area Presets: the amp's slots, the presets on this computer and the backups."""
from __future__ import annotations

from datetime import datetime

from PySide6.QtCore import QPointF, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QFontMetrics, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QFrame, QLabel, QLineEdit, QScrollArea, QSizePolicy, QVBoxLayout, QWidget

from .. import catalog, devices
from ..library import SavedPreset
from . import theme
from .theme import c
from .widgets import HardwareKey

MONTHS = ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sep.", "Okt.", "Nov.", "Dez."]


def german_date(date: datetime) -> str:
    local = date.astimezone()
    return f"{local.day}. {MONTHS[local.month - 1]} {local.year}, {local.strftime('%H:%M')}"


def chain_summary(preset) -> str:
    """The sounding models of a preset: the amp first, then compressor, drive, modulation and delay when on."""
    if len(preset.effects) != 7:
        return ""
    cat = catalog.load()
    parts = []
    for index in (3, 1, 2, 4, 5):
        effect = preset.effects[index]
        if effect.is_on:
            parts.append(cat.info(effect.name, len(effect.parameters)).name)
    return " · ".join(parts)


class Row(QWidget):
    clicked = Signal(object)
    double_clicked = Signal(object)
    context = Signal(object, object)

    def __init__(self, key, kind: str, title: str, subtitle: str = "", number: int = 0, parent=None):
        super().__init__(parent)
        self.key, self.kind, self.title, self.subtitle, self.number = key, kind, title, subtitle, number
        self.selected = False
        self.active = False
        self.setFixedHeight(58 if kind != "slot" else 54)
        self.setCursor(Qt.PointingHandCursor)
        self.setContextMenuPolicy(Qt.CustomContextMenu)
        self.customContextMenuRequested.connect(lambda pos: self.context.emit(self, self.mapToGlobal(pos)))

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.clicked.emit(self)

    def mouseDoubleClickEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.double_clicked.emit(self)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(4, 2, -4, -2)
        if self.selected:
            p.setPen(Qt.NoPen)
            p.setBrush(c("#F7C45C", 0.14))
            p.drawRoundedRect(r, 7, 7)
            p.setBrush(c(theme.SELECTED_BAR))
            p.drawRoundedRect(QRectF(r.left(), r.top() + 4, 3, r.height() - 8), 1.5, 1.5)
        x = r.left() + 14
        cy = r.center().y()
        ink = theme.DESK_TEXT
        if self.kind == "slot":
            circle = QRectF(x, cy - 15, 30, 30)
            p.setPen(QPen(c(theme.AMBER if self.active else theme.DESK_LINE), 1.5))
            p.setBrush(c("#2A2A2F"))
            p.drawEllipse(circle)
            p.setFont(theme.mono(13, True))
            p.setPen(c(theme.AMBER if self.active else theme.DESK_MUTED))
            p.drawText(circle, Qt.AlignCenter, str(self.number))
            p.setFont(theme.sans(15))
            p.setPen(c(ink if self.title != "–" else theme.DESK_MUTED))
            p.drawText(QRectF(x + 44, r.top(), r.width() - 70, r.height()), Qt.AlignLeft | Qt.AlignVCenter,
                       QFontMetrics(p.font()).elidedText(self.title, Qt.ElideRight, int(r.width() - 70)))
            if self.active:
                p.setPen(Qt.NoPen)
                p.setBrush(c(theme.AMBER))
                p.drawEllipse(QPointF(r.right() - 14, cy), 4, 4)
            return
        icon = QRectF(x, cy - 9, 20, 18)
        p.setPen(QPen(c(theme.DESK_MUTED), 1.4))
        p.setBrush(Qt.NoBrush)
        if self.kind == "backup":
            p.drawEllipse(QRectF(x + 1, cy - 8, 16, 16))
            p.drawLine(QPointF(x + 9, cy - 4), QPointF(x + 9, cy))
            p.drawLine(QPointF(x + 9, cy), QPointF(x + 12.5, cy + 2))
        else:
            path = QPainterPath()
            path.moveTo(icon.left(), icon.top() + 3)
            path.lineTo(icon.left() + 7, icon.top() + 3)
            path.lineTo(icon.left() + 9, icon.top() + 5.5)
            path.lineTo(icon.right(), icon.top() + 5.5)
            path.lineTo(icon.right(), icon.bottom())
            path.lineTo(icon.left(), icon.bottom())
            path.closeSubpath()
            p.drawPath(path)
        tx = x + 36
        width = int(r.width() - (tx - r.left()) - 10)
        p.setFont(theme.sans(15))
        p.setPen(c(ink))
        fm = QFontMetrics(p.font())
        p.drawText(QRectF(tx, r.top() + 6, width, 22), Qt.AlignLeft | Qt.AlignVCenter,
                   fm.elidedText(self.title, Qt.ElideRight, width))
        p.setFont(theme.sans(12))
        p.setPen(c(theme.DESK_MUTED))
        fm = QFontMetrics(p.font())
        p.drawText(QRectF(tx, r.top() + 28, width, 18), Qt.AlignLeft | Qt.AlignVCenter,
                   fm.elidedText(self.subtitle, Qt.ElideRight, width))


def heading(text: str) -> QWidget:
    box = QWidget()
    layout = QVBoxLayout(box)
    layout.setContentsMargins(14, 14, 14, 0)
    layout.setSpacing(6)
    label = QLabel(text)
    label.setFont(theme.sans(14, bold=True))
    label.setStyleSheet(f"background: transparent; color: {theme.DESK_TEXT};")
    rule = QFrame()
    rule.setFixedHeight(1)
    rule.setStyleSheet(f"background: {theme.DESK_LINE};")
    layout.addWidget(label)
    layout.addWidget(rule)
    return box


class Sidebar(QWidget):
    slot_selected = Signal(int)
    slot_played = Signal(int)
    item_selected = Signal(object)
    item_menu = Signal(object, object)
    search_changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedWidth(300)
        self.setStyleSheet(f"background: #18181B;")
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.body = QWidget()
        self.body.setStyleSheet("background: transparent;")
        self.column = QVBoxLayout(self.body)
        self.column.setContentsMargins(6, 6, 6, 12)
        self.column.setSpacing(0)
        self.scroll.setWidget(self.body)
        outer.addWidget(self.scroll, 1)
        self.search = QLineEdit()
        self.search.setPlaceholderText("Suchen")
        self.search.setClearButtonEnabled(True)
        self.search.setStyleSheet("margin: 8px;")
        self.search.textChanged.connect(lambda _: self.search_changed.emit())
        outer.addWidget(self.search)
        self.rows: list[Row] = []
        self.selection = None
        self.active_slot: int | None = None
        self.slots: list = [None] * 4
        self.profile = devices.SPARK_MINI
        self.items: list[SavedPreset] = []
        self.rebuild()

    def needle(self) -> str:
        return self.search.text().strip().casefold()

    def rebuild(self) -> None:
        while self.column.count():
            item = self.column.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self.rows = []
        profile = self.profile
        unknown = "–" if profile.can(devices.READ) else "Inhalt unbekannt"
        for slot in range(profile.slot_count):
            if slot == 0 or (profile.bank_size and slot % profile.bank_size == 0):
                bank = f" · {profile.bank_names[slot // profile.bank_size]}" if profile.bank_size else ""
                self.column.addWidget(heading(f"Am {profile.display_name}{bank}"))
            preset = self.slots[slot] if slot < len(self.slots) else None
            number = slot % profile.bank_size + 1 if profile.bank_size else slot + 1
            row = Row(("slot", slot), "slot", preset.name if preset else unknown, number=number)
            row.clicked.connect(lambda r: self._clicked(r))
            row.double_clicked.connect(lambda r: self.slot_played.emit(r.key[1]))
            self._add(row)
        needle = self.needle()
        shown = [i for i in self.items if not i.is_backup and (not needle or needle in
                 " ".join([i.name, *i.tags, chain_summary(i.preset)]).casefold())]
        self.column.addSpacing(10)
        self.column.addWidget(heading("Auf diesem Computer"))
        if not shown:
            note = QLabel("Noch nichts gesichert." if not needle else "Nichts gefunden.")
            note.setContentsMargins(14, 10, 14, 10)
            note.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
            self.column.addWidget(note)
        for item in shown:
            title = item.name + ("  ✦" if item.is_recipe else "")
            row = Row(("file", item.path), "file", title, chain_summary(item.preset))
            row.setToolTip("Sound-Rezept, als Preset gelesen" if item.is_recipe else str(item.path.name))
            self._wire_item(row, item)
            self._add(row)
        backups = [i for i in self.items if i.is_backup and (not needle or needle in i.name.casefold())]
        if backups:
            self.column.addSpacing(10)
            self.column.addWidget(heading("Sicherungen"))
            for item in sorted(backups, key=lambda i: i.saved_at, reverse=True):
                row = Row(("file", item.path), "backup", item.name, german_date(item.saved_at))
                self._wire_item(row, item)
                self._add(row)
        self.column.addStretch(1)
        self._apply_state()

    def _wire_item(self, row: Row, item: SavedPreset) -> None:
        row.clicked.connect(lambda r, i=item: self._clicked(r))
        row.context.connect(lambda r, pos, i=item: self.item_menu.emit(i, pos))
        row.item = item

    def _add(self, row: Row) -> None:
        self.rows.append(row)
        self.column.addWidget(row)

    def _clicked(self, row: Row) -> None:
        self.selection = row.key
        self._apply_state()
        if row.key[0] == "slot":
            self.slot_selected.emit(row.key[1])
        else:
            self.item_selected.emit(row.item)

    def select(self, key) -> None:
        self.selection = key
        self._apply_state()

    def _apply_state(self) -> None:
        for row in self.rows:
            row.selected = row.key == self.selection
            row.active = row.kind == "slot" and row.key[1] == self.active_slot
            row.update()
