"""Drives the real window against the simulated amp, headless."""
import os

import pytest

pytest.importorskip("PySide6")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QApplication, QMessageBox  # noqa: E402

from ampbench import factory, i18n  # noqa: E402
from ampbench.fake_amp import FakeAmp  # noqa: E402
from ampbench.library import PresetLibrary  # noqa: E402
from ampbench.qtlink import QtLink  # noqa: E402
from ampbench.ui import theme  # noqa: E402
from ampbench.ui.main_window import MainWindow  # noqa: E402


@pytest.fixture(scope="module")
def app():
    app = QApplication.instance() or QApplication([])
    app.setStyle("Fusion")
    app.setStyleSheet(theme.stylesheet())
    return app


@pytest.fixture(autouse=True)
def english_again():
    yield
    i18n.set_language(i18n.ENGLISH)


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
    from ampbench.demo_input import demo_devices, demo_engine
    from ampbench.recorder import RecorderModel
    from ampbench.store import LibraryStore
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
    from ampbench.demo_input import demo_devices, demo_engine
    from ampbench.recorder import RecorderModel
    from ampbench.store import LibraryStore
    amp = FakeAmp()
    recorder = RecorderModel(LibraryStore(tmp_path / "Aufnahmen"), demo_engine(), demo_devices)
    w = MainWindow(QtLink(lambda: amp), PresetLibrary(tmp_path / "Presets"), auto_connect=False, recorder=recorder)
    w.show()
    try:
        assert recorder.usable and recorder.selected is not None
        QTest.keyClick(w, __import__("PySide6.QtCore", fromlist=["Qt"]).Qt.Key_R)
        wait_for(lambda: recorder.is_recording)
        wait_for(lambda: recorder.engine.meter.seconds > 0.5)
        assert w.deck.time_label.text() != "00:00.0"
        QTest.keyClick(w, __import__("PySide6.QtCore", fromlist=["Qt"]).Qt.Key_R)
        wait_for(lambda: not recorder.is_recording and w.recordings.table.rowCount() == 1)
        take = recorder.store.document["recordings"][0]
        assert take["status"] == "open" and take["duration"] > 0.4
        assert not recorder.store.journal_path.exists()
    finally:
        w.close()


def test_recording_page_review_keys_and_undo(app, tmp_path, monkeypatch):
    from PySide6.QtCore import Qt
    from ampbench import trash
    from ampbench.demo_input import demo_devices, demo_engine
    from ampbench.recorder import RecorderModel
    from ampbench.store import LibraryStore
    monkeypatch.setattr("ampbench.trash.trash_root", lambda: tmp_path / "Trash")
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


