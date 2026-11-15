"""The library's search, filters, groups and close sounds, with made-up presets from the templates. The same cases
as Tests/SparkControlTests/LibraryQueryTests.swift."""
from pathlib import Path

from ampbench import factory, made_up
from ampbench import library_query as q
from ampbench.library import PresetLibrary, SavedPreset


def item(name, template="Clean", origin="Template", tags=(), favorite=False, backup=False, change=None):
    preset = factory.make(next(t for t in factory.templates() if t.name == template), name)
    if change:
        change(preset)
    return SavedPreset(Path(f"/made-up/{name}.json"), preset, origin=origin, is_backup=backup, favorite=favorite,
                       tags=list(tags))


def test_origins_are_recognized_in_both_languages():
    assert q.origin_of(item("a", origin="Kemper · Some Song · slot 2")) == q.KEMPER
    assert q.origin_of(item("b", origin="Rezept")) == q.RECIPE
    assert q.origin_of(item("c", origin="Platz 2 · Spark MINI")) == q.AMP
    assert q.origin_of(item("d", origin="Red 1 · REACTOR 50")) == q.AMP
    assert q.origin_of(item("e", origin="Vorlage")) == q.TEMPLATE
    assert q.origin_of(item("f", origin="Newly created")) == q.MADE
    assert q.origin_of(item("g", origin="Slot 1 · Spark MINI", backup=True)) == q.BACKUP


def test_scopes_filters_and_search_narrow_together():
    items = [
        item("Glass Harbor Clean", origin="Kemper · Glass Harbor · slot 1", tags=["song", "GlassHarbor", "listen"]),
        item("Glass Harbor Lead", "Lead", "Kemper · Glass Harbor · slot 3", tags=["song", "GlassHarbor"]),
        item("Lesson Crunch", "Crunch", tags=["unterricht"], favorite=True),
        item("Old slot 2", "Crunch", "Slot 2 · Spark MINI", backup=True),
    ]
    names = lambda query: [i.name for i in query.apply(items)]
    assert names(q.LibraryQuery()) == ["Glass Harbor Clean", "Glass Harbor Lead", "Lesson Crunch"], \
        "backups only in their scope"
    assert names(q.LibraryQuery(scope=q.BACKUPS)) == ["Old slot 2"]
    assert names(q.LibraryQuery(scope=q.FAVORITES)) == ["Lesson Crunch"]
    assert names(q.LibraryQuery(scope=q.TO_LISTEN)) == ["Glass Harbor Clean"]
    assert len(q.LibraryQuery(tags=["song"], origins={q.KEMPER}).apply(items)) == 2
    assert names(q.LibraryQuery(amps={"SLO100"})) == ["Glass Harbor Lead"]
    assert names(q.LibraryQuery(search="glass lead")) == ["Glass Harbor Lead"], "every word must match somewhere"
    assert names(q.LibraryQuery(search="#unter")) == ["Lesson Crunch"]
    assert names(q.LibraryQuery(search="plexi")) == ["Lesson Crunch"], "the search finds amp models"


def test_the_listen_mark_is_a_tag_that_older_versions_keep(tmp_path):
    assert q.with_listen(["song"], True) == ["song", "listen"]
    assert q.with_listen(["song", "Listen"], True) == ["song", "listen"], "marking twice adds nothing"
    assert q.with_listen(["song", "listen"], False) == ["song"]
    library = PresetLibrary(tmp_path, trash=lambda p: p.unlink())
    saved = library.save(factory.empty("Marked"), "Test", tags=["song"])
    saved = library.update_meta(saved, tags=q.with_listen(saved.tags, True))
    import json
    assert json.loads(saved.path.read_text())["tags"] == ["song", "listen"], "a plain tag in the format-2 file"
    assert q.needs_listen(saved)


def test_groups_by_tag_amp_and_origin():
    items = [item("A", tags=["song", "listen"]), item("B", "Lead", tags=["song", "basis"]),
             item("C", "Crunch", "Kemper · X · slot 1")]
    by_tag = q.groups(q.TAG, items)
    assert [g.title for g in by_tag] == ["#song", "#basis", "Without tags"], "the listen mark is no group"
    assert [i.name for i in by_tag[0].items] == ["A", "B"]
    assert [g.title for g in q.groups(q.TAG, items, leaving=["SONG"])] == ["#basis", "Without tags"], \
        "a tag filtered by is carried by all, so it makes no group"
    assert len(q.groups(q.AMP_GROUPS, items)) == 3
    assert [g.title for g in q.groups(q.ORIGIN, items)] == ["Kemper import", "Template"]
    assert len(q.groups(q.NONE, items)[0].items) == 3
    assert q.next_grouping(q.ORIGIN) == q.NONE


def test_close_sounds_are_found_and_others_are_not():
    def brighter(preset):
        preset.effects[3].parameters[0].value += 0.1

    def with_delay(preset):
        preset.effects[5].is_on = True

    def far_off(preset):
        for parameter in preset.effects[3].parameters:
            parameter.value = 1.0
        preset.effects[1].is_on = False
        preset.effects[6].is_on = False

    original, renamed = item("Clean"), item("Clean (copy from the Kemper)")
    turned, switched = item("Clean brighter", change=brighter), item("Clean with delay", change=with_delay)
    other_amp, far = item("Crunch", "Crunch"), item("Clean, all knobs turned", change=far_off)
    assert q.compare(original.preset, renamed.preset).is_equal
    assert q.compare(original.preset, turned.preset).differing == ["amp"]
    assert q.compare(original.preset, switched.preset).differing == ["delay"]
    assert q.compare(original.preset, other_amp.preset) is None, "another amp is never close"
    near = q.neighbours(original, [original, renamed, turned, switched, far])
    assert [i.name for i, _ in near] == ["Clean (copy from the Kemper)", "Clean brighter", "Clean with delay"]
    # Backups are close to what they backed up by design, and are left out.
    groups = q.close_groups([original, renamed, turned, other_amp, far, item("Clean backup", backup=True)])
    assert len(groups) == 1
    assert {i.name for i in groups[0]} == {"Clean", "Clean (copy from the Kemper)", "Clean brighter"}


def test_pieces_are_found_by_id_or_file_name():
    sound = item("Verse")
    sound.id = "ABC"
    document = {"pieces": [
        {"name": "Glass Harbor", "parts": [{"name": "Verse", "preset": {"presetID": "ABC", "fileName": "x.json"}},
                                           {"name": "Solo", "preset": {"presetID": "OTHER"}}]},
        {"name": "Old song", "preset": {"fileName": "Verse.json"}, "parts": []},
    ]}
    assert q.pieces_using(document, sound) == ["Glass Harbor · Verse", "Old song"], \
        "an id decides where both have one, the file name where the link has none"
    sound.id = None
    assert q.pieces_using(document, sound) == ["Old song"]
    assert q.pieces_using(None, sound) == []


def test_the_made_up_library_is_realistic_and_written_once(tmp_path):
    made_up.fill(tmp_path)
    library = PresetLibrary(tmp_path)
    library.reload()
    count = len(library.items)
    assert 90 <= count <= 120
    assert any(q.needs_listen(i) for i in library.items) and any(i.favorite for i in library.items)
    assert any(i.is_backup for i in library.items)
    assert q.close_groups(library.items), "the pictures need close sounds"
    made_up.fill(tmp_path)
    library.reload()
    assert len(library.items) == count, "a second start adds nothing"
    pieces = made_up.pieces(library.items)
    assert len(pieces) == len(made_up.SONGS)
    assert all(part["preset"]["presetID"] for piece in pieces for part in piece["parts"])
