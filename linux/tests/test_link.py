import asyncio

import pytest

from spark_studio import editor, factory, link, protocol
from spark_studio.fake_amp import FakeAmp


def run(coro):
    return asyncio.run(coro)


def make(amp=None, **kwargs):
    amp = amp or FakeAmp()
    events = []
    core = link.LinkCore(lambda: amp, lambda *a: events.append(a), gap=0.0, silence=0.5, **kwargs)
    return amp, core, events


async def connected(core, amp):
    core.start()
    for _ in range(300):
        await asyncio.sleep(0.01)
        if core.status == "connected" and all(core.slots) and core.activity is None:
            return
    raise AssertionError(f"not ready: {core.status} {core.slots}")


def test_connects_and_reads_the_amp():
    async def go():
        amp, core, _ = make()
        await connected(core, amp)
        assert core.firmware == "1.11.2.75" and core.device_name == "Spark MINI" and core.active_slot == 0
        for slot in range(4):
            assert core.slots[slot].same_content(amp.slots[slot])
        await core.stop()
        assert core.status == "off"
    run(go())


def test_select_try_out_and_store_with_readback():
    async def go():
        amp, core, _ = make()
        await connected(core, amp)
        await core.select(2)
        assert core.active_slot == 2 and amp.active == 2
        new = factory.empty("Probe")
        await core.try_out(new)
        assert core.trying_out == "Probe" and core.active_slot is None and amp.temporary.name == "Probe"
        await core.store(new, 1)
        assert amp.slots[1].name == "Probe" and core.active_slot == 1 and core.slots[1].name == "Probe"
        await core.stop()
    run(go())


def test_live_editing_sends_parameters_and_waits_for_acks():
    async def go():
        amp, core, _ = make()
        await connected(core, amp)
        ed = editor.PresetEditor(factory.empty("Live"))
        await core.play_for_editing(ed.current)
        assert core.is_editing_live
        for change in ed.set_parameter(3, 0, 0.8):
            assert await core.apply(change)
        assert amp.parameters == [("Twin", 0, pytest.approx(0.8))]
        for change in ed.set_on(2, True) + ed.set_model(4, "Flanger")[:1]:
            assert await core.apply(change) is True
        await core.stop()
    run(go())


def test_a_request_the_amp_ignores_is_asked_again():
    async def go():
        amp, core, _ = make(FakeAmp(drop_first_answer=True))
        await connected(core, amp)
        assert core.firmware == "1.11.2.75"
        await core.stop()
    run(go())


def test_button_on_the_amp_is_reported():
    async def go():
        amp, core, events = make()
        await connected(core, amp)
        amp.press_button(3)
        await asyncio.sleep(0.05)
        assert core.active_slot == 3 and ("amp_selected", 3) in events
        await core.stop()
    run(go())


def test_lost_connection_ends_live_editing_and_connects_again():
    async def go():
        amp, core, events = make()
        await connected(core, amp)
        await core.play_for_editing(factory.empty())
        events.clear()
        amp.drop_connection()
        await connected(core, amp)
        assert ("is_editing_live", False) in events and ("status", "searching") in events
        assert not core.is_editing_live
        await core.stop()
    run(go())


def test_requests_fail_cleanly_when_not_connected():
    async def go():
        amp, core, _ = make()
        core._lock = asyncio.Lock()
        with pytest.raises(link.NotConnected):
            await core.select(1)
    run(go())
