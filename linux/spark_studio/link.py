"""The Bluetooth LE connection to the amp. A port of SparkLink.swift, without any UI toolkit.

``LinkCore`` runs inside an asyncio loop and talks to a ``Transport`` (BlueZ through bleak, or a simulated amp for
tests and ``--demo``). It only looks for devices that offer the Spark control service, so no other Bluetooth device
nearby is ever used. Requests run one at a time, the way the amp wants them.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Callable

from . import editor, protocol
from .protocol import Message, Parser, Place, Preset

GAP = 0.15  # the amp sometimes ignores a request that follows the previous answer right away
SILENCE = 3.0  # waiting ends when the amp stays silent this long; a preset takes seconds, but data keeps coming


class LinkError(Exception):
    pass


class NotConnected(LinkError):
    def __str__(self):
        return "Der Verstärker ist nicht verbunden."


class NoAnswer(LinkError):
    def __str__(self):
        return "Der Verstärker hat nicht geantwortet."


class Unreadable(LinkError):
    def __init__(self, detail: str):
        super().__init__(f"Der Verstärker hat ein Preset geschickt, das nicht lesbar ist ({detail}).")


class VerifyFailed(LinkError):
    def __init__(self, name: str):
        super().__init__(f"Beim Zurücklesen enthielt der Platz nicht „{name}“. Die Sicherung liegt in der Bibliothek.")


class BluetoothUnavailable(LinkError):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason  # "off" or "unsupported"


@dataclass
class Transfer:
    kind: str  # sending, reading, switching
    done: int = 0
    total: int | None = None

    @property
    def fraction(self) -> float | None:
        return None if self.total is None else min(self.done, self.total) / max(self.total, 1)


class Transport:
    """What the link needs from Bluetooth."""

    async def connect(self, on_found: Callable[[str | None], None], on_notify: Callable[[bytes], None],
                      on_disconnect: Callable[[], None]) -> None:
        raise NotImplementedError

    async def write(self, blocks: list[bytes]) -> None:
        raise NotImplementedError

    async def disconnect(self) -> None:
        raise NotImplementedError


class BleakTransport(Transport):
    def __init__(self):
        self._client = None
        self._write_response = True
        self._chunk = 20

    async def connect(self, on_found, on_notify, on_disconnect):
        from bleak import BleakClient, BleakScanner
        from bleak.exc import BleakError

        def matches(device, advertisement):
            return protocol.SERVICE_UUID in [u.lower() for u in advertisement.service_uuids]

        try:
            device = await BleakScanner.find_device_by_filter(matches, timeout=20)
        except BleakError as error:
            text = str(error).lower()
            if "not powered" in text or "no bluetooth adapters" in text or "powered off" in text:
                raise BluetoothUnavailable("off") from error
            raise LinkError(str(error)) from error
        if device is None:
            raise LinkError("Kein Spark-Verstärker gefunden.")
        on_found((device.name or "").replace(" BLE", "") or None)
        client = BleakClient(device, disconnected_callback=lambda _: on_disconnect())
        await client.connect()
        characteristic = client.services.get_characteristic(protocol.WRITE_UUID)
        if characteristic is None or client.services.get_characteristic(protocol.NOTIFY_UUID) is None:
            await client.disconnect()
            raise LinkError("Das Gerät bietet den Spark-Dienst nicht an.")
        self._write_response = "write" in characteristic.properties
        try:
            self._chunk = max(int(client.mtu_size) - 3, 20)
        except Exception:
            self._chunk = 20
        await client.start_notify(protocol.NOTIFY_UUID, lambda _, data: on_notify(bytes(data)))
        self._client = client

    async def write(self, blocks):
        client = self._client
        if client is None or not client.is_connected:
            raise NotConnected()
        # A write longer than one Bluetooth packet is refused, so every block goes on its own.
        for block in blocks:
            for start in range(0, len(block), self._chunk):
                await client.write_gatt_char(protocol.WRITE_UUID, block[start:start + self._chunk],
                                             response=self._write_response)

    async def disconnect(self):
        client, self._client = self._client, None
        if client is not None:
            try:
                await client.disconnect()
            except Exception:
                pass


class LinkCore:
    """State and requests of the link. Every public ``async`` method must run in the link's loop."""

    def __init__(self, transport_factory: Callable[[], Transport], emit: Callable[..., None] = lambda *a: None,
                 gap: float = GAP, silence: float = SILENCE):
        self._factory = transport_factory
        self._emit = emit
        self.gap, self.silence = gap, silence
        self.status = "off"
        self.device_name: str | None = None
        self.firmware: str | None = None
        self.active_slot: int | None = None
        self.trying_out: str | None = None
        self.is_editing_live = False
        self.activity: str | None = None
        self.transfer: Transfer | None = None
        self.slots: list[Preset | None] = [None] * 4
        self.wanted = False
        self.trace: Callable[[str], None] | None = None
        self._transport: Transport | None = None
        self._parser = Parser()
        self._sequence = 0
        self._waiting: tuple[int, set[int], asyncio.Future] | None = None
        self._last_activity = 0.0
        self._lock: asyncio.Lock | None = None
        self._run_task: asyncio.Task | None = None
        self._lost_event: asyncio.Event | None = None
        self._recent_models: list[float] = []

    # MARK: State

    def _set(self, name: str, value) -> None:
        setattr(self, name, value)
        self._emit(name, value)

    def _set_status(self, status: str) -> None:
        self._set("status", status)

    # MARK: Connection

    def start(self) -> None:
        self.wanted = True
        if self._run_task is None or self._run_task.done():
            self._lock = asyncio.Lock()
            self._run_task = asyncio.ensure_future(self._run())

    async def stop(self) -> None:
        """Ends the connection, so the Spark app on the phone can take the amp."""
        self.wanted = False
        task, self._run_task = self._run_task, None
        if task is not None:
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        self._fail_waiting(NotConnected())
        transport, self._transport = self._transport, None
        if transport is not None:
            await transport.disconnect()
        self._reset_connection_state()
        self._set_status("off")

    def _reset_connection_state(self) -> None:
        self._parser = Parser()
        self._set("active_slot", None)
        self._set("trying_out", None)
        self._set("is_editing_live", False)  # the amp ends the temporary preset when the connection ends
        self._set("activity", None)
        self._set("transfer", None)

    async def _run(self) -> None:
        while self.wanted:
            self._set_status("searching")
            self._lost_event = asyncio.Event()
            transport = self._factory()
            try:
                await transport.connect(self._found, self._received, self._lost_event.set)
            except BluetoothUnavailable as error:
                self._set_status("unsupported" if error.reason == "unsupported" else "bluetooth_off")
                await asyncio.sleep(3)
                continue
            except asyncio.CancelledError:
                await transport.disconnect()
                raise
            except Exception as error:  # not found, refused, adapter busy
                if self.trace:
                    self.trace(f"Verbindung fehlgeschlagen: {error}")
                await transport.disconnect()
                await asyncio.sleep(2)
                continue
            self._transport = transport
            self._set_status("connected")
            asyncio.ensure_future(self._after_connect())
            try:
                await self._lost_event.wait()
            except asyncio.CancelledError:
                await transport.disconnect()
                raise
            self._lost()

    def _found(self, name: str | None) -> None:
        self._set("device_name", name)
        self._set_status("connecting")

    async def _after_connect(self) -> None:
        await self.load_all()
        self._emit("connected")

    def _lost(self) -> None:
        self._fail_waiting(NotConnected())
        self._transport = None
        self._reset_connection_state()
        self._set_status("searching" if self.wanted else "off")

    # MARK: Requests

    async def _once(self, build: Callable[[int], list[bytes]], sub: int, commands: set[int]) -> Message:
        await asyncio.sleep(self.gap)
        if self.status != "connected" or self._transport is None:
            raise NotConnected()
        self._sequence = (self._sequence + 1) & 0x7F
        blocks = build(self._sequence)
        self._trace_out(blocks)
        future: asyncio.Future = asyncio.get_running_loop().create_future()
        self._waiting = (sub, commands, future)
        self._last_activity = asyncio.get_running_loop().time()
        await self._transport.write(blocks)
        try:
            while True:
                remaining = self._last_activity + self.silence - asyncio.get_running_loop().time()
                if remaining <= 0:
                    raise NoAnswer()
                try:
                    return await asyncio.wait_for(asyncio.shield(future), remaining)
                except asyncio.TimeoutError:
                    continue
        finally:
            if self._waiting and self._waiting[2] is future:
                self._waiting = None

    async def _request(self, build, answer: int, command: int = protocol.CMD_RESPONSE) -> Message:
        """Sends a message and waits for the answer, asking a second time when none comes."""
        async with self._lock:
            try:
                return await self._once(build, answer, {command})
            except NoAnswer:
                return await self._once(build, answer, {command})

    async def _confirmed(self, build, answer: int) -> bool:
        """Sends a change the amp confirms with ``04 <sub>`` or at times with an echo ``03 <sub>``. It is not sent a
        second time, because a change that already happened gets no answer at all."""
        async with self._lock:
            try:
                message = await self._once(build, answer, {protocol.CMD_ACK, protocol.CMD_RESPONSE})
            except NoAnswer:
                return False
            if message.command != protocol.CMD_ACK:
                self._emit("strain")
            return True

    async def _send_only(self, build, gap: float) -> None:
        async with self._lock:
            if self.status != "connected" or self._transport is None:
                raise NotConnected()
            self._sequence = (self._sequence + 1) & 0x7F
            blocks = build(self._sequence)
            self._trace_out(blocks)
            await self._transport.write(blocks)
            await asyncio.sleep(gap)

    def _fail_waiting(self, error: Exception) -> None:
        waiting, self._waiting = self._waiting, None
        if waiting and not waiting[2].done():
            waiting[2].set_exception(error)

    def _trace_out(self, blocks: list[bytes]) -> None:
        if not self.trace or not blocks:
            return
        start = blocks[0].find(0xF0)
        text = f"{blocks[0][start + 4]:02X} {blocks[0][start + 5]:02X}" if start >= 0 else "?"
        self.trace("→ " + text + (f" ({len(blocks)} chunks)" if len(blocks) > 1 else ""))

    # MARK: Incoming

    def _received(self, data: bytes) -> None:
        self._last_activity = _now()
        messages = self._parser.feed(data)
        if self.transfer and self.transfer.kind == "reading" and self._parser.chunk_progress:
            self.transfer.done, self.transfer.total = self._parser.chunk_progress
            self._emit("transfer", self.transfer)
        for message in messages:
            if self.trace and message.sub != protocol.SUB_TUNER_PITCH:
                event = protocol.parse_event(message)
                self.trace(f"← {message.command:02X} {message.sub:02X}" + (f" {event.kind}" if event else ""))
            if message.command == 0x05 and message.sub == protocol.SUB_PRESET and self.transfer \
                    and self.transfer.kind == "sending":
                self.transfer.done += 1
                self._emit("transfer", self.transfer)
            waiting = self._waiting
            if waiting and waiting[0] == message.sub and message.command in waiting[1]:
                self._waiting = None
                if not waiting[2].done():
                    waiting[2].set_result(message)
                continue
            event = protocol.parse_event(message)
            if event is None:
                continue
            if event.kind == "preset_selected" and event.slot < 4:  # the amp's own preset button
                self._set("active_slot", event.slot)
                self._set("trying_out", None)
                self._set("is_editing_live", False)
                self._emit("amp_selected", event.slot)
            else:
                self._emit("amp_event", event)

    # MARK: Actions

    class _Tracked:
        def __init__(self, core: "LinkCore", transfer: Transfer):
            self.core, self.transfer = core, transfer

        async def __aenter__(self):
            self.core._set("transfer", self.transfer)

        async def __aexit__(self, *exc):
            if self.core.transfer is self.transfer:
                self.core._set("transfer", None)

    def _tracked(self, transfer: Transfer):
        return LinkCore._Tracked(self, transfer)

    async def read_preset(self, place: Place) -> Preset:
        slot = place.slot if place.kind == "slot" else None
        async with self._tracked(Transfer("reading")):
            message = await self._request(lambda s: protocol.get_preset(slot, s), protocol.SUB_PRESET)
        try:
            return Preset.from_payload(message.payload)
        except protocol.DecodeError as error:
            raise Unreadable(str(error)) from error

    async def _switch_to(self, slot: int) -> None:
        async with self._tracked(Transfer("switching")):
            await self._request(lambda s: protocol.change_hardware_preset(slot, s), protocol.SUB_HARDWARE_PRESET,
                                protocol.CMD_ACK)

    async def _send(self, preset: Preset, place: Place) -> None:
        total = len(protocol.send_preset(preset, place, 0))
        async with self._tracked(Transfer("sending", total=total)):
            await self._request(lambda s: protocol.send_preset(preset, place, s), protocol.SUB_PRESET, protocol.CMD_ACK)

    async def load_all(self) -> None:
        """Reads everything the window shows: firmware, the preset playing and the four slots."""
        self._set("activity", "Lese den Verstärker …")
        try:
            try:
                message = await self._request(lambda s: protocol.get_firmware(s), protocol.SUB_FIRMWARE)
                self._set("firmware", protocol.firmware_version(message.payload))
            except (NoAnswer, NotConnected):
                pass
            try:
                message = await self._request(lambda s: protocol.get_preset_number(s), protocol.SUB_PRESET_NUMBER)
                slot = protocol.slot_of(message.payload)
                if slot is not None and slot < 4:
                    self._set("active_slot", slot)
            except (NoAnswer, NotConnected):
                pass
            for slot in range(4):
                self._set("activity", f"Lese Platz {slot + 1} …")
                await self.refresh(slot)
        finally:
            self._set("activity", None)

    async def refresh(self, slot: int) -> None:
        try:
            preset = await self.read_preset(Place.of_slot(slot))
        except LinkError:
            return
        self.slots[slot] = preset
        self._emit("slots", self.slots)

    async def select(self, slot: int) -> None:
        self._set("activity", f"Schalte auf Platz {slot + 1} …")
        try:
            await self._switch_to(slot)
        finally:
            self._set("activity", None)
        self._set("active_slot", slot)
        self._set("trying_out", None)
        self._set("is_editing_live", False)

    async def try_out(self, preset: Preset) -> None:
        """Plays a preset without storing it. Switching to any slot ends it."""
        self._set("activity", f"Sende „{preset.name}“ …")
        try:
            await self._send(preset, protocol.TEMPORARY)
            await self._switch_to(0x7F)
        finally:
            self._set("activity", None)
        self._set("trying_out", preset.name)
        self._set("is_editing_live", False)
        self._set("active_slot", None)

    async def play_for_editing(self, preset: Preset) -> None:
        """Plays the editor's preset on the temporary place. Changes after it are heard at once."""
        self._set("activity", f"Sende „{preset.name}“ zum Bearbeiten …")
        try:
            await self._send(preset, protocol.TEMPORARY)
            await self._switch_to(0x7F)
        finally:
            self._set("activity", None)
        self._set("trying_out", None)
        self._set("is_editing_live", True)
        self._set("active_slot", None)

    async def apply(self, change: editor.Change) -> bool:
        """Sends one live change. Returns False when a change that the amp confirms got no answer."""
        if change.kind == "parameter":
            await self._send_only(lambda s: protocol.set_parameter(change.effect, change.index, change.value, s),
                                  editor.PARAMETER_GAP)
            return True
        if change.kind == "toggle":
            return await self._confirmed(lambda s: protocol.set_effect(change.effect, change.is_on, s),
                                         protocol.SUB_EFFECT_ON_OFF)
        if change.kind == "model":
            return await self._confirmed(lambda s: protocol.change_model(change.old, change.new, s),
                                         protocol.SUB_CHANGE_EFFECT)
        if change.kind == "whole":
            await self.play_for_editing(change.preset)
            return True
        return True

    def end_editing(self) -> None:
        self._set("is_editing_live", False)

    async def store(self, preset: Preset, slot: int) -> None:
        """Stores a preset in a slot, switches to it and reads it back to make sure it arrived unchanged."""
        self._set("activity", f"Speichere „{preset.name}“ auf Platz {slot + 1} …")
        try:
            await self._send(preset, Place.of_slot(slot))
            await self._switch_to(slot)
            self._set("active_slot", slot)
            self._set("trying_out", None)
            self._set("is_editing_live", False)
            self._set("activity", f"Prüfe Platz {slot + 1} …")
            stored = await self.read_preset(Place.of_slot(slot))
        finally:
            self._set("activity", None)
        self.slots[slot] = stored
        self._emit("slots", self.slots)
        if not stored.same_content(preset):
            raise VerifyFailed(preset.name)

    async def current_preset(self, slot: int) -> Preset:
        """Reads a slot fresh from the amp, for a backup that must match what is really stored."""
        preset = await self.read_preset(Place.of_slot(slot))
        self.slots[slot] = preset
        self._emit("slots", self.slots)
        return preset


def _now() -> float:
    return asyncio.get_running_loop().time()
