"""Puts the library overlay into the main window and does what it asks: hearing and opening sounds, favorites, the
mark "To listen", tags and notes for several sounds at once, renaming, the Trash with undo, the sounds used last and
the menu "Sounds". The Mac's counterpart is Sources/SparkPresetsUI/Model/PresetsModel+Browser.swift.

Grouping and the sounds used last are remembered on this computer only for the real presets folder; a test folder
(`--presets-folder`, `--demo`, the tests) neither reads nor changes them.
"""
from __future__ import annotations

import re
from pathlib import Path

from PySide6.QtCore import QSettings, Qt
from PySide6.QtWidgets import (QDialog, QDialogButtonBox, QFormLayout, QLabel, QLineEdit, QListWidget, QMessageBox,
                               QVBoxLayout)

from .. import library_query as q
from .. import protocol
from ..i18n import tr
from ..library import LibraryError, SavedPreset, default_folder, normalized_tags
from .library_overlay import LibraryOverlay

RECENT_KEY = "recentPresets"
GROUPING_KEY = "libraryGrouping"


class LibraryController:
    def __init__(self, window):
        self.window = window
        self.overlay = LibraryOverlay()
        window.presets_page.addWidget(self.overlay)
        try:
            self.remembers = Path(window.library.folder).resolve() == default_folder().resolve()
        except OSError:
            self.remembers = False
        self._settings = QSettings("local.ampbench", "AmpBench")
        self.recent: list[str] = []
        if self.remembers:
            stored = self._settings.value(RECENT_KEY) or []
            self.recent = [stored] if isinstance(stored, str) else list(stored)
            self.overlay.set_grouping(str(self._settings.value(GROUPING_KEY) or q.NONE))
        window.sidebar.recent_keys = self.recent
        o = self.overlay
        o.pieces_for = self.pieces_for
        o.close_requested.connect(self.close)
        o.hear.connect(self.hear)
        o.open_item.connect(self.open_item)
        o.favorite.connect(lambda items, on: self._change(items, favorite=on))
        o.listen.connect(self.set_listen)
        o.add_tags.connect(self.add_tags)
        o.remove_tag.connect(self.remove_tag)
        o.notes.connect(lambda item, text: self._change([item], notes=text, quiet=True))
        o.rename.connect(self.rename)
        o.trash.connect(self.trash)
        o.reveal.connect(window._reveal)
        o.pin.connect(self.toggle_pin)
        o.grouping_changed.connect(self._grouping_changed)
        window.sidebar.library_requested.connect(self.open)

    # MARK: Open and close

    @property
    def is_open(self) -> bool:
        return self.window.presets_page.currentWidget() is self.overlay

    def open(self, filters=None) -> None:
        """Opens the library over the area Presets, with these filters when given; the search has the keyboard."""
        if self.window.stack.currentIndex() != 1:
            self.window._area(1)
        if filters is not None:
            self.overlay.search.clear()
            self.overlay.set_filters(set(filters))
        self.window.presets_page.setCurrentWidget(self.overlay)
        self.overlay.focus_search()

    def close(self) -> None:
        if self.is_open:
            self.window.presets_page.setCurrentIndex(0)
            self.window.sidebar.search.setFocus()

    def toggle(self) -> None:
        self.close() if self.is_open else self.open()

    def show_item(self, item: SavedPreset) -> None:
        """Opens the library on all sounds with `item` chosen."""
        self.open(set())
        self.overlay.select_paths([item.path])
        self.overlay.focus_table()

    def library_changed(self) -> None:
        self.overlay.pinned = list(self.window.sidebar.pinned)
        self.overlay.set_items(self.window.library.items, self.window.library.unreadable)

    def pieces_for(self, item: SavedPreset) -> list[str]:
        recorder = self.window.recorder
        return q.pieces_using(recorder.store.document if recorder is not None else None, item)

    # MARK: The menu

    def add_menu(self, bar, action) -> None:
        menu = bar.addMenu(tr("Sounds"))
        action(menu, tr("Sound library"), self.toggle, "Ctrl+L")
        action(menu, tr("Search sounds"), self.open)
        menu.addSeparator()
        action(menu, tr("Hear on the amp"), lambda: self._on_selection(lambda items: self.hear(items[0])))
        action(menu, tr("Open in the editor"), lambda: self.is_open and self.overlay.open_selected(), "Ctrl+Return")
        action(menu, tr("Favorite on or off"), self.toggle_favorite, "Ctrl+Shift+F")
        action(menu, tr("To listen on or off"), self.toggle_listen, "Ctrl+K")
        action(menu, tr("Add a tag …"), self.focus_tags)
        menu.addSeparator()
        action(menu, tr("Next grouping"), lambda: self.is_open and self.overlay.next_grouping(), "Ctrl+G")
        action(menu, tr("Go to the filters"), lambda: self.is_open and self.overlay.focus_filters())

    def targets(self) -> list[SavedPreset]:
        """What the menu acts on: the library's selection while it is open, otherwise the sound in the editor."""
        if self.is_open:
            return self.overlay.selected_items()
        source = self.window.source
        return [source[1]] if source and source[0] == "file" else []

    def _on_selection(self, act) -> None:
        items = self.targets()
        if items:
            act(items)

    def focus_tags(self) -> None:
        if not self.is_open:
            self.window._edit_tags()
            return
        self.overlay.focus_tags()

    # MARK: Hearing and opening

    def hear(self, item: SavedPreset) -> None:
        """Plays the sound on the amp's temporary place: no slot changes, the editor keeps what it holds."""
        core = self.window.link.core
        if not (self.window.link.is_connected and core.can("play_temporary")):
            self.window._say("warning", tr("Connect the amp to hear the sound."))
            return
        self.window.run(core.try_out(item.preset.copy()))

    def open_item(self, item: SavedPreset) -> None:
        self.close()
        self.window._item_clicked(item)

    def remember(self, item: SavedPreset) -> None:
        key = item.id or item.path.name
        self.recent[:] = ([key] + [k for k in self.recent if k != key])[:15]
        if self.remembers:
            self._settings.setValue(RECENT_KEY, self.recent)

    # MARK: Marks, tags and notes

    def toggle_favorite(self) -> None:
        items = [i for i in self.targets() if not i.is_backup]
        if items:
            self._change(items, favorite=not all(i.favorite for i in items))

    def toggle_listen(self) -> None:
        items = [i for i in self.targets() if not i.is_backup]
        if items:
            self.set_listen(items, not all(q.needs_listen(i) for i in items))

    def set_listen(self, items: list[SavedPreset], on: bool) -> None:
        changed = self._change(items, tags=lambda i: q.with_listen(i.tags, on), quiet=True)
        if not changed:
            return
        if len(changed) == 1:
            text = tr("“{}” is marked to listen to.", changed[0]) if on else tr("“{}” is marked as listened to.",
                                                                               changed[0])
        else:
            text = (tr("{} sounds are marked to listen to.", len(changed)) if on
                    else tr("{} sounds are marked as listened to.", len(changed)))
        self.window._say("success", text)

    def add_tags(self, items: list[SavedPreset], tags: list[str]) -> None:
        self._change(items, tags=lambda i: normalized_tags(i.tags + tags), quiet=True)
        self.overlay.focus_tags()

    def remove_tag(self, items: list[SavedPreset], tag: str) -> None:
        self._change(items, tags=lambda i: [t for t in i.tags if t.casefold() != tag.casefold()], quiet=True)

    def _change(self, items: list[SavedPreset], favorite=None, tags=None, notes=None, quiet=False) -> list[str]:
        """Writes the change into every sound that takes it (never a slot backup), reloads once, and says which
        could not be changed. Returns the names of those changed."""
        library = self.window.library
        changed, failed = [], []
        for item in items:
            if item.is_backup:
                continue
            try:
                library.update_meta(item, favorite=favorite, tags=tags(item) if callable(tags) else tags,
                                    notes=notes, reloads=False)
                changed.append(item.name)
            except (OSError, LibraryError):
                failed.append(item.name)
        library.reload()
        self._follow_source()
        self.window._refresh_library()
        if failed:
            self.window._say("warning", tr("These sounds could not be changed: {}", ", ".join(failed)))
        return changed

    def _follow_source(self, renamed: dict | None = None) -> None:
        """The editor's file again after a reload, under its new path when it was renamed; None when it is gone."""
        window = self.window
        if not (window.source and window.source[0] == "file"):
            return
        path = (renamed or {}).get(window.source[1].path, window.source[1].path)
        found = next((i for i in window.library.items if i.path == path), None)
        if found is None:
            window.editor, window.source = None, None
            return
        window.source = ("file", found)
        if window.editor is not None and found.name != window.editor.original.name:
            window.editor.current.name = found.name
            window.editor.original.name = found.name

    def toggle_pin(self, tag: str) -> None:
        self.window.sidebar.toggle_pin(tag)
        self.overlay.pinned = list(self.window.sidebar.pinned)
        self.overlay.refresh(rebuild_filters=True)

    def _grouping_changed(self, grouping: str) -> None:
        if self.remembers:
            self._settings.setValue(GROUPING_KEY, grouping)

    # MARK: Renaming

    def rename(self, items: list[SavedPreset]) -> None:
        if len(items) == 1:
            self.window._rename(items[0])
            return
        dialog = RenameDialog(items, self.window)
        if dialog.exec() != QDialog.Accepted:
            return
        library, renamed, failed, moved = self.window.library, [], [], {}
        plan = [step for step in dialog.plan() if step[1] != step[0].name]
        for item, name, problem in plan:
            if problem:
                failed.append(item.name)
                continue
            try:
                new = library.rename(item, name)
                moved[item.path] = new.path
                renamed.append(new)
            except (OSError, LibraryError):
                failed.append(item.name)
        self._follow_source(moved)
        self.window._refresh_library()
        self.window._refresh_editor()
        self.overlay.select_paths([i.path for i in renamed])
        text = tr("1 sound renamed.") if len(renamed) == 1 else tr("{} sounds renamed.", len(renamed))
        if failed:
            text = tr("{} sounds renamed. Not renamed: {}", len(renamed), ", ".join(failed))
        self.window._say("warning" if failed else "success", text)

    # MARK: The Trash

    def trash(self, items: list[SavedPreset]) -> None:
        if not items:
            return
        uses = sorted({use for item in items for use in self.pieces_for(item)}, key=str.casefold)
        question = (tr("Move “{}” to the Trash?", items[0].name) if len(items) == 1
                    else tr("Move {} sounds to the Trash?", len(items)))
        if uses:
            question += "\n\n" + tr("Pieces use them: {}. The pieces keep the sound's name and show it as missing.",
                                    ", ".join(uses))
        if QMessageBox.question(self.window, "AmpBench", question, QMessageBox.Yes | QMessageBox.Cancel,
                                QMessageBox.Cancel) != QMessageBox.Yes:
            return
        library, moved, failed = self.window.library, [], []
        for item in items:
            try:
                moved.append((library.trash(item, reloads=False), item.path))
            except (OSError, LibraryError):
                failed.append(item.name)
        library.reload()
        self._follow_source()
        self.window._refresh_library()
        self.window._refresh_editor()
        done = len(moved)
        text = (tr("“{}” is in the Trash.", items[0].name) if len(items) == 1 and done == 1
                else tr("{} sounds are in the Trash.", done))
        if failed:
            text = tr("{} sounds are in the Trash. Not moved: {}", done, ", ".join(failed))
        restorable = [(where, path) for where, path in moved if isinstance(where, Path)]
        undo = (lambda: self._restore(restorable)) if restorable and len(restorable) == done else None
        self.window._say("warning" if failed else "success", text, undo)

    def _restore(self, moved: list[tuple[Path, Path]]) -> None:
        from .. import trash
        back = []
        for where, path in moved:
            try:
                back.append(trash.restore(where, path))
            except OSError as error:
                self.window._report(error)
        self.window.library.reload()
        self.window._refresh_library()
        self.overlay.select_paths(back)


