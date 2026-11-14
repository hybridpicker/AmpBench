"""The sound store in the window, headless: its model, the row in the sidebar, the dialog and the menu. Every test
has a store profile in its temporary folder; the real store and the keyring are never touched."""
import os
import time

import pytest

pytest.importorskip("PySide6")
pytest.importorskip("cryptography")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QApplication, QFileDialog, QLineEdit  # noqa: E402

from ampbench import i18n, store_profile  # noqa: E402
from ampbench.fake_amp import FakeAmp  # noqa: E402
from ampbench.library import PresetLibrary  # noqa: E402
from ampbench.qtlink import QtLink  # noqa: E402
from ampbench.store_profile import FOLDER, HTTP, SSH, StoreProfile, StoreSettings  # noqa: E402
from ampbench.ui import store_view, theme  # noqa: E402
from ampbench.ui.store_view import FAILED, IDLE, NOT_SET_UP, SYNCING, StoreDialog, StoreModel, StoreStatusRow  # noqa: E402


@pytest.fixture(scope="module")
def app():
    app = QApplication.instance() or QApplication([])
    app.setStyle("Fusion")
    app.setStyleSheet(theme.stylesheet())
    return app


@pytest.fixture(autouse=True)
def nothing_real(monkeypatch, tmp_path):
    def refuse(*arguments, **_):
        raise AssertionError(f"a test started a program: {arguments}")
    monkeypatch.setattr(store_profile.subprocess, "run", refuse)
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    yield
    i18n.set_language(i18n.ENGLISH)


@pytest.fixture
def open_dialog(app):
    """Makes a dialog and takes it away again after the test, as closing its window does in the app."""
    made = []

    def make(model):
        made.append(StoreDialog(model))
        return made[-1]
    yield make
    for dialog in made:
        dialog.close()
        dialog.deleteLater()
    app.sendPostedEvents(None, store_view.QEvent.DeferredDelete)


def wait_for(condition, timeout=4000):
    waited = 0
    while not condition() and waited < timeout:
        QTest.qWait(20)
        waited += 20
    assert condition(), "timed out"


class Device:
    """One device: a folder of sounds, a profile and the model the window uses."""

    def __init__(self, root, place, key: str | None = None):
        self.sounds = root / "Presets"
        self.sounds.mkdir(parents=True)
        self.trashed: list = []
        self.profile = StoreProfile.testing(root / "profile")
        self.profile.save(StoreSettings(FOLDER, folder_path=str(place)))
        if key:
            self.profile.use_key(key)
        else:
            self.profile.create_key()
        self.model = StoreModel(self.sounds, self.profile, self._trash)
        self.reports: list[tuple[bool, str]] = []
        self.reloads = 0
        self.model.report.connect(lambda is_error, text: self.reports.append((is_error, text)))
        self.model.files_changed.connect(self._reloaded)

    def _trash(self, path) -> None:
        self.trashed.append(path.name)
        path.unlink()

    def _reloaded(self) -> None:
        self.reloads += 1

    def sync(self, quiet: bool = False) -> None:
        self.model.sync(quiet=quiet)
        wait_for(lambda: self.model.state != SYNCING)


@pytest.fixture
def two(app, tmp_path):
    first = Device(tmp_path / "first", tmp_path / "place")
    second = Device(tmp_path / "second", tmp_path / "place", key=first.profile.identity.text)
    return first, second


# MARK: The model

def test_a_model_without_a_store_is_not_set_up_and_does_nothing(app, tmp_path):
    model = StoreModel(tmp_path / "Presets", StoreProfile.testing(tmp_path / "profile"), lambda path: None)
    assert model.state == NOT_SET_UP and not model.is_ready
    model.sync()
    model.sync_if_due()
    model.library_changed()
    assert model.state == NOT_SET_UP and not (tmp_path / "profile").exists()


