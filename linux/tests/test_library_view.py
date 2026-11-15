"""The library overlay in the real window against the simulated amp, headless, with made-up sounds in a temporary
folder. No real preset, take or setting is touched: a test folder neither reads nor writes what the app
remembers."""
import os

import pytest

pytest.importorskip("PySide6")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QSettings, Qt  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QApplication, QDialog, QMessageBox  # noqa: E402

from ampbench import factory, made_up  # noqa: E402
from ampbench import library_query as q  # noqa: E402
from test_ui import app, english_again, wait_for, window  # noqa: E402,F401 - fixtures


def menu_action(w, text):
    return next(a for menu in w.menuBar().actions() for a in menu.menu().actions() if a.text() == text)


@pytest.fixture
def full(window):
    """The window with about a hundred made-up sounds."""
    w, amp = window
    made_up.fill(w.library.folder)
    w.library.reload()
    w._refresh_library()
    return w, amp


def named(w, name):
    return next(i for i in w.library.items if i.name == name)


def test_the_sidebar_is_short_and_leads_into_the_library(full):
    w, _ = full
    kinds = {r.kind for r in w.sidebar.rows}
    assert "backup" not in kinds
    files = [r.title for r in w.sidebar.rows if r.kind == "file"]
    assert files == ["Harbor clean (old)", "Spark slot 2 sound", "Warm Jazz Box"], "only the favorites"
    entries = {r.title: r for r in w.sidebar.rows if r.kind == "entry"}
    assert entries["All sounds"].count == 96 and entries["To listen"].count == 52
    assert entries["Slot backups"].count == 3
    assert w.sidebar.search.count == 96
    entries["To listen"].clicked.emit(entries["To listen"])
    lv = w.library_view
    assert lv.is_open and lv.overlay.search.hasFocus()
    assert len(lv.overlay.shown_names()) == 52
    QTest.keyClick(lv.overlay.search, Qt.Key_Escape)
    assert not lv.is_open
    w.sidebar.search.click()
    assert lv.is_open and len(lv.overlay.shown_names()) == 52, "as it was left"


def test_search_keys_and_hearing(full):
    w, amp = full
    lv, o = w.library_view, w.library_view.overlay
    menu_action(w, "Sound library").trigger()
    assert lv.is_open
    o.show_all()
    QTest.keyClicks(o.search, "glass verse")
    assert o.shown_names() == ["Glass Harbor Verse"]
    assert o.count_label.text() == "1 OF 96 SOUNDS"
    QTest.keyClick(o.search, Qt.Key_Return)
    wait_for(lambda: w.link.core.tried_preset is not None and w.link.core.tried_preset.name == "Glass Harbor Verse")
    assert w.editor is None, "hearing leaves the editor as it was"
    o.search.setText("#basis")
    assert len(o.shown_names()) == 15
    QTest.keyClick(o.search, Qt.Key_Down)
    assert o.table.hasFocus() and o.table.currentItem() is not None
    menu_action(w, "Open in the editor").trigger()
    assert not lv.is_open and w.editor is not None and w.editor.current.name.startswith("Basis")
    assert w.sidebar.recent_keys[0] == w.source[1].id
    assert w.source[1].name in [r.title for r in w.sidebar.rows if r.kind == "file"], "under Recently used"


def test_filters_groups_and_close_sounds(full):
    w, _ = full
    lv, o = w.library_view, w.library_view.overlay
    before = QSettings("local.ampbench", "AmpBench").value("libraryGrouping")
    lv.open({("tag", "song"), ("origin", q.KEMPER)})
    assert len(o.shown_names()) == 60
    o.set_grouping(q.TAG, emit=True)
    titles = [o.table.topLevelItem(i).text(0).split("   ")[0] for i in range(o.table.topLevelItemCount())]
    assert "#song" not in titles and titles[0].startswith("#"), "the tag filtered by makes no group"
    assert QSettings("local.ampbench", "AmpBench").value("libraryGrouping") == before, \
        "a test folder does not change what the app remembers"
    menu_action(w, "Next grouping").trigger()
    assert o.grouping == q.AMP_GROUPS
    lv.open({("scope", q.CLOSE)})
    titles = [o.table.topLevelItem(i).text(0) for i in range(o.table.topLevelItemCount())]
    assert titles and all(t.startswith("Close to") for t in titles)
    o.select_paths([named(w, "Harbor clean, brighter").path])
    near = [b.text().split("\n")[0] for b in o.preview.findChildren(type(o.unreadable_key))
            if "\n" in b.text()]
    assert "Glass Harbor Verse" in near and "Harbor clean (old)" in near


