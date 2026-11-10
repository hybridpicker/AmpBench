"""Notes, tunings and what the tuner shows for a reading. A port of Sources/SparkCore/Tuning.swift and the amp's
interpreter in AmpTuner.swift; the Swift code is the reference, change both together. No audio code in here."""
from __future__ import annotations

import math
from dataclasses import dataclass, field, replace

from .i18n import number, tr


# Note names in the app's language: English B and B♭ are German H and B.
def sharp_names() -> list[str]:
    return ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", tr("B")]


def flat_names() -> list[str]:
    return ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", tr("B♭"), tr("B")]


def spoken_sharps() -> list[str]:
    return ["C", tr("C sharp"), "D", tr("D sharp"), "E", "F", tr("F sharp"), "G", tr("G sharp"), "A", tr("A sharp"),
            tr("B")]


def spoken_flats() -> list[str]:
    return ["C", tr("D flat"), "D", tr("E flat"), "E", "F", tr("G flat"), "G", tr("A flat"), "A", tr("B flat"), tr("B")]


def round_half_away(value: float) -> int:
    """Swift's .rounded(): halves go away from zero, unlike Python's round()."""
    return int(math.copysign(math.floor(abs(value) + 0.5), value))


A4_RANGE = (430.0, 450.0)
DEFAULT_A4 = 440.0


@dataclass(frozen=True)
class Note:
    """A note of the equal-tempered scale as a MIDI number: 69 is A4, 40 the low E of a guitar, 23 the low B of a
    five-string bass (B0)."""
    midi: int

    def name(self, flats: bool = False) -> str:
        return (flat_names() if flats else sharp_names())[self.pitch_class]

    def spoken_name(self, flats: bool = False) -> str:
        return (spoken_flats() if flats else spoken_sharps())[self.pitch_class]

    @property
    def pitch_class(self) -> int:
        return self.midi % 12

    @property
    def octave(self) -> int:
        return self.midi // 12 - 1

    def frequency(self, a4: float) -> float:
        return a4 * 2 ** ((self.midi - 69) / 12)

    @staticmethod
    def nearest(frequency: float, a4: float) -> "Note":
        return Note(round_half_away(69 + 12 * math.log2(frequency / a4)))

    def cents(self, frequency: float, a4: float) -> float:
        return 1200 * math.log2(frequency / self.frequency(a4))


TUNINGS = {
    "standard": ("Standard", [40, 45, 50, 55, 59, 64]),
    "dropD": ("Drop D", [38, 45, 50, 55, 59, 64]),
    "dadgad": ("DADGAD", [38, 45, 50, 55, 57, 62]),
    "openG": ("Open G", [38, 43, 50, 55, 59, 62]),
    "halfStepDown": ("Half step down", [39, 44, 49, 54, 58, 63]),
    "chromatic": ("Chromatic", []),
}


@dataclass(frozen=True)
class Tuning:
    """A tuning; strings go from the lowest, the sixth, to the highest, the first. Chromatic has none."""
    key: str

    @property
    def title(self) -> str:
        return tr(TUNINGS[self.key][0])

    @property
    def strings(self) -> list[Note]:
        return [Note(m) for m in TUNINGS[self.key][1]]

    @property
    def prefers_flats(self) -> bool:
        return self.key == "halfStepDown"

    @property
    def summary(self) -> str:
        strings = self.strings
        return tr("All notes") if not strings else " ".join(n.name(self.prefers_flats) for n in strings)

    @staticmethod
    def all() -> list["Tuning"]:
        return [Tuning(key) for key in TUNINGS]

    @staticmethod
    def named(key: str | None) -> "Tuning":
        return Tuning(key if key in TUNINGS else "standard")


@dataclass
class PitchReading:
    """What the tracker hears right now."""
    frequency: float
    is_held: bool = False
    uncertainty: float | None = None


@dataclass
class TunerReadout:
    frequency: float
    note: Note
    string: int | None
    cents: float
    flats: bool
    is_held: bool
    is_in_tune: bool
    is_from_amp: bool = False
    knows_octave: bool = True

    @property
    def direction(self) -> str:
        limit = AmpTunerInterpreter.TOLERANCE if self.is_from_amp else TunerInterpreter.TOLERANCE
        if abs(self.cents) <= limit:
            return "in_tune"
        return "low" if self.cents < 0 else "high"

    @property
    def note_name(self) -> str:
        return self.note.name(self.flats)


