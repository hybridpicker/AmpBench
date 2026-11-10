"""Import from a Kemper Profiler: reads a backup (.kpabackup) or a rig (.kipr) and turns rigs into sound recipes.

A port of Sources/SparkControl/Kemper; the Swift code is the reference, change both together. Read only: nothing is
ever sent to a Kemper and its files are not changed.

A rig file is a MIDI-like frame ("KThd" or "MThd", then "KTrk"/"MTrk" chunks) of Kemper SysEx (00 20 33): function 02
sets parameters from a number on (14-bit values, 8192 in the middle), 03 strings. A backup is a tar archive with
Rigs/*.kipr and repository.kdb (SQLite) for the performances. docs/STUDIO.md, "Kemper-Import", has the details.
"""
from __future__ import annotations

import io
import re
import sqlite3
import tarfile
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from . import catalog, recipe
from .i18n import tr
from .protocol import fingerprint, fit_description, fit_name


class KemperError(Exception):
    pass


# String parameter numbers as rig files use them. The Kemper's MIDI documentation lists the amp's six lower.
RIG_NAME, RIG_AUTHOR = 1, 2
AMP_NAME, AMP_MAKER, AMP_MODEL = 16, 21, 24
# Address pages.
PAGE_RIG, PAGE_AMP, PAGE_EQ = 4, 10, 11
PAGE_DELAY, PAGE_REVERB, PAGE_OLD_REVERB = 60, 61, 75
MODULES = [(50, "A"), (51, "B"), (52, "C"), (53, "D"), (56, "X"), (58, "MOD"), (60, "DLY"), (61, "REV")]

EFFECT_TYPES = {
    1: "Wah Wah", 2: "Wah Low Pass", 3: "Wah High Pass", 4: "Wah Vowel Filter", 6: "Wah Phaser", 7: "Wah Flanger",
    8: "Wah Rate Reducer", 9: "Wah Ring Modulator", 10: "Wah Freq Shifter", 11: "Pedal Pitch",
    12: "Wah Formant Shifter", 13: "Pedal Vinyl Stop", 17: "Bit Shaper", 18: "Octa Shaper", 19: "Soft Shaper",
    20: "Hard Shaper", 21: "Wave Shaper", 32: "Kemper Drive", 33: "Green Scream", 34: "Plus DS", 35: "One DS",
    36: "Muffin", 37: "Mouse", 38: "Kemper Fuzz", 39: "Metal DS", 42: "Full OC", 49: "Compressor", 50: "Auto Swell",
    57: "Noise Gate 2:1", 58: "Noise Gate 4:1", 64: "Space", 65: "Vintage Chorus", 66: "Hyper Chorus",
    67: "Air Chorus", 68: "Vibrato", 69: "Rotary Speaker", 70: "Tremolo", 71: "Micro Pitch", 81: "Phaser",
    82: "Phaser Vibe", 83: "Phaser Oneway", 89: "Flanger", 91: "Flanger Oneway", 97: "Graphic Equalizer",
    98: "Studio Equalizer", 99: "Metal Equalizer", 100: "Acoustic Simulator", 101: "Stereo Widener",
    102: "Phase Widener", 103: "Delay Widener", 104: "Double Tracker", 113: "Treble Booster", 114: "Lead Booster",
    115: "Pure Booster", 116: "Wah Pedal Booster", 121: "Loop Mono", 122: "Loop Stereo", 123: "Loop Distortion",
    129: "Transpose", 130: "Chromatic Pitch", 131: "Harmonic Pitch", 132: "Analog Octaver", 137: "Dual Chromatic",
    138: "Dual Harmonic", 139: "Dual Crystal", 140: "Dual Loop Pitch", 145: "Legacy Delay", 146: "Single Delay",
    147: "Dual Delay", 148: "Two Tap Delay", 149: "Serial TwoTap Delay", 150: "Crystal Delay",
    151: "Loop Pitch Delay", 152: "Freq Shifter Delay", 161: "Rhythm Delay", 162: "Melody Chromatic",
    163: "Melody Harmonic", 164: "Quad Delay", 165: "Quad Chromatic", 166: "Quad Harmonic", 177: "Legacy Reverb",
    178: "Natural Reverb", 179: "Easy Reverb", 180: "Echo Reverb", 181: "Cirrus Reverb", 182: "Formant Reverb",
    183: "Ionosphere Reverb", 193: "Spring Reverb",
}


