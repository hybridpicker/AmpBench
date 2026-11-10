"""KI-Sound: a description in words becomes a sound recipe through Ollama's cloud API. A port of
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

from . import catalog, recipe as recipemod
from .protocol import DESCRIPTION_LIMIT, fit_description

ENDPOINT = "https://ollama.com/api/chat"
TAGS_ENDPOINT = "https://ollama.com/api/tags"
USER_AGENT = "SparkStudio"
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
        super().__init__(message or _MESSAGES.get(kind, kind))


_MESSAGES = {
    "empty_request": "Beschreibe zuerst, welchen Sound du möchtest.",
    "empty_answer": "Das Modell hat nichts geantwortet. Versuch es noch einmal.",
    "no_json": "Das Modell hat kein Sound-Rezept (JSON) geliefert, sondern freien Text – auch nach einer Nachfrage. "
               "Versuch es noch einmal oder wähle unter „Erweitert“ ein anderes Modell.",
}


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
        return CloudError(kind, "Kein Ollama-API-Schlüssel. Hole einen unter ollama.com/settings/keys und trage ihn ein.")
    if kind == "unauthorized":
        return CloudError(kind, "Ollama hat den API-Schlüssel abgelehnt. Prüfe ihn unter ollama.com/settings/keys und "
                                "trage ihn neu ein (Erweitert → Schlüssel entfernen).")
    if kind == "model_not_found":
        return CloudError(kind, f"Das Modell „{model}“ gibt es bei Ollama Cloud nicht. Wähle unter „Erweitert“ ein anderes.")
    if kind == "rate_limited":
        return CloudError(kind, "Ollama ist gerade ausgelastet oder dein Kontingent ist aufgebraucht. Warte kurz und "
                                "versuch es noch einmal.", transient=True)
    if kind == "http":
        body = detail.strip()
        text = f"Ollama antwortete mit Status {status}." if not body else f"Ollama antwortete mit Status {status}: {body}"
        return CloudError(kind, text, transient=status >= 500)
    if kind == "no_content":
        return CloudError(kind, "Ollama antwortete ohne Inhalt. Versuch es noch einmal.")
    if kind == "unreadable":
        return CloudError(kind, "Die Antwort von Ollama war nicht lesbar. Versuch es noch einmal.")
    if kind == "timeout":
        return CloudError(kind, f"Ollama hat nicht rechtzeitig geantwortet (Zeitlimit {REQUEST_TIMEOUT} s). Versuch es "
                                "noch einmal oder wähle unter „Erweitert“ ein schnelleres Modell.")
    return CloudError("transport", f"Keine Verbindung zu Ollama: {detail}", transient=True)


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
    tail = " Lass das weg – an Ollama geht nur die Beschreibung des Sounds."
    if re.search(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", text, re.IGNORECASE):
        return "Dein Wunsch enthält eine E-Mail-Adresse." + tail
    for found in re.findall(r"\+?\d[\d \t/().-]{6,}\d", text):
        if sum(ch.isdigit() for ch in found) >= 8:
            return "Dein Wunsch enthält etwas wie eine Telefonnummer." + tail
    # A run of 24 or more letters and digits without spaces or hyphens, mixed, is a key or token, not a song.
    for found in re.findall(r"[A-Za-z0-9_+/=]{24,}", text):
        if sum(ch.isdigit() for ch in found) >= 4 and sum(ch.isalpha() for ch in found) >= 4:
            return "Dein Wunsch enthält etwas, das wie ein Schlüssel oder Passwort aussieht." + tail
    return None


def checked_request(request: str) -> str:
    trimmed = request.strip()
    if not trimmed:
        raise AIError("empty_request")
    if len(trimmed) > REQUEST_LIMIT:
        raise AIError("too_long", f"Beschreibe den Sound in höchstens {REQUEST_LIMIT} Zeichen.")
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


def keepsake(data: dict, request: str, adjustments: list[str] | None = None) -> dict:
    """The recipe as it goes into the library: the wish in the description, marked as a KI-Sound, the adjustments as
    tags. The description fits what the amp takes, the wish first."""
    kept = copy.deepcopy(data)
    wish = request.strip()
    own = str(data.get("description", "")).strip()
    description = own
    if wish:
        marked = f"KI-Sound: „{wish}“"
        both = marked if not own else f"{marked}. {own}"
        if len(both.encode()) <= DESCRIPTION_LIMIT:
            description = both
        elif len(marked.encode()) <= DESCRIPTION_LIMIT:
            description = marked
        else:
            cut = wish
            while len(f"KI-Sound: „{cut}…“".encode()) > DESCRIPTION_LIMIT:
                cut = cut[:-1]
            description = f"KI-Sound: „{cut}…“"
    kept["description"] = fit_description(description)
    tags: list[str] = []
    for tag in list(data.get("tags", [])) + ["KI-Sound"] + [ADJUSTMENTS[a]["label"] for a in adjustments or []]:
        if tag.casefold() not in (t.casefold() for t in tags):
            tags.append(tag)
    kept["tags"] = tags
    return kept


# MARK: Knowledge


ARCHETYPES = [
    ("The Edge (U2)", ["Compressor", "AC Boost", "DelayMono", "bias.reverb"],
     "gain 3–4, treble 6–7; Echo als punktierte Achtel (bpm = Songtempo × 4/3), effect 4–5, feedback 3–4; wenig Hall."),
    ("David Gilmour (Pink Floyd), Lead", ["GuitarMuff", "Twin", "DelayMono", "bias.reverb"],
     "Amp mit Headroom (gain 3–4), Muff sustain 6–7, tone 4–5; Echo um 400–500 ms als Achtel (bpm = Songtempo × 2); Saal mittel oder weit, level 3–4."),
    ("Jimi Hendrix", ["Fuzz", "Plexi", "UniVibe", "bias.reverb"],
     "Plexi gain 5–6, Fuzz fuzz 6–8 (Lautstärkeregler der Gitarre räumt auf); UniVibe speed 3–5; kaum Hall (Raum A)."),
    ("Stevie Ray Vaughan, Texas-Blues", ["DistortionTS9", "Twin", "bias.reverb"],
     "Amp knapp vor dem Aufbrechen (Twin gain 5–6 oder Bassman gain 5), DistortionTS9 drive 1–3, level 7–8; Raum B, level 2–3; kein Delay."),
    ("John Mayer", ["KlonCentaurSilver", "TwoStoneSP50", "bias.reverb"],
     "glasiger Clean (gain 4–5, middle 5–6), KlonCentaurSilver gain 3–4 für Leads; Platte kurz oder Raum; Delay höchstens leise."),
    ("Eddie Van Halen", ["EVH", "Phaser", "DelayMono", "bias.reverb"],
     "„Brown Sound“: EVH gain 6–7 oder Plexi gain 7–8, middle 6; Phaser speed 2–3 (Eruption) oder Flanger (Unchained); kurzes, leises Echo."),
    ("AC/DC", ["Plexi", "bias.reverb"],
     "kein Verzerrer, die Zerre kommt vom Amp: Plexi gain 5–6 (Rhythmus) bis 7 (Lead), middle 6–7, bass 4; Raum A, level 1,5–2; kein Delay, kein Gate."),
    ("Slash (Guns N' Roses)", ["DistortionTS9", "Plexi", "DelayMono", "bias.reverb"],
     "Plexi gain 7–8 oder YJM100, DistortionTS9 drive 1–2 als Schub, middle 7; Lead-Echo 350–450 ms, effect 2–3; Raum."),
    ("Metallica, Thrash-Rhythmus", ["bias.noisegate", "DistortionTS9", "Rectifier", "bias.reverb"],
     "Rectifier oder AmericanHighGain gain 6–7, middle 3–4, bass 6; DistortionTS9 drive 0–1, level 8 zum Straffen; Gate threshold 4; Hall aus oder minimal."),
    ("Moderner Metal, Djent", ["bias.noisegate", "DistortionTS9", "6505Plus"],
     "6505Plus oder BE101 gain 5–6,5 (nicht höher), DistortionTS9 drive 0, level 8; Gate 4–5; im Rhythmus kein Hall und kein Delay."),
    ("Funk (Nile Rodgers)", ["Compressor", "RolandJC120", "bias.reverb"],
     "Compressor sensitivity 5–6; RolandJC120 oder Twin gain 2–3, treble 7, middle 6; kein Delay, Hall level unter 1,5."),
    ("Mark Knopfler (Dire Straits)", ["Compressor", "Deluxe65", "bias.reverb"],
     "clean und mittig (gain 4, treble 6, middle 6), Kompressor leicht; Raum oder Saal natürlich. „Money for Nothing“: Plexi gain 6, middle 8, treble 3."),
    ("The Police, 80er-Clean mit Chorus", ["RolandJC120", "ChorusAnalog", "DelayMono", "bias.reverb"],
     "RolandJC120 gain 2–3, ChorusAnalog effect 5, rate 3; Echo als Achtel (bpm = Songtempo × 2), effect 3, feedback 3–4."),
    ("Nirvana, Grunge", ["ProCoRat", "AmericanHighGain", "Cloner", "bias.reverb"],
     "Refrain: ProCoRat distortion 6–7 in einen leicht angezerrten Amp (AmericanHighGain gain 4 oder Twin gain 5); Strophe clean mit Cloner (Come as You Are); Raum."),
    ("Garage-Rock (The White Stripes, The Black Keys)", ["GuitarMuff", "Checkmate", "bias.reverb"],
     "Fuzz (GuitarMuff sustain 7–9 oder Fuzz) in einen kleinen Combo (Checkmate oder BluesJrTweed gain 5–6); Raum, kein Delay."),
    ("Surf (Dick Dale, The Ventures)", ["Twin", "Tremolo", "bias.reverb"],
     "Twin gain 3, treble 7; nasser Hall statt Federhall: Platte satt, level 5–6, length 5–6; Tremolo speed 4–6."),
    ("Country, Chicken Picking", ["Compressor", "Twin", "DelayMono", "bias.reverb"],
     "Twin oder Deluxe65 gain 3, treble 7; Compressor; Slapback mit DelayMono: sync Frei, range „200 ms“, time 4–5, feedback 0–1, effect 3; Raum."),
    ("Jazz", ["RolandJC120", "bias.reverb"],
     "RolandJC120 oder Twin gain 2–3, treble 3–4, middle 5, bass 6; Raum, level 2; sonst keine Effekte."),
    ("Santana", ["DistortionTS9", "ODS50CN", "DelayMono", "bias.reverb"],
     "singendes Sustain: ODS50CN oder Bogner gain 6–7, middle 7, DistortionTS9 drive 2; leises Echo; Saal mittel."),
    ("Queen (Brian May)", ["Booster", "AC Boost", "DelayMono", "bias.reverb"],
     "Booster gain 7–9 in AC Boost (gain 6–7, treble 6, middle 7); Echo als Viertel oder Achtel, feedback 3–4; Saal."),
    ("Blues-Rock (Gary Moore, Joe Bonamassa)", ["DistortionTS9", "Plexi", "DelayMono", "bias.reverb"],
     "Plexi oder OverDrivenJM45 gain 6–7, DistortionTS9 drive 2–3, level 7; leises Lead-Echo; Saal natürlich."),
    ("Red Hot Chili Peppers (John Frusciante)", ["Plexi", "bias.reverb"],
     "Funk-Rhythmus fast clean über Plexi gain 3–4; Solo mit GuitarMuff oder DistortionTS9 davor; Raum, kaum Delay."),
    ("Britpop (Oasis)", ["Overdrive", "OrangeAD30", "Phaser", "bias.reverb"],
     "OrangeAD30 oder Plexi gain 6–7, Overdrive drive 3; Phaser speed 2, intensity 4; Raum."),
    ("Shoegaze, Post-Rock, Ambient", ["GuitarMuff", "Twin", "DelayRe201", "bias.reverb"],
     "Muff oder clean; DelayRe201 sustain 5–6, level 4; Saal weit, length 8–9, level 5; für Schwellklänge DelayReverse."),
]

EXAMPLES = [
    ("U2 – Where the Streets Have No Name",
     '{"format":"spark-sound-recipe","version":1,"name":"Streets Echo","description":"Glänzender britischer Clean-Sound mit punktiertem Achtel-Echo","bpm":168,"tags":["U2","Clean","Delay"],"notes":"Der Song läuft mit etwa 126 BPM; bpm steht auf 168 (126 × 4/3), damit das synchrone Echo als punktierte Achtel kommt. Zuerst delay.effect nach Gehör, dann amp.treble.","chain":{"compressor":{"model":"Compressor","settings":{"level":6,"sensitivity":4}},"amp":{"model":"AC Boost","settings":{"gain":3.5,"treble":6.5,"middle":5,"bass":4.5,"master":7}},"delay":{"model":"DelayMono","settings":{"effect":4.5,"feedback":3.5,"sync":true}},"reverb":{"model":"bias.reverb","settings":{"level":2,"length":5,"type":"Saal natürlich"}}}}'),
    ("AC/DC – Back in Black",
     '{"format":"spark-sound-recipe","version":1,"name":"Black Crunch","description":"Trockener Plexi-Crunch ohne Pedale","bpm":94,"tags":["AC/DC","Rock","Crunch"],"notes":"Die Verzerrung kommt nur vom Amp. Zu viel Zerre: amp.gain auf 5; zu dünn: amp.middle rauf.","chain":{"amp":{"model":"Plexi","settings":{"gain":6,"treble":6,"middle":7,"bass":4,"master":7}},"reverb":{"model":"bias.reverb","settings":{"level":1.5,"length":3.5,"type":"Raum A"}}}}'),
    ("Pink Floyd – Comfortably Numb, Solo",
     '{"format":"spark-sound-recipe","version":1,"name":"Numb Solo","description":"Singender Fuzz-Lead mit Echo und großem Saal","bpm":128,"tags":["Pink Floyd","Lead","Fuzz"],"notes":"Der Song läuft mit etwa 64 BPM; bpm steht auf 128, damit das Echo als Achtel (rund 470 ms) kommt. Zu matschig: drive.tone rauf; zu nass: reverb.level runter.","chain":{"compressor":{"model":"BlueComp","settings":{"level":5,"sustain":5}},"drive":{"model":"GuitarMuff","settings":{"sustain":6.5,"tone":4.5,"level":6}},"amp":{"model":"Twin","settings":{"gain":3.5,"treble":5.5,"middle":6,"bass":5,"master":7}},"delay":{"model":"DelayMono","settings":{"effect":3.5,"feedback":3.5,"sync":true}},"reverb":{"model":"bias.reverb","settings":{"level":3.5,"length":7,"type":"Saal mittel"}}}}'),
]

TEMPO_TEXT = """- Mit sync = BPM kommt das Echo als Viertelnote auf "bpm" (60000 / bpm Millisekunden). Ein Sync-Tremolo folgt demselben bpm.
- Für andere Notenwerte stellst du "bpm" um: Viertel → Songtempo; punktierte Achtel (The Edge) → Songtempo × 4/3; Achtel → Songtempo × 2. Bleib zwischen 40 und 250. Nenne das echte Songtempo in "notes".
- Ohne Song: Rhythmus-Echo 300–400 ms, Lead 400–500 ms, Ambient 500–700 ms (bpm = 60000 / ms).
- Slapback (Rockabilly, Country): DelayMono mit sync Frei, range „200 ms“, time 4–5, feedback 0–1."""

REVERB_TEXT = """- Rock, Blues, Crunch: Raum A/B oder Kammer, level 1,5–2,5.
- Ballade, singende Leads: Saal natürlich oder mittel, level 3–4.
- Clean, Pop, Funk: Platte kurz, level 2–3 (Funk unter 1,5).
- Surf: Platte satt, level 5–6 (statt Federhall).
- Ambient, Post-Rock: Saal weit, length 8–9, level 4–5.
- Metal-Rhythmus: aus, oder Raum mit level unter 1."""

VARIANT_HINTS = [
    "Variante A – originalgetreu: der Verstärker, der Verzerrer und die Effekte, die das Vorbild oder das Genre "
    "typischerweise nutzt. Gib dem Sound einen eigenen Namen.",
    "Variante B – druckvoller: eine Gain-Stufe mehr als die naheliegende Wahl (clean → angezerrt, Crunch → Lead) "
    "und ein anderes Verstärker-Modell als das naheliegendste; mehr Mitten und Präsenz. Gib dem Sound einen "
    "eigenen Namen, der das ausdrückt.",
    "Variante C – reduziert und offen: weniger Gain als die naheliegende Wahl, ein anderes Verstärker-Modell, "
    "höchstens zwei Effekte und eine andere Raum-Idee (zum Beispiel Bandecho statt Digital-Delay, Platte statt "
    "Saal). Dynamisch, reagiert auf den Anschlag. Gib dem Sound einen eigenen Namen, der das ausdrückt.",
]
VARIANT_TITLES = ["Originalgetreu", "Druckvoller", "Reduziert"]


def _raw_catalog() -> dict:
    return json.loads(catalog._find_catalog().read_text(encoding="utf-8"))


def catalog_text() -> str:
    """The catalog as a compact list for the prompt: id, character and parameters with keys and exact labels."""
    data = _raw_catalog()
    models = {m["id"]: m for m in data["models"]}
    lines = []
    for place in data["places"]:
        lines.append(f"## {place['title']} (Schlüssel: {place['key']})")
        for model_id in place["models"]:
            model = models.get(model_id)
            if model is None:
                continue
            head = f"- {model['id']} · {model['name']}"
            if model.get("inspiration"):
                head += f" · nach {model['inspiration']}"
            if model.get("group"):
                head += f" · {model['group']}"
            if model.get("pack"):
                head += " · PACK (kostenpflichtig)"
            lines.append(head)
            params = ", ".join(_describe(p) for p in model["parameters"])
            if params:
                lines.append(f"    {params}")
    return "\n".join(lines)


def _describe(parameter: dict) -> str:
    if parameter["kind"] == "switch":
        return f"`{parameter['key']}` Schalter ({parameter.get('off') or 'aus'}/{parameter.get('on') or 'an'})"
    if parameter["kind"] == "choice":
        return f"`{parameter['key']}` Auswahl ({' · '.join(o['label'] for o in parameter.get('options', []))})"
    return f"`{parameter['key']}` (0–10)"


def system_prompt() -> str:
    archetypes = "\n".join(f"- {topic}: {' → '.join(models)} · {advice}" for topic, models, advice in ARCHETYPES)
    examples = "\n\n".join(f"Wunsch: „{wish}“\n{text}" for wish, text in EXAMPLES)
    return f"""Du erstellst Gitarren-Sounds für Positive-Grid-Spark-Verstärker als „Sound-Rezept“ (ein JSON-Objekt). Der Nutzer beschreibt eine Idee, einen Song, eine Band, ein Vorbild oder eine Anweisung – zum Beispiel „Sound für U2 – Where the streets have no name“ oder „Blues-Sound für meine Telecaster“.

