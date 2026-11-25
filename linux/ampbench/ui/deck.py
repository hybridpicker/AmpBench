"""The deck: the fixed front on top of the window. Recording, level, the Spark and the click."""
from __future__ import annotations

from PySide6.QtCore import QPointF, Qt, Signal
from PySide6.QtGui import QPainter
from PySide6.QtWidgets import (QCheckBox, QComboBox, QDoubleSpinBox, QFormLayout, QFrame, QHBoxLayout, QLabel,
                               QPushButton, QSlider, QVBoxLayout, QWidget)

from . import theme
from .formats import channels, clock, khz
from .theme import c
from .widgets import (DevicePopup, Display, DisplayStepper, Engraving, Front, HardwareKey, Lamp, LEDMeter, RecordKey)
from ..capture import to_db
from ..i18n import number, tr

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


METERS = (2, 3, 4, 5, 6, 7, 9, 12)


class BeatLamps(QWidget):
    """Up to four dots, the current beat of the bar lit."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.beats, self.current = 4, -1
        self.setFixedSize(4 * 9, 16)

    def show_beat(self, beats: int, current: int) -> None:
        if (beats, current) != (self.beats, self.current):
            self.beats, self.current = beats, current
            self.update()

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setPen(Qt.NoPen)
        for index in range(min(max(self.beats, 1), 4)):
            p.setBrush(c(theme.ON) if index == self.current else c(theme.LAMP_OFF))
            p.drawEllipse(QPointF(4 + index * 9, 8), 3, 3)


class ClickDetails(QFrame):
    """Behind "⋯": volume, the click on or off, and where it goes while recording (Mac: MetronomeDetails)."""
    volume_changed = Signal(float)
    click_toggled = Signal()
    output_chosen = Signal(object)  # a node name, or None for automatic
    amp_part_set = Signal(float)  # seconds, set by hand
    measure_requested = Signal()

    def __init__(self, parent=None):
        super().__init__(parent, Qt.Popup)
        self.setFixedWidth(330)
        self.setStyleSheet(f"ClickDetails {{ background: {theme.PANEL_TOP}; border: 1px solid {theme.FIELD_EDGE}; "
                           f"border-radius: 8px; }} QLabel {{ color: {theme.TEXT}; }}")
        form = QFormLayout(self)
        form.setContentsMargins(14, 12, 14, 12)
        self.volume = QSlider(Qt.Horizontal)
        self.volume.setRange(0, 100)
        self.volume.valueChanged.connect(lambda v: self.volume_changed.emit(v / 100))
        form.addRow(tr("Volume"), self.volume)
        self.on = QCheckBox(tr("Click on"))
        self.on.clicked.connect(lambda _: self.click_toggled.emit())
        form.addRow(self.on)
        form.addRow(self._note(tr("It can only be heard while playing and recording. While playing it is on the "
                                  "playback output, while recording on the click output. A count-in always "
                                  "sounds.")))
        self.output = QComboBox()
        self.output.setStyleSheet(f"QComboBox {{ background: {theme.FIELD}; color: {theme.FIELD_TEXT}; "
                                  f"border: 1px solid {theme.FIELD_EDGE}; border-radius: 6px; padding: 3px 8px; }}")
        self.output.activated.connect(lambda i: self.output_chosen.emit(self.output.itemData(i)))
        form.addRow(tr("Click output"), self.output)
        self.goes_to = self._note("")
        form.addRow(self.goes_to)
        self.compensation = QDoubleSpinBox()
        self.compensation.setRange(-100.0, 300.0)
        self.compensation.setSingleStep(0.5)
        self.compensation.setDecimals(1)
        self.compensation.setSuffix(" ms")
        self.compensation.setKeyboardTracking(False)
        self.compensation.setStyleSheet(f"QDoubleSpinBox {{ background: {theme.FIELD}; color: {theme.FIELD_TEXT}; "
                                        f"border: 1px solid {theme.FIELD_EDGE}; border-radius: 6px; padding: 3px 8px; }}")
        self.compensation.valueChanged.connect(lambda v: self.amp_part_set.emit(v / 1000))
        form.addRow(tr("Compensation"), self.compensation)
        self.origin = self._note("")
        self.origin.setStyleSheet(f"color: {theme.TEXT};")
        form.addRow(self.origin)
        self.explanation = self._note("")
        form.addRow(self.explanation)
        self.measure = QPushButton(tr("Measure latency with a cable …"))
        self.measure.clicked.connect(self._measure)
        form.addRow(self.measure)
        form.addRow(self._note(tr("The app never puts the click into the file. Outputs of the same device are "
                                  "skipped until a measurement shows that they do not arrive at the input.")))

    @staticmethod
    def _note(text: str) -> QLabel:
        label = QLabel(text)
        label.setWordWrap(True)
        label.setFont(theme.sans(11))
        label.setStyleSheet(f"color: {theme.TEXT_DIM};")
        return label

    def _measure(self) -> None:
        self.hide()
        self.measure_requested.emit()

    def show_state(self, settings, recorder) -> None:
        self.volume.blockSignals(True)
        self.volume.setValue(int(round(settings.volume * 100)))
        self.volume.blockSignals(False)
        self.on.setChecked(settings.click_enabled)
        self.output.clear()
        self.output.addItem(tr("Automatic"), None)
        for device in recorder.outputs:
            self.output.addItem(device.title, device.node_name)
        chosen = recorder.chosen_click_output
        index = self.output.findData(chosen) if chosen else 0
        self.output.setCurrentIndex(max(index, 0))
        target = recorder.click_output
        if not recorder.can_click:
            self.goes_to.setText(tr("The click needs ampbench-rt, which is not built here. Run linux/install.sh "
                                    "again once a C compiler is there."))
        elif target is not None:
            self.goes_to.setText(tr("While recording, the click goes to “{}”.", target.title))
        else:
            self.goes_to.setText(tr("Right now there is no output that is certain not to reach the recording."))
        part = recorder.amp_part
        self.compensation.blockSignals(True)
        self.compensation.setValue(part.seconds * 1000 if part else 0.0)
        self.compensation.blockSignals(False)
        for widget in (self.compensation, self.origin, self.explanation, self.measure):
            widget.setVisible(target is not None and recorder.can_click)
        if part is None:
            self.origin.setText(tr("Not measured yet."))
        elif part.measured:
            day = (part.date or "")[:10]
            self.origin.setText(tr("Measured on {}, spread {} ms.", day, number(part.spread * 1000, 1)))
        else:
            self.origin.setText(tr("Set by hand."))
        reported = recorder.reported_latency
        self.explanation.setText(tr(
            "The devices report {} from the click into the file; the app always compensates for that. The "
            "compensation is added for what the amp delays internally. It belongs to the amp and applies to new "
            "takes with every wired click output.",
            tr("{} ms", number(reported * 1000, 1)) if reported is not None else tr("unknown")))
        self.measure.setEnabled(recorder.can_measure_latency)


class Deck(Front):
    connect_clicked = Signal()
    record_clicked = Signal()
    check_clicked = Signal()
    input_chosen = Signal(object)
    click_toggled = Signal()
    tempo_changed = Signal(int)
    meter_chosen = Signal(int)
    tap_clicked = Signal()
    count_in_chosen = Signal(int)
    click_volume_changed = Signal(float)
    click_output_chosen = Signal(object)
    amp_part_set = Signal(float)
    measure_requested = Signal()

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
        box.setSpacing(5)
        top = QHBoxLayout()
        top.addWidget(Engraving(tr("Click")))
        top.addStretch(1)
        self.beat_lamps = BeatLamps()
        top.addWidget(self.beat_lamps)
        self.click_lamp = ClickLampKey()
        self.click_lamp.clicked.connect(self.click_toggled)
        self.click_lamp.setToolTip(tr("Click on or off (N). It can only be heard while playing and recording."))
        top.addWidget(self.click_lamp)
        box.addLayout(top)
        tempo = QHBoxLayout()
        tempo.setSpacing(6)
        self.tempo = DisplayStepper(20, 400, signed=False)
        self.tempo.changed.connect(self.tempo_changed)
        self.tempo.setToolTip(tr("Tempo"))
        tempo.addWidget(self.tempo)
        bpm = QLabel("BPM")
        bpm.setFont(theme.sans(10, bold=True, spacing=0.09))
        bpm.setStyleSheet(f"background: transparent; color: {theme.ENGRAVING};")
        tempo.addWidget(bpm)
        self.meter_popup = DevicePopup(tr("Time signature"))
        self.meter_popup.setMinimumWidth(64)
        self.meter_popup.setFixedWidth(64)
        self.meter_popup.set_options([(f"{n}/4", n) for n in METERS], "4/4")
        self.meter_popup.chosen.connect(lambda n: self.meter_chosen.emit(int(n)))
        self.meter_popup.setToolTip(tr("Time signature"))
        tempo.addWidget(self.meter_popup)
        self.tap_key = HardwareKey(tr("Tap"), keycap="T")
        self.tap_key.setToolTip(tr("Tap in the tempo (T)"))
        self.tap_key.clicked.connect(self.tap_clicked)
        tempo.addWidget(self.tap_key)
        box.addLayout(tempo)
        count = QHBoxLayout()
        count.setSpacing(8)
        self.count_in_popup = DevicePopup(tr("Count-in before recording"))
        self.count_in_popup.setMinimumWidth(150)
        self.count_in_popup.set_options(COUNT_INS(), COUNT_INS()[0][0])
        self.count_in_popup.chosen.connect(lambda n: self.count_in_chosen.emit(int(n)))
        count.addWidget(self.count_in_popup, 1)
        self.details_key = HardwareKey("⋯")
        self.details_key.setToolTip(tr("Count-in, volume and click output"))
        self.details_key.clicked.connect(self._show_details)
        count.addWidget(self.details_key)
        box.addLayout(count)
        self.details = ClickDetails(self)
        self.details.volume_changed.connect(self.click_volume_changed)
        self.details.click_toggled.connect(self.click_toggled)
        self.details.output_chosen.connect(self.click_output_chosen)
        self.details.amp_part_set.connect(self.amp_part_set)
        self.details.measure_requested.connect(self.measure_requested)
        self._details_state = None
        return box

    def _show_details(self) -> None:
        if self._details_state is not None:
            self.details.show_state(*self._details_state)
        self.details.move(self.details_key.mapToGlobal(self.details_key.rect().bottomRight())
                          - QPointF(self.details.width(), -4).toPoint())
        self.details.show()

    def show_click(self, settings, recorder, beat_index: int | None) -> None:
        """The click module: what the metronome's settings say, and the beat of the running click or playback."""
        self._details_state = (settings, recorder)
        if self.details.isVisible():
            self.details.show_state(settings, recorder)
        self.click_lamp.set_on(settings.click_enabled)
        self.tempo.set_value(int(round(settings.bpm)))
        self.meter_popup.set_options([(f"{n}/4", n) for n in METERS], f"{settings.beats_per_bar}/4")
        options = COUNT_INS()
        self.count_in_popup.set_options(options, options[min(max(settings.count_in_bars, 0), 2)][0])
        idle = not recorder.is_recording
        for widget in (self.tempo, self.meter_popup, self.tap_key, self.count_in_popup):
            widget.setEnabled(idle)
        beats = max(settings.beats_per_bar if idle or not recorder.active_grid else recorder.active_grid.beats_per_bar,
                    1)
        self.beat_lamps.show_beat(beats, beat_index % beats if beat_index is not None else -1)

    # State

    def show_recorder(self, model) -> None:
        engine, meter = model.engine, model.engine.meter
        recording = model.is_recording
        self.record_key.set_recording(recording)
        self.record_key.setToolTip(tr("Cancel count-in (R)") if model.is_counting_in else "")
        if model.is_counting_in:
            self.state_lamp.set_state(True, tr("Count-in {}", model.count_in_left) if model.count_in_left
                                      else tr("Count-in"), "hot")
            self.time_label.setStyleSheet(f"background: transparent; color: {theme.AMBER};")
            self.time_label.setText(time_text(0))
        elif recording:
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
        if model.is_counting_in:
            self.state_lamp.set_state(True, tr("Count-in {}", model.count_in_left) if model.count_in_left
                                      else tr("Count-in"), "hot")
        elif model.is_recording:
            self.time_label.setText(time_text(meter.seconds))

    def show_devices(self, model) -> None:
        options = [(d.title, d) for d in model.devices]
        self.input_popup.set_options(options, model.selected.title if model.selected else tr("No Spark"))


def COUNT_INS() -> list[tuple[str, int]]:  # noqa: N802 – the texts follow the language, so they are made late
    return [(tr("No count-in"), 0), (tr("Count in 1 bar"), 1), (tr("Count in 2 bars"), 2)]


class ClickLampKey(Lamp):
    """The click's lamp is a key: "On · N" or "Off · N"."""
    clicked = Signal()

    def __init__(self, parent=None):
        super().__init__(tr("Off · N"), "on", False, size=7, parent=parent)
        self.setCursor(Qt.PointingHandCursor)

    def set_on(self, on: bool) -> None:
        self.set_state(on, tr("On · N") if on else tr("Off · N"))

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton and self.isEnabled():
            self.clicked.emit()


def time_now() -> float:
    import time
    return time.monotonic()
