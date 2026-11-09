"""Device profiles and the REACTOR's reports. A port of Sources/SparkControl/Devices (DeviceProfile, ReactorState); the
Swift code is the reference, change both together.

Every device gets only what was checked on it with the user. Listening (subscribing to what a device reports) is separate
from sending: a profile without ``send`` must not get a single byte, not even a read request. A device not listed here
gets a cautious profile that only reads and switches until it is checked.
"""
from __future__ import annotations

from dataclasses import dataclass, field, replace

from . import protocol
from .protocol import Message, Reader

SPARK_SERVICE = "ffc0"
REACTOR_SERVICE = "ffd0"
SPARK_SERVICE_UUID = protocol.SERVICE_UUID
REACTOR_SERVICE_UUID = "0000ffd0-0000-1000-8000-00805f9b34fb"
SEARCHED_SERVICES = [SPARK_SERVICE_UUID, REACTOR_SERVICE_UUID]

# Capabilities
LISTEN, SEND, READ, SWITCH_SLOT, PLAY_TEMPORARY = "listen", "send", "read", "switch_slot", "play_temporary"
LIVE_EDIT, STORE, MODEL_CHANGE, BUTTON_EVENTS = "live_edit", "store", "model_change", "button_events"
TUNER, TAP_TEMPO, USB_AUDIO, TEXT_TO_TONE = "tuner", "tap_tempo", "usb_audio", "text_to_tone"


@dataclass(frozen=True)
class DeviceProfile:
    id: str  # spark_mini, spark_neo, reactor50, reactor100, unknown_spark
    display_name: str
    ble_service: str
    ble_name_prefixes: tuple[str, ...]
    amp_names: tuple[str, ...]
    slot_count: int
    transport: str  # spark_ble, midi, text_only
    capabilities: frozenset[str]
    keeps_temporary_after_disconnect: bool | None  # None: not checked, counts as "loses it"
    confirms_parameters: bool
    checked_firmware: str | None
    usb_audio_names: tuple[str, ...]
    checked: str
    bank_size: int | None = None
    bank_names: tuple[str, ...] = ()
    midi_target: str | None = None

    def can(self, capability: str) -> bool:
        return capability in self.capabilities

    @property
    def can_send(self) -> bool:
        return SEND in self.capabilities

    @property
    def loses_temporary_on_disconnect(self) -> bool:
        return self.keeps_temporary_after_disconnect is not True

    def slot_name(self, slot: int) -> str:
        """"Platz 3", or with banks "Grün 1" for slot 4."""
        if self.bank_size and 0 <= slot and slot // self.bank_size < len(self.bank_names):
            return f"{self.bank_names[slot // self.bank_size]} {slot % self.bank_size + 1}"
        return f"Platz {slot + 1}"


_FULL = frozenset({LISTEN, SEND, READ, SWITCH_SLOT, PLAY_TEMPORARY, LIVE_EDIT, STORE, MODEL_CHANGE, BUTTON_EVENTS})

SPARK_MINI = DeviceProfile(
    "spark_mini", "Spark MINI", SPARK_SERVICE, ("Spark MINI",), ("Spark MINI",), 4, "spark_ble",
    _FULL | {TUNER, TAP_TEMPO, USB_AUDIO}, None, False, "1.11.2.75", ("spark",),
    "Lesen, Umschalten, Ausprobieren, Live-Ändern, Modellwechsel und Speichern, Firmware 1.11.2.75.")

SPARK_NEO = DeviceProfile(
    "spark_neo", "Spark NEO", SPARK_SERVICE, ("Spark NEO",), ("Spark NEO",), 4, "spark_ble", _FULL, False, False,
    "1.16.1.60", (),
    "Lesen, Umschalten, Ausprobieren, Live-Ändern, Modellwechsel, Speichern und die mittlere Taste, Firmware "
    "1.16.1.60. Trennen verwirft den vorübergehenden Sound.")

REACTOR_50 = DeviceProfile(
    "reactor50", "REACTOR 50", REACTOR_SERVICE, ("Reactor 50",), (), 8, "spark_ble",
    frozenset({LISTEN, BUTTON_EVENTS, TUNER, TAP_TEMPO, USB_AUDIO, TEXT_TO_TONE}), None, False, None,
    (),  # its USB audio name joins once read on the device, nothing is guessed
    "Nur mitgelesen: Regler, Amp-Wahl, Push/Smooth, Heat, Effekte, TAP, Preset, Bank und Stimmgerät. Es wurde nie "
    "etwas gesendet.", bank_size=4, bank_names=("Rot", "Grün"))

