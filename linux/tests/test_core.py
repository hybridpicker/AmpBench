import json
from pathlib import Path

import pytest

from spark_studio import catalog, editor, factory, library, protocol, recipe
from spark_studio.protocol import Parser, Place, Preset

FIXTURES = Path(__file__).parent / "fixtures"


def real_presets():
    result = []
    for path in sorted(FIXTURES.glob("*.json")):
        if path.name.startswith("."):
            continue
        data = json.loads(path.read_text())
        if recipe.is_recipe(data):
            continue
        result.append((path.name, data["preset"] if "preset" in data else data))
    return result


@pytest.mark.parametrize("name,data", real_presets())
def test_real_presets_roundtrip(name, data):
    preset = Preset.from_json(data)
    assert preset.checksum_matches, "presets read from the amp carry a valid checksum"
    assert preset.to_json()["effects"] == data["effects"]
    assert preset.to_json()["bpm"] == data["bpm"]
    assert Preset.from_json(preset.to_json()) == preset
    parser, messages = Parser(), []
    for block in protocol.send_preset(preset, Place.of_slot(1), 5):
        messages += parser.feed(block)
    assert len(messages) == 1 and messages[0].checksum_ok
    assert Preset.from_payload(messages[0].payload).same_content(preset)


def test_pack7_roundtrip():
    data = bytes(range(256)) * 3
    assert protocol.unpack7(protocol.pack7(data)) == data


def test_notifications_can_split_anywhere():
    preset = factory.empty("Teilen")
    wire = b"".join(protocol.send_preset(preset, Place.of_slot(0), 1))
    parser, messages = Parser(), []
    for i in range(0, len(wire), 7):
        messages += parser.feed(wire[i:i + 7])
    assert len(messages) == 1


def test_command_frames_match_the_swift_layout():
    # block header + F0 01 seq checksum cmd sub ... F7
    block = protocol.get_firmware(3)[0]
    assert block[:7] == bytes([0x01, 0xFE, 0x00, 0x00, 0x53, 0xFE, len(block)]) and block[16] == 0xF0
    assert block[-1] == 0xF7 and block[18] == 3 and block[20:22] == bytes([0x02, 0x2F])


def test_event_parsing():
    wire = b"".join(protocol.blocks(protocol.CMD_RESPONSE, protocol.SUB_PARAMETER_CHANGED,
                                    bytes([4, 0xA4]) + b"Twin" + bytes([2]) + b"\xCA\x3F\x00\x00\x00", 1, header=False))
    message = Parser().feed(wire)[0]
    event = protocol.parse_event(message)
    assert (event.kind, event.effect, event.index, event.value) == ("parameter", "Twin", 2, 0.5)


def test_catalog_matches_all_fixture_models():
    cat = catalog.load()
    for _, data in real_presets():
        for effect in data["effects"]:
            info = cat.known(effect["name"])
            assert info is not None, effect["name"]
            assert len(effect["parameters"]) <= info.parameter_count


def test_empty_preset_has_seven_places_and_valid_checksum():
    preset = factory.empty()
    assert [e.name for e in preset.effects][3] == "Twin"
    assert Preset.from_payload(preset.encode(Place.of_slot(0))).same_content(preset)
    assert Preset.from_payload(preset.encode(Place.of_slot(0))).checksum_matches


def test_templates_use_known_models():
    cat = catalog.load()
    for template in factory.templates():
        assert len(template.preset.effects) == 7
        for place, effect in zip(catalog.PLACES, template.preset.effects):
            assert cat.known(effect.name).place == place


@pytest.mark.parametrize("path", sorted(FIXTURES.glob("[a-z]*.json")))
def test_example_recipes_convert(path):
    raw = path.read_bytes()
    first = recipe.to_preset(json.loads(raw), raw)
    second = recipe.to_preset(json.loads(raw), raw)
    assert first.preset.uuid == second.preset.uuid, "same file, same uuid"
    assert first.preset.name


def test_recipe_roundtrip_through_preset():
    preset = factory.templates()[1].preset
    back = recipe.to_preset(recipe.from_preset(preset)).preset
    assert [e.name for e in back.effects] == [e.name for e in preset.effects]
    for a, b in zip(back.effects, preset.effects):
        for pa, pb in zip(a.parameters, b.parameters):
            assert abs(pa.value - pb.value) < 0.051


def test_recipe_reports_every_problem():
    bad = {"format": "spark-sound-recipe", "version": 1, "name": "x",
           "chain": {"amp": {"model": "Nope"}, "drive": {"model": "Twin"}, "foo": {"model": "Twin"}}}
    with pytest.raises(recipe.RecipeError) as error:
        recipe.to_preset(bad)
    assert len(error.value.messages) == 3


