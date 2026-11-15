"""The sidebar of the area Presets, short as on the Mac: the amp's slots, favorites, the sounds used last, and the
ways into the library (ui/library_overlay.py), which holds everything else."""
from __future__ import annotations

from datetime import datetime

from PySide6.QtCore import QPoint, QPointF, QRect, QRectF, QSettings, QSize, Qt, Signal
from PySide6.QtGui import QFontMetrics, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import (QFrame, QHBoxLayout, QLabel, QLayout, QMenu, QPushButton, QScrollArea,
                               QSizePolicy, QToolButton, QVBoxLayout, QWidget)

from .. import catalog, devices
from ..i18n import tr
from ..library import SavedPreset
from . import theme
from .formats import date_time
from .theme import c
from .widgets import HardwareKey

def saved_date(date: datetime) -> str:
    return date_time(date)


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
        self.count: int | None = None
        self.filters = None  # for an entry: the library's filters it opens with
        self.setFixedHeight(36 if kind == "entry" else 58 if kind != "slot" else 54)
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
        if self.kind == "entry":
            p.setFont(theme.mono(12))
            p.setPen(c(theme.DESK_MUTED))
            count = "" if self.count is None else str(self.count)
            count_w = QFontMetrics(p.font()).horizontalAdvance(count) + 8
            p.drawText(QRectF(r.left(), r.top(), r.width() - 12, r.height()), Qt.AlignRight | Qt.AlignVCenter, count)
            p.setFont(theme.sans(14))
            p.setPen(c(ink))
            width = int(r.width() - 26 - count_w)
            p.drawText(QRectF(x, r.top(), width, r.height()), Qt.AlignLeft | Qt.AlignVCenter,
                       QFontMetrics(p.font()).elidedText(self.title, Qt.ElideRight, width))
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


class FlowLayout(QLayout):
    """Lays chips out in lines, wrapping when the width is used up."""

    def __init__(self, parent=None, spacing: int = 4):
        super().__init__(parent)
        self._items: list = []
        self._spacing = spacing

    def addItem(self, item):
        self._items.append(item)

    def count(self):
        return len(self._items)

    def itemAt(self, index):
        return self._items[index] if 0 <= index < len(self._items) else None

    def takeAt(self, index):
        return self._items.pop(index) if 0 <= index < len(self._items) else None

    def hasHeightForWidth(self):
        return True

    def heightForWidth(self, width):
        return self._arrange(QRect(0, 0, width, 0), False)

    def setGeometry(self, rect):
        super().setGeometry(rect)
        self._arrange(rect, True)

    def sizeHint(self):
        return self.minimumSize()

    def minimumSize(self):
        size = QSize()
        for item in self._items:
            size = size.expandedTo(item.minimumSize())
        margins = self.contentsMargins()
        return size + QSize(margins.left() + margins.right(), margins.top() + margins.bottom())

    def _arrange(self, rect, apply: bool) -> int:
        margins = self.contentsMargins()
        x, y, line = rect.x() + margins.left(), rect.y() + margins.top(), 0
        right = rect.right() - margins.right()
        for item in self._items:
            hint = item.sizeHint()
            if x + hint.width() > right and line > 0:
                x, y, line = rect.x() + margins.left(), y + line + self._spacing, 0
            if apply:
                item.setGeometry(QRect(QPoint(x, y), hint))
            x += hint.width() + self._spacing
            line = max(line, hint.height())
        return y + line - rect.y() + margins.bottom()


FAVORITE_LIMIT = 8
RECENT_LIMIT = 5


