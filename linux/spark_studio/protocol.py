"""The Bluetooth LE control protocol of Positive Grid Spark amps, and the preset encoding.

A port of Sources/SparkControl (SparkProtocol, SparkPreset, SparkEvents, SparkCommands). The Swift code is the
reference: change both together. A message is one or more chunks
``F0 01 <seq> <checksum> <command> <sub-command> <7-bit data> F7``, wrapped in a 16-byte block header when sent.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
import struct
import uuid as uuidlib
from dataclasses import dataclass, field

SERVICE_UUID = "0000ffc0-0000-1000-8000-00805f9b34fb"
WRITE_UUID = "0000ffc1-0000-1000-8000-00805f9b34fb"
NOTIFY_UUID = "0000ffc2-0000-1000-8000-00805f9b34fb"

NAME_LIMIT = 31
BPM_RANGE = (40.0, 250.0)
# No description longer than this many bytes goes to the amp. On 2026-11-08 a preset with a 136-byte description
# made the amp howl painfully loud with its volume knobs at zero, right after the same sound with an 82-byte
# description had played fine. The knobs do not protect against such a noise, so it is not raised by trying.
DESCRIPTION_LIMIT = 80

CMD_SET, CMD_GET, CMD_RESPONSE, CMD_ACK = 0x01, 0x02, 0x03, 0x04
SUB_PRESET, SUB_PARAMETER, SUB_CHANGE_EFFECT = 0x01, 0x04, 0x06
SUB_PRESET_NUMBER, SUB_AMP_NAME, SUB_EFFECT_ON_OFF, SUB_FIRMWARE = 0x10, 0x11, 0x15, 0x2F
SUB_PARAMETER_CHANGED, SUB_STORE_REQUEST, SUB_TAP_TEMPO = 0x37, 0x27, 0x63
SUB_HARDWARE_PRESET, SUB_TUNER_PITCH, SUB_TUNER = 0x38, 0x64, 0x65

CHUNK_CAPACITY = 0x19


def f32(value: float) -> float:
    """Rounds to the nearest 32-bit float, the precision the amp stores."""
    return struct.unpack(">f", struct.pack(">f", value))[0]


def f32_repr(value: float) -> float:
    """The shortest decimal that reads back as the same 32-bit float, so JSON files look like the Mac's."""
    for digits in range(1, 10):
        candidate = float(f"{value:.{digits}g}")
        if f32(candidate) == value:
            return candidate
    return value


# MARK: 7-bit packing


def pack7(data: bytes) -> bytes:
    out = bytearray()
    for start in range(0, len(data), 7):
        group = data[start:start + 7]
        mask = 0
        for bit, byte in enumerate(group):
            if byte & 0x80:
                mask |= 1 << bit
        out.append(mask)
        out.extend(b & 0x7F for b in group)
    return bytes(out)


def unpack7(data: bytes) -> bytes:
    out = bytearray()
    for start in range(0, len(data), 8):
        mask = data[start]
        for bit, byte in enumerate(data[start + 1:start + 8]):
            out.append(byte | 0x80 if mask & (1 << bit) else byte)
    return bytes(out)


def hexdump(data: bytes) -> str:
    return " ".join(f"{b:02X}" for b in data)


# MARK: Reading and writing the amp's MessagePack-like encoding


class DecodeError(Exception):
    pass


class Reader:
    def __init__(self, data: bytes):
        self.data = bytes(data)
        self.position = 0

    def byte(self) -> int:
        if self.position >= len(self.data):
            raise DecodeError(f"data ends at byte {self.position}")
        value = self.data[self.position]
        self.position += 1
        return value

    def take(self, count: int) -> bytes:
        if self.position + count > len(self.data):
            raise DecodeError(f"data ends at byte {len(self.data)}")
        chunk = self.data[self.position:self.position + count]
        self.position += count
        return chunk

    def rest(self) -> bytes:
        chunk = self.data[min(self.position, len(self.data)):]
        self.position = len(self.data)
        return chunk

    def string(self) -> str:
        start = self.position
        marker = self.byte()
        if 0xA0 <= marker <= 0xBF:
            length = marker - 0xA0
        elif marker == 0xD9:
            length = self.byte()
        else:
            raise DecodeError(f"byte {start} is 0x{marker:02X}, expected a string")
        return self.take(length).decode("utf-8", errors="replace")

    def float(self) -> float:
        start = self.position
        marker = self.byte()
        if marker != 0xCA:
            raise DecodeError(f"byte {start} is 0x{marker:02X}, expected 0xCA")
        return struct.unpack(">f", self.take(4))[0]

    def bool(self) -> bool:
        start = self.position
        value = self.byte()
        if value == 0xC3:
            return True
        if value == 0xC2:
            return False
        raise DecodeError(f"byte {start} is 0x{value:02X}, expected 0xC2 or 0xC3")

    def array_count(self) -> int:
        start = self.position
        marker = self.byte()
        if not 0x90 <= marker <= 0x9F:
            raise DecodeError(f"byte {start} is 0x{marker:02X}, expected an array")
        return marker - 0x90

    def prefixed_string(self) -> str:
        """``len, A0+len, bytes`` or a plain string."""
        start = self.position
        first = self.byte()
        if first < 0x80:
            text = self.string()
            if len(text.encode("utf-8")) != first:
                raise DecodeError(f"byte {start} is {first}, expected the string's length")
            return text
        self.position = start
        return self.string()


