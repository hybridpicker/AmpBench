"""KI-Sound: the prompt's knowledge, the wish check, corrections, variants, quick changes and the HTTP client. A port
of Tests/SparkControlTests/SoundAIConversationTests.swift. Every chat and every HTTP answer is faked; nothing here
uses the network."""
import json
import threading
import time
import urllib.error

import pytest

from spark_studio import catalog, recipe as recipemod, sound_ai


class ScriptedChat:
    """Hands out prepared answers in order and records what was asked."""

    def __init__(self, answers):
        self.answers, self.calls = list(answers), []
        self.lock = threading.Lock()

    def __call__(self, messages, temperature):
        with self.lock:
            self.calls.append(list(messages))
            return self.answers.pop(0) if self.answers else ""


class ScriptedTransport:
    """Answers HTTP requests from a prepared list and counts them."""

    def __init__(self, steps):
        self.steps, self.requests = list(steps), []

    def __call__(self, request):
        self.requests.append(request)
        step = self.steps.pop(0) if self.steps else (500, b"")
        if isinstance(step, Exception):
            raise step
        return step


def ok(content):
    return 200, json.dumps({"message": {"role": "assistant", "content": content}}).encode()


def recipe(name="Test", amp="Plexi", gain=6, treble=6, drive=None, reverb_level=3):
    chain = {"amp": {"model": amp, "settings": {"gain": gain, "treble": treble, "middle": 5, "bass": 5, "master": 7}}}
    if drive:
        chain["drive"] = {"model": drive}
    chain["reverb"] = ({"model": "bias.reverb", "settings": {"level": reverb_level}} if reverb_level is not None
                       else {"model": "bias.reverb", "on": False})
    return json.dumps({"format": "spark-sound-recipe", "version": 1, "name": name, "bpm": 120, "chain": chain})


# MARK: Knowledge in the prompt


def test_examples_in_the_prompt_are_valid_recipes():
    assert len(sound_ai.EXAMPLES) >= 3
    for wish, text in sound_ai.EXAMPLES:
        conversion = recipemod.to_preset(sound_ai.parse(text))
        assert conversion.warnings == [], wish


def test_archetypes_use_only_free_catalog_models_in_chain_order():
    cat = catalog.load()
    assert len(sound_ai.ARCHETYPES) >= 20
    for topic, models, _ in sound_ai.ARCHETYPES:
        infos = [cat.known(m) for m in models]
        assert all(info is not None and not info.pack for info in infos), topic
        places = [catalog.PLACES.index(info.place) for info in infos]
        assert places == sorted(places) and len(set(places)) == len(places), topic


def test_system_prompt_carries_players_tempo_reverb_examples_and_catalog():
    prompt = sound_ai.messages("x")[0]["content"]
    for part in ("The Edge (U2)", "punktierte Achtel", "Songtempo × 4/3", "Hall nach Stil", '"name":"Streets Echo"',
                 "(Schlüssel: amp)", "`gain` (0–10)"):
        assert part in prompt, part


def test_variants_have_three_different_directions():
    assert len(set(sound_ai.VARIANT_HINTS)) == 3 == len(sound_ai.VARIANT_TITLES)


# MARK: The wish


def test_ordinary_wishes_pass():
    for wish in ("U2 – Where the Streets Have No Name", "Bryan Adams – Summer of '69", "Van Halen 5150 aus 1984",
                 "Metallica – Enter Sandman (1991), 123 BPM", "Drop-D-Riff in 7/8 bei 140 bpm",
                 "Where-the-streets-have-no-name-2"):
        assert sound_ai.checked_request(wish) == wish


def test_wishes_with_personal_data_or_secrets_are_refused():
    for wish in ("Sound für max.mustermann@example.com", "Ruf mich an: +43 664 1234567",
                 "Blues, Rückfrage unter 0664/1234567", "Mein Schlüssel 3f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c"):
        with pytest.raises(sound_ai.AIError) as error:
            sound_ai.checked_request(wish)
        assert error.value.kind == "privacy", wish


def test_empty_and_overlong_wishes_are_refused_and_send_nothing():
    for wish, kind in (("   ", "empty_request"), ("a" * (sound_ai.REQUEST_LIMIT + 1), "too_long")):
        with pytest.raises(sound_ai.AIError) as error:
            sound_ai.checked_request(wish)
        assert error.value.kind == kind
    chat = ScriptedChat([recipe()])
    with pytest.raises(sound_ai.AIError):
        sound_ai.variants("Ruf an: +43 664 1234567", chat, lambda *a: None, lambda *a: None)
    assert chat.calls == []


def test_history_puts_the_newest_first_once_and_stays_short():
    history = [f"Wunsch {i}" for i in range(8)]
    assert sound_ai.remember("wunsch 3", history)[:2] == ["wunsch 3", "Wunsch 0"]
    assert len(sound_ai.remember("neu", history)) == 8