def test_syncing_runs_off_the_ui_thread_and_reports(two):
    first, second = two
    (first.sounds / "Lead.json").write_text("first")
    assert first.model.state == IDLE and first.model.last_sync is None
    first.model.sync()
    assert first.model.state == SYNCING, "the window goes on while the store is busy"
    wait_for(lambda: first.model.state == IDLE)
    assert first.reports == [(False, "Store: 1 stored.")] and first.model.last_summary == "Store: 1 stored."
    assert first.model.last_sync is not None and first.reloads == 0

    second.sync()
    assert second.reports == [(False, "Store: 1 fetched.")] and second.reloads == 1
    assert (second.sounds / "Lead.json").read_text() == "first"

    # Automatic syncs speak up only when something changed.
    second.sync(quiet=True)
    assert len(second.reports) == 1
    second.sync()
    assert second.reports[-1] == (False, "The store is up to date: 1 sounds.")

    # What a sync removes here goes through the library's trash.
    (first.sounds / "Lead.json").unlink()
    first.sync(quiet=True)
    assert first.reports[-1] == (False, "Store: 1 removed in the store.")
    second.sync(quiet=True)
    assert second.trashed == ["Lead.json"] and second.reloads == 2
    assert second.reports[-1] == (False, "Store: 1 removed here.")


def test_a_failed_sync_shows_and_a_quiet_one_does_not_repeat_itself(two, tmp_path):
    first, second = two
    first.sync()
    other = StoreProfile.testing(tmp_path / "stranger")
    second.profile.use_key(other.create_key().text)
    second.sync(quiet=True)
    assert second.model.state == FAILED
    text = "The sound store could not be synced: This key does not open the store. Enter the key the store was set up with."
    assert second.model.failure == text and second.reports == [(True, text)]
    second.sync(quiet=True)
    assert len(second.reports) == 1, "the lamp shows it; the same message again would only nag"
    second.sync()
    assert len(second.reports) == 2
    second.model.use_key(first.profile.identity.text)
    assert second.model.state == FAILED, "until a sync went through"
    second.sync(quiet=True)
    assert second.model.state == IDLE and second.model.failure == ""


def test_automatic_syncs_wait_five_minutes_and_follow_changes_in_the_folder(two, monkeypatch):
    first, _ = two
    first.model.sync_if_due()
    wait_for(lambda: first.model.state == IDLE and first.model.last_sync is not None)
    stamp = first.profile.settings_file.stat().st_mtime_ns
    first.model.sync_if_due()
    assert first.model.state == IDLE, "not again within five minutes"
    monkeypatch.setattr(store_view.time, "monotonic", lambda: time.time() + 10_000)
    first.model.sync_if_due()
    assert first.model.state == SYNCING
    wait_for(lambda: first.model.state == IDLE)
    assert first.profile.settings_file.stat().st_mtime_ns != stamp

    # A change in the folder: one sync a little later, however many files changed.
    first.model.CHANGE_DELAY = 60
    first.model.library_changed()
    assert not first.model._scheduled.isActive(), "nothing changed, nothing to do"
    (first.sounds / "Lead.json").write_text("first")
    first.model.library_changed()
    (first.sounds / "Jazz.json").write_text("second")
    first.model.library_changed()
    assert first.model._scheduled.isActive() and first.model.state == IDLE
    wait_for(lambda: first.model.last_summary == "Store: 2 stored.")
    assert first.reports[-1] == (False, "Store: 2 stored.")
    first.model.library_changed()
    assert not first.model._scheduled.isActive()


def test_a_second_request_while_syncing_runs_once_more_afterwards(two):
    first, _ = two
    (first.sounds / "Lead.json").write_text("first")
    first.model.sync()
    first.model.sync()
    (first.sounds / "Jazz.json").write_text("second")
    wait_for(lambda: first.model.state == IDLE and not first.model._wants_another and first.model.last_summary is not None
             and len(first.profile.verify(first.sounds).not_stored) == 0)
    assert first.profile.verify(first.sounds).is_in_step


def test_disconnecting_stops_syncing_and_keeps_the_key(two):
    first, _ = two
    first.sync()
    first.model.sync()
    first.model.disconnect_device()
    assert first.model.state == NOT_SET_UP and first.model.settings is None and first.model.has_key
    QTest.qWait(200)
    assert first.model.state == NOT_SET_UP, "a sync that was on its way changes nothing any more"
    assert not first.profile.state_file.exists() and first.profile.identity is not None