class Writer:
    def __init__(self):
        self.data = bytearray()

    def bytes(self, values) -> None:
        self.data.extend(values)

    def string(self, text: str) -> None:
        raw = text.encode("utf-8")
        if len(raw) > 255:
            cut = text[:255]
            while len(cut.encode("utf-8")) > 255:
                cut = cut[:-1]
            raw = cut.encode("utf-8")
        self.data.extend([0xA0 + len(raw)] if len(raw) < 32 else [0xD9, len(raw)])
        self.data.extend(raw)

    def prefixed_string(self, text: str) -> None:
        raw = text.encode("utf-8")[:31]
        self.data.extend([len(raw), 0xA0 + len(raw)])
        self.data.extend(raw)

    def float(self, value: float) -> None:
        self.data.append(0xCA)
        self.data.extend(struct.pack(">f", value))

    def bool(self, value: bool) -> None:
        self.data.append(0xC3 if value else 0xC2)

    def array(self, count: int) -> None:
        self.data.append(0x90 + min(count, 15))


# MARK: Preset

STANDARD_TRAILER = bytes([0xCA, 0x46, 0x1C, 0x18, 0x00, 0xCA, 0x3F, 0x00, 0x00, 0x00, 0x00])


@dataclass
class Parameter:
    index: int
    value: float
    marker: int = 0x91


@dataclass
class Effect:
    name: str
    is_on: bool
    parameters: list[Parameter]


@dataclass
class Place:
    """Where a preset is, as the first two bytes of a preset message."""
    kind: str  # "slot", "playing" or "temporary"
    slot: int = 0

    @property
    def bytes(self) -> bytes:
        if self.kind == "slot":
            return bytes([0x00, self.slot])
        if self.kind == "playing":
            return bytes([0x01, 0x00])
        return bytes([0x00, 0x7F])

    @staticmethod
    def of_slot(slot: int) -> "Place":
        return Place("slot", slot)


TEMPORARY = Place("temporary")
PLAYING = Place("playing")


