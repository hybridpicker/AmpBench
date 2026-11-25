"""Where the bars of a recording lie, and what a take remembers about its click.

A port of Sources/SparkCore/ClickTiming.swift (ClickLatency, ClickOutputKind, AmpPart, AmpLatencies, ClickTiming) and
of TimingStamp and ClickWatch from TimingReview.swift. The JSON of a take's ``timing`` is that of the Mac app.

The click runs on the input's clock (native/ampbench-rt.c): beat 0 lies on the input frame ``anchor`` and each
further beat one interval of input frames later. Between handing the click to the output and the note showing up in
the file lie the output's latency, the amp's own delay and the input's latency; the devices report the first and the
last, the amp's part is measured once per amp or set by hand.
"""
from __future__ import annotations

from dataclasses import dataclass, field, replace
from datetime import datetime

WIRED, BLUETOOTH, AIRPLAY = "wired", "bluetooth", "airPlay"


@dataclass(frozen=True)
class AmpPart:
    """The amp's part of the click latency: what no device reports. It belongs to the input, the amp, and holds for
    every wired click output of the computer."""
    seconds: float
    measured: bool
    spread: float = 0.0  # a measurement's spread in seconds (earliest to latest click)
    date: str | None = None  # ISO 8601, a measurement's day

    def to_json(self) -> dict:
        origin = {"measured": {"spread": self.spread, "date": self.date}} if self.measured else {"setByHand": {}}
        return {"seconds": self.seconds, "origin": origin}

    @classmethod
    def from_json(cls, data) -> "AmpPart | None":
        if not isinstance(data, dict):
            return None
        try:
            seconds = float(data["seconds"])
        except (KeyError, TypeError, ValueError):
            return None
        origin = data.get("origin") if isinstance(data.get("origin"), dict) else {}
        measured = origin.get("measured")
        if isinstance(measured, dict):
            try:
                return cls(seconds, True, float(measured.get("spread", 0)), measured.get("date"))
            except (TypeError, ValueError):
                return cls(seconds, False)
        return cls(seconds, False)


@dataclass(frozen=True)
class ClickLatency:
    """How long a beat takes from the click output until it shows up in the file, if someone plays exactly on it."""
    output: float = 0.0
    input: float = 0.0
    amp: AmpPart | None = None
    output_kind: str = WIRED

    @property
    def amp_seconds(self) -> float:
        return self.amp.seconds if self.amp else 0.0

    @property
    def reported(self) -> float:
        return self.output + self.input

    @property
    def total(self) -> float:
        return self.reported + self.amp_seconds

    def to_json(self) -> dict:
        data = {"output": self.output, "input": self.input, "outputKind": self.output_kind}
        if self.amp:
            data["amp"] = self.amp.to_json()
        return data

    @classmethod
    def from_json(cls, data) -> "ClickLatency":
        if not isinstance(data, dict):
            return cls()
        try:
            kind = data.get("outputKind", WIRED)
            return cls(float(data.get("output", 0)), float(data.get("input", 0)), AmpPart.from_json(data.get("amp")),
                       kind if kind in (WIRED, BLUETOOTH, AIRPLAY) else WIRED)
        except (TypeError, ValueError):
            return cls()


HAND_SET_RANGE = (-0.1, 0.3)


@dataclass
class AmpLatencies:
    """The amp parts of the click latency, one per input, keyed by the input's node name."""
    parts: dict[str, AmpPart] = field(default_factory=dict)

    def part(self, input_key: str | None) -> AmpPart | None:
        return self.parts.get(input_key) if input_key else None

    def store_measurement(self, input_key: str, correction: float, spread: float, when: datetime) -> None:
        self.parts[input_key] = AmpPart(correction, True, spread, when.astimezone().isoformat(timespec="seconds"))

    def set_by_hand(self, input_key: str, seconds: float) -> None:
        """Sets the part by hand; it then counts as hand-set even when it was measured before. About zero forgets it."""
        clamped = min(max(seconds, HAND_SET_RANGE[0]), HAND_SET_RANGE[1])
        if abs(clamped) < 0.00005:
            self.parts.pop(input_key, None)
        else:
            self.parts[input_key] = AmpPart(clamped, False)

    def click_latency(self, input_key: str | None, reported_output: float, reported_input: float,
                      output_kind: str) -> ClickLatency:
        return ClickLatency(reported_output, reported_input, self.part(input_key), output_kind)

    def to_json(self) -> dict:
        return {"parts": {key: part.to_json() for key, part in self.parts.items()}}

    @classmethod
    def from_json(cls, data) -> "AmpLatencies":
        parts = (data or {}).get("parts") if isinstance(data, dict) else None
        if not isinstance(parts, dict):
            return cls()
        return cls({key: part for key, value in parts.items() if (part := AmpPart.from_json(value))})


# MARK: Where the bars lie

def beat_interval(bpm: float, input_rate: float) -> float:
    return input_rate * 60 / bpm


def downbeat_frame(anchor_frame: float, beats_before: int, bpm: float, input_rate: float) -> float:
    """The input frame of the beat that starts bar 1, at the click: ``beats_before`` counts the count-in."""
    return anchor_frame + beats_before * beat_interval(bpm, input_rate)


def grid_offset(anchor_frame: float, beats_before: int, bpm: float, input_rate: float, file_first_frame: int,
                latency: ClickLatency) -> float:
    """Where bar 1 lies in the file, in seconds: the place where a note played exactly on its click ends up."""
    downbeat = downbeat_frame(anchor_frame, beats_before, bpm, input_rate)
    return (downbeat - file_first_frame) / input_rate + latency.total


def gate_frame(anchor_frame: float, beats_before: int, bpm: float, input_rate: float, pre_roll: float) -> int:
    """The input frame where a recording after a count-in starts: ``pre_roll`` seconds before bar 1 at the click."""
    downbeat = downbeat_frame(anchor_frame, beats_before, bpm, input_rate)
    return int(round(downbeat - pre_roll * input_rate))


# MARK: The take's timing stamp

@dataclass(frozen=True)
class TimingStamp:
    """What a take remembers about its click, so its timing review can be judged later."""
    click_on_throughout: bool
    latency: ClickLatency

    def to_json(self) -> dict:
        return {"clickOnThroughout": self.click_on_throughout, "latency": self.latency.to_json()}

    @classmethod
    def from_json(cls, data) -> "TimingStamp | None":
        """A stamp that cannot be read in full never passes for one with the click on and the amp part measured."""
        if not isinstance(data, dict):
            return None
        on = data.get("clickOnThroughout")
        return cls(on if isinstance(on, bool) else False, ClickLatency.from_json(data.get("latency")))


@dataclass
class ClickWatch:
    """Follows the click through a recording. Once the click is off, even for a moment, the take is no longer one
    with the click on throughout."""
    on_throughout: bool

    def click_switched(self, on: bool) -> None:
        if not on:
            self.on_throughout = False

    def stamp(self, latency: ClickLatency) -> TimingStamp:
        return TimingStamp(self.on_throughout, latency)


def with_amp(latency: ClickLatency, amp: AmpPart | None) -> ClickLatency:
    return replace(latency, amp=amp)
