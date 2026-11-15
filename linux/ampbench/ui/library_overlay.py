"""The library of the area Presets: every saved sound at a glance, to find, hear and look after them.

It covers the sidebar and the editor while it is open, as on the Mac (Sources/SparkPresetsUI/Library): a front strip
with the count and Close, the search and the grouping, the filters on the left, the sounds as a table in the middle,
the chosen sound on the right, and a status line with the keys. The view only shows and asks; what changes files is
in library_controller.py.
"""
from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QEvent, QItemSelectionModel, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QFontMetrics, QKeySequence, QPainter, QPen, QShortcut
from PySide6.QtWidgets import (QAbstractItemView, QCheckBox, QFrame, QGridLayout, QHBoxLayout, QHeaderView, QLabel,
                               QLineEdit, QListWidget, QListWidgetItem, QMenu, QPlainTextEdit, QPushButton,
                               QScrollArea, QSizePolicy, QStyle, QStyledItemDelegate, QTreeWidget, QTreeWidgetItem,
                               QVBoxLayout, QWidget)

from .. import catalog
from .. import library_query as q
from ..i18n import tr
from ..library import SavedPreset, parse_tags
from . import theme
from .formats import date_time, short_date_time
from .sidebar import FlowLayout, chain_summary
from .theme import c
from .widgets import HardwareKey, Lamp, SegmentTabs

PATH_ROLE = Qt.UserRole
ROW_ROLE = Qt.UserRole + 1
FILTER_ROLE = Qt.UserRole + 2
COUNT_ROLE = Qt.UserRole + 3

COLUMNS = ("name", "chain", "amp", "tags", "origin", "saved")


def paint_chain(p: QPainter, rect: QRectF, preset, height: float = 14) -> None:
    """The chain in miniature: one block per place, lit in its color when on, the amp wider."""
    if len(preset.effects) != len(catalog.PLACES):
        return
    widths = [2.4 if place == "amp" else 1 for place in catalog.PLACES]
    gap = 2.5
    unit = min((rect.width() - gap * (len(widths) - 1)) / sum(widths), 14)
    x, top = rect.left(), rect.center().y() - height / 2
    for place, effect, width in zip(catalog.PLACES, preset.effects, widths):
        box = QRectF(x, top, unit * width, height)
        color = theme.place_color(place)
        p.setPen(QPen(c("#000000", 0.7), 1))
        if effect.is_on:
            p.setBrush(color)
        else:
            color.setAlphaF(0.22)
            p.setBrush(color)
        p.drawRoundedRect(box, 2.5, 2.5)
        x += box.width() + gap


def tags_text(item: SavedPreset) -> str:
    return " ".join(f"#{t}" for t in item.tags if t.casefold() != q.LISTEN_TAG)


def caption(text: str) -> QLabel:
    label = QLabel(text.upper())
    label.setFont(theme.sans(11, bold=True, spacing=0.09))
    label.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
    return label


def muted(text: str, size: int = 12) -> QLabel:
    label = QLabel(text)
    label.setWordWrap(True)
    label.setFont(theme.sans(size))
    label.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
    return label


class _RowDelegate(QStyledItemDelegate):
    """Group titles across the row, the name with a star and the pill "To listen", and the chain in miniature."""

    def __init__(self, overlay):
        super().__init__(overlay)
        self.overlay = overlay

    def sizeHint(self, option, index):
        return QSize(super().sizeHint(option, index).width(), 30)

    def paint(self, p, option, index):
        item = self.overlay.item_at(index)
        if item is None:
            if index.column() == 0:
                p.save()
                p.setFont(theme.sans(12, bold=True))
                p.setPen(c(theme.AMBER))
                rect = QRectF(option.rect).adjusted(10, 0, 0, 0)
                p.drawText(rect, Qt.AlignLeft | Qt.AlignVCenter, index.data())
                p.restore()
            return
        column = COLUMNS[index.column()]
        if column not in ("name", "chain"):
            super().paint(p, option, index)
            return
        # Background and selection as the other cells draw them, then the content.
        option.text = ""
        self.initStyleOption(option, index)
        option.text = ""
        option.widget.style().drawControl(QStyle.CE_ItemViewItem, option, p, option.widget)
        p.save()
        p.setRenderHint(QPainter.Antialiasing)
        rect = QRectF(option.rect).adjusted(8, 0, -6, 0)
        if column == "chain":
            paint_chain(p, rect, item.preset)
            p.restore()
            return
        x = rect.left()
        if item.favorite:
            p.setFont(theme.sans(12))
            p.setPen(c(theme.STAR))
            p.drawText(QRectF(x, rect.top(), 16, rect.height()), Qt.AlignLeft | Qt.AlignVCenter, "★")
        x += 18
        p.setFont(theme.sans(13))
        fm = QFontMetrics(p.font())
        pill = tr("To listen") if q.needs_listen(item) else ""
        pill_font = theme.sans(10, bold=True)
        pill_w = QFontMetrics(pill_font).horizontalAdvance(pill) + 14 if pill else 0
        room = int(rect.right() - x - (pill_w + 8 if pill else 0))
        name = fm.elidedText(item.name, Qt.ElideRight, max(room, 20))
        p.setPen(c(theme.DESK_TEXT))
        p.drawText(QRectF(x, rect.top(), room, rect.height()), Qt.AlignLeft | Qt.AlignVCenter, name)
        if pill:
            px = x + fm.horizontalAdvance(name) + 8
            box = QRectF(px, rect.center().y() - 8, pill_w, 16)
            p.setPen(QPen(c(theme.AMBER, 0.8), 1))
            p.setBrush(c(theme.AMBER, 0.16))
            p.drawRoundedRect(box, 8, 8)
            p.setFont(pill_font)
            p.setPen(c(theme.AMBER))
            p.drawText(box, Qt.AlignCenter, pill)
        p.restore()


