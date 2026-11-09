"""Device profiles, the REACTOR's reports and the link with several devices: the Linux side of DeviceProfileTests,
ReactorDecoderTests and SparkLinkTests. Synthetic data only."""
import asyncio
import struct

import pytest

from spark_studio import devices, factory, link, protocol
from spark_studio.devices import ReactorState
from spark_studio.fake_amp import FakeAmp, FakeDevices


# MARK: Profiles


def test_known_devices_and_what_was_checked():
    assert devices.SPARK_MINI.slot_count == 4 and devices.SPARK_MINI.checked_firmware == "1.11.2.75"
    assert devices.SPARK_NEO.slot_count == 4 and devices.SPARK_NEO.checked_firmware == "1.16.1.60"
    assert devices.REACTOR_50.slot_count == 8 and devices.REACTOR_50.bank_size == 4
    assert devices.REACTOR_50.checked_firmware is None
    assert devices.LARGEST_SLOT_COUNT == 8


def test_the_neo_loses_its_temporary_sound_and_the_mini_counts_the_same_until_checked():
    assert devices.SPARK_NEO.keeps_temporary_after_disconnect is False
    assert devices.SPARK_MINI.keeps_temporary_after_disconnect is None
    assert devices.SPARK_NEO.loses_temporary_on_disconnect and devices.SPARK_MINI.loses_temporary_on_disconnect
    assert not any(p.confirms_parameters for p in devices.ALL)


def test_the_reactor_may_only_be_listened_to():
    for profile in (devices.REACTOR_50, devices.REACTOR_100):
        assert profile.can(devices.LISTEN) and not profile.can_send
        for capability in (devices.READ, devices.SWITCH_SLOT, devices.PLAY_TEMPORARY, devices.LIVE_EDIT,
                           devices.STORE, devices.MODEL_CHANGE):
            assert not profile.can(capability)
    unknown = devices.UNKNOWN_SPARK
    assert unknown.can(devices.READ) and unknown.can(devices.SWITCH_SLOT) and not unknown.can(devices.PLAY_TEMPORARY)


def test_recognition():
    assert devices.for_advertisement("ffc0", "Spark NEO Control").id == "spark_neo"
    assert devices.for_advertisement("ffc0", "Spark MINI BLE").id == "spark_mini"
    assert devices.for_advertisement("ffc0", "Spark 40 Audio").id == "unknown_spark"
    assert devices.for_advertisement(devices.REACTOR_SERVICE_UUID, "Reactor 50 Probenraum").id == "reactor50"
    assert devices.for_advertisement("ffd0", "Reactor 100 X").id == "reactor100"
    assert devices.for_advertisement("ffd0", "Spark MINI").id == "reactor50"
    assert devices.for_amp_name("Spark NEO").id == "spark_neo"
    assert devices.for_amp_name("Spark 40") is None


def test_names_slots_and_usb():
    assert devices.loggable_name("Reactor 50 Probenraum") == "Reactor 50"
    assert devices.loggable_name("Reactor 100 Bühne") == "Reactor 100"
    assert devices.loggable_name("Spark NEO Control") == "Spark NEO Control"
    assert devices.REACTOR_50.slot_name(0) == "Rot 1" and devices.REACTOR_50.slot_name(7) == "Grün 4"
    assert devices.SPARK_NEO.slot_name(2) == "Platz 3"
    assert devices.recordable_usb_names() == ["spark"]


# MARK: The REACTOR's reports


def wire(sub, payload, command=protocol.CMD_RESPONSE):
    return protocol.frame(command, sub, bytes(payload), 0x10, header=False)


def parameter(block, index, value):
    name = block.encode()
    return wire(protocol.SUB_PARAMETER_CHANGED, bytes([len(name), 0xA0 + len(name)]) + name + bytes([index, 0xCA])
                + struct.pack(">f", value))


def on_off(model, is_on):
    name = model.encode()
    return wire(protocol.SUB_EFFECT_ON_OFF, bytes([len(name), 0xA0 + len(name)]) + name + bytes([0xC3 if is_on else 0xC2]))


def number(sub, value, prefix=b""):
    return wire(sub, prefix + b"\xCA" + struct.pack(">f", value))


def decode(frames, state):
    parser = protocol.Parser()
    data = b"".join(frames)
    for start in range(0, len(data), 7):
        for message in parser.feed(data[start:start + 7]):
            state.apply(message)


