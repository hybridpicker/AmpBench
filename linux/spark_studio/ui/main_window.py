"""The window: the amp's slots and the presets on this computer on the left, the editor on the right."""
from __future__ import annotations

import json
from pathlib import Path

from PySide6.QtCore import QObject, Qt, QTimer, Signal
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtWidgets import (QApplication, QComboBox, QFileDialog, QFrame, QHBoxLayout, QInputDialog, QLabel,
                               QLineEdit, QListWidget, QListWidgetItem, QMainWindow, QMenu, QMessageBox, QProgressBar,
                               QPushButton, QSpinBox, QVBoxLayout, QWidget)

from .. import BUILD, VERSION, catalog, factory, protocol, recipe
from ..editor import PresetEditor
from ..library import LibraryError, PresetLibrary, SavedPreset
from ..link import LinkError
from ..qtlink import QtLink
from . import theme
from .widgets import Knob, Lamp, Pedal

STATUS_TEXT = {
    "off": "Getrennt", "searching": "Suche den Verstärker …", "connecting": "Verbinde …", "connected": "Verbunden",
    "bluetooth_off": "Bluetooth ist aus", "unsupported": "Kein Bluetooth gefunden", "starting": "Starte …",
}


class _Bridge(QObject):
    """Brings results from the link's thread back into the UI thread."""
    finished = Signal(object, object, object, object)

    def __init__(self):
        super().__init__()
        self.finished.connect(self._run)

    @staticmethod
    def _run(on_ok, on_err, result, error):
        if error is not None:
            if on_err:
                on_err(error)
        elif on_ok:
            on_ok(result)


def section(text: str) -> QLabel:
    label = QLabel(text.upper())
    label.setObjectName("section")
    return label