def effect_name(kind: int) -> str:
    return EFFECT_TYPES.get(kind, tr("Effect {}", kind))


def _tenths(value: float) -> float:
    return round(value * 10) / 10


# MARK: Rig


@dataclass
class Module:
    slot: str
    page: int
    type: int
    is_on: bool

    @property
    def type_name(self) -> str:
        return effect_name(self.type)


@dataclass
class Rig:
    """One rig: its strings by number and its parameters by address page and number (0 to 16383)."""
    strings: dict[int, str] = field(default_factory=dict)
    pages: dict[int, dict[int, int]] = field(default_factory=dict)

    def string(self, tag: int) -> str | None:
        text = self.strings.get(tag, "").strip()
        return text or None

    def value(self, page: int, parameter: int) -> int | None:
        return self.pages.get(page, {}).get(parameter)

    @property
    def name(self) -> str:
        return self.string(RIG_NAME) or tr("No name")

    @property
    def amp_description(self) -> str:
        parts: list[str] = []
        for tag in (AMP_MAKER, AMP_MODEL, AMP_NAME):
            text = self.string(tag)
            if text and text.casefold() not in (p.casefold() for p in parts):
                parts.append(text)
        return " ".join(parts)

    @property
    def is_placeholder(self) -> bool:
        """No real profile: no amp named, or the Kemper's own "Crunch Amp" that fills new performances."""
        if self.string(AMP_MODEL) or self.string(AMP_MAKER):
            return False
        amp = self.string(AMP_NAME)
        return amp is None or amp == "Crunch Amp" or self.string(18) == "AmpCreationDateTag"

    def knob(self, page: int, parameter: int) -> float | None:
        value = self.value(page, parameter)
        return None if value is None else _tenths(value / 16383 * 10)

    def signed_knob(self, page: int, parameter: int) -> float:
        value = self.value(page, parameter)
        return 0.0 if value is None else _tenths((value - 8192) / 8192 * 5)

    @property
    def gain(self) -> float | None:
        return self.knob(PAGE_AMP, 4)

    @property
    def tempo(self) -> float | None:
        raw = self.value(PAGE_RIG, 0)
        if self.value(PAGE_RIG, 2) != 1 or raw is None:
            return None
        bpm = round(raw / 64)
        return float(bpm) if 40 <= bpm <= 250 else None

    @property
    def modules(self) -> list[Module]:
        result = []
        for page, name in MODULES:
            kind = self.value(page, 0)
            if kind:
                result.append(Module(name, page, kind, self.value(page, 3) == 1))
        return result

    @property
    def old_reverb(self) -> tuple[bool, float, float] | None:
        """The reverb of OS 2 to 5 (page 75): on, mix and time from 0 to 10."""
        if PAGE_OLD_REVERB not in self.pages:
            return None
        return (self.value(PAGE_OLD_REVERB, 2) == 1, self.knob(PAGE_OLD_REVERB, 3) or 0.0,
                self.knob(PAGE_OLD_REVERB, 6) if self.knob(PAGE_OLD_REVERB, 6) is not None else 5.0)


# MARK: Reading


def _variable_length(data: bytes, index: int) -> tuple[int, int] | None:
    value = 0
    for _ in range(4):
        if index >= len(data):
            return None
        byte = data[index]
        index += 1
        value = value << 7 | (byte & 0x7F)
        if not byte & 0x80:
            return value, index
    return None


def events(data: bytes) -> list[bytes]:
    """The SysEx messages in a stream of timed events: delta time, F0, length, message."""
    messages, index = [], 0
    while index < len(data):
        delta = _variable_length(data, index)
        if delta is None or delta[1] >= len(data) or data[delta[1]] != 0xF0:
            break
        length = _variable_length(data, delta[1] + 1)
        if length is None or length[1] + length[0] > len(data):
            break
        messages.append(data[length[1]:length[1] + length[0]])
        index = length[1] + length[0]
    return messages


