"""The window: the deck on top, the sidebar and the editor of the area Presets below.

The behavior follows the Mac app (Sources/SparkPresetsUI): selecting a slot plays it, a preset from the computer plays
on the temporary place, the first change of a session sends the whole preset, A/B compares with the saved state.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from PySide6.QtCore import QEvent, QObject, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QAction, QDesktopServices, QKeySequence
from PySide6.QtWidgets import (QAbstractButton, QAbstractSpinBox, QApplication, QDialog, QFileDialog, QFrame, QHBoxLayout,
                               QInputDialog, QLabel,
                               QLineEdit, QMainWindow, QMenu, QMessageBox, QPlainTextEdit, QStackedWidget, QTextEdit,
                               QToolButton, QVBoxLayout, QWidget)

from .. import BUILD, VERSION, catalog, devices, factory, protocol, recipe
from ..editor import PresetEditor
from ..library import LibraryError, PresetLibrary, SavedPreset
from ..link import LinkError
from ..qtlink import QtLink
from ..store import parse_iso
from . import theme
from .deck import Deck
from .recordings import RecordingsPage
from .sidebar import Sidebar
from .theme import c
from .widgets import (Display, DeviceSwitch, Engraving, Footswitch, Front, HardwareKey, Knob, LEDSegments, Lamp,
                      Pedal, SegmentTabs)

GROUPS = {"clean": "Clean", "bright": "Brillant", "crunch": "Crunch", "highGain": "High Gain", "metal": "Metal",
          "acoustic": "Akustik", "bass": "Bass"}
STATUS_TEXT = {
    "off": "Getrennt", "searching": "Suche …", "connecting": "Verbinde …", "connected": "Verbunden",
    "bluetooth_off": "Bluetooth aus", "unsupported": "Kein Bluetooth", "starting": "Starte …",
}
SHORTCUTS = [
    ("R", "Aufnahme starten oder beenden"), ("Leertaste", "Abspielen oder anhalten, während der Aufnahme: beenden und abspielen"),
    ("L / M", "Schleife A, B, löschen / Marker setzen"), ("1 – 5 / F", "Bewertung / Favorit"), ("Strg+F", "Suchen"), ("K / Rücktaste", "Take behalten / in den Papierkorb"),
    ("← →", "5 Sekunden springen, mit Umschalt 1 Sekunde"), ("- + 0", "Langsamer, schneller / Tempo und Ton zurücksetzen"), ("Strg+1 – 4", "Platz am Verstärker spielen"), ("Strg+Z / Umschalt+Strg+Z", "Rückgängig / Wiederholen"),
    ("Strg+S", "Preset sichern"), ("Umschalt+Strg+S", "Sichern unter neuem Namen"), ("Strg+N / Umschalt+Strg+N", "Neues Preset / aus Vorlage"),
    ("Strg+D", "Duplizieren"), ("Strg+Alt+1 – 4", "Auf Platz 1 bis 4 speichern"), ("Strg+B", "Mit dem gesicherten Stand vergleichen (A/B)"),
    ("Umschalt+Strg+L", "Live am Verstärker ein oder aus"), ("Strg+R", "Verstärker neu lesen"),
    ("Alt+1 – 7", "Einheit der Kette wählen"), ("Alt+0", "Gewählte Einheit ein oder aus"),
    ("Pfeile am Regler", "Regler drehen, mit Umschalt in großen Schritten"), ("Strg+E", "Umbenennen"),
    ("Strg+Rücktaste", "In den Papierkorb"), ("Umschalt+Strg+R", "Im Dateimanager zeigen"), ("Strg+/", "Diese Liste"),
]


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


class FlatEdit(QLineEdit):
    """A text field that sits in a display: no box, just text."""

    def __init__(self, font, color: str, parent=None):
        super().__init__(parent)
        self.setFont(font)
        self.setStyleSheet(f"QLineEdit {{ background: transparent; border: none; padding: 0; color: {color}; "
                           f"selection-background-color: {theme.AMBER}; selection-color: #000; }}"
                           f"QLineEdit:disabled {{ color: {theme.AMBER_DIM}; }}")


class Banner(QFrame):
    """A message above the editor, with an optional way back."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(40)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(14, 0, 8, 0)
        self.label = QLabel("")
        self.label.setFont(theme.sans(13, bold=True))
        self.action = HardwareKey("Rückgängig")
        self.close_key = HardwareKey("OK")
        layout.addWidget(self.label, 1)
        layout.addWidget(self.action)
        layout.addWidget(self.close_key)
        self.close_key.clicked.connect(self.hide)
        self._undo = None
        self.action.clicked.connect(self._run_undo)
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.timeout.connect(self.hide)
        self.hide()

    def show_message(self, kind: str, text: str, undo=None) -> None:
        tone = {"info": ("#24323A", "#68C6D6"), "warning": ("#3A2A14", theme.AMBER), "error": ("#3A1A18", theme.DANGER_TEXT),
                "success": ("#1B3A24", theme.ON)}[kind]
        self.setStyleSheet(f"Banner {{ background: {tone[0]}; border-bottom: 1px solid {tone[1]}; }}")
        self.label.setStyleSheet(f"background: transparent; color: {tone[1]};")
        self.label.setText(text)
        self._undo = undo
        self.action.setVisible(undo is not None)
        self.show()
        self._timer.start(9000 if undo is None else 15000)

    def _run_undo(self) -> None:
        undo, self._undo = self._undo, None
        self.hide()
        if undo:
            undo()


class KeyRouter(QObject):
    """Single keys, like the Mac app's KeyRouter: they act in the area Aufnahme, R and Space in both, and never while
    a text field has the focus or a dialog is open."""

    def __init__(self, window):
        super().__init__(window)
        self.window = window

    def eventFilter(self, obj, event):
        if event.type() == QEvent.KeyPress and isinstance(obj, QWidget) and obj.window() is self.window:
            return self.window.handle_key(event)
        return False