def test_library_views_rate_search_pieces_and_sound(app, tmp_path, monkeypatch):
    from PySide6.QtCore import Qt
    from ampbench import factory, protocol, store as storemod
    from ampbench.demo_input import demo_devices, demo_engine
    from ampbench.recorder import RecorderModel
    from ampbench.store import LibraryStore
    monkeypatch.setattr("ampbench.trash.trash_root", lambda: tmp_path / "Trash")
    recorder = RecorderModel(LibraryStore(tmp_path / "Aufnahmen"), demo_engine(), demo_devices)
    amp = FakeAmp()
    w = MainWindow(QtLink(lambda: amp), PresetLibrary(tmp_path / "Presets"), auto_connect=True, recorder=recorder)
    w.show()
    page = w.recordings
    try:
        wait_for(lambda: w.link.core.status == "connected" and all(w.link.core.slots) and not w.link.core.activity)
        w._slot_clicked(1)
        wait_for(lambda: w.link.core.active_slot == 1)
        w._area(0)
        QTest.keyClick(w, Qt.Key_R)
        wait_for(lambda: recorder.is_recording and recorder.engine.meter.seconds > 0.4)
        QTest.keyClick(w, Qt.Key_R)
        wait_for(lambda: not recorder.is_recording and page.table.rowCount() == 1)
        take = recorder.store.document["recordings"][0]
        assert take["preset"]["slot"] == 2 and take["preset"]["name"] == amp.slots[1].name
        assert page.inspector.sound_label.text().startswith(amp.slots[1].name)
        # rating and favorite by key and by click
        QTest.keyClick(w, Qt.Key_4)
        QTest.keyClick(w, Qt.Key_F)
        assert take["rating"] == 4 and take["favorite"] is True
        page.inspector.stars.mousePressEvent(type("E", (), {"position": lambda self: __import__("PySide6.QtCore", fromlist=["QPointF"]).QPointF(2, 5)})())
        assert take["rating"] == 1
        # a piece, assigned from the inspector
        page.create_piece("Blues in A", [take["id"]])
        assert take["pieceID"] == storemod.piece(recorder.store, take["pieceID"])["id"]
        assert page.takes.table.item(0, 5).text() == "Blues in A"
        page.mark_best(take["id"])
        assert storemod.piece(recorder.store, take["pieceID"])["bestTakeID"] == take["id"]
        page.set_piece_for_new(take["pieceID"])
        assert recorder.current_piece_id == take["pieceID"]
        # search narrows the table
        page.takes.search.setText("gibt es nicht")
        assert page.table.rowCount() == 0
        page.takes.search.setText("blues")
        assert page.table.rowCount() == 1
        page.takes.search.setText("")
        # tags and notes are saved
        page.update_take(take["id"], {"tags": ["Blues", "Üben"], "note": "langsam"})
        assert recorder.store.recording(take["id"])["tags"] == ["Blues", "Üben"]
        # the sound of the take opens in the editor as a new preset
        page.inspector.editor_key.click()
        assert w.stack.currentIndex() == 1 and w.source == ("new", None)
        assert protocol.fingerprint(w.editor.current) == take["preset"]["sha256"]
        # renaming renames the file
        page.rename_marker  # exists
        page._rename_to(take["id"], "Mein Take")
        assert (recorder.store.folder / "Mein Take.wav").exists()
    finally:
        w.editor = None
        w.close()


def test_tags_filter_and_pinned_sections(window, monkeypatch):
    w, _ = window
    from PySide6.QtCore import QSettings
    from PySide6.QtWidgets import QInputDialog
    QSettings("local.ampbench", "AmpBench").remove("pinnedTags")
    w.sidebar.pinned = []
    clean = w.library.save(factory.empty("Clean A"), "Test", tags=["#basis", "clean"])
    w.library.save(factory.empty("Lead B"), "Test", tags=["song"])
    w._refresh_library()
    files = lambda: [r.title for r in w.sidebar.rows if r.kind == "file"]
    assert files() == ["Clean A", "Lead B"]
    assert w.sidebar.tag_counts() == [("basis", 1), ("clean", 1), ("song", 1)]

    w.sidebar.toggle_filter("basis")
    assert files() == ["Clean A"]
    w.sidebar.toggle_filter("basis")
    w.sidebar.toggle_pin("basis")
    assert files() == ["Clean A", "Clean A", "Lead B"], "in its pinned section and in the full list"
    w.sidebar.search.setText("#so")
    assert files() == ["Lead B"]
    w.sidebar.search.setText("")

    monkeypatch.setattr(QInputDialog, "getText", lambda *a, **k: ("#unterricht clean", True))
    w._edit_tags(clean)
    assert next(i for i in w.library.items if i.name == "Clean A").tags == ["unterricht", "clean"]
    w.sidebar.toggle_pin("basis")


def test_the_kemper_import_writes_presets_and_pieces(window, tmp_path):
    w, _ = window
    from test_kemper import _library
    from ampbench import kemper
    from ampbench.ui.kemper_dialog import KemperDialog
    plan = kemper.Plan(_library(tmp_path))
    dialog = KemperDialog(plan, "test.kpabackup", w)
    assert dialog.summary.text() == "1 songs, 2 setups, 0 rigs"
    dialog.kind_boxes[2][1].setCurrentIndex(list(kemper.KINDS).index("skip"))
    w._run_kemper_import(dialog.apply())
    names = sorted(i.name for i in w.library.items)
    # "Quick Setup" plays the same two sounds: one preset each, with the tags of both uses.
    assert names == ["Can't Stop · Comping", "Can't Stop · Solo"]
    comping = next(i for i in w.library.items if i.name == "Can't Stop · Comping")
    assert "song" in comping.tags and "basis" in comping.tags and "unterricht" not in comping.tags
    pieces = w.recorder.store.document["pieces"]
    assert [p["name"] for p in pieces] == ["Can't Stop"]
    assert [p["name"] for p in pieces[0]["parts"]] == ["Comping", "Solo"]
    assert w.sidebar.is_pinned("basis") and w.sidebar.is_pinned("song")
    w.sidebar.pinned = []
    w.sidebar._settings.remove("pinnedTags")