def _rig(messages: list[bytes]) -> Rig:
    rig = Rig()
    for body in messages:
        if len(body) < 9 or body[:3] != b"\x00\x20\x33":
            continue
        function, rest = body[5], body[7:]
        if rest.endswith(b"\xF7"):
            rest = rest[:-1]
        if function == 0x03 and len(rest) >= 2 and rest[0] == 0:
            # The first string of a number wins.
            rig.strings.setdefault(rest[1], rest[2:].split(b"\x00")[0].decode("utf-8", "replace"))
        elif function in (0x01, 0x02) and len(rest) >= 4:
            page, number = rest[0], rest[1]
            for offset in range(2, len(rest) - 1, 2):
                rig.pages.setdefault(page, {})[number] = rest[offset] << 7 | rest[offset + 1]
                number += 1
    return rig


def rig_file(data: bytes) -> Rig:
    if len(data) < 14 or data[:4] not in (b"KThd", b"MThd"):
        raise KemperError(tr("The Kemper file is damaged: {}", tr("no rig header")))
    index = 8 + int.from_bytes(data[4:8], "big")
    messages: list[bytes] = []
    while index + 8 <= len(data) and data[index:index + 4] in (b"KTrk", b"MTrk"):
        end = min(index + 8 + int.from_bytes(data[index + 4:index + 8], "big"), len(data))
        messages += events(data[index + 8:end])
        index = end
    return _rig(messages)


def rig_stream(data: bytes) -> Rig:
    """A stream of events without a frame, as a performance keeps its slots."""
    return _rig(events(data))


@dataclass
class Performance:
    number: int
    name: str
    slots: list[Rig | None]
    slot_names: list[str] = field(default_factory=lambda: [""] * 5)

    def slot_name(self, index: int) -> str:
        own = self.slot_names[index].strip() if index < len(self.slot_names) else ""
        if own:
            return own
        rig = self.slots[index] if index < len(self.slots) else None
        return (rig.string(RIG_NAME) if rig else None) or tr("Slot {}", index + 1)

    @property
    def is_unused(self) -> bool:
        lowered = self.name.casefold()
        return (not self.name or lowered in ("new performance", "default performance")
                or lowered.startswith("example") or all(slot is None for slot in self.slots))


@dataclass
class Library:
    rigs: list[Rig]
    performances: list[Performance]

    @property
    def own_performances(self) -> list[Performance]:
        return [p for p in self.performances if not p.is_unused]


def _performance_strings(data: bytes) -> dict[int, str]:
    strings = {}
    for body in events(data):
        # 00 20 33 | product, device | 07 | 00 00 01 00 | index | text 00
        if len(body) > 12 and body[:3] == b"\x00\x20\x33" and body[5] == 0x07:
            strings[body[11]] = re.split(b"[\x00\xF7]", body[12:])[0].decode("utf-8", "replace")
    return strings


def _performances(database: bytes) -> list[Performance]:
    # SQLite reads from a file. The copy is private to this user and removed right after.
    with tempfile.TemporaryDirectory(prefix="spark-kemper-") as folder:
        path = Path(folder) / "repository.kdb"
        path.write_bytes(database)
        try:
            db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        except sqlite3.Error as error:
            raise KemperError(tr("The Kemper file is damaged: {}", tr("database cannot be read"))) from error
        try:
            order = [row[0] for row in db.execute("SELECT perfid FROM perflist ORDER BY id")]
            result = []
            for position, perf_id in enumerate(order):
                row = db.execute("SELECT perfdata FROM perfs WHERE id = ?", (perf_id,)).fetchone()
                names = _performance_strings(bytes(row[0] or b"") if row else b"")
                slots: list[Rig | None] = [None] * 5
                for slot, track in db.execute(
                        "SELECT p.slot, t.track FROM perfslots p JOIN perftracks t ON t.id = p.trackid "
                        "WHERE p.perfid = ? ORDER BY p.slot", (perf_id,)):
                    if slot is None or not 0 <= slot < 5:
                        continue
                    rig = rig_stream(bytes(track or b""))
                    placeholder = rig.is_placeholder or (rig.string(RIG_NAME) or "") in ("Initialized Rig", "Slot", "")
                    slots[slot] = None if placeholder else rig
                result.append(Performance(position + 1, names.get(0, ""), slots,
                                          [names.get(i, "") for i in range(1, 6)]))
            return result
        except sqlite3.Error as error:
            raise KemperError(tr("The Kemper file is damaged: {}", tr("database has an unknown schema"))) from error
        finally:
            db.close()


