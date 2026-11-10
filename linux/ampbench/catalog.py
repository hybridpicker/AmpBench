"""The amp and effect models, read from docs/ai/spark-catalog.json.

That file is written by the Mac app (``AmpBench --catalog-export docs/ai``) from its Swift catalog, so both
apps know exactly the same models, parameters and start values.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

from . import i18n
from .protocol import Effect, Parameter

PLACES = ["gate", "compressor", "drive", "amp", "modulation", "delay", "reverb"]
# The newest catalog this app reads. Version 3 is English, with German in parallel "de" objects.
NEWEST_VERSION = 3


class _Titles(dict):
    """(English, German) by key; reading one gives the text in the app's language at that moment."""

    def __getitem__(self, key):
        english, german = super().__getitem__(key)
        return german if i18n.language() == i18n.GERMAN else english

    def get(self, key, default=None):
        return self[key] if key in self else default

    def values(self):
        return [self[key] for key in self]

    def items(self):
        return [(key, self[key]) for key in self]


PLACE_TITLES = _Titles({"gate": ("Noise Gate", "Noise Gate"), "compressor": ("Compressor", "Kompressor"),
                        "drive": ("Drive", "Verzerrer"), "amp": ("Amp", "Amp"),
                        "modulation": ("Modulation", "Modulation"), "delay": ("Delay", "Delay"),
                        "reverb": ("Reverb", "Hall")})
PLACE_SHORT = _Titles({"gate": ("Gate", "Gate"), "compressor": ("Comp", "Komp"), "drive": ("Drive", "Drive"),
                       "amp": ("Amp", "Amp"), "modulation": ("Mod", "Mod"), "delay": ("Delay", "Delay"),
                       "reverb": ("Reverb", "Hall")})
# The same colors as the Mac app's chain strip.
PLACE_COLORS = {"gate": (0.55, 0.66, 0.70), "compressor": (0.36, 0.62, 0.92), "drive": (0.98, 0.55, 0.20),
                "amp": (0.98, 0.76, 0.36), "modulation": (0.70, 0.52, 0.95), "delay": (0.30, 0.80, 0.66),
                "reverb": (0.55, 0.80, 0.98)}


def _german() -> bool:
    return i18n.language() == i18n.GERMAN


@dataclass
class ParameterInfo:
    """One parameter. The `english_…` fields are what recipes write; `label`, `off`, `on` and `options` are in the
    app's language."""
    index: int
    key: str
    english_label: str
    kind: str  # knob, switch, choice, mirror, reserved
    english_off: str = ""
    english_on: str = ""
    english_options: list[tuple[str, float]] = field(default_factory=list)  # label, amp value 0 to 1
    german_label: str | None = None
    german_off: str | None = None
    german_on: str | None = None
    german_options: list[str] | None = None  # the labels, in the order of english_options

    @property
    def label(self) -> str:
        return self.german_label if _german() and self.german_label else self.english_label

    @property
    def off(self) -> str:
        return self.german_off if _german() and self.german_off else self.english_off

    @property
    def on(self) -> str:
        return self.german_on if _german() and self.german_on else self.english_on

    @property
    def options(self) -> list[tuple[str, float]]:
        if _german() and self.german_options and len(self.german_options) == len(self.english_options):
            return [(label, value) for label, (_, value) in zip(self.german_options, self.english_options)]
        return self.english_options

    @property
    def visible(self) -> bool:
        return self.kind in ("knob", "switch", "choice")

    def _option(self, value: float) -> int:
        return min(range(len(self.english_options)), key=lambda i: abs(self.english_options[i][1] - value))

    def display(self, value: float) -> str:
        """The value as the window shows it, in the app's language."""
        if self.kind == "switch":
            return self.on if value >= 0.5 else self.off
        if self.kind == "choice" and self.english_options:
            return self.options[self._option(value)][0]
        return i18n.number(value * 10, 1)

    def english_display(self, value: float) -> str:
        """The value as a recipe writes it: English labels, a decimal point."""
        if self.kind == "switch":
            return self.english_on if value >= 0.5 else self.english_off
        if self.kind == "choice" and self.english_options:
            return self.english_options[self._option(value)][0]
        return f"{value * 10:.1f}"

    def names(self, text: str, english: str) -> bool:
        """Whether `text` names the switch position or option `english`, by its English or German label."""
        folded = text.casefold()
        if folded == english.casefold():
            return True
        if english == self.english_on and self.german_on and folded == self.german_on.casefold():
            return True
        if english == self.english_off and self.german_off and folded == self.german_off.casefold():
            return True
        if self.german_options and len(self.german_options) == len(self.english_options):
            return any(e == english and folded == g.casefold()
                       for (e, _), g in zip(self.english_options, self.german_options))
        return False


def _numbered(index: int) -> ParameterInfo:
    """A knob the catalog has no name for."""
    return ParameterInfo(index, f"knob{index + 1}", f"Knob {index + 1}", "knob",
                         german_label=(i18n.german("Knob {}") or "Knob {}").format(index + 1))