REACTOR_100 = replace(REACTOR_50, id="reactor100", display_name="REACTOR 100", ble_name_prefixes=("Reactor 100",),
                      checked="Nicht geprüft. Wie der REACTOR 50 behandelt: nur mitlesen, nichts senden.")

UNKNOWN_SPARK = DeviceProfile(
    "unknown_spark", "Spark", SPARK_SERVICE, ("Spark",), (), 4, "spark_ble",
    frozenset({LISTEN, SEND, READ, SWITCH_SLOT, BUTTON_EVENTS}), None, False, None, (),
    "Nicht geprüft. Nur Lesen und Umschalten, bis das Gerät mit dem Nutzer geprüft ist.")

ALL = [SPARK_MINI, SPARK_NEO, REACTOR_50, REACTOR_100, UNKNOWN_SPARK]
LARGEST_SLOT_COUNT = max(p.slot_count for p in ALL)


def profile(profile_id: str) -> DeviceProfile:
    return next((p for p in ALL if p.id == profile_id), UNKNOWN_SPARK)


def for_advertisement(service: str, name: str | None) -> DeviceProfile:
    """FFD0 is a REACTOR, recognised without any request. A Spark is told apart by its Bluetooth name and confirmed by
    its amp name (``02 11``) once connected."""
    lower = (name or "").lower()
    if service.lower().startswith(REACTOR_SERVICE) or service.lower() == REACTOR_SERVICE_UUID:
        return REACTOR_100 if lower.startswith("reactor 100") else REACTOR_50
    for p in ALL:
        if p.ble_service == SPARK_SERVICE and p.id != "unknown_spark" and \
                any(lower.startswith(prefix.lower()) for prefix in p.ble_name_prefixes):
            return p
    return UNKNOWN_SPARK


def for_amp_name(amp_name: str) -> DeviceProfile | None:
    name = amp_name.strip().lower()
    return next((p for p in ALL if any(a.lower() == name for a in p.amp_names)), None)


def loggable_name(name: str | None) -> str:
    """A REACTOR's Bluetooth name ends in a part its owner chose; it never goes into a log or the probe's output."""
    if name is None:
        return "?"
    lower = name.lower()
    for prefix in ("reactor 100", "reactor 50"):
        if lower.startswith(prefix):
            return name[:len(prefix)]
    return name


def recordable_usb_names() -> list[str]:
    names: list[str] = []
    for p in ALL:
        for name in p.usb_audio_names:
            if name not in names:
                names.append(name)
    return names


# MARK: What a REACTOR reports

AMP_NAMES = ["Clean", "Warm", "Grit", "Crunch", "Hi-Gain", "Extreme"]
VOICE_NAMES = ["Push", "Standard", "Smooth"]
PLACE_NAMES = ["Gate", "Comp", "Drive", "Amp", "Mod", "Delay", "Reverb"]
KNOBS = {("Amp.Preamp", 0): "gain", ("Amp.Tonestack", 1): "bass", ("Amp.Tonestack", 2): "middle",
         ("Amp.Tonestack", 3): "treble", ("Amp.Poweramp", 0): "master"}
KNOB_TITLES = {"gain": "Gain", "bass": "Bass", "middle": "Middle", "treble": "Treble", "master": "Master"}
SUB_AMP_SELECTOR = 0xB1
SUB_SELECTED_EFFECT = 0xB3


@dataclass
class ReactorEffect:
    model: str
    is_on: bool | None = None
    place: int | None = None
    parameters: dict[int, float] = field(default_factory=dict)

    @property
    def level(self) -> float | None:
        return self.parameters.get(0)


def _catalog_place(model: str) -> int | None:
    try:
        from . import catalog
        info = catalog.load().models.get(model)
    except Exception:
        return None
    if info is None:
        return None
    index = catalog.PLACES.index(info.place) if info.place in catalog.PLACES else None
    return None if index in (None, 3) else index


