"""AI Sound: a description in words becomes a sound recipe through Ollama's cloud API. A port of
Sources/SparkControl/Library/SoundAI.swift, SoundAIKnowledge.swift and OllamaCloud.swift; the Swift code is the
reference, change both together.

The chat is passed in as a function (`Chat`): `ollama(model, key)` talks to the cloud, tests pass a fake, so nothing
here needs a network. What leaves the computer: the model name, the chat messages (rules, catalog, the wish and, for a
follow-up, the recipe being adjusted) and the temperature. The key goes only into the Authorization header, the user
agent is a fixed name. `checked_request` refuses a wish with an e-mail address, a phone number or a key in it.
"""
from __future__ import annotations

import concurrent.futures
import copy
import json
import re
import socket
import threading
import time
import urllib.error
import urllib.request
from typing import Callable

from . import catalog, i18n, recipe as recipemod
from .i18n import tr
from .protocol import DESCRIPTION_LIMIT, fit_description

ENDPOINT = "https://ollama.com/api/chat"
TAGS_ENDPOINT = "https://ollama.com/api/tags"
USER_AGENT = "AmpBench"
REQUEST_TIMEOUT = 120
RETRY_DELAYS = (1.5, 4.0)
DEFAULT_MODEL = "gpt-oss:120b"
REQUEST_LIMIT = 200
PLACES = ("gate", "compressor", "drive", "amp", "modulation", "delay", "reverb")

Chat = Callable[[list[dict], float], str]


class Cancelled(Exception):
    """The user cancelled; nothing needs saying."""


class AIError(Exception):
    """What went wrong, in words the user can read and that can be fed back to the assistant for a correction."""

    def __init__(self, kind: str, message: str = ""):
        self.kind = kind
        super().__init__(message or _message(kind))


def _message(kind: str) -> str:
    """The standard text of an error kind, in the app's language at the time it is raised."""
    if kind == "empty_request":
        return tr("First describe the sound you want.")
    if kind == "empty_answer":
        return tr("The model did not answer. Try again.")
    if kind == "no_json":
        return tr("The model gave free text instead of a sound recipe (JSON) – even when asked again. Try again or choose another model under “Advanced”.")
    return kind


class CloudError(Exception):
    def __init__(self, kind: str, message: str, transient: bool = False):
        self.kind, self.transient = kind, transient
        super().__init__(message)


def message_for(error: Exception) -> str | None:
    """A message for the window, or None when the user cancelled."""
    return None if isinstance(error, Cancelled) else str(error)


# MARK: The cloud


def _cloud_error(kind: str, model: str = "", status: int = 0, detail: str = "") -> CloudError:
    if kind == "missing_key":
        return CloudError(kind, tr("No Ollama API key. Get one at ollama.com/settings/keys and enter it."))
    if kind == "unauthorized":
        return CloudError(kind, tr("Ollama refused the API key. Check it at ollama.com/settings/keys and enter it again (Advanced → Remove key)."))
    if kind == "model_not_found":
        return CloudError(kind, tr("Ollama Cloud has no model “{}”. Choose another one under “Advanced”.", model))
    if kind == "rate_limited":
        return CloudError(kind, tr("Ollama is busy right now or your quota is used up. Wait a moment and try again."),
                          transient=True)
    if kind == "http":
        body = detail.strip()
        text = (tr("Ollama answered with status {}: {}", status, body) if body
                else tr("Ollama answered with status {}.", status))
        return CloudError(kind, text, transient=status >= 500)
    if kind == "no_content":
        return CloudError(kind, tr("Ollama answered without content. Try again."))
    if kind == "unreadable":
        return CloudError(kind, tr("The answer from Ollama could not be read. Try again."))
    if kind == "timeout":
        return CloudError(kind, tr("Ollama did not answer in time (time limit {} s). Try again or choose a faster model under “Advanced”.", REQUEST_TIMEOUT))
    return CloudError("transport", tr("No connection to Ollama: {}", detail), transient=True)