def backup(data: bytes) -> Library:
    try:
        archive = tarfile.open(fileobj=io.BytesIO(data))
    except tarfile.TarError as error:
        raise KemperError(tr("The Kemper file is damaged: {}", tr("not an archive"))) from error
    rigs: list[tuple[str, Rig]] = []
    database = None
    with archive:
        members = [m for m in archive.getmembers() if m.isfile()]
        if not members:
            raise KemperError(tr("The Kemper file is damaged: {}", tr("empty archive")))
        for member in members:
            parts = [p for p in member.name.split("/") if p not in (".", "")]
            # Only names are looked at; nothing is ever extracted to disk under a name from the archive.
            if len(parts) == 2 and parts[0] == "Rigs" and parts[1].lower().endswith(".kipr"):
                try:
                    rigs.append((member.name, rig_file(archive.extractfile(member).read())))
                except KemperError:
                    pass
            elif parts and parts[-1] == "repository.kdb":
                database = archive.extractfile(member).read()
    rigs.sort(key=lambda pair: pair[0])
    return Library([rig for _, rig in rigs], _performances(database) if database else [])


def read(path: Path) -> Library:
    """Reads a rig file (.kipr) or a backup of the whole Kemper (.kpabackup)."""
    suffix = path.suffix.lower()
    if suffix == ".kipr":
        return Library([rig_file(path.read_bytes())], [])
    if suffix == ".kpabackup":
        return backup(path.read_bytes())
    raise KemperError(tr("“{}” is not a Kemper file (expected: .kipr or .kpabackup).", path.name))


# MARK: Translation

# First match wins: words in the rig's amp and name, the Spark amp, and the gain from which the rule applies.
AMP_RULES: list[tuple[list[str], str, float]] = [
    (["jazz chorus", "roland jc", " jc-120", "jc120"], "RolandJC120", 0),
    (["5150iii", "5150 iii", "evh", "edvaha"], "EVH", 0),
    (["5150", "fifty-one fifty", "6505"], "6505Plus", 0),
    (["rectifier", "trip rect", "dual rect", "recto"], "Rectifier", 0),
    (["soldano", "slo100", "slo-100", "slo 100", " sold "], "SLO100", 0),
    (["bogner", "ecstasy", "engl", "blackmore"], "Bogner", 0),
    (["jvm", "jcm 2210", "2210", "friedman", "be-100", "be100"], "BE101", 0),
    (["orange", "oranje", "rockerverb", "ad30"], "OrangeAD30", 0),
    (["lonestar", "naylor", "super drive"], "OverDrivenLuxVerb", 0),
    (["mesa", "mebo", "boogie", "mark iv", "mark v"], "AmericanHighGain", 0),
    (["dream weaver", "plexi", "jmp", "jtm", "1959", "super lead", "marshall", "mars ", "trainwreck", "bletchley",
      "grandmeister", "hughes"], "Plexi", 4),
    (["dumble", "o+d+s", " ods", "overdrive special", "dream weaver"], "ODS50CN", 0),
    (["matchless", "sc30", "dc30", "divided by 13", "/13", "ldw39", "ftr37", "ert33", "star "], "94MatchDCV2", 0),
    (["ac30", "ac15", "ace thirty", "vox", "voice "], "AC Boost", 0),
    (["twin"], "Twin", 0),
    (["deluxe", " lux ", "princeton", "lil king", " carr ", "headstrong"], "Deluxe65", 0),
    (["bassman", "tweed", "1955 super", "leo fender"], "Bassman", 0),
    (["davoli", "checkmate", "teisco", "silvertone"], "Checkmate", 0),
    (["marshall", "mars ", "jcm"], "Plexi", 0),
    (["am pro", "fender", "fan "], "Twin", 0),
    (["acoustic"], "AcousticAmpV2", 0),
]


def character(gain: float) -> str:
    return "clean" if gain < 3.5 else "crunch" if gain < 6 else "drive"


