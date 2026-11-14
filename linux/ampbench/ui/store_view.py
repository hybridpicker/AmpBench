"""The sound store in the window: its row at the foot of the Presets sidebar, its dialog, and when it syncs.

A port of Sources/SparkPresetsUI/Store/StoreModel.swift and StoreViews.swift with the same flows and texts. The
store syncs when the app starts, when its window comes to the front (at most every five minutes), a little after
sounds changed, and on request. The key is only read into the window when the user asks to see it."""
from __future__ import annotations

import threading
import time
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QEvent, QFileSystemWatcher, QMimeData, QObject, Qt, QTimer, Signal
from PySide6.QtWidgets import (QApplication, QDialog, QFileDialog, QFrame, QGridLayout, QHBoxLayout, QLabel, QLineEdit,
                               QMessageBox, QPushButton, QVBoxLayout, QWidget)

from ..i18n import tr
from ..store_profile import FOLDER, HTTP, KINDS, SSH, StoreProfile, StoreSettings
from . import theme
from .formats import date_time
from .widgets import HardwareKey, Lamp, SegmentTabs

NOT_SET_UP, IDLE, SYNCING, FAILED = "not_set_up", "idle", "syncing", "failed"


class StoreModel(QObject):
    """The sound store as the area Presets shows it: whether it is set up, what it did last, and syncing."""
    changed = Signal()
    # A sync changed files here, so the library reads its folder again.
    files_changed = Signal()
    # What a sync did, when it did something or failed: (is an error, text). Automatic syncs that change nothing
    # stay silent.
    report = Signal(bool, str)
    # Carries a sync's result from its thread into the UI thread, like the bridge of the AI Sound window.
    _finished = Signal(int, object, object, bool, str)

    # Seconds between the automatic syncs at start and when the window comes to the front.
    DUE_AFTER = 300
    # Milliseconds from a change in the folder to its sync, so a run of edits becomes one sync.
    CHANGE_DELAY = 15_000

    def __init__(self, folder: Path, profile: StoreProfile, remove, parent=None):
        super().__init__(parent)
        self.folder, self.profile, self._remove = Path(folder), profile, remove
        self.state = NOT_SET_UP
        self.failure = ""
        self.last_sync: datetime | None = None
        self.last_summary: str | None = None
        self.settings: StoreSettings | None = None
        self.has_key = False
        self._running = False
        self._generation = 0
        self._synced_signature: str | None = None
        self._last_attempt = float("-inf")
        self._wants_another = False
        self._scheduled = QTimer(self)
        self._scheduled.setSingleShot(True)
        self._scheduled.timeout.connect(lambda: self.sync(quiet=True))
        self._finished.connect(self._done)
        self.use_profile(profile)

    def use_profile(self, profile: StoreProfile) -> None:
        """Another store profile, before anything synced: the app hands the real one to its window."""
        self._generation += 1
        self._running = False
        self._scheduled.stop()
        self.profile = profile
        self.state, self.failure, self.last_summary, self._synced_signature = NOT_SET_UP, "", None, None
        self.has_key = False
        self._last_attempt = float("-inf")
        # Without a place there is nothing the key is needed for yet, so the keyring is left alone until the
        # dialog opens.
        self.refresh(key=profile.settings is not None)

    @property
    def is_ready(self) -> bool:
        return self.settings is not None and self.has_key

    def refresh(self, key: bool = True) -> None:
        self.settings = self.profile.settings
        if key:
            self.has_key = self.profile.has_key
        self.last_sync = self.profile.last_sync
        if self.state != SYNCING:
            if not self.is_ready:
                self.state = NOT_SET_UP
            elif self.state != FAILED:
                self.state = IDLE
        self.changed.emit()

    # MARK: Setting up

    def create_key(self) -> None:
        self.profile.create_key()
        self.refresh()

    def use_key(self, text: str) -> None:
        self.profile.use_key(text)
        self._synced_signature = None
        self.refresh()

    def reveal_key(self) -> str | None:
        """The key as text, for writing it down or carrying it to another device. Only read when the user asks."""
        identity = self.profile.identity
        return identity.text if identity else None

    def save(self, settings: StoreSettings, password: str | None) -> None:
        if self.profile.settings != settings:
            self._synced_signature = None
        self.profile.save(settings, password)
        self.state = IDLE
        self.refresh()

    def disconnect_device(self) -> None:
        # A sync on its way runs to its end; what it finds is no longer of interest.
        self._generation += 1
        self._running = False
        self._scheduled.stop()
        self.profile.disconnect()
        self._synced_signature = None
        self.last_summary = None
        self.state = NOT_SET_UP
        self.refresh()

    # MARK: Syncing

    def sync(self, quiet: bool = False) -> None:
        """Syncs now. `quiet` is for the automatic syncs: they speak up only when something changed or failed."""
        if not self.is_ready:
            return
        if self._running:
            self._wants_another = True
            return
        self._scheduled.stop()
        before = self.failure if self.state == FAILED else ""
        self.state, self._running = SYNCING, True
        self._last_attempt = time.monotonic()
        self.changed.emit()
        generation, profile, folder, remove = self._generation, self.profile, self.folder, self._remove

        def work() -> None:
            # The network and the files, off the UI thread.
            try:
                result, error = profile.sync(folder, remove), None
            except Exception as failure:  # noqa: BLE001 - whatever went wrong is shown, never raised in a thread
                result, error = None, failure
            try:
                self._finished.emit(generation, result, error, quiet, before)
            except RuntimeError:  # the window is gone
                pass

        threading.Thread(target=work, name="ampbench-store-sync", daemon=True).start()

    def _done(self, generation: int, report, error, quiet: bool, before: str) -> None:
        if generation != self._generation:
            return
        self._running = False
        if error is None:
            self.state, self.failure = IDLE, ""
            self.last_sync = self.profile.last_sync
            self.last_summary = report.summary
            if report.downloaded or report.removed_locally:
                self.files_changed.emit()
            self._synced_signature = self.signature(self.folder)
            if not quiet or not report.is_empty:
                self.report.emit(False, report.summary)
        else:
            text = tr("The sound store could not be synced: {}", str(error) or type(error).__name__)
            # A quiet sync that fails the same way again stays quiet: the lamp shows it.
            repeated = before == text
            self.state, self.failure = FAILED, text
            if not quiet or not repeated:
                self.report.emit(True, text)
        self.changed.emit()
        if self._wants_another:
            self._wants_another = False
            self.sync(quiet=True)

    def sync_if_due(self) -> None:
        """The app started or came to the front: sync, but not more often than every five minutes."""
        if self.is_ready and time.monotonic() - self._last_attempt > self.DUE_AFTER:
            self.sync(quiet=True)

    def library_changed(self) -> None:
        """The folder changed: when its files differ from the last sync, sync a little later."""
        if not self.is_ready or self._running or self._synced_signature is None:
            return
        if self._synced_signature != self.signature(self.folder):
            self._scheduled.start(self.CHANGE_DELAY)

    @staticmethod
    def signature(folder: Path) -> str:
        """Names, sizes and dates of the sound files, enough to see that something changed."""
        lines = []
        pending = [Path(folder)]
        while pending:
            try:
                children = [child for child in pending.pop().iterdir() if not child.name.startswith(".")]
            except OSError:
                continue
            for child in children:
                try:
                    if child.is_symlink():
                        continue
                    if child.is_dir():
                        pending.append(child)
                    elif child.is_file():
                        stat = child.stat()
                        lines.append(f"{child}|{stat.st_size}|{stat.st_mtime_ns}")
                except OSError:
                    continue
        return "\n".join(sorted(lines))


