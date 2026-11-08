"""Drives the real window against the simulated amp, headless."""
import os

import pytest

pytest.importorskip("PySide6")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QApplication, QMessageBox  # noqa: E402

from spark_studio import factory  # noqa: E402
from spark_studio.fake_amp import FakeAmp  # noqa: E402
from spark_studio.library import PresetLibrary  # noqa: E402
from spark_studio.qtlink import QtLink  # noqa: E402
from spark_studio.ui import theme  # noqa: E402
from spark_studio.ui.main_window import MainWindow  # noqa: E402


@pytest.fixture(scope="module")
def app():
    app = QApplication.instance() or QApplication([])
    app.setStyle("Fusion")
    app.setStyleSheet(theme.STYLESHEET)
    return app


def wait_for(condition, timeout=4000):
    waited = 0
    while not condition() and waited < timeout:
        QTest.qWait(20)
        waited += 20
    assert condition(), "timed out"


@pytest.fixture
def window(app, tmp_path, monkeypatch):
    amp = FakeAmp()
    link = QtLink(lambda: amp)
    lib = PresetLibrary(tmp_path, trash=lambda p: p.unlink())
    w = MainWindow(link, lib, auto_connect=True)
    w.show()
    wait_for(lambda: link.core.status == "connected" and all(link.core.slots) and not link.core.activity)
    monkeypatch.setattr(QMessageBox, "question", lambda *a, **k: QMessageBox.Yes)
    monkeypatch.setattr(QMessageBox, "warning", lambda *a, **k: pytest.fail(f"warning: {a[2]}"))
    yield w, amp
    w.editor = None  # nothing to ask on close
    w.close()


def test_slots_are_shown_and_open_in_the_editor(window):
    w, amp = window
    assert "Crunch" in w.slot_list.item(1).text()
    w._slot_clicked(1)
    assert w.name_edit.text() == amp.slots[1].name
    assert len(w.pedals) == 7 and all(p.isVisibleTo(w) for p in w.pedals)


def test_turning_a_knob_live_reaches_the_amp(window):
    w, amp = window
    w._slot_clicked(0)
    w.live_button.click()
    wait_for(lambda: w.link.core.is_editing_live)
    w._select_place(3)
    knob = w.knob_row.itemAt(0).widget()
    knob.gesture_started.emit()
    knob._set_from_user(0.9)
    knob.gesture_ended.emit()
    wait_for(lambda: any(abs(v - 0.9) < 1e-6 for _, _, v in amp.parameters))
    assert w.editor.is_modified
    w._undo()
    assert not w.editor.is_modified


def test_store_backs_up_the_old_preset_then_writes_and_verifies(window):
    w, amp = window
    old_name = amp.slots[2].name
    w._new(factory.templates()[3])
    w.editor.set_name("Neu auf 3")
    w._store(2)
    wait_for(lambda: amp.slots[2].name == "Neu auf 3" and w.source == ("slot", 2))
    backups = [i for i in w.library.items if i.is_backup]
    assert len(backups) == 1 and backups[0].name == old_name
    assert not w.editor.is_modified


def test_save_creates_and_updates_a_file(window):
    w, _ = window
    w._new(None)
    w.editor.set_name("Datei")
    w._save()
    assert w.source[0] == "file" and w.source[1].path.name == "Datei.json"
    w._toggle_place(5, True)
    assert w.editor.is_modified
    w._save()
    assert not w.editor.is_modified
    assert any(i.name == "Datei" for i in w.library.items)


def test_model_change_updates_the_chain(window):
    w, _ = window
    w._new(None)
    w._select_place(3)
    row = w.model_combo.findData("Plexi")
    w._model_chosen(row)
    assert w.editor.current.effects[3].name == "Plexi"
    assert w.pedals[3].model_name == "Plexi Crunch"