Antworte NUR mit einem einzigen JSON-Objekt, ohne Text davor oder danach, in genau diesem Aufbau:

{{
  "format": "spark-sound-recipe",
  "version": 1,
  "name": "kurzer Name, höchstens 31 Bytes (Umlaute zählen doppelt)",
  "description": "ein Satz, was der Sound ist",
  "bpm": 120,
  "tags": ["Stil", "Stimmung"],
  "notes": "was man zuerst nach Gehör drehen sollte und warum",
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

Regeln:
- Es gibt genau diese sieben Plätze in fester Reihenfolge: gate, compressor, drive, amp, modulation, delay, reverb. Einen Platz, der nicht klingen soll, lässt du weg (kein Eintrag) oder setzt "on": false.
- Jeder Platz hat genau EIN "model". Nutze ausschließlich Modell-IDs aus dem Katalog unten, exakt so geschrieben (Groß-/Kleinschreibung zählt).
- "settings" nutzt ausschließlich die Parameter-Schlüssel dieses Modells aus dem Katalog. Regler: Zahl von 0 bis 10. Schalter: true/false oder genau die angegebenen Labels. Auswahl: genau ein angegebenes Label (deutsch).
- Ein weggelassener Wert behält den Startwert des Verstärkers. Setze gain, treble, middle, bass und master beim Amp immer ausdrücklich.
- Der EQ ist eine Modulation (GuitarEQ6 oder BassEQ6). Am Modulations-Platz steht entweder ein EQ oder ein Chorus/Phaser/Tremolo, nie beides.
- Das Wah des kostenpflichtigen Zusatzpakets sitzt am compressor-Platz. Vermeide Modelle mit „PACK“, außer der Nutzer verlangt sie ausdrücklich.
- Es gibt genau ein Hall-Modell (bias.reverb); sein „type“ wählt Raum, Kammer, Saal oder Platte. Einen Federhall gibt es nicht.
- Verstärker haben fünf Regler: gain, treble, middle, bass, master (Paket-Amps nennen ihn volume).
- Bei einem Song setze "bpm" passend zum Tempo des Songs (siehe Tempo und Delay-Zeit), sonst 120.
- Wenn eine „Ausrichtung dieser Variante“ dasteht, halte dich daran. Varianten sollen hörbar verschieden sein: anderer Verstärker, andere Gain-Stufe oder andere Effekt-Idee.

So wählst du (Ausgangspunkte, kein Gesetz):
- Strahlend clean, Jazz, Funk: Twin, RolandJC120, 94MatchDCV2 (clean)
- Clean, das beim Anschlag aufbricht: ODS50CN, Deluxe65, BluesJrTweed
- Britischer Glanz, 60er-Pop, Indie: AC Boost, Bassman (bright)
- Classic-Rock-Rhythmus: Plexi, OverDrivenJM45 (crunch)
- Blues-Lead: Bassman oder OverDrivenLuxVerb, angetrieben von DistortionTS9
- Singendes Lead, Fusion: SLO100, Bogner, ODS50CN mit Drive (highGain)
- 80er-Hardrock: EVH, SwitchAxeLead, YJM100
- Modern Metal: 6505Plus, Rectifier, BE101 (metal)
- Akustik: AcousticAmpV2, FatAcousticV2 · Bass: GK800, Sunny3000, W600, Hammer500

Vorbilder – typische Signalketten (Ausgangspunkte, nur mit Modellen aus dem Katalog):
{archetypes}

Gain-Staging (Regler 0–10):
- Clean: amp.gain 2–4 · am Rand des Aufbrechens: 4,5–6 · Crunch: 5–7 · High-Gain-Verstärker meist 5–7, über 8 wird es fizzelig und rauschig.
- master ist Lautstärke, nicht Verzerrung: 6–8. Ein Set soll ähnlich laut sein.
- High-Gain straffen: Drive davor fast ohne Gain, hoher Level (DistortionTS9 drive 0–1,5, level 7–9), oder Booster.
- Crunch zu Lead pushen: DistortionTS9 drive 2–4.

EQ-Wörter (was der Nutzer sagt → was du drehst):
- wärmer/dunkler: treble 1–2 runter (bei Drives tone runter)
- heller/mehr Glanz: treble 1 rauf, Hall highCut rauf
- matschig/wummernd: bass 1–2 runter
- dünn/scharf: bass rauf, treble runter, weniger gain
- mehr Biss/Durchsetzung: middle 1–2 rauf
- scooped/schwerer Rhythmus: middle auf 3–4, nicht unter 3
- mehr Sustain: Kompressor BlueComp sustain 6–7, oder mehr gain
- Funk-Spank: LA2AComp oder Compressor, cleaner Amp, wenig Hall

Zeit-Effekte:
- Delay: level/mix 2–3 für Rhythmus, 3–4 für Leads; feedback 2–4 (wenige Wiederholungen), über 7 läuft es weg.
- Modulation: Chorus effect 3–5, rate niedrig; Tremolo speed 4–6 für Surf-Puls.
- Gate: threshold 1,5–3 Crunch, 3–5 High-Gain; für clean aus.

Tempo und Delay-Zeit:
{TEMPO_TEXT}

Hall nach Stil:
{REVERB_TEXT}

Halte es einfach: wenige, passende Effekte statt alles auf einmal. Wähle zuerst den Verstärker, dann baue darum herum. Schreibe in "notes", welche ein bis zwei Regler der Spieler zuerst nach Gehör drehen soll.

BEISPIELE – gültige Rezepte in genau der verlangten Form:

{examples}

KATALOG – nutze nur diese Modell-IDs, Parameter-Schlüssel und Labels:

{catalog_text()}"""


def messages(request: str, hint: str = "") -> list[dict]:
    suffix = f"\n\nAusrichtung dieser Variante: {hint}" if hint else ""
    return [{"role": "system", "content": system_prompt()},
            {"role": "user", "content": f"Nutzerwunsch: {request}{suffix}"}]


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
        raise AIError("unreadable", f"Ungültiges JSON: {error}")
    if not isinstance(data, dict) or data.get("format") != recipemod.FORMAT:
        raise AIError("unreadable", f"Das Feld „format“ muss „{recipemod.FORMAT}“ sein.")
    if not isinstance(data.get("name"), str):
        raise AIError("unreadable", "Das Feld „name“ fehlt im JSON.")
    chain = data.get("chain", {})
    if not isinstance(chain, dict) or any(not isinstance(u, dict) or not isinstance(u.get("model"), str)
                                          for u in chain.values()):
        raise AIError("unreadable", "Falscher Typ bei „chain“.")
    try:
        recipemod.to_preset(data)
    except recipemod.RecipeError as error:
        raise AIError("invalid", "\n".join(error.messages))
    except (TypeError, ValueError, AttributeError) as error:
        raise AIError("unreadable", f"Falscher Typ: {error}")
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
            correction = ("Deine Antwort enthielt kein JSON-Objekt. Antworte ohne jede Erklärung."
                          if error.kind == "no_json" else f"Dein JSON war nicht lesbar. Fehler:\n{error}")
        history.append({"role": "user", "content": correction
                        + "\n\nAntworte erneut NUR mit dem vollständigen, korrigierten JSON-Objekt."})
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
    return f"gleicher Verstärker „{amp}“" + (f" und gleicher Verzerrer „{drive}“" if drive else ", beide ohne Verzerrer")


def distinctness(data: dict, others: list[dict]) -> str | None:
    for other in others:
        reason = resemblance(data, other)
        if reason:
            return (f"Dieser Vorschlag klingt zu ähnlich wie „{other.get('name')}“ ({reason}). Baue eine hörbar andere "
                    "Variante: wähle ein anderes Verstärker-Modell und passe Verzerrer und Effekte dazu an. Behalte die "
                    "Ausrichtung dieser Variante und gib ihr einen anderen Namen.")
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

    pool = concurrent.futures.ThreadPoolExecutor(max_workers=len(hints), thread_name_prefix="spark-ai")
    futures = [pool.submit(one, index, hint) for index, hint in enumerate(hints)]
    pool.shutdown(wait=False)
    done: concurrent.futures.Future = concurrent.futures.Future()
    threading.Thread(target=lambda: (concurrent.futures.wait(futures), done.set_result(None)), daemon=True).start()
    return done


# MARK: Refinement

ADJUSTMENTS = {
    "warmer": {"label": "wärmer", "nudge": "Höhen am Amp −1,5",
               "instruction": "Mach den Sound wärmer: amp.treble 1–2 runter, bei einem Verzerrer auch dessen tone "
                              "etwas runter, beim Hall highCut etwas runter."},
    "moreGain": {"label": "mehr Gain", "nudge": "Gain am Amp +1,5",
                 "instruction": "Gib dem Sound mehr Gain: amp.gain um 1–2 rauf, oder einen passenden Verzerrer "
                                "einschalten bzw. dessen Gain erhöhen. master höchstens etwas senken, damit es gleich "
                                "laut bleibt."},
    "lessReverb": {"label": "weniger Hall", "nudge": "Hall-Pegel −1,5",
                   "instruction": "Mach den Hall deutlich weniger: reverb.level um 1–2 runter, bei Bedarf auch length "
                                  "kürzer."},
    "brighter": {"label": "heller", "nudge": "Höhen am Amp +1,5",
                 "instruction": "Mach den Sound heller: amp.treble 1–2 rauf, bei einem Verzerrer dessen tone etwas "
                                "rauf, beim Hall highCut etwas rauf."},
}


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
        return "Der Sound hat keinen Hall." if active_model(data, "reverb") is None or level <= 0 else None
    if adjustment == "moreGain":
        gain = value(data, "amp", "gain") or 0
        return "Mehr Gain geht nicht." if gain >= 10 and active_model(data, "drive") is not None else None
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
    label = ADJUSTMENTS[adjustment]["label"]
    for place in PLACES:
        if place in open_places:
            continue
        before = active_model(old, place)
        if before is None:
            continue
        if adjustment == "lessReverb" and place == "reverb" and active_model(new, place) is None:
            continue
        if active_model(new, place) != before:
            return (f"Du hast am Platz {place} „{before}“ ersetzt oder ausgeschaltet. Behalte alle Modelle und ändere "
                    f"nur die Regler, die für „{label}“ nötig sind.")
    if not is_applied(adjustment, old, new):
        return f"Das Rezept ist nicht „{label}“ geworden. {ADJUSTMENTS[adjustment]['instruction']}"
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
    direction it goes back once; if still wrong, Spark Studio turns the obvious knob itself and says so."""
    reason = impossibility(adjustment, data)
    if reason:
        raise AIError("not_possible", reason)
    wish = checked_request(request)
    info = ADJUSTMENTS[adjustment]
    start = messages(wish) + [
        {"role": "assistant", "content": json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False)},
        {"role": "user", "content": f"Passe genau dieses Rezept an: {info['label']}. {info['instruction']}\n"
                                    "Behalte den Namen, den Verstärker und alle anderen Modelle. Ändere nur die Regler, "
                                    "die dafür nötig sind, und lass alles andere unverändert. Passe \"notes\" in einem "
                                    "Satz an.\nAntworte NUR mit dem vollständigen JSON-Objekt."},
    ]
    new, unresolved = converse(start, chat, 0.2, check=lambda n: complaint(adjustment, data, n), cancelled=cancelled)
    note = None
    if unresolved is not None:
        new = nudged(adjustment, data)
        note = (f"Das Modell hat „{info['label']}“ nicht sauber umgesetzt. Spark Studio hat selbst nachgestellt "
                f"({info['nudge']}).")
    new = copy.deepcopy(new)
    new["name"], new["tags"] = data.get("name"), list(data.get("tags", []))
    return new, note
