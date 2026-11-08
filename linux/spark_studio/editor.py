"""Edits a preset: every change returns what to send to the amp, with undo and redo. A port of PresetEditor,
LiveChange and LiveQueue."""
from __future__ import annotations

import time
from dataclasses import dataclass

from . import catalog
from .protocol import BPM_RANGE, Parameter, Preset, f32

PARAMETER_GAP = 0.04
MODEL_GAP = 1.0
MODEL_BURST = 6
MODEL_WINDOW = 20.0
HISTORY_LIMIT = 200


@dataclass(frozen=True)
class Change:
    kind: str  # parameter, toggle, model, whole
    effect: str = ""
    index: int = 0
    value: float = 0.0
    is_on: bool = False
    old: str = ""
    new: str = ""
    preset: Preset | None = None


def between(old: Preset, new: Preset) -> list[Change]:
    """The changes that turn one preset into another, in an order the amp can follow."""
    if len(old.effects) != len(new.effects) or old.bpm != new.bpm:
        return [Change("whole", preset=new.copy())]
    changes = []
    for a, b in zip(old.effects, new.effects):
        model_changed = a.name != b.name
        if model_changed:
            changes.append(Change("model", old=a.name, new=b.name))
        before = {p.index: p.value for p in a.parameters}
        for p in b.parameters:
            if model_changed or before.get(p.index) != p.value:
                changes.append(Change("parameter", effect=b.name, index=p.index, value=p.value))
        if model_changed or a.is_on != b.is_on:
            changes.append(Change("toggle", effect=b.name, is_on=b.is_on))
    return changes


class LiveQueue:
    """Changes waiting to go to the amp, one at a time. Only the newest value of a parameter is kept."""

    def __init__(self):
        self.items: list[Change] = []

    def __bool__(self) -> bool:
        return bool(self.items)

    def push(self, changes) -> None:
        for change in changes:
            self._push(change)

    def _push(self, change: Change) -> None:
        if change.kind == "whole":
            self.items = [change]
            return
        if change.kind in ("parameter", "toggle"):
            slot = self._replaceable(lambda c: c.kind == change.kind and c.effect == change.effect
                                     and (change.kind == "toggle" or c.index == change.index))
            if slot is not None:
                self.items[slot] = change
                return
        self.items.append(change)

    def _replaceable(self, matches):
        for index in range(len(self.items) - 1, -1, -1):
            if matches(self.items[index]):
                return index
            if self.items[index].kind in ("model", "whole"):
                return None
        return None

    def next(self) -> Change | None:
        return self.items.pop(0) if self.items else None

    def clear(self) -> None:
        self.items.clear()


def wait_before(change: Change, now: float, recent_model_changes: list[float]) -> float:
    """How long to wait before sending ``change``, given when the recent model changes went out."""
    if change.kind != "model":
        return 0.0
    wait = 0.0
    if recent_model_changes:
        wait = max(wait, recent_model_changes[-1] + MODEL_GAP - now)
    window = [t for t in recent_model_changes if now - t < MODEL_WINDOW]
    if len(window) >= MODEL_BURST:
        wait = max(wait, window[0] + MODEL_WINDOW - now)
    return max(wait, 0.0)


