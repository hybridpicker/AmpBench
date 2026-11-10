"""Sound recipes: a sound described by model and settings, as written by people and AI assistants.

A port of SoundRecipe.swift (see docs/ai/SOUND-GUIDE.md). Knobs go from 0 to 10, a place left out is switched off.
"""
from __future__ import annotations

import hashlib
import json
import uuid as uuidlib
from dataclasses import dataclass, field

from . import catalog, factory
from .i18n import tr
from .protocol import BPM_RANGE, DESCRIPTION_LIMIT, NAME_LIMIT, Preset, f32, fit_description, fit_name

FORMAT = "spark-sound-recipe"
VERSION = 1
FALLBACKS = {"gate": "bias.noisegate", "compressor": "BlueComp", "drive": "DistortionTS9", "amp": "Twin",
             "modulation": "ChorusAnalog", "delay": "DelayMono", "reverb": "bias.reverb"}


class RecipeError(Exception):
    def __init__(self, messages: list[str]):
        super().__init__("\n".join(messages))
        self.messages = messages


@dataclass
class Conversion:
    preset: Preset
    warnings: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)
    notes: str = ""


def is_recipe(data: object) -> bool:
    return isinstance(data, dict) and data.get("format") == FORMAT


def _amp_value(value, info: catalog.ParameterInfo):
    """(amp value 0 to 1, note) or raises ValueError with the problem."""
    if info.kind == "knob":
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(tr("A knob needs a number from 0 to 10."))
        clamped = min(max(float(value), 0.0), 10.0)
        note = None if clamped == value else tr("{} is outside 0–10, set to {}.", f"{value:g}", f"{clamped:g}")
        return round(clamped / 10, 6), note
    if info.kind == "switch":
        if isinstance(value, bool):
            return (1.0 if value else 0.0), None
        if isinstance(value, str):
            # The English or the German label, so recipes written before the catalog was English still read.
            if info.names(value, info.english_on):
                return 1.0, None
            if info.names(value, info.english_off):
                return 0.0, None
            raise ValueError(tr("A switch needs true, false, “{}” or “{}”.", info.english_off, info.english_on))
        raise ValueError(tr("A switch needs true or false."))
    if info.kind == "choice":
        if not isinstance(value, str):
            raise ValueError(tr("A choice needs one of the names from the catalog."))
        for label, amp in info.english_options:
            if info.names(value, label):
                return amp, None
        raise ValueError(tr("“{}” is no choice. Allowed: {}.", value,
                            ", ".join(tr("“{}”", label) for label, _ in info.english_options)))
    raise ValueError(tr("This parameter is not set."))


def stable_uuid(identity: bytes | None) -> str:
    if identity is None:
        return str(uuidlib.uuid4()).upper()
    raw = bytearray(hashlib.sha256(identity).digest()[:16])
    raw[6] = (raw[6] & 0x0F) | 0x50
    raw[8] = (raw[8] & 0x3F) | 0x80
    return str(uuidlib.UUID(bytes=bytes(raw))).upper()