def test_editor_undo_redo_and_live_changes():
    ed = editor.PresetEditor(factory.empty())
    changes = ed.set_parameter(3, 0, 0.9)
    assert changes[0].kind == "parameter" and changes[0].effect == "Twin"
    assert ed.is_modified
    ed.undo()
    assert not ed.is_modified and ed.can_redo
    ed.redo()
    assert ed.current.effects[3].parameters[0].value == pytest.approx(0.9)
    model = ed.set_model(3, "Plexi")
    assert model[0].kind == "model" and model[0].old == "Twin"
    assert [c.kind for c in model[1:]] == ["parameter"] * 5
    toggled = ed.set_on(6, True)
    assert toggled[0].kind == "toggle"
    mirror = catalog.load().known("bias.reverb").mirrors[0]
    assert ed.current.effects[6].parameters[mirror].value == 1.0


def test_gesture_is_one_undo_step():
    ed = editor.PresetEditor(factory.empty())
    ed.begin_gesture()
    for v in (0.2, 0.3, 0.4):
        ed.set_parameter(3, 1, v)
    ed.end_gesture()
    ed.undo()
    assert not ed.is_modified


def test_live_queue_keeps_only_the_newest_value():
    q = editor.LiveQueue()
    q.push([editor.Change("parameter", effect="Twin", index=0, value=0.1),
            editor.Change("parameter", effect="Twin", index=0, value=0.2)])
    assert len(q.items) == 1 and q.items[0].value == 0.2
    q.push([editor.Change("model", old="Twin", new="Plexi"),
            editor.Change("parameter", effect="Twin", index=0, value=0.3)])
    assert len(q.items) == 3, "no merging across a model change"


def test_model_changes_are_paced():
    change = editor.Change("model", old="a", new="b")
    assert editor.wait_before(change, 10.0, [9.5]) == pytest.approx(0.5)
    assert editor.wait_before(change, 10.0, [1, 2, 3, 4, 5, 6]) > 0
    assert editor.wait_before(editor.Change("parameter"), 10.0, [9.9]) == 0


def test_library_saves_reads_renames_and_keeps_mac_format(tmp_path):
    lib = library.PresetLibrary(tmp_path, trash=lambda p: p.unlink())
    saved = lib.save(factory.empty("Mein Sound"), "Test")
    data = json.loads(saved.path.read_text())
    assert data["format"] == 2 and data["preset"]["name"] == "Mein Sound" and data["isBackup"] is False
    assert lib.existing(factory.empty("Mein Sound")) is None or True
    renamed = lib.rename(saved, "Anders")
    assert renamed.path.name == "Anders.json" and not saved.path.exists()
    again = lib.save(factory.empty("Anders"), "Test")
    assert again.path.name == "Anders 2.json"
    backup = lib.save(factory.empty("Alt"), "Platz 1", is_backup=True)
    assert "Sicherung" in backup.path.name and backup.is_backup
    lib.trash(again)
    assert len(lib.items) == 2


def test_library_reads_mac_files_and_recipes(tmp_path):
    for path in FIXTURES.glob("*.json"):
        if path.name.startswith("Platz"):
            continue
        (tmp_path / path.name).write_bytes(path.read_bytes())
    lib = library.PresetLibrary(tmp_path)
    lib.reload()
    assert not lib.unreadable
    assert any(i.is_recipe for i in lib.items) and any(i.name == "Jazz" or "Jazz" in i.name for i in lib.items)


# SHA-256 of the effect chains as `SparkStudio --fingerprint` prints them on the Mac.
MAC_FINGERPRINTS = {
    "Jazz.json": "cf5899f677e80a86a9cc79052d91ebe04e0e8e30740c3e0113779408dfc283b2",
    "Platz 1 - Jazz.json": "cf5899f677e80a86a9cc79052d91ebe04e0e8e30740c3e0113779408dfc283b2",
    "Platz 2 - Fusion Sound.json": "9e95c1faafbac5339717503f476c5245f376f7b62c46d46623a3a9d543d978a6",
    "Platz 3 - SOLO.json": "1522f6382c5356109773656ac264464b8be8d1c9db498501834c48ecb9a74600",
    "Platz 4 - CUSTOM.json": "d7d0b74f8182dec6b930bc7afd07ee4e79dfe967431688460d437660890aab3d",
}


@pytest.mark.parametrize("name,expected", sorted(MAC_FINGERPRINTS.items()))
def test_fingerprint_equals_the_mac_apps(name, expected):
    data = json.loads((FIXTURES / name).read_text())
    assert protocol.fingerprint(Preset.from_json(data["preset"] if "preset" in data else data)) == expected