@dataclass
class Preset:
    name: str
    effects: list[Effect]
    uuid: str = field(default_factory=lambda: str(uuidlib.uuid4()).upper())
    version: str = "0.7"
    description: str = ""
    icon: str = "icon.png"
    bpm: float = 120.0
    trailer: bytes = STANDARD_TRAILER

    def copy(self) -> "Preset":
        return copy.deepcopy(self)

    def effect_index(self, name: str) -> int | None:
        for index, effect in enumerate(self.effects):
            if effect.name == name:
                return index
        return None

    # Reading

    @staticmethod
    def from_payload(payload: bytes) -> "Preset":
        reader = Reader(payload)
        reader.byte()
        reader.byte()
        preset = Preset._read(reader)
        return preset

    @staticmethod
    def _read(reader: Reader) -> "Preset":
        uuid = reader.string()
        name = reader.string()
        version = reader.string()
        description = reader.string()
        icon = reader.string()
        bpm = reader.float()
        effects = []
        for _ in range(reader.array_count()):
            effect_name = reader.string()
            is_on = reader.bool()
            parameters = []
            for _ in range(reader.array_count()):
                index = reader.byte()
                marker = reader.byte()
                parameters.append(Parameter(index, reader.float(), marker))
            effects.append(Effect(effect_name, is_on, parameters))
        return Preset(name=name, effects=effects, uuid=uuid, version=version, description=description, icon=icon,
                      bpm=bpm, trailer=reader.rest())

    # Writing

    def _body(self) -> bytes:
        w = Writer()
        w.string(self.uuid)
        w.string(self.name)
        w.string(self.version)
        w.string(self.description)
        w.string(self.icon)
        w.float(self.bpm)
        w.array(len(self.effects))
        for effect in self.effects:
            w.string(effect.name)
            w.bool(effect.is_on)
            w.array(len(effect.parameters))
            for parameter in effect.parameters:
                w.bytes([parameter.index, parameter.marker])
                w.float(parameter.value)
        w.bytes(self.trailer)
        return bytes(w.data)

    @property
    def has_checksum(self) -> bool:
        """The trailer ends in one checksum byte, behind zero or more floats."""
        reader = Reader(self.trailer)
        while len(self.trailer) - reader.position > 1:
            try:
                reader.float()
            except DecodeError:
                return False
        return len(self.trailer) - reader.position == 1

    @property
    def trailer_floats(self) -> list[float]:
        reader = Reader(self.trailer)
        floats = []
        while True:
            try:
                floats.append(reader.float())
            except DecodeError:
                return floats

    @staticmethod
    def checksum(data: bytes) -> int:
        return sum(data) & 0xFF

    @property
    def checksum_matches(self) -> bool:
        if not self.has_checksum:
            return False
        return Preset.checksum(self._body()[:-1]) == self.trailer[-1]

    def encode(self, place: Place) -> bytes:
        """The payload for a preset message. The checksum is recomputed, so an edited preset stays consistent."""
        body = bytearray(self._body())
        if self.has_checksum:
            body[-1] = Preset.checksum(bytes(body[:-1]))
        return place.bytes + bytes(body)

    def same_content(self, other: "Preset") -> bool:
        """Equal apart from the checksum byte."""
        def stripped(p: "Preset") -> "Preset":
            q = p.copy()
            if q.has_checksum:
                q.trailer = q.trailer[:-1]
            return q
        return stripped(self) == stripped(other)

    # JSON, in the shape the Mac app writes (Swift Codable)

    def to_json(self) -> dict:
        return {
            "uuid": self.uuid, "name": self.name, "version": self.version, "description": self.description,
            "icon": self.icon, "bpm": f32_repr(self.bpm),
            "effects": [
                {"name": e.name, "isOn": e.is_on,
                 "parameters": [{"index": p.index, "value": f32_repr(p.value), "marker": p.marker}
                                for p in e.parameters]}
                for e in self.effects],
            "trailer": list(self.trailer),
        }

    @staticmethod
    def from_json(data: dict) -> "Preset":
        effects = [Effect(e["name"], bool(e["isOn"]),
                          [Parameter(int(p["index"]), f32(float(p["value"])), int(p.get("marker", 0x91)))
                           for p in e["parameters"]])
                   for e in data["effects"]]
        return Preset(name=data["name"], effects=effects, uuid=data["uuid"], version=data.get("version", "0.7"),
                      description=data.get("description", ""), icon=data.get("icon", "icon.png"),
                      bpm=f32(float(data.get("bpm", 120))), trailer=bytes(data.get("trailer", STANDARD_TRAILER)))


def name_problem(name: str) -> str | None:
    trimmed = name.strip()
    if not trimmed:
        return "Der Name darf nicht leer sein."
    if len(trimmed.encode("utf-8")) > NAME_LIMIT:
        return f"Höchstens {NAME_LIMIT} Zeichen (Umlaute zählen doppelt)."
    return None


def fit_description(text: str) -> str:
    """The description cut at a character boundary so it fits DESCRIPTION_LIMIT."""
    while len(text.encode("utf-8")) > DESCRIPTION_LIMIT:
        text = text[:-1]
    return text


# The last check before a preset goes to the amp, as AmpGuard on the Mac. On 2026-11-08 a sound that had just played
# fine made the amp howl at full volume once it was sent again with a 136-byte description: 540 bytes in 22 chunks,
# where everything that had worked had at most 486 bytes, 20 chunks and strings under 128 bytes. Both stay inside
# what is known to work. The amp's volume knobs did not help, so no limit is raised by trying it on the speaker.
PAYLOAD_LIMIT = 486
STRING_LIMIT = 127
UUID_LIMIT = 36
EFFECT_COUNT = 7