class PresetEditor:
    def __init__(self, preset: Preset):
        self.original = preset.copy()
        self.current = preset.copy()
        self._undo: list[Preset] = []
        self._redo: list[Preset] = []
        self._gesture: Preset | None = None
        self.is_unsaved = False

    @property
    def can_undo(self) -> bool:
        return bool(self._undo)

    @property
    def can_redo(self) -> bool:
        return bool(self._redo)

    @property
    def is_modified(self) -> bool:
        return self.is_unsaved or not self.current.same_content(self.original)

    # Changes

    def set_parameter(self, place: int, index: int, value: float) -> list[Change]:
        effects = self.current.effects
        if not 0 <= place < len(effects):
            return []
        parameter = next((p for p in effects[place].parameters if p.index == index), None)
        if parameter is None:
            return []
        value = f32(min(max(value, 0.0), 1.0))
        if parameter.value == value:
            return []
        self._record()
        parameter.value = value
        return [Change("parameter", effect=effects[place].name, index=index, value=value)]

    def set_on(self, place: int, is_on: bool) -> list[Change]:
        effects = self.current.effects
        if not 0 <= place < len(effects) or effects[place].is_on == is_on:
            return []
        self._record()
        effect = effects[place]
        effect.is_on = is_on
        info = catalog.load().info(effect.name, len(effect.parameters))
        for parameter in effect.parameters:
            if parameter.index in info.mirrors:
                parameter.value = 1.0 if is_on else 0.0
        return [Change("toggle", effect=effect.name, is_on=is_on)]

    def set_model(self, place: int, model_id: str) -> list[Change]:
        """Changes the model of a place. Its parameters get the catalog's start values, so the result does not
        depend on what the amp chooses: each value is sent after the model change."""
        effects = self.current.effects
        if not 0 <= place < len(effects) or effects[place].name == model_id:
            return []
        info = catalog.load().info(model_id, len(effects[place].parameters))
        fresh = catalog.load().make_effect(model_id, effects[place].is_on)
        if not info.defaults:
            fresh.parameters = [Parameter(p.index, 0.5) for p in fresh.parameters]
        self._record()
        old = effects[place].name
        marker = effects[place].parameters[0].marker if effects[place].parameters else 0x91
        effects[place].name = model_id
        effects[place].parameters = [Parameter(p.index, p.value, marker) for p in fresh.parameters]
        changes = [Change("model", old=old, new=model_id)]
        changes += [Change("parameter", effect=model_id, index=p.index, value=p.value)
                    for p in effects[place].parameters]
        return changes

    def set_name(self, name: str) -> None:
        if self.current.name != name:
            self._record()
            self.current.name = name

    def set_description(self, text: str) -> None:
        if self.current.description != text:
            self._record()
            self.current.description = text

    def set_bpm(self, bpm: float) -> list[Change]:
        bpm = f32(min(max(float(round(bpm)), BPM_RANGE[0]), BPM_RANGE[1]))
        if self.current.bpm == bpm:
            return []
        self._record()
        self.current.bpm = bpm
        return [Change("whole", preset=self.current.copy())]

    def follow(self, event) -> None:
        from .protocol import apply_event
        apply_event(self.current, event)

    # Undo

    def begin_gesture(self) -> None:
        if self._gesture is None:
            self._gesture = self.current.copy()

    def end_gesture(self) -> None:
        start, self._gesture = self._gesture, None
        if start is not None and start != self.current:
            self._push(start)

    def _record(self) -> None:
        if self._gesture is None:
            self._push(self.current.copy())

    def _push(self, state: Preset) -> None:
        self._undo.append(state)
        if len(self._undo) > HISTORY_LIMIT:
            self._undo.pop(0)
        self._redo.clear()

    def undo(self) -> list[Change]:
        self.end_gesture()
        if not self._undo:
            return []
        self._redo.append(self.current.copy())
        return self._move(self._undo.pop())

    def redo(self) -> list[Change]:
        if not self._redo:
            return []
        self._undo.append(self.current.copy())
        return self._move(self._redo.pop())

    def _move(self, state: Preset) -> list[Change]:
        changes = between(self.current, state)
        self.current = state
        return changes

    # Saved state

    def revert(self) -> list[Change]:
        if not self.is_modified:
            return []
        self._record()
        return self._move(self.original.copy())

    def mark_saved(self, preset: Preset | None = None) -> None:
        if preset is not None:
            self.current = preset.copy()
        self.original = self.current.copy()
        self.is_unsaved = False

    def mark_unsaved(self) -> None:
        self.is_unsaved = True