class MainWindow(QMainWindow):
    def __init__(self, link: QtLink, library: PresetLibrary, auto_connect: bool = True, recorder=None):
        super().__init__()
        self.link, self.library, self.recorder = link, library, recorder
        self.editor: PresetEditor | None = None
        self.source: tuple[str, object] | None = None  # ("slot", n) or ("file", SavedPreset) or ("new", None)
        self.place = 3
        self.live_enabled = True
        self.show_original = False
        self._bridge = _Bridge()
        self._loading = False
        self._library_stamp = None
        self._recording_undo = None
        self.setWindowTitle("Spark Studio")
        self.resize(1280, 860)
        self.setMinimumSize(1120, 720)
        self._build()
        self._menus()
        self._wire()
        self.library.reload()
        self._refresh_library()
        self._refresh_all()
        if self.recorder is not None:
            self.recorder.start_library()
            self.recorder.refresh_devices()
            self._refresh_recorder()
            self.recordings.refresh()
        self.recorder.sound_provider = self._heard_sound
        self.recordings.presets_provider = lambda: [i for i in self.library.items if not i.is_backup]
        self.recordings.send_sound.connect(self._send_sound)
        self.recordings.open_sound.connect(self._open_sound)
        self.recordings.play_link.connect(self._play_link)
        self._router = KeyRouter(self)
        QApplication.instance().installEventFilter(self._router)
        if auto_connect:
            QTimer.singleShot(200, self.link.start)

    # MARK: Building

    def _build(self) -> None:
        root = QWidget()
        root.setObjectName("root")
        self.setCentralWidget(root)
        column = QVBoxLayout(root)
        column.setContentsMargins(0, 0, 0, 0)
        column.setSpacing(0)
        bar = QWidget()
        bar.setFixedHeight(46)
        bar.setStyleSheet(f"background: {theme.DESK}; border-bottom: 1px solid {theme.DESK_LINE};")
        bar_row = QHBoxLayout(bar)
        bar_row.setContentsMargins(22, 7, 22, 7)
        self.tabs = SegmentTabs(["Aufnahme", "Presets", "Stimmgerät"])
        self.tabs.set_index(0)
        bar_row.addWidget(self.tabs)
        bar_row.addStretch(1)
        column.addWidget(bar)
        self.deck = Deck()
        column.addWidget(self.deck)
        self.stack = QStackedWidget()
        column.addWidget(self.stack, 1)
        self.recording_banner = Banner()
        column.insertWidget(column.indexOf(self.stack), self.recording_banner)
        self.recordings = RecordingsPage(self.recorder)
        self.recordings.message.connect(self._recording_message)
        self.stack.addWidget(self.recordings)
        presets = QWidget()
        body = QHBoxLayout(presets)
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(0)
        self.sidebar = Sidebar()
        body.addWidget(self.sidebar)
        body.addWidget(self._build_editor(), 1)
        self.stack.addWidget(presets)
        from ..tuner import TunerModel
        from .tuner_view import TunerView
        self.tuner = TunerModel(self.recorder, self.link)
        self.tuner_view = TunerView(self.tuner)
        self.stack.addWidget(self.tuner_view)
        self.stack.setCurrentIndex(0)
        self.activity_label = QLabel("")
        status = self.statusBar()
        status.setSizeGripEnabled(False)
        status.addWidget(self.activity_label, 1)
        status.addPermanentWidget(QLabel("Strg+/  Tastenkürzel"))
        status.addPermanentWidget(QLabel(f"   Version {VERSION} ({BUILD})"))
        # The deck's controls keep the names the Presets code uses.
        self.lamp_connected, self.device_label = self.deck.connected_lamp, self.deck.amp_label
        self.firmware_label, self.connect_key = self.deck.firmware_label, self.deck.connect_key

    def _build_editor(self) -> QWidget:
        page = QWidget()
        outer = QVBoxLayout(page)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)
        self.banner = Banner()
        outer.addWidget(self.banner)

        self.empty_label = QLabel("Wähle links einen Platz oder ein Preset, oder lege ein neues an (Strg+N).")
        self.empty_label.setFont(theme.sans(15))
        self.empty_label.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
        self.empty_label.setAlignment(Qt.AlignCenter)
        outer.addWidget(self.empty_label, 1)

        self.editor_box = QWidget()
        box = QVBoxLayout(self.editor_box)
        box.setContentsMargins(0, 0, 0, 0)
        box.setSpacing(0)
        outer.addWidget(self.editor_box, 1)

        # Header: the display with name, state, tempo and transfer, and the keys.
        header = QWidget()
        header.setStyleSheet(f"background: {theme.DESK};")
        h = QHBoxLayout(header)
        h.setContentsMargins(22, 16, 22, 16)
        h.setSpacing(16)
        display = Display(radius=12)
        dv = QVBoxLayout(display)
        dv.setContentsMargins(16, 10, 16, 10)
        dv.setSpacing(4)
        top = QHBoxLayout()
        top.setSpacing(12)
        self.name_edit = FlatEdit(theme.sans(26, bold=True), theme.AMBER)
        self.name_edit.setMaxLength(60)
        top.addWidget(self.name_edit, 1)
        self.lamp_changed = Lamp("Geändert", "hot", False, size=6)
        self.lamp_live = Lamp("Live", "on", False, size=6)
        top.addWidget(self.lamp_changed)
        top.addWidget(self.lamp_live)
        self.bpm_edit = FlatEdit(theme.mono(22, True), theme.AMBER)
        self.bpm_edit.setFixedWidth(52)
        self.bpm_edit.setAlignment(Qt.AlignRight)
        bpm_unit = QLabel("BPM")
        bpm_unit.setFont(theme.sans(10, bold=True, spacing=0.09))
        bpm_unit.setStyleSheet(f"background: transparent; color: {theme.AMBER_DIM};")
        top.addWidget(self.bpm_edit)
        top.addWidget(bpm_unit)
        dv.addLayout(top)
        mid = QHBoxLayout()
        mid.setSpacing(8)
        self.source_label = QLabel("")
        self.source_label.setFont(theme.sans(12, bold=True))
        self.source_label.setStyleSheet(f"background: transparent; color: {theme.AMBER_DIM};")
        dot = QLabel("·")
        dot.setStyleSheet(f"background: transparent; color: {theme.AMBER_DIM};")
        self.description_edit = FlatEdit(theme.sans(12), theme.AMBER_DIM)
        self.description_edit.setPlaceholderText("Beschreibung hinzufügen")
        mid.addWidget(self.source_label)
        mid.addWidget(dot)
        mid.addWidget(self.description_edit, 1)
        dv.addLayout(mid)
        transfer = QHBoxLayout()
        transfer.setSpacing(10)
        t = QLabel("ÜBERTRAGUNG")
        t.setFont(theme.sans(10, bold=True, spacing=0.09))
        t.setStyleSheet(f"background: transparent; color: {theme.LAMP_OFF_TEXT};")
        self.meter = LEDSegments(48, 5)
        transfer.addWidget(t)
        transfer.addWidget(self.meter, 1)
        dv.addLayout(transfer)
        h.addWidget(display, 1)

        keys = QHBoxLayout()
        keys.setSpacing(8)
        self.undo_key = HardwareKey("↶", keycap="Strg+Z")
        self.redo_key = HardwareKey("↷")
        self.ab_key = HardwareKey("A / B", keycap="Strg+B")
        self.save_key = HardwareKey("Sichern", "primary", "Strg+S")
        self.more_key = HardwareKey("⋯")
        for key in (self.undo_key, self.redo_key, self.ab_key, self.save_key, self.more_key):
            keys.addWidget(key)
        h.addLayout(keys)
        box.addWidget(header)

        # The chain on its board.
        board = QFrame()
        board.setStyleSheet(f"background: {theme.BOARD};")
        b = QHBoxLayout(board)
        b.setContentsMargins(20, 18, 20, 18)
        b.setSpacing(10)
        self.pedals: list[Pedal] = []
        for index, place in enumerate(catalog.PLACES):
            pedal = Pedal(index, place)
            pedal.selected.connect(self._select_place)
            pedal.toggled.connect(self._toggle_place)
            self.pedals.append(pedal)
            b.addWidget(pedal, 2 if place == "amp" else 1)
        box.addWidget(board)

        # The control field of the chosen unit.
        self.field = ControlField()
        box.addWidget(self.field, 1)
        return page

    def _menus(self) -> None:
        def action(menu, text, slot, shortcut=None):
            a = QAction(text, self)
            if shortcut:
                a.setShortcut(QKeySequence(shortcut))
            a.triggered.connect(slot)
            menu.addAction(a)
            return a

        view = self.menuBar().addMenu("Darstellung")
        action(view, "Aufnahme", lambda: self._area(0), "Ctrl+Shift+1")
        action(view, "Presets", lambda: self._area(1), "Ctrl+Shift+2")
        action(view, "Stimmgerät", lambda: self._area(2), "Ctrl+Shift+3")
        preset = self.menuBar().addMenu("Preset")
        action(preset, "Neues Preset", lambda: self._new(None), "Ctrl+N")
        action(preset, "Neu aus Vorlage …", self._new_from_template, "Ctrl+Shift+N")
        action(preset, "Duplizieren", self._duplicate, "Ctrl+D")
        preset.addSeparator()
        action(preset, "Sichern", self._save, "Ctrl+S")
        action(preset, "Sichern unter …", self._save_as, "Ctrl+Shift+S")
        action(preset, "Umbenennen …", self._rename, "Ctrl+E")
        action(preset, "Als Rezept speichern …", self._export_recipe)
        action(preset, "Rezept öffnen …", self._open_recipe)
        action(preset, "Vom Kemper übernehmen …", self._import_kemper)
        action(preset, "Tags bearbeiten …", self._ctrl_t, "Ctrl+T")
        preset.addSeparator()
        action(preset, "Im Dateimanager zeigen", self._reveal, "Ctrl+Shift+R")
        action(preset, "In den Papierkorb legen", self._trash, "Ctrl+Backspace")
        preset.addSeparator()
        action(preset, "Beenden", self.close, "Ctrl+Q")

        edit = self.menuBar().addMenu("Bearbeiten")
        action(edit, "Rückgängig", self._undo, "Ctrl+Z")
        action(edit, "Wiederholen", self._redo, "Ctrl+Shift+Z")
        action(edit, "Mit dem gesicherten Stand vergleichen", self._toggle_comparison, "Ctrl+B")
        action(edit, "Änderungen verwerfen", self._revert)
        action(edit, "Aufnahmen durchsuchen", self._search, "Ctrl+F")

        amp = self.menuBar().addMenu("Verstärker")
        action(amp, "Mit dem Verstärker verbinden", self.link.start)
        action(amp, "Trennen", self.link.stop)
        action(amp, "Verstärker neu lesen", self._reread, "Ctrl+R")
        self.live_action = action(amp, "Live am Verstärker", self._toggle_live, "Ctrl+Shift+L")
        self.live_action.setCheckable(True)
        self.live_action.setChecked(True)
        self.device_menu = amp.addMenu("Gerät")
        self.device_menu.aboutToShow.connect(self._fill_device_menu)
        amp.addSeparator()
        # As many slots as the device with the most has; those the connected device lacks are hidden.
        self.play_actions = [action(amp, f"Platz {slot + 1} spielen", lambda _=False, s=slot: self._play_slot(s),
                                    f"Ctrl+{slot + 1}") for slot in range(devices.LARGEST_SLOT_COUNT)]
        amp.addSeparator()
        self.store_actions = [action(amp, f"Auf Platz {slot + 1} speichern …", lambda _=False, s=slot: self._store(s),
                                     f"Ctrl+Alt+{slot + 1}") for slot in range(devices.LARGEST_SLOT_COUNT)]
        self._apply_profile(devices.SPARK_MINI)

        chain = self.menuBar().addMenu("Kette")
        for index, place in enumerate(catalog.PLACES):
            action(chain, f"{catalog.PLACE_TITLES[place]} wählen", lambda _=False, i=index: self._select_place(i),
                   f"Alt+{index + 1}")
        action(chain, "Gewählte Einheit ein oder aus", lambda: self._toggle_place(self.place, not self._current_on()),
               "Alt+0")

        tuner = self.menuBar().addMenu("Stimmgerät")
        action(tuner, "Zeiger oder Stroboskop", lambda: self.tuner.set_strobe(not self.tuner.shows_strobe))
        action(tuner, "Kammerton höher", lambda: self._tuner_key(lambda: self.tuner.set_a4(self.tuner.a4 + 0.1)),
               "Ctrl+Up")
        action(tuner, "Kammerton tiefer", lambda: self._tuner_key(lambda: self.tuner.set_a4(self.tuner.a4 - 0.1)),
               "Ctrl+Down")
        action(tuner, "Kammerton 440 Hz", lambda: self._tuner_key(lambda: self.tuner.set_a4(440.0)), "Ctrl+0")

        help_menu = self.menuBar().addMenu("Hilfe")
        action(help_menu, "Tastenkürzel", self._show_shortcuts, "Ctrl+/")
        action(help_menu, "Über Spark Studio", self._about)

    def _wire(self) -> None:
        link = self.link
        link.status.connect(self._on_status)
        link.device_name.connect(lambda _: self._refresh_connection())
        link.firmware.connect(lambda _: self._refresh_connection())
        link.active_slot.connect(self._on_active_slot)
        link.slots.connect(self._on_slots)
        link.trying_out.connect(lambda _: self._refresh_activity())
        link.is_editing_live.connect(lambda _: self._refresh_lamps())
        link.activity.connect(lambda _: self._refresh_activity())
        link.transfer.connect(self._on_transfer)
        link.connected.connect(self._on_reconnected)
        link.amp_selected.connect(self._on_amp_selected)
        link.amp_event.connect(self._on_amp_event)
        link.live_failed.connect(lambda text: self._say("warning", text))
        link.strain.connect(lambda: self._say("info", "Der Verstärker antwortet langsam. Änderungen gehen jetzt gemächlicher."))
        link.profile.connect(self._apply_profile)
        link.temporary_lost.connect(self._on_temporary_lost)

        self.connect_key.clicked.connect(self._connect_clicked)
        self.tabs.changed.connect(self._area)
        if self.recorder is not None:
            r = self.recorder
            self.deck.record_clicked.connect(r.toggle)
            self.deck.check_clicked.connect(r.toggle_monitoring)
            self.deck.input_chosen.connect(r.select)
            r.phase_changed.connect(lambda _: self._refresh_recorder())
            r.monitoring_changed.connect(lambda _: self._refresh_recorder())
            r.devices_changed.connect(self._refresh_devices)
            r.meter_changed.connect(lambda: self.deck.show_levels(r))
            r.message.connect(self._say)
        sb = self.sidebar
        sb.slot_selected.connect(self._slot_clicked)
        sb.slot_played.connect(self._play_slot)
        sb.item_selected.connect(self._item_clicked)
        sb.item_menu.connect(self._item_menu)
        sb.search_changed.connect(sb.rebuild)
        self.name_edit.editingFinished.connect(self._name_edited)
        self.bpm_edit.editingFinished.connect(self._bpm_edited)
        self.description_edit.editingFinished.connect(self._description_edited)
        self.undo_key.clicked.connect(self._undo)
        self.redo_key.clicked.connect(self._redo)
        self.ab_key.clicked.connect(self._toggle_comparison)
        self.save_key.clicked.connect(self._save)
        self.more_key.clicked.connect(self._more_menu)
        self.field.model_chosen.connect(self._model_chosen)
        self.field.toggled.connect(lambda on: self._toggle_place(self.place, on))

    # MARK: Link state

    def _on_status(self, status: str) -> None:
        self._refresh_connection()
        self._apply_profile(self.link.core.profile)

    def _apply_profile(self, profile) -> None:
        """Slots, names and what may be done follow the connected device."""
        connected = self.link.core.status == "connected"
        for slot, (play, store) in enumerate(zip(self.play_actions, self.store_actions)):
            visible = slot < profile.slot_count
            play.setVisible(visible)
            store.setVisible(visible)
            play.setText(f"{profile.slot_name(slot)} spielen")
            store.setText(f"Auf {profile.slot_name(slot)} speichern …")
            play.setEnabled(connected and profile.can(devices.SWITCH_SLOT))
            store.setEnabled(connected and profile.can(devices.STORE))
        if self.sidebar.profile != profile:
            self.sidebar.profile = profile
            self.sidebar.slots = list(self.link.core.slots)
            self.sidebar.rebuild()

    def _fill_device_menu(self) -> None:
        menu = self.device_menu
        menu.clear()
        core = self.link.core
        if not core.found:
            menu.addAction("Noch kein Gerät gefunden").setEnabled(False)
        for address, (name, profile) in core.found.items():
            state = "verbunden" if address == core.address and core.status == "connected" else "gesehen"
            item = menu.addAction(f"{name or profile.display_name} – {state}",
                                  lambda a=address: self._choose_device(a))
            item.setCheckable(True)
            item.setChecked(address == core.chosen)

    def _choose_device(self, address: str) -> None:
        core = self.link.core
        if address == core.chosen and core.status == "connected":
            return
        if self._temporary_would_be_lost():
            answer = QMessageBox.question(
                self, "Spark Studio",
                f"Der Sound auf dem {core.profile.display_name} geht beim Trennen verloren. Vorher als Preset sichern?",
                QMessageBox.Save | QMessageBox.Discard | QMessageBox.Cancel)
            if answer == QMessageBox.Cancel:
                return
            if answer == QMessageBox.Save:
                self._save()
        self.link.choose(address)

    def _temporary_would_be_lost(self) -> bool:
        core = self.link.core
        if core.status != "connected" or not core.profile.loses_temporary_on_disconnect:
            return False
        return bool(core.is_editing_live and self.editor is not None and self.editor.is_modified)

    def _on_temporary_lost(self, name: str) -> None:
        text = (f"{name} ist getrennt und spielt wieder seinen gespeicherten Platz. Der vorübergehende Sound ist dort "
                "weg. Beim nächsten Verbinden liest Studio nach, was spielt.")
        if self.recorder is not None and self.recorder.is_recording:
            text += " Der Take behält den Sound, mit dem er begann."
        self._say("warning", text)

    def _refresh_connection(self) -> None:
        core = self.link.core
        status = core.status
        self.lamp_connected.set_state(status == "connected", STATUS_TEXT.get(status, status),
                                      "on" if status == "connected" else "amber" if status in ("searching", "connecting") else "rec")
        self.device_label.setText(core.device_name or "Spark")
        self.firmware_label.setText(f"Firmware {core.firmware}" if core.firmware else STATUS_TEXT.get(status, ""))
        self.connect_key.setText("Trennen" if status in ("connected", "connecting", "searching") else "Verbinden")
        self.connect_key.set_style("normal" if status == "connected" else "primary")

    def _on_active_slot(self, slot) -> None:
        self.sidebar.active_slot = slot
        self.sidebar._apply_state()
        self._refresh_lamps()

    def _on_slots(self, slots) -> None:
        self.sidebar.slots = list(slots)
        self.sidebar.rebuild()
        if self.source and self.source[0] == "slot" and self.editor and not self.editor.is_modified:
            preset = slots[self.source[1]]
            if preset is not None and not preset.same_content(self.editor.current):
                self.editor = PresetEditor(preset)
                self._refresh_editor()

    def _refresh_activity(self) -> None:
        core = self.link.core
        self.activity_label.setText(core.activity or (f"Probiert: {core.trying_out}" if core.trying_out else ""))
        self._refresh_lamps()

    def _refresh_lamps(self) -> None:
        heard = self.link.core.is_editing_live and self.editor is not None
        self.lamp_live.set_state(heard)
        if self.show_original:
            self.lamp_changed.set_state(True, "A · Gespeichert", "amber")
        else:
            self.lamp_changed.set_state(bool(self.editor and self.editor.is_modified), "Geändert", "hot")

    def _on_transfer(self, transfer) -> None:
        if transfer is None:
            self.meter.set_fraction(0.0)
        else:
            self.meter.set_fraction(transfer.fraction)

    def _on_reconnected(self) -> None:
        """After a connection that came back by itself the temporary preset is gone, and an edit in progress goes back to
        the amp. After "Trennen" or another device, what plays is read, not assumed."""
        if not self.link.core.came_back:
            return
        if self.editor is not None and self.live_enabled and self.editor.is_modified:
            self.link.play_now(self.editor.current)
            self._say("info", "Die Verbindung war weg. Der bearbeitete Stand spielt wieder am Verstärker.")

    def _on_amp_selected(self, slot: int) -> None:
        """The player pressed the amp's preset button: Studio follows without playing anything."""
        self._open_slot(slot, play=False)

    def _on_amp_event(self, event) -> None:
        """The amp reports a knob turned on the amp itself; the editor follows while it plays live."""
        if self.editor is None or not self.link.core.is_editing_live or self.show_original:
            return
        self.editor.follow(event)
        self._refresh_editor()

    def _say(self, kind: str, text: str, undo=None) -> None:
        banner = self.recording_banner if self.stack.currentIndex() == 0 else self.banner
        banner.show_message(kind, text, undo)

    def _recording_message(self, kind: str, text: str, undo) -> None:
        self._recording_undo = undo
        self.recording_banner.show_message(kind, text, undo)

    def _heard_sound(self):
        """What the amp plays now, from memory only: the editor's state while it plays live, a tried-out preset, or
        the stored slot. Without a connection a take has no sound."""
        core = self.link.core
        if core.status != "connected":
            return None
        profile = core.profile
        # The profile's name, never a REACTOR's own Bluetooth name: the stamp is kept in the library.
        device = core.device_name if profile.id == "unknown_spark" and core.device_name else profile.display_name
        if not profile.can_send:
            slot = core.reactor.slot
            name = f"{device} {profile.slot_name(slot)}" if slot is not None else device
            return {"name": name, "slot": slot, "device": device, "listened": core.reactor.lines(profile)}
        if core.is_editing_live and self.editor is not None:
            return self._shown().copy(), None, f"Spark Studio · {device}", device
        if core.trying_out and core.tried_preset is not None:
            return core.tried_preset.copy(), None, f"Spark Studio · {device}", device
        slot = core.active_slot
        if slot is not None and slot < len(core.slots) and core.slots[slot] is not None:
            return core.slots[slot].copy(), slot, f"{profile.slot_name(slot)} · {device}", device
        return None

    def _send_sound(self, preset) -> None:
        if not self.link.is_connected:
            self._say("warning", "Der Verstärker ist nicht verbunden.")
            return
        self.run(self.link.core.try_out(preset.copy()))

    def _open_sound(self, preset) -> None:
        if not self._confirm_discard():
            return
        self._area(1)
        self.sidebar.select(None)
        copy = factory.duplicate(preset, preset.name)
        self._open(copy, ("new", None), unsaved=True)

    def _play_link(self, link) -> None:
        if not link:
            return
        items = [i for i in self.library.items if not i.is_backup]
        found = next((i for i in items if link.get("presetID") and i.id == link["presetID"]), None) or \
            next((i for i in items if link.get("fileName") and i.path.name == link["fileName"]), None)
        if found is None:
            self._say("warning", f"Das Preset „{link.get('name', '')}“ gibt es nicht mehr.")
            return
        self._send_sound(found.preset)

    def handle_key(self, event) -> bool:
        key, mods = event.key(), event.modifiers()
        if mods & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier):
            return False
        focus = QApplication.focusWidget()
        if isinstance(focus, (QLineEdit, QAbstractSpinBox, QTextEdit, QPlainTextEdit)):
            return False
        if QApplication.activeModalWidget() is not None or event.isAutoRepeat():
            return False
        if key == Qt.Key_R:
            self.recorder.toggle()
            return True
        if key == Qt.Key_Space:
            if isinstance(focus, QAbstractButton) and not self.recorder.is_recording:
                return False
            self.recordings.toggle_play()
            return True
        if self.stack.currentIndex() != 0:
            return False
        page, shift = self.recordings, bool(mods & Qt.ShiftModifier)
        actions = {Qt.Key_L: page.toggle_loop, Qt.Key_M: page.add_marker, Qt.Key_K: page.keep,
                   Qt.Key_Backspace: page.discard, Qt.Key_Delete: page.discard,
                   Qt.Key_Left: lambda: page.jump(-1 if shift else -5), Qt.Key_Right: lambda: page.jump(1 if shift else 5),
                   Qt.Key_Minus: lambda: page.nudge_tempo(-0.05), Qt.Key_Plus: lambda: page.nudge_tempo(0.05),
                   Qt.Key_Equal: lambda: page.nudge_tempo(0.05), Qt.Key_0: page.reset_tempo_pitch,
                   Qt.Key_F: page.toggle_favorite}
        for number in range(1, 6):
            actions[getattr(Qt, f"Key_{number}")] = lambda n=number: page.rate(n)
        handler = actions.get(key)
        if handler is None:
            return False
        handler()
        return True

    def _search(self) -> None:
        if self.stack.currentIndex() == 0:
            self.recordings.show_tab(0)
            self.recordings.takes.focus_search()
        else:
            self.sidebar.search.setFocus()

    def _area(self, index: int) -> None:
        self.tabs.set_index(index)
        self.stack.setCurrentIndex(index)
        # The tuner listens only while its area shows; the amp's own tuner goes off when it is left.
        self.tuner.set_active(index == 2)

    def _ctrl_t(self) -> None:
        """Strg+T: the strobe in the area Stimmgerät, the tags of the preset elsewhere."""
        if self.stack.currentIndex() == 2:
            self.tuner.set_strobe(not self.tuner.shows_strobe)
        else:
            self._edit_tags()

    def _tuner_key(self, action) -> None:
        if self.stack.currentIndex() == 2:
            action()

    def _refresh_recorder(self) -> None:
        self.deck.show_recorder(self.recorder)

    def _refresh_devices(self) -> None:
        self.deck.show_devices(self.recorder)
        self._refresh_recorder()

    def _report(self, error: Exception) -> None:
        known = isinstance(error, (LinkError, LibraryError, recipe.RecipeError))
        self._say("error", str(error) if known else f"{type(error).__name__}: {error}")

    def run(self, coroutine, on_ok=None, on_err=None) -> None:
        self.link.call(coroutine, lambda r, e: self._bridge.finished.emit(on_ok, on_err or self._report, r, e))

    # MARK: Selection

    def _connect_clicked(self) -> None:
        if self.link.core.status in ("connected", "connecting", "searching"):
            self.link.stop()
        else:
            self.link.start()

    def _slot_clicked(self, slot: int) -> None:
        self._open_slot(slot, play=True)

    def _open_slot(self, slot: int, play: bool) -> None:
        preset = self.link.core.slots[slot]
        if preset is None:
            return
        if not self._confirm_discard():
            self._restore_selection()
            return
        self._open(preset.copy(), ("slot", slot))
        self.sidebar.select(("slot", slot))
        if play and self.link.is_connected:
            self.link.play_slot(slot)

    def _play_slot(self, slot: int) -> None:
        if not self.link.is_connected:
            self._say("warning", "Der Verstärker ist nicht verbunden.")
            return
        self.link.play_slot(slot)

    def _item_clicked(self, item: SavedPreset) -> None:
        if not self._confirm_discard():
            self._restore_selection()
            return
        self._open(item.preset.copy(), ("file", item))
        self.sidebar.select(("file", item.path))
        if self.live_enabled and self.link.is_connected:
            self.link.play_now(item.preset)

    def _restore_selection(self) -> None:
        key = None
        if self.source and self.source[0] == "slot":
            key = ("slot", self.source[1])
        elif self.source and self.source[0] == "file":
            key = ("file", self.source[1].path)
        self.sidebar.select(key)

    def _refresh_library(self) -> None:
        self.sidebar.items = list(self.library.items)
        self.sidebar.rebuild()
        if self.source and self.source[0] == "file":
            self.sidebar.select(("file", self.source[1].path))

    def _item_menu(self, item: SavedPreset, pos) -> None:
        menu = QMenu(self)
        menu.addAction("Ausprobieren", lambda: self.link.is_connected and self.link.core.is_editing_live is not None
                       and self.run(self.link.core.try_out(item.preset.copy())))
        store = menu.addMenu("Auf den Verstärker")
        profile = self.link.core.profile
        store.setEnabled(self.link.core.can(devices.STORE))
        for slot in range(profile.slot_count):
            store.addAction(f"{profile.slot_name(slot)} …", lambda s=slot: self._store(s, item.preset.copy()))
        menu.addSeparator()
        menu.addAction("Umbenennen …", lambda: self._rename(item))
        menu.addAction("Tags bearbeiten …", lambda: self._edit_tags(item))
        menu.addAction("Duplizieren", lambda: self._open(factory.duplicate(item.preset), ("new", None), True))
        menu.addAction("Im Dateimanager zeigen", lambda: self._reveal(item))
        menu.addSeparator()
        menu.addAction("In den Papierkorb legen", lambda: self._trash(item))
        menu.exec(pos)

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
        self.link.core.end_editing()
        self.editor = PresetEditor(preset)
        if unsaved:
            self.editor.mark_unsaved()
        self.source = source
        self.show_original = False
        self.place = 3 if len(preset.effects) == 7 else 0
        self._refresh_all()
        if source[0] == "new" and self.live_enabled and self.link.is_connected:
            self.link.play_now(preset)

    def _new(self, template) -> None:
        if not self._confirm_discard():
            return
        self.sidebar.select(None)
        self._open(factory.empty() if template is None else factory.make(template), ("new", None), unsaved=True)

    def _new_from_template(self) -> None:
        names = [f"{t.name} – {t.summary}" for t in factory.templates()]
        choice, ok = QInputDialog.getItem(self, "Neu aus Vorlage", "Vorlage:", names, 0, False)
        if ok:
            self._new(factory.templates()[names.index(choice)])

    def _duplicate(self) -> None:
        if self.editor is not None:
            self.sidebar.select(None)
            self._open(factory.duplicate(self.editor.current), ("new", None), unsaved=True)

    def _refresh_all(self) -> None:
        self._refresh_connection()
        self._refresh_editor()

    @property
    def locked(self) -> bool:
        return self.editor is None or self.show_original

    def _shown(self) -> protocol.Preset:
        return self.editor.original if self.show_original else self.editor.current

    def _refresh_editor(self) -> None:
        has = self.editor is not None
        self.editor_box.setVisible(has)
        self.empty_label.setVisible(not has)
        if not has:
            self._refresh_lamps()
            return
        ed = self.editor
        self._loading = True
        try:
            preset = self._shown()
            if not self.name_edit.hasFocus():
                self.name_edit.setText(preset.name)
            if not self.bpm_edit.hasFocus():
                self.bpm_edit.setText(f"{preset.bpm:.0f}")
            if not self.description_edit.hasFocus():
                self.description_edit.setText(preset.description)
            for edit in (self.name_edit, self.bpm_edit, self.description_edit):
                edit.setEnabled(not self.show_original)
            self.source_label.setText(self._source_text())
            self.undo_key.setEnabled(ed.can_undo and not self.show_original)
            self.redo_key.setEnabled(ed.can_redo and not self.show_original)
            self.ab_key.setText("A" if self.show_original else "A / B")
            self.ab_key.set_style("on" if self.show_original else "normal")
            self.ab_key.setEnabled(ed.is_modified or self.show_original)
            self.save_key.setEnabled(not self.show_original)
            self.more_key.setEnabled(not self.show_original)
            seven = len(preset.effects) == 7
            cat = catalog.load()
            for index, pedal in enumerate(self.pedals):
                pedal.setVisible(seven)
                if seven:
                    effect = preset.effects[index]
                    info = cat.info(effect.name, len(effect.parameters))
                    values = [p.value for p in effect.parameters if info.parameter(p.index).visible]
                    group = GROUPS.get(info.group or "", "") if index == 3 else ""
                    pedal.set_state(catalog.PLACE_TITLES[catalog.PLACES[index]], info.name, group, values,
                                    effect.is_on, index == self.place)
            self._refresh_field(preset)
        finally:
            self._loading = False
        self._refresh_lamps()

    def _source_text(self) -> str:
        kind = self.source[0] if self.source else ""
        if kind == "slot":
            device = self.link.core.device_name or "Spark"
            return f"Platz {self.source[1] + 1} · {device}"
        if kind == "file":
            return "Rezept" if self.source[1].is_recipe else "Auf diesem Computer"
        return "Neu, noch nicht gesichert" if kind == "new" else ""

    def _refresh_field(self, preset: protocol.Preset) -> None:
        if self.place >= len(preset.effects):
            self.place = 0
        effect = preset.effects[self.place]
        cat = catalog.load()
        info = cat.info(effect.name, len(effect.parameters))
        place_key = catalog.PLACES[self.place] if len(preset.effects) == 7 else info.place
        self.field.show_unit(info, effect, place_key, self.place, len(preset.effects), self.locked, self)

    def _current_on(self) -> bool:
        return bool(self.editor and self.editor.current.effects[self.place].is_on)

    def _select_place(self, index: int) -> None:
        if self.editor is None:
            return
        self.place = index
        self._refresh_editor()

    # MARK: Changes

    def _edited(self, changes) -> None:
        if self.live_enabled and not self.show_original and self.editor is not None:
            self.link.push_live(changes, self.editor.current)
        self._update_flags()

    def _update_flags(self) -> None:
        ed = self.editor
        if ed is None:
            return
        self.undo_key.setEnabled(ed.can_undo and not self.show_original)
        self.redo_key.setEnabled(ed.can_redo and not self.show_original)
        self.ab_key.setEnabled(ed.is_modified or self.show_original)
        self.source_label.setText(self._source_text())
        self._refresh_lamps()

    def parameter_changed(self, place: int, index: int, value: float) -> None:
        if not self.locked:
            self._edited(self.editor.set_parameter(place, index, value))

    def _toggle_place(self, index: int, on: bool) -> None:
        if self.locked:
            return
        self._edited(self.editor.set_on(index, on))
        self._refresh_editor()

    def _model_chosen(self, model_id: str) -> None:
        if self.locked:
            return
        self._edited(self.editor.set_model(self.place, model_id))
        self._refresh_editor()

    def _name_edited(self) -> None:
        if self.locked or self._loading:
            return
        name = self.name_edit.text().strip()
        problem = protocol.name_problem(name)
        if problem:
            self._say("warning", problem)
            self.name_edit.setText(self.editor.current.name)
            return
        self.editor.set_name(name)
        self._update_flags()

    def _bpm_edited(self) -> None:
        if self.locked or self._loading:
            return
        try:
            value = float(self.bpm_edit.text().replace(",", "."))
        except ValueError:
            self.bpm_edit.setText(f"{self.editor.current.bpm:.0f}")
            return
        self._edited(self.editor.set_bpm(value))
        self.bpm_edit.setText(f"{self.editor.current.bpm:.0f}")

    def _description_edited(self) -> None:
        if self.locked or self._loading:
            return
        self.editor.set_description(self.description_edit.text().strip())
        self._update_flags()

    def _undo(self) -> None:
        if self.stack.currentIndex() == 0:
            undo, self._recording_undo = self._recording_undo, None
            if undo:
                self.recording_banner.hide()
                undo()
            return
        if self.editor and not self.show_original:
            self._edited(self.editor.undo())
            self._refresh_editor()

    def _redo(self) -> None:
        if self.editor and not self.show_original:
            self._edited(self.editor.redo())
            self._refresh_editor()

    def _revert(self) -> None:
        if self.editor and not self.show_original:
            self._edited(self.editor.revert())
            self._refresh_editor()

    def _toggle_comparison(self) -> None:
        """A/B: plays the saved state, then the edited one again. The controls are locked meanwhile."""
        if self.editor is None or not (self.editor.is_modified or self.show_original):
            return
        self.show_original = not self.show_original
        if self.live_enabled and self.link.is_connected:
            self.link.play_now(self.editor.original if self.show_original else self.editor.current)
        self._refresh_editor()

    def _toggle_live(self) -> None:
        self.live_enabled = not self.live_enabled
        self.live_action.setChecked(self.live_enabled)
        if self.live_enabled and self.editor is not None and self.link.is_connected:
            self.link.play_now(self._shown())
        elif not self.live_enabled:
            self.link.core.end_editing()
        self._say("info", "Live: Änderungen gehen sofort zum Verstärker." if self.live_enabled
                  else "Live aus. Änderungen bleiben im Editor, bis du sie ausprobierst.")

    def _more_menu(self) -> None:
        menu = QMenu(self)
        menu.addAction("Sichern unter …", self._save_as)
        menu.addSeparator()
        profile = self.link.core.profile
        for slot in range(profile.slot_count):
            old = self.link.core.slots[slot] if slot < len(self.link.core.slots) else None
            label = f"Auf {profile.slot_name(slot)} speichern …" + (f" (jetzt „{old.name}“)" if old else "")
            action = menu.addAction(label, lambda s=slot: self._store(s))
            action.setEnabled(self.link.core.can(devices.STORE))
        menu.addSeparator()
        menu.addAction("Text für REACTOR kopieren", self._copy_tone_text)
        menu.addSeparator()
        revert = menu.addAction("Änderungen verwerfen", self._revert)
        revert.setEnabled(bool(self.editor and self.editor.is_modified))
        menu.addAction("Duplizieren", self._duplicate)
        menu.exec(self.more_key.mapToGlobal(self.more_key.rect().bottomLeft()))

    # MARK: Amp actions

    def _reread(self) -> None:
        if self.link.is_connected:
            self.run(self.link.core.load_all())

    def _copy_tone_text(self) -> None:
        """The edited sound as English text for REACTOR's Text to Tone. Nothing goes to the REACTOR."""
        if self.editor is None:
            return
        try:
            text = recipe.tone_description(recipe.from_preset(self.editor.current))
        except Exception as error:  # noqa: BLE001 - reported to the user
            self._say("warning", f"Der Sound ließ sich nicht als Text beschreiben: {error}")
            return
        QApplication.clipboard().setText(text)
        self._say("info", "Der Text für REACTOR ist kopiert. Füge ihn in der REACTOR-App bei „Text to Tone“ ein; der "
                          "REACTOR deutet ihn selbst.")

    def _store(self, slot: int, preset: protocol.Preset | None = None) -> None:
        preset = preset or (self.editor.current.copy() if self.editor else None)
        if preset is None or not self.link.core.can(devices.STORE):
            self._say("warning", "Dazu muss ein Preset offen und ein Gerät verbunden sein, das speichern darf.")
            return
        problem = protocol.name_problem(preset.name)
        if problem:
            self._say("warning", problem)
            return
        old = self.link.core.slots[slot]
        answer = QMessageBox.question(
            self, "Spark Studio",
            f"„{preset.name}“ auf Platz {slot + 1} speichern?\n\n"
            + (f"Das jetzige Preset „{old.name}“ wird vorher gesichert und liegt dann auf diesem Computer."
               if old else "Der Platz wird überschrieben."),
            QMessageBox.Yes | QMessageBox.Cancel, QMessageBox.Cancel)
        if answer != QMessageBox.Yes:
            return
        edited = self.editor is not None and preset == self.editor.current
        self.run(self.link.core.current_preset(slot), lambda current: self._store_step2(preset, slot, current, edited))

    def _store_step2(self, preset, slot: int, current, edited: bool) -> None:
        try:
            if self.library.existing(current) is None:
                device = self.link.core.device_name or "Spark"
                self.library.save(current, f"Platz {slot + 1} · {device}", is_backup=True)
                self._refresh_library()
        except (OSError, LibraryError) as error:
            self._report(error)
            return  # no backup, no overwrite
        self.run(self.link.core.store(preset, slot), lambda _: self._stored(slot, edited))

    def _stored(self, slot: int, edited: bool) -> None:
        if self.editor and edited:
            self.editor.mark_saved()
            self.source = ("slot", slot)
            self.sidebar.select(("slot", slot))
        self._refresh_editor()
        self._say("success", f"Auf Platz {slot + 1} gespeichert und zurückgelesen.")

    # MARK: Library actions

    def _save(self) -> bool:
        if self.editor is None:
            return True
        problem = protocol.name_problem(self.editor.current.name)
        if problem:
            self._say("warning", problem)
            return False
        try:
            if self.source and self.source[0] == "file":
                saved = self.library.replace(self.source[1], self.editor.current)
            else:
                origin = (f"Platz {self.source[1] + 1} · {self.link.core.device_name or 'Spark'}"
                          if self.source and self.source[0] == "slot" else "Spark Studio")
                saved = self.library.save(self.editor.current, origin)
        except (OSError, LibraryError) as error:
            self._report(error)
            return False
        self.editor.mark_saved()
        self.source = ("file", saved)
        self.show_original = False
        self._refresh_library()
        self._refresh_editor()
        self._say("success", f"„{saved.name}“ auf diesem Computer gesichert.")
        return True

    # MARK: Tags and the Kemper import

    def _edit_tags(self, item: SavedPreset | None = None) -> None:
        """Tags and notes of a saved preset, typed with or without "#", separated by blanks."""
        if not isinstance(item, SavedPreset):
            item = self.source[1] if self.source and self.source[0] == "file" else None
        if item is None or item.is_backup:
            self._say("info", "Tags gehören zu einem Preset auf diesem Computer. Sichere es zuerst.")
            return
        known = " ".join(f"#{t}" for t, _ in self.library.tag_counts()[:12])
        text, ok = QInputDialog.getText(
            self, "Tags bearbeiten", f"Tags für „{item.name}“, mit oder ohne #, durch Leerzeichen getrennt."
            + (f"\nSchon vergeben: {known}" if known else ""), text=" ".join(f"#{t}" for t in item.tags))
        if not ok:
            return
        from ..library import parse_tags
        try:
            saved = self.library.update_meta(item, tags=parse_tags(text))
        except (OSError, LibraryError) as error:
            self._report(error)
            return
        if self.source and self.source[0] == "file" and self.source[1].path == saved.path:
            self.source = ("file", saved)
        self._refresh_library()

    def _import_kemper(self) -> None:
        """Reads a Kemper backup or rig, asks what to make of it, and writes presets and pieces. Reads only."""
        from .. import kemper
        from .kemper_dialog import KemperDialog
        path, _ = QFileDialog.getOpenFileName(self, "Kemper-Backup oder Rig wählen", str(Path.home()),
                                              "Kemper (*.kpabackup *.kipr)")
        if not path:
            return
        try:
            plan = kemper.Plan(kemper.read(Path(path)))
        except (kemper.KemperError, OSError) as error:
            self._report(error)
            return
        if not plan.performances and not plan.rigs:
            self._say("warning", "In der Datei sind keine Rigs.")
            return
        dialog = KemperDialog(plan, Path(path).name, self)
        if dialog.exec() != QDialog.Accepted:
            return
        self._run_kemper_import(dialog.apply())

    def _run_kemper_import(self, plan) -> None:
        from .. import recipe as recipemod
        from .. import store as storemod
        try:
            sounds, songs = plan.output()
            written, new = self.library.import_kemper(sounds)
        except (OSError, LibraryError, recipemod.RecipeError) as error:
            self._report(error)
            return
        message = f"Kemper-Import: {new} neue Presets"
        if len(sounds) > new:
            message += f", {len(sounds) - new} schon vorhandene ergänzt"
        message += "."
        if songs and self.recorder is not None:
            pieces = [{"title": song.title, "notes": song.notes, "parts": [
                {"name": name, "preset": {"presetID": written[index].id, "fileName": written[index].path.name,
                                          "name": written[index].name}} for name, index in song.parts]}
                for song in songs]
            added, kept = storemod.add_imported_pieces(self.recorder.store, pieces)
            if added:
                self.recorder.store.save()
                self.recorder.library_changed.emit()
            message += f" {added} Stücke unter Aufnahme angelegt."
            if kept:
                message += " Schon da und unverändert: " + ", ".join(kept) + "."
        self.sidebar.pin([tag for tag in ("basis", "song", "unterricht")
                          if any(tag in sound.tags for sound in sounds)])
        self._refresh_library()
        self._say("success", message + " Jeder Sound ist eine Annäherung: am Verstärker anhören.")

    def _save_as(self) -> None:
        if self.editor is None:
            return
        name, ok = QInputDialog.getText(self, "Sichern unter", "Name:", text=self.editor.current.name)
        if not ok:
            return
        name = name.strip()
        problem = protocol.name_problem(name)
        if problem:
            self._say("warning", problem)
            return
        copy = factory.duplicate(self.editor.current, name)
        try:
            saved = self.library.save(copy, "Spark Studio")
        except (OSError, LibraryError) as error:
            self._report(error)
            return
        self.editor = PresetEditor(copy)
        self.source = ("file", saved)
        self._refresh_library()
        self._refresh_editor()

    def _rename(self, item: SavedPreset | None = None) -> None:
        if item is None and self.stack.currentIndex() == 0:
            self.recordings.rename()
            return
        item = item or (self.source[1] if self.source and self.source[0] == "file" else None)
        if item is None:
            self._say("info", "Nur gesicherte Presets lassen sich umbenennen. Den Namen des offenen Presets ändert das Namensfeld.")
            return
        name, ok = QInputDialog.getText(self, "Umbenennen", "Neuer Name:", text=item.name)
        if not ok:
            return
        problem = protocol.name_problem(name)
        if problem:
            self._say("warning", problem)
            return
        try:
            renamed = self.library.rename(item, name)
        except (OSError, LibraryError) as error:
            self._report(error)
            return
        if self.source and self.source[0] == "file" and self.source[1].path == item.path:
            self.source = ("file", renamed)
            if self.editor:
                self.editor.current.name = renamed.name
                self.editor.original.name = renamed.name
        self._refresh_library()
        self._refresh_editor()

    def _trash(self, item: SavedPreset | None = None) -> None:
        if item is None and self.stack.currentIndex() == 0:
            self.recordings.discard()
            return
        item = item or (self.source[1] if self.source and self.source[0] == "file" else None)
        if item is None:
            return
        if QMessageBox.question(self, "Spark Studio", f"„{item.name}“ in den Papierkorb legen?",
                                QMessageBox.Yes | QMessageBox.Cancel, QMessageBox.Cancel) != QMessageBox.Yes:
            return
        try:
            self.library.trash(item)
        except (OSError, LibraryError) as error:
            self._report(error)
            return
        if self.source and self.source[0] == "file" and self.source[1].path == item.path:
            self.editor, self.source = None, None
        self._refresh_library()
        self._refresh_editor()

    def _reveal(self, item: SavedPreset | None = None) -> None:
        if item is None and self.stack.currentIndex() == 0:
            self.recordings.reveal()
            return
        item = item or (self.source[1] if self.source and self.source[0] == "file" else None)
        folder = item.path.parent if item else self.library.folder
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(folder)))

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
        if not self._confirm_discard():
            return
        self.sidebar.select(None)
        self._open(conversion.preset, ("new", None), unsaved=True)
        if conversion.warnings:
            self._say("info", " ".join(conversion.warnings))

    def changeEvent(self, event):
        if event.type() == event.Type.ActivationChange and self.isActiveWindow():
            stamp = self.library.folder.stat().st_mtime if self.library.folder.exists() else None
            if stamp != self._library_stamp:
                self._library_stamp = stamp
                self.library.reload()
                self._refresh_library()
        super().changeEvent(event)

    def _show_shortcuts(self) -> None:
        text = "\n".join(f"{keys:<30} {what}" for keys, what in SHORTCUTS)
        box = QMessageBox(QMessageBox.NoIcon, "Tastenkürzel", "", parent=self)
        box.setText(f"<pre style='font-family: {theme.mono_family()}'>{text}</pre>")
        box.exec()

    def _about(self) -> None:
        QMessageBox.about(self, "Spark Studio", f"Spark Studio {VERSION} ({BUILD}) für Linux\n\n"
                          "Der Bereich Presets der Mac-App: Verstärker lesen, Presets bearbeiten, live hören und "
                          f"sichern.\nKatalog: {catalog.load().checked_on}")

    def closeEvent(self, event):
        if not self._confirm_discard():
            event.ignore()
            return
        self.tuner.set_active(False)
        if self.recorder is not None:
            self.recorder.shutdown()
        QApplication.instance().removeEventFilter(self._router)
        self.link.shutdown()
        super().closeEvent(event)