def test_keepsake_carries_the_wish_and_tags():
    kept = sound_ai.keepsake(sound_ai.parse(sound_ai.EXAMPLES[1][1]), "AC/DC – Back in Black", ["warmer", "moreGain"])
    assert kept["description"].startswith("KI-Sound: „AC/DC – Back in Black“")
    assert kept["tags"] == ["AC/DC", "Rock", "Crunch", "KI-Sound", "wärmer", "mehr Gain"]
    long = sound_ai.keepsake(sound_ai.parse(recipe()), "x" * 150)
    assert len(long["description"].encode()) <= 80 and long["description"].endswith("…“")


# MARK: Conversation


def test_an_answer_without_json_is_sent_back_once():
    chat = ScriptedChat(["Gern! Hier ist dein Sound.", recipe(name="Zweiter Versuch")])
    data, unresolved = sound_ai.converse(sound_ai.messages("Rock"), chat, 0.4)
    assert data["name"] == "Zweiter Versuch" and unresolved is None
    assert "kein JSON-Objekt" in chat.calls[1][-1]["content"]


def test_repeated_prose_ends_with_a_hint_about_the_model():
    with pytest.raises(sound_ai.AIError) as error:
        sound_ai.converse(sound_ai.messages("Rock"), ScriptedChat(["nur Text"] * 3), 0.4)
    assert error.value.kind == "no_json" and "anderes Modell" in str(error.value)


def test_a_wrong_model_id_is_sent_back_with_the_error():
    wrong = json.loads(recipe())
    wrong["chain"]["amp"]["model"] = "Marshall"
    chat = ScriptedChat([json.dumps(wrong), recipe()])
    data, _ = sound_ai.converse(sound_ai.messages("Rock"), chat, 0.4)
    assert data["chain"]["amp"]["model"] == "Plexi"
    assert "„Marshall“ gibt es nicht" in chat.calls[1][-1]["content"]


def wait_for(condition, timeout=3.0):
    end = time.time() + timeout
    while time.time() < end and not condition():
        time.sleep(0.01)
    return condition()


def test_variants_arrive_and_a_sound_alike_one_is_sent_back():
    chat = ScriptedChat([recipe(name="A", amp="Plexi"), recipe(name="B", amp="Plexi"), recipe(name="C", amp="Twin"),
                         recipe(name="B2", amp="SLO100")])
    ready, failed = {}, {}
    sound_ai.variants("Rock", chat, lambda i, d: ready.__setitem__(i, d), lambda i, e: failed.__setitem__(i, e))
    assert wait_for(lambda: len(ready) + len(failed) == 3)
    amps = [d["chain"]["amp"]["model"] for d in ready.values()]
    assert len(set(amps)) == 3, "every variant has its own amp"
    assert any("zu ähnlich" in call[-1]["content"] for call in chat.calls)


def test_one_failing_variant_does_not_stop_the_others():
    def chat(messages, temperature):
        if "Variante B" in messages[1]["content"]:
            raise sound_ai.CloudError("unauthorized", "Ollama hat den API-Schlüssel abgelehnt.")
        return recipe(amp="Twin" if "Variante A" in messages[1]["content"] else "SLO100")

    ready, failed = {}, {}
    sound_ai.variants("Rock", chat, lambda i, d: ready.__setitem__(i, d), lambda i, e: failed.__setitem__(i, e))
    assert wait_for(lambda: len(ready) + len(failed) == 3)
    assert set(ready) == {0, 2} and set(failed) == {1}


def test_cancelling_reports_nothing():
    cancelled = threading.Event()
    gate = threading.Event()

    def chat(messages, temperature):
        gate.wait(1)
        return recipe()

    ready, failed = [], []
    done = sound_ai.variants("Rock", chat, lambda *a: ready.append(a), lambda *a: failed.append(a), cancelled=cancelled)
    cancelled.set()
    gate.set()
    done.result(timeout=3)
    assert ready == [] and failed == []


# MARK: Quick changes


def test_refine_keeps_the_sound_and_makes_the_change():
    original = sound_ai.parse(recipe(name="Crunch", treble=6))
    chat = ScriptedChat([recipe(name="Anderer Name", treble=4)])
    new, note = sound_ai.refine(original, "warmer", "Rock", chat)
    assert new["name"] == "Crunch" and new["chain"]["amp"]["settings"]["treble"] == 4 and note is None
    sent = chat.calls[0]
    assert [m["role"] for m in sent] == ["system", "user", "assistant", "user"]
    assert '"Crunch"' in sent[2]["content"] and "wärmer" in sent[3]["content"]


