"""The design language of docs/DESIGN.md: a dark device (deck, pedals, displays) on a dark desk.

The values are the ones of Sources/SparkDesign/Theme.swift. AmpBench is always dark.
"""
from __future__ import annotations

from PySide6.QtGui import QColor, QFont, QFontDatabase

from .. import catalog


def c(value: str, alpha: float | None = None) -> QColor:
    color = QColor(value)
    if alpha is not None:
        color.setAlphaF(alpha)
    return color


# Device, fixed
FRONT_TOP, FRONT_BOTTOM, FRONT_EDGE = "#27272B", "#18181B", "#060607"
BOARD = "#0F0F12"
PANEL_TOP, PANEL_BOTTOM = "#2A2A2F", "#19191C"
DISPLAY, DISPLAY_EDGE = "#0C0B09", "#2A2824"
AMBER, AMBER_DIM, AMBER_HOT = "#F7C45C", "#A8906A", "#FFA02E"
TEXT, TEXT_DIM, ENGRAVING = "#E8E8EA", "#B2B2B8", "#96969E"
RECORD = "#E4332A"
LISTENING = "#F99A22"
ON = "#4BD36A"
LAMP_OFF, LAMP_OFF_TEXT = "#3A3028", "#9E9186"
KEY_TOP, KEY_BOTTOM, KEY_EDGE = "#333338", "#28282C", "#0E0E10"
MAIN_TOP, MAIN_BOTTOM = "#FFD36F", "#EFB64A"
ON_TOP, ON_BOTTOM = "#F0A93A", "#D98F22"
KEY_INK = "#1A1206"
DANGER_TEXT = "#FF8A80"
FIELD, FIELD_EDGE, FIELD_TEXT = "#111113", "#0A0A0C", "#D6D6DA"
SWITCH_OFF, SWITCH_ON, SWITCH_THUMB = "#3A3A40", "#D98F22", "#C9C9CE"

# Desk, dark
DESK = "#1C1C1F"
DESK_ALT = "#232327"
DESK_LINE = "#2E2E33"
DESK_TEXT = "#E8E8EA"
DESK_MUTED = "#8E8E96"
SELECTED_BG = (247, 196, 92, 36)
SELECTED_BAR = "#F7C45C"
WAVE = "#68C6D6"
STAR = "#F2B233"


def place_color(place: str) -> QColor:
    r, g, b = catalog.PLACE_COLORS[place]
    return QColor.fromRgbF(r, g, b)


_mono: str | None = None
_sans: str | None = None


def mono_family() -> str:
    global _mono
    if _mono is None:
        families = set(QFontDatabase.families())
        _mono = next((f for f in ("SF Mono", "JetBrainsMono Nerd Font", "JetBrains Mono", "Noto Sans Mono",
                                  "DejaVu Sans Mono", "Liberation Mono") if f in families), "monospace")
    return _mono


def sans_family() -> str:
    global _sans
    if _sans is None:
        families = set(QFontDatabase.families())
        _sans = next((f for f in ("Inter", "SF Pro Text", "Noto Sans", "Cantarell", "DejaVu Sans")
                      if f in families), "sans-serif")
    return _sans


def mono(size: float, bold: bool = False) -> QFont:
    font = QFont(mono_family())
    font.setPixelSize(int(size))
    font.setBold(bold)
    font.setStyleHint(QFont.Monospace)
    return font


def sans(size: float, bold: bool = False, italic: bool = False, spacing: float = 0.0) -> QFont:
    font = QFont(sans_family())
    font.setPixelSize(int(size))
    font.setBold(bold)
    font.setItalic(italic)
    if spacing:
        font.setLetterSpacing(QFont.PercentageSpacing, 100 + spacing * 100)
    return font


_arrow: str | None = None


def arrow_path() -> str:
    """A small chevron as a PNG file in a temporary folder, for the drop-downs of combo boxes."""
    global _arrow
    if _arrow is None:
        import tempfile
        from PySide6.QtCore import QPointF, Qt
        from PySide6.QtGui import QPainter, QPen, QPixmap
        pixmap = QPixmap(16, 16)
        pixmap.fill(Qt.transparent)
        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setPen(QPen(QColor(DESK_MUTED), 1.8, Qt.SolidLine, Qt.RoundCap))
        painter.drawLine(QPointF(4, 6), QPointF(8, 10))
        painter.drawLine(QPointF(8, 10), QPointF(12, 6))
        painter.end()
        _arrow = str(__import__("pathlib").Path(tempfile.mkdtemp(prefix="ampbench-")) / "chevron.png")
        pixmap.save(_arrow)
    return _arrow


def stylesheet() -> str:
    return f"""
* {{ color: {DESK_TEXT}; }}
QMainWindow, QWidget#root {{ background: {DESK}; }}
QToolTip {{ background: {FRONT_BOTTOM}; color: {TEXT}; border: 1px solid {DESK_LINE}; padding: 4px; }}
QLabel {{ background: transparent; }}
QLineEdit {{ background: {FIELD}; border: 1px solid {FIELD_EDGE}; border-radius: 8px; padding: 6px 10px;
    color: {FIELD_TEXT}; selection-background-color: {AMBER}; selection-color: #000; }}
QLineEdit:focus {{ border-color: {AMBER_DIM}; }}
QScrollArea, QScrollArea > QWidget > QWidget {{ background: transparent; border: none; }}
QMenuBar {{ background: {DESK}; color: {DESK_TEXT}; }}
QMenuBar::item:selected {{ background: {DESK_ALT}; }}
QMenu {{ background: #26262A; border: 1px solid {DESK_LINE}; padding: 4px; }}
QMenu::item {{ padding: 5px 22px 5px 14px; border-radius: 4px; }}
QMenu::item:selected {{ background: {AMBER_DIM}; color: #000; }}
QMenu::item:disabled {{ color: {DESK_MUTED}; }}
QMenu::separator {{ height: 1px; background: {DESK_LINE}; margin: 4px 8px; }}
QStatusBar {{ background: {DESK}; color: {DESK_MUTED}; border-top: 1px solid {DESK_LINE}; }}
QStatusBar QLabel {{ color: {DESK_MUTED}; }}
QScrollBar:vertical {{ background: transparent; width: 10px; }}
QScrollBar::handle:vertical {{ background: {DESK_LINE}; border-radius: 5px; min-height: 24px; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
QMessageBox, QInputDialog, QDialog {{ background: #26262A; }}
QPushButton {{ background: #333338; border: 1px solid {KEY_EDGE}; border-radius: 6px; padding: 5px 14px; }}
QPushButton:hover {{ background: #3A3A40; }}
"""