def guarded_value(value: float) -> float | None:
    """A value as it may go to the amp: within 0…1, None when it is no number."""
    return min(max(float(value), 0.0), 1.0) if math.isfinite(value) else None


def preset_size(preset: Preset) -> int:
    return len(preset.encode(TEMPORARY))


def for_amp(preset: Preset) -> Preset:
    """The preset with everything fitted that can be without changing the sound: values within 0…1, the tempo within
    range, the description within DESCRIPTION_LIMIT and short enough for PAYLOAD_LIMIT."""
    safe = copy.deepcopy(preset)
    safe.description = fit_description(preset.description)
    if math.isfinite(safe.bpm):
        safe.bpm = f32(min(max(safe.bpm, BPM_RANGE[0]), BPM_RANGE[1]))
    for effect in safe.effects:
        for parameter in effect.parameters:
            fitted = guarded_value(parameter.value)
            if fitted is not None and fitted != parameter.value:
                parameter.value = f32(fitted)
    while preset_size(safe) > PAYLOAD_LIMIT and safe.description:
        safe.description = safe.description[:-1]
    return safe


def for_device(preset: Preset, checked_text: dict | None) -> Preset:
    """``for_amp``, and on a device with checked text limits (the NEO) the texts fitted to what it was heard playing:
    the name cut, the description left out, version and icon as on the device. The sound stays the same."""
    if not checked_text:
        return for_amp(preset)
    source = preset.copy()
    source.name = _fit_bytes(source.name, checked_text["name_bytes"])
    source.description = _fit_bytes(source.description, checked_text["description_bytes"])
    source.version = checked_text["version"]
    source.icon = checked_text["icon"]
    return for_amp(source)


def _fit_bytes(text: str, limit: int) -> str:
    while len(text.encode("utf-8")) > limit:
        text = text[:-1]
    return text


def amp_problems(preset: Preset) -> list[str]:
    """What keeps the prepared preset from going to the amp. Empty when it may be sent."""
    safe = for_amp(preset)
    problems = []
    if len(safe.effects) != EFFECT_COUNT:
        problems.append(f"Das Preset hat {len(safe.effects)} statt {EFFECT_COUNT} Effekte.")
    if not math.isfinite(safe.bpm):
        problems.append("Das Tempo ist keine Zahl.")
    for effect in safe.effects:
        if any(not math.isfinite(p.value) for p in effect.parameters):
            problems.append(f"„{effect.name}“ hat einen Wert, der keine Zahl ist.")
    strings = [("Der Name", safe.name, NAME_LIMIT), ("Die Version", safe.version, NAME_LIMIT),
               ("Das Symbol", safe.icon, NAME_LIMIT), ("Die Kennung", safe.uuid, UUID_LIMIT)]
    strings += [(f"Der Effektname „{e.name[:20]}“", e.name, NAME_LIMIT) for e in safe.effects]
    for label, text, limit in strings:
        limit = min(limit, STRING_LIMIT)
        if len(text.encode("utf-8")) > limit:
            problems.append(f"{label} ist mit {len(text.encode('utf-8'))} Bytes zu lang (höchstens {limit}).")
    size = preset_size(safe)
    if size > PAYLOAD_LIMIT:
        problems.append(f"Das Preset ist mit {size} Bytes größer als die {PAYLOAD_LIMIT}, die der Verstärker sicher verträgt.")
    return problems


def fit_name(name: str) -> str:
    name = name.strip()
    while len(name.encode("utf-8")) > NAME_LIMIT:
        name = name[:-1]
    return name


# MARK: Messages


@dataclass
class Message:
    command: int
    sub: int
    sequence: int
    payload: bytes
    checksum_ok: bool = True


def is_multi_chunk(command: int, sub: int) -> bool:
    return sub == SUB_PRESET and command in (CMD_SET, CMD_RESPONSE)


def block_header(length: int) -> bytes:
    return bytes([0x01, 0xFE, 0x00, 0x00, 0x53, 0xFE, length & 0xFF]) + bytes(9)