def test_the_signature_sees_names_sizes_and_dates(tmp_path):
    (tmp_path / "Kemper").mkdir()
    (tmp_path / "Kemper" / "Jazz.json").write_text("a")
    (tmp_path / ".hidden.json").write_text("a")
    before = StoreModel.signature(tmp_path)
    assert "Jazz.json" in before and ".hidden" not in before
    (tmp_path / ".other.tmp").write_text("b")
    assert StoreModel.signature(tmp_path) == before
    (tmp_path / "Kemper" / "Jazz.json").write_text("ab")
    assert StoreModel.signature(tmp_path) != before
    assert StoreModel.signature(tmp_path / "missing") == ""


# MARK: The row

def test_the_row_says_the_state_in_words(two, monkeypatch):
    first, _ = two
    row = StoreStatusRow(first.model)
    assert row.detail.text() == "not synced yet" and row.key.text() == "Sync" and not row.lamp.lit
    first.model.sync()
    assert row.detail.text() == "syncing …" and not row.key.isEnabled() and row.lamp.lit
    wait_for(lambda: first.model.state == IDLE)
    assert row.detail.text().startswith("in step · ") and row.key.isEnabled() and row.lamp.lit and row.lamp.tone == "on"
    assert row.toolTip() == "Folder “place”" and row.accessibleName().startswith("Sound store, in step")
    row.key.click()
    assert first.model.state == SYNCING
    wait_for(lambda: first.model.state == IDLE)

    opened = []
    row.opened.connect(lambda: opened.append(True))
    QTest.mouseClick(row, store_view.Qt.LeftButton)
    assert opened == [True]

    first.profile.use_key(StoreProfile.testing(first.sounds.parent / "stranger").create_key().text)
    first.sync(quiet=True)
    assert row.detail.text() == "last sync failed" and row.lamp.lit and row.lamp.tone == "hot"
    assert row.toolTip().startswith("The sound store could not be synced")

    first.model.disconnect_device()
    assert row.detail.text() == "not set up" and row.key.text() == "Set up" and not row.lamp.lit
    row.key.click()
    assert opened == [True, True], "without a store the key opens the dialog"

    i18n.set_language(i18n.GERMAN)
    row.refresh()
    assert row.detail.text() == "nicht eingerichtet" and row.key.text() == "Einrichten"


# MARK: The dialog

def test_the_dialog_sets_a_store_up_from_nothing(open_dialog, tmp_path, monkeypatch):
    sounds = tmp_path / "Presets"
    sounds.mkdir()
    (sounds / "Lead.json").write_text("first")
    profile = StoreProfile.testing(tmp_path / "profile")
    model = StoreModel(sounds, profile, lambda path: path.unlink())
    dialog = open_dialog(model)
    assert dialog.kind() == FOLDER and dialog.folder_label.text() == "No folder chosen"
    assert dialog.keys.currentIndex() == 0 and not dialog.save_button.isEnabled()
    assert not dialog.disconnect_button.isVisibleTo(dialog) and not dialog.use_button.isEnabled()

    dialog.create_button.click()
    identity = profile.identity
    assert identity is not None and dialog.keys.currentIndex() == 1 and dialog.save_button.isEnabled()
    assert dialog.key_place_label.text() == "This device has its key, in a file only you can read."
    assert identity.text not in visible_text(dialog), "the key shows only when asked for"

    dialog.save_button.click()
    assert dialog.message.text() == "The store's settings are incomplete." and profile.settings is None

    monkeypatch.setattr(QFileDialog, "getExistingDirectory", lambda *a, **k: str(tmp_path / "place"))
    dialog._choose_folder()
    assert dialog.folder_label.text() == str(tmp_path / "place")
    dialog.save_button.click()
    assert profile.settings == StoreSettings(FOLDER, folder_path=str(tmp_path / "place"))
    assert model.state == SYNCING and not dialog.save_button.isEnabled() and dialog.busy.text() == "syncing …"
    wait_for(lambda: model.state == IDLE)
    assert dialog.message.text() == "Store: 1 stored." and dialog.disconnect_button.isVisibleTo(dialog)
    assert (tmp_path / "place" / "manifest.age").exists()

    # Show, copy, hide.
    dialog._show_key()
    assert dialog.keys.currentIndex() == 2 and dialog.key_text.text() == identity.text
    dialog._copy_key()
    assert QApplication.clipboard().text() == identity.text
    QApplication.clipboard().clear()
    dialog._hide_key()
    assert dialog.keys.currentIndex() == 1 and identity.text not in visible_text(dialog)
    dialog._show_key()
    dialog.reject()
    assert dialog.key_text.text() == "" and dialog.shown_key is None, "a closed dialog holds no key"

    dialog.disconnect_now()
    assert profile.settings is None and model.state == NOT_SET_UP and profile.identity == identity
    assert dialog.folder_label.text() == "No folder chosen" and not dialog.disconnect_button.isVisibleTo(dialog)