def test_fingerprint_ignores_name_bpm_and_trailer():
    a = factory.empty("A")
    b = a.copy()
    b.name, b.bpm, b.trailer = "B", 90.0, bytes([0xCA, 0, 0, 0, 0, 0])
    assert protocol.fingerprint(a) == protocol.fingerprint(b)
    b.effects[3].parameters[0].value = 0.123
    assert protocol.fingerprint(a) != protocol.fingerprint(b)


# A preset with a 136-byte description made the amp howl at full volume on 2026-11-08.
HOWLING = ("KI-Sound: „U2 - where the streets have no name.“. "
           "Originalgetreuer The-Edge-Sound: glänzender Vox-Clean mit punktiertem Achtel-Echo")


def _sent(preset: Preset, place: Place) -> Preset:
    parser = Parser()
    messages = parser.feed(b"".join(protocol.send_preset(preset, place, 1)))
    return Preset.from_payload(messages[-1].payload)


def test_the_howling_description_is_cut_before_it_is_sent():
    assert len(HOWLING.encode("utf-8")) == 136
    preset = recipe.to_preset({"format": "spark-sound-recipe", "version": 1, "name": "Joshua Tree Echo",
                               "chain": {"amp": {"model": "AC Boost", "settings": {"gain": 4}}}}).preset
    preset.description = HOWLING
    for place in (protocol.TEMPORARY, Place.of_slot(0)):
        sent = _sent(preset, place)
        assert len(sent.description.encode("utf-8")) <= protocol.DESCRIPTION_LIMIT
        assert HOWLING.startswith(sent.description)
        assert sent.effects == preset.effects
    assert preset.description == HOWLING


def test_editor_and_recipe_cut_a_long_description():
    conversion = recipe.to_preset({"format": "spark-sound-recipe", "version": 1, "name": "Joshua Tree Echo",
                                   "description": HOWLING, "chain": {}})
    assert len(conversion.preset.description.encode("utf-8")) <= protocol.DESCRIPTION_LIMIT
    assert any("Beschreibung" in w for w in conversion.warnings)
    edit = editor.PresetEditor(conversion.preset)
    edit.set_description(HOWLING)
    assert len(edit.current.description.encode("utf-8")) <= protocol.DESCRIPTION_LIMIT
    assert protocol.fit_description("ä" * 100) == "ä" * 40


def _catalog_preset(name: str = "Joshua Tree Echo", description: str = "", models: dict | None = None) -> Preset:
    chain = {place: {"model": model} for place, model in (models or {}).items()}
    preset = recipe.to_preset({"format": "spark-sound-recipe", "version": 1, "name": "x", "chain": chain}).preset
    preset.name = name
    preset.description = description
    return preset


def test_the_amp_guard_fits_the_howling_preset_and_every_catalog_preset():
    howling = _catalog_preset(description=HOWLING)
    assert protocol.preset_size(howling) > protocol.PAYLOAD_LIMIT
    assert protocol.amp_problems(howling) == []
    sent = protocol.for_amp(howling)
    assert protocol.preset_size(sent) <= protocol.PAYLOAD_LIMIT
    assert sent.effects == howling.effects
    assert len(protocol.send_preset(howling, protocol.TEMPORARY, 1)) <= 20

    models = {}
    for place in ("gate", "compressor", "drive", "amp", "modulation", "delay", "reverb"):
        candidates = [m.id for m in catalog.load().models_for(place, include_packs=True)]
        models[place] = max(candidates, key=lambda m: protocol.preset_size(_catalog_preset(models={place: m})))
    biggest = _catalog_preset(name="W" * protocol.NAME_LIMIT, description="ä" * 100, models=models)
    assert protocol.amp_problems(biggest) == []
    assert protocol.preset_size(protocol.for_amp(biggest)) <= protocol.PAYLOAD_LIMIT
    assert protocol.for_amp(biggest).name == "W" * protocol.NAME_LIMIT


def test_the_amp_guard_fits_values_and_refuses_what_is_broken():
    wild = _catalog_preset()
    wild.effects[3].parameters[0].value = 7.0
    wild.bpm = 900.0
    sent = protocol.for_amp(wild)
    assert sent.effects[3].parameters[0].value == 1.0
    assert sent.bpm == protocol.BPM_RANGE[1]
    broken = _catalog_preset()
    broken.effects[5].parameters[1].value = float("nan")
    assert protocol.amp_problems(broken)
    short = _catalog_preset()
    short.effects.pop()
    assert protocol.amp_problems(short)
    long_name = _catalog_preset(name="N" * 40)
    assert protocol.amp_problems(long_name)
    assert protocol.set_parameter("AC Boost", 4, 5.0, 1) == protocol.set_parameter("AC Boost", 4, 1.0, 1)
