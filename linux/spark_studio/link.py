"""The Bluetooth LE connection to the amp. A port of SparkLink.swift, without any UI toolkit.

``LinkCore`` runs inside an asyncio loop and talks to a ``Transport`` (BlueZ through bleak, or a simulated amp for
tests and ``--demo``). It only looks for devices that offer the Spark control service FFC0 or REACTOR's FFD0, so no
other Bluetooth device nearby is ever used. Requests run one at a time, the way the amp wants them.

What may go to a device is decided by its profile (devices.py). A profile without ``send`` (the REACTOR) gets not a
single byte: the transport keeps nothing to write to, and every write is refused here too.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Callable

from . import devices, editor, protocol
from .devices import DeviceProfile, ReactorState
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


class Refused(LinkError):
    def __init__(self, problems: list[str]):
        super().__init__("Nicht gesendet, damit der Verstärker nichts Unbekanntes spielt: " + " ".join(problems))


class VerifyFailed(LinkError):
    def __init__(self, name: str):
        super().__init__(f"Beim Zurücklesen enthielt der Platz nicht „{name}“. Die Sicherung liegt in der Bibliothek.")


class NotAllowed(LinkError):
    """The device's profile may not get anything, such as a REACTOR."""
    def __init__(self, device: str):
        super().__init__(f"An {device} sendet Spark Studio nichts. Er wird nur mitgelesen.")


