"""Runs the link's asyncio loop in a thread and shows its state to Qt through signals."""
from __future__ import annotations

import asyncio
import threading
import time
from typing import Callable

from PySide6.QtCore import QObject, Signal

from . import editor
from .link import BleakTransport, LinkCore, LinkError, Transport
from .protocol import Preset


class QtLink(QObject):
    # State, mirrored from LinkCore
    status = Signal(str)
    device_name = Signal(object)
    firmware = Signal(object)
    active_slot = Signal(object)
    trying_out = Signal(object)
    is_editing_live = Signal(bool)
    activity = Signal(object)
    transfer = Signal(object)
    slots = Signal(object)
    connected = Signal()
    amp_selected = Signal(int)
    amp_event = Signal(object)
    strain = Signal()
    trace = Signal(str)
    live_failed = Signal(str)

    def __init__(self, transport_factory: Callable[[], Transport] = BleakTransport, parent=None):
        super().__init__(parent)
        self._loop = asyncio.new_event_loop()
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._run_loop, name="spark-link", daemon=True)
        self.core: LinkCore | None = None
        self._factory = transport_factory
        self._queue = editor.LiveQueue()
        self._wakeup: asyncio.Event | None = None
        self._pump_task = None
        self._recent_models: list[float] = []
        self._closed = False
        self._thread.start()
        self._ready.wait()

    # The loop thread

    def _run_loop(self) -> None:
        asyncio.set_event_loop(self._loop)
        self.core = LinkCore(self._factory, self._emit_from_core)
        self.core.trace = self.trace.emit
        self._wakeup = asyncio.Event()
        self._loop.call_soon(self._ready.set)
        self._loop.run_forever()

    def _emit_from_core(self, name: str, *values) -> None:
        signal = getattr(self, name, None)
        if signal is not None:
            signal.emit(*values) if values else signal.emit()
        if name == "is_editing_live" and not values[0]:
            self._queue.clear()

    def call(self, coroutine, done: Callable[[object, Exception | None], None] | None = None):
        """Runs a coroutine in the link's loop. ``done(result, error)`` is called in the loop thread, so connect it
        to a signal or use ``QtLink.then`` to get it back into the UI thread."""
        future = asyncio.run_coroutine_threadsafe(coroutine, self._loop)
        if done:
            def finished(f):
                try:
                    done(f.result(), None)
                except Exception as error:  # noqa: BLE001 - reported to the UI
                    done(None, error)
            future.add_done_callback(finished)
        return future

    # Public API (called from the UI thread)

    def start(self) -> None:
        self._loop.call_soon_threadsafe(self.core.start)

    def stop(self) -> None:
        self.call(self.core.stop())

    def shutdown(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._loop.call_soon_threadsafe(lambda: self._pump_task and self._pump_task.cancel())
        try:
            self.call(self.core.stop()).result(timeout=3)
        except Exception:  # noqa: BLE001
            pass
        self._loop.call_soon_threadsafe(self._loop.stop)

    @property
    def is_connected(self) -> bool:
        return self.core.status == "connected"

    # Live changes: a queue that keeps only the newest value of a knob, drained at the amp's pace.

    def push_live(self, changes: list[editor.Change]) -> None:
        if not changes:
            return
        self._loop.call_soon_threadsafe(self._enqueue, changes)

    def _enqueue(self, changes) -> None:
        if not self.core.is_editing_live:
            return
        self._queue.push(changes)
        if self._pump_task is None or self._pump_task.done():
            self._pump_task = asyncio.ensure_future(self._pump())

    async def _pump(self) -> None:
        while self._queue:
            change = self._queue.next()
            if change is None or not self.core.is_editing_live:
                self._queue.clear()
                return
            wait = editor.wait_before(change, time.monotonic(), self._recent_models)
            if wait > 0:
                await asyncio.sleep(wait)
            try:
                ok = await self.core.apply(change)
            except LinkError as error:
                self._queue.clear()
                self.live_failed.emit(str(error))
                return
            if change.kind == "model":
                self._recent_models = [t for t in self._recent_models if time.monotonic() - t < editor.MODEL_WINDOW]
                self._recent_models.append(time.monotonic())
            if not ok:
                self.live_failed.emit("Der Verstärker hat die Änderung nicht bestätigt.")