class MainWindow(QMainWindow):
    def __init__(self, link: QtLink, library: PresetLibrary, auto_connect: bool = True):
        super().__init__()
        self.link, self.library = link, library
        self.editor: PresetEditor | None = None
        self.source: tuple[str, object] | None = None  # ("slot", n) or ("file", SavedPreset) or ("new", None)
        self.place = 3
        self._bridge = _Bridge()
        self._loading = False
        self._library_stamp = None
        self.setWindowTitle("Spark Studio")
        self.resize(1180, 760)
        self.setMinimumSize(940, 620)
        self._build()
        self._menus()
        self._wire()
        self.library.reload()
        self._fill_library()
        self._refresh_all()
        if auto_connect:
            QTimer.singleShot(200, self.link.start)

    # MARK: Building

    def _build(self) -> None:
        root = QWidget()
        root.setObjectName("root")
        self.setCentralWidget(root)
        layout = QHBoxLayout(root)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.addWidget(self._build_sidebar())
        layout.addWidget(self._build_editor(), 1)
        self.progress = QProgressBar()
        self.progress.setFixedWidth(160)
        self.progress.setTextVisible(False)
        self.progress.hide()
        self.activity_label = QLabel("")
        bar = self.statusBar()
        bar.addWidget(self.activity_label, 1)
        bar.addPermanentWidget(self.progress)
        self.version_label = QLabel(f"Version {VERSION} ({BUILD})")
        bar.addPermanentWidget(self.version_label)

    def _build_sidebar(self) -> QWidget:
        side = QFrame()
        side.setObjectName("sidebar")
        side.setFixedWidth(300)
        box = QVBoxLayout(side)
        box.setContentsMargins(14, 14, 14, 14)
        box.setSpacing(8)

        status_row = QHBoxLayout()
        self.lamp = Lamp()
        self.status_label = QLabel("Getrennt")
        self.status_label.setObjectName("title")
        status_row.addWidget(self.lamp)
        status_row.addWidget(self.status_label, 1)
        box.addLayout(status_row)
        self.device_label = QLabel("")
        self.device_label.setObjectName("muted")
        box.addWidget(self.device_label)
        self.connect_button = QPushButton("Verbinden")
        self.connect_button.setObjectName("primary")
        box.addWidget(self.connect_button)

        box.addSpacing(6)
        box.addWidget(section("Verstärker"))
        self.slot_list = QListWidget()
        self.slot_list.setFixedHeight(4 * 34 + 6)
        for slot in range(4):
            self.slot_list.addItem(QListWidgetItem(f"{slot + 1}   –"))
        box.addWidget(self.slot_list)
        slot_hint = QLabel("Klick: bearbeiten · Doppelklick: spielen")
        slot_hint.setObjectName("muted")
        box.addWidget(slot_hint)

        box.addSpacing(6)
        box.addWidget(section("Auf diesem Computer"))
        self.search = QLineEdit()
        self.search.setPlaceholderText("Suchen")
        self.search.setClearButtonEnabled(True)
        box.addWidget(self.search)
        self.library_list = QListWidget()
        box.addWidget(self.library_list, 1)
        self.library_note = QLabel("")
        self.library_note.setObjectName("muted")
        self.library_note.setWordWrap(True)
        box.addWidget(self.library_note)
        row = QHBoxLayout()
        self.new_button = QPushButton("Neu")
        self.duplicate_button = QPushButton("Duplizieren")
        row.addWidget(self.new_button)
        row.addWidget(self.duplicate_button)
        box.addLayout(row)
        return side

    def _build_editor(self) -> QWidget:
        page = QWidget()
        outer = QVBoxLayout(page)
        outer.setContentsMargins(18, 16, 18, 12)
        outer.setSpacing(12)

        self.empty_label = QLabel("Wähle links ein Preset oder lege ein neues an.")
        self.empty_label.setObjectName("muted")
        self.empty_label.setAlignment(Qt.AlignCenter)
        outer.addWidget(self.empty_label, 1)

        self.editor_box = QWidget()
        box = QVBoxLayout(self.editor_box)
        box.setContentsMargins(0, 0, 0, 0)
        box.setSpacing(12)
        outer.addWidget(self.editor_box, 1)

        header = QFrame()
        header.setObjectName("card")
        h = QVBoxLayout(header)
        h.setContentsMargins(14, 12, 14, 12)
        top = QHBoxLayout()
        self.name_edit = QLineEdit()
        self.name_edit.setMaxLength(60)
        self.name_edit.setStyleSheet("font-size: 17px; font-weight: 600;")
        self.bpm_spin = QSpinBox()
        self.bpm_spin.setRange(40, 250)
        self.bpm_spin.setSuffix(" BPM")
        self.bpm_spin.setKeyboardTracking(False)
        top.addWidget(self.name_edit, 1)
        top.addWidget(self.bpm_spin)
        h.addLayout(top)
        self.source_label = QLabel("")
        self.source_label.setObjectName("muted")
        h.addWidget(self.source_label)
        buttons = QHBoxLayout()
        self.live_button = QPushButton("Live am Verstärker")
        self.live_button.setCheckable(True)
        self.live_button.setToolTip("Spielt das Preset auf dem Verstärker und schickt jede Änderung sofort (Strg+Umschalt+L)")
        self.try_button = QPushButton("Ausprobieren")
        self.undo_button = QPushButton("Rückgängig")
        self.redo_button = QPushButton("Wiederholen")
        self.save_button = QPushButton("Sichern")
        self.save_button.setObjectName("primary")
        self.to_amp_button = QPushButton("Auf den Verstärker ▾")
        for b in (self.live_button, self.try_button, self.undo_button, self.redo_button):
            buttons.addWidget(b)
        buttons.addStretch(1)
        buttons.addWidget(self.to_amp_button)
        buttons.addWidget(self.save_button)
        h.addLayout(buttons)
        box.addWidget(header)

        chain = QHBoxLayout()
        chain.setSpacing(8)
        self.pedals: list[Pedal] = []
        for index, place in enumerate(catalog.PLACES):
            pedal = Pedal(index, place)
            pedal.selected.connect(self._select_place)
            pedal.toggled.connect(self._toggle_place)
            self.pedals.append(pedal)
            chain.addWidget(pedal)
        box.addLayout(chain)

        unit = QFrame()
        unit.setObjectName("card")
        u = QVBoxLayout(unit)
        u.setContentsMargins(14, 12, 14, 12)
        u.setSpacing(10)
        head = QHBoxLayout()
        self.unit_title = QLabel("")
        self.unit_title.setObjectName("title")
        self.model_combo = QComboBox()
        self.model_combo.setMinimumWidth(260)
        head.addWidget(self.unit_title)
        head.addStretch(1)
        head.addWidget(self.model_combo)
        u.addLayout(head)
        self.unit_summary = QLabel("")
        self.unit_summary.setObjectName("muted")
        self.unit_summary.setWordWrap(True)
        u.addWidget(self.unit_summary)
        self.knob_row = QHBoxLayout()
        self.knob_row.setSpacing(14)
        u.addLayout(self.knob_row)
        u.addStretch(1)
        box.addWidget(unit, 1)
        return page

    def _menus(self) -> None:
        def action(menu, text, slot, shortcut=None):
            a = QAction(text, self)
            if shortcut:
                a.setShortcut(QKeySequence(shortcut))
            a.triggered.connect(slot)
            menu.addAction(a)
            return a

        preset = self.menuBar().addMenu("Preset")
        new_menu = preset.addMenu("Neu aus Vorlage")
        action(new_menu, "Leeres Preset", lambda: self._new(None), "Ctrl+N")
        new_menu.addSeparator()
        for template in factory.templates():
            action(new_menu, f"{template.name} – {template.summary}", lambda _=False, t=template: self._new(t))
        action(preset, "Duplizieren", self._duplicate, "Ctrl+D")
        preset.addSeparator()
        action(preset, "Sichern", self._save, "Ctrl+S")
        action(preset, "Sichern unter neuem Namen …", self._save_as, "Ctrl+Shift+S")
        action(preset, "Als Rezept speichern …", self._export_recipe)
        action(preset, "Rezept öffnen …", self._open_recipe)
        preset.addSeparator()
        action(preset, "In den Papierkorb", self._trash, "Ctrl+Backspace")
        preset.addSeparator()
        action(preset, "Beenden", self.close, "Ctrl+Q")

        edit = self.menuBar().addMenu("Bearbeiten")
        action(edit, "Rückgängig", self._undo, "Ctrl+Z")
        action(edit, "Wiederholen", self._redo, "Ctrl+Shift+Z")
        action(edit, "Auf den gesicherten Stand zurück", self._revert)

        amp = self.menuBar().addMenu("Verstärker")
        action(amp, "Mit dem Verstärker verbinden", self.link.start)
        action(amp, "Trennen", self.link.stop)
        action(amp, "Verstärker neu lesen", self._reread, "Ctrl+R")
        action(amp, "Live am Verstärker", lambda: self.live_button.click(), "Ctrl+Shift+L")
        amp.addSeparator()
        for slot in range(4):
            action(amp, f"Platz {slot + 1} spielen", lambda _=False, s=slot: self._play_slot(s), f"Ctrl+{slot + 1}")
        amp.addSeparator()
        for slot in range(4):
            action(amp, f"Auf Platz {slot + 1} speichern …", lambda _=False, s=slot: self._store(s),
                   f"Ctrl+Alt+{slot + 1}")

        help_menu = self.menuBar().addMenu("Hilfe")
        action(help_menu, "Über Spark Studio", self._about)

    def _wire(self) -> None:
        link = self.link
        link.status.connect(self._on_status)
        link.device_name.connect(lambda _: self._refresh_connection())
        link.firmware.connect(lambda _: self._refresh_connection())
        link.active_slot.connect(lambda _: self._refresh_slots())
        link.slots.connect(lambda _: self._refresh_slots())
        link.trying_out.connect(lambda _: self._refresh_activity())
        link.is_editing_live.connect(self._on_live_changed)
        link.activity.connect(lambda _: self._refresh_activity())
        link.transfer.connect(self._on_transfer)
        link.amp_selected.connect(self._on_amp_selected)
        link.amp_event.connect(self._on_amp_event)
        link.live_failed.connect(lambda text: self._say(text))
        link.strain.connect(lambda: self._say("Der Verstärker antwortet langsam. Änderungen gehen jetzt gemächlicher."))

        self.connect_button.clicked.connect(self._connect_clicked)
        self.slot_list.currentRowChanged.connect(self._slot_clicked)
        self.slot_list.itemDoubleClicked.connect(lambda item: self._play_slot(self.slot_list.row(item)))
        self.library_list.itemSelectionChanged.connect(self._library_clicked)
        self.search.textChanged.connect(lambda _: self._fill_library())
        self.new_button.clicked.connect(self._new_menu)
        self.duplicate_button.clicked.connect(self._duplicate)
        self.name_edit.editingFinished.connect(self._name_edited)
        self.bpm_spin.valueChanged.connect(self._bpm_edited)
        self.live_button.toggled.connect(self._live_toggled)
        self.try_button.clicked.connect(self._try_out)
        self.undo_button.clicked.connect(self._undo)
        self.redo_button.clicked.connect(self._redo)
        self.save_button.clicked.connect(self._save)
        self.to_amp_button.clicked.connect(self._to_amp_menu)
        self.model_combo.activated.connect(self._model_chosen)

    # MARK: Link state

    def _on_status(self, status: str) -> None:
        self._refresh_connection()
        if status == "connected":
            self._say("Verbunden.")

    def _refresh_connection(self) -> None:
        core = self.link.core
        status = core.status
        self.status_label.setText(STATUS_TEXT.get(status, status))
        colors = {"connected": theme.GOOD, "searching": theme.ACCENT, "connecting": theme.ACCENT,
                  "bluetooth_off": theme.BAD, "unsupported": theme.BAD}
        self.lamp.set_lit(status in colors, colors.get(status))
        parts = [p for p in (core.device_name, f"Firmware {core.firmware}" if core.firmware else None) if p]
        self.device_label.setText(" · ".join(parts))
        self.connect_button.setText("Trennen" if status in ("connected", "connecting", "searching") else "Verbinden")
        connected = status == "connected"
        for b in (self.live_button, self.try_button, self.to_amp_button):
            b.setEnabled(connected and self.editor is not None)
        self.slot_list.setEnabled(True)

    def _refresh_slots(self) -> None:
        core = self.link.core
        for slot in range(4):
            preset = core.slots[slot]
            name = preset.name if preset else "–"
            active = "●  " if core.active_slot == slot else "    "
            self.slot_list.item(slot).setText(f"{active}{slot + 1}   {name}")
        self._refresh_activity()

    def _refresh_activity(self) -> None:
        core = self.link.core
        text = core.activity or (f"Probiert: {core.trying_out}" if core.trying_out else "")
        self.activity_label.setText(text)

    def _on_transfer(self, transfer) -> None:
        if transfer is None or transfer.fraction is None:
            self.progress.setVisible(transfer is not None)
            self.progress.setRange(0, 0 if transfer is not None else 1)
            return
        self.progress.setRange(0, 100)
        self.progress.setValue(int(transfer.fraction * 100))
        self.progress.show()

    def _on_live_changed(self, live: bool) -> None:
        self.live_button.blockSignals(True)
        self.live_button.setChecked(live)
        self.live_button.blockSignals(False)

    def _on_amp_selected(self, slot: int) -> None:
        name = self.link.core.slots[slot].name if self.link.core.slots[slot] else ""
        self._say(f"Am Verstärker gewählt: Platz {slot + 1} {name}".strip())

    def _on_amp_event(self, event) -> None:
        """The amp reports a knob turned on the amp itself; the editor follows while it plays live."""
        if self.editor is None or not self.link.core.is_editing_live:
            return
        self.editor.follow(event)
        self._refresh_editor(keep_focus=True)

    def _say(self, text: str) -> None:
        self.statusBar().showMessage(text, 6000)

    def _report(self, error: Exception) -> None:
        text = str(error) if isinstance(error, (LinkError, LibraryError, recipe.RecipeError)) else f"{type(error).__name__}: {error}"
        QMessageBox.warning(self, "Spark Studio", text)

    def run(self, coroutine, on_ok=None, on_err=None) -> None:
        self.link.call(coroutine, lambda r, e: self._bridge.finished.emit(on_ok, on_err or self._report, r, e))

    # MARK: Sidebar actions

    def _connect_clicked(self) -> None:
        if self.link.core.status in ("connected", "connecting", "searching"):
            self.link.stop()
        else:
            self.link.start()

    def _slot_clicked(self, row: int) -> None:
        if row < 0 or self._loading:
            return
        preset = self.link.core.slots[row]
        if preset is None:
            return
        self.library_list.clearSelection()
        self._open(preset.copy(), ("slot", row))

    def _play_slot(self, slot: int) -> None:
        if not self.link.is_connected:
            self._say("Der Verstärker ist nicht verbunden.")
            return
        self.run(self.link.core.select(slot))

    def _fill_library(self) -> None:
        needle = self.search.text().strip().casefold()
        self.library_list.blockSignals(True)
        self.library_list.clear()
        shown = 0
        for item in self.library.items:
            if item.is_backup:
                continue
            haystack = " ".join([item.name, *item.tags, item.notes]).casefold()
            if needle and needle not in haystack:
                continue
            marker = "★ " if item.favorite else ""
            suffix = "   (Rezept)" if item.is_recipe else ""
            entry = QListWidgetItem(f"{marker}{item.name}{suffix}")
            entry.setData(Qt.UserRole, str(item.path))
            self.library_list.addItem(entry)
            shown += 1
        backups = sum(1 for i in self.library.items if i.is_backup)
        note = []
        if backups:
            note.append(f"{backups} Sicherung{'en' if backups != 1 else ''} im Ordner")
        if self.library.unreadable:
            note.append(f"{len(self.library.unreadable)} Datei(en) nicht lesbar")
        self.library_note.setText(" · ".join(note))
        self.library_list.blockSignals(False)
        self._select_in_library()

    def _select_in_library(self) -> None:
        if not self.source or self.source[0] != "file":
            return
        path = str(self.source[1].path)
        self.library_list.blockSignals(True)
        for row in range(self.library_list.count()):
            if self.library_list.item(row).data(Qt.UserRole) == path:
                self.library_list.setCurrentRow(row)
        self.library_list.blockSignals(False)

    def _library_clicked(self) -> None:
        items = self.library_list.selectedItems()
        if not items:
            return
        path = items[0].data(Qt.UserRole)
        saved = next((i for i in self.library.items if str(i.path) == path), None)
        if saved is None:
            return
        self.slot_list.blockSignals(True)
        self.slot_list.clearSelection()
        self.slot_list.setCurrentRow(-1)
        self.slot_list.blockSignals(False)
        self._open(saved.preset.copy(), ("file", saved))

    def _new_menu(self) -> None:
        menu = QMenu(self)
        menu.addAction("Leeres Preset", lambda: self._new(None))
        menu.addSeparator()
        for template in factory.templates():
            menu.addAction(f"{template.name} – {template.summary}", lambda t=template: self._new(t))
        menu.exec(self.new_button.mapToGlobal(self.new_button.rect().bottomLeft()))

    # MARK: Opening and editing

    def _confirm_discard(self) -> bool:
        if self.editor is None or not self.editor.is_modified:
            return True
        box = QMessageBox(QMessageBox.Question, "Spark Studio",
                          f"„{self.editor.current.name}“ hat ungesicherte Änderungen.", parent=self)
        save = box.addButton("Sichern", QMessageBox.AcceptRole)
        discard = box.addButton("Verwerfen", QMessageBox.DestructiveRole)
        box.addButton("Abbrechen", QMessageBox.RejectRole)
        box.exec()
        if box.clickedButton() is save:
            return self._save()
        return box.clickedButton() is discard

    def _open(self, preset: protocol.Preset, source, unsaved: bool = False) -> None:
        if self.editor is not None and not self._loading and self.source != source and not self._confirm_discard():
            self._restore_selection()
            return
        self.editor = PresetEditor(preset)
        if unsaved:
            self.editor.mark_unsaved()
        self.source = source
        self.place = 3 if len(preset.effects) == 7 else 0
        self._refresh_all()
        if self.live_button.isChecked() and self.link.is_connected:
            self.run(self.link.core.play_for_editing(preset.copy()))

    def _restore_selection(self) -> None:
        self.slot_list.blockSignals(True)
        self.library_list.blockSignals(True)
        self.slot_list.setCurrentRow(self.source[1] if self.source and self.source[0] == "slot" else -1)
        self.library_list.clearSelection()
        self.slot_list.blockSignals(False)
        self.library_list.blockSignals(False)
        self._select_in_library()

    def _new(self, template) -> None:
        if not self._confirm_discard():
            return
        preset = factory.empty() if template is None else factory.make(template)
        self.source = None
        self._open(preset, ("new", None), unsaved=True)

    def _duplicate(self) -> None:
        if self.editor is None:
            return
        self._open(factory.duplicate(self.editor.current), ("new", None), unsaved=True)

    def _refresh_all(self) -> None:
        self._refresh_connection()
        self._refresh_slots()
        self._refresh_editor()

    def _refresh_editor(self, keep_focus: bool = False) -> None:
        has = self.editor is not None
        self.editor_box.setVisible(has)
        self.empty_label.setVisible(not has)
        for b in (self.duplicate_button,):
            b.setEnabled(has)
        if not has:
            return
        ed = self.editor
        self._loading = True
        try:
            preset = ed.current
            if not self.name_edit.hasFocus():
                self.name_edit.setText(preset.name)
            self.bpm_spin.setValue(int(round(preset.bpm)))
            self._refresh_source_label()
            self.undo_button.setEnabled(ed.can_undo)
            self.redo_button.setEnabled(ed.can_redo)
            self.save_button.setEnabled(ed.is_modified or self.source is None or self.source[0] != "file")
            seven = len(preset.effects) == 7
            cat = catalog.load()
            for index, pedal in enumerate(self.pedals):
                pedal.setVisible(seven and index < len(preset.effects))
                if seven:
                    effect = preset.effects[index]
                    pedal.set_state(cat.info(effect.name, len(effect.parameters)).name, effect.is_on,
                                    index == self.place)
            self._build_unit(keep_focus)
        finally:
            self._loading = False
        self._refresh_connection()

    def _refresh_source_label(self) -> None:
        ed = self.editor
        where = {"slot": lambda s: f"Platz {s + 1} am Verstärker", "file": lambda s: "Auf diesem Computer",
                 "new": lambda s: "Neu, noch nirgends gesichert"}[self.source[0]](self.source[1] if self.source[0] == "slot" else None)
        if self.source[0] == "file" and self.source[1].is_recipe:
            where = "Rezept (als Preset gelesen)"
        self.source_label.setText(where + ("  ·  geändert" if ed.is_modified else ""))

    def _select_place(self, index: int) -> None:
        self.place = index
        self._refresh_editor()

    def _build_unit(self, keep_focus: bool) -> None:
        while self.knob_row.count():
            item = self.knob_row.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        preset = self.editor.current
        if self.place >= len(preset.effects):
            self.place = 0
        effect = preset.effects[self.place]
        cat = catalog.load()
        info = cat.info(effect.name, len(effect.parameters))
        place_key = catalog.PLACES[self.place] if len(preset.effects) == 7 else info.place
        color = theme.place_color(place_key)
        self.unit_title.setText(catalog.PLACE_TITLES.get(place_key, place_key))
        self.unit_summary.setText(info.summary + (f"  ·  nach dem Vorbild von {info.inspiration}" if info.inspiration else "")
                                  + ("  ·  Zusatzpaket" if info.pack else ""))
        self.model_combo.blockSignals(True)
        self.model_combo.clear()
        models = cat.models_for(place_key)
        if all(m.id != effect.name for m in models):
            models = [info, *models]
        for model in models:
            group = f"  ({model.group})" if model.group and place_key == "amp" else ""
            self.model_combo.addItem(model.name + group, model.id)
            self.model_combo.setItemData(self.model_combo.count() - 1, model.summary, Qt.ToolTipRole)
        self.model_combo.setCurrentIndex(max(self.model_combo.findData(effect.name), 0))
        self.model_combo.blockSignals(False)
        for parameter in effect.parameters:
            pinfo = info.parameter(parameter.index)
            if not pinfo.visible:
                continue
            start = info.defaults[parameter.index] if parameter.index < len(info.defaults) else None
            self.knob_row.addWidget(self._parameter_widget(parameter, pinfo, start, color))
        self.knob_row.addStretch(1)

    def _parameter_widget(self, parameter, pinfo, start, color) -> QWidget:
        place = self.place
        index = parameter.index
        if pinfo.kind == "knob":
            knob = Knob(pinfo.label, color, start)
            knob.set_value(parameter.value)
            knob.gesture_started.connect(self.editor.begin_gesture)
            knob.gesture_ended.connect(lambda: (self.editor.end_gesture(), self._after_edit()))
            knob.changed.connect(lambda v, p=place, i=index: self._edited(self.editor.set_parameter(p, i, v)))
            return knob
        block = QWidget()
        block.setFixedSize(110, 104)
        v = QVBoxLayout(block)
        v.setContentsMargins(0, 6, 0, 0)
        v.setSpacing(6)
        if pinfo.kind == "switch":
            button = QPushButton(pinfo.on if parameter.value >= 0.5 else pinfo.off)
            button.setCheckable(True)
            button.setChecked(parameter.value >= 0.5)

            def toggled(on, p=place, i=index, b=button, info=pinfo):
                b.setText(info.on if on else info.off)
                self._edited(self.editor.set_parameter(p, i, 1.0 if on else 0.0))
                self._after_edit()
            button.toggled.connect(toggled)
            v.addWidget(button)
        else:
            combo = QComboBox()
            for label, value in pinfo.options:
                combo.addItem(label, value)
            nearest = min(range(len(pinfo.options)), key=lambda k: abs(pinfo.options[k][1] - parameter.value))
            combo.setCurrentIndex(nearest)

            def chosen(_, p=place, i=index, c=combo):
                self._edited(self.editor.set_parameter(p, i, c.currentData()))
                self._after_edit()
            combo.activated.connect(chosen)
            v.addWidget(combo)
        label = QLabel(pinfo.label)
        label.setObjectName("muted")
        label.setAlignment(Qt.AlignCenter)
        v.addWidget(label)
        v.addStretch(1)
        return block

    def _edited(self, changes) -> None:
        if self.live_button.isChecked():
            self.link.push_live(changes)
        self._update_flags()

    def _after_edit(self) -> None:
        self._update_flags()

    def _update_flags(self) -> None:
        ed = self.editor
        if ed is None:
            return
        self.undo_button.setEnabled(ed.can_undo)
        self.redo_button.setEnabled(ed.can_redo)
        self.save_button.setEnabled(ed.is_modified or self.source is None or self.source[0] != "file")
        self._refresh_source_label()

    def _toggle_place(self, index: int, on: bool) -> None:
        if self.editor is None:
            return
        self._edited(self.editor.set_on(index, on))
        self._refresh_editor()

    def _model_chosen(self, row: int) -> None:
        if self.editor is None:
            return
        model_id = self.model_combo.itemData(row)
        self._edited(self.editor.set_model(self.place, model_id))
        self._refresh_editor()

    def _name_edited(self) -> None:
        if self.editor is None or self._loading:
            return
        self.editor.set_name(self.name_edit.text().strip() or self.editor.current.name)
        self._update_flags()

    def _bpm_edited(self, value: int) -> None:
        if self.editor is None or self._loading:
            return
        self._edited(self.editor.set_bpm(value))

    def _undo(self) -> None:
        if self.editor:
            self._edited(self.editor.undo())
            self._refresh_editor()

    def _redo(self) -> None:
        if self.editor:
            self._edited(self.editor.redo())
            self._refresh_editor()

    def _revert(self) -> None:
        if self.editor:
            self._edited(self.editor.revert())
            self._refresh_editor()

    # MARK: Amp actions

    def _live_toggled(self, on: bool) -> None:
        if self.editor is None:
            return
        if not on:
            self.link.core.end_editing()
            self._say("Live aus. Das Preset spielt weiter, bis du einen Platz wählst.")
            return
        if not self.link.is_connected:
            self._on_live_changed(False)
            self._say("Der Verstärker ist nicht verbunden.")
            return
        self.run(self.link.core.play_for_editing(self.editor.current.copy()), on_err=self._live_failed)

    def _live_failed(self, error: Exception) -> None:
        self._on_live_changed(False)
        self._report(error)

    def _try_out(self) -> None:
        if self.editor:
            self.run(self.link.core.try_out(self.editor.current.copy()))

    def _reread(self) -> None:
        if self.link.is_connected:
            self.run(self.link.core.load_all())

    def _to_amp_menu(self) -> None:
        menu = QMenu(self)
        for slot in range(4):
            existing = self.link.core.slots[slot]
            label = f"Platz {slot + 1}" + (f"  (jetzt: {existing.name})" if existing else "")
            menu.addAction(label, lambda s=slot: self._store(s))
        menu.exec(self.to_amp_button.mapToGlobal(self.to_amp_button.rect().bottomLeft()))

    def _store(self, slot: int) -> None:
        if self.editor is None or not self.link.is_connected:
            self._say("Dazu muss ein Preset offen und der Verstärker verbunden sein.")
            return
        problem = protocol.name_problem(self.editor.current.name)
        if problem:
            QMessageBox.warning(self, "Spark Studio", problem)
            return
        old = self.link.core.slots[slot]
        answer = QMessageBox.question(
            self, "Spark Studio",
            f"„{self.editor.current.name}“ auf Platz {slot + 1} speichern?\n\n"
            + (f"Das jetzige Preset „{old.name}“ wird vorher gesichert und liegt dann auf diesem Computer."
               if old else "Der Platz wird überschrieben."),
            QMessageBox.Yes | QMessageBox.Cancel, QMessageBox.Cancel)
        if answer != QMessageBox.Yes:
            return
        preset = self.editor.current.copy()
        self.run(self.link.core.current_preset(slot), lambda current: self._store_step2(preset, slot, current))

    def _store_step2(self, preset: protocol.Preset, slot: int, current: protocol.Preset) -> None:
        try:
            if self.library.existing(current) is None:
                device = self.link.core.device_name or "Spark"
                self.library.save(current, f"Platz {slot + 1} · {device}", is_backup=True)
                self._fill_library()
        except (OSError, LibraryError) as error:
            self._report(error)
            return  # no backup, no overwrite
        self.run(self.link.core.store(preset, slot), lambda _: self._stored(slot))

    def _stored(self, slot: int) -> None:
        if self.editor:
            self.editor.mark_saved()
            self.source = ("slot", slot)
        self._refresh_editor()
        self._say(f"Auf Platz {slot + 1} gespeichert und zurückgelesen.")

    # MARK: Library actions

    def _save(self) -> bool:
        if self.editor is None:
            return True
        problem = protocol.name_problem(self.editor.current.name)
        if problem:
            QMessageBox.warning(self, "Spark Studio", problem)
            return False
        try:
            if self.source and self.source[0] == "file":
                saved = self.library.replace(self.source[1], self.editor.current)
            else:
                origin = f"Platz {self.source[1] + 1} · {self.link.core.device_name or 'Spark'}" \
                    if self.source and self.source[0] == "slot" else "Spark Studio"
                saved = self.library.save(self.editor.current, origin)
        except (OSError, LibraryError) as error:
            self._report(error)
            return False
        self.editor.mark_saved()
        self.source = ("file", saved)
        self._fill_library()
        self._refresh_editor()
        self._say(f"„{saved.name}“ gesichert.")
        return True

    def _save_as(self) -> None:
        if self.editor is None:
            return
        name, ok = QInputDialog.getText(self, "Sichern unter neuem Namen", "Name:", text=self.editor.current.name)
        if not ok:
            return
        name = name.strip()
        problem = protocol.name_problem(name)
        if problem:
            QMessageBox.warning(self, "Spark Studio", problem)
            return
        copy = factory.duplicate(self.editor.current, name)
        try:
            saved = self.library.save(copy, "Spark Studio")
        except (OSError, LibraryError) as error:
            self._report(error)
            return
        self.editor = PresetEditor(copy)
        self.source = ("file", saved)
        self._fill_library()
        self._refresh_editor()

    def _trash(self) -> None:
        if not self.source or self.source[0] != "file":
            return
        item: SavedPreset = self.source[1]
        if QMessageBox.question(self, "Spark Studio", f"„{item.name}“ in den Papierkorb legen?",
                                QMessageBox.Yes | QMessageBox.Cancel, QMessageBox.Cancel) != QMessageBox.Yes:
            return
        try:
            self.library.trash(item)
        except (OSError, LibraryError) as error:
            self._report(error)
            return
        self.editor, self.source = None, None
        self._fill_library()
        self._refresh_editor()

    def _export_recipe(self) -> None:
        if self.editor is None:
            return
        path, _ = QFileDialog.getSaveFileName(self, "Als Rezept speichern", f"{self.editor.current.name}.json",
                                              "Sound-Rezept (*.json)")
        if not path:
            return
        try:
            data = recipe.from_preset(self.editor.current)
            Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
        except (OSError, recipe.RecipeError) as error:
            self._report(error)

    def _open_recipe(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "Rezept öffnen", str(self.library.folder), "Sound-Rezept (*.json)")
        if not path:
            return
        try:
            raw = Path(path).read_bytes()
            conversion = recipe.to_preset(json.loads(raw), raw)
        except (OSError, ValueError, recipe.RecipeError) as error:
            self._report(error)
            return
        self._open(conversion.preset, ("new", None), unsaved=True)
        if conversion.warnings:
            QMessageBox.information(self, "Spark Studio", "\n".join(conversion.warnings))

    def changeEvent(self, event):
        if event.type() == event.Type.ActivationChange and self.isActiveWindow():
            stamp = self.library.folder.stat().st_mtime if self.library.folder.exists() else None
            if stamp != self._library_stamp:
                self._library_stamp = stamp
                self.library.reload()
                self._fill_library()
        super().changeEvent(event)

    def _about(self) -> None:
        QMessageBox.about(self, "Spark Studio", f"Spark Studio {VERSION} ({BUILD}) für Linux\n\n"
                          "Der Bereich Presets der Mac-App: Verstärker lesen, Presets bearbeiten, live hören und "
                          f"sichern.\nKatalog: {catalog.load().checked_on}")

    def closeEvent(self, event):
        if not self._confirm_discard():
            event.ignore()
            return
        self.link.shutdown()
        super().closeEvent(event)
