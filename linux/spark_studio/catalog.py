"""The amp and effect models, read from docs/ai/spark-catalog.json.

That file is written by the Mac app (``SparkStudio --catalog-export docs/ai``) from its Swift catalog, so both
apps know exactly the same models, parameters and start values.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

from .protocol import Effect, Parameter

PLACES = ["gate", "compressor", "drive", "amp", "modulation", "delay", "reverb"]
PLACE_TITLES = {"gate": "Noise Gate", "compressor": "Kompressor", "drive": "Verzerrer", "amp": "Amp",
                "modulation": "Modulation", "delay": "Delay", "reverb": "Hall"}
PLACE_SHORT = {"gate": "Gate", "compressor": "Komp", "drive": "Drive", "amp": "Amp", "modulation": "Mod",
               "delay": "Delay", "reverb": "Hall"}
# The same colors as the Mac app's chain strip.
PLACE_COLORS = {"gate": (0.55, 0.66, 0.70), "compressor": (0.36, 0.62, 0.92), "drive": (0.98, 0.55, 0.20),
                "amp": (0.98, 0.76, 0.36), "modulation": (0.70, 0.52, 0.95), "delay": (0.30, 0.80, 0.66),
                "reverb": (0.55, 0.80, 0.98)}


@dataclass
class ParameterInfo:
    index: int
    key: str
    label: str
    kind: str  # knob, switch, choice, mirror, reserved
    off: str = ""
    on: str = ""
    options: list[tuple[str, float]] = field(default_factory=list)  # label, amp value 0 to 1

    @property
    def visible(self) -> bool:
        return self.kind in ("knob", "switch", "choice")

    def display(self, value: float) -> str:
        if self.kind == "switch":
            return self.on if value >= 0.5 else self.off
        if self.kind == "choice" and self.options:
            return min(self.options, key=lambda option: abs(option[1] - value))[0]
        return f"{value * 10:.1f}".replace(".", ",")


@dataclass
class ModelInfo:
    id: str
    place: str
    name: str
    summary: str
    inspiration: str | None
    group: str | None
    pack: bool
    checked: bool
    parameter_count: int
    defaults: list[float]
    parameters: list[ParameterInfo]  # settable ones, indexes may skip hidden parameters
    mirrors: list[int]

    def parameter(self, index: int) -> ParameterInfo:
        for parameter in self.parameters:
            if parameter.index == index:
                return parameter
        kind = "mirror" if index in self.mirrors else "reserved" if index < self.parameter_count else "knob"
        return ParameterInfo(index, f"knob{index + 1}", "An/Aus" if kind == "mirror" else f"Regler {index + 1}", kind)


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
                parameters.append(ParameterInfo(p["index"], p["key"], p["label"], kind, p.get("off") or "",
                                                p.get("on") or "", options))
            model = ModelInfo(entry["id"], entry["place"], entry["name"], entry["summary"], entry.get("inspiration"),
                              entry.get("group"), entry["pack"], entry["checkedOnAmp"], entry["parameterCount"],
                              [float(v) for v in entry["defaults"]], parameters, entry["mirrors"])
            self.models[model.id] = model
            self.by_place[model.place].append(model)

    def known(self, model_id: str) -> ModelInfo | None:
        return self.models.get(model_id)

    def info(self, model_id: str, parameter_count: int = 0) -> ModelInfo:
        known = self.models.get(model_id)
        if known:
            return known
        return ModelInfo(model_id, "modulation", model_id, "Unbekanntes Modell", None, None, False, False,
                         parameter_count, [], [ParameterInfo(i, f"knob{i + 1}", f"Regler {i + 1}", "knob")
                                               for i in range(parameter_count)], [])

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