def amp_for(rig: Rig) -> tuple[str, str]:
    text = f" {rig.amp_description} {rig.name} ".lower()
    gain = rig.gain if rig.gain is not None else 5.0
    for words, model, minimum in AMP_RULES:
        if gain < minimum:
            continue
        for word in words:
            if word in text:
                return model, tr("“{}”", word.strip())
    return {"clean": ("94MatchDCV2", tr("unknown amp, clean")), "crunch": ("Plexi", tr("unknown amp, crunch")),
            "drive": ("SLO100", tr("unknown amp, distorted"))}[character(gain)]


@dataclass
class Translation:
    recipe: dict
    character: str
    amp_model: str
    amp_reason: str
    left_out: list[str]


def _unit_for(module: Module, rig: Rig) -> tuple[str, dict] | None:
    """The Spark place and unit for one Kemper effect, or None when the Spark has nothing like it."""
    page = module.page

    def knob(parameter: int, fallback: float, scale: float = 1, low: float = 0, high: float = 10) -> float:
        value = rig.knob(page, parameter)
        return _tenths(min(max((fallback if value is None else value) * scale, low), high))

    # The Kemper adds a delay or reverb to the dry signal and its mix often stands at the top; the Spark's level is
    # the effect's loudness, so the mix is scaled down and capped.
    wet = knob(4, 5, scale=0.4, low=1, high=4.5)
    kind = module.type
    if kind in (57, 58):
        return "gate", {"model": "bias.noisegate", "settings": {"threshold": knob(18, 4)}}
    if kind == 49:
        return "compressor", {"model": "BlueComp", "settings": {"sustain": knob(18, 5), "level": 5}}
    if kind in (1, 116):
        return "compressor", {"model": "JH.Vox846"}
    if kind == 33:
        return "drive", {"model": "DistortionTS9", "settings": {"drive": knob(16, 4), "tone": knob(17, 5), "level": 6}}
    if kind in (32, 34, 35, 19):
        return "drive", {"model": "Overdrive", "settings": {"drive": knob(16, 4), "tone": knob(17, 5), "level": 6}}
    if kind == 42:
        return "drive", {"model": "KlonCentaurSilver",
                         "settings": {"gain": knob(16, 4), "treble": knob(17, 5), "level": 6}}
    if kind == 36:
        return "drive", {"model": "GuitarMuff"}
    if kind in (37, 39):
        return "drive", {"model": "ProCoRat"}
    if kind in (38, 20, 21):
        return "drive", {"model": "Fuzz"}
    if kind in (113, 114, 115):
        return "drive", {"model": "Booster", "settings": {"gain": knob(6, 6)}}
    if kind in (65, 66, 67):
        return "modulation", {"model": "ChorusAnalog", "settings": {"rate": knob(20, 4), "depth": knob(21, 5)}}
    if kind == 70:
        return "modulation", {"model": "Tremolo", "settings": {"speed": knob(20, 5), "depth": knob(21, 5)}}
    if kind in (81, 83):
        return "modulation", {"model": "Phaser", "settings": {"speed": knob(20, 4), "intensity": knob(21, 5)}}
    if kind in (82, 69):
        return "modulation", {"model": "UniVibe", "settings": {"speed": knob(20, 4), "intensity": knob(21, 5)}}
    if kind in (89, 91):
        return "modulation", {"model": "Flanger",
                              "settings": {"rate": knob(20, 4), "depth": knob(21, 5), "mix": knob(4, 5)}}
    if kind == 68:
        return "modulation", {"model": "Vibrato01", "settings": {"speed": knob(20, 4), "depth": knob(21, 5)}}
    if 145 <= kind <= 166:
        settings = {"effect": wet, "feedback": knob(93, 4), "time": knob(71, 4)}
        if rig.value(page, 80) == 1:
            settings["sync"] = True
        return "delay", {"model": "DelayMono", "settings": settings}
    if 177 <= kind <= 193:
        return "reverb", {"model": "bias.reverb", "settings": {"level": wet, "length": knob(93, 5)}}
    return None