def test_amp_knobs_selector_and_unknown_messages():
    state = ReactorState()
    decode([parameter("Amp.Preamp", 0, 0.62), wire(0x1A, [0x91, 0x00, 0x02, 0xC3]), parameter("Amp.Tonestack", 1, 0.3),
            parameter("Amp.Tonestack", 3, 0.8), parameter("Amp.Poweramp", 0, 0.5), wire(devices.SUB_AMP_SELECTOR, [3, 7])],
           state)
    assert state.knobs["gain"] == pytest.approx(0.62) and state.knobs["master"] == pytest.approx(0.5)
    assert state.amp_name == "Crunch" and state.voice_name == "Standard" and state.heat == 2
    assert state.unknown == {"03 1A": 1}
    decode([wire(devices.SUB_AMP_SELECTOR, [5, 12])], state)
    assert state.amp_name == "Extreme" and state.voice_name == "Smooth" and state.heat == 2


def test_fx_keys_tap_and_tuner():
    state = ReactorState()
    decode([on_off("MonoReverb", True), wire(devices.SUB_SELECTED_EFFECT, [6, 0xC3]), parameter("MonoReverb", 0, 0.4),
            on_off("DistortionTS9", False), number(protocol.SUB_TAP_TEMPO, 116)], state)
    assert state.effects["MonoReverb"].place == 6 and state.effects["MonoReverb"].level == pytest.approx(0.4)
    assert state.effects["DistortionTS9"].place == 2  # from the catalog
    assert state.selected_place == 6 and state.tempo == pytest.approx(116)
    decode([wire(protocol.SUB_TUNER, [0xC3]), number(protocol.SUB_TUNER_PITCH, -1, b"\x00")], state)
    assert state.tuner_on and state.tuner_reading is None
    decode([wire(protocol.SUB_TUNER, [0xC2])], state)
    assert not state.tuner_on


def test_a_slot_change_makes_the_content_unknown():
    state = ReactorState()
    decode([parameter("Amp.Preamp", 0, 0.7), wire(protocol.SUB_HARDWARE_PRESET, [0, 1]),
            wire(protocol.SUB_HARDWARE_PRESET, [0, 1])], state)
    assert state.slot == 1 and not state.has_readings
    decode([parameter("Amp.Tonestack", 3, 0.25), wire(protocol.SUB_HARDWARE_PRESET, [0, 1])], state)
    assert state.knobs == {"treble": 0.25}
    decode([wire(protocol.SUB_HARDWARE_PRESET, [0, 7])], state)
    assert state.slot == 7 and state.bank == 1 and state.knobs == {}
    decode([wire(protocol.SUB_HARDWARE_PRESET, [0, 8])], state)
    assert state.slot == 7


def test_the_readings_in_words_match_the_mac():
    state = ReactorState()
    decode([wire(protocol.SUB_HARDWARE_PRESET, [0, 4]), wire(devices.SUB_AMP_SELECTOR, [4, 3]),
            parameter("Amp.Preamp", 0, 0.75), on_off("ChorusCloner", True), wire(devices.SUB_SELECTED_EFFECT, [4, 0xC3]),
            parameter("ChorusCloner", 0, 0.5), number(protocol.SUB_TAP_TEMPO, 120)], state)
    assert [f"{a}: {b}" for a, b in state.lines()] == [
        "Platz: Grün 1", "Amp: Hi-Gain", "Push/Smooth: Push", "Heat: 4 von 5", "Gain: 7,5",
        "Mod ChorusCloner: an, Level 5,0", "Tempo: 120 BPM"]


# MARK: The link


def make(transport):
    events = []
    core = link.LinkCore(lambda: transport, lambda *a: events.append(a), gap=0.0, silence=0.4)
    return core, events


async def until(condition, seconds=5.0):
    for _ in range(int(seconds / 0.01)):
        if condition():
            return True
        await asyncio.sleep(0.01)
    return condition()


def test_the_neo_is_named_read_and_followed():
    async def go():
        amp = FakeAmp(kind="neo")
        core, events = make(amp)
        core.start()
        assert await until(lambda: core.status == "connected" and all(core.slots) and core.activity is None)
        assert core.profile.id == "spark_neo" and core.device_name == "Spark NEO" and core.firmware == "1.16.1.60"
        assert len(core.slots) == 4 and amp.listen_only is False
        amp.press_button(3)  # the middle button
        assert await until(lambda: core.active_slot == 3)
        assert ("amp_selected", 3) in events
        await core.stop()
    asyncio.run(go())


