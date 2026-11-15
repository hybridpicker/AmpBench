"""What the library overlay shows: origins, scopes, search, filters, groups and close sounds.

The port of Sources/SparkControl/Library/LibraryQuery.swift and PresetSimilarity.swift; change both together.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from . import catalog
from .i18n import tr
from .library import SavedPreset, tag_text

# The tag that marks a sound as wanting a listen, such as an imported Kemper sound, which is an approximation. A tag
# rather than a field of its own, so older versions, the Mac app and the sound store keep it as it is.
LISTEN_TAG = "listen"

AMP_INDEX = 3


def needs_listen(item: SavedPreset) -> bool:
    return any(t.casefold() == LISTEN_TAG for t in item.tags)


def with_listen(tags: list[str], on: bool) -> list[str]:
    """The tags with the mark set or taken away; the other tags keep their order."""
    kept = [t for t in tags if t.casefold() != LISTEN_TAG]
    return kept + [LISTEN_TAG] if on else kept


def amp_model(preset) -> str | None:
    """The model id of the amp in the chain, if the chain has one."""
    return preset.effects[AMP_INDEX].name if len(preset.effects) == len(catalog.PLACES) else None


def amp_name(model_id: str | None) -> str:
    if not model_id:
        return ""
    known = catalog.load().known(model_id)
    return known.name if known else model_id


# MARK: Origins

KEMPER, RECIPE, AMP, TEMPLATE, MADE, BACKUP = "kemper", "recipe", "amp", "template", "made", "backup"
ORIGINS = (KEMPER, RECIPE, AMP, TEMPLATE, MADE, BACKUP)


def origin_title(origin: str) -> str:
    return {KEMPER: tr("Kemper import"), RECIPE: tr("Recipe or AI Sound"), AMP: tr("From the amp"),
            TEMPLATE: tr("Template"), MADE: tr("Made here"), BACKUP: tr("Slot backup")}[origin]


def origin_of(item: SavedPreset) -> str:
    """Where a saved sound came from, worked out from what its file says. The file keeps the origin as a sentence in
    the language of the day it was saved, so both languages are recognized."""
    if item.is_backup:
        return BACKUP
    if item.is_recipe:
        return RECIPE
    origin = item.origin
    if origin.startswith("Kemper"):
        return KEMPER
    if origin in ("Recipe", "Rezept") or origin.startswith(("AI Sound", "KI-Sound")):
        return RECIPE
    if origin in ("Template", "Vorlage"):
        return TEMPLATE
    # "Slot 2 · Spark MINI", "Platz 2 · Spark NEO", "Red 1 · REACTOR 50", "Played temporarily · Spark MINI".
    if " · " in origin and ("Spark" in origin or "REACTOR" in origin):
        return AMP
    return MADE


# MARK: Scopes and the query

ALL, FAVORITES, TO_LISTEN, CLOSE, BACKUPS = "all", "favorites", "toListen", "close", "backups"
SCOPES = (ALL, FAVORITES, TO_LISTEN, CLOSE, BACKUPS)


def scope_title(scope: str) -> str:
    return {ALL: tr("All sounds"), FAVORITES: tr("Favorites"), TO_LISTEN: tr("To listen"),
            CLOSE: tr("Close sounds"), BACKUPS: tr("Slot backups")}[scope]


def _contains(text: str, word: str) -> bool:
    return word.casefold() in text.casefold()


def matches(item: SavedPreset, search: str) -> bool:
    """The search looks at names, origin, models, tags and notes; "#clean" looks at tags only. Every word must be
    found somewhere, so "clean twin" finds a clean sound on the Twin."""
    query = search.strip()
    if not query:
        return True
    if query.startswith("#"):
        tag = tag_text(query).casefold()
        return not tag or any(t.casefold().startswith(tag) for t in item.tags)
    cat = catalog.load()

    def found(word: str) -> bool:
        if any(_contains(text, word) for text in (item.name, item.origin, item.notes, *item.tags)):
            return True
        for effect in item.preset.effects:
            known = cat.known(effect.name)
            if _contains(effect.name, word) or (known is not None and _contains(known.name, word)):
                return True
        return False

    return all(found(word) for word in query.split())


@dataclass
class LibraryQuery:
    """A scope, a search and filters. A sound must match the search, carry every chosen tag, and have one of the
    chosen amps and one of the chosen origins when any are chosen."""
    scope: str = ALL
    search: str = ""
    tags: list[str] = field(default_factory=list)
    amps: set[str] = field(default_factory=set)
    origins: set[str] = field(default_factory=set)

    @property
    def is_filtering(self) -> bool:
        return bool(self.search.strip() or self.tags or self.amps or self.origins)

    def apply(self, items: list[SavedPreset], close: set[Path] | None = None) -> list[SavedPreset]:
        """The items to show, in the order given. `close` holds the paths of sounds with a close one."""
        wanted = [t.casefold() for t in self.tags]
        close = close or set()
        result = []
        for item in items:
            if self.scope == ALL and item.is_backup:
                continue
            if self.scope == FAVORITES and (item.is_backup or not item.favorite):
                continue
            if self.scope == TO_LISTEN and (item.is_backup or not needs_listen(item)):
                continue
            if self.scope == CLOSE and item.path not in close:
                continue
            if self.scope == BACKUPS and not item.is_backup:
                continue
            own = {t.casefold() for t in item.tags}
            if not all(t in own for t in wanted):
                continue
            if self.amps and (amp_model(item.preset) or "") not in self.amps:
                continue
            if self.origins and origin_of(item) not in self.origins:
                continue
            if matches(item, self.search):
                result.append(item)
        return result


# MARK: Groups

NONE, TAG, AMP_GROUPS, ORIGIN = "none", "tag", "amp", "origin"
GROUPINGS = (NONE, TAG, AMP_GROUPS, ORIGIN)


def grouping_title(grouping: str) -> str:
    """The short titles of the grouping tabs."""
    return {NONE: tr("A–Z"), TAG: tr("Tag"), AMP_GROUPS: tr("Amp"), ORIGIN: tr("Origin")}[grouping]


def next_grouping(grouping: str) -> str:
    return GROUPINGS[(GROUPINGS.index(grouping) + 1) % len(GROUPINGS)] if grouping in GROUPINGS else NONE


@dataclass
class Group:
    id: str
    title: str
    items: list[SavedPreset]


def groups(grouping: str, items: list[SavedPreset], leaving: list[str] | None = None) -> list[Group]:
    """The items in groups. Groups are ordered by size for tags, by name otherwise; the items keep their order. A
    sound stands in each of its tags. `leaving` names tags that get no group, such as those filtered by, which every
    item carries; the listen mark is never a group."""
    left = {t.casefold() for t in (leaving or []) + [LISTEN_TAG]}
    if grouping == TAG:
        by_tag: dict[str, Group] = {}
        untagged = []
        for item in items:
            tags = [t for t in item.tags if t.casefold() not in left]
            if not tags:
                untagged.append(item)
            for tag in tags:
                by_tag.setdefault(tag.casefold(), Group(f"tag:{tag.casefold()}", f"#{tag}", [])).items.append(item)
        result = sorted(by_tag.values(), key=lambda g: (-len(g.items), g.id))
        if untagged:
            result.append(Group("tag:", tr("Without tags"), untagged))
        return result
    if grouping == AMP_GROUPS:
        by_amp: dict[str, list] = {}
        for item in items:
            by_amp.setdefault(amp_model(item.preset) or "", []).append(item)
        result = [Group(f"amp:{model}", amp_name(model) or tr("No amp"), members) for model, members in by_amp.items()]
        return sorted(result, key=lambda g: g.title.casefold())
    if grouping == ORIGIN:
        by_origin: dict[str, list] = {}
        for item in items:
            by_origin.setdefault(origin_of(item), []).append(item)
        return [Group(f"origin:{o}", origin_title(o), by_origin[o]) for o in ORIGINS if o in by_origin]
    return [Group("all", "", list(items))]


# MARK: Close sounds

CLOSE_LIMIT = 0.5
"""At most this distance counts as close: about a fifth of the amp's knobs turned by a quarter, or one effect switched
with everything else alike."""


@dataclass
class Comparison:
    distance: float
    differing: list[str]  # chain places, in chain order

    @property
    def is_equal(self) -> bool:
        return not self.differing and self.distance == 0


def _knob_change(x, y) -> float:
    """The mean change of the knobs both have, 0 to 1. Rounding in the amp's floats is not a difference anyone
    hears."""
    changes = [abs(a.value - b.value) for a, b in zip(x.parameters, y.parameters)]
    if not changes:
        return 0.0
    mean = sum(changes) / len(changes)
    return 0.0 if mean < 0.0005 else mean


def compare(a, b) -> Comparison | None:
    """How close two sounds are. Only what is heard counts: an effect that is off in both is left out. Sounds on
    different amp models are never close (None). Otherwise every place adds to the distance: the mean change of its
    knobs (the amp's twice), or 0.5 for an effect on in only one of them or on with another model."""
    if len(a.effects) != len(b.effects) or not a.effects:
        return None
    places = catalog.PLACES if len(a.effects) == len(catalog.PLACES) else [None] * len(a.effects)
    distance, differing = 0.0, []
    for index, (x, y) in enumerate(zip(a.effects, b.effects)):
        place = places[index]
        if place == "amp":
            if x.name != y.name:
                return None
            change = _knob_change(x, y)
            distance += 2 * change
            if change > 0:
                differing.append("amp")
            continue
        if not x.is_on and not y.is_on:
            continue
        if x.is_on and y.is_on and x.name == y.name:
            change = _knob_change(x, y)
            distance += change
            if change > 0 and place:
                differing.append(place)
        else:
            distance += 0.5
            if place:
                differing.append(place)
    return Comparison(distance, differing)


def neighbours(item: SavedPreset, items: list[SavedPreset],
               limit: float = CLOSE_LIMIT) -> list[tuple[SavedPreset, Comparison]]:
    """The sounds of `items` close to `item`, nearest first, leaving out its own file."""
    found = []
    for other in items:
        if other.path == item.path:
            continue
        comparison = compare(item.preset, other.preset)
        if comparison is not None and comparison.distance <= limit:
            found.append((other, comparison))
    return sorted(found, key=lambda pair: pair[1].distance)


def close_groups(items: list[SavedPreset], limit: float = CLOSE_LIMIT) -> list[list[SavedPreset]]:
    """Groups of sounds close to each other, directly or through one another, each of two or more, the largest
    first. Slot backups are left out: being close to what they backed up is their purpose."""
    sounds = [i for i in items if not i.is_backup]
    parent = list(range(len(sounds)))

    def root(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    by_amp: dict[str, list[int]] = {}
    for index, sound in enumerate(sounds):
        by_amp.setdefault(amp_model(sound.preset) or "", []).append(index)
    for indices in by_amp.values():
        for n, i in enumerate(indices):
            for j in indices[n + 1:]:
                comparison = compare(sounds[i].preset, sounds[j].preset)
                if comparison is not None and comparison.distance <= limit:
                    parent[root(j)] = root(i)
    grouped: dict[int, list[SavedPreset]] = {}
    for index, sound in enumerate(sounds):
        grouped.setdefault(root(index), []).append(sound)
    result = [members for members in grouped.values() if len(members) > 1]
    return sorted(result, key=lambda g: (-len(g), g[0].name.casefold()))


# MARK: Pieces

def pieces_using(document: dict | None, item: SavedPreset) -> list[str]:
    """The pieces and parts of the take library that play `item`: by its id, or by its file name for a link
    without one. "Piece · Part" for a part."""
    if not document:
        return []

    def names(link) -> bool:
        if not link:
            return False
        if link.get("presetID") and item.id:
            return link["presetID"] == item.id
        return link.get("fileName") == item.path.name

    result = []
    for piece in document.get("pieces", []):
        if names(piece.get("preset")):
            result.append(piece.get("name", ""))
        result += [f"{piece.get('name', '')} · {part.get('name', '')}" for part in piece.get("parts", [])
                   if names(part.get("preset"))]
    return result