def blocks(command: int, sub: int, payload: bytes, sequence: int, header: bool = True) -> list[bytes]:
    """A message as separate blocks, one chunk each. Each block goes to the amp in a write of its own."""
    if is_multi_chunk(command, sub):
        parts = [payload[i:i + CHUNK_CAPACITY] for i in range(0, max(len(payload), 1), CHUNK_CAPACITY)]
        chunks = [bytes([len(parts), number, len(part)]) + part for number, part in enumerate(parts)]
    else:
        chunks = [bytes(payload)]
    result = []
    for raw in chunks:
        packed = pack7(raw)
        checksum = 0
        for b in packed:
            checksum ^= b
        chunk = bytes([0xF0, 0x01, sequence & 0x7F, checksum, command, sub]) + packed + b"\xF7"
        result.append(block_header(len(chunk) + 16) + chunk if header else chunk)
    return result


def frame(command: int, sub: int, payload: bytes, sequence: int, header: bool = True) -> bytes:
    return b"".join(blocks(command, sub, payload, sequence, header))


def get_firmware(sequence: int) -> list[bytes]:
    return blocks(CMD_GET, SUB_FIRMWARE, b"", sequence)


def get_amp_name(sequence: int) -> list[bytes]:
    return blocks(CMD_GET, SUB_AMP_NAME, b"", sequence)


def get_preset_number(sequence: int) -> list[bytes]:
    return blocks(CMD_GET, SUB_PRESET_NUMBER, b"", sequence)


def get_preset(slot: int | None, sequence: int) -> list[bytes]:
    selector = bytes([0x00, slot]) if slot is not None else bytes([0x01, 0x00])
    return blocks(CMD_GET, SUB_PRESET, selector + bytes(30), sequence)


def send_preset(preset: Preset, place: Place, sequence: int) -> list[bytes]:
    """The description is cut to DESCRIPTION_LIMIT here, whatever the preset came from: a longer one made the amp howl."""
    return blocks(CMD_SET, SUB_PRESET, for_amp(preset).encode(place), sequence)


def change_hardware_preset(slot: int, sequence: int) -> list[bytes]:
    return blocks(CMD_SET, SUB_HARDWARE_PRESET, bytes([0x00, slot]), sequence)


def set_parameter(effect: str, index: int, value: float, sequence: int) -> list[bytes]:
    w = Writer()
    w.prefixed_string(effect)
    w.bytes([index])
    # Never more than full: a value outside 0…1 is no setting the amp knows. The link refuses non-numbers first.
    fitted = guarded_value(value)
    w.float(0.0 if fitted is None else fitted)
    w.bytes([0x00])
    return blocks(CMD_SET, SUB_PARAMETER, bytes(w.data), sequence)


def set_effect(effect: str, on: bool, sequence: int) -> list[bytes]:
    w = Writer()
    w.prefixed_string(effect)
    w.bool(on)
    w.bytes([0x00])
    return blocks(CMD_SET, SUB_EFFECT_ON_OFF, bytes(w.data), sequence)


def change_model(old: str, new: str, sequence: int) -> list[bytes]:
    w = Writer()
    w.prefixed_string(old)
    w.prefixed_string(new)
    w.bytes([0x00])
    return blocks(CMD_SET, SUB_CHANGE_EFFECT, bytes(w.data), sequence)


class Parser:
    """Collects notification bytes into messages. Notifications can split a chunk anywhere."""

    def __init__(self):
        self._current: bytearray | None = None
        self._pending: dict | None = None
        self.chunk_progress: tuple[int, int] | None = None

    def feed(self, data: bytes) -> list[Message]:
        messages = []
        for byte in data:
            if byte == 0xF0:
                self._current = bytearray()
            elif byte == 0xF7 and self._current is not None:
                chunk, self._current = bytes(self._current), None
                message = self._finish(chunk)
                if message:
                    messages.append(message)
            elif self._current is not None:
                self._current.append(byte)
        return messages

    def _finish(self, chunk: bytes) -> Message | None:
        if len(chunk) < 5 or chunk[0] != 0x01:
            return None
        sequence, checksum, command, sub = chunk[1], chunk[2], chunk[3], chunk[4]
        packed = chunk[5:]
        calculated = 0
        for b in packed:
            calculated ^= b
        ok = calculated == checksum
        data = unpack7(packed)
        if not is_multi_chunk(command, sub) or len(data) < 3:
            return Message(command, sub, sequence, data, ok)
        total, number = data[0], data[1]
        part = data[3:]
        pending = self._pending
        if number == 0 or pending is None or pending["command"] != command or pending["sub"] != sub:
            pending = self._pending = {"command": command, "sub": sub, "sequence": sequence, "data": bytearray(),
                                       "ok": True}
        pending["data"].extend(part)
        pending["ok"] = pending["ok"] and ok
        self.chunk_progress = (number + 1, total)
        if number + 1 < total:
            return None
        self._pending = None
        self.chunk_progress = None
        return Message(command, sub, pending["sequence"], bytes(pending["data"]), pending["ok"])