def time_text(date: datetime) -> str:
    """`14:05` today, the date with it before."""
    local = date.astimezone()
    return local.strftime("%H:%M") if local.date() == datetime.now().astimezone().date() else date_time(date)


def _muted(text: str, size: float | None = None) -> QLabel:
    label = QLabel(text)
    label.setWordWrap(True)
    if size:
        label.setFont(theme.sans(size))
    label.setStyleSheet(f"background: transparent; color: {theme.DESK_MUTED};")
    return label


def _heading(text: str) -> QLabel:
    label = QLabel(text)
    label.setFont(theme.sans(14, bold=True))
    return label


class _Pages(QWidget):
    """One of several pages, the others hidden. Unlike a QStackedWidget it is as tall as the page that shows, so a
    note that wraps is never cut off."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._column = QVBoxLayout(self)
        self._column.setContentsMargins(0, 0, 0, 0)
        self._pages: list[QWidget] = []
        self._index = 0

    def addWidget(self, page: QWidget) -> None:
        page.setVisible(not self._pages)
        self._pages.append(page)
        self._column.addWidget(page)

    def currentIndex(self) -> int:
        return self._index

    def setCurrentIndex(self, index: int) -> None:
        self._index = index
        for number, page in enumerate(self._pages):
            page.setVisible(number == index)


class StoreStatusRow(QFrame):
    """The sound store's lamp and state at the foot of the sidebar. A click opens its dialog."""
    opened = Signal()

    def __init__(self, model: StoreModel, parent=None):
        super().__init__(parent)
        self.model = model
        self.setCursor(Qt.PointingHandCursor)
        # The sidebar's own color, which its style sheet also gives the lamp and the texts in this row.
        self.setStyleSheet(f"StoreStatusRow {{ background: #18181B; border-top: 1px solid {theme.DESK_LINE}; }}")
        row = QHBoxLayout(self)
        row.setContentsMargins(14, 8, 10, 6)
        row.setSpacing(8)
        self.lamp = Lamp("", size=8)
        self.lamp.setFixedWidth(14)
        row.addWidget(self.lamp)
        texts = QVBoxLayout()
        texts.setSpacing(0)
        self.title = QLabel(tr("Sound store"))
        self.title.setFont(theme.sans(12, bold=True))
        self.detail = _muted("", 11)
        texts.addWidget(self.title)
        texts.addWidget(self.detail)
        row.addLayout(texts, 1)
        self.key = HardwareKey("")
        self.key.clicked.connect(self._key_pressed)
        row.addWidget(self.key)
        model.changed.connect(self.refresh)
        self.refresh()

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.opened.emit()

    def _key_pressed(self) -> None:
        if self.model.is_ready:
            self.model.sync()
        else:
            self.opened.emit()

    def detail_text(self) -> str:
        model = self.model
        if model.state == NOT_SET_UP:
            return tr("not set up")
        if model.state == SYNCING:
            return tr("syncing …")
        if model.state == FAILED:
            return tr("last sync failed")
        return tr("in step · {}", time_text(model.last_sync)) if model.last_sync else tr("not synced yet")

    def refresh(self) -> None:
        model = self.model
        lit = model.state in (SYNCING, FAILED) or (model.state == IDLE and model.last_sync is not None)
        self.lamp.set_state(lit, tone="hot" if model.state == FAILED else "on")
        detail = self.detail_text()
        self.detail.setText(detail)
        if model.is_ready:
            self.key.setText(tr("Sync"))
            self.key.setToolTip(tr("Stores this device’s sounds encrypted and fetches the sounds of your other "
                                   "devices."))
        else:
            self.key.setText(tr("Set up"))
            self.key.setToolTip(tr("Keeps your sounds encrypted in a place you choose: a folder, your own server or "
                                   "a cloud drive."))
        self.key.setEnabled(model.state != SYNCING)
        self.key.updateGeometry()
        self.setToolTip(model.failure if model.state == FAILED else model.settings.summary if model.settings else "")
        self.setAccessibleName(tr("Sound store") + ", " + detail)
        self.setAccessibleDescription(tr("Opens the sound store’s settings."))