class Sidebar(QWidget):
    slot_selected = Signal(int)
    slot_played = Signal(int)
    item_selected = Signal(object)
    item_menu = Signal(object, object)
    # The library is wanted, with these filters (a set) or as it was (None).
    library_requested = Signal(object)

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
        # The way into the library, where the search field always was: drawn like one, with its key.
        self.search = LibraryEntry()
        self.search.clicked.connect(lambda: self.library_requested.emit(None))
        # "+" beside the search, as on the Mac: a new preset, from a template, AI Sound, the Kemper import. The main
        # window fills its menu (`new_menu`).
        self.new_button = QToolButton()
        self.new_button.setText("+")
        self.new_button.setToolTip(tr("New preset"))
        self.new_button.setPopupMode(QToolButton.InstantPopup)
        self.new_button.setStyleSheet("QToolButton { margin: 8px 8px 8px 0; padding: 2px 9px; font-weight: bold; }"
                                      "QToolButton::menu-indicator { image: none; }")
        self.new_menu = QMenu(self.new_button)
        self.new_button.setMenu(self.new_menu)
        bottom = QHBoxLayout()
        bottom.setContentsMargins(0, 0, 0, 0)
        bottom.setSpacing(0)
        bottom.addWidget(self.search, 1)
        bottom.addWidget(self.new_button)
        outer.addLayout(bottom)
        self.rows: list[Row] = []
        self.selection = None
        self.active_slot: int | None = None
        self.slots: list = [None] * 4
        self.profile = devices.SPARK_MINI
        self.items: list[SavedPreset] = []
        self.unreadable: list[str] = []
        # The ids or file names of the sounds opened last, newest first (library_controller.py keeps them).
        self.recent_keys: list[str] = []
        # Tags shown as entries of their own under "Library" (kept on this computer).
        self._settings = QSettings("local.ampbench", "AmpBench")
        pinned = self._settings.value("pinnedTags") or []
        self.pinned: list[str] = [pinned] if isinstance(pinned, str) else list(pinned)
        self.rebuild()

    def tag_counts(self) -> list[tuple[str, int]]:
        counts: dict[str, list] = {}
        for item in self.items:
            if not item.is_backup:
                for tag in item.tags:
                    counts.setdefault(tag.casefold(), [tag, 0])[1] += 1
        return sorted(((t, c) for t, c in counts.values()), key=lambda e: (-e[1], e[0].casefold()))

    def is_pinned(self, tag: str) -> bool:
        return tag.casefold() in (t.casefold() for t in self.pinned)

    def toggle_pin(self, tag: str) -> None:
        if self.is_pinned(tag):
            self.pinned = [t for t in self.pinned if t.casefold() != tag.casefold()]
        else:
            self.pinned.append(tag)
        self._settings.setValue("pinnedTags", self.pinned)
        self.rebuild()

    def pin(self, tags: list[str]) -> None:
        for tag in tags:
            if not self.is_pinned(tag):
                self.pinned.append(tag)
        self._settings.setValue("pinnedTags", self.pinned)

    def rebuild(self) -> None:
        while self.column.count():
            item = self.column.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self.rows = []
        profile = self.profile
        unknown = "–" if profile.can(devices.READ) else tr("Content unknown")
        for slot in range(profile.slot_count):
            if slot == 0 or (profile.bank_size and slot % profile.bank_size == 0):
                bank = f" · {profile.bank_names[slot // profile.bank_size]}" if profile.bank_size else ""
                self.column.addWidget(heading(tr("On the {}", profile.display_name) + bank))
            preset = self.slots[slot] if slot < len(self.slots) else None
            number = slot % profile.bank_size + 1 if profile.bank_size else slot + 1
            row = Row(("slot", slot), "slot", preset.name if preset else unknown, number=number)
            row.clicked.connect(lambda r: self._clicked(r))
            row.double_clicked.connect(lambda r: self.slot_played.emit(r.key[1]))
            self._add(row)
        from .. import library_query as q
        sounds = [i for i in self.items if not i.is_backup]
        favorites = [i for i in sounds if i.favorite]
        if favorites:
            self.column.addSpacing(10)
            self.column.addWidget(heading(tr("Favorites")))
            for item in favorites[:FAVORITE_LIMIT]:
                self._add_item_row(item)
            if len(favorites) > FAVORITE_LIMIT:
                self._add_entry(tr("{} more favorites", len(favorites) - FAVORITE_LIMIT), None,
                                {("scope", q.FAVORITES)})
        by_key = {key: i for i in sounds for key in (i.id, i.path.name) if key}
        recent = [by_key[k] for k in dict.fromkeys(self.recent_keys) if k in by_key][:RECENT_LIMIT]
        if recent:
            self.column.addSpacing(10)
            self.column.addWidget(heading(tr("Recently used")))
            for item in recent:
                self._add_item_row(item)
        self.column.addSpacing(10)
        self.column.addWidget(heading(tr("Library")))
        self._add_entry(tr("All sounds"), len(sounds), set())
        for tag in self.pinned:
            count = sum(1 for i in sounds if tag.casefold() in (t.casefold() for t in i.tags))
            if count:
                row = self._add_entry(f"#{tag}", count, {("tag", tag)})
                row.context.connect(lambda r, pos, t=tag: self._pin_menu(t, pos))
        listen = sum(1 for i in sounds if q.needs_listen(i))
        if listen:
            self._add_entry(tr("To listen"), listen, {("scope", q.TO_LISTEN)})
        backups = sum(1 for i in self.items if i.is_backup)
        if backups:
            self._add_entry(tr("Slot backups"), backups, {("scope", q.BACKUPS)})
        if self.unreadable:
            self._add_entry(tr("1 file unreadable") if len(self.unreadable) == 1
                            else tr("{} files unreadable", len(self.unreadable)), None, None)
        self.search.set_count(len(sounds))
        self.column.addStretch(1)
        self._apply_state()

    def _add_entry(self, title: str, count: int | None, filters) -> Row:
        row = Row(("entry", title), "entry", title)
        row.count, row.filters = count, filters
        row.setToolTip(tr("Opens the library"))
        row.clicked.connect(lambda r: self.library_requested.emit(r.filters))
        self._add(row)
        return row

    def _pin_menu(self, tag: str, pos) -> None:
        menu = QMenu(self)
        menu.addAction(tr("Unpin from the sidebar"), lambda: self.toggle_pin(tag))
        menu.exec(pos)

    def _add_item_row(self, item: SavedPreset) -> None:
        title = item.name + ("  ✦" if item.is_recipe else "")
        subtitle = chain_summary(item.preset)
        if item.tags:
            subtitle += "   " + " ".join(f"#{t}" for t in item.tags)
        row = Row(("file", item.path), "file", title, subtitle)
        row.setToolTip(item.notes or (tr("Sound recipe, read as a preset") if item.is_recipe else str(item.path.name)))
        self._wire_item(row, item)
        self._add(row)

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