def make_request(model: str, key: str, messages: list[dict], temperature: float) -> urllib.request.Request:
    key = key.strip()
    if not key:
        raise _cloud_error("missing_key")
    body = json.dumps({"model": model, "messages": messages, "stream": False, "format": "json",
                       "options": {"temperature": temperature}}).encode("utf-8")
    return urllib.request.Request(ENDPOINT, data=body, method="POST", headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json", "User-Agent": USER_AGENT})


def urllib_transport(request: urllib.request.Request) -> tuple[int, bytes]:
    """Sends a request and returns status and body. Injected so tests run without a network."""
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def complete(model: str, key: str, messages: list[dict], temperature: float = 0.4,
             transport: Callable = urllib_transport, retry: tuple[float, ...] = RETRY_DELAYS,
             cancelled: threading.Event | None = None) -> str:
    """One chat answer. A network problem or a busy server is asked again as `retry` says."""
    request = make_request(model, key, messages, temperature)
    attempt = 0
    while True:
        if cancelled is not None and cancelled.is_set():
            raise Cancelled()
        try:
            return _send(request, model, transport)
        except CloudError as error:
            if not error.transient or attempt >= len(retry):
                raise
            delay = retry[attempt]
            attempt += 1
            if cancelled is not None:
                if cancelled.wait(delay):
                    raise Cancelled()
            elif delay > 0:
                time.sleep(delay)


def _send(request, model: str, transport) -> str:
    try:
        status, data = transport(request)
    except (socket.timeout, TimeoutError):
        raise _cloud_error("timeout")
    except urllib.error.URLError as error:
        if isinstance(error.reason, (socket.timeout, TimeoutError)):
            raise _cloud_error("timeout")
        raise _cloud_error("transport", detail=str(error.reason))
    except OSError as error:
        raise _cloud_error("transport", detail=str(error))
    if status != 200:
        try:
            detail = json.loads(data).get("error") or ""
        except (ValueError, AttributeError):
            detail = data.decode("utf-8", "replace")
        detail = str(detail)[:200]
        if status in (401, 403):
            raise _cloud_error("unauthorized")
        if status == 404:
            raise _cloud_error("model_not_found", model)
        if status == 429:
            raise _cloud_error("rate_limited")
        raise _cloud_error("http", status=status, detail=detail)
    try:
        content = json.loads(data)["message"]["content"]
    except (ValueError, KeyError, TypeError):
        raise _cloud_error("unreadable")
    if not str(content).strip():
        raise _cloud_error("no_content")
    return content


def available_models(transport: Callable = urllib_transport) -> list[str]:
    """The models the cloud offers right now (public list, no key needed). Only on the user's asking."""
    request = urllib.request.Request(TAGS_ENDPOINT, headers={"User-Agent": USER_AGENT})
    status, data = transport(request)
    if status != 200:
        raise _cloud_error("http", status=status)
    return sorted(model["name"] for model in json.loads(data)["models"])


def ollama(model: str, key: str, transport: Callable = urllib_transport, retry: tuple[float, ...] = RETRY_DELAYS,
           cancelled: threading.Event | None = None) -> Chat:
    return lambda messages, temperature: complete(model, key, messages, temperature, transport, retry, cancelled)


# MARK: The wish


def privacy_problem(text: str) -> str | None:
    """Why a wish should not leave the computer: it holds something personal or secret. Deterministic patterns."""
    tail = " " + tr("Leave that out – only the description of the sound goes to Ollama.")
    if re.search(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", text, re.IGNORECASE):
        return tr("Your wish contains an e-mail address.") + tail
    for found in re.findall(r"\+?\d[\d \t/().-]{6,}\d", text):
        if sum(ch.isdigit() for ch in found) >= 8:
            return tr("Your wish contains something like a phone number.") + tail
    # A run of 24 or more letters and digits without spaces or hyphens, mixed, is a key or token, not a song.
    for found in re.findall(r"[A-Za-z0-9_+/=]{24,}", text):
        if sum(ch.isdigit() for ch in found) >= 4 and sum(ch.isalpha() for ch in found) >= 4:
            return tr("Your wish contains something that looks like a key or password.") + tail
    return None


def checked_request(request: str) -> str:
    trimmed = request.strip()
    if not trimmed:
        raise AIError("empty_request")
    if len(trimmed) > REQUEST_LIMIT:
        raise AIError("too_long", tr("Describe the sound in at most {} characters.", REQUEST_LIMIT))
    problem = privacy_problem(trimmed)
    if problem:
        raise AIError("privacy", problem)
    return trimmed


def remember(request: str, history: list[str], limit: int = 8) -> list[str]:
    trimmed = request.strip()
    if not trimmed:
        return history
    rest = [h for h in history if h.casefold() != trimmed.casefold()]
    return ([trimmed] + rest)[:limit]


# The tag every sound made here carries. A stored value the library filters by, so it is the same in every language.
AI_TAG = "KI-Sound"


def keepsake(data: dict, request: str, adjustments: list[str] | None = None) -> dict:
    """The recipe as it goes into the library: the wish in the description, marked as an AI Sound, the adjustments as
    tags. The description fits what the amp takes, the wish first."""
    kept = copy.deepcopy(data)
    wish = request.strip()
    own = str(data.get("description", "")).strip()
    description = own
    if wish:
        marked = tr("AI Sound: “{}”", wish)
        both = marked if not own else f"{marked}. {own}"
        if len(both.encode()) <= DESCRIPTION_LIMIT:
            description = both
        elif len(marked.encode()) <= DESCRIPTION_LIMIT:
            description = marked
        else:
            cut = wish
            while len(tr("AI Sound: “{}…”", cut).encode()) > DESCRIPTION_LIMIT and cut:
                cut = cut[:-1]
            description = tr("AI Sound: “{}…”", cut)
    kept["description"] = fit_description(description)
    tags: list[str] = []
    for tag in list(data.get("tags", [])) + [AI_TAG] + [label(a) for a in adjustments or []]:
        if tag.casefold() not in (t.casefold() for t in tags):
            tags.append(tag)
    kept["tags"] = tags
    return kept


# MARK: Knowledge


ARCHETYPES = [
    ("The Edge (U2)", ["Compressor", "AC Boost", "DelayMono", "bias.reverb"],
     "gain 3–4, treble 6–7; echo as dotted eighths (bpm = song tempo × 4/3), effect 4–5, feedback 3–4; little reverb."),
    ("David Gilmour (Pink Floyd), lead", ["GuitarMuff", "Twin", "DelayMono", "bias.reverb"],
     "amp with headroom (gain 3–4), Muff sustain 6–7, tone 4–5; echo around 400–500 ms as eighths (bpm = song tempo × 2); Medium hall or Wide hall, level 3–4."),
    ("Jimi Hendrix", ["Fuzz", "Plexi", "UniVibe", "bias.reverb"],
     "Plexi gain 5–6, Fuzz fuzz 6–8 (the guitar's volume knob cleans it up); UniVibe speed 3–5; hardly any reverb (Room A)."),
    ("Stevie Ray Vaughan, Texas blues", ["DistortionTS9", "Twin", "bias.reverb"],
     "amp just before breakup (Twin gain 5–6 or Bassman gain 5), DistortionTS9 drive 1–3, level 7–8; Room B, level 2–3; no delay."),
    ("John Mayer", ["KlonCentaurSilver", "TwoStoneSP50", "bias.reverb"],
     "glassy clean (gain 4–5, middle 5–6), KlonCentaurSilver gain 3–4 for leads; Short plate or a room; delay quiet at most."),
    ("Eddie Van Halen", ["EVH", "Phaser", "DelayMono", "bias.reverb"],
     "“brown sound”: EVH gain 6–7 or Plexi gain 7–8, middle 6; Phaser speed 2–3 (Eruption) or Flanger (Unchained); short, quiet echo."),
    ("AC/DC", ["Plexi", "bias.reverb"],
     "no drive pedal, the distortion comes from the amp: Plexi gain 5–6 (rhythm) to 7 (lead), middle 6–7, bass 4; Room A, level 1.5–2; no delay, no gate."),
    ("Slash (Guns N' Roses)", ["DistortionTS9", "Plexi", "DelayMono", "bias.reverb"],
     "Plexi gain 7–8 or YJM100, DistortionTS9 drive 1–2 as a push, middle 7; lead echo 350–450 ms, effect 2–3; a room."),
    ("Metallica, thrash rhythm", ["bias.noisegate", "DistortionTS9", "Rectifier", "bias.reverb"],
     "Rectifier or AmericanHighGain gain 6–7, middle 3–4, bass 6; DistortionTS9 drive 0–1, level 8 to tighten; gate threshold 4; reverb off or minimal."),
    ("Modern metal, djent", ["bias.noisegate", "DistortionTS9", "6505Plus"],
     "6505Plus or BE101 gain 5–6.5 (not higher), DistortionTS9 drive 0, level 8; gate 4–5; no reverb and no delay for rhythm."),
    ("Funk (Nile Rodgers)", ["Compressor", "RolandJC120", "bias.reverb"],
     "Compressor sensitivity 5–6; RolandJC120 or Twin gain 2–3, treble 7, middle 6; no delay, reverb level below 1.5."),
    ("Mark Knopfler (Dire Straits)", ["Compressor", "Deluxe65", "bias.reverb"],
     "clean and mid-focused (gain 4, treble 6, middle 6), light compressor; a room or Natural hall. “Money for Nothing”: Plexi gain 6, middle 8, treble 3."),
    ("The Police, 80s clean with chorus", ["RolandJC120", "ChorusAnalog", "DelayMono", "bias.reverb"],
     "RolandJC120 gain 2–3, ChorusAnalog effect 5, rate 3; echo as eighths (bpm = song tempo × 2), effect 3, feedback 3–4."),
    ("Nirvana, grunge", ["ProCoRat", "AmericanHighGain", "Cloner", "bias.reverb"],
     "chorus of the song: ProCoRat distortion 6–7 into a lightly driven amp (AmericanHighGain gain 4 or Twin gain 5); verse clean with Cloner (Come as You Are); a room."),
    ("Garage rock (The White Stripes, The Black Keys)", ["GuitarMuff", "Checkmate", "bias.reverb"],
     "fuzz (GuitarMuff sustain 7–9 or Fuzz) into a small combo (Checkmate or BluesJrTweed gain 5–6); a room, no delay."),
    ("Surf (Dick Dale, The Ventures)", ["Twin", "Tremolo", "bias.reverb"],
     "Twin gain 3, treble 7; wet reverb instead of a spring: Rich plate, level 5–6, length 5–6; Tremolo speed 4–6."),
    ("Country, chicken picking", ["Compressor", "Twin", "DelayMono", "bias.reverb"],
     "Twin or Deluxe65 gain 3, treble 7; Compressor; slapback with DelayMono: sync Free, range “200 ms”, time 4–5, feedback 0–1, effect 3; a room."),
    ("Jazz", ["RolandJC120", "bias.reverb"],
     "RolandJC120 or Twin gain 2–3, treble 3–4, middle 5, bass 6; a room, level 2; no other effects."),
    ("Santana", ["DistortionTS9", "ODS50CN", "DelayMono", "bias.reverb"],
     "singing sustain: ODS50CN or Bogner gain 6–7, middle 7, DistortionTS9 drive 2; quiet echo; Medium hall."),
    ("Queen (Brian May)", ["Booster", "AC Boost", "DelayMono", "bias.reverb"],
     "Booster gain 7–9 into AC Boost (gain 6–7, treble 6, middle 7); echo as quarters or eighths, feedback 3–4; a hall."),
    ("Blues rock (Gary Moore, Joe Bonamassa)", ["DistortionTS9", "Plexi", "DelayMono", "bias.reverb"],
     "Plexi or OverDrivenJM45 gain 6–7, DistortionTS9 drive 2–3, level 7; quiet lead echo; Natural hall."),
    ("Red Hot Chili Peppers (John Frusciante)", ["Plexi", "bias.reverb"],
     "funk rhythm almost clean through Plexi gain 3–4; solo with GuitarMuff or DistortionTS9 in front; a room, hardly any delay."),
    ("Britpop (Oasis)", ["Overdrive", "OrangeAD30", "Phaser", "bias.reverb"],
     "OrangeAD30 or Plexi gain 6–7, Overdrive drive 3; Phaser speed 2, intensity 4; a room."),
    ("Shoegaze, post-rock, ambient", ["GuitarMuff", "Twin", "DelayRe201", "bias.reverb"],
     "Muff or clean; DelayRe201 sustain 5–6, level 4; Wide hall, length 8–9, level 5; DelayReverse for swells."),
]

EXAMPLES = [
    ("U2 – Where the Streets Have No Name",
     '{"format":"spark-sound-recipe","version":1,"name":"Streets Echo","description":"Shimmering British clean with a dotted-eighth echo","bpm":168,"tags":["U2","Clean","Delay"],"notes":"The song runs at about 126 BPM; bpm is 168 (126 × 4/3) so that the synced echo comes as dotted eighths. Set delay.effect by ear first, then amp.treble.","chain":{"compressor":{"model":"Compressor","settings":{"level":6,"sensitivity":4}},"amp":{"model":"AC Boost","settings":{"gain":3.5,"treble":6.5,"middle":5,"bass":4.5,"master":7}},"delay":{"model":"DelayMono","settings":{"effect":4.5,"feedback":3.5,"sync":true}},"reverb":{"model":"bias.reverb","settings":{"level":2,"length":5,"type":"Natural hall"}}}}'),
    ("AC/DC – Back in Black",
     '{"format":"spark-sound-recipe","version":1,"name":"Black Crunch","description":"Dry Plexi crunch without pedals","bpm":94,"tags":["AC/DC","Rock","Crunch"],"notes":"The distortion comes from the amp alone. Too much drive: amp.gain to 5; too thin: amp.middle up.","chain":{"amp":{"model":"Plexi","settings":{"gain":6,"treble":6,"middle":7,"bass":4,"master":7}},"reverb":{"model":"bias.reverb","settings":{"level":1.5,"length":3.5,"type":"Room A"}}}}'),
    ("Pink Floyd – Comfortably Numb, solo",
     '{"format":"spark-sound-recipe","version":1,"name":"Numb Solo","description":"Singing fuzz lead with echo and a big hall","bpm":128,"tags":["Pink Floyd","Lead","Fuzz"],"notes":"The song runs at about 64 BPM; bpm is 128 so that the echo comes as eighths (about 470 ms). Too muddy: drive.tone up; too wet: reverb.level down.","chain":{"compressor":{"model":"BlueComp","settings":{"level":5,"sustain":5}},"drive":{"model":"GuitarMuff","settings":{"sustain":6.5,"tone":4.5,"level":6}},"amp":{"model":"Twin","settings":{"gain":3.5,"treble":5.5,"middle":6,"bass":5,"master":7}},"delay":{"model":"DelayMono","settings":{"effect":3.5,"feedback":3.5,"sync":true}},"reverb":{"model":"bias.reverb","settings":{"level":3.5,"length":7,"type":"Medium hall"}}}}'),
]

TEMPO_TEXT = """- With sync = BPM the echo comes as a quarter note of "bpm" (60000 / bpm milliseconds). A sync tremolo follows the same bpm.
- For other note values you change "bpm": quarters → song tempo; dotted eighths (The Edge) → song tempo × 4/3; eighths → song tempo × 2. Stay between 40 and 250. Name the real song tempo in "notes".
- Without a song: rhythm echo 300–400 ms, lead 400–500 ms, ambient 500–700 ms (bpm = 60000 / ms).
- Slapback (rockabilly, country): DelayMono with sync Free, range “200 ms”, time 4–5, feedback 0–1."""

REVERB_TEXT = """- Rock, blues, crunch: Room A, Room B or Chamber, level 1.5–2.5.
- Ballad, singing leads: Natural hall or Medium hall, level 3–4.
- Clean, pop, funk: Short plate, level 2–3 (funk below 1.5).
- Surf: Rich plate, level 5–6 (instead of a spring reverb).
- Ambient, post-rock: Wide hall, length 8–9, level 4–5.
- Metal rhythm: off, or Room A with level below 1."""

# Three directions for the same wish, so the user gets sounds that differ audibly instead of three takes of one.
VARIANT_HINTS = [
    "Variant A – faithful: the amp, the drive and the effects the player or the genre typically uses. Give the "
    "sound a name of its own.",
    "Variant B – more punch: one gain stage more than the obvious choice (clean → edge of breakup, crunch → lead) "
    "and another amp model than the most obvious one; more mids and presence. Give the sound a name of its "
    "own that says so.",
    "Variant C – reduced and open: less gain than the obvious choice, another amp model, at most two effects and "
    "another idea of space (for example tape echo instead of digital delay, plate instead of hall). Dynamic, "
    "responds to picking. Give the sound a name of its own that says so.",
]


def variant_titles() -> list[str]:
    """A short title for each direction, one per hint, for the cards while they are written."""
    return [tr("Faithful"), tr("More punch"), tr("Reduced")]


def answer_language() -> str:
    """The language the assistant writes the recipe's own words in: the user's."""
    return "German" if i18n.language() == i18n.GERMAN else "English"


def _raw_catalog() -> dict:
    return json.loads(catalog._find_catalog().read_text(encoding="utf-8"))


def catalog_text() -> str:
    """The catalog as a compact list for the prompt: id, character and parameters with keys and exact labels. English,
    the labels as recipes write them."""
    data = _raw_catalog()
    models = {m["id"]: m for m in data["models"]}
    lines = []
    for place in data["places"]:
        lines.append(f"## {place['title']} (key: {place['key']})")
        for model_id in place["models"]:
            model = models.get(model_id)
            if model is None:
                continue
            head = f"- {model['id']} · {model['name']}"
            if model.get("inspiration"):
                head += f" · modeled on {model['inspiration']}"
            if model.get("group"):
                head += f" · {model['group']}"
            if model.get("pack"):
                head += " · PACK (paid add-on)"
            lines.append(head)
            params = ", ".join(_describe(p) for p in model["parameters"])
            if params:
                lines.append(f"    {params}")
    return "\n".join(lines)


def _describe(parameter: dict) -> str:
    if parameter["kind"] == "switch":
        return f"`{parameter['key']}` switch ({parameter.get('off') or 'Off'}/{parameter.get('on') or 'On'})"
    if parameter["kind"] == "choice":
        return f"`{parameter['key']}` choice ({' · '.join(o['label'] for o in parameter.get('options', []))})"
    return f"`{parameter['key']}` (0–10)"


def system_prompt() -> str:
    """The rules, the knowledge and the catalog. English whatever the app's language is; the assistant is told to
    write the recipe's name, description, tags and notes in the user's language."""
    language = answer_language()
    archetypes = "\n".join(f"- {topic}: {' → '.join(models)} · {advice}" for topic, models, advice in ARCHETYPES)
    examples = "\n\n".join(f"Wish: “{wish}”\n{text}" for wish, text in EXAMPLES)
    return f"""You build guitar sounds for Positive Grid Spark amps as a “sound recipe” (a JSON object). The user describes an idea, a song, a band, a player or an instruction – for example “sound for U2 – Where the streets have no name” or “blues sound for my Telecaster”. The user may write in any language.

Answer ONLY with a single JSON object, with no text before or after it, in exactly this form:

{{
  "format": "spark-sound-recipe",
  "version": 1,
  "name": "short name, at most 31 bytes (umlauts count double)",
  "description": "one sentence saying what the sound is",
  "bpm": 120,
  "tags": ["style", "mood"],
  "notes": "what to turn first by ear, and why",
  "chain": {{
    "gate":       {{ "model": "<id>", "on": true, "settings": {{ }} }},
    "compressor": {{ "model": "<id>", "on": true, "settings": {{ }} }},
    "drive":      {{ "model": "<id>", "on": true, "settings": {{ }} }},
    "amp":        {{ "model": "<id>", "settings": {{ }} }},
    "modulation": {{ "model": "<id>", "on": true, "settings": {{ }} }},
    "delay":      {{ "model": "<id>", "on": true, "settings": {{ }} }},
    "reverb":     {{ "model": "<id>", "settings": {{ }} }}
  }}
}}

Rules:
- Write "name", "description", "tags" and "notes" in {language}. Model ids, parameter keys and labels stay exactly as the catalog writes them.
- There are exactly these seven places in a fixed order: gate, compressor, drive, amp, modulation, delay, reverb. A place that should not sound is left out (no entry) or gets "on": false.
- Every place has exactly ONE "model". Use only model ids from the catalog below, written exactly like that (upper and lower case matter).
- "settings" uses only the parameter keys of that model from the catalog. Knob: a number from 0 to 10. Switch: true/false or exactly one of the given labels. Choice: exactly one of the given labels.
- A value left out keeps the amp's start value. Always set gain, treble, middle, bass and master of the amp explicitly.
- The EQ is a modulation (GuitarEQ6 or BassEQ6). The modulation place holds either an EQ or a chorus/phaser/tremolo, never both.
- The wah of the paid add-on sits in the compressor place. Avoid models marked “PACK” unless the user asks for them explicitly.
- There is exactly one reverb model (bias.reverb); its “type” chooses room, chamber, hall or plate. There is no spring reverb.
- Amps have five knobs: gain, treble, middle, bass, master (pack amps call it volume).
- For a song set "bpm" to fit the song's tempo (see Tempo and delay time), otherwise 120.
- If a “Direction of this variant” is given, follow it. Variants should differ audibly: another amp, another gain stage or another idea for the effects.

How to choose (starting points, not law):
- Sparkling clean, jazz, funk: Twin, RolandJC120, 94MatchDCV2 (clean)
- Clean that breaks up when you dig in: ODS50CN, Deluxe65, BluesJrTweed
- British chime, 60s pop, indie: AC Boost, Bassman (bright)
- Classic rock rhythm: Plexi, OverDrivenJM45 (crunch)
- Blues lead: Bassman or OverDrivenLuxVerb, pushed by DistortionTS9
- Singing lead, fusion: SLO100, Bogner, ODS50CN with a drive (highGain)
- 80s hard rock: EVH, SwitchAxeLead, YJM100
- Modern metal: 6505Plus, Rectifier, BE101 (metal)
- Acoustic: AcousticAmpV2, FatAcousticV2 · Bass: GK800, Sunny3000, W600, Hammer500

Players and genres – typical signal chains (starting points, only with models from the catalog):
{archetypes}

Gain staging (knobs 0–10):
- Clean: amp.gain 2–4 · edge of breakup: 4.5–6 · crunch: 5–7 · high-gain amps mostly 5–7, above 8 it gets fizzy and noisy.
- master is volume, not distortion: 6–8. The sounds of a set should be about equally loud.
- Tightening high gain: a drive in front with almost no gain and a high level (DistortionTS9 drive 0–1.5, level 7–9), or Booster.
- Pushing crunch to lead: DistortionTS9 drive 2–4.

EQ words (what the user says → what you turn):
- warmer/darker: treble down 1–2 (tone down on drives)
- brighter/more sparkle: treble up 1, reverb highCut up
- muddy/boomy: bass down 1–2
- thin/harsh: bass up, treble down, less gain
- more bite/cut: middle up 1–2
- scooped/heavy rhythm: middle at 3–4, not below 3
- more sustain: compressor BlueComp sustain 6–7, or more gain
- funk spank: LA2AComp or Compressor, clean amp, little reverb

Time effects:
- Delay: level/mix 2–3 for rhythm, 3–4 for leads; feedback 2–4 (few repeats), above 7 it runs away.
- Modulation: chorus effect 3–5, rate low; tremolo speed 4–6 for a surf pulse.
- Gate: threshold 1.5–3 crunch, 3–5 high gain; off for clean.

Tempo and delay time:
{TEMPO_TEXT}

Reverb by style:
{REVERB_TEXT}

Keep it simple: a few fitting effects instead of everything at once. Choose the amp first, then build around it. Write in "notes" which one or two knobs the player should turn first by ear.

EXAMPLES – valid recipes in exactly the required form:

{examples}

CATALOG – use only these model ids, parameter keys and labels:

{catalog_text()}"""


def messages(request: str, hint: str = "") -> list[dict]:
    suffix = f"\n\nDirection of this variant: {hint}" if hint else ""
    return [{"role": "system", "content": system_prompt()},
            {"role": "user", "content": f"User's wish: {request}{suffix}"}]


# MARK: Parsing and conversation


def extract_json_object(text: str) -> str | None:
    start, end = text.find("{"), text.rfind("}")
    return text[start:end + 1] if 0 <= start < end else None


def parse(answer: str) -> dict:
    """Reads a recipe from the assistant's answer and checks it. Raises every problem at once."""
    trimmed = answer.strip()
    if not trimmed:
        raise AIError("empty_answer")
    found = extract_json_object(trimmed)
    if found is None:
        raise AIError("no_json")
    try:
        data = json.loads(found)
    except ValueError as error:
        raise AIError("unreadable", tr("Invalid JSON: {}", error))
    if not isinstance(data, dict) or data.get("format") != recipemod.FORMAT:
        raise AIError("unreadable", tr("Invalid JSON at “{}”: {}", "format", f"format is not {recipemod.FORMAT}"))
    if not isinstance(data.get("name"), str):
        raise AIError("unreadable", tr("The field “{}” is missing in the JSON.", "name"))
    chain = data.get("chain", {})
    if not isinstance(chain, dict) or any(not isinstance(u, dict) or not isinstance(u.get("model"), str)
                                          for u in chain.values()):
        raise AIError("unreadable", tr("Wrong type at “{}”.", "chain"))
    try:
        recipemod.to_preset(data)
    except recipemod.RecipeError as error:
        raise AIError("invalid", "\n".join(error.messages))
    except (TypeError, ValueError, AttributeError) as error:
        raise AIError("unreadable", tr("Wrong type at “{}”.", tr("root")))
    return data


def converse(start: list[dict], chat: Chat, temperature: float, rounds: int = 3,
             check: Callable[[dict], str | None] = lambda _: None,
             cancelled: threading.Event | None = None) -> tuple[dict, str | None]:
    """Asks until the answer reads as a recipe and `check` has nothing to complain about, at most `rounds` times.
    Returns the recipe and what is still wrong with it."""
    history = list(start)
    last_valid = None
    last_error: AIError = AIError("empty_answer")
    for _ in range(rounds):
        if cancelled is not None and cancelled.is_set():
            raise Cancelled()
        answer = chat(history, temperature)
        history.append({"role": "assistant", "content": answer})
        try:
            data = parse(answer)
            complaint = check(data)
            if complaint is None:
                return data, None
            last_valid = (data, complaint)
            correction = complaint
        except AIError as error:
            last_error = error
            correction = ("Your answer contained no JSON object. Answer without any explanation."
                          if error.kind == "no_json" else f"Your JSON could not be read. Error:\n{error}")
        history.append({"role": "user", "content": correction
                        + "\n\nAnswer again ONLY with the complete, corrected JSON object."})
    if last_valid is not None:
        return last_valid
    raise last_error


def active_model(data: dict, place: str) -> str | None:
    unit = data.get("chain", {}).get(place)
    if not unit or not unit.get("on", True):
        return None
    return unit.get("model")


def resemblance(a: dict, b: dict) -> str | None:
    amp = a.get("chain", {}).get("amp", {}).get("model")
    if not amp or amp != b.get("chain", {}).get("amp", {}).get("model"):
        return None
    drive = active_model(a, "drive")
    if drive != active_model(b, "drive"):
        return None
    return f"same amp “{amp}”" + (f" and same drive “{drive}”" if drive else ", both without a drive")


def distinctness(data: dict, others: list[dict]) -> str | None:
    for other in others:
        reason = resemblance(data, other)
        if reason:
            return (f"This suggestion sounds too much like “{other.get('name')}” ({reason}). Build an audibly different "
                    "variant: choose another amp model and fit the drive and the effects to it. Keep the direction of "
                    "this variant and give it another name.")
    return None


def variants(request: str, chat: Chat, on_ready: Callable[[int, dict], None],
             on_failed: Callable[[int, Exception], None], hints: list[str] = VARIANT_HINTS,
             cancelled: threading.Event | None = None) -> concurrent.futures.Future:
    """Writes one recipe per hint at the same time and hands each over as soon as it is done. A variant too close
    to one already done goes back once to be made different. Raises before anything is sent when the wish is empty,
    too long or holds personal data."""
    wish = checked_request(request)
    lock = threading.Lock()
    offered: dict[int, dict] = {}

    def one(index: int, hint: str) -> None:
        complained = [False]

        def claim(data: dict) -> str | None:
            with lock:
                others = [offered[k] for k in sorted(offered) if k != index]
                complaint = distinctness(data, others)
                if complaint is None:
                    offered[index] = data
                    return None
            if complained[0]:
                return None
            complained[0] = True
            return complaint

        try:
            data, _ = converse(messages(wish, hint), chat, 0.6, check=claim, cancelled=cancelled)
            with lock:
                offered[index] = data
            if not (cancelled is not None and cancelled.is_set()):
                on_ready(index, data)
        except Exception as error:  # noqa: BLE001 - every failure is reported per variant
            if not (cancelled is not None and cancelled.is_set()) and message_for(error) is not None:
                on_failed(index, error)

    pool = concurrent.futures.ThreadPoolExecutor(max_workers=len(hints), thread_name_prefix="ampbench-ai")
    futures = [pool.submit(one, index, hint) for index, hint in enumerate(hints)]
    pool.shutdown(wait=False)
    done: concurrent.futures.Future = concurrent.futures.Future()
    threading.Thread(target=lambda: (concurrent.futures.wait(futures), done.set_result(None)), daemon=True).start()
    return done


# MARK: Refinement

# A quick change to an offered sound, made by a follow-up request instead of a new one. The English label goes to the
# assistant; `label` is what the button shows and what is kept as a tag, in the language the sound was made in.
ADJUSTMENTS = {
    "warmer": {"english": "warmer",
               "instruction": "Make the sound warmer: amp.treble down 1–2, with a drive also its tone down a little, "
                              "the reverb's highCut down a little."},
    "moreGain": {"english": "more gain",
                 "instruction": "Give the sound more gain: amp.gain up 1–2, or switch on a fitting drive or raise its "
                                "gain. Lower master a little at most, so that it stays equally loud."},
    "lessReverb": {"english": "less reverb",
                   "instruction": "Make the reverb clearly less: reverb.level down 1–2, length shorter too if needed."},
    "brighter": {"english": "brighter",
                 "instruction": "Make the sound brighter: amp.treble up 1–2, with a drive its tone up a little, the "
                                "reverb's highCut up a little."},
}


def label(adjustment: str) -> str:
    """The button's label, also kept as a tag."""
    return {"warmer": tr("warmer"), "moreGain": tr("more gain"), "lessReverb": tr("less reverb"),
            "brighter": tr("brighter")}[adjustment]


def nudge_description(adjustment: str) -> str:
    """What `nudged` turns, for telling the user."""
    return {"warmer": tr("amp treble −1.5"), "brighter": tr("amp treble +1.5"), "moreGain": tr("amp gain +1.5"),
            "lessReverb": tr("reverb level −1.5")}[adjustment]


def value(data: dict, place: str, key: str) -> float | None:
    """A knob's value in a recipe: the one it sets, or the start value from the catalog."""
    unit = data.get("chain", {}).get(place)
    if not unit:
        return None
    setting = unit.get("settings", {}).get(key)
    if isinstance(setting, (int, float)) and not isinstance(setting, bool):
        return float(setting)
    for model in _raw_catalog()["models"]:
        if model["id"] == unit.get("model"):
            start = next((p.get("start") for p in model["parameters"] if p["key"] == key), None)
            return float(start) if isinstance(start, (int, float)) and not isinstance(start, bool) else None
    return None


def impossibility(adjustment: str, data: dict) -> str | None:
    if adjustment == "lessReverb":
        level = value(data, "reverb", "level") or 0
        return tr("The sound has no reverb.") if active_model(data, "reverb") is None or level <= 0 else None
    if adjustment == "moreGain":
        gain = value(data, "amp", "gain") or 0
        return tr("More gain is not possible.") if gain >= 10 and active_model(data, "drive") is not None else None
    return None


def is_applied(adjustment: str, old: dict, new: dict) -> bool:
    def change(place: str, key: str) -> float:
        if active_model(old, place) is None or active_model(new, place) is None:
            return 0.0
        before, after = value(old, place, key), value(new, place, key)
        return 0.0 if before is None or after is None else after - before

    step = 0.5
    if adjustment == "warmer":
        return change("amp", "treble") <= -step or change("drive", "tone") <= -step or change("reverb", "highCut") <= -step
    if adjustment == "brighter":
        return (change("amp", "treble") >= step or change("drive", "tone") >= step or change("drive", "treble") >= step
                or change("reverb", "highCut") >= step)
    if adjustment == "moreGain":
        a, b = active_model(old, "drive"), active_model(new, "drive")
        if (a is None and b is not None) or (a is not None and b is not None and a != b):
            return True
        return change("amp", "gain") >= step or any(change("drive", k) >= step
                                                    for k in ("drive", "gain", "fuzz", "sustain", "distortion"))
    if adjustment == "lessReverb":
        if active_model(old, "reverb") is not None and active_model(new, "reverb") is None:
            return True
        return change("reverb", "level") <= -step or change("reverb", "length") <= -step
    return False


def complaint(adjustment: str, old: dict, new: dict) -> str | None:
    open_places = {"drive", "gate"} if adjustment == "moreGain" else set()
    english = ADJUSTMENTS[adjustment]["english"]
    for place in PLACES:
        if place in open_places:
            continue
        before = active_model(old, place)
        if before is None:
            continue
        if adjustment == "lessReverb" and place == "reverb" and active_model(new, place) is None:
            continue
        if active_model(new, place) != before:
            return (f"In the place {place} you replaced “{before}” or switched it off. Keep all models and change "
                    f"only the knobs that “{english}” needs.")
    if not is_applied(adjustment, old, new):
        return f"The recipe did not become “{english}”. {ADJUSTMENTS[adjustment]['instruction']}"
    return None


def nudged(adjustment: str, data: dict) -> dict:
    """The same change made locally, when the assistant does not make it: a step on the obvious knob."""
    result = copy.deepcopy(data)

    def shift(place: str, key: str, amount: float) -> None:
        if active_model(result, place) is None:
            return
        current = value(result, place, key)
        if current is None:
            return
        result["chain"][place].setdefault("settings", {})[key] = round(min(max(current + amount, 0), 10) * 10) / 10

    if adjustment == "warmer":
        shift("amp", "treble", -1.5)
        shift("drive", "tone", -1)
    elif adjustment == "brighter":
        shift("amp", "treble", 1.5)
    elif adjustment == "moreGain":
        shift("amp", "gain", 1.5)
    elif adjustment == "lessReverb":
        shift("reverb", "level", -1.5)
        if (value(result, "reverb", "level") or 0) < 0.5:
            result["chain"]["reverb"]["on"] = False
    return result


def refine(data: dict, adjustment: str, request: str, chat: Chat,
           cancelled: threading.Event | None = None) -> tuple[dict, str | None]:
    """Adjusts an offered sound by a follow-up request. If the answer changed models or did not move in the asked
    direction it goes back once; if still wrong, AmpBench turns the obvious knob itself and says so."""
    reason = impossibility(adjustment, data)
    if reason:
        raise AIError("not_possible", reason)
    wish = checked_request(request)
    info = ADJUSTMENTS[adjustment]
    start = messages(wish) + [
        {"role": "assistant", "content": json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False)},
        {"role": "user", "content": f"Adjust exactly this recipe: {info['english']}. {info['instruction']}\n"
                                    "Keep the name, the amp and all other models. Change only the knobs this needs and "
                                    "leave everything else as it is. Adjust \"notes\" in one sentence, in "
                                    f"{answer_language()}.\nAnswer ONLY with the complete JSON object."},
    ]
    new, unresolved = converse(start, chat, 0.2, check=lambda n: complaint(adjustment, data, n), cancelled=cancelled)
    note = None
    if unresolved is not None:
        new = nudged(adjustment, data)
        note = tr("The model did not apply “{}” cleanly. AmpBench made the change itself ({}).", label(adjustment),
                  nudge_description(adjustment))
    new = copy.deepcopy(new)
    new["name"], new["tags"] = data.get("name"), list(data.get("tags", []))
    return new, note