def test_the_neo_drops_its_temporary_sound_when_the_connection_ends():
    async def go():
        amp = FakeAmp(kind="neo")
        core, events = make(amp)
        core.start()
        assert await until(lambda: core.status == "connected" and all(core.slots) and core.activity is None)
        amp.active = 2
        await core.select(2)
        await core.play_for_editing(factory.empty("Probe"))
        assert core.is_editing_live and amp.temporary.name == "Probe"
        amp.drop_connection()
        assert await until(lambda: ("temporary_lost", "Spark NEO") in events)
        assert not core.is_editing_live and core.trying_out is None
        # Back by itself: what plays is read, not assumed.
        assert await until(lambda: core.status == "connected" and core.active_slot == 2 and core.activity is None)
        assert amp.temporary is None
        await core.stop()
    asyncio.run(go())


def test_the_reactor_gets_not_a_single_byte():
    async def go():
        amp = FakeAmp(kind="reactor")
        core, events = make(amp)
        core.start()
        assert await until(lambda: core.status == "connected")
        assert core.profile.id == "reactor50" and len(core.slots) == 8 and amp.listen_only is True
        assert core.device_name == "Reactor 50 Proberaum" and core.loggable_name == "Reactor 50"
        await core.load_all()
        await core.refresh(0)
        for attempt in (core.select(1), core.try_out(factory.empty("X")), core.play_for_editing(factory.empty("X")),
                        core.store(factory.empty("X"), 0), core.read_preset(protocol.PLAYING)):
            with pytest.raises(link.LinkError):
                await attempt
        await asyncio.sleep(0.1)
        assert amp.written == []
        amp.press_button(5)
        amp.report(devices.SUB_AMP_SELECTOR, bytes([3, 7]))
        assert await until(lambda: core.reactor.amp_name == "Crunch")
        assert core.active_slot == 5 and amp.written == []
        await core.stop()
        assert amp.written == []
    asyncio.run(go())


def test_an_unknown_spark_only_reads_and_switches():
    async def go():
        amp = FakeAmp(kind="unknown")
        core, _ = make(amp)
        core.start()
        assert await until(lambda: core.status == "connected" and all(core.slots) and core.activity is None)
        assert core.profile.id == "unknown_spark" and core.device_name == "Spark 40"
        await core.select(1)
        with pytest.raises(link.NotSupported):
            await core.try_out(factory.empty("X"))
        await core.stop()
    asyncio.run(go())


def test_choosing_another_device_ends_the_old_connection_first():
    async def go():
        mini, neo = FakeAmp(kind="mini"), FakeAmp(kind="neo")
        radio = FakeDevices([mini, neo])
        core, _ = make(radio)
        core.start()
        assert await until(lambda: core.status == "connected" and core.profile.id == "spark_mini"
                            and core.activity is None)
        core.choose(neo.address)
        assert await until(lambda: core.status == "connected" and core.profile.id == "spark_neo"
                           and core.activity is None)
        assert not mini.connected and neo.connected and core.chosen == neo.address
        await core.stop()
    asyncio.run(go())


# MARK: Text for REACTOR


def test_the_text_for_reactor_matches_the_mac():
    import json
    from pathlib import Path
    from spark_studio import recipe
    data = json.loads((Path(__file__).resolve().parents[2] / "docs/ai/examples/texas-blues.json").read_text())
    # Written by the Mac's `SparkStudio --recipe-prompt docs/ai/examples/texas-blues.json`.
    assert recipe.tone_description(data) == 'Guitar tone “Texas Blues: Edge-of-breakup combo pushed by a mid drive”, 96 BPM.\nDrive pedal: Ibanez TS9 style pedal, drive 3/10, tone 5.5/10, level 7/10.\nAmp: Fender Bassman ’59 style amp, gain 5/10, treble 6/10, middle 6.5/10, bass 4.5/10, master 7/10.\nReverb: room reverb, level 2.5/10, length 4/10.\nNotes: Tweed combo just breaking up, the mid drive adds push rather than gain. Too fizzy: lower drive.drive to 2. Too clean on the neck pickup: raise amp.gain to 6.\n'