def to_preset(data: dict, identity: bytes | None = None) -> Conversion:
    """The preset for the amp. Raises RecipeError with every problem at once; small things are corrected and
    listed in the warnings."""
    cat = catalog.load()
    problems: list[str] = []
    warnings: list[str] = []
    if data.get("format") != FORMAT:
        raise RecipeError([tr("format is not {}.", FORMAT)])
    if int(data.get("version", 1)) > VERSION:
        warnings.append(tr("The recipe has version {}, AmpBench knows up to {}.", data["version"], VERSION))
    name = str(data.get("name", "")).strip()
    if not name:
        problems.append(tr("The name is missing."))
    fitted = fit_name(name)
    if fitted != name:
        warnings.append(tr("The name was longer than {} bytes and was shortened to “{}”.", NAME_LIMIT, fitted))
    chain = data.get("chain", {}) or {}
    for key in chain:
        if key not in catalog.PLACES:
            problems.append(tr("“{}” is no place of the chain. Allowed: {}.", key, ", ".join(catalog.PLACES)))

    effects = []
    for place in catalog.PLACES:
        unit = chain.get(place)
        if unit is None:
            effects.append(cat.make_effect(FALLBACKS[place], False))
            continue
        model = str(unit.get("model", ""))
        info = cat.known(model)
        if info is None:
            problems.append(tr("{}: There is no model “{}”. The model ids are in docs/ai/spark-catalog.json; upper "
                               "and lower case matter.", place, model))
            continue
        if info.place != place:
            problems.append(tr("{}: “{}” belongs in the place {}.", place, model, info.place))
            continue
        if info.pack:
            warnings.append(tr("{}: “{}” belongs to a paid add-on. Without the add-on the amp does not take it.", place, model))
        changes: dict[int, float] = {}
        settings = unit.get("settings", {}) or {}
        for key in sorted(settings):
            parameter = next((p for p in info.parameters if p.key == key), None)
            if parameter is None:
                problems.append(tr("{} {}: There is no “{}”. Allowed: {}.", place, model, key,
                                   ", ".join(p.key for p in info.parameters)))
                continue
            try:
                amp, note = _amp_value(settings[key], parameter)
            except ValueError as error:
                problems.append(f"{place} {model} {key}: {error}")
                continue
            changes[parameter.index] = amp
            if note:
                warnings.append(f"{place} {model} {key}: {note}")
        effects.append(cat.make_effect(model, bool(unit.get("on", True)), changes))
    if problems:
        raise RecipeError(problems)

    bpm = float(data.get("bpm", 120))
    rounded = float(round(bpm))
    clamped = min(max(rounded, BPM_RANGE[0]), BPM_RANGE[1])
    if clamped != rounded:
        warnings.append(tr("The tempo {} is outside {}–{} and was adjusted.", f"{bpm:g}", int(BPM_RANGE[0]), int(BPM_RANGE[1])))
    description = str(data.get("description", ""))
    short = fit_description(description)
    if short != description:
        warnings.append(tr("The description was longer than {} bytes and was shortened.", DESCRIPTION_LIMIT))
    preset = Preset(name=fitted, effects=effects, uuid=stable_uuid(identity), description=short,
                    bpm=f32(clamped))
    return Conversion(preset, warnings, list(data.get("tags", [])), str(data.get("notes", "")))


def from_preset(preset: Preset, tags: list[str] | None = None, notes: str = "") -> dict:
    """A preset described as a recipe. Every setting is written out; switches and choices by their English label,
    whatever language the app shows."""
    cat = catalog.load()
    if len(preset.effects) != len(catalog.PLACES):
        raise RecipeError([tr("The preset has {} places instead of 7.", len(preset.effects))])
    chain, problems = {}, []
    for place, effect in zip(catalog.PLACES, preset.effects):
        info = cat.known(effect.name)
        if info is None:
            problems.append(tr("{}: The catalog does not know the model “{}”.", place, effect.name))
            continue
        settings = {}
        for parameter in info.parameters:
            value = next((p.value for p in effect.parameters if p.index == parameter.index), None)
            if value is None:
                continue
            if parameter.kind in ("switch", "choice"):
                settings[parameter.key] = parameter.english_display(value)
            else:
                settings[parameter.key] = round(value * 100) / 10
        chain[place] = {"model": effect.name, "on": effect.is_on, "settings": settings}
    if problems:
        raise RecipeError(problems)
    return {"format": FORMAT, "version": VERSION, "name": preset.name, "description": preset.description,
            "bpm": preset.bpm, "tags": tags or [], "notes": notes, "chain": chain}


def check_file(path: str) -> int:
    """``--recipe-check``: prints what is wrong with a recipe. Returns the exit status."""
    raw = open(path, "rb").read()
    try:
        conversion = to_preset(json.loads(raw), raw)
    except (RecipeError, json.JSONDecodeError) as error:
        print(tr("{}: not readable", path))
        for message in (error.messages if isinstance(error, RecipeError) else [str(error)]):
            print("  " + tr("Error: {}", message))
        return 1
    print(tr("{}: ok, “{}”", path, conversion.preset.name))
    for warning in conversion.warnings:
        print("  " + tr("Note: {}", warning))
    return 0


# MARK: Text for REACTOR's Text to Tone (a port of ToneDescription.swift; keep both the same)

_ROLES = {"gate": "Noise gate", "compressor": "Compressor", "drive": "Drive pedal", "amp": "Amp",
          "modulation": "Modulation", "delay": "Delay", "reverb": "Reverb"}