class _FilterDelegate(QStyledItemDelegate):
    """A filter with its count on the right; section titles in bold."""

    def sizeHint(self, option, index):
        return QSize(super().sizeHint(option, index).width(), 34 if index.data(FILTER_ROLE) is None else 28)

    def paint(self, p, option, index):
        filter_ = index.data(FILTER_ROLE)
        if filter_ is None:
            p.save()
            p.setFont(theme.sans(12, bold=True))
            p.setPen(c(theme.DESK_MUTED))
            p.drawText(QRectF(option.rect).adjusted(12, 8, 0, 0), Qt.AlignLeft | Qt.AlignVCenter, index.data())
            p.restore()
            return
        count = index.data(COUNT_ROLE)
        self.initStyleOption(option, index)
        text = option.text
        option.text = ""
        option.widget.style().drawControl(QStyle.CE_ItemViewItem, option, p, option.widget)
        p.save()
        rect = QRectF(option.rect).adjusted(14, 0, -12, 0)
        p.setFont(theme.mono(11))
        p.setPen(c(theme.DESK_MUTED))
        count_text = "" if count is None else str(count)
        cw = QFontMetrics(p.font()).horizontalAdvance(count_text) + 6
        p.drawText(rect, Qt.AlignRight | Qt.AlignVCenter, count_text)
        p.setFont(theme.sans(13))
        p.setPen(c(theme.DESK_TEXT if filter_[0] != "more" else theme.DESK_MUTED))
        fm = QFontMetrics(p.font())
        p.drawText(rect.adjusted(0, 0, -cw, 0), Qt.AlignLeft | Qt.AlignVCenter,
                   fm.elidedText(text, Qt.ElideRight, int(rect.width() - cw)))
        p.restore()


class SoundTable(QTreeWidget):
    """The table; Return hears the selected sound, ↑ at the top goes back to the search. Tags, origin and
    date step aside when the table is narrow, so the name keeps its room (the preview shows them)."""
    hear = Signal()
    to_search = Signal()
    WIDE = {3: 640, 4: 900, 5: 1010}

    def resizeEvent(self, event):
        super().resizeEvent(event)
        for column, width in self.WIDE.items():
            self.setColumnHidden(column, self.viewport().width() < width)

    def keyPressEvent(self, event):
        if event.key() in (Qt.Key_Return, Qt.Key_Enter) and not event.modifiers() & Qt.ControlModifier:
            self.hear.emit()
            return
        if event.key() == Qt.Key_Up and not event.modifiers():
            first = self._first_row()
            if first is not None and self.currentItem() is first:
                self.to_search.emit()
                return
        super().keyPressEvent(event)

    def _first_row(self):
        iterator = self.topLevelItem(0)
        if iterator is None:
            return None
        return iterator.child(0) if iterator.childCount() else iterator


class NotesEdit(QPlainTextEdit):
    """Notes that are kept when the field loses the keyboard."""
    finished = Signal(str)

    def focusOutEvent(self, event):
        self.finished.emit(self.toPlainText())
        super().focusOutEvent(event)


