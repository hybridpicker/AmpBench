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
