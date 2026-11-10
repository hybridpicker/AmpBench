"""The Kemper import, with Kemper files built here from scratch, never real ones."""
import io
import sqlite3
import tarfile

import pytest

from ampbench import catalog, i18n, kemper, library, recipe, store as storemod


def _var(value: int) -> bytes:
    out = [value & 0x7F]
    value >>= 7
    while value:
        out.insert(0, (value & 0x7F) | 0x80)
        value >>= 7
    return bytes(out)


def _event(body: bytes) -> bytes:
    return b"\x00\xF0" + _var(len(body)) + body


def _string(tag: int, text: str) -> bytes:
    return _event(b"\x00\x20\x33\x00\x00\x03\x00\x00" + bytes([tag]) + text.encode() + b"\x00\xF7")


def _parameters(page: int, first: int, values: list[int]) -> bytes:
    data = b"".join(bytes([v >> 7 & 0x7F, v & 0x7F]) for v in values)
    return _event(b"\x00\x20\x33\x00\x00\x02\x00" + bytes([page, first]) + data + b"\xF7")


def rig_events(name, amp=None, maker=None, model=None, gain=5.0, eq=(0, 0, 0, 0), modules=(), tempo=None) -> bytes:
    events = _string(1, name)
    for tag, text in ((16, amp), (21, maker), (24, model)):
        if text:
            events += _string(tag, text)
    events += _parameters(10, 2, [1, 8192, int(gain / 10 * 16383)])
    events += _parameters(11, 4, [8192 + int(v / 5 * 8192) for v in eq])
    for page, kind, on in modules:
        events += _parameters(page, 0, [kind, 0, 1, 1 if on else 0, 8192])
    if tempo:
        events += _parameters(4, 0, [tempo * 64, 0, 1])
    return events


def rig_file(events: bytes, header: bytes = b"KThd") -> bytes:
    return header + bytes([0, 0, 0, 6, 0, 0, 0, 1, 1, 0xE0]) + b"KTrk" + len(events).to_bytes(4, "big") + events


PLACEHOLDER = _string(1, "Crunch") + _string(16, "Crunch Amp") + _string(18, "AmpCreationDateTag") \
    + _parameters(10, 4, [8192])


def database(performances, slot_names=(), tmp_path=None) -> bytes:
    path = tmp_path / "fixture.kdb"
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE perflist (id INTEGER PRIMARY KEY AUTOINCREMENT, perfid INTEGER)")
    db.execute("CREATE TABLE perfs (id INTEGER PRIMARY KEY AUTOINCREMENT, perfdata BLOB)")
    db.execute("CREATE TABLE perfslots (id INTEGER PRIMARY KEY AUTOINCREMENT, perfid INTEGER NOT NULL, slot INTEGER, "
               "trackid INTEGER NOT NULL UNIQUE)")
    db.execute("CREATE TABLE perftracks (id INTEGER PRIMARY KEY AUTOINCREMENT, track BLOB)")
    track = 0
    for position, (name, slots) in enumerate(performances):
        header = b"".join(_event(b"\x00\x20\x33\x00\x00\x07\x00\x00\x00\x01\x00" + bytes([index]) + text.encode()
                                 + b"\x00\xF7") for index, text in enumerate([name, *slot_names]))
        db.execute("INSERT INTO perfs (id, perfdata) VALUES (?, ?)", (position + 1, header))
        db.execute("INSERT INTO perflist (perfid) VALUES (?)", (position + 1,))
        for slot, events in enumerate(slots):
            track += 1
            db.execute("INSERT INTO perftracks (id, track) VALUES (?, ?)", (track, events))
            db.execute("INSERT INTO perfslots (perfid, slot, trackid) VALUES (?, ?, ?)", (position + 1, slot, track))
    db.commit()
    db.close()
    data = path.read_bytes()
    path.unlink()
    return data


def tar(files) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, content in files:
            info = tarfile.TarInfo(name)
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
    return buffer.getvalue()


def _fill(rigs):
    return list(rigs) + [PLACEHOLDER] * (5 - len(rigs))


def test_reads_a_rig_file():
    events = rig_events("Plexi Rock", "JMP 50", "Marshall", "50w JMP", gain=7, eq=(-1, 2, 0.5, 1),
                        modules=[(50, 49, True), (60, 145, False)], tempo=96)
    for header in (b"KThd", b"MThd"):
        rig = kemper.rig_file(rig_file(events, header))
        assert rig.name == "Plexi Rock"
        assert rig.amp_description == "Marshall 50w JMP JMP 50"
        assert rig.gain == 7
        assert rig.signed_knob(11, 4) == -1 and rig.signed_knob(11, 5) == 2
        assert rig.tempo == 96
        assert [m.type_name for m in rig.modules] == ["Compressor", "Legacy Delay"]
        assert [m.is_on for m in rig.modules] == [True, False]
        assert not rig.is_placeholder