# MARK: Values and events


def firmware_version(payload: bytes) -> str | None:
    if len(payload) >= 5 and payload[0] == 0xCE:
        return ".".join(str(b) for b in payload[1:5])
    return None


def string_of(payload: bytes) -> str | None:
    """A string, also with the extra length byte in front that the amp puts before its name (``02 11``)."""
    data = bytes(payload)
    if len(data) >= 2 and data[0] < 0x80 and 0xA0 <= data[1] <= 0xBF:
        data = data[1:]
    try:
        return Reader(data).string()
    except DecodeError:
        return None


def slot_of(payload: bytes) -> int | None:
    return payload[1] if len(payload) >= 2 else None


@dataclass
class Event:
    kind: str  # parameter, effect_on_off, model_changed, preset_selected, store_requested, tuner, tuner_on, tap_tempo, ack
    effect: str = ""
    index: int = 0
    value: float = 0.0
    is_on: bool = False
    old: str = ""
    new: str = ""
    slot: int = 0
    sub: int = 0


def parse_event(message: Message) -> Event | None:
    if message.command == CMD_ACK:
        return Event("ack", sub=message.sub)
    if message.command != CMD_RESPONSE:
        return None
    reader = Reader(message.payload)
    try:
        if message.sub == SUB_PARAMETER_CHANGED:
            effect = reader.prefixed_string()
            index = reader.byte()
            return Event("parameter", effect=effect, index=index, value=reader.float())
        if message.sub == SUB_EFFECT_ON_OFF:
            effect = reader.prefixed_string()
            return Event("effect_on_off", effect=effect, is_on=reader.bool())
        if message.sub == SUB_CHANGE_EFFECT:
            old = reader.prefixed_string()
            return Event("model_changed", old=old, new=reader.prefixed_string())
        if message.sub == SUB_HARDWARE_PRESET:
            slot = slot_of(message.payload)
            return Event("preset_selected", slot=slot) if slot is not None else None
        if message.sub == SUB_STORE_REQUEST:
            slot = slot_of(message.payload)
            return Event("store_requested", slot=slot) if slot is not None else None
        if message.sub == SUB_TAP_TEMPO:
            return Event("tap_tempo", value=reader.float())
    except DecodeError:
        return None
    return None


def apply_event(preset: Preset, event: Event) -> bool:
    """Applies a change the amp reported, so a copy of the playing preset stays in step with it."""
    if event.kind == "parameter":
        place = preset.effect_index(event.effect)
        if place is None:
            return False
        for parameter in preset.effects[place].parameters:
            if parameter.index == event.index:
                parameter.value = event.value
                return True
        return False
    if event.kind == "effect_on_off":
        place = preset.effect_index(event.effect)
        if place is None:
            return False
        preset.effects[place].is_on = event.is_on
        return True
    if event.kind == "model_changed":
        place = preset.effect_index(event.old)
        if place is None:
            return False
        preset.effects[place].name = event.new
        return True
    return False


def _swift_number(value: float) -> str:
    """A 32-bit float the way Swift's JSONEncoder prints it: shortest digits, no ".0" on whole numbers."""
    short = f32_repr(value)
    if short == int(short) and abs(short) < 1e15:
        return str(int(short))
    return repr(short)


def canonical_effects(preset: Preset) -> str:
    """The effect chain as compact JSON with sorted keys, exactly the bytes the Mac app fingerprints."""
    effects = []
    for effect in preset.effects:
        parameters = ",".join(
            f'{{"index":{p.index},"marker":{p.marker},"value":{_swift_number(p.value)}}}' for p in effect.parameters)
        name = json.dumps(effect.name, ensure_ascii=False).replace("/", "/")
        effects.append(f'{{"isOn":{"true" if effect.is_on else "false"},"name":{name},"parameters":[{parameters}]}}')
    return "[" + ",".join(effects) + "]"


def fingerprint(preset: Preset) -> str:
    """SHA-256 of the effect chain in lowercase hex: the sound of a take. Name, BPM, uuid and trailer do not count."""
    return hashlib.sha256(canonical_effects(preset).encode("utf-8")).hexdigest()