def translate(rig: Rig, name: str | None = None) -> Translation:
    """The nearest Spark sound for a rig: the amp by keywords and gain, the Kemper's gain and equalizer, its effects
    on the Spark's places. The notes say what was matched and left out; every sound wants a listen."""
    cat = catalog.load()
    gain = rig.gain if rig.gain is not None else 5.0
    kind = character(gain)
    amp_model, reason = amp_for(rig)

    def knob(value: float) -> float:
        return _tenths(min(max(value, 0), 10))

    bass, middle, treble, presence = (rig.signed_knob(PAGE_EQ, n) for n in (4, 5, 6, 7))
    # The Spark amps have no presence knob, so half of it goes to the treble.
    chain: dict[str, dict] = {"amp": {"model": amp_model, "settings": {
        "gain": knob(gain), "bass": knob(5 + bass), "middle": knob(5 + middle),
        "treble": knob(5 + treble + presence / 2), "master": 6}}}
    left_out: list[str] = []
    used: list[str] = []

    def spark_name(model: str) -> str:
        info = cat.known(model)
        return info.name if info else model

    # The delay and reverb modules first, so a delay sitting in MOD or X does not push out the real one.
    first = (PAGE_DELAY, PAGE_REVERB)
    ordered = [m for m in rig.modules if m.page in first] + [m for m in rig.modules if m.page not in first]
    for module in ordered:
        if not module.is_on:
            continue
        found = _unit_for(module, rig)
        if found is None:
            left_out.append(module.type_name)
        elif found[0] not in chain:
            chain[found[0]] = found[1]
            used.append(f"{module.type_name} → {spark_name(found[1]['model'])}")
        else:
            left_out.append(tr("{} (place {} already taken)", module.type_name, found[0]))
    old = rig.old_reverb
    if "reverb" not in chain and old and old[0]:
        chain["reverb"] = {"model": "bias.reverb", "settings": {"level": knob(max(old[1] * 1.5, 1.5)),
                                                                   "length": knob(old[2])}}
        used.append(tr("Reverb → Reverb"))

    # Written in the app's language at the time of the import, as on the Mac.
    notes = tr("From the Kemper rig “{}”", rig.name)
    if rig.amp_description:
        notes += tr(", amp {}", rig.amp_description)
    if rig.string(RIG_AUTHOR):
        notes += tr(", profile by {}", rig.string(RIG_AUTHOR))
    notes += ". " + tr("Spark amp {} because of {}. Gain {} as on the Kemper; bass, middle and treble from the Kemper EQ, "
                       "half of the presence in the treble.", spark_name(amp_model), reason, recipe._number_text(gain))
    if used:
        notes += " " + tr("Effects: {}.", ", ".join(used))
    if left_out:
        notes += " " + tr("Not imported: {}.", ", ".join(left_out))
    notes += " " + tr("A profile is a recording of the real amp, the Spark computes with models: listen and adjust "
                      "before you use it.")
    data = {"format": recipe.FORMAT, "version": recipe.VERSION, "name": fit_name(name or rig.name),
            "description": fit_description(rig.amp_description), "bpm": rig.tempo or 120,
            "tags": ["kemper", kind], "notes": notes, "chain": chain}
    return Translation(data, kind, amp_model, reason, left_out)


# MARK: Plan

class _Kinds(dict):
    """(label, tag) by kind. The label reads in the app's language; the tag is stored and stays as it is."""

    def __getitem__(self, key):
        label, tag = super().__getitem__(key)
        return tr(label), tag

    def items(self):
        return [(key, self[key]) for key in self]

    def values(self):
        return [self[key] for key in self]


KINDS = _Kinds({"song": ("Song", "song"), "basis": ("Basic setup", "basis"), "lesson": ("Lessons", "unterricht"),
                "skip": ("Do not import", None)})


def hashtag(title: str) -> str:
    """Words joined without blanks and apostrophes: "Can't Stop" becomes "CantStop"."""
    joined = "".join(c for c in title if c not in "'’`´")
    return "".join(word[:1].upper() + word[1:] for word in re.split(r"[^0-9A-Za-zÀ-ÿ]+", joined) if word)


def guess_kind(name: str) -> str:
    lowered = name.casefold()
    if any(word in lowered for word in ("unterricht", "lesson", "übung", "licks", "schüler", "workshop")):
        return "lesson"
    setups = ("setup", "clean", "crunch", "drive", "ballad", "solo", "lead", "master", "performance", "basis",
              "rock'n'roll", "punk", "jazz", "blues", "funk", "oldschool")
    return "basis" if any(word in lowered for word in setups) else "song"


