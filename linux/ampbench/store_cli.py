"""The sound store from the command line, for a first setup, a script or a scheduled backup. The same commands as
the Mac app (Sources/AmpBench/StoreCommandLine.swift):

    --store-setup folder <path>          keep the encrypted sounds in a folder (also one a cloud drive syncs)
    --store-setup ssh <host> <path>      keep them on a server, through this computer's ssh
    --store-setup https <url> [user]     keep them below an HTTPS address; the password is read from standard input
    --store-key new                      make this device's key; prints only its public half
    --store-key set                      take a key from standard input (the key of a store you already have)
    --store-key show                     print the key, to write it down or to enter it on another device
    --store-sync                         bring the presets folder and the store in step, both ways
    --store-verify                       read every sound back from the store, open it and compare it; changes nothing
    --store-status                       where the store is, when it last synced, which folder it keeps

`--presets-folder DIR` names the folder of sounds; `--store-profile DIR` keeps settings, key and state in DIR, apart
from the real store (for tests)."""
from __future__ import annotations

import os
import sys
from pathlib import Path

from .age import AgeError
from .i18n import tr
from .library import LibraryError, default_folder
from .store_places import StoreError
from .store_profile import FOLDER, HTTP, SSH, ProfileError, StoreProfile, StoreSettings

USAGE = 64


def wanted(args) -> bool:
    return bool(args.store_setup or args.store_key or args.store_sync or args.store_verify or args.store_status)


def profile_for(args) -> StoreProfile:
    return StoreProfile.testing(Path(args.store_profile)) if args.store_profile else StoreProfile.standard()


def run(args, stdin=None) -> int:
    """The exit status: 0, 1 when it failed, 64 for arguments that are no command."""
    stdin = stdin or sys.stdin
    folder = Path(args.presets_folder) if args.presets_folder else default_folder()
    profile = profile_for(args)
    try:
        if args.store_setup:
            return _setup(args.store_setup, profile, stdin)
        if args.store_key:
            return _key(args.store_key, profile, stdin)
        if args.store_sync:
            return _sync(folder, profile)
        if args.store_verify:
            return _verify(folder, profile)
        return _status(folder, profile)
    except (StoreError, ProfileError, AgeError, LibraryError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1


def _first_line(stdin) -> str | None:
    line = stdin.readline()
    return line.rstrip("\r\n") if line else None


def _setup(arguments: list[str], profile: StoreProfile, stdin) -> int:
    password = None
    kind, count = arguments[0], len(arguments)
    if kind == "folder" and count == 2:
        # Written out in full: the next sync may start from another working folder.
        settings = StoreSettings(FOLDER, folder_path=os.path.abspath(os.path.expanduser(arguments[1])))
    elif kind == "ssh" and count == 3:
        settings = StoreSettings(SSH, host=arguments[1], path=arguments[2])
    elif kind == "https" and count in (2, 3):
        user = arguments[2] if count == 3 else None
        settings = StoreSettings(HTTP, url=arguments[1], user=user)
        # Never an argument: other processes can read a command line.
        if user is not None:
            password = _first_line(stdin)
    else:
        print("usage: --store-setup folder <path> | ssh <host> <path> | https <url> [user]  "
              "(password on standard input)")
        return USAGE
    profile.save(settings, password)
    print(tr("The sound store is set up: {}.", settings.summary))
    if not profile.has_key:
        print(tr("This device has no key yet: --store-key new makes one, --store-key set takes one you have."))
    return 0


def _key(command: str, profile: StoreProfile, stdin) -> int:
    if command == "new":
        identity = profile.create_key()
        print(tr("A new key is kept {}. Its public half: {}", profile.key_place, identity.recipient))
        print(tr("Write the key itself down: --store-key show prints it, and so does “Show key” in the app. Without "
                 "it nobody can read the store."))
    elif command == "set":
        # The first line that is a key: a file made by `age-keygen` starts with comment lines.
        lines = (line.strip() for line in stdin)
        text = next((line for line in lines if line and not line.startswith("#")), None)
        if text is None:
            return USAGE
        identity = profile.use_key(text)
        print(tr("The key is kept {}. Its public half: {}", profile.key_place, identity.recipient))
    elif command == "show":
        identity = profile.identity
        if identity is None:
            raise ProfileError(ProfileError.NO_KEY)
        print(identity.text)
    else:
        print("usage: --store-key new | set (key on standard input) | show")
        return USAGE
    return 0


def _sync(folder: Path, profile: StoreProfile) -> int:
    from .library import _trash
    report = profile.sync(folder, _trash)
    print(report.summary)
    for label, names in ((tr("stored"), report.uploaded), (tr("fetched"), report.downloaded),
                         (tr("removed here"), report.removed_locally),
                         (tr("removed in the store"), report.marked_deleted)):
        for name in names:
            print(f"  {label}: {name}")
    return 0


def _verify(folder: Path, profile: StoreProfile) -> int:
    report = profile.verify(folder)
    print(report.summary)
    for label, names in ((tr("missing in the store"), report.missing), (tr("damaged in the store"), report.damaged),
                         (tr("differs here"), report.differing), (tr("only in the store"), report.not_here),
                         (tr("only here"), report.not_stored)):
        for name in names:
            print(f"  {label}: {name}")
    return 0 if report.is_restorable else 1


def _status(folder: Path, profile: StoreProfile) -> int:
    settings = profile.settings
    if settings is None:
        print(tr("The sound store is not set up on this device."))
        return 0
    print(tr("Place: {}", settings.summary))
    print(tr("Key: {}", profile.key_place) if profile.has_key else tr("Key: none on this device"))
    date = profile.last_sync
    print(tr("Last sync: {}", date.strftime("%Y-%m-%dT%H:%M:%SZ")) if date else tr("Last sync: never"))
    print(tr("Sounds folder: {}", folder))
    return 0