class RenameDialog(QDialog):
    """Several sounds renamed at once by replacing a text in their names, with the new names before anything
    happens. A name the amp would not take (empty, or too long) stays as it is."""

    def __init__(self, items: list[SavedPreset], parent=None):
        super().__init__(parent)
        self.items = items
        self.setWindowTitle(tr("Rename {} sounds", len(items)))
        self.setMinimumWidth(480)
        column = QVBoxLayout(self)
        form = QFormLayout()
        self.find = QLineEdit()
        self.find.setPlaceholderText(tr("Type a text that the names contain."))
        self.replace = QLineEdit()
        self.replace.setPlaceholderText(tr("New text, or nothing to remove it"))
        form.addRow(tr("Text in the names"), self.find)
        form.addRow(tr("Replace with"), self.replace)
        column.addLayout(form)
        self.summary = QLabel("")
        column.addWidget(self.summary)
        self.preview = QListWidget()
        self.preview.setMinimumHeight(220)
        column.addWidget(self.preview)
        self.buttons = QDialogButtonBox(QDialogButtonBox.Cancel)
        self.go = self.buttons.addButton(tr("Rename {} sounds", len(items)), QDialogButtonBox.AcceptRole)
        self.buttons.accepted.connect(self.accept)
        self.buttons.rejected.connect(self.reject)
        column.addWidget(self.buttons)
        self.find.textChanged.connect(lambda _: self._update())
        self.replace.textChanged.connect(lambda _: self._update())
        self._update()

    def plan(self) -> list[tuple[SavedPreset, str, str | None]]:
        find = self.find.text()
        result = []
        for item in self.items:
            if not find:
                result.append((item, item.name, None))
                continue
            name = re.sub(re.escape(find), lambda _m: self.replace.text(), item.name, flags=re.IGNORECASE)
            result.append((item, name, protocol.name_problem(name) if name != item.name else None))
        return result

    def _update(self) -> None:
        plan = self.plan()
        changing = [step for step in plan if step[1] != step[0].name]
        self.preview.clear()
        for item, name, problem in plan:
            text = f"{item.name}  →  {name}" if name != item.name else item.name
            if problem:
                text += f"   ({problem})"
            self.preview.addItem(text)
            if name == item.name:
                self.preview.item(self.preview.count() - 1).setForeground(Qt.gray)
        good = [step for step in changing if not step[2]]
        self.summary.setText(tr("{} names change.", len(good)))
        self.go.setEnabled(bool(good))
