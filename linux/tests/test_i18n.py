import ast
import string
from pathlib import Path

import pytest

from ampbench import i18n
from ampbench.de import GERMAN_TEXTS

PACKAGE = Path(i18n.__file__).parent


@pytest.fixture(autouse=True)
def english_again():
    yield
    i18n.set_language(i18n.ENGLISH)


def test_only_a_german_locale_chooses_german():
    assert i18n.language_for("de_AT.UTF-8") == i18n.GERMAN
    assert i18n.language_for("de") == i18n.GERMAN
    assert i18n.language_for("en_US.UTF-8") == i18n.ENGLISH
    assert i18n.language_for("denmark") == i18n.ENGLISH
    assert i18n.language_for(None) == i18n.ENGLISH


def test_environment_wins_over_the_choice(monkeypatch):
    monkeypatch.setenv(i18n.ENVIRONMENT_KEY, "de")
    assert i18n.decide("en") == i18n.GERMAN
    monkeypatch.delenv(i18n.ENVIRONMENT_KEY)
    assert i18n.decide("en") == i18n.ENGLISH


def test_arguments_and_numbers_follow_the_language():
    assert i18n.tr("{} of {}", 2, "four") == "2 of four"
    assert i18n.number(1.5) == "1.5"
    i18n.set_language(i18n.GERMAN)
    assert i18n.number(1.5) == "1,5"
    assert i18n.tr("zzz no such text zzz") == "zzz no such text zzz"


def _fields(text: str) -> list[str]:
    return sorted(name or "" for _, name, _, _ in string.Formatter().parse(text) if name is not None)


def test_german_keeps_the_placeholders():
    for english, german in GERMAN_TEXTS.items():
        assert _fields(english) == _fields(german), english


def test_every_text_in_the_sources_has_german():
    missing = []
    for file in sorted(PACKAGE.rglob("*.py")):
        if file.name in ("de.py", "i18n.py"):
            continue
        for node in ast.walk(ast.parse(file.read_text(encoding="utf-8"))):
            if (isinstance(node, ast.Call) and getattr(node.func, "id", getattr(node.func, "attr", "")) == "tr"
                    and node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str)):
                if node.args[0].value not in GERMAN_TEXTS:
                    missing.append(f"{file.name}: {node.args[0].value}")
    assert not missing, "no German text for:\n" + "\n".join(missing)


def test_tables_agree_on_shared_keys():
    from ampbench.de_core import GERMAN_CORE
    from ampbench.de_ui import GERMAN_UI
    differing = [key for key in GERMAN_CORE.keys() & GERMAN_UI.keys() if GERMAN_CORE[key] != GERMAN_UI[key]]
    assert not differing, differing
