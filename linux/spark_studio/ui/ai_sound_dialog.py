"""KI-Sound: describe a sound in your own words, get three different suggestions, hear them on the amp, adjust them,
keep only what you like. A port of Sources/SparkPresetsUI/App/AISoundSheet.swift and the KI-Sound part of
PresetsModel.swift. Network only when the user asks: a request, or the list of models."""
from __future__ import annotations

import threading

from PySide6.QtCore import QObject, QSettings, Qt, Signal
from PySide6.QtWidgets import (QDialog, QFrame, QGridLayout, QHBoxLayout, QLabel, QLineEdit, QPlainTextEdit,
                               QPushButton, QScrollArea, QStackedWidget, QVBoxLayout, QWidget)

from .. import ai_key, recipe as recipemod, sound_ai
from . import theme

HISTORY_KEY = "AI Sound History"
MODEL_KEY = "AI Sound Model"
IDEAS = ["Blues-Crunch für meine Telecaster", "Metallica – Enter Sandman", "Cleaner Funk mit Biss",
         "Pink Floyd – Comfortably Numb, Solo", "Warmer Jazz-Sound"]


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
        self.setWindowTitle("KI-Sound")
        self.resize(760, 640)
        self._play, self._keep = play, keep
        self._settings = settings or QSettings("local.sparkstudio", "Spark Studio")
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
        column.addWidget(_title("Mit Ollama Cloud verbinden"))
        column.addWidget(_muted("Für KI-Sound braucht Spark Studio einen Ollama-API-Schlüssel. Du bekommst ihn "
                                "kostenlos mit einem Ollama-Konto unter ollama.com/settings/keys."))
        self.key_field = QLineEdit()
        self.key_field.setEchoMode(QLineEdit.Password)
        self.key_field.setPlaceholderText("API-Schlüssel einfügen")
        column.addWidget(self.key_field)
        column.addWidget(_muted("Der Schlüssel liegt im Schlüsselbund deines Desktops (sonst in einer Datei, die nur "
                                "du lesen kannst) und wird nur an Ollama (ollama.com) gesendet, wenn du einen Sound "
                                "erzeugen lässt."))
        column.addStretch(1)
        row = QHBoxLayout()
        row.addStretch(1)
        cancel = QPushButton("Abbrechen")
        cancel.clicked.connect(self.reject)
        connect = QPushButton("Verbinden")
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
        column.addWidget(_title("KI-Sound"))
        column.addWidget(_muted("Beschreibe den Sound mit eigenen Worten – ein Song, eine Band, eine Stimmung. Du "
                                "bekommst drei verschiedene Vorschläge, hörst sie am Verstärker an, besserst nach und "
                                "behältst nur, was dir gefällt."))
        self.request_field = QPlainTextEdit()
        self.request_field.setPlaceholderText("z. B. „U2 – Where the streets have no name“")
        self.request_field.setFixedHeight(70)
        self.request_field.setStyleSheet(f"QPlainTextEdit {{ background: {theme.FIELD}; color: {theme.FIELD_TEXT}; "
                                         f"border: 1px solid {theme.FIELD_EDGE}; border-radius: 6px; padding: 4px; }}")
        self.request_field.textChanged.connect(self._request_changed)
        column.addWidget(self.request_field)
        self.counter = _muted("")
        column.addWidget(self.counter)
        self.history_box = QWidget()
        column.addWidget(self.history_box)
        column.addWidget(_muted("Ideen zum Anklicken"))
        ideas = QHBoxLayout()
        for idea in IDEAS:
            button = QPushButton(idea)
            button.clicked.connect(lambda _=False, text=idea: self.request_field.setPlainText(text))
            ideas.addWidget(button)
        ideas.addStretch(1)
        column.addLayout(ideas)
        advanced = QFrame()
        grid = QGridLayout(advanced)
        grid.addWidget(_muted("Modell"), 0, 0)
        self.model_field = QLineEdit(self.model_name)
        self.model_field.setPlaceholderText(sound_ai.DEFAULT_MODEL)
        self.model_field.editingFinished.connect(self._model_changed)
        grid.addWidget(self.model_field, 0, 1)
        load = QPushButton("Modelle laden")
        load.setToolTip("Fragt ollama.com nach den Modellen, die es gerade gibt (ohne Schlüssel).")
        load.clicked.connect(self._load_models)
        grid.addWidget(load, 0, 2)
        self.models_label = _muted("")
        grid.addWidget(self.models_label, 1, 0, 1, 3)
        remove = QPushButton("Schlüssel entfernen")
        remove.clicked.connect(self._remove_key)
        grid.addWidget(remove, 2, 0)
        column.addWidget(_muted("Erweitert"))
        column.addWidget(advanced)
        self.wish_error = QLabel("")
        self.wish_error.setWordWrap(True)
        self.wish_error.setStyleSheet(f"color: {theme.DANGER_TEXT};")
        column.addWidget(self.wish_error)
        column.addStretch(1)
        row = QHBoxLayout()
        row.addWidget(_muted("Nur dein Text geht an Ollama (ollama.com) – keine Presets, Namen oder Gerätedaten."), 1)
        cancel = QPushButton("Abbrechen")
        cancel.clicked.connect(self.reject)
        self.create = QPushButton("Vorschläge erstellen")
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
        self.counter.setText(f"{length} von {sound_ai.REQUEST_LIMIT} Zeichen")
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
        old.addWidget(_muted("Zuletzt gewünscht"))
        for wish in self.history[:4]:
            button = QPushButton(wish if len(wish) < 34 else wish[:32] + "…")
            button.setToolTip(wish)
            button.clicked.connect(lambda _=False, text=wish: self.request_field.setPlainText(text))
            old.addWidget(button)
        clear = QPushButton("Verlauf löschen")
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
        self.models_label.setText("Lade die Modelle von ollama.com …")

        def run():
            try:
                self._bridge.models.emit(sound_ai.available_models())
            except Exception as error:  # noqa: BLE001
                self._bridge.models.emit(str(error))

        threading.Thread(target=run, daemon=True).start()

    def _models_loaded(self, result) -> None:
        if isinstance(result, str):
            self.models_label.setText(f"Die Liste ließ sich nicht laden: {result}")
        else:
            self.models_label.setText("Verfügbar: " + ", ".join(result[:30]))

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
                offer.error = offer.error or "Abgebrochen."

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
        column.addWidget(_title("Hör dir die Vorschläge an"))
        self.results_intro = _muted("")
        column.addWidget(self.results_intro)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        self.cards = QWidget()
        self.cards_layout = QVBoxLayout(self.cards)
        scroll.setWidget(self.cards)
        column.addWidget(scroll, 1)
        row = QHBoxLayout()
        other = QPushButton("Andere Beschreibung")
        other.clicked.connect(lambda: (self.cancel_requests(), self.stack.setCurrentIndex(1)))
        self.again = QPushButton("Neue Vorschläge")
        self.again.clicked.connect(self.generate)
        self.stop = QPushButton("Anfrage abbrechen")
        self.stop.clicked.connect(lambda: (self.cancel_requests(), self._show_offers()))
        close = QPushButton("Schließen")
        close.clicked.connect(self.reject)
        for button in (other, self.again, self.stop):
            row.addWidget(button)
        row.addStretch(1)
        row.addWidget(close)
        column.addLayout(row)
        return page

    def _show_offers(self) -> None:
        self.results_intro.setText(f"„{self.asked}“ – jeder Vorschlag erscheint, sobald er fertig ist. „Anhören“ spielt "
                                   "ihn am Verstärker, gespeichert wird nichts. Die Knöpfe darunter bessern nur diesen "
                                   "Vorschlag nach. Erst „Behalten“ legt ihn in deine Bibliothek.")
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
        title = sound_ai.VARIANT_TITLES[offer.index] if offer.index < len(sound_ai.VARIANT_TITLES) else ""
        if offer.recipe is None:
            if offer.busy:
                column.addWidget(_muted(f"{title}: wird geschrieben …"))
            else:
                column.addWidget(_muted(f"{title}: {offer.error or 'kein Vorschlag'}"))
                again = QPushButton("Nochmal")
                again.clicked.connect(lambda _=False, i=offer.index: self.retry(i))
                column.addWidget(again, 0, Qt.AlignLeft)
            return card
        data = offer.recipe
        head = QHBoxLayout()
        name = QLabel(f"{title} · {data.get('name', '')}")
        name.setFont(theme.sans(13, bold=True))
        head.addWidget(name, 1)
        if self.listening == offer.index:
            head.addWidget(QLabel("spielt"))
        listen = QPushButton("Anhören")
        listen.clicked.connect(lambda _=False, i=offer.index: self.listen(i))
        keep = QPushButton("Behalten")
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
            column.addWidget(_muted(f"Tipp: {data['notes']}"))
        quick = QHBoxLayout()
        for key, info in sound_ai.ADJUSTMENTS.items():
            button = QPushButton(info["label"])
            button.setEnabled(not offer.busy)
            button.clicked.connect(lambda _=False, i=offer.index, k=key: self.adjust(i, k))
            quick.addWidget(button)
        quick.addStretch(1)
        if offer.busy:
            quick.addWidget(_muted("wird angepasst …"))
        column.addLayout(quick)
        if offer.adjustments:
            column.addWidget(_muted("angepasst: " + ", ".join(sound_ai.ADJUSTMENTS[a]["label"]
                                                               for a in offer.adjustments)))
        if offer.note:
            column.addWidget(_muted(offer.note))
        return card