@dataclass
class ReactorState:
    """What a REACTOR reports by itself. After a slot change everything but the slot is unknown again, because it
    does not send the preset and may not be asked. Messages of unknown meaning (such as ``03 1A``) are counted."""
    slot: int | None = None
    amp: int | None = None
    voice: int | None = None
    heat: int | None = None
    knobs: dict[str, float] = field(default_factory=dict)
    effects: dict[str, ReactorEffect] = field(default_factory=dict)
    selected_place: int | None = None
    level_model: str | None = None
    tempo: float | None = None
    tuner_on: bool = False
    tuner_reading: float | None = None
    unknown: dict[str, int] = field(default_factory=dict)
    _last_switched_on: str | None = None

    @property
    def bank(self) -> int | None:
        return None if self.slot is None else self.slot // 4

    @property
    def amp_name(self) -> str | None:
        return AMP_NAMES[self.amp] if self.amp is not None and 0 <= self.amp < 6 else None

    @property
    def voice_name(self) -> str | None:
        return VOICE_NAMES[self.voice] if self.voice is not None and 0 <= self.voice < 3 else None

    @property
    def has_readings(self) -> bool:
        return any(v is not None for v in (self.amp, self.voice, self.heat, self.tempo)) or bool(self.knobs) \
            or bool(self.effects)

    def _effect(self, model: str) -> ReactorEffect:
        if model not in self.effects:
            self.effects[model] = ReactorEffect(model, place=_catalog_place(model))
        return self.effects[model]

    def apply(self, message: Message) -> bool:
        if message.command != protocol.CMD_RESPONSE:
            self._count(message)
            return False
        payload = message.payload
        reader = Reader(payload)
        try:
            if message.sub == protocol.SUB_HARDWARE_PRESET:
                slot = protocol.slot_of(payload)
                if slot is not None and slot < 8:
                    self._switch(slot)
                    return True
            elif message.sub == SUB_AMP_SELECTOR:
                if len(payload) >= 2 and payload[0] < 6 and payload[1] < 15:
                    self.amp, self.voice, self.heat = payload[0], payload[1] // 5, payload[1] % 5
                    return True
            elif message.sub == SUB_SELECTED_EFFECT:
                if payload and payload[0] < 7:
                    self.selected_place = payload[0]
                    model = self._last_switched_on
                    if model and model in self.effects and self.effects[model].place is None:
                        self.effects[model].place = payload[0]
                    self._last_switched_on = None
                    return True
            elif message.sub == protocol.SUB_PARAMETER_CHANGED:
                block = reader.prefixed_string()
                index = reader.byte()
                value = reader.float()
                if value == value and abs(value) != float("inf"):
                    if (block, index) in KNOBS:
                        self.knobs[KNOBS[(block, index)]] = value
                        return True
                    if not block.startswith("Amp."):
                        self._effect(block).parameters[index] = value
                        if index == 0:
                            self.level_model = block
                        return True
            elif message.sub == protocol.SUB_EFFECT_ON_OFF:
                model = reader.prefixed_string()
                is_on = reader.bool()
                self._effect(model).is_on = is_on
                self._last_switched_on = model if is_on else None
                return True
            elif message.sub == protocol.SUB_TAP_TEMPO:
                bpm = reader.float()
                if bpm > 0:
                    self.tempo = bpm
                    return True
            elif message.sub == protocol.SUB_TUNER:
                self.tuner_on = reader.bool()
                if not self.tuner_on:
                    self.tuner_reading = None
                return True
            elif message.sub == protocol.SUB_TUNER_PITCH:
                reader.byte()
                value = reader.float()
                self.tuner_reading = None if value < 0 else value
                return True
        except protocol.DecodeError:
            pass
        self._count(message)
        return False

    def _switch(self, slot: int) -> None:
        # The preset key reports the same slot twice; that is no change.
        if slot != self.slot:
            self.amp = self.voice = self.heat = None
            self.knobs, self.effects = {}, {}
            self.selected_place = self.level_model = self._last_switched_on = None
        self.slot = slot

    def _count(self, message: Message) -> None:
        key = f"{message.command:02X} {message.sub:02X}"
        self.unknown[key] = self.unknown.get(key, 0) + 1

    def lines(self, device: DeviceProfile = REACTOR_50) -> list[tuple[str, str]]:
        lines: list[tuple[str, str]] = []
        if self.slot is not None:
            lines.append(("Platz", device.slot_name(self.slot)))
        if self.amp_name:
            lines.append(("Amp", self.amp_name))
        if self.voice_name:
            lines.append(("Push/Smooth", self.voice_name))
        if self.heat is not None:
            lines.append(("Heat", f"{self.heat + 1} von 5"))
        for knob in ("gain", "bass", "middle", "treble", "master"):
            if knob in self.knobs:
                lines.append((KNOB_TITLES[knob], tenths(self.knobs[knob])))
        for effect in sorted(self.effects.values(), key=lambda e: (99 if e.place is None else e.place, e.model)):
            parts = []
            if effect.is_on is not None:
                parts.append("an" if effect.is_on else "aus")
            if effect.level is not None:
                parts.append(f"Level {tenths(effect.level)}")
            place = "FX" if effect.place is None else PLACE_NAMES[effect.place]
            lines.append((f"{place} {effect.model}", ", ".join(parts) or "gesehen"))
        if self.tempo is not None:
            lines.append(("Tempo", f"{round(self.tempo)} BPM"))
        return lines


def tenths(value: float) -> str:
    return f"{min(max(value, 0.0), 1.0) * 10:.1f}".replace(".", ",")