class ControlField(QFrame):
    """The panel under the chain: the chosen unit with its model, a stripe in the place's color and big knobs."""
    model_chosen = Signal(str)
    toggled = Signal(bool)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.color = theme.place_color("amp")
        self.setStyleSheet(f"ControlField {{ background: {theme.DESK}; }}")
        outer = QVBoxLayout(self)
        outer.setContentsMargins(22, 18, 22, 18)
        self.panel = Panel()
        outer.addWidget(self.panel)
        grid = QHBoxLayout(self.panel)
        grid.setContentsMargins(28, 24, 28, 22)
        grid.setSpacing(24)
        left = QVBoxLayout()
        left.setSpacing(4)
        self.caption = QLabel("")
        self.caption.setFont(theme.sans(11, bold=True, spacing=0.12))
        left.addWidget(self.caption)
        title_row = QHBoxLayout()
        self.title = QToolButton()
        self.title.setPopupMode(QToolButton.InstantPopup)
        self.title.setToolButtonStyle(Qt.ToolButtonTextOnly)
        self.title.setCursor(Qt.PointingHandCursor)
        self.title.setFont(theme.sans(30, bold=True))
        title_row.addWidget(self.title)
        title_row.addStretch(1)
        left.addLayout(title_row)
        self.summary = QLabel("")
        self.summary.setFont(theme.sans(15))
        self.summary.setWordWrap(True)
        self.inspiration = QLabel("")
        self.inspiration.setFont(theme.sans(13))
        self.inspiration.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
        left.addWidget(self.summary)
        left.addWidget(self.inspiration)
        left.addSpacing(8)
        self.knob_row = QHBoxLayout()
        self.knob_row.setSpacing(18)
        left.addLayout(self.knob_row)
        left.addStretch(1)
        grid.addLayout(left, 1)

        right_box = QWidget()
        right_box.setFixedWidth(70)
        right = QVBoxLayout(right_box)
        right.setContentsMargins(0, 0, 0, 0)
        right.setAlignment(Qt.AlignTop | Qt.AlignHCenter)
        self.on_lamp = Lamp("", "on", False, size=8)
        self.on_foot = Footswitch(44)
        self.on_foot.clicked.connect(lambda: self.toggled.emit(self.on_foot.isChecked()))
        self.on_text = QLabel("AN")
        self.on_text.setFont(theme.sans(11, bold=True, spacing=0.12))
        self.on_text.setAlignment(Qt.AlignCenter)
        right.addWidget(self.on_lamp, 0, Qt.AlignHCenter)
        right.addWidget(self.on_foot, 0, Qt.AlignHCenter)
        right.addWidget(self.on_text)
        right.addStretch(1)
        grid.addWidget(right_box)
        self._window = None

    def show_unit(self, info, effect, place_key: str, place: int, count: int, locked: bool, window) -> None:
        self._window = window
        self.color = theme.place_color(place_key)
        hexcolor = self.color.name()
        self.panel.color = self.color
        self.panel.update()
        self.caption.setText(f"{catalog.PLACE_TITLES.get(place_key, place_key).upper()} · PLATZ {place + 1} VON {count}")
        self.caption.setStyleSheet(f"background: transparent; color: {hexcolor};")
        self.title.setText(f"{info.name} ⌄")
        self.title.setStyleSheet(f"QToolButton {{ border: none; background: transparent; color: {hexcolor}; "
                                 f"padding: 0; text-align: left; }} QToolButton::menu-indicator {{ image: none; }}")
        self.title.setEnabled(not locked)
        menu = QMenu(self.title)
        cat = catalog.load()
        models = cat.models_for(place_key)
        if all(m.id != effect.name for m in models):
            models = [info, *models]
        last_group = None
        for model in models:
            if place_key == "amp" and model.group != last_group:
                if last_group is not None:
                    menu.addSeparator()
                menu.addSection(GROUPS.get(model.group or "", model.group or ""))
                last_group = model.group
            label = model.name + (f"   {model.summary}" if model.summary else "")
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(model.id == effect.name)
            action.triggered.connect(lambda _=False, mid=model.id: self.model_chosen.emit(mid))
        self.title.setMenu(menu)
        self.summary.setText(info.summary)
        self.inspiration.setText(f"Vorbild: {info.inspiration}" if info.inspiration else ("Zusatzpaket" if info.pack else ""))
        self.inspiration.setVisible(bool(info.inspiration or info.pack))
        while self.knob_row.count():
            item = self.knob_row.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        for parameter in effect.parameters:
            pinfo = info.parameter(parameter.index)
            if not pinfo.visible:
                continue
            start = info.defaults[parameter.index] if parameter.index < len(info.defaults) else None
            self.knob_row.addWidget(self._widget_for(parameter, pinfo, start, place, locked))
        self.knob_row.addStretch(1)
        self.knob_row.addWidget(self._help())
        self.on_foot.setChecked(effect.is_on)
        self.on_foot.setEnabled(not locked)
        self.on_lamp.set_state(effect.is_on, "")
        self.on_text.setText("AN" if effect.is_on else "AUS")
        self.on_text.setStyleSheet(f"background: transparent; color: {theme.ON if effect.is_on else theme.ENGRAVING};")

    def _help(self) -> QWidget:
        box = QFrame()
        box.setStyleSheet(f"QFrame {{ border-left: 1px solid {theme.DESK_LINE}; }} QLabel {{ border: none; }}")
        box.setFixedWidth(330)
        v = QVBoxLayout(box)
        v.setContentsMargins(22, 0, 0, 0)
        a = QLabel("<b>Scrollen</b> dreht fein, <b>Ziehen</b> grob, <b>Doppelklick</b> setzt den Standardwert.")
        b = QLabel("Jede Änderung ist sofort am Verstärker hörbar, ohne einen Platz zu überschreiben.")
        for label in (a, b):
            label.setWordWrap(True)
            label.setFont(theme.sans(13))
            label.setStyleSheet(f"color: {theme.DESK_MUTED}; border: none;")
            v.addWidget(label)
        v.addStretch(1)
        return box

    def _widget_for(self, parameter, pinfo, start, place, locked) -> QWidget:
        window = self._window
        index = parameter.index
        if pinfo.kind == "knob":
            knob = Knob(pinfo.label, self.color, start, size=66)
            knob.set_value(parameter.value)
            knob.locked = locked
            knob.gesture_started.connect(window.editor.begin_gesture)
            knob.gesture_ended.connect(lambda: (window.editor.end_gesture(), window._update_flags()))
            knob.changed.connect(lambda v, p=place, i=index: window.parameter_changed(p, i, v))
            return knob
        block = QWidget()
        v = QVBoxLayout(block)
        v.setContentsMargins(6, 14, 6, 0)
        v.setSpacing(12)
        if pinfo.kind == "switch":
            switch = DeviceSwitch(pinfo.off, pinfo.on)
            switch.set_on(parameter.value >= 0.5)
            switch.locked = locked
            switch.toggled.connect(lambda on, p=place, i=index: (window.parameter_changed(p, i, 1.0 if on else 0.0),
                                                                  window.editor and window._update_flags()))
            v.addWidget(switch)
        else:
            choice = QToolButton()
            choice.setPopupMode(QToolButton.InstantPopup)
            choice.setText(pinfo.display(parameter.value) + "  ▾")
            choice.setEnabled(not locked)
            choice.setFont(theme.sans(13, bold=True))
            choice.setStyleSheet(f"QToolButton {{ background: {theme.FIELD}; border: 1px solid {theme.FIELD_EDGE}; "
                                 f"border-radius: 8px; padding: 6px 12px; color: {theme.AMBER}; }} "
                                 "QToolButton::menu-indicator { image: none; }")
            menu = QMenu(choice)
            for label, value in pinfo.options:
                menu.addAction(label, lambda val=value, lab=label, p=place, i=index, ch=choice:
                               (ch.setText(lab + "  ▾"), window.parameter_changed(p, i, val)))
            choice.setMenu(menu)
            v.addWidget(choice)
        caption = QLabel(pinfo.label.upper())
        caption.setFont(theme.sans(10, bold=True, spacing=0.09))
        caption.setStyleSheet(f"background: transparent; color: {theme.ENGRAVING};")
        caption.setAlignment(Qt.AlignHCenter)
        v.addWidget(caption)
        v.addStretch(1)
        return block


class Panel(QFrame):
    """The raised panel of the control field, with the stripe of the place's color on top."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.color = theme.place_color("amp")

    def paintEvent(self, _):
        from PySide6.QtCore import QRectF
        from PySide6.QtGui import QPainter, QPen
        from .widgets import vgradient
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        p.setPen(QPen(c("#060607"), 1))
        p.setBrush(vgradient(r, "#2A2A2F", "#1B1B1F"))
        p.drawRoundedRect(r, 16, 16)
        p.setPen(Qt.NoPen)
        p.setBrush(self.color)
        p.drawRoundedRect(QRectF(r.left() + 30, r.top(), r.width() - 60, 4), 2, 2)
