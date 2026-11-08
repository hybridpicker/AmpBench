"""A simulated Spark amp, for tests and ``spark-studio --demo``. It answers the way the real one does (see
SparkLink.swift): chunk acknowledgements ``05 01`` and ``04 01`` for presets, ``04 38`` for a preset switch, ``04 15``
and ``04 06`` for changes, and nothing for a parameter."""
from __future__ import annotations

import asyncio

from . import factory, protocol
from .link import NotConnected, Transport
from .protocol import Message, Parser, Place, Preset


class FakeAmp(Transport):
    def __init__(self, slots: list[Preset] | None = None, delay: float = 0.0, drop_first_answer: bool = False):
        templates = factory.templates()
        self.slots = slots or [factory.make(templates[i]) for i in (0, 1, 2, 3)]
        self.active = 0
        self.temporary: Preset | None = None
        self.delay = delay
        self.log: list[tuple[int, int]] = []
        self.parameters: list[tuple[str, int, float]] = []
        self.connected = False
        self._parser = Parser()
        self._on_notify = lambda data: None
        self._on_disconnect = lambda: None
        self._drop = drop_first_answer
        self._seq = 0

    async def connect(self, on_found, on_notify, on_disconnect):
        on_found("Spark MINI")
        self._on_notify, self._on_disconnect = on_notify, on_disconnect
        self.connected = True

    async def disconnect(self):
        if self.connected:
            self.connected = False

    def drop_connection(self) -> None:
        self.connected = False
        self._on_disconnect()

    def press_button(self, slot: int) -> None:
        """The player presses the preset button on the amp."""
        self.active = slot
        self._reply(protocol.CMD_RESPONSE, protocol.SUB_HARDWARE_PRESET, bytes([0, slot]))

    async def write(self, blocks):
        if not self.connected:
            raise NotConnected()
        for block in blocks:
            for message in self._parser.feed(block):
                self._handle(message)

    # The amp's side

    def _reply(self, command: int, sub: int, payload: bytes) -> None:
        self._seq = (self._seq + 1) & 0x7F
        wire = b"".join(protocol.blocks(command, sub, payload, self._seq, header=False))
        loop = asyncio.get_running_loop()
        for i in range(0, len(wire), 20):  # notifications split chunks anywhere
            loop.call_later(self.delay, self._on_notify, wire[i:i + 20])

    def _handle(self, message: Message) -> None:
        self.log.append((message.command, message.sub))
        if self._drop and message.command == protocol.CMD_GET:
            self._drop = False  # the real amp sometimes ignores a request
            return
        c, s = message.command, message.sub
        if c == protocol.CMD_GET and s == protocol.SUB_FIRMWARE:
            self._reply(protocol.CMD_RESPONSE, s, bytes([0xCE, 1, 11, 2, 75]))
        elif c == protocol.CMD_GET and s == protocol.SUB_PRESET_NUMBER:
            self._reply(protocol.CMD_RESPONSE, s, bytes([0, self.active]))
        elif c == protocol.CMD_GET and s == protocol.SUB_PRESET:
            if message.payload[0] == 0x01:
                preset = self.temporary or self.slots[self.active]
                place = protocol.PLAYING
            else:
                preset, place = self.slots[message.payload[1]], Place.of_slot(message.payload[1])
            self._reply(protocol.CMD_RESPONSE, s, preset.encode(place))
        elif c == protocol.CMD_SET and s == protocol.SUB_PRESET:
            preset = Preset.from_payload(message.payload)
            for _ in range(max(1, (len(message.payload) + 24) // 25)):
                self._reply(0x05, s, b"")
            if message.payload[1] == 0x7F:
                self.temporary = preset
            else:
                self.slots[message.payload[1]] = preset
            self._reply(protocol.CMD_ACK, s, b"")
        elif c == protocol.CMD_SET and s == protocol.SUB_HARDWARE_PRESET:
            slot = message.payload[1]
            if slot != 0x7F:
                self.active, self.temporary = slot, None
            self._reply(protocol.CMD_ACK, s, message.payload)
        elif c == protocol.CMD_SET and s == protocol.SUB_PARAMETER:
            from .protocol import Reader
            reader = Reader(message.payload)
            self.parameters.append((reader.prefixed_string(), reader.byte(), reader.float()))
        elif c == protocol.CMD_SET and s in (protocol.SUB_EFFECT_ON_OFF, protocol.SUB_CHANGE_EFFECT):
            self._reply(protocol.CMD_ACK, s, b"")