def visible_text(dialog) -> str:
    from PySide6.QtWidgets import QLabel
    return "\n".join(label.text() for label in dialog.findChildren(QLabel)) + "\n".join(
        field.text() for field in dialog.findChildren(QLineEdit))


def test_the_dialog_takes_a_key_and_a_server(two, open_dialog, tmp_path):
    first, _ = two
    profile = StoreProfile.testing(tmp_path / "third")
    model = StoreModel(tmp_path / "third-sounds", profile, lambda path: path.unlink())
    dialog = open_dialog(model)
    dialog.key_field.setText("not a key")
    assert dialog.use_button.isEnabled()
    dialog.use_button.click()
    assert dialog.message.text() == "This is not a valid key. A key starts with AGE-SECRET-KEY-1."
    dialog.key_field.setText(f" {first.profile.identity.text} ")
    assert dialog.key_field.echoMode() == QLineEdit.Password
    dialog.use_button.click()
    assert profile.identity == first.profile.identity and dialog.key_field.text() == "" and not dialog.message.text()

    # SSH: the fields are checked before anything is kept.
    dialog.kinds.set_index(1)
    dialog._kind_changed(1)
    assert dialog.kind() == SSH and dialog.path_field.text() == "ampbench-store"
    dialog.host_field.setText("made up host")
    dialog.save_button.click()
    assert dialog.message.text().startswith("The server name may only hold") and profile.settings is None
    assert dialog.settings() == StoreSettings(SSH, host="made up host", path="ampbench-store")

    # HTTPS: only with TLS, and the password goes to the secrets, not the settings.
    dialog.kinds.set_index(2)
    dialog._kind_changed(2)
    dialog.url_field.setText(" http://store.example/dav ")
    dialog.user_field.setText("player")
    dialog.password_field.setText("made-up word")
    assert dialog.password_field.echoMode() == QLineEdit.Password
    dialog.save_button.click()
    assert dialog.message.text() == "The address must start with https://." and profile.settings is None
    model.sync = lambda quiet=False: None  # the made-up server is not asked
    dialog.url_field.setText("https://store.example/dav")
    dialog.save_button.click()
    assert profile.settings == StoreSettings(HTTP, url="https://store.example/dav", user="player")
    assert profile.password == "made-up word" and "made-up word" not in profile.settings_file.read_text()

    again = open_dialog(model)
    assert again.kind() == HTTP and again.url_field.text() == "https://store.example/dav"
    assert again.user_field.text() == "player" and again.password_field.text() == "made-up word"


def test_the_dialog_is_german_too(two, open_dialog):
    first, _ = two
    i18n.set_language(i18n.GERMAN)
    dialog = open_dialog(first.model)
    assert dialog.windowTitle() == "Sound-Store" and dialog.save_button.text() == "Sichern und abgleichen"
    assert dialog.kinds.names == ["Ordner", "Server (SSH)", "Server (HTTPS)"]
    assert dialog.key_place_label.text() == "Dieses Gerät hat seinen Schlüssel, in einer Datei, die nur du lesen kannst."


# MARK: In the window

@pytest.fixture
def window(app, tmp_path):
    from ampbench.demo_input import demo_devices, demo_engine
    from ampbench.recorder import RecorderModel
    from ampbench.store import LibraryStore
    from ampbench.ui.main_window import MainWindow
    trashed = []
    library = PresetLibrary(tmp_path / "Presets", trash=lambda path: (trashed.append(path.name), path.unlink()))
    recorder = RecorderModel(LibraryStore(tmp_path / "Recordings"), demo_engine(), demo_devices)
    w = MainWindow(QtLink(lambda: FakeAmp()), library, auto_connect=False, recorder=recorder)
    w.show()
    w._area(1)
    yield w, trashed
    w.editor = None  # nothing to ask on close
    w.close()