def sound_name(performance: str, slot: str, single: bool) -> str:
    base, slot = performance.strip(), slot.strip()
    if single or not slot or slot.casefold() == base.casefold():
        return fit_name(base)
    return fit_name(f"{base} · {slot}")


@dataclass
class PlanSlot:
    number: int
    name: str
    translation: Translation


@dataclass
class PlanPerformance:
    number: int
    name: str
    kind: str
    slots: list[PlanSlot]


@dataclass
class PlanRig:
    id: int
    is_chosen: bool
    translation: Translation

    @property
    def name(self) -> str:
        return self.translation.recipe["name"]


@dataclass
class Sound:
    preset: object
    tags: list[str]
    notes: str
    origin: str


@dataclass
class Song:
    title: str
    parts: list[tuple[str, int]]
    notes: str


class Plan:
    """What to make of a Kemper library: per performance a kind, single rigs to choose. Plain data, so the window
    can show and change it before anything is written."""

    def __init__(self, library: Library):
        own = library.own_performances
        self.performances: list[PlanPerformance] = []
        for performance in own:
            # Titles that repeat get the performance's number.
            repeats = sum(1 for p in own if p.name.casefold() == performance.name.casefold()) > 1
            title = f"{performance.name} {performance.number}" if repeats else performance.name
            used = [(index, rig) for index, rig in enumerate(performance.slots) if rig is not None]
            slots = [PlanSlot(index + 1, performance.slot_name(index),
                              translate(rig, sound_name(title, performance.slot_name(index), len(used) == 1)))
                     for index, rig in used]
            if slots:
                self.performances.append(PlanPerformance(performance.number, title, guess_kind(performance.name), slots))
        single = not library.performances
        self.rigs = [PlanRig(index, single, translate(rig)) for index, rig in enumerate(library.rigs)]

    def output(self) -> tuple[list[Sound], list[Song]]:
        """The sounds and songs this plan makes. Slots that end up as the same Spark sound are one preset that
        carries the tags of all of them."""
        sounds: list[Sound] = []
        by_chain: dict[str, int] = {}

        def add(translation: Translation, tags: list[str], origin: str) -> int:
            from .library import normalized_tags
            preset = recipe.to_preset(translation.recipe).preset
            key = fingerprint(preset)
            all_tags = list(translation.recipe["tags"]) + tags
            if key in by_chain:
                sounds[by_chain[key]].tags = normalized_tags(sounds[by_chain[key]].tags + all_tags)
                return by_chain[key]
            sounds.append(Sound(preset, normalized_tags(all_tags), translation.recipe["notes"], origin))
            by_chain[key] = len(sounds) - 1
            return by_chain[key]

        songs: list[Song] = []
        for performance in self.performances:
            if performance.kind == "skip":
                continue
            tags = [KINDS[performance.kind][1], hashtag(performance.name)]
            parts = [(slot.name, add(slot.translation, tags, tr("Kemper · {} · slot {}", performance.name, slot.number)))
                     for slot in performance.slots]
            if performance.kind == "song":
                songs.append(Song(performance.name, parts,
                                  tr("From the Kemper performance {} “{}”.", performance.number, performance.name)))
        for rig in self.rigs:
            if rig.is_chosen:
                add(rig.translation, [], "Kemper · Rig")
        return sounds, songs


def list_file(path: str) -> int:
    """`ampbench --kemper-list <file>`: what an import would make, without writing anything."""
    cat = catalog.load()
    try:
        library = read(Path(path))
        plan = Plan(library)
        print(tr("{} rigs, {} performances, {} of your own", len(library.rigs), len(library.performances),
                 len(plan.performances)))
        for performance in plan.performances:
            print(f"{performance.number}. {performance.name}  [{KINDS[performance.kind][0]}]")
            for slot in performance.slots:
                t = slot.translation
                info = cat.known(t.amp_model)
                left = "  " + tr("without: {}", ", ".join(t.left_out)) if t.left_out else ""
                print(f"   {slot.number} {slot.name} → {info.name if info else t.amp_model} ({t.amp_reason}), "
                      f"{t.character}{left}")
        sounds, songs = plan.output()
        print(tr("Result: {} presets, {} pieces", len(sounds), len(songs)))
        return 0
    except (KemperError, OSError, recipe.RecipeError) as error:
        print(tr("not possible: {}", error))
        return 1
