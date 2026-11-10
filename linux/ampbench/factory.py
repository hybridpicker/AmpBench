"""New presets: empty, from a template, or as a copy. A port of PresetFactory."""
from __future__ import annotations

import uuid as uuidlib
from dataclasses import dataclass

from . import catalog
from .i18n import tr
from .protocol import Preset, fit_name


@dataclass
class Template:
    name: str
    summary: str
    preset: Preset


def _e(model: str, on: bool, changes: dict[int, float] | None = None):
    return catalog.load().make_effect(model, on, changes)


def empty(name: str | None = None) -> Preset:
    return Preset(name=name or tr("New preset"), effects=[
        _e("bias.noisegate", False), _e("BlueComp", False), _e("DistortionTS9", False), _e("Twin", True),
        _e("ChorusAnalog", False), _e("DelayMono", False), _e("bias.reverb", False)])


def templates() -> list[Template]:
    return [
        Template("Clean", tr("Clear amp, a little compression and a small room"), Preset(name="Clean", bpm=100, effects=[
            _e("bias.noisegate", False), _e("BlueComp", True), _e("DistortionTS9", False), _e("Twin", True, {0: 0.4}),
            _e("ChorusAnalog", False), _e("DelayMono", False), _e("bias.reverb", True, {0: 0.25, 6: 0})])),
        Template("Crunch", tr("British crunch, pushed by the overdrive"), Preset(name="Crunch", bpm=120, effects=[
            _e("bias.noisegate", True, {0: 0.15}), _e("Compressor", False),
            _e("DistortionTS9", True, {0: 0.35, 2: 0.6}), _e("Plexi", True), _e("ChorusAnalog", False),
            _e("DelayMono", False), _e("bias.reverb", True, {0: 0.2, 6: 0.2})])),
        Template("Lead", tr("Singing high gain with echo for solos"), Preset(name="Lead", bpm=120, effects=[
            _e("bias.noisegate", True, {0: 0.25}), _e("Compressor", False), _e("Booster", True, {0: 0.6}),
            _e("SLO100", True), _e("ChorusAnalog", False), _e("DelayMono", True, {0: 0.3, 4: 1}),
            _e("bias.reverb", True, {0: 0.25, 6: 0.4})])),
        Template("Ambient", tr("Wide clean with chorus, long echo and lots of reverb"), Preset(name="Ambient", bpm=80,
                                                                                         effects=[
            _e("bias.noisegate", False), _e("BBEOpticalComp", True), _e("DistortionTS9", False),
            _e("94MatchDCV2", True, {0: 0.35}), _e("ChorusAnalog", True, {0: 0.5}),
            _e("DelayRe201", True, {0: 0.6, 4: 1}), _e("bias.reverb", True, {0: 0.55, 5: 0.85, 6: 0.5})])),
        Template("Funk", tr("Dry, snappy clean with lots of compression"), Preset(name="Funk", bpm=105, effects=[
            _e("bias.noisegate", True, {0: 0.1}), _e("LA2AComp", True), _e("DistortionTS9", False),
            _e("RolandJC120", True, {0: 0.35, 2: 0.6}), _e("Phaser", False), _e("DelayMono", False),
            _e("bias.reverb", True, {0: 0.12, 6: 0})])),
    ]


def duplicate(preset: Preset, name: str | None = None) -> Preset:
    copy = preset.copy()
    copy.uuid = str(uuidlib.uuid4()).upper()
    copy.name = fit_name(name or tr("{} copy", preset.name))
    return copy


def make(template: Template, name: str | None = None) -> Preset:
    return duplicate(template.preset, name or template.name)
