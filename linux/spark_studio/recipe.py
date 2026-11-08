"""Sound recipes: a sound described by model and settings, as written by people and AI assistants.

A port of SoundRecipe.swift (see docs/ai/SOUND-GUIDE.md). Knobs go from 0 to 10, a place left out is switched off.
"""
from __future__ import annotations

import hashlib
import json
import uuid as uuidlib
from dataclasses import dataclass, field

from . import catalog, factory
from .protocol import BPM_RANGE, NAME_LIMIT, Preset, f32, fit_name

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
            raise ValueError("Ein Regler braucht eine Zahl von 0 bis 10.")
        clamped = min(max(float(value), 0.0), 10.0)
        note = None if clamped == value else f"{value:g} liegt außerhalb von 0–10, gesetzt auf {clamped:g}."
        return round(clamped / 10, 6), note
    if info.kind == "switch":
        if isinstance(value, bool):
            return (1.0 if value else 0.0), None
        if isinstance(value, str):
            if value.casefold() == info.on.casefold():
                return 1.0, None
            if value.casefold() == info.off.casefold():
                return 0.0, None
            raise ValueError(f"Ein Schalter braucht true, false, „{info.off}“ oder „{info.on}“.")
        raise ValueError("Ein Schalter braucht true oder false.")
    if info.kind == "choice":
        if not isinstance(value, str):
            raise ValueError("Eine Auswahl braucht einen der Namen aus dem Katalog.")
        for label, amp in info.options:
            if label.casefold() == value.casefold():
                return amp, None
        raise ValueError(f"„{value}“ ist keine Auswahl. Erlaubt: " + ", ".join(f"„{l}“" for l, _ in info.options) + ".")
    raise ValueError("Dieser Parameter wird nicht gesetzt.")


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
        raise RecipeError([f"format ist nicht {FORMAT}."])
    if int(data.get("version", 1)) > VERSION:
        warnings.append(f"Das Rezept hat Version {data['version']}, Spark Studio kennt bis {VERSION}.")
    name = str(data.get("name", "")).strip()
    if not name:
        problems.append("Der Name fehlt.")
    fitted = fit_name(name)
    if fitted != name:
        warnings.append(f"Der Name war länger als {NAME_LIMIT} Bytes und wurde auf „{fitted}“ gekürzt.")
    chain = data.get("chain", {}) or {}
    for key in chain:
        if key not in catalog.PLACES:
            problems.append(f"„{key}“ ist kein Platz der Kette. Erlaubt: {', '.join(catalog.PLACES)}.")

    effects = []
    for place in catalog.PLACES:
        unit = chain.get(place)
        if unit is None:
            effects.append(cat.make_effect(FALLBACKS[place], False))
            continue
        model = str(unit.get("model", ""))
        info = cat.known(model)
        if info is None:
            problems.append(f"{place}: Das Modell „{model}“ gibt es nicht. Die Modell-ids stehen in "
                            "docs/ai/spark-catalog.json, Groß- und Kleinschreibung zählen.")
            continue
        if info.place != place:
            problems.append(f"{place}: „{model}“ gehört an den Platz {info.place}.")
            continue
        if info.pack:
            warnings.append(f"{place}: „{model}“ gehört zu einem Zusatzpaket. Ohne das Paket nimmt der Verstärker es nicht.")
        changes: dict[int, float] = {}
        settings = unit.get("settings", {}) or {}
        for key in sorted(settings):
            parameter = next((p for p in info.parameters if p.key == key), None)
            if parameter is None:
                problems.append(f"{place} {model}: „{key}“ gibt es nicht. Erlaubt: "
                                + ", ".join(p.key for p in info.parameters) + ".")
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
        warnings.append(f"Das Tempo {bpm:g} liegt außerhalb von {int(BPM_RANGE[0])}–{int(BPM_RANGE[1])} und wurde angepasst.")
    preset = Preset(name=fitted, effects=effects, uuid=stable_uuid(identity), description=str(data.get("description", "")),
                    bpm=f32(clamped))
    return Conversion(preset, warnings, list(data.get("tags", [])), str(data.get("notes", "")))


def from_preset(preset: Preset, tags: list[str] | None = None, notes: str = "") -> dict:
    """A preset described as a recipe. Every setting is written out."""
    cat = catalog.load()
    if len(preset.effects) != len(catalog.PLACES):
        raise RecipeError([f"Das Preset hat {len(preset.effects)} statt 7 Plätze."])
    chain, problems = {}, []
    for place, effect in zip(catalog.PLACES, preset.effects):
        info = cat.known(effect.name)
        if info is None:
            problems.append(f"{place}: Das Modell „{effect.name}“ kennt der Katalog nicht.")
            continue
        settings = {}
        for parameter in info.parameters:
            value = next((p.value for p in effect.parameters if p.index == parameter.index), None)
            if value is None:
                continue
            if parameter.kind == "switch":
                settings[parameter.key] = parameter.on if value >= 0.5 else parameter.off
            elif parameter.kind == "choice":
                settings[parameter.key] = parameter.display(value)
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
        print(f"{path}: nicht in Ordnung")
        for message in (error.messages if isinstance(error, RecipeError) else [str(error)]):
            print(f"  - {message}")
        return 1
    print(f"{path}: in Ordnung. „{conversion.preset.name}“")
    for warning in conversion.warnings:
        print(f"  Hinweis: {warning}")
    return 0