_PLAIN_NAMES = {
    "bias.noisegate": "noise gate", "BassComp": "bass compressor", "Booster": "clean boost",
    "Overdrive": "classic overdrive", "SABdriver": "amp-in-a-box overdrive", "Acoustic": "neutral acoustic simulation",
    "FatAcousticV2": "full jumbo acoustic simulation", "FlatAcoustic": "flat acoustic simulation",
    "Tremolo": "vintage amp tremolo", "ChorusAnalog": "analog chorus", "Flanger": "flanger",
    "Vibrato01": "pitch vibrato", "Tremolator": "tempo-synced tremolo", "TremoloSquare": "square-wave tremolo",
    "GuitarEQ6": "6-band graphic EQ", "BassEQ6": "6-band bass EQ", "DelayEchoFilt": "filtered echo",
    "VintageDelay": "analog bucket-brigade delay", "DelayReverse": "reverse delay",
    "DelayMultiHead": "multi-head tape echo", "bias.reverb": "reverb",
}
_LABELS = {
    "Room A": "small room", "Room B": "room", "Chamber": "chamber", "Natural hall": "natural hall",
    "Medium hall": "medium hall", "Wide hall": "large hall", "Short plate": "short plate",
    "Rich plate": "rich plate", "Long plate": "long plate", "Free": "free time", "BPM": "synced to tempo",
    "Comp.": "compress", "Limit": "limit", "Low": "low", "High": "high", "1 bar": "1 bar",
    "Off": "off", "On": "on",
}


def _number_text(value: float) -> str:
    return str(int(value)) if value == int(value) else f"{value:g}"


def _spoken(key: str) -> str:
    """"lowCut" → "low cut", "hz1600" → "1.6 kHz", "knob3" → "knob 3"."""
    if key.startswith("hz") and key[2:].isdigit():
        hertz = int(key[2:])
        return f"{_number_text(hertz / 1000)} kHz" if hertz >= 1000 else f"{hertz} Hz"
    if key.startswith("knob") and key[4:].isdigit():
        return f"knob {int(key[4:])}"
    if key == "effect":
        return "level"
    return "".join(" " + ch.lower() if ch.isupper() else ch for ch in key)


def _english_name(info) -> str:
    if info.id in _PLAIN_NAMES:
        return _PLAIN_NAMES[info.id]
    if not info.inspiration:
        return info.english_name
    kind = {"amp": "amp", "drive": "pedal", "compressor": "compressor"}.get(info.place, "")
    return f"{info.inspiration} style {kind}" if kind else f"{info.inspiration} style"


def _words(parameter, value: float) -> str:
    if parameter.kind in ("switch", "choice"):
        label = parameter.english_display(value)
        english = _LABELS.get(label, label)
        return english if parameter.key == "sync" else f"{_spoken(parameter.key)} {english}"
    return f"{_spoken(parameter.key)} {_number_text(round(value * 100) / 10)}/10"


def tone_description(data: dict) -> str:
    """A recipe as plain English for REACTOR's "Text to Tone". Models are named after what they are modeled after,
    values on the 0 to 10 scale. A description to start from: the REACTOR picks its own models."""
    conversion = to_preset(data)
    preset = conversion.preset
    cat = catalog.load()
    head = ": ".join(t for t in (data.get("name", ""), data.get("description", "")) if t)
    lines = [f"Guitar tone “{head}”, {int(preset.bpm)} BPM."]
    chain = data.get("chain", {})
    for place, effect in zip(catalog.PLACES, preset.effects):
        if not effect.is_on:
            continue
        info = cat.known(effect.name)
        if info is None:
            continue
        settings = (chain.get(place) or {}).get("settings") or {}
        values = []
        for parameter in info.parameters:
            if not parameter.visible or parameter.key == "type":
                continue
            if place != "amp" and parameter.key not in settings:
                continue
            value = next((p.value for p in effect.parameters if p.index == parameter.index), None)
            if value is not None:
                values.append(_words(parameter, value))
        what = _english_name(info)
        kind = next((p for p in info.parameters if p.visible and p.key == "type"), None)
        if kind is not None:
            value = next((p.value for p in effect.parameters if p.index == kind.index), None)
            if value is not None:
                label = kind.english_display(value)
                what = f"{_LABELS.get(label, label)} reverb"
        lines.append(f"{_ROLES[place]}: {what}" + (", " + ", ".join(values) if values else "") + ".")
    if len(lines) == 1:
        lines.append("Everything off.")
    notes = str(data.get("notes", ""))
    if notes:
        lines.append(f"Notes: {notes}")
    return "\n".join(lines) + "\n"
