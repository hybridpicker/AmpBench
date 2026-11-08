"""Colors and the stylesheet. Always dark, like the Mac app, and quiet next to Omarchy's own themes."""
from __future__ import annotations

from PySide6.QtGui import QColor

from .. import catalog

BG = "#15171a"
PANEL = "#1d2024"
PANEL_HI = "#262a30"
LINE = "#33383f"
TEXT = "#e6e8eb"
MUTED = "#8b929c"
ACCENT = "#f2b84b"
GOOD = "#5ec28a"
BAD = "#e5604f"


def place_color(place: str) -> QColor:
    r, g, b = catalog.PLACE_COLORS[place]
    return QColor.fromRgbF(r, g, b)


STYLESHEET = f"""
* {{ font-family: "Inter", "Noto Sans", "DejaVu Sans", sans-serif; font-size: 13px; }}
QMainWindow, QWidget#root {{ background: {BG}; }}
QWidget {{ color: {TEXT}; }}
QLabel#muted, QLabel[muted="true"] {{ color: {MUTED}; }}
QLabel#section {{ color: {MUTED}; font-size: 11px; font-weight: 600; letter-spacing: 1px; }}
QLabel#title {{ font-size: 15px; font-weight: 600; }}
QFrame#sidebar {{ background: {PANEL}; border-right: 1px solid {LINE}; }}
QFrame#card {{ background: {PANEL}; border: 1px solid {LINE}; border-radius: 10px; }}
QListWidget {{ background: transparent; border: none; outline: none; }}
QListWidget::item {{ padding: 6px 8px; border-radius: 6px; }}
QListWidget::item:selected {{ background: {PANEL_HI}; color: {TEXT}; }}
QListWidget::item:hover {{ background: {PANEL_HI}; }}
QLineEdit, QSpinBox, QComboBox, QPlainTextEdit {{
    background: {BG}; border: 1px solid {LINE}; border-radius: 6px; padding: 5px 8px; selection-background-color: {ACCENT};
    selection-color: #000; }}
QLineEdit:focus, QSpinBox:focus, QComboBox:focus {{ border-color: {ACCENT}; }}
QComboBox QAbstractItemView {{ background: {PANEL}; border: 1px solid {LINE}; selection-background-color: {PANEL_HI}; }}
QPushButton {{ background: {PANEL_HI}; border: 1px solid {LINE}; border-radius: 6px; padding: 6px 12px; }}
QPushButton:hover {{ border-color: {MUTED}; }}
QPushButton:disabled {{ color: {MUTED}; background: {PANEL}; }}
QPushButton:checked {{ background: {ACCENT}; color: #1a1300; border-color: {ACCENT}; }}
QPushButton#primary {{ background: {ACCENT}; color: #1a1300; border-color: {ACCENT}; font-weight: 600; }}
QPushButton#primary:disabled {{ background: {PANEL_HI}; color: {MUTED}; border-color: {LINE}; }}
QStatusBar {{ background: {PANEL}; border-top: 1px solid {LINE}; color: {MUTED}; }}
QMenuBar {{ background: {PANEL}; }}
QMenuBar::item:selected, QMenu::item:selected {{ background: {PANEL_HI}; }}
QMenu {{ background: {PANEL}; border: 1px solid {LINE}; }}
QToolTip {{ background: {PANEL_HI}; color: {TEXT}; border: 1px solid {LINE}; }}
QProgressBar {{ background: {BG}; border: 1px solid {LINE}; border-radius: 4px; max-height: 8px; }}
QProgressBar::chunk {{ background: {ACCENT}; border-radius: 3px; }}
QScrollBar:vertical {{ background: transparent; width: 10px; }}
QScrollBar::handle:vertical {{ background: {LINE}; border-radius: 5px; min-height: 24px; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
"""