@dataclass
class ModelInfo:
    """One model. `name` and `summary` are in the app's language, `english_name` is what stays the same."""
    id: str
    place: str
    english_name: str
    english_summary: str
    inspiration: str | None
    group: str | None
    pack: bool
    checked: bool
    parameter_count: int
    defaults: list[float]
    parameters: list[ParameterInfo]  # settable ones, indexes may skip hidden parameters
    mirrors: list[int]
    german_name: str | None = None
    german_summary: str | None = None

    @property
    def name(self) -> str:
        return self.german_name if _german() and self.german_name else self.english_name

    @property
    def summary(self) -> str:
        return self.german_summary if _german() and self.german_summary else self.english_summary

    def parameter(self, index: int) -> ParameterInfo:
        for parameter in self.parameters:
            if parameter.index == index:
                return parameter
        kind = "mirror" if index in self.mirrors else "reserved" if index < self.parameter_count else "knob"
        if kind == "mirror":
            return ParameterInfo(index, f"knob{index + 1}", "On/Off", kind, german_label=i18n.german("On/Off"))
        numbered = _numbered(index)
        numbered.kind = kind
        return numbered


def _find_catalog() -> Path:
    here = Path(__file__).resolve().parent
    for candidate in (here / "data" / "spark-catalog.json",
                      here.parent.parent / "docs" / "ai" / "spark-catalog.json"):
        if candidate.is_file():
            return candidate
    raise FileNotFoundError("spark-catalog.json not found")


@lru_cache(maxsize=1)
def load() -> "Catalog":
    return Catalog(json.loads(_find_catalog().read_text(encoding="utf-8")))


class Catalog:
    def __init__(self, data: dict):
        self.version = int(data.get("version", 1))
        if self.version > NEWEST_VERSION:
            raise ValueError(f"spark-catalog.json has version {self.version}, this app reads up to {NEWEST_VERSION}")
        # Up to version 2 the catalog's texts were German and there was no "de"; they are then shown as they are.
        self.groups: dict[str, tuple[str, str | None]] = {
            g["key"]: (g["title"], (g.get("de") or {}).get("title")) for g in data.get("groups", [])}
        self.place_titles: dict[str, tuple[str, str | None]] = {
            p["key"]: (p["title"], (p.get("de") or {}).get("title")) for p in data.get("places", []) if "title" in p}
        checked = data.get("checkedOn", "")
        # Since catalog version 2 a list of devices, each with firmware and what was checked there.
        if isinstance(checked, list):
            checked = "; ".join(f"{c['device']}, firmware {c['firmware']}" for c in checked)
        self.checked_on = checked
        self.models: dict[str, ModelInfo] = {}
        self.by_place: dict[str, list[ModelInfo]] = {place: [] for place in PLACES}
        for entry in data["models"]:
            parameters = []
            for p in entry["parameters"]:
                kind = {"knob": "knob", "switch": "switch", "choice": "choice"}[p["kind"]]
                options = [(o["label"], round(o["value"] / 10, 4)) for o in p.get("options", [])]
                de = p.get("de") or {}
                german_options = [(o.get("de") or {}).get("label") or o["label"] for o in p.get("options", [])]
                parameters.append(ParameterInfo(p["index"], p["key"], p["label"], kind, p.get("off") or "",
                                                p.get("on") or "", options, de.get("label"), de.get("off"),
                                                de.get("on"), german_options or None))
            de = entry.get("de") or {}
            model = ModelInfo(entry["id"], entry["place"], entry["name"], entry["summary"], entry.get("inspiration"),
                              entry.get("group"), entry["pack"], entry["checkedOnAmp"], entry["parameterCount"],
                              [float(v) for v in entry["defaults"]], parameters, entry["mirrors"],
                              de.get("name"), de.get("summary"))
            self.models[model.id] = model
            self.by_place[model.place].append(model)

    def known(self, model_id: str) -> ModelInfo | None:
        return self.models.get(model_id)

    def info(self, model_id: str, parameter_count: int = 0) -> ModelInfo:
        known = self.models.get(model_id)
        if known:
            return known
        return ModelInfo(model_id, "modulation", model_id, "Unknown model", None, None, False, False,
                         parameter_count, [], [_numbered(i) for i in range(parameter_count)], [],
                         german_summary=i18n.german("Unknown model"))

    def group_title(self, key: str | None) -> str:
        """An amp group's title ("clean" → "Clean", "bright" → "Brillant" in German); the key when unknown."""
        english, german = self.groups.get(key or "", (key or "", None))
        return german if _german() and german else english

    def place_title(self, key: str) -> str:
        """A place's title in the app's language, from the catalog when it has one."""
        english, german = self.place_titles.get(key, (None, None))
        if english is None or german is None:
            return PLACE_TITLES.get(key, english or key)
        return german if _german() else english

    def models_for(self, place: str, include_packs: bool = False) -> list[ModelInfo]:
        return [m for m in self.by_place[place] if include_packs or not m.pack]

    def make_effect(self, model_id: str, on: bool, changes: dict[int, float] | None = None) -> Effect:
        """An effect with the catalog's start values, its mirror parameter in step with ``on``."""
        info = self.info(model_id)
        count = info.parameter_count or len(info.parameters)
        values = list(info.defaults) if info.defaults else [0.5] * count
        for index, value in (changes or {}).items():
            if 0 <= index < len(values):
                values[index] = value
        for index in info.mirrors:
            if index < len(values):
                values[index] = 1.0 if on else 0.0
        return Effect(model_id, on, [Parameter(i, _f32(v)) for i, v in enumerate(values)])


def _f32(value: float) -> float:
    from .protocol import f32
    return f32(value)