def test_the_tuner_listens_only_while_its_area_shows(window):
    w, amp = window
    tuner = w.tuner
    tuner.choose("deck")
    w._area(2)
    wait_for(lambda: tuner.status == "listening")
    assert w.recorder.is_sharing(tuner._listener)
    # The simulated Spark input plays a 220 Hz pluck twice a second: the tuner hears it through the shared input.
    tuner.set_tuning("chromatic")
    wait_for(lambda: tuner.readout is not None and tuner.readout.note_name == "A" and abs(tuner.readout.cents) < 1,
             timeout=6000)
    assert tuner.readout.note.octave == 3
    assert w.tuner_view.note.text() == "A"
    tuner.set_tuning("standard")
    w._area(1)
    assert tuner.status == "idle" and not w.recorder.engine.is_open, "leaving the area closes the input"


def test_the_amps_own_tuner_is_on_only_while_the_area_shows(window):
    w, amp = window
    tuner = w.tuner
    tuner.choose("amp")
    w._area(2)
    wait_for(lambda: amp.tuner_on and tuner.status == "listening")
    assert tuner.uses_amp
    w._area(1)
    wait_for(lambda: not amp.tuner_on)
    tuner.choose("automatic")


def test_tuner_settings_are_kept(window):
    w, _ = window
    from ampbench.tuner import TunerModel
    tuner = w.tuner
    tuner.set_a4(441.26)
    tuner.set_tuning("dadgad")
    tuner.set_strobe(True)
    assert tuner.a4 == 441.3
    again = TunerModel()
    assert (again.a4, again.tuning.key, again.shows_strobe) == (441.3, "dadgad", True)
    tuner.set_a4(470)
    assert tuner.a4 == 450
    tuner.set_a4(400)
    assert tuner.a4 == 430
    tuner.set_a4(440)
    tuner.set_tuning("standard")
    tuner.set_strobe(False)


def test_the_ai_sound_window_offers_plays_and_keeps(window, monkeypatch, tmp_path):
    w, amp = window
    from PySide6.QtCore import QSettings
    from ampbench import sound_ai
    from ampbench.ui import ai_sound_dialog
    from test_sound_ai import recipe
    monkeypatch.setattr(ai_sound_dialog.ai_key, "load", lambda: "test-key")
    answers = {"Variant A": recipe(name="Rock A", amp="Plexi"), "Variant B": recipe(name="Rock B", amp="SLO100"),
               "Variant C": recipe(name="Rock C", amp="Twin")}

    def factory(model, key, cancelled):
        assert key == "test-key"
        return lambda messages, temperature: next(v for k, v in answers.items() if k in messages[1]["content"])

    played, kept = [], []
    settings = QSettings(str(tmp_path / "ai.ini"), QSettings.IniFormat)
    dialog = ai_sound_dialog.AISoundDialog(lambda p: played.append(p) or None, kept.append, w, settings, factory)
    assert dialog.stack.currentIndex() == 1, "with a key it starts at the wish"
    dialog.request_field.setPlainText("Rock für die Telecaster")
    dialog.generate()
    wait_for(lambda: all(o.recipe is not None for o in dialog.offers))
    assert [o.recipe["name"] for o in dialog.offers] == ["Rock A", "Rock B", "Rock C"]
    assert dialog.history[0] == "Rock für die Telecaster"
    dialog.listen(1)
    assert played and played[0].name == "Rock B" and dialog.listening == 1
    dialog.pick(1)
    assert kept[0]["name"] == "Rock B" and "KI-Sound" in kept[0]["tags"]
    assert kept[0]["description"].startswith("AI Sound: “Rock für die Telecaster”")
    sound_ai.recipemod.to_preset(kept[0])