def test_marks_and_tags_for_several_sounds(full):
    w, _ = full
    lv, o = w.library_view, w.library_view.overlay
    lv.open({("tag", "Basis1")})
    o.table.selectAll()
    assert len(o.selected_items()) == 5
    menu_action(w, "To listen on or off").trigger()  # four of five are marked: all get it
    assert all(q.needs_listen(i) for i in w.library.items if "Basis1" in i.tags)
    assert w.recording_banner.label.text() == "5 sounds are marked to listen to."
    menu_action(w, "To listen on or off").trigger()
    assert not any(q.needs_listen(i) for i in w.library.items if "Basis1" in i.tags)
    menu_action(w, "Favorite on or off").trigger()
    assert all(i.favorite for i in w.library.items if "Basis1" in i.tags)
    assert len(o.selected_items()) == 5, "the selection stays"
    o.focus_tags()
    o.tag_field.setText("#warm, live")
    QTest.keyClick(o.tag_field, Qt.Key_Return)
    assert all({"warm", "live"} <= set(i.tags) for i in w.library.items if "Basis1" in i.tags)
    o.remove_tag.emit(o.selected_items(), "LIVE")
    assert not any("live" in i.tags for i in w.library.items)
    o.notes.emit(named(w, "Basis 1 · 1"), "Made-up note")
    assert named(w, "Basis 1 · 1").notes == "Made-up note"


def test_several_sounds_are_renamed_by_replacing_a_text(full, monkeypatch):
    w, _ = full
    lv, o = w.library_view, w.library_view.overlay
    from ampbench.ui import library_controller

    def answer(dialog):
        dialog.find.setText("lesson ")
        dialog.replace.setText("Class ")
        assert dialog.summary.text() == "5 names change."
        return QDialog.Accepted

    monkeypatch.setattr(library_controller.RenameDialog, "exec", answer)
    lv.open({("tag", "LessonBlues")})
    o.table.selectAll()
    w._rename()
    names = sorted(i.name for i in w.library.items if "LessonBlues" in i.tags)
    assert names == [f"Class Blues {n}" for n in range(1, 6)]
    assert w.recording_banner.label.text() == "5 sounds renamed."
    assert len(o.selected_items()) == 5


def test_the_trash_names_the_pieces_and_undo_brings_the_sounds_back(full, monkeypatch, tmp_path):
    w, _ = full
    lv, o = w.library_view, w.library_view.overlay
    from ampbench.store import add_imported_pieces
    add_imported_pieces(w.recorder.store, made_up.pieces(w.library.items))
    trash_folder = tmp_path / "trash"
    trash_folder.mkdir()

    def to_trash(path):
        target = trash_folder / path.name
        path.rename(target)
        return target

    w.library._trash = to_trash
    asked = []
    monkeypatch.setattr(QMessageBox, "question", lambda _w, _t, text, *a, **k: asked.append(text) or QMessageBox.Yes)
    lv.open({("tag", "SlowRiver")})
    o.table.selectAll()
    count = len(o.selected_items())
    w._trash()
    assert asked and asked[0].startswith(f"Move {count} sounds to the Trash?") and "Slow River · Intro" in asked[0]
    assert not any("SlowRiver" in i.tags for i in w.library.items)
    assert w.recording_banner.label.text() == f"{count} sounds are in the Trash." and w.recording_banner.action.isVisibleTo(w)
    w.recording_banner._run_undo()
    assert sum("SlowRiver" in i.tags for i in w.library.items) == count


def test_the_library_speaks_german(full):
    w, _ = full
    from ampbench import i18n
    i18n.set_language(i18n.GERMAN)
    o = w.library_view.overlay
    o.refresh(rebuild_filters=True)
    assert o.count_label.text() == "96 SOUNDS"
    assert o.status_label.text().startswith("52 zum Anhören")
    assert q.scope_title(q.CLOSE) == "Ähnliche Sounds"


def test_no_two_actions_share_a_key(window):
    w, _ = window
    keys = {}
    for menu in w.menuBar().actions():
        for action in menu.menu().actions():
            for sequence in action.shortcuts():
                text = sequence.toString()
                assert text not in keys, f"{text}: {keys.get(text)} and {action.text()}"
                keys[text] = action.text()
    assert {"Ctrl+L", "Ctrl+K", "Ctrl+G", "Ctrl+Shift+F", "Ctrl+Return"} <= set(keys)


def test_the_library_answers_real_keys(full):
    w, _ = full
    lv, o = w.library_view, w.library_view.overlay
    w.activateWindow()
    QTest.keyClick(w, Qt.Key_L, Qt.ControlModifier)
    assert lv.is_open and o.search.hasFocus()
    QTest.keyClicks(o.search, "slow river")
    QTest.keyClick(o.search, Qt.Key_Down)
    QTest.keyClick(o.table, Qt.Key_Down)
    chosen = o.selected_items()[0].name
    QTest.keyClick(o.table, Qt.Key_Return)
    wait_for(lambda: w.link.core.tried_preset is not None and w.link.core.tried_preset.name == chosen)
    QTest.keyClick(o.table, Qt.Key_Return, Qt.ControlModifier)
    assert not lv.is_open and w.editor.current.name == chosen
    QTest.keyClick(w, Qt.Key_L, Qt.ControlModifier)
    assert lv.is_open
    QTest.keyClick(o.table, Qt.Key_Escape)
    assert not lv.is_open