def menu_actions(w) -> dict:
    return {action.text(): action for menu in w.menuBar().actions() for action in menu.menu().actions()}


def test_the_window_shows_the_store_and_starts_apart_from_the_real_one(window, tmp_path):
    w, _ = window
    assert w.store.model.profile.settings_file == tmp_path / "Presets" / ".store-settings.json"
    row = w.store.row
    assert row.isVisibleTo(w) and row.parent() is w.sidebar
    assert row.title.text() == "Sound store" and row.detail.text() == "not set up" and row.key.text() == "Set up"
    assert w.sidebar.search.geometry().top() >= row.geometry().bottom(), "at the foot, above the search"
    actions = menu_actions(w)
    assert not actions["Sync the sound store now"].isEnabled() and actions["Sound store …"].isEnabled()
    presets = next(menu.menu() for menu in w.menuBar().actions() if menu.text() == "Presets")
    assert [a.text() for a in presets.actions()][-4:-2] == ["Sync the sound store now", "Sound store …"]
    QTest.qWait(50)
    assert not list((tmp_path / "Presets").glob(".store-*")), "a store that is not set up writes nothing"


def test_the_window_syncs_reloads_the_library_and_reports(window, tmp_path, monkeypatch):
    w, trashed = window
    from ampbench import factory
    saved = w.library.save(factory.make(factory.templates()[0], "Made-up Lead"), "Test")
    w._refresh_library()

    # Another device with the same key, which has one more sound.
    other = Device(tmp_path / "other", tmp_path / "place")
    (other.sounds / "From elsewhere.json").write_bytes(saved.path.read_bytes().replace(b"Made-up Lead", b"From elsewhere"))
    other.sync()

    profile = StoreProfile.testing(tmp_path / "profile")
    profile.save(StoreSettings(FOLDER, folder_path=str(tmp_path / "place")))
    profile.use_key(other.profile.identity.text)
    w.store.model.DUE_AFTER = 0
    w.store.use_profile(profile)
    assert w.store.row.detail.text() == "not synced yet" and menu_actions(w)["Sync the sound store now"].isEnabled()
    menu_actions(w)["Sync the sound store now"].trigger()
    assert not menu_actions(w)["Sync the sound store now"].isEnabled()
    wait_for(lambda: w.store.model.state == IDLE)
    assert w.banner.isVisibleTo(w) and w.banner.label.text() == "Store: 1 stored, 1 fetched."
    assert sorted(item.name for item in w.library.items) == ["From elsewhere", "Made-up Lead"]
    assert "From elsewhere" in [row.title for row in w.sidebar.rows], "the sidebar shows what arrived"
    assert w.store.row.detail.text().startswith("in step · ")

    # A sound removed elsewhere goes to this window's trash at the next automatic sync, when the window comes up.
    other.sync()
    (other.sounds / "Made-up Lead.json").unlink()
    other.sync()
    w.banner.hide()
    QApplication.sendEvent(w, store_view.QEvent(store_view.QEvent.WindowActivate))
    wait_for(lambda: trashed == ["Made-up Lead.json"] and w.store.model.state == IDLE)
    assert [item.name for item in w.library.items] == ["From elsewhere"]
    assert w.banner.label.text() == "Store: 1 removed here."

    # A sound saved in the window is stored a little later, by itself.
    w.banner.hide()
    w.store.model.CHANGE_DELAY = 50
    w.library.save(factory.make(factory.templates()[1], "Made-up Jazz"), "Test")
    wait_for(lambda: w.store.model.last_summary == "Store: 1 stored.", timeout=8000)
    other.sync()
    assert (other.sounds / "Made-up Jazz.json").exists()


def test_the_row_and_the_menu_open_the_dialog(window, monkeypatch):
    w, _ = window
    opened = []
    monkeypatch.setattr(StoreDialog, "exec", lambda self: opened.append(self.windowTitle()))
    w.store.row.key.click()
    menu_actions(w)["Sound store …"].trigger()
    assert opened == ["Sound store", "Sound store"]