class StoreDialog(QDialog):
    """Sets the sound store up and shows what it does: where the encrypted sounds are kept, and the key that opens
    them."""

    def __init__(self, model: StoreModel, parent=None):
        super().__init__(parent)
        self.model = model
        self.setWindowTitle(tr("Sound store"))
        self.setMinimumWidth(540)
        self.shown_key: str | None = None
        self.problem: str | None = None
        self.folder_path = ""
        column = QVBoxLayout(self)
        column.setSpacing(10)
        title = QLabel(tr("Sound store"))
        title.setFont(theme.sans(17, bold=True))
        column.addWidget(title)
        column.addWidget(_muted(tr("Your sounds are encrypted on this device and kept in a place you choose. Whoever "
                                   "runs that place sees only unreadable files. Other devices with the same key get "
                                   "the same sounds.")))
        column.addWidget(_heading(tr("Place")))
        self.kinds = SegmentTabs([tr("Folder"), tr("Server (SSH)"), tr("Server (HTTPS)")])
        self.kinds.changed.connect(self._kind_changed)
        column.addWidget(self.kinds)
        self.places = _Pages()
        self.places.addWidget(self._folder_page())
        self.places.addWidget(self._ssh_page())
        self.places.addWidget(self._http_page())
        column.addWidget(self.places)
        rule = QFrame()
        rule.setFixedHeight(1)
        rule.setStyleSheet(f"background: {theme.DESK_LINE};")
        column.addWidget(rule)
        column.addWidget(_heading(tr("Store key")))
        self.keys = _Pages()
        self.keys.addWidget(self._no_key_page())
        self.keys.addWidget(self._has_key_page())
        self.keys.addWidget(self._shown_key_page())
        column.addWidget(self.keys)
        self.message = QLabel("")
        self.message.setWordWrap(True)
        column.addWidget(self.message)
        column.addStretch(1)
        row = QHBoxLayout()
        self.disconnect_button = QPushButton(tr("Disconnect this device …"))
        self.disconnect_button.setStyleSheet(f"color: {theme.DANGER_TEXT};")
        self.disconnect_button.clicked.connect(self._disconnect)
        row.addWidget(self.disconnect_button)
        row.addStretch(1)
        self.busy = _muted("")
        row.addWidget(self.busy)
        close = QPushButton(tr("Close"))
        close.clicked.connect(self.reject)
        self.save_button = QPushButton(tr("Save and sync"))
        self.save_button.setDefault(True)
        self.save_button.clicked.connect(self.save_and_sync)
        row.addWidget(close)
        row.addWidget(self.save_button)
        column.addLayout(row)
        model.changed.connect(self.refresh)
        # Only now is the keyring asked, when the user came to see the store.
        model.refresh()
        self.load()

    # MARK: Place

    def _field(self, grid: QGridLayout, line: int, label: str, placeholder: str = "") -> QLineEdit:
        field = QLineEdit()
        field.setPlaceholderText(placeholder)
        field.setAccessibleName(label)
        grid.addWidget(QLabel(label), line, 0)
        grid.addWidget(field, line, 1)
        return field

    def _folder_page(self) -> QWidget:
        page = QWidget()
        column = QVBoxLayout(page)
        column.setContentsMargins(0, 0, 0, 0)
        row = QHBoxLayout()
        self.folder_label = QLabel("")
        self.folder_label.setTextInteractionFlags(Qt.TextSelectableByMouse)
        choose = QPushButton(tr("Choose folder …"))
        choose.clicked.connect(self._choose_folder)
        row.addWidget(self.folder_label, 1)
        row.addWidget(choose)
        column.addLayout(row)
        column.addWidget(_muted(tr("Any folder works, also one that a cloud drive keeps in step: Nextcloud, Google "
                                   "Drive, Dropbox or a network share."), 11))
        return page

    def _ssh_page(self) -> QWidget:
        page = QWidget()
        grid = QGridLayout(page)
        grid.setContentsMargins(0, 0, 0, 0)
        self.host_field = self._field(grid, 0, tr("Server, as ssh knows it"), "myserver")
        self.path_field = self._field(grid, 1, tr("Folder on the server"), "ampbench-store")
        grid.addWidget(_muted(tr("Uses this computer’s ssh with your own keys and ~/.ssh/config. AmpBench stores no "
                                 "login."), 11), 2, 0, 1, 2)
        return page

    def _http_page(self) -> QWidget:
        page = QWidget()
        grid = QGridLayout(page)
        grid.setContentsMargins(0, 0, 0, 0)
        self.url_field = self._field(grid, 0, tr("Address"), "https://example.org/ampbench-store/")
        self.user_field = self._field(grid, 1, tr("User name"))
        self.password_field = self._field(grid, 2, tr("Password"))
        self.password_field.setEchoMode(QLineEdit.Password)
        grid.addWidget(_muted(tr("A WebDAV folder or any HTTPS address that takes GET and PUT, such as Nextcloud or "
                                 "your own server. The password is kept in your desktop's keyring, otherwise in a "
                                 "file only you can read."), 11), 3, 0, 1, 2)
        return page

    def kind(self) -> str:
        return KINDS[self.kinds.index]

    def _kind_changed(self, index: int) -> None:
        self.places.setCurrentIndex(index)
        self._fit()

    def _fit(self) -> None:
        """Grows the window to what the pages that show now need."""
        self.layout().activate()
        needed = self.layout().totalHeightForWidth(self.width())
        if needed > self.height():
            self.resize(self.width(), needed)

    def showEvent(self, event):
        super().showEvent(event)
        self._fit()

    def _choose_folder(self) -> None:
        folder = QFileDialog.getExistingDirectory(self, tr("Choose folder …"), self.folder_path or str(Path.home()))
        if folder:
            self.set_folder(folder)

    def set_folder(self, folder: str) -> None:
        self.folder_path = folder
        self.folder_label.setText(folder or tr("No folder chosen"))
        self.folder_label.setStyleSheet(f"color: {theme.DESK_TEXT if folder else theme.DESK_MUTED};")

    # MARK: Key

    def _no_key_page(self) -> QWidget:
        page = QWidget()
        column = QVBoxLayout(page)
        column.setContentsMargins(0, 0, 0, 0)
        row = QHBoxLayout()
        self.create_button = QPushButton(tr("Create a new key"))
        self.create_button.clicked.connect(lambda: self._run(self.model.create_key))
        row.addWidget(self.create_button)
        row.addWidget(_muted(tr("for a new store")), 1)
        column.addLayout(row)
        row = QHBoxLayout()
        self.key_field = QLineEdit()
        self.key_field.setEchoMode(QLineEdit.Password)
        self.key_field.setPlaceholderText("AGE-SECRET-KEY-1…")
        self.key_field.setAccessibleName(tr("Store key"))
        self.use_button = QPushButton(tr("Use this key"))
        self.use_button.setEnabled(False)
        self.key_field.textChanged.connect(lambda text: self.use_button.setEnabled(bool(text.strip())))
        self.use_button.clicked.connect(self._use_key)
        row.addWidget(self.key_field, 1)
        row.addWidget(self.use_button)
        column.addLayout(row)
        column.addWidget(_muted(tr("Enter the key of a store you already have, as shown on the device that made "
                                   "it."), 11))
        return page

    def _has_key_page(self) -> QWidget:
        page = QWidget()
        column = QVBoxLayout(page)
        column.setContentsMargins(0, 0, 0, 0)
        row = QHBoxLayout()
        self.key_place_label = QLabel("")
        show = QPushButton(tr("Show key …"))
        show.clicked.connect(self._show_key)
        row.addWidget(self.key_place_label, 1)
        row.addWidget(show)
        column.addLayout(row)
        column.addWidget(_muted(tr("Your other devices need the same key. Show it here and enter it there."), 11))
        return page

    def _shown_key_page(self) -> QWidget:
        page = QWidget()
        column = QVBoxLayout(page)
        column.setContentsMargins(0, 0, 0, 0)
        self.key_text = QLabel("")
        self.key_text.setFont(theme.mono(11))
        self.key_text.setWordWrap(True)
        self.key_text.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.key_text.setStyleSheet(f"background: {theme.FIELD}; border: 1px solid {theme.FIELD_EDGE}; "
                                    f"border-radius: 6px; padding: 8px; color: {theme.FIELD_TEXT};")
        column.addWidget(self.key_text)
        row = QHBoxLayout()
        copy = QPushButton(tr("Copy"))
        copy.clicked.connect(self._copy_key)
        hide = QPushButton(tr("Hide"))
        hide.clicked.connect(self._hide_key)
        row.addWidget(copy)
        row.addWidget(hide)
        row.addStretch(1)
        column.addLayout(row)
        column.addWidget(_muted(tr("Whoever has this key can read your sounds, and without it nobody can, not even "
                                   "you. Keep a copy in your password manager, and enter it on your other devices. "
                                   "Never put it into a file that is shared or published."), 11))
        return page

    def _use_key(self) -> None:
        def use() -> None:
            self.model.use_key(self.key_field.text())
            self.key_field.clear()
        self._run(use)

    def _show_key(self) -> None:
        self.shown_key = self.model.reveal_key()
        self.refresh()

    def _hide_key(self) -> None:
        self.shown_key = None
        self.refresh()

    def _copy_key(self) -> None:
        if not self.shown_key:
            return
        data = QMimeData()
        data.setText(self.shown_key)
        # Clipboard managers that know this hint (Klipper, KeePassXC's convention) do not keep the text.
        data.setData("x-kde-passwordManagerHint", b"secret")
        QApplication.clipboard().setMimeData(data)

    # MARK: Actions

    def load(self) -> None:
        """Shows the stored place. Nothing typed is kept."""
        self.problem, self.shown_key = None, None
        settings = self.model.settings
        self.kinds.set_index(KINDS.index(settings.kind) if settings else 0)
        self.places.setCurrentIndex(self.kinds.index)
        self.set_folder((settings.folder_path if settings else None) or "")
        self.host_field.setText((settings.host if settings else None) or "")
        self.path_field.setText((settings.path if settings else None) or "ampbench-store")
        self.url_field.setText((settings.url if settings else None) or "")
        self.user_field.setText((settings.user if settings else None) or "")
        self.password_field.setText((self.model.profile.password or "") if settings and settings.kind == HTTP else "")
        self.refresh()

    def refresh(self) -> None:
        model = self.model
        self.keys.setCurrentIndex(0 if not model.has_key else 2 if self.shown_key else 1)
        self.key_text.setText(self.shown_key or "")
        if model.has_key:
            self.key_place_label.setText(tr("This device has its key, {}.", model.profile.key_place))
        text = self.problem or (model.failure if model.state == FAILED else "")
        if text:
            self.message.setStyleSheet(f"color: {theme.DANGER_TEXT};")
        else:
            text = model.last_summary or ""
            self.message.setStyleSheet(f"color: {theme.DESK_MUTED};")
        self.message.setText(text)
        self.message.setVisible(bool(text))
        self.disconnect_button.setVisible(model.settings is not None)
        self.busy.setText(tr("syncing …") if model.state == SYNCING else "")
        self.save_button.setEnabled(model.has_key and model.state != SYNCING)
        self._fit()

    def _run(self, action) -> None:
        try:
            action()
            self.problem = None
        except Exception as error:  # noqa: BLE001 - shown in the dialog, whatever it is
            self.problem = str(error) or type(error).__name__
        self.refresh()

    def settings(self) -> StoreSettings:
        """The place as the fields say it."""
        kind = self.kind()
        if kind == FOLDER:
            return StoreSettings(FOLDER, folder_path=self.folder_path or None)
        if kind == SSH:
            return StoreSettings(SSH, host=self.host_field.text().strip(), path=self.path_field.text().strip())
        return StoreSettings(HTTP, url=self.url_field.text().strip(), user=self.user_field.text().strip() or None)

    def save_and_sync(self) -> None:
        def save() -> None:
            self.model.save(self.settings(), self.password_field.text() if self.kind() == HTTP else None)
            self.model.sync()
        self._run(save)

    def _disconnect(self) -> None:
        box = QMessageBox(QMessageBox.NoIcon, "AmpBench", tr("Disconnect this device from the sound store?"),
                          parent=self)
        box.setInformativeText(tr("The sounds on this device and in the store stay as they are, and the key stays "
                                  "where it is. This device just no longer syncs."))
        disconnect = box.addButton(tr("Disconnect"), QMessageBox.DestructiveRole)
        box.addButton(tr("Cancel"), QMessageBox.RejectRole)
        box.exec()
        if box.clickedButton() is disconnect:
            self.disconnect_now()

    def disconnect_now(self) -> None:
        self.model.disconnect_device()
        self.load()

    def closeEvent(self, event):
        # The key does not stay on a window that is no longer looked at.
        self.shown_key = None
        self.key_text.setText("")
        super().closeEvent(event)

    def done(self, result):
        self.shown_key = None
        self.key_text.setText("")
        super().done(result)


