"""Times, dates and numbers as the window shows them, in the app's language."""
from __future__ import annotations

from datetime import datetime

from .. import i18n
from ..i18n import tr

# Month names are written out here: strftime("%b") follows the process locale, which Qt sets from the system.
_MONTHS = {
    i18n.ENGLISH: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
    i18n.GERMAN: ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sep.", "Okt.", "Nov.", "Dez."],
}


def _german() -> bool:
    return i18n.language() == i18n.GERMAN


def decimal_sign() -> str:
    return "," if _german() else "."


def clock(seconds: float, tenths: bool = False) -> str:
    """Minutes and seconds, `01:05`, with tenths `01:05.3` (German `01:05,3`)."""
    seconds = max(seconds, 0.0)
    text = f"{int(seconds) // 60:02d}:{int(seconds) % 60:02d}"
    return text + (f"{decimal_sign()}{int(seconds * 10) % 10}" if tenths else "")


def signed(value: float, digits: int = 1) -> str:
    """A number that always carries its sign: `+1.5`, `-3.0`."""
    return ("+" if value >= 0 else "-") + i18n.number(abs(value), digits)


def _month(date: datetime) -> str:
    return _MONTHS[i18n.language()][date.month - 1]


def date_time(date: datetime, seconds: bool = False) -> str:
    """`Nov 5, 2026, 14:03`, German `5. Nov. 2026, 14:03`."""
    local = date.astimezone()
    time = local.strftime("%H:%M:%S" if seconds else "%H:%M")
    if _german():
        return f"{local.day}. {_month(local)} {local.year}, {time}"
    return f"{_month(local)} {local.day}, {local.year}, {time}"


def short_date_time(date: datetime) -> str:
    """For a table column: `11/05/26, 14:03`, German `05.11.26, 14:03`."""
    return date.astimezone().strftime("%d.%m.%y, %H:%M" if _german() else "%m/%d/%y, %H:%M")


def day_month(date) -> str:
    """For a chart's axis: `11/05`, German `05.11.`."""
    return date.strftime("%d.%m." if _german() else "%m/%d")


def channels(count: int) -> str:
    return tr("Mono") if count == 1 else tr("Stereo") if count == 2 else tr("{} channels", count)


def minutes_text(minutes: float) -> str:
    if minutes < 1:
        return tr("{} s", round(minutes * 60))
    hours, rest = divmod(round(minutes), 60)
    return tr("{} h {} min", hours, rest) if hours else tr("{} min", rest)


def khz(rate: float) -> str:
    """A sample rate in kilohertz: `44.1 kHz`, German `44,1 kHz`."""
    text = f"{rate / 1000:g}"
    return (text.replace(".", ",") if _german() else text) + " kHz"
