"""The window for importing a Kemper Profiler's sounds: per performance song, basic setup, lesson or skip, single
rigs to tick. Shows for every slot which Spark amp it becomes and which Kemper effects the Spark has nothing for."""
from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (QCheckBox, QComboBox, QDialog, QDialogButtonBox, QHBoxLayout, QLabel, QScrollArea,
                               QVBoxLayout, QWidget)

from .. import catalog, kemper
from . import theme


def _slot_line(number, name: str, translation: kemper.Translation) -> str:
    info = catalog.load().known(translation.amp_model)
    text = f"{number} " if number else ""
    text += f"{name} → {info.name if info else translation.amp_model}  #{translation.character}"
    if translation.left_out:
        text += "\n     Ohne: " + ", ".join(translation.left_out)
    return text


class KemperDialog(QDialog):
    def __init__(self, plan: kemper.Plan, file_name: str, parent=None):
        super().__init__(parent)
        self.plan = plan
        self.setWindowTitle("Vom Kemper übernehmen")
        self.resize(720, 620)
        layout = QVBoxLayout(self)
        title = QLabel(f"Vom Kemper übernehmen  ·  {file_name}")
        title.setFont(theme.sans(14, bold=True))
        layout.addWidget(title)
        intro = QLabel("Jeder Rig wird zum nächstliegenden Spark-Sound: passender Amp, Gain und EQ, die Effekte, die "
                       "der Spark kennt. Ein Kemper-Profil ist eine Aufnahme des echten Amps, darum jeden Sound am "
                       "Verstärker anhören. Zum Kemper wird nichts gesendet.")
        intro.setWordWrap(True)
        intro.setStyleSheet(f"color: {theme.DESK_MUTED};")
        layout.addWidget(intro)

        body = QWidget()
        column = QVBoxLayout(body)
        column.setSpacing(10)
        self.kind_boxes: list[tuple[kemper.PlanPerformance, QComboBox]] = []
        for performance in plan.performances:
            row = QHBoxLayout()
            name = QLabel(f"{performance.number}.  {performance.name}")
            name.setFont(theme.sans(12, bold=True))
            box = QComboBox()
            for key, (label, _) in kemper.KINDS.items():
                box.addItem(label, key)
            box.setCurrentIndex(list(kemper.KINDS).index(performance.kind))
            box.setAccessibleName(f"Art von „{performance.name}“")
            box.currentIndexChanged.connect(self._update_summary)
            row.addWidget(name, 1)
            row.addWidget(box)
            column.addLayout(row)
            lines = QLabel("\n".join(_slot_line(s.number, s.name, s.translation) for s in performance.slots))
            lines.setContentsMargins(18, 0, 0, 0)
            lines.setStyleSheet(f"color: {theme.DESK_MUTED};")
            column.addWidget(lines)
            self.kind_boxes.append((performance, box))
        self.rig_boxes: list[tuple[kemper.PlanRig, QCheckBox]] = []
        if plan.rigs:
            heading = QLabel(f"Einzelne Rigs ({len(plan.rigs)})")
            heading.setFont(theme.sans(12, bold=True))
            column.addWidget(heading)
            for rig in plan.rigs:
                box = QCheckBox(_slot_line(None, rig.name, rig.translation))
                box.setChecked(rig.is_chosen)
                box.toggled.connect(self._update_summary)
                column.addWidget(box)
                self.rig_boxes.append((rig, box))
        column.addStretch(1)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        scroll.setWidget(body)
        layout.addWidget(scroll, 1)

        self.summary = QLabel()
        self.summary.setStyleSheet(f"color: {theme.DESK_MUTED};")
        layout.addWidget(self.summary)
        self.buttons = QDialogButtonBox(QDialogButtonBox.Cancel | QDialogButtonBox.Ok)
        self.buttons.button(QDialogButtonBox.Ok).setText("Übernehmen")
        self.buttons.button(QDialogButtonBox.Cancel).setText("Abbrechen")
        self.buttons.accepted.connect(self.accept)
        self.buttons.rejected.connect(self.reject)
        layout.addWidget(self.buttons)
        self._update_summary()

    def apply(self) -> kemper.Plan:
        """Writes the choices into the plan and returns it."""
        for performance, box in self.kind_boxes:
            performance.kind = box.currentData()
        for rig, box in self.rig_boxes:
            rig.is_chosen = box.isChecked()
        return self.plan

    def _update_summary(self, *_) -> None:
        kinds = [box.currentData() for _, box in self.kind_boxes]
        rigs = sum(1 for _, box in self.rig_boxes if box.isChecked())
        self.summary.setText(f"{kinds.count('song')} Songs, {kinds.count('basis') + kinds.count('lesson')} Setups, "
                             f"{rigs} Rigs")
        anything = any(kind != "skip" for kind in kinds) or rigs > 0
        self.buttons.button(QDialogButtonBox.Ok).setEnabled(anything)