class TunerInterpreter:
    """Turns readings into notes, strings and cents for a tuning and a concert pitch, with a little hysteresis so the
    note does not flicker between two neighbours, and with the timer behind "Gestimmt"."""
    TOLERANCE = 0.5          # "Gestimmt" within ±0.5 cents ...
    IN_TUNE_AFTER = 0.4      # ... held for this long ...
    IN_TUNE_PRECISION = 0.2  # ... measured precisely enough to tell

    def __init__(self, tuning: Tuning | None = None, a4: float = DEFAULT_A4):
        self.tuning = tuning or Tuning("standard")
        self.a4 = a4
        self._previous: tuple[Note, int | None] | None = None
        self._within_since: float | None = None
        self._last_in_tune = False

    def interpret(self, reading: PitchReading | None, time: float) -> TunerReadout | None:
        if reading is None:
            self._previous, self._within_since, self._last_in_tune = None, None, False
            return None
        note, string = self.target(reading.frequency)
        self._previous = (note, string)
        cents = note.cents(reading.frequency, self.a4)
        in_tune = self._last_in_tune
        if not reading.is_held:
            if abs(cents) <= self.TOLERANCE and reading.uncertainty is not None \
                    and reading.uncertainty <= self.IN_TUNE_PRECISION:
                if self._within_since is None:
                    self._within_since = time
                in_tune = time - self._within_since >= self.IN_TUNE_AFTER
            else:
                self._within_since, in_tune = None, False
            self._last_in_tune = in_tune
        return TunerReadout(reading.frequency, note, string, cents, self.tuning.prefers_flats, reading.is_held, in_tune)

    def target(self, frequency: float) -> tuple[Note, int | None]:
        """The string or note a frequency is tuned towards."""
        strings = self.tuning.strings
        if strings:
            distances = [abs(s.cents(frequency, self.a4)) for s in strings]
            best = min(range(len(strings)), key=lambda i: distances[i])
            if distances[best] <= 300:
                # Stay on the string from before unless the new one is clearly nearer.
                if self._previous and self._previous[1] is not None:
                    string = self._previous[1]
                    index = len(strings) - string
                    if 0 <= index < len(strings) and index != best and distances[index] <= 300 \
                            and distances[index] - distances[best] < 30:
                        return strings[index], string
                return strings[best], len(strings) - best
        nearest = Note.nearest(frequency, self.a4)
        if self._previous and self._previous[1] is None and self._previous[0] != nearest \
                and abs(self._previous[0].cents(frequency, self.a4)) < 60:
            return self._previous[0], None
        return nearest, None


