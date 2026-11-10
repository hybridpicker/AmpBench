"""AI Sound: describe a sound in your own words, get three different suggestions, hear them on the amp, adjust them,
keep only what you like. A port of Sources/SparkPresetsUI/App/AISoundSheet.swift and the AI Sound part of
PresetsModel.swift (the same texts). Network only when the user asks: a request, or the list of models."""
from __future__ import annotations

import threading

from PySide6.QtCore import QObject, QSettings, Qt, Signal
from PySide6.QtWidgets import (QDialog, QFrame, QGridLayout, QHBoxLayout, QLabel, QLineEdit, QPlainTextEdit,
                               QPushButton, QScrollArea, QStackedWidget, QVBoxLayout, QWidget)

from .. import ai_key, recipe as recipemod, sound_ai
from ..i18n import tr
from . import theme

HISTORY_KEY = "AI Sound History"
MODEL_KEY = "AI Sound Model"


def _ideas() -> list[str]:
    """The example wishes, as on the Mac."""
    return [tr("Blues crunch for my Telecaster"), "Metallica – Enter Sandman", tr("Clean funk with bite"),
            "Pink Floyd – Comfortably Numb, Solo", tr("Warm jazz sound")]


class _Bridge(QObject):
    """Carries results from the request threads into the UI thread."""
    ready = Signal(int, object)
    failed = Signal(int, str)
    refined = Signal(int, object, object)
    refine_failed = Signal(int, str)
    models = Signal(object)


def _muted(text: str) -> QLabel:
    label = QLabel(text)
    label.setWordWrap(True)
    label.setStyleSheet(f"color: {theme.DESK_MUTED};")
    return label


def _title(text: str) -> QLabel:
    label = QLabel(text)
    label.setFont(theme.sans(17, bold=True))
    return label


class Offer:
    def __init__(self, index: int):
        self.index = index
        self.recipe: dict | None = None
        self.error: str | None = None
        self.adjustments: list[str] = []
        self.busy = True
        self.note: str | None = None