class NotSupported(LinkError):
    def __init__(self, device: str):
        super().__init__(f"Das kann Spark Studio mit {device} noch nicht; es ist dort nicht geprüft.")


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
    """What the link needs from Bluetooth. ``connect`` looks for a device with FFC0 or FFD0 (only ``chosen``, an
    address, when given), calls ``on_found(name, service, address)``, which answers with the device's profile, and
    opens the control channel. For a profile that may not send it subscribes to FFC2 and keeps nothing to write to."""

    async def connect(self, on_found: Callable[[str | None, str, str], DeviceProfile],
                      on_notify: Callable[[bytes], None], on_disconnect: Callable[[], None],
                      chosen: str | None = None) -> None:
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
        self._can_write = False
        self._service = devices.SPARK_SERVICE_UUID

    async def connect(self, on_found, on_notify, on_disconnect, chosen=None):
        from bleak import BleakClient, BleakScanner
        from bleak.exc import BleakError

        found_service: dict[str, str] = {}

        def matches(device, advertisement):
            uuids = [u.lower() for u in advertisement.service_uuids]
            service = next((u for u in devices.SEARCHED_SERVICES if u in uuids), None)
            if service is None or (chosen and device.address != chosen):
                return False
            found_service[device.address] = service
            return True

        try:
            device = await BleakScanner.find_device_by_filter(matches, timeout=20)
        except BleakError as error:
            text = str(error).lower()
            if "not powered" in text or "no bluetooth adapters" in text or "powered off" in text:
                raise BluetoothUnavailable("off") from error
            raise LinkError(str(error)) from error
        if device is None:
            raise LinkError("Kein Spark-Gerät gefunden.")
        service = found_service.get(device.address, devices.SPARK_SERVICE_UUID)
        profile = on_found(device.name, service, device.address)
        self._can_write = profile.can_send
        self._service = service
        client = BleakClient(device, disconnected_callback=lambda _: on_disconnect())
        await client.connect()
        control = client.services.get_service(service)
        notify = control.get_characteristic(protocol.NOTIFY_UUID) if control else None
        characteristic = control.get_characteristic(protocol.WRITE_UUID) if control and self._can_write else None
        if notify is None or (self._can_write and characteristic is None):
            await client.disconnect()
            raise LinkError("Das Gerät bietet den Steuerdienst nicht an.")
        self._write_response = characteristic is not None and "write" in characteristic.properties
        try:
            self._chunk = max(int(client.mtu_size) - 3, 20)
        except Exception:
            self._chunk = 20
        await client.start_notify(notify, lambda _, data: on_notify(bytes(data)))
        self._client = client
        self._write_characteristic = characteristic

    async def write(self, blocks):
        client = self._client
        if client is None or not client.is_connected:
            raise NotConnected()
        if not self._can_write or self._write_characteristic is None:
            raise NotAllowed("diesem Gerät")
        # A write longer than one Bluetooth packet is refused, so every block goes on its own.
        for block in blocks:
            for start in range(0, len(block), self._chunk):
                await client.write_gatt_char(self._write_characteristic, block[start:start + self._chunk],
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
        self.profile: DeviceProfile = devices.SPARK_MINI
        self.reactor = ReactorState()
        self.chosen: str | None = None  # the address of the device to connect to, None: the first found
        self.address: str | None = None
        self.found: dict[str, tuple[str | None, DeviceProfile]] = {}
        self.came_back = False  # the last connection returned by itself after it was lost
        self._lost_by_itself = False
        self.active_slot: int | None = None
        self.trying_out: str | None = None
        self.tried_preset: Preset | None = None
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
        # The amp's own tuner: what the tuner area wants, what the amp confirmed, and whether it may still be on
        # (it was on when the connection ended, or switching it off got no answer).
        self.amp_tuner_wanted = False
        self.is_amp_tuner_on = False
        self._amp_tuner_maybe_on = False
        self._tuner_task: asyncio.Task | None = None
        self._last_tuner_reading = 0.0
        self._tuner_off_tries = 0

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
        """Ends the connection, so the Spark app on the phone can take the amp. An amp whose tuner may be on gets
        `tuner off` first, so it is not left silent."""
        if self.status == "connected" and self._transport is not None and self.profile.can_send \
                and (self.is_amp_tuner_on or self._amp_tuner_maybe_on):
            self._sequence = (self._sequence + 1) & 0x7F
            try:
                await self._write(protocol.set_tuner(False, self._sequence))
                await asyncio.sleep(0.3)
            except Exception:
                pass
            self._set("is_amp_tuner_on", False)
            self._amp_tuner_maybe_on = False
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

    @property
    def loggable_name(self) -> str:
        return devices.loggable_name(self.device_name or self.profile.display_name)

    @property
    def shown_name(self) -> str:
        return self.device_name or self.profile.display_name

    def can(self, capability: str) -> bool:
        return self.status == "connected" and self.profile.can(capability)

    def choose(self, address: str) -> None:
        """Connects to another device. The current connection ends first; there is only ever one."""
        self.chosen = address
        if self.wanted and self._lost_event is not None and self._transport is not None:
            self._switching = True
            self._lost_event.set()

    def _set_profile(self, profile: DeviceProfile) -> None:
        self._set("profile", profile)
        if len(self.slots) != profile.slot_count:
            self.slots = [None] * profile.slot_count
            self._emit("slots", self.slots)

    def _reset_connection_state(self) -> None:
        was_temporary = self.trying_out is not None or self.is_editing_live
        if was_temporary and self.profile.loses_temporary_on_disconnect and self.status == "connected":
            # The NEO plays its stored slot again; heard on 2026-11-09.
            self._emit("temporary_lost", self.shown_name)
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
                await transport.connect(self._found, self._received, self._lost_event.set, self.chosen)
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
            if self._transport is transport:
                await transport.disconnect()
            self._lost()

    def _found(self, name: str | None, service: str, address: str) -> DeviceProfile:
        profile = devices.for_advertisement(service, name)
        self.found[address] = (name, profile)
        self.address = address
        if self.chosen is None:
            self.chosen = address
        shown = (name or "").replace(" BLE", "").replace(" Control", "") or None
        self._set_profile(profile)
        self._set("device_name", shown)
        self._set("firmware", None)
        self._set_status("connecting")
        self._emit("devices", self.found)
        return profile

    async def _after_connect(self) -> None:
        self.came_back, self._lost_by_itself = self._lost_by_itself, False
        if not self.profile.can_send:
            self.reactor = ReactorState()  # listen only: nothing is asked, the device reports by itself
            self._emit("reactor", self.reactor)
            self._emit("connected")
            return
        await self._identify()
        await self.load_all()
        self._emit("connected")
        self._reconcile_tuner()

    async def _identify(self) -> None:
        """Asks a Spark for its amp name (``02 11``) and takes the profile it names."""
        try:
            message = await self._request(lambda s: protocol.get_amp_name(s), protocol.SUB_AMP_NAME)
        except (LinkError, NotConnected):
            return
        name = protocol.string_of(message.payload)
        if not name:
            return
        self._set("device_name", name)
        named = devices.for_amp_name(name)
        if named is not None and named.ble_service == self.profile.ble_service:
            self._set_profile(named)
            if self.address:
                self.found[self.address] = (name, named)

    _switching = False

    def _lost(self) -> None:
        # Whether the amp keeps its tuner on without a connection is unknown: it is switched off after reconnecting.
        if self.is_amp_tuner_on:
            self._amp_tuner_maybe_on = True
        self._set("is_amp_tuner_on", False)
        self._tuner_off_tries = 0
        self._lost_by_itself = self.wanted and not self._switching
        self._switching = False
        self._fail_waiting(NotConnected())
        self._transport = None
        self._reset_connection_state()
        self._set_status("searching" if self.wanted else "off")

    # MARK: Requests

    async def _write(self, blocks: list[bytes]) -> None:
        """The one place where bytes go to the device. A profile that may not send gets nothing, whatever asked."""
        if not self.profile.can_send:
            raise NotAllowed(self.profile.display_name)
        self._trace_out(blocks)
        await self._transport.write(blocks)

    def _require(self, capability: str) -> None:
        if self.status != "connected" or self._transport is None:
            raise NotConnected()
        if not self.profile.can(capability):
            raise NotSupported(self.profile.display_name)

    async def _once(self, build: Callable[[int], list[bytes]], sub: int, commands: set[int]) -> Message:
        await asyncio.sleep(self.gap)
        if self.status != "connected" or self._transport is None:
            raise NotConnected()
        if not self.profile.can_send:
            raise NotAllowed(self.profile.display_name)
        self._sequence = (self._sequence + 1) & 0x7F
        blocks = build(self._sequence)
        future: asyncio.Future = asyncio.get_running_loop().create_future()
        self._waiting = (sub, commands, future)
        self._last_activity = asyncio.get_running_loop().time()
        await self._write(blocks)
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
            await self._write(blocks)
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
            if not self.profile.can_send:
                self._listened(message)
                continue
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
            if event.kind == "tuner":
                self._last_tuner_reading = _now()
                self._emit("tuner_reading", (event.index, None if event.value < 0 else
                                             protocol.tuner_cents(event.value)))
                continue
            if event.kind == "preset_selected" and event.slot < self.profile.slot_count:  # preset or NEO middle button
                self._set("active_slot", event.slot)
                self._set("trying_out", None)
                self._set("is_editing_live", False)
                self._emit("amp_selected", event.slot)
            else:
                self._emit("amp_event", event)

    def _listened(self, message: Message) -> None:
        """A device that is only listened to: its messages become its state, nothing is answered."""
        before = self.reactor.slot
        self.reactor.apply(message)
        self._emit("reactor", self.reactor)
        if self.reactor.slot is not None and self.reactor.slot != before:
            self._set("active_slot", self.reactor.slot)
            self._emit("amp_event", protocol.Event("preset_selected", slot=self.reactor.slot))

    # MARK: The amp's own tuner

    @property
    def can_use_amp_tuner(self) -> bool:
        """The connected device can switch its tuner on from here: a MINI or NEO, never one that is only listened to."""
        return self.status == "connected" and self.profile.can(devices.TUNER) and self.profile.can_send

    def want_amp_tuner(self, on: bool) -> None:
        """Asks for the amp's tuner on or off. It is switched when connected and kept so after a reconnect."""
        self.amp_tuner_wanted = on
        if on:
            self._tuner_off_tries = 0
        self._reconcile_tuner()

    def _reconcile_tuner(self) -> None:
        """Switches the amp's tuner until it is as wanted: one message at a time, never two at once."""
        if (self._tuner_task is not None and not self._tuner_task.done()) or not self.can_use_amp_tuner:
            return
        on = self.amp_tuner_wanted
        if (self.is_amp_tuner_on if on else not (self.is_amp_tuner_on or self._amp_tuner_maybe_on)):
            return
        if not on and self._tuner_off_tries >= 3:
            if self.trace:
                self.trace("Das Stimmgerät des Verstärkers ist vielleicht noch an: Ausschalten blieb dreimal ohne Antwort.")
            return

        async def run():
            await self._switch_tuner(on)
            self._tuner_task = None
            if self.status == "connected" and (self.amp_tuner_wanted != on or (not on and self._amp_tuner_maybe_on)):
                self._reconcile_tuner()

        self._tuner_task = asyncio.ensure_future(run())

    async def _switch_tuner(self, on: bool) -> None:
        try:
            answered = await self._confirmed(lambda s: protocol.set_tuner(on, s), protocol.SUB_TUNER)
        except (LinkError, NotConnected):
            answered = False
        if self.status != "connected":
            return
        if on:
            # The amp may be on even without an answer, so it is switched off later in any case.
            self._amp_tuner_maybe_on = True
            self._set("is_amp_tuner_on", answered or _now() - self._last_tuner_reading < 1)
            return
        self._set("is_amp_tuner_on", False)
        if answered:
            self._amp_tuner_maybe_on = False
            self._tuner_off_tries = 0
            return
        # The MINI once switched off without `04 65`. Readings that stop are an answer too.
        self._tuner_off_tries += 1
        await asyncio.sleep(1)
        self._amp_tuner_maybe_on = _now() - self._last_tuner_reading < 0.8

    async def switch_tuner_off_before_quitting(self, seconds: float = 1.5) -> None:
        """Switches the amp's tuner off before the app ends, waiting at most `seconds` for it."""
        self.amp_tuner_wanted = False
        if not self.can_use_amp_tuner or not (self.is_amp_tuner_on or self._amp_tuner_maybe_on):
            return
        self._reconcile_tuner()
        end = _now() + seconds
        while _now() < end and (self.is_amp_tuner_on or self._amp_tuner_maybe_on
                                or (self._tuner_task is not None and not self._tuner_task.done())):
            await asyncio.sleep(0.05)

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
        self._require(devices.READ)
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

    def _fitted(self, preset: Preset) -> Preset:
        """The preset as this device may get it: on the NEO only texts as long as it was heard playing."""
        text = dict(self.profile.checked_text) if self.profile.checked_text else None
        return protocol.for_device(preset, text)

    async def _send(self, preset: Preset, place: Place) -> None:
        problems = protocol.amp_problems(preset)
        if problems:
            raise Refused(problems)
        preset = self._fitted(preset)
        total = len(protocol.send_preset(preset, place, 0))
        async with self._tracked(Transfer("sending", total=total)):
            await self._request(lambda s: protocol.send_preset(preset, place, s), protocol.SUB_PRESET, protocol.CMD_ACK)

    async def load_all(self) -> None:
        """Reads everything the window shows: firmware, the preset playing and the slots."""
        if not self.can(devices.READ):
            return
        self._set("activity", f"Lese {self.shown_name} …")
        try:
            try:
                message = await self._request(lambda s: protocol.get_firmware(s), protocol.SUB_FIRMWARE)
                self._set("firmware", protocol.firmware_version(message.payload))
            except (NoAnswer, NotConnected):
                pass
            try:
                message = await self._request(lambda s: protocol.get_preset_number(s), protocol.SUB_PRESET_NUMBER)
                slot = protocol.slot_of(message.payload)
                if slot is not None and slot < self.profile.slot_count:
                    self._set("active_slot", slot)
            except (NoAnswer, NotConnected):
                pass
            for slot in range(self.profile.slot_count):
                self._set("activity", f"Lese {self.profile.slot_name(slot)} …")
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
        self._require(devices.SWITCH_SLOT)
        if not 0 <= slot < self.profile.slot_count:
            raise NotSupported(self.profile.display_name)
        self._set("activity", f"Schalte auf {self.profile.slot_name(slot)} …")
        try:
            await self._switch_to(slot)
        finally:
            self._set("activity", None)
        self._set("active_slot", slot)
        self._set("trying_out", None)
        self._set("is_editing_live", False)

    async def try_out(self, preset: Preset) -> None:
        """Plays a preset without storing it. Switching to any slot ends it."""
        self._require(devices.PLAY_TEMPORARY)
        self._set("activity", f"Sende „{preset.name}“ …")
        try:
            await self._send(preset, protocol.TEMPORARY)
            await self._switch_to(0x7F)
        finally:
            self._set("activity", None)
        self.tried_preset = preset.copy()
        self._set("trying_out", preset.name)
        self._set("is_editing_live", False)
        self._set("active_slot", None)

    async def play_for_editing(self, preset: Preset) -> None:
        """Plays the editor's preset on the temporary place. Changes after it are heard at once."""
        self._require(devices.PLAY_TEMPORARY)
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
        """Sends one live change. Returns False when a change that the amp confirms got no answer. No device checked
        so far confirms a parameter (``04 04``), so a parameter is never waited for."""
        if change.kind in ("parameter", "toggle"):
            self._require(devices.LIVE_EDIT)
        if change.kind == "model":
            self._require(devices.MODEL_CHANGE)
        if change.kind == "parameter":
            if protocol.guarded_value(change.value) is None:
                raise Refused(["Der Wert ist keine Zahl."])
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
        self._require(devices.STORE)
        if not 0 <= slot < self.profile.slot_count:
            raise NotSupported(self.profile.display_name)
        self._set("activity", f"Speichere „{preset.name}“ auf {self.profile.slot_name(slot)} …")
        try:
            await self._send(preset, Place.of_slot(slot))
            await self._switch_to(slot)
            self._set("active_slot", slot)
            self._set("trying_out", None)
            self._set("is_editing_live", False)
            self._set("activity", f"Prüfe {self.profile.slot_name(slot)} …")
            stored = await self.read_preset(Place.of_slot(slot))
        finally:
            self._set("activity", None)
        self.slots[slot] = stored
        self._emit("slots", self.slots)
        # What went out had its description cut to the length the amp takes.
        if not stored.same_content(self._fitted(preset)):
            raise VerifyFailed(preset.name)

    async def current_preset(self, slot: int) -> Preset:
        """Reads a slot fresh from the amp, for a backup that must match what is really stored."""
        preset = await self.read_preset(Place.of_slot(slot))
        self.slots[slot] = preset
        self._emit("slots", self.slots)
        return preset


def _now() -> float:
    return asyncio.get_running_loop().time()
