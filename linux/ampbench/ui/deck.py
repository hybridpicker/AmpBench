"""The deck: the fixed front on top of the window. Recording, level, the Spark and (later) the click."""
from __future__ import annotations

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QVBoxLayout, QWidget

from . import theme
from .formats import channels, clock, khz
from .widgets import (DevicePopup, Display, Engraving, Front, HardwareKey, Lamp, LEDMeter, RecordKey)
from ..capture import to_db
from ..i18n import tr

DASH = "–"


def divider() -> QWidget:
    line = QFrame()
    line.setFixedWidth(2)
    line.setStyleSheet("background: qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #000000, stop:0.5 #000000, "
                       "stop:0.5 #1E1E21, stop:1 #1E1E21);")
    return line


def time_text(seconds: float) -> str:
    return clock(seconds, tenths=True)


def fact(name: str, value: str) -> str:
    """A line of the level module: the name in capitals, padded so that the values stand below each other."""
    return f"{name.upper():<9}{value}"


class Deck(Front):
    connect_clicked = Signal()
    record_clicked = Signal()
    check_clicked = Signal()
    input_chosen = Signal(object)

    def __init__(self, parent=None):
        super().__init__(radius=0, parent=parent)
        self.setFixedHeight(122)
        row = QHBoxLayout(self)
        row.setContentsMargins(22, 12, 22, 12)
        row.setSpacing(16)
        row.addLayout(self._record_module())
        row.addWidget(divider())
        row.addLayout(self._level_module(), 1)
        row.addWidget(divider())
        row.addLayout(self._spark_module())
        row.addWidget(divider())
        row.addLayout(self._click_module())

    def _record_module(self) -> QHBoxLayout:
        box = QHBoxLayout()
        box.setSpacing(14)
        self.record_key = RecordKey()
        self.record_key.clicked.connect(self.record_clicked)
        box.addWidget(self.record_key)
        self.display = Display(radius=12)
        self.display.setFixedWidth(240)
        d = QVBoxLayout(self.display)
        d.setContentsMargins(14, 8, 14, 8)
        d.setSpacing(0)
        top = QHBoxLayout()
        self.state_lamp = Lamp(tr("Ready"), "amber", True, size=8)
        hint = QLabel(tr("R · RECORD"))
        hint.setFont(theme.sans(10, bold=True, spacing=0.09))
        hint.setStyleSheet(f"background: transparent; color: {theme.AMBER_DIM};")
        top.addWidget(self.state_lamp)
        top.addStretch(1)
        top.addWidget(hint)
        d.addLayout(top)
        self.time_label = QLabel(time_text(0))
        self.time_label.setFont(theme.mono(36, True))
        self.time_label.setStyleSheet(f"background: transparent; color: {theme.AMBER};")
        d.addWidget(self.time_label)
        self.device_label = QLabel(tr("No Spark"))
        self.device_label.setFont(theme.mono(11))
        self.device_label.setStyleSheet(f"background: transparent; color: {theme.AMBER_DIM};")
        d.addWidget(self.device_label)
        box.addWidget(self.display)
        return box

    def _level_module(self) -> QVBoxLayout:
        box = QVBoxLayout()
        box.setSpacing(4)
        top = QHBoxLayout()
        top.addWidget(Engraving(tr("Level")))
        top.addStretch(1)
        self.clip_lamp = Lamp(tr("Clipping"), "rec", False, size=7)
        self.silence_lamp = Lamp(tr("No signal"), "amber", False, size=7)
        top.addWidget(self.clip_lamp)
        top.addSpacing(10)
        top.addWidget(self.silence_lamp)
        box.addLayout(top)
        self.meter = LEDMeter()
        box.addWidget(self.meter)
        bottom = QHBoxLayout()
        facts = QVBoxLayout()
        facts.setSpacing(0)
        self.source_label = QLabel(fact(tr("Source"), DASH))
        self.file_label = QLabel(fact(tr("File"), tr("{}-bit", 24)))
        for label in (self.source_label, self.file_label):
            label.setFont(theme.mono(11))
            label.setStyleSheet(f"background: transparent; color: {theme.TEXT_DIM};")
            facts.addWidget(label)
        bottom.addLayout(facts, 1)
        self.check_key = HardwareKey(tr("Check input"))
        self.check_key.clicked.connect(self.check_clicked)
        bottom.addWidget(self.check_key, 0, Qt.AlignRight | Qt.AlignVCenter)
        box.addLayout(bottom)
        return box

    def _spark_module(self) -> QVBoxLayout:
        box = QVBoxLayout()
        box.setSpacing(5)
        top = QHBoxLayout()
        top.addWidget(Engraving("Spark"))
        top.addStretch(1)
        self.connected_lamp = Lamp(tr("Connected"), "on", False, size=7)
        top.addWidget(self.connected_lamp)
        box.addLayout(top)
        row = QHBoxLayout()
        self.device_display = Display(radius=8)
        d = QVBoxLayout(self.device_display)
        d.setContentsMargins(10, 4, 10, 4)
        d.setSpacing(0)
        self.amp_label = QLabel("Spark")
        self.amp_label.setFont(theme.mono(13, True))
        self.amp_label.setStyleSheet(f"background: transparent; color: {theme.AMBER};")
        self.firmware_label = QLabel("")
        self.firmware_label.setFont(theme.mono(10))
        self.firmware_label.setStyleSheet(f"background: transparent; color: {theme.AMBER_DIM};")
        d.addWidget(self.amp_label)
        d.addWidget(self.firmware_label)
        self.device_display.setMinimumWidth(130)
        row.addWidget(self.device_display)
        self.connect_key = HardwareKey(tr("Connect"), "primary")
        self.connect_key.clicked.connect(self.connect_clicked)
        row.addWidget(self.connect_key, 0, Qt.AlignVCenter)
        box.addLayout(row)
        inp = QHBoxLayout()
        label = Engraving(tr("Input"))
        label.setFixedWidth(62)
        inp.addWidget(label)
        self.input_popup = DevicePopup(tr("Input"))
        self.input_popup.chosen.connect(self.input_chosen)
        inp.addWidget(self.input_popup, 1)
        box.addLayout(inp)
        return box

    def _click_module(self) -> QVBoxLayout:
        box = QVBoxLayout()
        box.addWidget(Engraving(tr("Click")))
        later = QLabel(tr("Click, count-in and\nRetro recording follow."))
        later.setFont(theme.sans(12))
        later.setStyleSheet(f"background: transparent; color: {theme.ENGRAVING};")
        box.addWidget(later)
        box.addStretch(1)
        return box

    # State

    def show_recorder(self, model) -> None:
        engine, meter = model.engine, model.engine.meter
        recording = model.is_recording
        self.record_key.set_recording(recording)
        if recording:
            self.state_lamp.set_state(True, tr("Recording"), "rec")
            self.time_label.setStyleSheet(f"background: transparent; color: #FFFFFF;")
            self.time_label.setText(time_text(meter.seconds))
            self.display.setStyleSheet("")
        else:
            self.state_lamp.set_state(True, tr("Checking input") if model.is_monitoring else tr("Ready"), "amber")
            self.time_label.setStyleSheet(f"background: transparent; color: {theme.AMBER};")
            self.time_label.setText(time_text(0))
        device = model.selected
        self.device_label.setText(device.title if device else tr("No Spark"))
        self.source_label.setText(fact(tr("Source"), f"{tr('{}-bit', device.bits)} · {khz(device.rate)} · "
                                                     f"{channels(device.channels)}" if device else DASH))
        self.file_label.setText(fact(tr("File"), "WAV " + tr("{}-bit", 24) + (f" · {khz(device.rate)}" if device else "")))
        self.check_key.setText(tr("Stop checking") if model.is_monitoring else tr("Check input"))
        self.check_key.set_style("on" if model.is_monitoring else "normal")
        self.check_key.setEnabled(not recording)
        self.input_popup.setEnabled(not recording)

    def show_levels(self, model) -> None:
        meter = model.engine.meter
        live = model.engine.is_open
        self.meter.set_levels(to_db(meter.level) if live else -120.0, to_db(meter.hold) if live else -120.0)
        self.clip_lamp.set_state(live and meter.clipped)
        quiet = live and meter.quiet_since is not None and (time_now() - meter.quiet_since) > 2.0
        self.silence_lamp.set_state(bool(quiet))
        if model.is_recording:
            self.time_label.setText(time_text(meter.seconds))

    def show_devices(self, model) -> None:
        options = [(d.title, d) for d in model.devices]
        self.input_popup.set_options(options, model.selected.title if model.selected else tr("No Spark"))


def time_now() -> float:
    import time
    return time.monotonic()