def test_rejects_other_files(tmp_path):
    with pytest.raises(kemper.KemperError):
        kemper.rig_file(b"not a rig at all")
    with pytest.raises(kemper.KemperError):
        kemper.read(tmp_path / "sound.json")
    assert kemper.rig_stream(PLACEHOLDER).is_placeholder


def test_reads_a_backup_with_performances(tmp_path):
    clean = rig_events("Clean", "Deluxe", "Fender", "Deluxe Reverb", gain=2)
    lead = rig_events("Solo", "Plexi", "Marshall", "Plexi", gain=7)
    data = database([("Wonderwall", _fill([clean, lead])), ("New Performance", [PLACEHOLDER] * 5)], tmp_path=tmp_path)
    found = kemper.backup(tar([("./Rigs/Clean - 2020.kipr", rig_file(clean)), ("./Stomp/Comp.kipr", rig_file(clean)),
                               ("./repository.kdb", data)]))
    assert [r.name for r in found.rigs] == ["Clean"], "only rigs from Rigs/"
    assert [p.name for p in found.performances] == ["Wonderwall", "New Performance"]
    assert [s.name if s else None for s in found.performances[0].slots] == ["Clean", "Solo", None, None, None]
    assert [p.name for p in found.own_performances] == ["Wonderwall"]


@pytest.mark.parametrize("amp, gain, model", [
    ("Dumble ODS", 3, "ODS50CN"), ("Marshall 50w JMP", 6, "Plexi"), ("Marshall 50w JMP", 2, "Plexi"),
    ("Divided By 13 LDW39", 2.5, "94MatchDCV2"), ("Fender Deluxe Reverb", 2, "Deluxe65"),
    ("AC30 VOX JMI", 4, "AC Boost"), ("EVH 5150III 50 watt", 7, "EVH"), ("Mesa Lonestar", 6, "OverDrivenLuxVerb"),
    ("Roland Jazz Chorus", 2, "RolandJC120"), ("Unknown Boutique", 8, "SLO100"),
    ("Unknown Boutique", 1, "94MatchDCV2"), ("3rd Power Dream Weaver Proto", 7, "Plexi"),
    ("3rd Power Dream Weaver Proto", 2, "ODS50CN")])
def test_amps_find_their_spark_model(amp, gain, model):
    assert kemper.translate(kemper.rig_file(rig_file(rig_events("Test", amp, gain=gain)))).amp_model == model


def test_gain_equalizer_and_effects_carry_over():
    rig = kemper.rig_file(rig_file(rig_events("Lead", "Marshall JMP", gain=7, eq=(-2, 1, 0, 2), modules=[
        (50, 49, True), (51, 115, True), (56, 101, True), (58, 70, True), (60, 146, True), (52, 33, False)])))
    result = kemper.translate(rig)
    amp = result.recipe["chain"]["amp"]["settings"]
    assert (amp["gain"], amp["bass"], amp["middle"], amp["treble"]) == (7, 3, 6, 6)
    assert result.character == "drive" and result.recipe["tags"] == ["kemper", "drive"]
    chain = result.recipe["chain"]
    assert [chain[p]["model"] for p in ("compressor", "drive", "modulation", "delay")] == \
        ["BlueComp", "Booster", "Tremolo", "DelayMono"]
    assert chain["delay"]["settings"]["effect"] == 2, "the Kemper's mix of 5, scaled for the Spark's level"
    assert result.left_out == ["Stereo Widener"], "the switched-off Green Scream is not mentioned"


def test_every_mapping_makes_a_valid_recipe():
    cat = catalog.load()
    for _, model, _ in kemper.AMP_RULES:
        assert cat.known(model) is not None, model
    for kind in sorted(kemper.EFFECT_TYPES):
        page = 61 if kind >= 177 else 60 if kind >= 145 else 50
        rig = kemper.rig_file(rig_file(rig_events(f"FX {kind}", "Fender Twin", gain=3, modules=[(page, kind, True)])))
        recipe.to_preset(kemper.translate(rig).recipe)


def _library(tmp_path):
    clean = rig_events("Comping", "LDW39", "Divided By 13", gain=2.5)
    solo = rig_events("Solo", "JMP", "Marshall", gain=7)
    data = database([("Can't Stop", _fill([clean, solo])), ("Quick Setup", _fill([clean, solo])),
                     ("Licks", _fill([solo]))], tmp_path=tmp_path)
    return kemper.backup(tar([("Rigs/Comping.kipr", rig_file(clean)), ("repository.kdb", data)]))