class AmpTunerInterpreter:
    """Turns the amp's own tuner readings into what the tuner shows. The amp's values jump by about ±10 cents, so
    the median of the last 0.4 s is shown, in whole cents; a new note shows after three readings in a row. The amp
    names the note, not its octave: the tuning's string of that name gives it when there is exactly one."""
    TOLERANCE = 3.0
    IN_TUNE_AFTER = 0.5
    WINDOW = 0.4
    SWITCH_AFTER = 3
    SIGNAL_TIMEOUT = 0.3
    HOLD_FOR = 1.5
    AMP_A4 = 440.0

    def __init__(self, tuning: Tuning | None = None, a4: float = DEFAULT_A4):
        self.tuning = tuning or Tuning("standard")
        self.a4 = a4
        self.reset()

    def reset(self) -> None:
        self._recent: list[tuple[float, float]] = []
        self._shown: int | None = None
        self._candidate: tuple[int, int] | None = None
        self._last_signal: float | None = None
        self._within_since: float | None = None
        self._last: TunerReadout | None = None
        self._previous_string: int | None = None

    def add(self, pitch_class: int, cents: float | None, time: float) -> None:
        """One reading from the amp. `cents` None: no signal."""
        if cents is None or not 0 <= pitch_class < 12 or not math.isfinite(cents):
            return
        position = pitch_class * 100 + cents - 1200 * math.log2(self.a4 / self.AMP_A4)
        note = round_half_away(position / 100)
        offset = position - note * 100
        pitch = note % 12
        self._last_signal = time
        if pitch != self._shown:
            count = self._candidate[1] + 1 if self._candidate and self._candidate[0] == pitch else 1
            self._candidate = (pitch, count)
            if count < self.SWITCH_AFTER:
                return
            self._shown, self._candidate, self._recent, self._within_since = pitch, None, [], None
        else:
            self._candidate = None
        self._recent.append((time, offset))
        self._recent = [r for r in self._recent if time - r[0] <= self.WINDOW]

    @property
    def has_signal(self) -> bool:
        return self._last is not None and not self._last.is_held

    def readout(self, time: float) -> TunerReadout | None:
        if self._shown is None or self._last_signal is None:
            return None
        if time - self._last_signal > self.SIGNAL_TIMEOUT:
            self._within_since = None
            if time - self._last_signal >= self.HOLD_FOR or self._last is None:
                self._last = None
                return None
            self._last = replace(self._last, is_held=True, is_in_tune=False)
            return self._last
        values = sorted(c for _, c in self._recent)
        if not values:
            return self._last
        cents = float(round_half_away(values[len(values) // 2]))
        note, string, knows_octave = self._target(self._shown)
        if abs(cents) <= self.TOLERANCE:
            if self._within_since is None:
                self._within_since = time
        else:
            self._within_since = None
        in_tune = self._within_since is not None and time - self._within_since >= self.IN_TUNE_AFTER
        frequency = note.frequency(self.a4) * 2 ** (cents / 1200) if knows_octave else 0.0
        self._last = TunerReadout(frequency, note, string, cents, self.tuning.prefers_flats, False, in_tune,
                                  is_from_amp=True, knows_octave=knows_octave)
        return self._last

    def _target(self, pitch_class: int) -> tuple[Note, int | None, bool]:
        strings = self.tuning.strings
        matching = [i for i, s in enumerate(strings) if s.pitch_class == pitch_class]
        if len(matching) == 1:
            index = matching[0]
            self._previous_string = len(strings) - index
            return strings[index], len(strings) - index, True
        if self._previous_string is not None and (len(strings) - self._previous_string) in matching:
            return strings[len(strings) - self._previous_string], self._previous_string, True
        self._previous_string = None
        # The octave is unknown: a note of the guitar's middle, for its name only.
        return Note(48 + pitch_class), None, False


# MARK: Text


def decimal(value: float, digits: int) -> str:
    return number(value, digits)


def cents_text(value: float) -> str:
    """"+0.3", "−12.0", "±0.0"; with a decimal comma in German."""
    rounded = round_half_away(value * 10) / 10
    if rounded == 0:
        return "±" + decimal(0, 1)
    return ("−" if rounded < 0 else "+") + decimal(abs(rounded), 1)


def whole_cents_text(value: float) -> str:
    """"+3", "−12", "±0": whole cents, for the amp's coarser tuner."""
    rounded = round_half_away(value)
    if rounded == 0:
        return "±0"
    return ("−" if rounded < 0 else "+") + str(abs(int(rounded)))


def hertz_text(value: float, digits: int = 2) -> str:
    return decimal(value, digits)


def spoken_cents(value: float) -> str:
    rounded = round_half_away(value * 10) / 10
    if rounded == 0:
        return tr("0 cents")
    amount = decimal(abs(rounded), 1)
    return tr("minus {} cents", amount) if rounded < 0 else tr("plus {} cents", amount)


def spoken(readout: TunerReadout) -> str:
    """"E, string 6, 2 cents too low" or "E, string 6, in tune"."""
    parts = [readout.note.spoken_name(readout.flats)]
    if readout.string is not None:
        parts.append(tr("string {}", readout.string))
    if readout.is_in_tune:
        parts.append(tr("in tune"))
    else:
        amount = abs(readout.cents)
        text = str(round_half_away(amount)) if amount >= 2 else decimal(amount, 1)
        parts.append(tr("{} cents too low", text) if readout.cents < 0 else tr("{} cents too high", text))
    return ", ".join(parts)