class LibraryEntry(QPushButton):
    """"Search 92 sounds" with its key: drawn like a search field, opens the library."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.count = 0
        self.setCursor(Qt.PointingHandCursor)
        self.setFixedHeight(48)
        self.setToolTip(tr("Opens the library, to find, hear and look after every sound (Ctrl+L)"))
        self.set_count(0)

    def set_count(self, count: int) -> None:
        self.count = count
        self.setAccessibleName(tr("Search {} sounds", count))
        self.update()

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(8.5, 8.5, -6.5, -8.5)
        p.setPen(QPen(c(theme.AMBER_DIM if self.hasFocus() else theme.FIELD_EDGE), 1))
        p.setBrush(c(theme.FIELD))
        p.drawRoundedRect(r, 8, 8)
        glass = QRectF(r.left() + 10, r.center().y() - 6, 10, 10)
        p.setPen(QPen(c(theme.DESK_MUTED), 1.5))
        p.setBrush(Qt.NoBrush)
        p.drawEllipse(glass)
        p.drawLine(QPointF(glass.right() - 1, glass.bottom() - 1), QPointF(glass.right() + 3, glass.bottom() + 3))
        p.setFont(theme.mono(11))
        key = tr("Ctrl+L")
        key_w = QFontMetrics(p.font()).horizontalAdvance(key)
        p.drawText(QRectF(r.right() - key_w - 10, r.top(), key_w, r.height()), Qt.AlignVCenter, key)
        p.setFont(theme.sans(13))
        p.setPen(c(theme.DESK_MUTED))
        width = int(r.width() - 44 - key_w)
        p.drawText(QRectF(r.left() + 30, r.top(), width, r.height()), Qt.AlignLeft | Qt.AlignVCenter,
                   QFontMetrics(p.font()).elidedText(tr("Search {} sounds", self.count), Qt.ElideRight, width))
