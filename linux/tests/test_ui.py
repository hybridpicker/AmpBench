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
    app.setStyleSheet(theme.stylesheet())
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
    from spark_studio.demo_input import demo_devices, demo_engine
    from spark_studio.recorder import RecorderModel
    from spark_studio.store import LibraryStore
    recorder = RecorderModel(LibraryStore(tmp_path / "Aufnahmen"), demo_engine(), demo_devices)
    w = MainWindow(link, lib, auto_connect=True, recorder=recorder)
    w.show()
    w._area(1)
    wait_for(lambda: link.core.status == "connected" and all(link.core.slots) and not link.core.activity)
    monkeypatch.setattr(QMessageBox, "question", lambda *a, **k: QMessageBox.Yes)
    monkeypatch.setattr(QMessageBox, "warning", lambda *a, **k: pytest.fail(f"warning: {a[2]}"))
    yield w, amp
    w.editor = None  # nothing to ask on close
    w.close()


def test_slots_are_shown_and_open_in_the_editor(window):
    w, amp = window
    assert w.sidebar.rows[1].title == amp.slots[1].name
    w._slot_clicked(1)
    wait_for(lambda: amp.active == 1)
    assert w.name_edit.text() == amp.slots[1].name
    assert len(w.pedals) == 7 and all(p.isVisibleTo(w) for p in w.pedals)


def test_first_change_sends_the_whole_preset_then_single_parameters(window):
    w, amp = window
    w._slot_clicked(0)
    wait_for(lambda: not w.link.core.is_editing_live and amp.active == 0)
    w._select_place(3)
    knob = w.field.knob_row.itemAt(0).widget()
    knob.gesture_started.emit()
    knob._set_from_user(0.9)
    knob.gesture_ended.emit()
    wait_for(lambda: w.link.core.is_editing_live)
    assert amp.temporary is not None and abs(amp.temporary.effects[3].parameters[0].value - 0.9) < 1e-6
    knob.gesture_started.emit()
    knob._set_from_user(0.7)
    knob.gesture_ended.emit()
    wait_for(lambda: any(abs(v - 0.7) < 1e-6 for _, _, v in amp.parameters))
    assert w.editor.is_modified and w.lamp_live.lit
    w._undo()
    w._undo()
    assert not w.editor.is_modified


def test_ab_comparison_plays_the_saved_state_and_locks_the_controls(window):
    w, amp = window
    w._slot_clicked(1)
    w._toggle_place(5, True)
    wait_for(lambda: w.link.core.is_editing_live)
    assert w.editor.is_modified
    w._toggle_comparison()
    assert w.show_original and w.locked
    wait_for(lambda: amp.temporary is not None and not amp.temporary.effects[5].is_on)
    w._toggle_comparison()
    wait_for(lambda: amp.temporary.effects[5].is_on)
    assert not w.show_original


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
    w._model_chosen("Plexi")
    assert w.editor.current.effects[3].name == "Plexi"
    assert w.pedals[3].model_name == "Plexi Crunch"


def test_record_a_take_through_the_window(app, tmp_path):
    from spark_studio.demo_input import demo_devices, demo_engine
    from spark_studio.recorder import RecorderModel
    from spark_studio.store import LibraryStore
    amp = FakeAmp()
    recorder = RecorderModel(LibraryStore(tmp_path / "Aufnahmen"), demo_engine(), demo_devices)
    w = MainWindow(QtLink(lambda: amp), PresetLibrary(tmp_path / "Presets"), auto_connect=False, recorder=recorder)
    w.show()
    try:
        assert recorder.usable and recorder.selected is not None
        QTest.keyClick(w, __import__("PySide6.QtCore", fromlist=["Qt"]).Qt.Key_R)
        wait_for(lambda: recorder.is_recording)
        wait_for(lambda: recorder.engine.meter.seconds > 0.5)
        assert w.deck.time_label.text() != "00:00,0"
        QTest.keyClick(w, __import__("PySide6.QtCore", fromlist=["Qt"]).Qt.Key_R)
        wait_for(lambda: not recorder.is_recording and w.recordings.table.rowCount() == 1)
        take = recorder.store.document["recordings"][0]
        assert take["status"] == "open" and take["duration"] > 0.4
        assert not recorder.store.journal_path.exists()
    finally:
        w.close()


def test_recording_page_review_keys_and_undo(app, tmp_path, monkeypatch):
    from PySide6.QtCore import Qt
    from spark_studio import trash
    from spark_studio.demo_input import demo_devices, demo_engine
    from spark_studio.recorder import RecorderModel
    from spark_studio.store import LibraryStore
    monkeypatch.setattr("spark_studio.trash.trash_root", lambda: tmp_path / "Trash")
    recorder = RecorderModel(LibraryStore(tmp_path / "Aufnahmen"), demo_engine(), demo_devices)
    w = MainWindow(QtLink(lambda: FakeAmp()), PresetLibrary(tmp_path / "Presets"), auto_connect=False, recorder=recorder)
    w.show()
    page = w.recordings
    try:
        for _ in range(2):
            QTest.keyClick(w, Qt.Key_R)
            wait_for(lambda: recorder.is_recording and recorder.engine.meter.seconds > 0.4)
            QTest.keyClick(w, Qt.Key_R)
            wait_for(lambda: not recorder.is_recording)
            QTest.qWait(150)
        wait_for(lambda: page.table.rowCount() == 2)
        newest = page.recordings[0]
        assert page.current_id == newest["id"], "the new take is in focus"
        assert page.keep_key.isVisibleTo(page) and page.discard_key.isVisibleTo(page)
        QTest.keyClick(w, Qt.Key_M)
        assert len(recorder.store.recording(newest["id"])["markers"]) == 1
        QTest.keyClick(w, Qt.Key_Plus)
        assert page.player.tempo == pytest.approx(1.05)
        QTest.keyClick(w, Qt.Key_0)
        assert page.player.tempo == 1.0 and page.player.pitch == 0
        QTest.keyClick(w, Qt.Key_K)
        assert recorder.store.recording(newest["id"])["status"] == "kept" and not page.keep_key.isVisibleTo(page)
        QTest.keyClick(w, Qt.Key_Backspace)
        assert page.table.rowCount() == 1 and recorder.store.recording(newest["id"]) is None
        w._undo()
        assert page.table.rowCount() == 2 and recorder.store.recording(newest["id"])["status"] == "kept"
        # single keys never act while a text field has the focus
        w._area(1)
        w.name_edit.setFocus()
        QTest.keyClick(w.name_edit, Qt.Key_R)
        assert not recorder.is_recording
    finally:
        w.close()