def test_refine_sends_back_an_amp_swap_and_turns_the_knob_itself_when_needed():
    original = sound_ai.parse(recipe(amp="Plexi", treble=6))
    chat = ScriptedChat([recipe(amp="Twin", treble=4), recipe(amp="Plexi", treble=4.5)])
    new, _ = sound_ai.refine(original, "warmer", "Rock", chat)
    assert new["chain"]["amp"]["model"] == "Plexi" and "ersetzt" in chat.calls[1][-1]["content"]
    unchanged = recipe(treble=6)
    new, note = sound_ai.refine(original, "warmer", "Rock", ScriptedChat([unchanged] * 3))
    assert new["chain"]["amp"]["settings"]["treble"] == 4.5 and note


def test_less_reverb_is_refused_without_reverb_and_sends_nothing():
    dry = sound_ai.parse(recipe(reverb_level=None))
    chat = ScriptedChat([recipe()])
    with pytest.raises(sound_ai.AIError) as error:
        sound_ai.refine(dry, "lessReverb", "Rock", chat)
    assert error.value.kind == "not_possible" and chat.calls == []


def test_adjustment_directions_and_nudges():
    base = sound_ai.parse(recipe(gain=5, treble=6, reverb_level=3))
    p = lambda **k: sound_ai.parse(recipe(**k))  # noqa: E731
    assert sound_ai.is_applied("warmer", base, p(gain=5, treble=4.5))
    assert not sound_ai.is_applied("warmer", base, p(gain=5, treble=7))
    assert sound_ai.is_applied("brighter", base, p(gain=5, treble=7))
    assert sound_ai.is_applied("moreGain", base, p(gain=6.5))
    assert sound_ai.is_applied("moreGain", base, p(gain=5, drive="DistortionTS9"))
    assert not sound_ai.is_applied("moreGain", base, p(gain=5))
    assert sound_ai.is_applied("lessReverb", base, p(reverb_level=1.5))
    assert sound_ai.is_applied("lessReverb", base, p(reverb_level=None))
    edge = sound_ai.parse(recipe(gain=9.5, treble=1, reverb_level=1))
    for adjustment in sound_ai.ADJUSTMENTS:
        nudged = sound_ai.nudged(adjustment, edge)
        recipemod.to_preset(nudged)
        assert sound_ai.is_applied(adjustment, edge, nudged), adjustment
    assert sound_ai.nudged("moreGain", edge)["chain"]["amp"]["settings"]["gain"] == 10
    assert sound_ai.nudged("lessReverb", edge)["chain"]["reverb"]["on"] is False


# MARK: HTTP client


def test_request_carries_only_the_chat_and_a_generic_agent():
    request = sound_ai.make_request("gpt-oss:120b", " key ", [{"role": "user", "content": "Blues"}], 0.3)
    assert request.full_url == sound_ai.ENDPOINT
    assert request.get_header("Authorization") == "Bearer key"
    assert request.get_header("User-agent") == "SparkStudio"
    body = json.loads(request.data)
    assert set(body) == {"model", "messages", "stream", "format", "options"} and body["stream"] is False
    assert b"key" not in request.data, "the key stays in the header"


def test_missing_key_sends_nothing():
    transport = ScriptedTransport([ok("x")])
    with pytest.raises(sound_ai.CloudError) as error:
        sound_ai.complete("m", "  ", [], transport=transport)
    assert error.value.kind == "missing_key" and transport.requests == []


def test_a_busy_server_is_asked_again():
    transport = ScriptedTransport([(503, b'{"error":"overloaded"}'), (429, b""), ok("fertig")])
    assert sound_ai.complete("m", "k", [], transport=transport, retry=(0, 0)) == "fertig"
    assert len(transport.requests) == 3


def test_a_lost_connection_is_asked_again_then_reported():
    lost = urllib.error.URLError("Network is unreachable")
    transport = ScriptedTransport([lost, lost, lost, ok("zu spät")])
    with pytest.raises(sound_ai.CloudError) as error:
        sound_ai.complete("m", "k", [], transport=transport, retry=(0, 0))
    assert error.value.kind == "transport" and len(transport.requests) == 3


def test_a_wrong_key_or_model_is_not_repeated():
    for status, kind in ((401, "unauthorized"), (404, "model_not_found")):
        transport = ScriptedTransport([(status, b'{"error":"nope"}'), ok("x")])
        with pytest.raises(sound_ai.CloudError) as error:
            sound_ai.complete("m", "k", [], transport=transport, retry=(0, 0))
        assert error.value.kind == kind and len(transport.requests) == 1


def test_a_timeout_and_an_empty_or_broken_answer_are_reported():
    for step, kind in ((TimeoutError(), "timeout"), (ok(" "), "no_content"), ((200, b"kein json"), "unreadable")):
        with pytest.raises(sound_ai.CloudError) as error:
            sound_ai.complete("m", "k", [], transport=ScriptedTransport([step]), retry=())
        assert error.value.kind == kind