def test_kept_ai_sound_lands_in_the_library(window):
    w, _ = window
    from test_sound_ai import recipe
    import json
    data = json.loads(recipe(name="KI Probe"))
    path = w.library.add_recipe(data)
    w._refresh_library()
    item = next(i for i in w.library.items if i.path == path)
    assert item.is_recipe and item.name == "KI Probe"


def test_the_window_speaks_english(window):
    w, _ = window
    assert w.windowTitle() == "AmpBench"
    assert [a.text() for a in w.menuBar().actions()] == ["View", "Presets", "Edit", "Amp", "Chain", "Tuner", "Help"]
    assert w.tabs.names == ["Record", "Presets", "Tuner"]
    assert w.recordings.library_tabs.names == ["Takes", "Pieces", "Statistics"]
    assert w.save_key.text() == "Save" and w.connect_key.text() == "Disconnect"
    assert w.recordings.play_key.text() == "Play" and w.deck.check_key.text() == "Check input"
    assert w.tuner_view.lamp_in_tune.text == "In tune"
    assert w.deck.time_label.text() == "00:00.0"
    assert w.recordings.takes.COLUMNS[:3] == ["Name", "Date", "Length"]


def test_the_window_speaks_german_when_asked(app, tmp_path):
    from datetime import datetime
    from ampbench.demo_input import demo_devices, demo_engine
    from ampbench.recorder import RecorderModel
    from ampbench.store import LibraryStore
    from ampbench.ui import formats
    i18n.set_language(i18n.GERMAN)
    recorder = RecorderModel(LibraryStore(tmp_path / "Aufnahmen"), demo_engine(), demo_devices)
    w = MainWindow(QtLink(lambda: FakeAmp()), PresetLibrary(tmp_path / "Presets"), auto_connect=False, recorder=recorder)
    try:
        assert [a.text() for a in w.menuBar().actions()][:4] == ["Darstellung", "Presets", "Bearbeiten", "Verstärker"]
        assert w.tabs.names == ["Aufnahme", "Presets", "Stimmgerät"]
        assert w.save_key.text() == "Sichern" and w.connect_key.text() == "Verbinden"
        assert w.recordings.library_tabs.names == ["Aufnahmen", "Stücke", "Statistik"]
        assert w.deck.time_label.text() == "00:00,0"
        assert w.tuner_view.lamp_in_tune.text == "Gestimmt"
        day = datetime(2026, 11, 5, 14, 3, 9)
        assert formats.date_time(day) == "5. Nov. 2026, 14:03" and formats.khz(44100) == "44,1 kHz"
        assert formats.signed(-1.5) + " dB" == "-1,5 dB" and formats.minutes_text(75) == "1 Std. 15 Min."
        i18n.set_language(i18n.ENGLISH)
        assert formats.date_time(day) == "Nov 5, 2026, 14:03" and formats.khz(44100) == "44.1 kHz"
        assert formats.signed(-1.5) + " dB" == "-1.5 dB" and formats.minutes_text(75) == "1 h 15 min"
    finally:
        w.close()


def test_the_language_menu_stores_the_choice(window, tmp_path, monkeypatch):
    w, _ = window
    from PySide6.QtCore import QSettings
    from ampbench.ui import main_window
    settings = lambda: QSettings(str(tmp_path / "language.ini"), QSettings.IniFormat)
    monkeypatch.setattr(main_window, "app_settings", settings)
    assert [a.text() for a in w.language_actions.values()] == ["System", "English", "Deutsch"]
    w.language_actions[i18n.GERMAN].trigger()
    assert settings().value(i18n.SETTINGS_KEY) == "de" and w.language_actions[i18n.GERMAN].isChecked()
    assert w.banner.label.text() == "The language changes after you restart AmpBench."
    assert i18n.language() == i18n.ENGLISH, "the running window keeps its language"
    w.language_actions[None].trigger()
    assert settings().value(i18n.SETTINGS_KEY) is None and w.language_actions[None].isChecked()