class AISoundDialog(QDialog):
    """`play(preset)` plays a sound on the amp's temporary place and returns a problem or None; `keep(data)` writes
    the kept recipe into the library."""

    def __init__(self, play, keep, parent=None, settings: QSettings | None = None, chat_factory=None):
        super().__init__(parent)
        self.setWindowTitle(tr("AI Sound"))
        self.resize(760, 640)
        self._play, self._keep = play, keep
        self._settings = settings or QSettings("local.ampbench", "AmpBench")
        self._chat_factory = chat_factory or (lambda model, key, cancelled: sound_ai.ollama(model, key,
                                                                                         cancelled=cancelled))
        self._bridge = _Bridge()
        self._bridge.ready.connect(self._ready)
        self._bridge.failed.connect(self._failed)
        self._bridge.refined.connect(self._refined)
        self._bridge.refine_failed.connect(self._refine_failed)
        self._bridge.models.connect(self._models_loaded)
        self._cancelled = threading.Event()
        self.key = ai_key.load()
        history = self._settings.value(HISTORY_KEY) or []
        self.history: list[str] = [history] if isinstance(history, str) else list(history)
        self.model_name = str(self._settings.value(MODEL_KEY) or sound_ai.DEFAULT_MODEL)
        self.asked = ""
        self.offers: list[Offer] = []
        self.listening: int | None = None

        self.stack = QStackedWidget()
        layout = QVBoxLayout(self)
        layout.addWidget(self.stack)
        self.stack.addWidget(self._key_page())
        self.stack.addWidget(self._wish_page())
        self.stack.addWidget(self._results_page())
        self.stack.setCurrentIndex(1 if self.key else 0)

    # MARK: The key

    def _key_page(self) -> QWidget:
        page = QWidget()
        column = QVBoxLayout(page)
        column.addWidget(_title(tr("Connect to Ollama Cloud")))
        column.addWidget(_muted(tr("AI Sound needs an Ollama API key. You get one for free with an Ollama account.")))
        link = QLabel(f'<a href="https://ollama.com/settings/keys">{tr("Create a key at ollama.com/settings/keys")}</a>')
        link.setOpenExternalLinks(True)
        column.addWidget(link)
        self.key_field = QLineEdit()
        self.key_field.setEchoMode(QLineEdit.Password)
        self.key_field.setPlaceholderText(tr("Paste the API key"))
        column.addWidget(self.key_field)
        column.addWidget(_muted(tr("The key is kept in your desktop's keyring (otherwise in a file only you can read) "
                                   "and is sent only to Ollama (ollama.com) when you have a sound created.")))
        column.addStretch(1)
        row = QHBoxLayout()
        row.addStretch(1)
        cancel = QPushButton(tr("Cancel"))
        cancel.clicked.connect(self.reject)
        connect = QPushButton(tr("Connect"))
        connect.setDefault(True)
        connect.clicked.connect(self._connect_key)
        row.addWidget(cancel)
        row.addWidget(connect)
        column.addLayout(row)
        return page

    def _connect_key(self) -> None:
        key = self.key_field.text().strip()
        if not key:
            return
        ai_key.save(key)
        self.key = key
        self.key_field.clear()
        self.stack.setCurrentIndex(1)

    # MARK: The wish

    def _wish_page(self) -> QWidget:
        page = QWidget()
        column = QVBoxLayout(page)
        column.addWidget(_title(tr("AI Sound")))
        column.addWidget(_muted(tr("Describe the sound in your own words – a song, a band, a mood. You get three "
                                   "different suggestions, listen to them on the amp, refine them and keep only what "
                                   "you like.")))
        self.request_field = QPlainTextEdit()
        self.request_field.setPlaceholderText(tr("e.g. “U2 – Where the streets have no name”"))
        self.request_field.setFixedHeight(70)
        self.request_field.setStyleSheet(f"QPlainTextEdit {{ background: {theme.FIELD}; color: {theme.FIELD_TEXT}; "
                                         f"border: 1px solid {theme.FIELD_EDGE}; border-radius: 6px; padding: 4px; }}")
        self.request_field.textChanged.connect(self._request_changed)
        column.addWidget(self.request_field)
        self.counter = _muted("")
        column.addWidget(self.counter)
        self.history_box = QWidget()
        column.addWidget(self.history_box)
        column.addWidget(_muted(tr("Ideas to click")))
        ideas = QHBoxLayout()
        for idea in _ideas():
            button = QPushButton(idea)
            button.clicked.connect(lambda _=False, text=idea: self.request_field.setPlainText(text))
            ideas.addWidget(button)
        ideas.addStretch(1)
        column.addLayout(ideas)
        advanced = QFrame()
        grid = QGridLayout(advanced)
        grid.addWidget(_muted(tr("Model")), 0, 0)
        self.model_field = QLineEdit(self.model_name)
        self.model_field.setPlaceholderText(sound_ai.DEFAULT_MODEL)
        self.model_field.editingFinished.connect(self._model_changed)
        grid.addWidget(self.model_field, 0, 1)
        load = QPushButton(tr("Load models"))
        load.setToolTip(tr("Asks ollama.com for the models it offers right now (without the key)."))
        load.clicked.connect(self._load_models)
        grid.addWidget(load, 0, 2)
        self.models_label = _muted("")
        grid.addWidget(self.models_label, 1, 0, 1, 3)
        remove = QPushButton(tr("Remove key"))
        remove.clicked.connect(self._remove_key)
        grid.addWidget(remove, 2, 0)
        column.addWidget(_muted(tr("Advanced")))
        column.addWidget(advanced)
        self.wish_error = QLabel("")
        self.wish_error.setWordWrap(True)
        self.wish_error.setStyleSheet(f"color: {theme.DANGER_TEXT};")
        column.addWidget(self.wish_error)
        column.addStretch(1)
        row = QHBoxLayout()
        row.addWidget(_muted(tr("Only your text goes to Ollama (ollama.com) – no presets, names or device data.")), 1)
        cancel = QPushButton(tr("Cancel"))
        cancel.clicked.connect(self.reject)
        self.create = QPushButton(tr("Create suggestions"))
        self.create.setDefault(True)
        self.create.clicked.connect(self.generate)
        row.addWidget(cancel)
        row.addWidget(self.create)
        column.addLayout(row)
        self._show_history()
        self._request_changed()
        return page

    def _request_changed(self) -> None:
        length = len(self.request_field.toPlainText().strip())
        self.counter.setText(tr("{} of {} characters", length, sound_ai.REQUEST_LIMIT))
        self.create.setEnabled(0 < length <= sound_ai.REQUEST_LIMIT)

    def _show_history(self) -> None:
        old = self.history_box.layout()
        if old is not None:
            while old.count():
                item = old.takeAt(0)
                if item.widget():
                    item.widget().deleteLater()
        else:
            old = QHBoxLayout(self.history_box)
        if not self.history:
            self.history_box.hide()
            return
        self.history_box.show()
        old.addWidget(_muted(tr("Asked for recently")))
        for wish in self.history[:4]:
            button = QPushButton(wish if len(wish) < 34 else wish[:32] + "…")
            button.setToolTip(wish)
            button.clicked.connect(lambda _=False, text=wish: self.request_field.setPlainText(text))
            old.addWidget(button)
        clear = QPushButton(tr("Clear history"))
        clear.clicked.connect(self._clear_history)
        old.addWidget(clear)
        old.addStretch(1)

    def _clear_history(self) -> None:
        self.history = []
        self._settings.remove(HISTORY_KEY)
        self._show_history()

    def _model_changed(self) -> None:
        self.model_name = self.model_field.text().strip() or sound_ai.DEFAULT_MODEL
        self._settings.setValue(MODEL_KEY, self.model_name)

    def _remove_key(self) -> None:
        ai_key.save("")
        self.key = ""
        self.stack.setCurrentIndex(0)

    def _load_models(self) -> None:
        self.models_label.setText(tr("Loading the models from ollama.com …"))

        def run():
            try:
                self._bridge.models.emit(sound_ai.available_models())
            except Exception as error:  # noqa: BLE001
                self._bridge.models.emit(str(error))

        threading.Thread(target=run, daemon=True).start()

    def _models_loaded(self, result) -> None:
        if isinstance(result, str):
            self.models_label.setText(tr("The list could not be loaded: {}", result))
        else:
            self.models_label.setText(tr("Available: {}", ", ".join(result[:30])))

    # MARK: Requests

    def generate(self) -> None:
        request = self.request_field.toPlainText()
        try:
            wish = sound_ai.checked_request(request)
        except sound_ai.AIError as error:
            self.wish_error.setText(str(error))
            return
        if not self.key:
            self.stack.setCurrentIndex(0)
            return
        self.wish_error.setText("")
        self.cancel_requests()
        self._cancelled = threading.Event()
        self.asked = wish
        self.history = sound_ai.remember(wish, self.history)
        self._settings.setValue(HISTORY_KEY, self.history)
        self._show_history()
        self.offers = [Offer(i) for i in range(len(sound_ai.VARIANT_HINTS))]
        self.listening = None
        chat = self._chat_factory(self.model_name, self.key, self._cancelled)
        sound_ai.variants(wish, chat, lambda i, d: self._bridge.ready.emit(i, d),
                          lambda i, e: self._bridge.failed.emit(i, str(e)), cancelled=self._cancelled)
        self.stack.setCurrentIndex(2)
        self._show_offers()

    def cancel_requests(self) -> None:
        self._cancelled.set()
        for offer in self.offers:
            if offer.busy:
                offer.busy = False
                offer.error = offer.error or tr("Cancelled.")

    def _ready(self, index: int, data) -> None:
        if index < len(self.offers):
            offer = self.offers[index]
            offer.recipe, offer.busy, offer.error = data, False, None
            self._show_offers()

    def _failed(self, index: int, message: str) -> None:
        if index < len(self.offers):
            offer = self.offers[index]
            offer.busy, offer.error = False, message
            self._show_offers()

    def retry(self, index: int) -> None:
        offer = self.offers[index]
        offer.busy, offer.error = True, None
        chat = self._chat_factory(self.model_name, self.key, self._cancelled)
        sound_ai.variants(self.asked, chat, lambda _, d: self._bridge.ready.emit(index, d),
                          lambda _, e: self._bridge.failed.emit(index, str(e)),
                          hints=[sound_ai.VARIANT_HINTS[index]], cancelled=self._cancelled)
        self._show_offers()

    def adjust(self, index: int, adjustment: str) -> None:
        offer = self.offers[index]
        if offer.recipe is None or offer.busy:
            return
        reason = sound_ai.impossibility(adjustment, offer.recipe)
        if reason:
            offer.note = reason
            self._show_offers()
            return
        offer.busy, offer.note = True, None
        chat = self._chat_factory(self.model_name, self.key, self._cancelled)
        current = offer.recipe

        def run():
            try:
                new, note = sound_ai.refine(current, adjustment, self.asked, chat, cancelled=self._cancelled)
                self._bridge.refined.emit(index, (new, adjustment), note)
            except Exception as error:  # noqa: BLE001
                if sound_ai.message_for(error):
                    self._bridge.refine_failed.emit(index, str(error))

        threading.Thread(target=run, daemon=True).start()
        self._show_offers()

    def _refined(self, index: int, result, note) -> None:
        offer = self.offers[index]
        new, adjustment = result
        offer.recipe, offer.busy, offer.note = new, False, note
        offer.adjustments.append(adjustment)
        self._show_offers()
        if self.listening == index:
            self.listen(index)

    def _refine_failed(self, index: int, message: str) -> None:
        offer = self.offers[index]
        offer.busy, offer.note = False, message
        self._show_offers()

    def listen(self, index: int) -> None:
        offer = self.offers[index]
        if offer.recipe is None:
            return
        try:
            preset = recipemod.to_preset(offer.recipe).preset
        except recipemod.RecipeError as error:
            offer.note = "\n".join(error.messages)
            self._show_offers()
            return
        problem = self._play(preset)
        if problem:
            offer.note = problem
        else:
            self.listening = index
        self._show_offers()

    def pick(self, index: int) -> None:
        offer = self.offers[index]
        if offer.recipe is None:
            return
        self._keep(sound_ai.keepsake(offer.recipe, self.asked, offer.adjustments))
        self.cancel_requests()
        self.accept()

    def reject(self) -> None:
        self.cancel_requests()
        super().reject()

    # MARK: The results

    def _results_page(self) -> QWidget:
        page = QWidget()
        column = QVBoxLayout(page)
        column.addWidget(_title(tr("Listen to the suggestions")))
        self.results_intro = _muted("")
        column.addWidget(self.results_intro)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        self.cards = QWidget()
        self.cards_layout = QVBoxLayout(self.cards)
        scroll.setWidget(self.cards)
        column.addWidget(scroll, 1)
        row = QHBoxLayout()
        other = QPushButton(tr("Other description"))
        other.clicked.connect(lambda: (self.cancel_requests(), self.stack.setCurrentIndex(1)))
        self.again = QPushButton(tr("New suggestions"))
        self.again.clicked.connect(self.generate)
        self.stop = QPushButton(tr("Cancel request"))
        self.stop.clicked.connect(lambda: (self.cancel_requests(), self._show_offers()))
        close = QPushButton(tr("Close"))
        close.clicked.connect(self.reject)
        for button in (other, self.again, self.stop):
            row.addWidget(button)
        row.addStretch(1)
        row.addWidget(close)
        column.addLayout(row)
        return page

    def _show_offers(self) -> None:
        self.results_intro.setText(tr("“{}” – every suggestion appears as soon as it is ready. “Listen” plays it on "
                                      "the amp, nothing is stored. The buttons below refine only that suggestion. Only "
                                      "“Keep” puts it into your library.", self.asked))
        while self.cards_layout.count():
            item = self.cards_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        busy = any(o.busy for o in self.offers)
        self.again.setEnabled(not busy)
        self.stop.setVisible(busy)
        for offer in self.offers:
            self.cards_layout.addWidget(self._card(offer))
        self.cards_layout.addStretch(1)

    def _card(self, offer: Offer) -> QWidget:
        card = QFrame()
        card.setObjectName("offer")
        card.setStyleSheet(f"QFrame#offer {{ background: {theme.DESK_ALT}; border: 1px solid {theme.DESK_LINE}; "
                           "border-radius: 10px; }")
        column = QVBoxLayout(card)
        titles = sound_ai.variant_titles()
        title = titles[offer.index] if offer.index < len(titles) else tr("Suggestion {}", offer.index + 1)
        if offer.recipe is None:
            if offer.busy:
                column.addWidget(_muted(tr("{}: being written …", title)))
            else:
                column.addWidget(_muted(f"{title}: {offer.error or tr('No suggestion came back. Try again.')}"))
                again = QPushButton(tr("Again"))
                again.clicked.connect(lambda _=False, i=offer.index: self.retry(i))
                column.addWidget(again, 0, Qt.AlignLeft)
            return card
        data = offer.recipe
        head = QHBoxLayout()
        name = QLabel(f"{title} · {data.get('name', '')}")
        name.setFont(theme.sans(13, bold=True))
        head.addWidget(name, 1)
        if self.listening == offer.index:
            head.addWidget(QLabel(tr("playing")))
        listen = QPushButton(tr("Listen"))
        listen.clicked.connect(lambda _=False, i=offer.index: self.listen(i))
        keep = QPushButton(tr("Keep"))
        keep.clicked.connect(lambda _=False, i=offer.index: self.pick(i))
        head.addWidget(listen)
        head.addWidget(keep)
        column.addLayout(head)
        column.addWidget(_muted(str(data.get("description", ""))))
        try:
            from .sidebar import chain_summary
            column.addWidget(_muted(chain_summary(recipemod.to_preset(data).preset)))
        except recipemod.RecipeError:
            pass
        if data.get("notes"):
            column.addWidget(_muted(tr("Tip: {}", data["notes"])))
        quick = QHBoxLayout()
        for key in sound_ai.ADJUSTMENTS:
            button = QPushButton(sound_ai.label(key))
            reason = sound_ai.impossibility(key, data)
            button.setEnabled(not offer.busy and reason is None)
            button.setToolTip(reason or tr("Make this suggestion {}, the rest stays", sound_ai.label(key)))
            button.clicked.connect(lambda _=False, i=offer.index, k=key: self.adjust(i, k))
            quick.addWidget(button)
        quick.addStretch(1)
        if offer.busy:
            quick.addWidget(_muted(tr("being adjusted …")))
        column.addLayout(quick)
        if offer.adjustments:
            column.addWidget(_muted(tr("adjusted: {}", ", ".join(sound_ai.label(a) for a in offer.adjustments))))
        if offer.note:
            column.addWidget(_muted(offer.note))
        return card
