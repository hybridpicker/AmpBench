"""About a hundred made-up sounds for a test folder, so the library can be seen and checked at a realistic size
without one's own presets: `ampbench --presets-folder <test folder> --made-up-sounds`. Songs, basic setups and
lessons as a Kemper import makes them, recipes, sounds saved from slots, backups, favorites and a few close sounds.
Every name is invented. The Mac app's counterpart is Sources/SparkPresetsUI/App/MadeUpLibrary.swift (the same songs,
not the same knobs).
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import catalog, factory
from .library import PresetLibrary
from .library_query import LISTEN_TAG

SONGS = ["Glass Harbor", "Northbound Lights", "Paper Tigers", "Slow River", "Copper Sky", "Night Shift",
         "Lantern Hill", "Velvet Static", "Echo Garden", "Iron Meadow", "Blue Window", "Silver Thread"]
PARTS = ["Intro", "Verse", "Chorus", "Bridge", "Solo", "Outro"]


class _Generator:
    """A small fixed sequence, so the made-up library is the same on every run."""

    def __init__(self, seed: int):
        self.state = seed

    def next(self, bound: int) -> int:
        self.state = (self.state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        return (self.state >> 33) % max(bound, 1)

    def value(self) -> float:
        return self.next(1000) / 1000


def _hashtag(title: str) -> str:
    return "".join(word[:1].upper() + word[1:] for word in title.split())


def fill(folder: Path) -> None:
    """Fills `folder` once: nothing is written when it already holds 20 sounds or more."""
    library = PresetLibrary(Path(folder), trash=lambda path: None)
    library.reload()
    if len(library.items) >= 20:
        return
    random = _Generator(7)
    cat = catalog.load()
    amps = [m.id for m in cat.models_for("amp")]
    drives = [m.id for m in cat.models_for("drive")]
    delays = [m.id for m in cat.models_for("delay")]
    modulations = [m.id for m in cat.models_for("modulation")]
    templates = factory.templates()
    start = datetime(2026, 10, 26, 9, 0, tzinfo=timezone.utc)

    def sound(name: str, amp: str | None = None):
        preset = factory.make(templates[random.next(len(templates))], name)
        preset.effects[3] = cat.make_effect(amp or amps[random.next(len(amps))], True,
                                            {0: random.value(), 1: random.value(), 2: random.value()})
        if random.next(3) == 0:
            preset.effects[2] = cat.make_effect(drives[random.next(len(drives))], True, {0: random.value()})
        if random.next(3) == 0:
            preset.effects[5] = cat.make_effect(delays[random.next(len(delays))], True, {0: random.value()})
        if random.next(4) == 0:
            preset.effects[4] = cat.make_effect(modulations[random.next(len(modulations))], True)
        preset.bpm = float(70 + random.next(80))
        return preset

    def save(preset, origin: str, tags=(), notes: str = "", favorite: bool = False, backup: bool = False,
             days: int = 0):
        saved = library.save(preset, origin, is_backup=backup, date=start + timedelta(days=days), tags=list(tags),
                             notes=notes)
        if favorite:
            library.update_meta(saved, favorite=True)
        return saved

    for index, song in enumerate(SONGS):
        amp = amps[random.next(len(amps))]
        for slot in range(4 + index % 3):
            part = PARTS[slot % len(PARTS)]
            tags = ["song", _hashtag(song)] + ([LISTEN_TAG] if (index + slot) % 3 else [])
            save(sound(f"{song} {part}", amp if slot % 2 == 0 else None), f"Kemper · {song} · slot {slot + 1}",
                 tags, f"Made-up rig “{song} {part}”.", days=index)
    for number in range(1, 4):
        for slot in range(1, 6):
            save(sound(f"Basis {number} · {slot}"), f"Kemper · Basis {number} · slot {slot}",
                 ["basis", f"Basis{number}"] + ([] if slot == 1 else [LISTEN_TAG]), days=14 + number)
    for number, lesson in enumerate(["Lesson Rhythm", "Lesson Blues"]):
        for slot in range(1, 6):
            save(sound(f"{lesson} {slot}"), f"Kemper · {lesson} · slot {slot}", ["unterricht", _hashtag(lesson)],
                 days=20 + number)
    for index, name in enumerate(["Warm Jazz Box", "Surf Spring", "Desert Fuzz", "Shimmer Pad", "Tight Rhythm"]):
        save(sound(name), "Recipe", ["clean"] if index < 2 else [], favorite=index == 0, days=25 + index)
    for slot in range(1, 5):
        save(sound(f"Spark slot {slot} sound"), f"Slot {slot} · Spark MINI", favorite=slot == 2, days=30 + slot)
    verse = next((i for i in library.items if i.name == "Glass Harbor Verse"), None)
    if verse is not None:
        copy = factory.duplicate(verse.preset, "Harbor clean (old)")
        save(copy, "Newly created", ["clean"], favorite=True, days=40)
        brighter = factory.duplicate(verse.preset, "Harbor clean, brighter")
        knob = brighter.effects[3].parameters[0]
        knob.value = min(1.0, knob.value + 0.08)
        save(brighter, "Newly created", days=41)
    for slot in range(1, 4):
        save(sound(f"Slot {slot} before"), f"Slot {slot} · Spark MINI, before overwriting", backup=True,
             days=42 + slot)


def pieces(items) -> list[dict]:
    """The made-up songs as pieces, the way the Kemper import hands them to the take library."""
    result = []
    for song in SONGS:
        parts = [{"name": item.name[len(song) + 1:],
                  "preset": {"presetID": item.id, "fileName": item.path.name, "name": item.name}}
                 for item in items if item.origin.startswith(f"Kemper · {song} · ")]
        if parts:
            result.append({"title": song, "notes": "", "parts": parts})
    return result