class LibraryOverlay(QWidget):
    """The view. It is given the items (`set_items`) and says what is wanted through its signals."""
    close_requested = Signal()
    hear = Signal(object)                 # SavedPreset
    open_item = Signal(object)            # SavedPreset
    favorite = Signal(list, bool)
    listen = Signal(list, bool)
    add_tags = Signal(list, list)
    remove_tag = Signal(list, str)
    notes = Signal(object, str)
    rename = Signal(list)
    trash = Signal(list)
    reveal = Signal(object)
    pin = Signal(str)
    grouping_changed = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("library")
        self.items: list[SavedPreset] = []
        self.unreadable: list[str] = []
        self.filters: set[tuple] = set()
        self.grouping = q.NONE
        self.sort_column, self.descending = 0, False
        self.close_sets: list[list[SavedPreset]] = []
        self.close_paths: set[Path] = set()
        self.pinned: list[str] = []
        self.show_rare_tags = False
        self.pieces_for = lambda item: []
        self._rows: dict[int, SavedPreset] = {}
        self._building = False
        self.setStyleSheet(f"QWidget#library {{ background: {theme.DESK}; }} "
                           f"QCheckBox {{ spacing: 7px; }} "
                           f"QCheckBox::indicator {{ width: 15px; height: 15px; border-radius: 4px; "
                           f"border: 1px solid {theme.KEY_EDGE}; background: {theme.KEY_TOP}; }} "
                           f"QCheckBox::indicator:checked {{ background: {theme.AMBER}; border-color: #6B4E12; }} "
                           f"QCheckBox::indicator:indeterminate {{ background: {theme.AMBER_DIM}; }}")
        column = QVBoxLayout(self)
        column.setContentsMargins(0, 0, 0, 0)
        column.setSpacing(0)
        column.addWidget(self._front())
        column.addLayout(self._search_row())
        body = QHBoxLayout()
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(0)
        body.addWidget(self._filter_list())
        body.addWidget(self._table(), 1)
        body.addWidget(self._preview_area())
        column.addLayout(body, 1)
        column.addWidget(self._status_line())
        # Tab walks from the search to the list, the filters and the chosen sound.
        self.setTabOrder(self.search, self.table)
        self.setTabOrder(self.table, self.filter_list)
        self.setTabOrder(self.filter_list, self.preview_scroll)
        escape = QShortcut(QKeySequence(Qt.Key_Escape), self)
        escape.setContext(Qt.WidgetWithChildrenShortcut)
        escape.activated.connect(self.close_requested)

    # MARK: Building

    def _front(self) -> QWidget:
        strip = QFrame()
        strip.setObjectName("front")
        strip.setFixedHeight(54)
        strip.setStyleSheet(f"QFrame#front {{ background: qlineargradient(x1:0, y1:0, x2:0, y2:1, "
                            f"stop:0 {theme.FRONT_TOP}, stop:1 {theme.FRONT_BOTTOM}); "
                            f"border-bottom: 1px solid {theme.FRONT_EDGE}; }}")
        row = QHBoxLayout(strip)
        row.setContentsMargins(22, 8, 18, 8)
        row.setSpacing(14)
        title = QLabel(tr("Library").upper())
        title.setFont(theme.sans(12, bold=True, spacing=0.12))
        title.setStyleSheet(f"color: {theme.ENGRAVING};")
        title.setAccessibleName(tr("Library"))
        row.addWidget(title)
        self.count_label = QLabel("")
        self.count_label.setFont(theme.mono(13, True))
        self.count_label.setStyleSheet(f"color: {theme.AMBER};")
        row.addWidget(self.count_label)
        row.addStretch(1)
        self.close_key = HardwareKey(tr("Close"), keycap="Esc")
        self.close_key.setToolTip(tr("Closes the library (Esc)"))
        self.close_key.clicked.connect(self.close_requested)
        row.addWidget(self.close_key)
        return strip

    def _search_row(self) -> QHBoxLayout:
        row = QHBoxLayout()
        row.setContentsMargins(18, 10, 18, 10)
        row.setSpacing(14)
        self.search = QLineEdit()
        self.search.setPlaceholderText(tr("Search names, amps, tags, notes – “#song” searches tags"))
        self.search.setClearButtonEnabled(True)
        self.search.setAccessibleName(tr("Search the library"))
        self.search.setMaximumWidth(560)
        self.search.textChanged.connect(lambda _: self.refresh())
        self.search.returnPressed.connect(self._hear_first_match)
        self.search.installEventFilter(self)
        row.addWidget(self.search, 1)
        row.addStretch(0)
        self.group_tabs = SegmentTabs([q.grouping_title(g) for g in q.GROUPINGS])
        self.group_tabs.setToolTip(tr("How the sounds are grouped (Ctrl+G for the next)"))
        self.group_tabs.changed.connect(lambda index: self.set_grouping(q.GROUPINGS[index], emit=True))
        row.addWidget(self.group_tabs)
        return row

    def _filter_list(self) -> QWidget:
        self.filter_list = QListWidget()
        self.filter_list.setFixedWidth(216)
        self.filter_list.setSelectionMode(QAbstractItemView.ExtendedSelection)
        self.filter_list.setItemDelegate(_FilterDelegate(self.filter_list))
        self.filter_list.setAccessibleName(tr("Filters"))
        self.filter_list.setContextMenuPolicy(Qt.CustomContextMenu)
        self.filter_list.customContextMenuRequested.connect(self._filter_menu)
        self.filter_list.itemSelectionChanged.connect(self._filters_chosen)
        self.filter_list.setStyleSheet(
            f"QListWidget {{ background: #18181B; border: none; border-right: 1px solid {theme.DESK_LINE}; "
            f"outline: none; padding: 4px 6px; }} "
            f"QListWidget::item {{ border-radius: 6px; }} "
            f"QListWidget::item:selected {{ background: rgba(247,196,92,46); color: {theme.DESK_TEXT}; }}")
        return self.filter_list

    def _table(self) -> QWidget:
        self.table = SoundTable()
        self.table.setColumnCount(len(COLUMNS))
        self.table.setHeaderLabels([tr("Name"), tr("Chain"), tr("Amp"), tr("Tags"), tr("Origin"), tr("Saved")])
        self.table.setRootIsDecorated(False)
        self.table.setIndentation(0)
        self.table.setUniformRowHeights(True)
        self.table.setAlternatingRowColors(True)
        self.table.setSelectionMode(QAbstractItemView.ExtendedSelection)
        self.table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.table.setAllColumnsShowFocus(True)
        self.table.setItemsExpandable(False)
        self.table.setExpandsOnDoubleClick(False)
        self.table.setItemDelegate(_RowDelegate(self))
        self.table.setAccessibleName(tr("Sounds"))
        self.table.setContextMenuPolicy(Qt.CustomContextMenu)
        self.table.customContextMenuRequested.connect(self._row_menu)
        self.table.itemSelectionChanged.connect(self._selection_changed)
        self.table.itemDoubleClicked.connect(lambda row, _c: self._hear_selected())
        self.table.hear.connect(self._hear_selected)
        self.table.to_search.connect(self.focus_search)
        header = self.table.header()
        header.setStretchLastSection(False)
        header.setSectionResizeMode(QHeaderView.Interactive)
        header.setSectionResizeMode(0, QHeaderView.Stretch)
        header.setMinimumSectionSize(60)
        self.table.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        for index, width in ((1, 104), (2, 128), (3, 160), (4, 130), (5, 104)):
            header.resizeSection(index, width)
        header.setSectionsClickable(True)
        header.setSortIndicatorShown(True)
        header.setSortIndicator(0, Qt.AscendingOrder)
        header.setDefaultAlignment(Qt.AlignLeft | Qt.AlignVCenter)
        header.sectionClicked.connect(self._header_clicked)
        self.table.setStyleSheet(
            f"QTreeWidget {{ background: {theme.DESK}; border: none; alternate-background-color: {theme.DESK_ALT}; "
            f"outline: none; }} "
            f"QHeaderView::section {{ background: {theme.DESK}; color: {theme.DESK_TEXT}; border: none; "
            f"border-bottom: 1px solid {theme.DESK_LINE}; padding: 7px 8px; font-weight: bold; }} "
            f"QTreeWidget::item {{ padding: 0 4px; }} "
            f"QTreeWidget::item:selected, QTreeWidget::item:selected:!active {{ background: rgba(247,196,92,52); "
            f"color: {theme.DESK_TEXT}; }}")
        self.empty_note = QWidget()
        note_column = QVBoxLayout(self.empty_note)
        note_column.addStretch(1)
        self.empty_label = muted("", 14)
        self.empty_label.setAlignment(Qt.AlignCenter)
        note_column.addWidget(self.empty_label)
        self.show_all_key = HardwareKey(tr("Show all sounds"))
        self.show_all_key.clicked.connect(self.show_all)
        note_column.addWidget(self.show_all_key, 0, Qt.AlignHCenter)
        note_column.addStretch(2)
        holder = QWidget()
        stack = QVBoxLayout(holder)
        stack.setContentsMargins(0, 0, 0, 0)
        stack.setSpacing(0)
        stack.addWidget(self.table, 1)
        stack.addWidget(self.empty_note, 1)
        self.empty_note.hide()
        return holder

    def _preview_area(self) -> QWidget:
        self.preview_scroll = QScrollArea()
        self.preview_scroll.setFixedWidth(332)
        self.preview_scroll.setWidgetResizable(True)
        self.preview_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.preview_scroll.setStyleSheet(f"QScrollArea {{ border: none; border-left: 1px solid {theme.DESK_LINE}; }}")
        self.preview = QWidget()
        self.preview_column = QVBoxLayout(self.preview)
        self.preview_column.setContentsMargins(16, 14, 16, 16)
        self.preview_column.setSpacing(10)
        self.preview_scroll.setWidget(self.preview)
        return self.preview_scroll

    def _status_line(self) -> QWidget:
        line = QFrame()
        line.setObjectName("statusline")
        line.setStyleSheet(f"QFrame#statusline {{ border-top: 1px solid {theme.DESK_LINE}; }}")
        row = QHBoxLayout(line)
        row.setContentsMargins(18, 6, 18, 6)
        self.status_label = muted("", 12)
        self.status_label.setWordWrap(False)
        row.addWidget(self.status_label)
        self.unreadable_key = QPushButton("")
        self.unreadable_key.setFlat(True)
        self.unreadable_key.setFont(theme.sans(12))
        self.unreadable_key.setStyleSheet(f"QPushButton {{ color: {theme.DANGER_TEXT}; border: none; "
                                          f"background: transparent; padding: 0 8px; }}")
        self.unreadable_key.clicked.connect(lambda: self.reveal.emit(None))
        row.addWidget(self.unreadable_key)
        row.addStretch(1)
        keys = muted("   ".join([tr("Return hear"), tr("Ctrl+Return open"), tr("Ctrl+K to listen"), tr("Ctrl+T tag"),
                                 tr("Ctrl+/ all keys")]), 12)
        keys.setWordWrap(False)
        keys.setFont(theme.mono(11))
        row.addWidget(keys)
        return line

    # MARK: State from outside

    def set_items(self, items: list[SavedPreset], unreadable: list[str] | None = None) -> None:
        self.items = list(items)
        self.unreadable = list(unreadable or [])
        self.close_sets = q.close_groups(self.items)
        self.close_paths = {i.path for group in self.close_sets for i in group}
        known = {t.casefold() for i in self.items for t in i.tags}
        amps = {q.amp_model(i.preset) or "" for i in self.items}
        # Filters on tags and amps that no sound has any more are dropped.
        self.filters = {f for f in self.filters if f[0] not in ("tag", "amp") or
                        (f[0] == "tag" and f[1].casefold() in known) or (f[0] == "amp" and f[1] in amps)}
        self.refresh(rebuild_filters=True)

    def set_grouping(self, grouping: str, emit: bool = False) -> None:
        self.grouping = grouping if grouping in q.GROUPINGS else q.NONE
        self.group_tabs.set_index(q.GROUPINGS.index(self.grouping))
        self.refresh()
        if emit:
            self.grouping_changed.emit(self.grouping)

    def next_grouping(self) -> None:
        self.set_grouping(q.next_grouping(self.grouping), emit=True)

    def set_filters(self, filters: set[tuple]) -> None:
        self.filters = set(filters)
        self.refresh(rebuild_filters=True)

    def show_all(self) -> None:
        self.search.clear()
        self.set_filters(set())

    def focus_search(self) -> None:
        self.search.setFocus()
        self.search.selectAll()

    def focus_filters(self) -> None:
        self.filter_list.setFocus()

    def focus_table(self) -> None:
        self.table.setFocus()
        if not self.table.selectedItems():
            first = self.table._first_row()
            if first is not None:
                self.table.setCurrentItem(first)

    def focus_tags(self) -> None:
        if getattr(self, "tag_field", None) is not None:
            self.tag_field.setFocus()

    @property
    def query(self) -> q.LibraryQuery:
        query = q.LibraryQuery(search=self.search.text())
        query.scope = next((s for s in q.SCOPES if ("scope", s) in self.filters), q.ALL)
        for kind, value in self.filters:
            if kind == "origin":
                query.origins.add(value)
            elif kind == "amp":
                query.amps.add(value)
            elif kind == "tag":
                query.tags.append(value)
        query.tags.sort(key=str.casefold)
        return query

    def shown_names(self) -> list[str]:
        return [item.name for item in self._rows.values()]

    # MARK: The groups and rows

    def _sort_key(self, item: SavedPreset):
        column = COLUMNS[self.sort_column]
        if column == "saved":
            return item.saved_at.timestamp()
        if column == "amp":
            return q.amp_name(q.amp_model(item.preset)).casefold()
        if column == "tags":
            return tags_text(item).casefold()
        if column == "origin":
            return item.origin.casefold()
        if column == "chain":
            return chain_summary(item.preset).casefold()
        return item.name.casefold()

    def groups(self) -> list[q.Group]:
        query = self.query
        shown = query.apply(self.items, self.close_paths)
        if query.scope == q.CLOSE:
            # Close sounds stand in their groups, whatever the grouping, or they could not be told apart.
            wanted = {i.path for i in shown}
            result = []
            for index, group in enumerate(self.close_sets):
                members = [i for i in group if i.path in wanted]
                if len(members) > 1:
                    result.append(q.Group(f"close:{index}", tr("Close to “{}”", members[0].name), members))
        else:
            result = q.groups(self.grouping, shown, leaving=query.tags)
        for group in result:
            group.items = sorted(group.items, key=self._sort_key, reverse=self.descending)
        return result

    def refresh(self, rebuild_filters: bool = False) -> None:
        selected = self.selected_row_ids()
        current = self.table.currentItem()
        current_id = current.data(0, ROW_ROLE) if current is not None else None
        groups = self.groups()
        self._building = True
        self.table.clear()
        self._rows = {}
        grouped = len(groups) > 1 or (groups and groups[0].title)
        shown_paths = set()
        for group in groups:
            parent = None
            if grouped:
                parent = QTreeWidgetItem([f"{group.title}   {len(group.items)}"])
                parent.setFlags(Qt.ItemIsEnabled)
                self.table.addTopLevelItem(parent)
                parent.setFirstColumnSpanned(True)
            for item in group.items:
                row = QTreeWidgetItem(["", "", q.amp_name(q.amp_model(item.preset)), tags_text(item), item.origin,
                                       short_date_time(item.saved_at)])
                row.setData(0, PATH_ROLE, str(item.path))
                row.setData(0, ROW_ROLE, f"{group.id}\n{item.path}")
                row.setData(0, Qt.AccessibleTextRole, ", ".join(
                    [item.name] + ([tr("favorite")] if item.favorite else []) +
                    ([tr("to listen")] if q.needs_listen(item) else [])))
                row.setForeground(3, c(theme.AMBER))
                row.setForeground(5, c(theme.DESK_MUTED))
                row.setToolTip(0, item.notes or item.name)
                (parent.addChild(row) if parent is not None else self.table.addTopLevelItem(row))
                self._rows[id(row)] = item
                shown_paths.add(item.path)
            if parent is not None:
                parent.setExpanded(True)
        # The selection survives a refresh, row by row, or by the sound when its group is gone.
        wanted_paths = {rid.split("\n", 1)[-1] for rid in selected}
        found_paths = set()
        for row in self._all_rows():
            if row.data(0, ROW_ROLE) in selected:
                row.setSelected(True)
                found_paths.add(row.data(0, PATH_ROLE))
        for row in self._all_rows():
            path = row.data(0, PATH_ROLE)
            if path in wanted_paths and path not in found_paths:
                row.setSelected(True)
                found_paths.add(path)
            if row.data(0, ROW_ROLE) == current_id:
                self.table.setCurrentItem(row, 0, QItemSelectionModel.NoUpdate)
        self._building = False
        everything = [i for i in self.items if not i.is_backup]
        shown = len(shown_paths)
        self.count_label.setText(tr("{} SOUNDS", len(everything)) if not self.query.is_filtering and
                                 self.query.scope == q.ALL else tr("{} OF {} SOUNDS", shown, len(everything)))
        nothing = not self._rows
        self.table.setVisible(not nothing)
        self.empty_note.setVisible(nothing)
        if nothing:
            self.empty_label.setText(tr("No sounds yet. Save a slot, create a new one or import sounds from the "
                                        "Kemper.") if not self.items else tr("No sound matches."))
            self.show_all_key.setVisible(bool(self.items))
        listen = sum(1 for i in everything if q.needs_listen(i))
        groups_text = (tr("1 group of close sounds") if len(self.close_sets) == 1
                       else tr("{} groups of close sounds", len(self.close_sets)))
        self.status_label.setText(f"{tr('{} to listen', listen)} · {groups_text}")
        self.unreadable_key.setVisible(bool(self.unreadable))
        self.unreadable_key.setText(tr("1 file unreadable") if len(self.unreadable) == 1
                                    else tr("{} files unreadable", len(self.unreadable)))
        if rebuild_filters:
            self._fill_filters()
        self._selection_changed()

    def _all_rows(self):
        for index in range(self.table.topLevelItemCount()):
            top = self.table.topLevelItem(index)
            if top.childCount():
                for child in range(top.childCount()):
                    yield top.child(child)
            elif id(top) in self._rows:
                yield top

    def item_at(self, index) -> SavedPreset | None:
        row = self.table.itemFromIndex(index.siblingAtColumn(0))
        return self._rows.get(id(row)) if row is not None else None

    def selected_row_ids(self) -> set[str]:
        return {row.data(0, ROW_ROLE) for row in self.table.selectedItems() if row.data(0, ROW_ROLE)}

    def selected_items(self) -> list[SavedPreset]:
        """The selected sounds, each once, in the library's order."""
        paths = {row.data(0, PATH_ROLE) for row in self.table.selectedItems()}
        return [i for i in self.items if str(i.path) in paths]

    def select_paths(self, paths: list[Path]) -> None:
        wanted = {str(p) for p in paths}
        self.table.clearSelection()
        first = None
        for row in self._all_rows():
            if row.data(0, PATH_ROLE) in wanted:
                row.setSelected(True)
                wanted.discard(row.data(0, PATH_ROLE))
                first = first or row
        if first is not None:
            self.table.setCurrentItem(first, 0, QItemSelectionModel.NoUpdate)
            self.table.scrollToItem(first)

    def _header_clicked(self, column: int) -> None:
        if column == self.sort_column:
            self.descending = not self.descending
        else:
            self.sort_column, self.descending = column, COLUMNS[column] == "saved"
        self.table.header().setSortIndicator(column, Qt.DescendingOrder if self.descending else Qt.AscendingOrder)
        self.refresh()

    # MARK: Filters

    def _fill_filters(self) -> None:
        self._building = True
        lst = self.filter_list
        lst.clear()

        def section(title: str) -> None:
            entry = QListWidgetItem(title)
            entry.setFlags(Qt.NoItemFlags)
            lst.addItem(entry)

        def add(title: str, filter_: tuple, count: int | None) -> None:
            entry = QListWidgetItem(title)
            entry.setData(FILTER_ROLE, filter_)
            entry.setData(COUNT_ROLE, count)
            entry.setToolTip(title)
            lst.addItem(entry)
            if filter_ in self.filters:
                entry.setSelected(True)

        sounds = [i for i in self.items if not i.is_backup]
        section(tr("Show"))
        counts = {q.ALL: len(sounds), q.FAVORITES: sum(i.favorite for i in sounds),
                  q.TO_LISTEN: sum(q.needs_listen(i) for i in sounds), q.CLOSE: len(self.close_paths),
                  q.BACKUPS: sum(i.is_backup for i in self.items)}
        for scope in q.SCOPES:
            add(q.scope_title(scope), ("scope", scope), counts[scope])
        origins: dict[str, int] = {}
        for item in sounds:
            origin = q.origin_of(item)
            origins[origin] = origins.get(origin, 0) + 1
        section(tr("Origin"))
        for origin in q.ORIGINS:
            if origin in origins:
                add(q.origin_title(origin), ("origin", origin), origins[origin])
        amps: dict[str, int] = {}
        for item in sounds:
            model = q.amp_model(item.preset) or ""
            amps[model] = amps.get(model, 0) + 1
        section(tr("Amp"))
        for model in sorted(amps, key=lambda m: (q.amp_name(m) or tr("No amp")).casefold()):
            add(q.amp_name(model) or tr("No amp"), ("amp", model), amps[model])
        tags: dict[str, list] = {}
        for item in sounds:
            for tag in item.tags:
                if tag.casefold() != q.LISTEN_TAG:
                    tags.setdefault(tag.casefold(), [tag, 0])[1] += 1
        if tags:
            section(tr("Tags"))
            filtered = {f[1].casefold() for f in self.filters if f[0] == "tag"}
            pinned = {t.casefold() for t in self.pinned}
            ordered = sorted(tags.values(), key=lambda e: (-e[1], e[0].casefold()))
            common = [e for e in ordered if e[1] > 1 or e[0].casefold() in pinned | filtered]
            rare = [e for e in ordered if e not in common]
            for tag, count in common:
                add(("📌 " if tag.casefold() in pinned else "") + f"#{tag}", ("tag", tag), count)
            if rare:
                if self.show_rare_tags:
                    for tag, count in rare:
                        add(f"#{tag}", ("tag", tag), count)
                else:
                    add(tr("1 tag used once") if len(rare) == 1 else tr("{} tags used once", len(rare)),
                        ("more", ""), None)
        self._building = False

    def _filters_chosen(self) -> None:
        if self._building:
            return
        chosen = [entry.data(FILTER_ROLE) for entry in self.filter_list.selectedItems()]
        if ("more", "") in chosen:
            self.show_rare_tags = True
            self.filter_list.blockSignals(True)
            self._fill_filters()
            self.filter_list.blockSignals(False)
            return
        # One scope at a time; "All sounds" is the same as none.
        scopes = [f for f in chosen if f[0] == "scope"]
        newest = next((f for f in scopes if f not in self.filters), scopes[-1] if scopes else None)
        self.filters = {f for f in chosen if f[0] != "scope"} | ({newest} if newest and newest[1] != q.ALL else set())
        if newest is not None and len(scopes) > 1:
            self.refresh(rebuild_filters=True)
        else:
            self.refresh()

    def _filter_menu(self, pos) -> None:
        entry = self.filter_list.itemAt(pos)
        filter_ = entry.data(FILTER_ROLE) if entry is not None else None
        if not filter_ or filter_[0] != "tag":
            return
        tag = filter_[1]
        menu = QMenu(self)
        pinned = tag.casefold() in (t.casefold() for t in self.pinned)
        menu.addAction(tr("Unpin from the sidebar") if pinned else tr("Pin to the sidebar"), lambda: self.pin.emit(tag))
        menu.exec(self.filter_list.mapToGlobal(pos))

    # MARK: Acting

    def _hear_first_match(self) -> None:
        rows = list(self._all_rows())
        if not rows:
            return
        if not self.table.selectedItems():
            self.table.setCurrentItem(rows[0])
        self._hear_selected()

    def _hear_selected(self) -> None:
        items = self.selected_items()
        if items:
            self.hear.emit(items[0])

    def open_selected(self) -> None:
        items = self.selected_items()
        if items:
            self.open_item.emit(items[0])

    def eventFilter(self, obj, event):
        if obj is self.search and event.type() == QEvent.KeyPress and event.key() == Qt.Key_Down:
            self.focus_table()
            return True
        return super().eventFilter(obj, event)

    def _row_menu(self, pos) -> None:
        items = self.selected_items()
        if not items:
            return
        menu = QMenu(self)
        if len(items) == 1:
            menu.addAction(tr("Hear on the amp"), lambda: self.hear.emit(items[0]))
            menu.addAction(tr("Open in the editor"), lambda: self.open_item.emit(items[0]))
            menu.addSeparator()
        all_favorite = all(i.favorite for i in items)
        menu.addAction(tr("Remove from favorites") if all_favorite else tr("Add to favorites"),
                       lambda: self.favorite.emit(items, not all_favorite))
        all_listen = all(q.needs_listen(i) for i in items)
        menu.addAction(tr("Mark as listened to") if all_listen else tr("Mark to listen to"),
                       lambda: self.listen.emit(items, not all_listen))
        menu.addAction(tr("Add a tag …"), self.focus_tags)
        menu.addSeparator()
        menu.addAction(tr("Rename …") if len(items) == 1 else tr("Rename {} sounds …", len(items)),
                       lambda: self.rename.emit(items))
        menu.addAction(tr("Show in file manager"), lambda: self.reveal.emit(items[0]))
        menu.addSeparator()
        menu.addAction(tr("Move to Trash") if len(items) == 1 else tr("Move {} sounds to the Trash", len(items)),
                       lambda: self.trash.emit(items))
        menu.exec(self.table.viewport().mapToGlobal(pos))

    # MARK: The preview

    def _selection_changed(self) -> None:
        if self._building:
            return
        while self.preview_column.count():
            entry = self.preview_column.takeAt(0)
            if entry.widget():
                entry.widget().deleteLater()
            elif entry.layout():
                _clear(entry.layout())
        self.tag_field = None
        items = self.selected_items()
        if not items:
            note = muted(tr("Choose a sound to see it here."), 13)
            note.setAlignment(Qt.AlignCenter)
            self.preview_column.addStretch(1)
            self.preview_column.addWidget(note)
            self.preview_column.addStretch(2)
            return
        if len(items) == 1:
            self._single(items[0])
        else:
            self._several(items)
        self.preview_column.addStretch(1)

    def _card(self, title: str, subtitle: str, preset=None) -> QVBoxLayout:
        card = QFrame()
        card.setObjectName("card")
        card.setStyleSheet(f"QFrame#card {{ background: qlineargradient(x1:0, y1:0, x2:0, y2:1, "
                           f"stop:0 {theme.PANEL_TOP}, stop:1 {theme.PANEL_BOTTOM}); border: 1px solid #000; "
                           f"border-radius: 12px; }}")
        column = QVBoxLayout(card)
        column.setContentsMargins(16, 14, 16, 14)
        column.setSpacing(8)
        name = QLabel(title)
        name.setWordWrap(True)
        name.setFont(theme.sans(22, bold=True))
        name.setStyleSheet(f"color: {theme.AMBER};")
        column.addWidget(name)
        if subtitle:
            sub = QLabel(subtitle)
            sub.setWordWrap(True)
            sub.setFont(theme.sans(12))
            sub.setStyleSheet(f"color: {theme.TEXT_DIM};")
            column.addWidget(sub)
        if preset is not None:
            column.addWidget(_ChainStrip(preset))
        self.preview_column.addWidget(card)
        return column

    def _single(self, item: SavedPreset) -> None:
        card = self._card(item.name, chain_summary(item.preset), item.preset)
        lamps = QHBoxLayout()
        lamps.setSpacing(16)
        lamps.addWidget(Lamp(tr("Favorite"), "amber", item.favorite))
        lamps.addWidget(Lamp(tr("To listen"), "amber", q.needs_listen(item)))
        lamps.addStretch(1)
        card.addLayout(lamps)
        keys = QHBoxLayout()
        keys.setSpacing(8)
        hear = HardwareKey(tr("Hear"), "primary", "↩")
        hear.setToolTip(tr("Plays the sound on the amp's temporary place. No slot changes."))
        hear.clicked.connect(lambda: self.hear.emit(item))
        opener = HardwareKey(tr("Edit"), keycap=tr("Ctrl+↩"))
        opener.setToolTip(tr("Opens the sound in the editor and closes the library"))
        opener.clicked.connect(lambda: self.open_item.emit(item))
        keys.addWidget(hear)
        keys.addWidget(opener)
        keys.addStretch(1)
        card.addLayout(keys)

        facts = QGridLayout()
        facts.setHorizontalSpacing(14)
        facts.setVerticalSpacing(6)
        row = 0
        if len(item.preset.effects) == len(catalog.PLACES):
            cat = catalog.load()
            for place, effect in zip(catalog.PLACES, item.preset.effects):
                name = cat.info(effect.name, len(effect.parameters)).name
                facts.addWidget(caption(catalog.PLACE_SHORT[place]), row, 0)
                value = QLabel(name if effect.is_on else tr("{} (off)", name))
                value.setStyleSheet(f"color: {theme.DESK_TEXT if effect.is_on else theme.DESK_MUTED};")
                facts.addWidget(value, row, 1)
                row += 1
        for title, text in ((tr("Origin"), item.origin or q.origin_title(q.origin_of(item))),
                            (tr("Saved"), date_time(item.saved_at)), (tr("Tempo"), f"{item.preset.bpm:.0f} BPM")):
            facts.addWidget(caption(title), row, 0)
            value = QLabel(text)
            value.setWordWrap(True)
            facts.addWidget(value, row, 1)
            row += 1
        facts.setColumnStretch(1, 1)
        self.preview_column.addLayout(facts)

        if not item.is_backup:
            marks = QHBoxLayout()
            favorite = QCheckBox(tr("Favorite"))
            favorite.setChecked(item.favorite)
            favorite.toggled.connect(lambda on: self.favorite.emit([item], on))
            listen = QCheckBox(tr("To listen"))
            listen.setChecked(q.needs_listen(item))
            listen.toggled.connect(lambda on: self.listen.emit([item], on))
            marks.addWidget(favorite)
            marks.addWidget(listen)
            marks.addStretch(1)
            self.preview_column.addLayout(marks)
            self._tag_editor([item])
            self.preview_column.addWidget(caption(tr("Notes")))
            notes = NotesEdit(item.notes)
            notes.setPlaceholderText(tr("Where the sound comes from, what it suits, what to try"))
            notes.setFixedHeight(80)
            notes.setStyleSheet(f"QPlainTextEdit {{ background: {theme.FIELD}; border: 1px solid {theme.FIELD_EDGE}; "
                                f"border-radius: 8px; padding: 4px; color: {theme.FIELD_TEXT}; }}")
            notes.finished.connect(lambda text: text != item.notes and self.notes.emit(item, text))
            self.preview_column.addWidget(notes)
            self._close_sounds(item)
        self._pieces([item])

    def _several(self, items: list[SavedPreset]) -> None:
        amps = {q.amp_model(i.preset) for i in items}
        card = self._card(tr("{} sounds selected", len(items)),
                          tr("all on one amp") if len(amps) == 1 else tr("on {} amps", len(amps)))
        keys = QHBoxLayout()
        keys.setSpacing(8)
        rename = HardwareKey(tr("Rename …"), keycap=tr("Ctrl+E"))
        rename.clicked.connect(lambda: self.rename.emit(items))
        trash = HardwareKey(tr("To the Trash"), "danger")
        trash.clicked.connect(lambda: self.trash.emit(items))
        keys.addWidget(rename)
        keys.addWidget(trash)
        keys.addStretch(1)
        card.addLayout(keys)
        sounds = [i for i in items if not i.is_backup]
        if sounds:
            marks = QHBoxLayout()
            for title, state, signal in ((tr("Favorite"), [i.favorite for i in sounds], self.favorite),
                                         (tr("To listen"), [q.needs_listen(i) for i in sounds], self.listen)):
                box = QCheckBox(title)
                box.setTristate(False)
                box.setCheckState(Qt.Checked if all(state) else Qt.PartiallyChecked if any(state) else Qt.Unchecked)
                box.clicked.connect(lambda _=False, s=state, sig=signal: sig.emit(sounds, not all(s)))
                marks.addWidget(box)
            marks.addStretch(1)
            self.preview_column.addLayout(marks)
            self._tag_editor(sounds)
        self._pieces(items)

    def _tag_editor(self, items: list[SavedPreset]) -> None:
        self.preview_column.addWidget(caption(tr("Tags")))
        counts: dict[str, list] = {}
        for item in items:
            for tag in item.tags:
                if tag.casefold() != q.LISTEN_TAG:
                    counts.setdefault(tag.casefold(), [tag, 0])[1] += 1
        if counts:
            box = QWidget()
            flow = FlowLayout(box, spacing=6)
            pinned = {t.casefold() for t in self.pinned}
            for tag, count in counts.values():
                label = ("📌 " if tag.casefold() in pinned else "") + f"#{tag}"
                if len(items) > 1:
                    label += f"  {count}/{len(items)}"
                chip = QPushButton(label + "  ×")
                chip.setFont(theme.sans(11))
                chip.setCursor(Qt.PointingHandCursor)
                chip.setToolTip(tr("Removes #{} from the selected sounds", tag))
                chip.setStyleSheet("QPushButton { border: none; border-radius: 9px; padding: 3px 9px; "
                                   f"background: #2A2A2E; color: {theme.DESK_TEXT}; }}")
                chip.clicked.connect(lambda _=False, t=tag: self.remove_tag.emit(items, t))
                flow.addWidget(chip)
            self.preview_column.addWidget(box)
        field = QLineEdit()
        field.setPlaceholderText(tr("Add #tag") if len(items) == 1 else tr("Add #tag to all"))
        field.returnPressed.connect(lambda: parse_tags(field.text()) and self.add_tags.emit(items, parse_tags(field.text())))
        self.preview_column.addWidget(field)
        self.tag_field = field

    def _close_sounds(self, item: SavedPreset) -> None:
        near = q.neighbours(item, [i for i in self.items if not i.is_backup])
        if not near:
            return
        self.preview_column.addWidget(caption(tr("Close sounds")))
        for other, comparison in near[:6]:
            if comparison.is_equal:
                detail = tr("The same sound")
            else:
                detail = tr("Differs in {}", ", ".join(catalog.PLACE_SHORT[p] for p in comparison.differing))
            key = QPushButton(f"{other.name}\n{detail}")
            key.setFont(theme.sans(12))
            key.setCursor(Qt.PointingHandCursor)
            key.setToolTip(tr("Selects “{}”", other.name))
            key.setStyleSheet(f"QPushButton {{ text-align: left; padding: 6px 10px; background: {theme.DESK_ALT}; "
                              f"border: 1px solid {theme.DESK_LINE}; border-radius: 8px; }}")
            key.clicked.connect(lambda _=False, path=other.path: self.select_paths([path]))
            self.preview_column.addWidget(key)

    def _pieces(self, items: list[SavedPreset]) -> None:
        uses = sorted({use for item in items for use in self.pieces_for(item)}, key=str.casefold)
        self.preview_column.addWidget(caption(tr("Used in pieces")))
        if not uses:
            self.preview_column.addWidget(muted(tr("No piece uses this sound.") if len(items) == 1
                                                else tr("No piece uses these sounds.")))
            return
        for use in uses[:12]:
            line = QLabel(f"♪  {use}")
            line.setWordWrap(True)
            self.preview_column.addWidget(line)
        if len(uses) > 12:
            self.preview_column.addWidget(muted(f"+ {len(uses) - 12}"))


class _ChainStrip(QWidget):
    def __init__(self, preset, parent=None):
        super().__init__(parent)
        self.preset = preset
        self.setFixedHeight(22)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        paint_chain(p, QRectF(0, 0, min(self.width(), 220), self.height()), self.preset, 18)


def _clear(layout) -> None:
    while layout.count():
        entry = layout.takeAt(0)
        if entry.widget():
            entry.widget().deleteLater()
        elif entry.layout():
            _clear(entry.layout())
