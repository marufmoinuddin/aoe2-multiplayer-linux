#!/usr/bin/env python3
"""Uninstaller for the AoE II Classic + Voobly Linux installer.

Removes what the installer created: the dedicated Wine prefix, the Wine
runner, wrappers, launchers, desktop entries, icons, state, logs, caches and
prefix backups. It never touches the original game directory, the Voobly
setup executable, or system Wine, and lists the full inventory before
deleting anything.

Usage:
    ./uninstall_aoe2_voobly.py                  interactive removal
    ./uninstall_aoe2_voobly.py --dry-run        show what would be removed
    ./uninstall_aoe2_voobly.py --purge-backups  also remove game-dir backups
    ./uninstall_aoe2_voobly.py --purge-legacy   also remove the previous aoe2-voobly data
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import signal
import sys
import time
from pathlib import Path

HOME = Path.home()
DATA = Path(os.environ.get('XDG_DATA_HOME', HOME / '.local/share')) / 'aoe2-multiplayer-linux'
CACHE = Path(os.environ.get('XDG_CACHE_HOME', HOME / '.cache')) / 'aoe2-multiplayer-linux'
# The previous aoe2-voobly layout is only touched when explicitly requested.
LEGACY_DATA = Path(os.environ.get('XDG_DATA_HOME', HOME / '.local/share')) / 'aoe2-voobly'
LEGACY_CACHE = Path(os.environ.get('XDG_CACHE_HOME', HOME / '.cache')) / 'aoe2-voobly'
APPS = DATA.parent / 'applications'
ICON_ROOT = DATA.parent / 'icons'
COLOR = sys.stdout.isatty() and not os.environ.get('NO_COLOR')
DRY = '--dry-run' in sys.argv[1:]
PURGE_BACKUPS = '--purge-backups' in sys.argv[1:]
PURGE_LEGACY = '--purge-legacy' in sys.argv[1:]

removed = []


def say(text, color='36'):
    print(('\033[' + color + 'm' + text + '\033[0m') if COLOR else text, flush=True)


def ask(text, default=''):
    value = input(f'{text}' + (f' [{default}]' if default else '') + ': ').strip()
    return value or str(default)


def yes(text, default=False):
    value = ask(text + (' [Y/n]' if default else ' [y/N]')).lower()
    return value in (('y', 'yes', '') if default else ('y', 'yes'))


def human(n):
    return f'{n / 1048576:.1f} MiB'


def tree_size(path):
    total = 0
    stack = [path]
    while stack:
        p = stack.pop()
        try:
            if p.is_symlink():
                continue
            if p.is_dir():
                stack.extend(p.iterdir())
            else:
                total += p.stat().st_size
        except OSError:
            pass
    return total


def ident(prefix):
    return hashlib.sha256(str(prefix).encode()).hexdigest()[:12]


def collect_states():
    states = []
    inst = DATA / 'installs'
    for sf in sorted(inst.glob('*.json')) if inst.is_dir() else []:
        try:
            states.append((sf, json.loads(sf.read_text())))
        except Exception as exc:
            say(f'Warning: unreadable state {sf}: {exc}', '33')
    return states


def find_prefixes(states):
    idents = {sf.stem for sf, _ in states}
    prefixes, seen = [], set()

    def add(raw, source=None):
        if not raw:
            return
        p = Path(str(raw)).expanduser().absolute()
        if str(p) in seen:
            return
        if p == HOME or p == Path('/') or p == DATA:
            say(f'Refusing to treat {p} as a prefix.', '31')
            return
        managed = str(p).startswith(str(DATA) + os.sep) or ident(p) in idents
        if not managed:
            say(f'Skipping unmanaged directory: {p}', '33')
            return
        if source:
            s = Path(source)
            if p == s or p in s.parents or s in p.parents:
                say(f'Skipping prefix nested with the game directory: {p}', '31')
                return
        seen.add(str(p))
        prefixes.append(p)

    for _, st in states:
        summary = st.get('summary') or {}
        add(st.get('prefix') or summary.get('prefix'), st.get('source'))
    if (DATA / 'prefix').exists():
        add(DATA / 'prefix')
    return prefixes


def game_backups(states):
    found, seen = [], set()

    def add(p):
        if str(p) not in seen:
            seen.add(str(p))
            found.append(p)

    for _, st in states:
        raw = st.get('game_backup')
        if raw and Path(raw).exists():
            add(Path(raw))
        src = st.get('source')
        if src:
            s = Path(src)
            if s.is_dir():
                for b in s.parent.iterdir():
                    if b.name.startswith(s.name + '.backup-'):
                        add(b)
    return found


def installer_lock():
    if not DATA.is_dir():
        return None
    try:
        handle = (DATA / 'installer.lock').open('w')
    except OSError:
        return None
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise RuntimeError('Another installer/uninstaller is already running.')
    return handle


def prefix_pids(prefix):
    hits = []
    needle = f'WINEPREFIX={prefix}'.encode()
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            env = (proc / 'environ').read_bytes().split(b'\0')
        except OSError:
            continue
        if needle in env:
            try:
                comm = (proc / 'comm').read_text().strip()
            except OSError:
                comm = '?'
            hits.append((int(proc.name), comm))
    return hits


def stop_prefix_processes(prefix):
    hits = prefix_pids(prefix)
    if not hits:
        return True
    for pid, comm in hits:
        say(f'  running: pid {pid} ({comm})', '33')
    if DRY:
        return True
    if not yes('Terminate these processes so the prefix can be removed?', True):
        say(f'Kept {prefix}: processes are still running.', '33')
        return False
    for pid, _ in hits:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and prefix_pids(prefix):
        time.sleep(0.5)
    for pid, _ in prefix_pids(prefix):
        if yes(f'PID {pid} is still running. Force-stop it?', True):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        else:
            say(f'Kept {prefix}: pid {pid} is still running.', '33')
            return False
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and prefix_pids(prefix):
        time.sleep(0.5)
    if prefix_pids(prefix):
        say(f'Kept {prefix}: could not stop all processes.', '33')
        return False
    return True


def drop(path, label):
    if not path.exists() and not path.is_symlink():
        return
    removed.append(path)
    if DRY:
        say(f'  [dry-run] remove {label}: {path}')
        return
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()
    say(f'  removed {label}: {path}', '32')


def trim_empty_parents(paths):
    parents = {p.parent for p in paths}
    for parent in sorted(parents, key=lambda p: len(p.parts), reverse=True):
        cur = parent
        while cur != ICON_ROOT and ICON_ROOT in cur.parents:
            try:
                cur.rmdir()
            except OSError:
                break
            cur = cur.parent


def show(label, paths, size=None):
    if not paths:
        say(f'  {label}: none')
        return
    total = size if size is not None else sum(tree_size(p) for p in paths)
    say(f'  {label}: {len(paths)} item(s), {human(total)}')
    for p in paths:
        say(f'    {p}')


def attach_terminal():
    """`curl ... | python3` makes stdin the script; prompts need the terminal."""
    try:
        if sys.stdin is None or not sys.stdin.isatty():
            sys.stdin = open('/dev/tty', 'r', encoding='utf-8', errors='replace')
    except OSError:
        pass


def main():
    if sys.platform != 'linux':
        raise RuntimeError('This utility supports Linux only.')
    attach_terminal()
    if os.geteuid() == 0:
        raise RuntimeError('Run as your desktop user, not root or sudo.')
    lock = installer_lock()
    say('\n╔══════════════════════════════════════════════════════════════╗\n'
        '║     AoE II × Voobly — Linux uninstaller                      ║\n'
        '║     Game directory and Voobly setup are never removed.       ║\n'
        '╚══════════════════════════════════════════════════════════════╝', '1;33')

    states = collect_states()
    prefixes = find_prefixes(states)
    desktops = sorted(APPS.glob('aoe2-voobly-*')) if APPS.is_dir() else []
    icons = sorted(ICON_ROOT.glob('hicolor/*/apps/aoe2-voobly-*')) if ICON_ROOT.is_dir() else []
    backups = game_backups(states)
    managed = [p for p in (DATA, CACHE) if p.exists()]
    legacy = [p for p in (LEGACY_DATA, LEGACY_CACHE) if p.exists()]

    say('\nInventory of installer-managed files:')
    show('Wine prefix(es)', prefixes)
    show('Installer data (runner, translator/box64, launchers, tools, state, logs)', [DATA] if DATA.exists() else [],
         tree_size(DATA) if DATA.exists() else 0)
    show('Download cache', [CACHE] if CACHE.exists() else [], tree_size(CACHE) if CACHE.exists() else 0)
    show('Desktop entries', desktops)
    show('Icons', icons)
    show('Game directory backups (kept unless purged)', backups)
    show('Previous aoe2-voobly layout (optional, kept unless purged)', legacy)

    if not prefixes and not desktops and not icons and not managed and not legacy:
        say('\nNothing to remove. The installation is already gone.', '32')
        return

    for _, st in states:
        if st.get('source'):
            say(f'\nNever removed: game directory {st["source"]}')
    say('Never removed: the Voobly setup executable and any system Wine.')

    if DRY:
        say('\nDry run — nothing will be deleted.', '1;33')
    elif not yes('\nRemove everything listed above?', True):
        say('Cancelled. Nothing was removed.', '33')
        return

    purge = PURGE_BACKUPS
    if backups and not purge and not DRY:
        purge = yes('Also remove the game directory backups listed above?', False)

    purge_legacy = PURGE_LEGACY
    if legacy and not purge_legacy and not DRY:
        purge_legacy = yes('Also remove the previous aoe2-voobly data (old layout)?', False)

    for prefix in prefixes:
        say(f'\nPrefix: {prefix}')
        if not stop_prefix_processes(prefix):
            continue
        drop(prefix, 'prefix')

    say('\nDesktop entries and icons:')
    for path in desktops:
        drop(path, 'desktop entry')
    for path in icons:
        drop(path, 'icon')
    if not DRY and icons:
        trim_empty_parents(icons)

    say('\nInstaller data:')
    drop(DATA, 'installer data')
    drop(CACHE, 'download cache')

    if purge:
        say('\nBackups:')
        for path in backups:
            drop(path, 'game backup')

    if purge_legacy:
        say('\nPrevious layout:')
        for path in legacy:
            if not DRY:
                for proc_prefix in (LEGACY_DATA / 'prefix', LEGACY_DATA / 'routes' / 'wow64' / 'prefix',
                                    LEGACY_DATA / 'routes' / 'box64-wow64' / 'prefix'):
                    if proc_prefix.is_dir():
                        stop_prefix_processes(proc_prefix)
            drop(path, 'previous layout data')

    if not DRY and shutil.which('update-desktop-database') and (desktops or icons):
        from subprocess import run as sp_run
        sp_run(['update-desktop-database', str(APPS)], check=False)

    say(f'\n{"Would remove" if DRY else "Removed"} {len(removed)} item(s).')
    kept = [str(p) for _, st in states if st.get('source') for p in [st['source']]]
    for path in dict.fromkeys(kept):
        say(f'Kept: {path}', '32')
    say('Kept: Voobly setup executable and system Wine.', '32')
    if backups and not purge:
        say('Kept: game directory backups (rerun with --purge-backups to remove).', '33')
    if legacy and not purge_legacy:
        say('Kept: previous aoe2-voobly data (rerun with --purge-legacy to remove).', '33')
    say('\nUninstall complete.' if not DRY else 'Dry run complete.', '1;32')


if __name__ == '__main__':
    if {'-h', '--help'} & set(sys.argv[1:]):
        print(__doc__.strip())
        sys.exit(0)
    unknown = [a for a in sys.argv[1:] if a not in ('--dry-run', '--purge-backups', '--purge-legacy')]
    if unknown:
        print(f'Unknown argument(s): {" ".join(unknown)}', file=sys.stderr)
        print('Usage: uninstall_aoe2_voobly.py [--dry-run] [--purge-backups] [--purge-legacy]', file=sys.stderr)
        sys.exit(2)
    try:
        main()
    except KeyboardInterrupt:
        say('\nCancelled. No further items were removed.', '33')
        sys.exit(130)
    except Exception as exc:
        say(f'\nSTOPPED: {exc}', '31')
        sys.exit(1)