class StoreController(QObject):
    """Puts the sound store into the main window: the row below the sidebar's list, the dialog, the messages, and
    the moments it syncs by itself. The window only names it and its two menu items.

    Without a profile the store lives in hidden files of the presets folder, apart from the real one, so a window
    built by a test can never reach the user's store. The app hands over the real profile (`use_profile`)."""

    def __init__(self, window, profile: StoreProfile | None = None):
        super().__init__(window)
        self.window = window
        folder = window.library.folder
        # Through the library's own trash, so nothing a sync removes here is deleted for good.
        self.model = StoreModel(folder, profile or StoreProfile.testing(folder),
                                lambda path: window.library._trash(path), self)
        self.row = StoreStatusRow(self.model)
        self.row.opened.connect(self.open_dialog)
        # At the foot of the sidebar, above the search.
        window.sidebar.layout().insertWidget(1, self.row)
        self.sync_action = None
        self.model.changed.connect(self._refresh_action)
        self.model.report.connect(lambda is_error, text: window._say("error" if is_error else "info", text))
        self.model.files_changed.connect(self._reload_library)
        self._watcher = QFileSystemWatcher(self)
        self._watcher.directoryChanged.connect(lambda _: self.model.library_changed())
        try:
            folder.mkdir(parents=True, exist_ok=True)
            self._watcher.addPath(str(folder))
        except OSError:
            pass
        window.installEventFilter(self)
        QTimer.singleShot(0, self.model.sync_if_due)

    def use_profile(self, profile: StoreProfile) -> None:
        self.model.use_profile(profile)

    def add_menu_items(self, menu, action) -> None:
        """"Sync the sound store now" and "Sound store …", as in the Mac's File menu."""
        self.sync_action = action(menu, tr("Sync the sound store now"), lambda: self.model.sync())
        action(menu, tr("Sound store …"), self.open_dialog)
        self._refresh_action()

    def _refresh_action(self) -> None:
        if self.sync_action is not None:
            self.sync_action.setEnabled(self.model.is_ready and self.model.state != SYNCING)

    def open_dialog(self) -> None:
        dialog = StoreDialog(self.model, self.window)
        dialog.exec()
        dialog.deleteLater()

    def _reload_library(self) -> None:
        self.window.library.reload()
        self.window._refresh_library()

    def eventFilter(self, watched, event):
        if watched is self.window and event.type() == QEvent.WindowActivate:
            self.model.sync_if_due()
        return False
