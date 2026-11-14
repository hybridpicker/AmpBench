"""Entry point: ``ampbench`` opens the window, ``--recipe-check FILE`` checks a sound recipe without one."""
from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

from . import version_line
from . import i18n
from .i18n import tr


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ampbench", description=tr("AmpBench for Linux: presets, recording and tuner for Positive Grid amps"))
    parser.add_argument("--version", action="store_true", help="print the version and exit")
    parser.add_argument("--recipe-check", metavar="FILE", help="check a sound recipe and exit")
    parser.add_argument("--kemper-list", metavar="FILE", help="show what a Kemper import would make and exit")
    parser.add_argument("--demo", action="store_true", help="use a simulated amp and a temporary presets folder")
    parser.add_argument("--presets-folder", metavar="DIR", help="folder of the saved presets (default ~/Music/AmpBench/Presets)")
    parser.add_argument("--recordings-folder", metavar="DIR", help="folder of the recordings (default ~/Music/AmpBench/Recordings)")
    parser.add_argument("--no-connect", action="store_true", help="do not look for the amp at start")
    parser.add_argument("--screenshot", metavar="PNG", help="render the window to a file and exit (for checks)")
    parser.add_argument("--size", default="1180x760", help="window size for --screenshot")
    parser.add_argument("--open-slot", type=int, metavar="N", help="open the amp's slot N (1 to 4) at start")
    # The sound store without a window (store_cli.py).
    parser.add_argument("--store-setup", nargs="+", metavar="ARG",
                        help="where the sound store is: folder DIR | ssh HOST DIR | https URL [USER] "
                             "(password on standard input)")
    parser.add_argument("--store-key", metavar="new|set|show",
                        help="make the store's key, take one from standard input, or print it")
    parser.add_argument("--store-sync", action="store_true", help="bring the presets folder and the sound store in step")
    parser.add_argument("--store-verify", action="store_true", help="read every sound back from the store and compare it")
    parser.add_argument("--store-status", action="store_true", help="where the sound store is and when it last synced")
    parser.add_argument("--store-profile", metavar="DIR",
                        help="keep the store's settings, key and state in DIR, apart from the real store (for tests)")
    args = parser.parse_args(argv)

    if args.version:
        print(version_line())
        return 0
    if args.recipe_check:
        from .recipe import check_file
        return check_file(args.recipe_check)
    if args.kemper_list:
        from .kemper import list_file
        return list_file(args.kemper_list)

    from . import store_cli
    if store_cli.wanted(args):
        return store_cli.run(args)

    if not args.demo:
        # Presets, takes and settings from the time the app was called Spark Studio.
        from .migrate import carry_over
        carry_over()

    from PySide6.QtCore import QSettings, QTimer
    from PySide6.QtGui import QIcon
    from PySide6.QtWidgets import QApplication

    from .library import PresetLibrary
    from .qtlink import QtLink
    from .ui import theme
    from .ui.main_window import MainWindow

    # The user's language choice, before any window is built. The environment wins, then this, then the system.
    i18n.set_language(i18n.decide(QSettings("local.ampbench", "AmpBench").value(i18n.SETTINGS_KEY)))

    app = QApplication(sys.argv[:1])
    app.setApplicationName("AmpBench")
    app.setDesktopFileName("ampbench")
    app.setStyle("Fusion")
    app.setFont(theme.sans(13))
    app.setStyleSheet(theme.stylesheet())
    icon = _find_icon()
    if icon:
        app.setWindowIcon(QIcon(str(icon)))

    folder = Path(args.presets_folder) if args.presets_folder else None
    factory = None
    if args.demo:
        from .fake_amp import FakeAmp
        amp = FakeAmp(delay=0.01)
        factory = lambda: amp  # noqa: E731 - the same simulated amp on every reconnect
        if folder is None:
            folder = Path(tempfile.mkdtemp(prefix="ampbench-demo-"))
            _seed_demo(PresetLibrary(folder))
    link = QtLink(factory) if factory else QtLink()
    from .recorder import RecorderModel
    from .store import LibraryStore
    recordings = Path(args.recordings_folder) if args.recordings_folder else None
    devices = None
    engine = None
    if args.demo:
        from .demo_input import demo_engine, demo_devices
        engine, devices = demo_engine(), demo_devices
        recordings = recordings or Path(tempfile.mkdtemp(prefix="ampbench-demo-recordings-"))
    recorder_args = {"devices": devices} if devices else {}
    recorder = RecorderModel(LibraryStore(recordings), engine, **recorder_args)
    window = MainWindow(link, PresetLibrary(folder), auto_connect=not args.no_connect, recorder=recorder)
    # Only here does a window get the real sound store; the simulated amp's sounds stay out of it.
    from .store_profile import StoreProfile
    window.store.use_profile(StoreProfile.testing(Path(tempfile.mkdtemp(prefix="ampbench-demo-store-")))
                             if args.demo and not args.store_profile else store_cli.profile_for(args))
    if args.size and "x" in args.size:
        w, h = args.size.split("x")
        window.resize(int(w), int(h))
    window.show()

    if args.open_slot:
        QTimer.singleShot(1500, lambda: window._slot_clicked(args.open_slot - 1))
    if args.screenshot:
        def shoot():
            window.grab().save(args.screenshot)
            window.link.shutdown()
            app.quit()
        QTimer.singleShot(3200, shoot)
    return app.exec()


def _find_icon() -> Path | None:
    here = Path(__file__).resolve().parent
    for candidate in (here / "data" / "AppIcon.png", here.parent.parent / "Resources" / "AppIcon.png"):
        if candidate.is_file():
            return candidate
    return None


def _seed_demo(library) -> None:
    from . import factory
    for template in factory.templates()[:3]:
        library.save(factory.make(template, f"Demo {template.name}"), "Demo")


if __name__ == "__main__":
    raise SystemExit(main())