def test_the_plan_guesses_kinds_and_joins_equal_sounds(tmp_path):
    plan = kemper.Plan(_library(tmp_path))
    assert [p.kind for p in plan.performances] == ["song", "basis", "lesson"]
    assert [r.is_chosen for r in plan.rigs] == [False]
    assert [s.translation.recipe["name"] for s in plan.performances[0].slots] == \
        ["Can't Stop · Comping", "Can't Stop · Solo"]
    assert [s.translation.recipe["name"] for s in plan.performances[2].slots] == ["Licks"]
    plan.performances[1].slots = plan.performances[0].slots
    sounds, songs = plan.output()
    assert len(sounds) == 2
    comping = next(s for s in sounds if s.preset.name == "Can't Stop · Comping")
    assert comping.tags == ["kemper", "clean", "song", "CantStop", "basis", "QuickSetup"]
    assert [song.title for song in songs] == ["Can't Stop"]
    assert [name for name, _ in songs[0].parts] == ["Comping", "Solo"]


def test_slot_names_and_repeated_titles(tmp_path):
    rig = rig_events("72 Marshall", "JMP", "Marshall", gain=5)
    other = rig_events("Lead", "JMP", "Marshall", gain=8)
    data = database([("Live", _fill([rig, other])), ("Live", _fill([rig]))], slot_names=["Intro", ""], tmp_path=tmp_path)
    plan = kemper.Plan(kemper.backup(tar([("repository.kdb", data)])))
    assert [p.name for p in plan.performances] == ["Live 1", "Live 2"]
    assert [s.name for s in plan.performances[0].slots] == ["Intro", "Lead"]


def test_importing_twice_adds_nothing_and_songs_become_pieces(tmp_path):
    plan = kemper.Plan(_library(tmp_path))
    sounds, songs = plan.output()
    presets = library.PresetLibrary(tmp_path / "Presets", trash=lambda path: path.unlink())
    presets.reload()
    written, new = presets.import_kemper(sounds)
    assert new == len(sounds) == 2 and all(w.id for w in written)
    assert written[0].tags[:2] == ["kemper", "clean"] and "listen and adjust" in written[0].notes
    again, new_again = presets.import_kemper(sounds)
    assert new_again == 0 and len(presets.items) == 2
    assert ("kemper", 2) in presets.tag_counts()

    takes = storemod.LibraryStore(tmp_path / "Aufnahmen")
    takes.load()
    pieces = [{"title": s.title, "notes": s.notes, "parts": [
        {"name": n, "preset": {"presetID": written[i].id, "fileName": written[i].path.name, "name": written[i].name}}
        for n, i in s.parts]} for s in songs]
    assert storemod.add_imported_pieces(takes, pieces) == (1, [])
    assert storemod.add_imported_pieces(takes, pieces) == (0, ["Can't Stop"]), "an existing title is left alone"
    piece = takes.document["pieces"][0]
    assert [p["name"] for p in piece["parts"]] == ["Comping", "Solo"]
    assert piece["parts"][0]["preset"]["presetID"] == written[0].id


def test_tags_are_kept_without_the_hash():
    assert library.parse_tags("#Basis basis, #clean  ") == ["Basis", "clean"]
    assert kemper.hashtag("Can't Stop") == "CantStop" and kemper.hashtag("180er Band") == "180erBand"


def test_the_list_reads_like_the_mac(tmp_path, capsys):
    file = tmp_path / "all.kpabackup"
    clean = rig_events("Comping", "LDW39", "Divided By 13", gain=2.5)
    solo = rig_events("Solo", "JMP", "Marshall", gain=7)
    data = database([("Can't Stop", _fill([clean, solo])), ("Licks", _fill([solo]))], tmp_path=tmp_path)
    file.write_bytes(tar([("Rigs/Comping.kipr", rig_file(clean)), ("repository.kdb", data)]))
    assert kemper.list_file(str(file)) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[0] == "1 rigs, 2 performances, 2 of your own"
    assert lines[1] == "1. Can't Stop  [Song]" and "2. Licks  [Lessons]" in lines
    assert lines[2].startswith("   1 Comping → ") and lines[2].endswith("(“divided by 13”), clean")
    assert lines[-1] == "Result: 2 presets, 1 pieces"
    assert kemper.list_file(str(tmp_path / "nothing.txt")) == 1
    assert capsys.readouterr().out.startswith("not possible: “nothing.txt” is not a Kemper file")
    i18n.set_language(i18n.GERMAN)
    try:
        assert kemper.list_file(str(file)) == 0
        lines = capsys.readouterr().out.splitlines()
        assert lines[0] == "1 Rigs, 2 Performances, 2 eigene" and lines[-1] == "Ergebnis: 2 Presets, 1 Stücke"
        assert "2. Licks  [Unterricht]" in lines and list(kemper.KINDS) == ["song", "basis", "lesson", "skip"]
    finally:
        i18n.set_language(i18n.ENGLISH)
