#!/usr/bin/env python3
"""AoE II Classic + Voobly installer for Linux (x86_64 native, ARM64 via FEX).

Validated layout: Wine 10.0 x86 (32-bit only) driven through FEX on ARM64,
a pure WINEARCH=win32 prefix, the existing game exposed through the first free
Wine drive letter (Wine may already have claimed G: for a host mount), native
DirectPlay from Winetricks, and runner-pinned launchers.

Use only with game files and installers you trust and are licensed to use.
Wine is not a security sandbox. State and logs are user-local.
"""
from __future__ import annotations

import datetime as dt
import fcntl
import hashlib
import json
import logging
import os
import platform
import re
import shlex
import shutil
import signal
import struct
import subprocess as sp
import sys
import tarfile
import tempfile
import time
import urllib.request
from pathlib import Path

HOME = Path.home()
DATA = Path(os.environ.get('XDG_DATA_HOME', HOME / '.local/share')) / 'aoe2-voobly'
CACHE = Path(os.environ.get('XDG_CACHE_HOME', HOME / '.cache')) / 'aoe2-voobly'
APPS = DATA.parent / 'applications'
ICONS = DATA.parent / 'icons/hicolor/256x256/apps'
COLOR = sys.stdout.isatty() and not os.environ.get('NO_COLOR')
STAMP = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
LOG = DATA / 'logs' / (STAMP + '.log')

WINE_VERSION = '10.0'
WINE_ARCHIVE = f'wine-{WINE_VERSION}-x86.tar.xz'
WINE_SHA256 = 'c5be273749f5c513b3edf7ad79d8214be558b80c67c6ca343d2f17fdcc30c2d2'
WINE_URL = f'https://github.com/Kron4ek/Wine-Builds/releases/download/{WINE_VERSION}/{WINE_ARCHIVE}'
TOTAL_STAGES = 8
DIRECTPLAY_FILES = ('dplayx.dll', 'dpnet.dll', 'dpnhpast.dll', 'dpwsockx.dll')


def say(text, color='36'):
    print(('\033[' + color + 'm' + text + '\033[0m') if COLOR else text, flush=True)


def ask(text, default=''):
    value = input(f'{text}' + (f' [{default}]' if default else '') + ': ').strip()
    return value or str(default)


def yes(text, default=False):
    return ask(text + (' [Y/n]' if default else ' [y/N]')).lower() in (('y', 'yes', '') if default else ('y', 'yes'))


def stage(n, text):
    say(f'\n  [{n}/{TOTAL_STAGES}]  {text}\n' + '─' * 64, '1;36')


def run(argv, env=None, cwd=None, timeout=180, check=True):
    argv = [str(x) for x in argv]
    logging.info('RUN %s cwd=%s', shlex.join(argv), cwd)
    with tempfile.TemporaryFile(mode='w+') as output:
        proc = sp.Popen(argv, env=env, cwd=cwd, stdout=output, stderr=sp.STDOUT,
                        start_new_session=True)
        start = time.monotonic()
        frames = '|/-\\'
        i = 0
        try:
            while proc.poll() is None:
                if timeout and time.monotonic() - start > timeout:
                    raise RuntimeError(f'Timed out: {shlex.join(argv)}. Wine children may still be running; inspect the log.')
                if sys.stdout.isatty():
                    print(f'\r  {frames[i % 4]} Working… {int(time.monotonic()-start)}s', end='', flush=True)
                i += 1
                time.sleep(.15)
        except BaseException:
            # Ctrl+C and timeouts must not leave the Wine application running.
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    proc.wait(8)
                except sp.TimeoutExpired:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.wait()
            raise
        if sys.stdout.isatty():
            print('\r' + ' ' * 60 + '\r', end='')
        output.seek(0)
        text = output.read()
    logging.info('EXIT %s\n%s', proc.returncode, text)
    if check and proc.returncode:
        raise RuntimeError(f'Command exited {proc.returncode}: {shlex.join(argv)}\n{text[-3500:]}')
    return proc.returncode, text


def download(url, target, digest=None):
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)

    def checksum(p):
        h = hashlib.sha256()
        with p.open('rb') as f:
            for b in iter(lambda: f.read(1024 * 1024), b''):
                h.update(b)
        return h.hexdigest()

    if target.exists() and digest and checksum(target) == digest:
        return target
    temp = target.with_suffix(target.suffix + '.part')
    req = urllib.request.Request(url, headers={'User-Agent': 'AoE2-Voobly-Installer/2.0'})
    with urllib.request.urlopen(req, timeout=60) as response, temp.open('wb') as f:
        total = int(response.headers.get('Content-Length', 0))
        done = 0
        while chunk := response.read(1024 * 512):
            f.write(chunk); done += len(chunk)
            if sys.stdout.isatty():
                pct = f'{done / total:6.1%}' if total else f'{done // 1048576} MiB'
                print(f'\r  Downloading {target.name}: {pct}', end='', flush=True)
    print()
    actual = checksum(temp)
    logging.info('DOWNLOAD %s sha256=%s', url, actual)
    if digest and actual.lower() != digest.lower():
        temp.unlink()
        raise RuntimeError('SHA256 verification failed; archive was not executed.')
    temp.replace(target)
    return target


def api(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'AoE2-Voobly-Installer/2.0'})
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.load(r)


def pe_machine(path):
    try:
        with Path(path).open('rb') as f:
            if f.read(2) != b'MZ': return None
            f.seek(0x3c); off = struct.unpack('<I', f.read(4))[0]
            f.seek(off)
            if f.read(4) != b'PE\0\0': return None
            return struct.unpack('<H', f.read(2))[0]
    except (OSError, struct.error):
        return None


def elf_machine(path):
    try:
        b = Path(path).read_bytes()[:20]
        if b[:4] != b'\x7fELF': return None
        return int.from_bytes(b[18:20], 'little' if b[5] == 1 else 'big')
    except OSError:
        return None


def find_ci(root, name):
    return sorted((p for p in Path(root).rglob('*') if p.is_file() and p.name.casefold() == name.casefold()),
                  key=lambda p: (len(p.relative_to(root).parts), str(p)))


def atomic(path, text, mode=0o644):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    tmp.write_text(text); tmp.chmod(mode); tmp.replace(path)


def path_input(label, default, kind):
    while True:
        p = Path(os.path.expandvars(ask(label, default).strip().strip('\"\''))).expanduser().absolute()
        if any(c in str(p) for c in '\n\r\x00'):
            say('Control characters are not allowed.', '31'); continue
        if kind == 'dir' and not p.is_dir():
            say('Directory does not exist.', '31'); continue
        if kind == 'exe' and (not p.is_file() or pe_machine(p) not in (0x14c, 0x8664)):
            say('Select a readable x86/x64 Windows PE executable.', '31'); continue
        return p.resolve()


def prefix_arch(prefix):
    reg = Path(prefix) / 'system.reg'
    if not reg.is_file(): return None
    m = re.search(r'^#arch=(\w+)$', reg.read_text(errors='replace'), re.M)
    return m.group(1) if m else None


def tools():
    required = ['cabextract', 'unzip', 'wrestool', 'icotool', 'curl', 'sha256sum', 'sed', 'timeout']
    missing = [x for x in required if not shutil.which(x)]
    if not missing: return
    say('Missing helper tools: ' + ', '.join(missing), '33')
    if shutil.which('apt-get'):
        cmd = ['apt-get', 'install', '-y', 'cabextract', 'unzip', 'icoutils']
    elif shutil.which('dnf'):
        cmd = ['dnf', 'install', '-y', 'cabextract', 'unzip', 'icoutils']
    elif shutil.which('pacman'):
        cmd = ['pacman', '-S', '--needed', '--noconfirm', 'cabextract', 'unzip', 'icoutils']
    else:
        raise RuntimeError('Install cabextract, unzip and icoutils with your package manager, then rerun.')
    say(shlex.join(['sudo', *cmd]))
    if not yes('Authorize installing these helper packages?'):
        raise RuntimeError('Required helper installation declined.')
    sudo = shutil.which('sudo')
    if not sudo: raise RuntimeError('sudo unavailable; install the listed packages as administrator and rerun.')
    if sp.call([sudo, *cmd]) != 0 or any(not shutil.which(x) for x in required):
        raise RuntimeError('Helper package installation failed.')


def require_fex():
    fex = shutil.which('FEX')
    if not fex:
        raise RuntimeError('FEX is required on ARM64. Install the emulator and its Fedora rootfs '
                           '(for example: sudo dnf install fex-emu fex-emu-rootfs-fedora), then rerun. '
                           'Do not install the unrelated package named simply "fex".')
    images = sorted(Path('/usr/share/fex-emu/RootFS').glob('default*')) if Path('/usr/share/fex-emu/RootFS').is_dir() else []
    if not images:
        raise RuntimeError('No FEX rootfs found under /usr/share/fex-emu/RootFS. Configure FEX RootFS '
                           '(see ~/.fex-emu/Config.json) before creating the Wine prefix.')
    return Path(fex).resolve()


def wine_env(prefix, extra=None):
    env = os.environ.copy()
    for key in ('WINEARCH', 'WINEPREFIX', 'WINEDLLPATH', 'WINELOADER', 'WINESERVER', 'WINE',
                'WINEDLLOVERRIDES', 'WINE64', 'LD_PRELOAD', 'LD_LIBRARY_PATH',
                'WINE_DISABLE_FULLSCREEN_HACK', 'STAGING_WRITECOPY'):
        env.pop(key, None)
    env.update(WINEPREFIX=str(prefix), WINEARCH='win32', WINEDEBUG='-all',
               WINEDLLOVERRIDES='winemenubuilder.exe=d',
               WINE=str(DATA / 'bin32' / 'wine'), WINESERVER=str(DATA / 'bin32' / 'wineserver'))
    env['PATH'] = str(DATA / 'bin32') + ':' + env.get('PATH', '')
    if extra: env.update(extra)
    return env


WRAPPER_TEMPLATE = '''#!/usr/bin/env bash
set -uo pipefail
RUNNER="@RUNNER@"
NAME="${0##*/}"

case "$NAME" in
    wine|wineserver) ;;
    *)
        printf 'Unexpected wrapper name: %s\\n' "$NAME" >&2
        exit 2
        ;;
esac

unset WINE64 WINELOADER WINEDLLPATH
unset LD_PRELOAD LD_LIBRARY_PATH
unset WINE_DISABLE_FULLSCREEN_HACK STAGING_WRITECOPY

export WINE="$RUNNER/bin/wine"
export WINESERVER="$RUNNER/bin/wineserver"
export WINEARCH="${WINEARCH:-win32}"
export PATH="$RUNNER/bin:$PATH"
export WINEDLLOVERRIDES="winemenubuilder.exe=d${VOOBLY_DLLOVERRIDES:+;$VOOBLY_DLLOVERRIDES}"

@EXEC@ "$RUNNER/bin/$NAME" "$@" | sed '/^erofsfuse [0-9][0-9.]*[[:space:]]*$/d'
statuses=("${PIPESTATUS[@]}")
[[ "${statuses[0]}" -eq 0 ]] || exit "${statuses[0]}"
exit "${statuses[1]}"
'''


def install_wrappers(runner, fex):
    """Bash wrappers around the runner; they strip only the erofsfuse banner.

    Winetricks parses `wine --version` output as data, so the FEX rootfs mount
    banner must never reach stdout.
    """
    bin_dir = DATA / 'bin32'
    bin_dir.mkdir(parents=True, exist_ok=True)
    text = (WRAPPER_TEMPLATE
            .replace('@RUNNER@', str(runner))
            .replace('@EXEC@', shlex.quote(str(fex)) if fex else ''))
    for name in ('wine', 'wineserver'):
        atomic(bin_dir / name, text, 0o755)
    return bin_dir / 'wine', bin_dir / 'wineserver'


def install_runner():
    runner = DATA / 'runners' / f'wine-{WINE_VERSION}-x86'
    wine = runner / 'bin' / 'wine'
    if not (runner / '.complete').exists():
        archive = download(WINE_URL, CACHE / WINE_ARCHIVE, WINE_SHA256)
        runner.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=runner.parent) as t:
            tmp = Path(t)
            with tarfile.open(archive) as tar:
                if not hasattr(tarfile, 'data_filter'):
                    raise RuntimeError('Safe archive extraction requires Python 3.12+ or a patched tarfile (3.10/3.11).')
                tar.extractall(tmp, filter='data')
            candidates = list(tmp.glob('*/bin/wine')) or list(tmp.glob('bin/wine'))
            if not candidates:
                raise RuntimeError('Downloaded runner has no bin/wine.')
            src = candidates[0].parent.parent
            if runner.exists():
                raise RuntimeError(f'Incomplete runner exists: {runner}. Inspect it before retrying; nothing was overwritten.')
            shutil.move(str(src), runner)
            atomic(runner / '.complete', WINE_VERSION)
    if not wine.is_file():
        raise RuntimeError(f'Runner wine binary missing: {wine}')
    if elf_machine(wine.resolve()) != 3:
        raise RuntimeError('Runner wine is not a 32-bit x86 ELF; this installer requires the x86 build '
                           'for the win32 prefix.')
    return runner


def check_wine_version(wine, prefix, fex):
    rc, text = run([wine, '--version'], env=wine_env(prefix), timeout=120, check=False)
    # FEX writes mount diagnostics on stderr; only accept the version line itself.
    match = re.search(r'^wine-\S+.*$', text, re.M)
    version = match.group(0).strip() if match else ''
    say(f'Wine: {version or "(no output)"} | {wine}')
    if rc != 0 or not version:
        hint = ('verify FEX and its rootfs first: FEXBash -c "uname -m"'
                if fex else
                'install 32-bit runtime support for this distribution (e.g. glibc.i686 / libc6:i386)')
        raise RuntimeError(f'Wine did not execute through the selected route; {hint}.\n{text[-1500:]}')
    if not version.startswith(f'wine-{WINE_VERSION}'):
        raise RuntimeError(f'Unexpected Wine version {version!r}; this installer expects wine-{WINE_VERSION} '
                           'and the FEX mount banner must be filtered from stdout.')
    return version


def create_prefix(wine, prefix, state, save):
    fresh = not (prefix / 'system.reg').exists()
    if fresh and prefix.exists() and any(prefix.iterdir()):
        raise RuntimeError('Prefix directory is not empty and not a managed Wine prefix; choose an empty path.')
    prefix.mkdir(parents=True, exist_ok=True)
    if fresh:
        run([wine, 'wineboot', '--init'], env=wine_env(prefix), timeout=300)
        state['prefix_created'] = True; save()
    arch = prefix_arch(prefix)
    if arch != 'win32':
        raise RuntimeError(f'Expected a win32 prefix, found arch={arch!r}. Do not reuse a 64-bit/WoW64 prefix.')
    for name in ('cmd.exe', 'ntdll.dll', 'kernel32.dll'):
        target = prefix / 'drive_c/windows/system32' / name
        if not target.is_file():
            raise RuntimeError(f'Missing prefix file: {target}')
    rc, text = run([wine, str(prefix / 'drive_c/windows/system32/cmd.exe'), '/c', 'echo WIN32_PREFIX_OK'],
                   env=wine_env(prefix), timeout=120, check=False)
    if rc != 0 or 'WIN32_PREFIX_OK' not in text:
        raise RuntimeError('32-bit console execution failed in this prefix; inspect the log before continuing.')
    # Windows 10 is Wine 10's default; set it explicitly to match the reference setup.
    run([wine, 'reg', 'add', r'HKCU\Software\Wine', '/v', 'Version', '/d', 'win10', '/f'],
        env=wine_env(prefix), check=False)
    # Virtual desktop breaks Explorer startup on this runner family; keep it unset.
    run([wine, 'reg', 'delete', r'HKCU\Software\Wine\Explorer', '/v', 'Desktop', '/f'],
        env=wine_env(prefix), check=False)


DRIVE_ORDER = 'yxwvutsrqponmlkjihgfed'


def choose_drive(prefix, source):
    """Reuse an existing mapping to the game, else claim the first free letter.

    Wine assigns host mount points to drive letters automatically, so G: is not
    guaranteed to be free.
    """
    dev = Path(prefix) / 'dosdevices'
    if not dev.is_dir():
        raise RuntimeError(f'Missing Wine dosdevices directory: {dev}')
    game = Path(source).resolve()

    def linked(letter):
        link = dev / f'{letter}:'
        if link.is_symlink() or link.exists():
            return Path(os.path.realpath(link))
        return None

    for letter in DRIVE_ORDER:
        if linked(letter) == game:
            return letter
    for letter in DRIVE_ORDER:
        if linked(letter) is None:
            (dev / f'{letter}:').symlink_to(game)
            return letter
    raise RuntimeError('No free Wine drive letter available to expose the game directory.')


def map_drive(wine, prefix, source, aoc_rel):
    """Make the game reachable through a drive letter, or fall back to Z:.

    A running wineserver keeps the drive list it started with, so a mapping
    created afterwards is invisible until that server restarts. Retry with a
    restart before giving up.
    """
    servers = DATA / 'bin32' / 'wineserver'
    rel_win = str(aoc_rel).replace('/', '\\')
    drive = 'Z:'
    win_path = ('Z:' + str(Path(source).resolve())).replace('/', '\\') + '\\' + rel_win
    for attempt in range(3):
        try:
            letter = choose_drive(prefix, source)
        except RuntimeError as exc:
            say(f'{exc} Falling back to Z:.', '33')
            break
        drive = letter.upper() + ':'
        win_path = drive + '\\' + rel_win
        rc, text = run([wine, 'cmd', '/c', f'dir {win_path}'], env=wine_env(prefix),
                       timeout=180, check=False)
        if rc == 0 and Path(aoc_rel).name.casefold() in text.casefold():
            return drive, win_path
        logging.warning('Drive %s not visible (attempt %s)', drive, attempt + 1)
        run([servers, '-k'], env=wine_env(prefix), timeout=60, check=False)
        run([servers, '-w'], env=wine_env(prefix), timeout=60, check=False)
    rc, text = run([wine, 'cmd', '/c', f'dir {win_path}'], env=wine_env(prefix), timeout=180, check=False)
    if rc != 0 or Path(aoc_rel).name.casefold() not in text.casefold():
        logging.warning('Z: verification output: %s', text[-800:])
    say(f'WARNING: Wine does not list a spare drive letter; Voobly should use {win_path}', '33')
    return 'Z:', win_path


def backup_game(source):
    source = Path(source)
    target = source.with_name(source.name + f'.backup-{STAMP}')
    needed = sum(p.stat().st_size for p in source.rglob('*') if p.is_file())
    free = shutil.disk_usage(source.parent).free
    say(f'Game backup: {target}\nSize: {needed // 1048576} MiB | free: {free // 1048576} MiB')
    if free < needed + 512 * 1024 * 1024:
        say('Not enough free space for a full game backup; skipping it.', '33')
        return None
    shutil.copytree(source, target, symlinks=False)
    return target


def backup_prefix(prefix, label):
    target = DATA / 'backups' / f'{Path(prefix).name}-{label}-{STAMP}'
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(prefix, target, symlinks=True)
    return target


def install_winetricks():
    wt = DATA / 'tools' / 'winetricks'
    if wt.is_file():
        return wt
    commit = api('https://api.github.com/repos/Winetricks/winetricks/commits/master')['sha']
    download(f'https://raw.githubusercontent.com/Winetricks/winetricks/{commit}/src/winetricks', wt)
    run(['bash', '-n', str(wt)])
    wt.chmod(0o755)
    logging.info('Winetricks pinned at commit %s', commit)
    return wt


def directplay_registered(wine, prefix):
    rc, text = run([wine, 'reg', 'query', r'HKCU\Software\Wine\DllOverrides'],
                   env=wine_env(prefix), check=False)
    return rc == 0 and 'dplayx' in text.casefold()


def install_components(wine, prefix, state, save):
    system32 = prefix / 'drive_c/windows/system32'
    have_dlls = all((system32 / n).is_file() for n in DIRECTPLAY_FILES)
    if have_dlls and directplay_registered(wine, prefix):
        say('Native DirectPlay is installed and registered; skipping Winetricks.', '32')
    else:
        if have_dlls:
            say('DirectPlay DLLs exist but its DLL overrides are missing; repairing.', '33')
        backup = backup_prefix(prefix, 'before-multiplayer')
        say(f'Prefix backup: {backup}')
        wt = install_winetricks()
        env = wine_env(prefix, {'WINETRICKS_CACHE': str(CACHE / 'winetricks')})
        # Only native DirectPlay is needed; no corefonts, renderers, runtimes or quartz.
        for component in ('directplay',):
            say(f'Installing/checking Winetricks component: {component}')
            run([str(wt), '-q', component], env=env, timeout=1200)
        missing = [n for n in DIRECTPLAY_FILES if not (system32 / n).is_file()]
        if missing:
            raise RuntimeError('DirectPlay installation is incomplete; missing: ' + ', '.join(missing))
        run([str(wt), 'list-installed'], env=env, check=False)
    # dpnlobby has no Microsoft DLL here; leaving a native override breaks DirectPlay.
    for value in ('dpnlobby', '*dpnlobby'):
        run([wine, 'reg', 'delete', r'HKCU\Software\Wine\DllOverrides', '/v', value, '/f'],
            env=wine_env(prefix), check=False)
    state['components'] = True; save()


def desktop_escape(s):
    return str(s).replace('\\', '\\\\').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')


def exec_quote(s):
    return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%') + '"'


def make_icon(exe, ident, title):
    target = ICONS / (ident + '.png')
    ICONS.mkdir(parents=True, exist_ok=True)
    if target.exists(): return target
    try:
        with tempfile.TemporaryDirectory(dir=CACHE) as t:
            t = Path(t)
            run(['wrestool', '-x', '-t', '14', '-o', t, exe])
            for ico in sorted(t.iterdir()):
                run(['icotool', '-x', '-o', t, ico], check=False)
            pngs = list(t.glob('*.png'))
            if pngs:
                def area(p):
                    b = p.read_bytes()
                    return struct.unpack('>II', b[16:24])[0] * struct.unpack('>II', b[16:24])[1]
                shutil.copy2(max(pngs, key=area), target)
                return target
    except Exception as e:
        logging.warning('Icon extraction failed: %s', e)
    # Self-contained fallback: no third-party artwork download or image dependencies.
    from xml.sax.saxutils import escape
    svg = ICONS.parent.parent / 'scalable/apps' / (ident + '.svg')
    letters = 'V' if title == 'Voobly' else ('II' if 'Conquerors' not in title else 'II X')
    atomic(svg, f'<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256"><title>{escape(title)}</title><defs><linearGradient id="g" x2="1" y2="1"><stop stop-color="#132a45"/><stop offset="1" stop-color="#39152b"/></linearGradient></defs><rect x="8" y="8" width="240" height="240" rx="44" fill="url(#g)" stroke="#dab86e" stroke-width="7"/><path d="M65 100V62h22v21h30V62h22v21h30V62h22v38l-18 18v67H83v-67z" fill="#dab86e" opacity=".35"/><text x="128" y="164" text-anchor="middle" font-family="serif" font-size="66" font-weight="bold" fill="#ffe2a0">{letters}</text></svg>')
    return svg


LAUNCHER_TEMPLATE = '''#!/usr/bin/env bash
set -uo pipefail
umask 077

BASE="@BASE@"
RUNNER="@RUNNER@"
PREFIX="@PREFIX@"
GAME="@GAME@"
DRIVE_PREF="@DRIVE_PREF@"
GAME_REL="@GAME_REL@"
MARKER="@MARKER@"
FIXED_TARGET="@TARGET@"
LOG="$BASE/logs/@SLUG@-$(date +%Y%m%d-%H%M%S).log"

[[ -x "$RUNNER/bin/wine" ]] || { echo "STOP: Wine runner is missing." >&2; exit 1; }
[[ -f "$PREFIX/system.reg" ]] || { echo "STOP: Wine prefix is missing." >&2; exit 1; }
grep -q '^#arch=win32$' "$PREFIX/system.reg" || { echo "STOP: expected a win32 prefix." >&2; exit 1; }

unset WINE64 WINELOADER WINEDLLPATH
unset LD_PRELOAD LD_LIBRARY_PATH
unset WINE_DISABLE_FULLSCREEN_HACK STAGING_WRITECOPY

export WINE="$RUNNER/bin/wine"
export WINESERVER="$RUNNER/bin/wineserver"
export WINEPREFIX="$PREFIX"
export WINEARCH=win32
export PATH="$RUNNER/bin:$PATH"
export WINEDLLOVERRIDES='winemenubuilder.exe=d'
export WINEDEBUG='-all,err+all'

# Wine rewrites dosdevices during wineboot and can renumber drive letters, so the
# mapping is (re)created here and checked through Wine itself.
ensure_drive() {
    local preferred="$1" letter link
    for letter in "$preferred" y x w v u t s r q p o n m l k j i h g f e d; do
        link="$PREFIX/dosdevices/$letter:"
        if [[ "$(readlink -f "$link" 2>/dev/null)" == "$(readlink -f "$GAME")" ]]; then
            printf '%s:' "${letter^^}"
            return 0
        fi
    done
    for letter in "$preferred" y x w v u t s r q p o n m l k j i h g f e d; do
        link="$PREFIX/dosdevices/$letter:"
        if [[ ! -e "$link" && ! -L "$link" ]]; then
            ln -s "$GAME" "$link" && printf '%s:' "${letter^^}" && return 0
        fi
    done
    return 1
}

wine_sees_drive() {
    [[ -n "${1:-}" ]] || return 1
    "$WINE" cmd /d /c "if exist ${1}\\\\${MARKER} echo AOE_DRIVE_OK" 2>/dev/null | grep -q AOE_DRIVE_OK
}

DRIVE=""
if [[ -z "$GAME_REL" ]]; then
    DRIVE="$(ensure_drive "$DRIVE_PREF" 2>/dev/null || true)"
    if [[ -n "$DRIVE" ]] && ! wine_sees_drive "$DRIVE"; then
        "$WINESERVER" -k >/dev/null 2>&1 || true
        "$WINESERVER" -w >/dev/null 2>&1 || true
        DRIVE="$(ensure_drive "$DRIVE_PREF" 2>/dev/null || true)"
        if [[ -n "$DRIVE" ]] && ! wine_sees_drive "$DRIVE"; then
            echo "WARNING: $DRIVE exists on disk but Wine does not list it." >&2
            echo "         In Voobly, use Z: and the game folder instead." >&2
        fi
    fi
    if [[ -z "$DRIVE" ]]; then
        echo "WARNING: no free drive letter for $GAME; in Voobly use Z: paths." >&2
    fi
fi

# Games always start through the Unix path, which cannot break on a drive change.
if [[ -n "$GAME_REL" ]]; then
    TARGET="$GAME/$GAME_REL"
    [[ -f "$TARGET" ]] || { echo "STOP: game executable missing: $TARGET" >&2; exit 1; }
else
    TARGET="$FIXED_TARGET"
    [[ -e "$TARGET" ]] || { echo "STOP: executable missing: $TARGET" >&2; exit 1; }
fi

mkdir -p "$BASE/logs"
cd "$GAME" || exit 1

# A leftover DirectPlay helper holding port 47624 makes session creation fail
# silently (return to the connection screen). Clear it when nothing is playing.
HELPER="$BASE/tools/clear-directplay-conflict.sh"
if [[ -x "$HELPER" ]]; then
    helper_out="$("$HELPER" --auto 2>&1 || true)"
    if [[ -n "$helper_out" ]]; then
        printf '%s\\n' "$helper_out"
    fi
fi

printf 'Starting @TITLE@ without a time limit.\\nLog: %s\\n' "$LOG"

@EXEC@ "$RUNNER/bin/wine" "$TARGET" @ARGS@ "$@" >"$LOG" 2>&1
rc=$?

printf '@SLUG@_EXIT=%s\\nLog: %s\\n' "$rc" "$LOG"
if [[ "$rc" -ne 0 ]]; then
    tail -n 80 "$LOG"
fi
exit "$rc"
'''


def make_launcher(slug, title, target, args, runner, prefix, source, drive, fex, rel='', marker=''):
    text = (LAUNCHER_TEMPLATE
            .replace('@BASE@', str(DATA))
            .replace('@RUNNER@', str(runner))
            .replace('@PREFIX@', str(prefix))
            .replace('@GAME@', str(source))
            .replace('@DRIVE_PREF@', 'y' if drive.upper().startswith('Z') else drive[0].lower())
            .replace('@GAME_REL@', rel)
            .replace('@MARKER@', marker)
            .replace('@TARGET@', target)
            .replace('@SLUG@', slug)
            .replace('@TITLE@', title)
            .replace('@ARGS@', args)
            .replace('@EXEC@', shlex.quote(str(fex)) if fex else ''))
    path = DATA / 'bin32' / slug
    atomic(path, text, 0o755)
    return path


def menu_entry(slug, title, launcher, icon, ident, source):
    key = f'aoe2-voobly-{ident}-{slug}'
    file = APPS / (key + '.desktop')
    text = '[Desktop Entry]\nType=Application\nVersion=1.0\n'
    text += f'Name={title}\nComment=AoE II through the dedicated Voobly Wine prefix\n'
    text += 'Exec=' + exec_quote(launcher) + '\n'
    text += f'Path={desktop_escape(source)}\nIcon={desktop_escape(icon)}\nTerminal=false\n'
    text += 'Categories=Game;StrategyGame;\nStartupNotify=false\n'
    if file.exists() and file.read_text() != text:
        shutil.copy2(file, file.with_suffix('.desktop.bak-' + STAMP))
    atomic(file, text, 0o755)
    if shutil.which('desktop-file-validate'): run(['desktop-file-validate', file], check=False)
    return file


PORT_HELPER = r'''#!/usr/bin/env bash
set -euo pipefail
umask 077

MODE="interactive"
PORT="47624"
case "${1:-}" in
    --auto) MODE="auto" ;;
    "") ;;
    *) PORT="$1" ;;
esac

PREFIX="${WINEPREFIX:-}"

command -v ss >/dev/null || { echo "STOP: ss (iproute2) is required to inspect port $PORT." >&2; exit 1; }

sockets() { ss -H -lntup "sport = :$PORT" || true; }

owner_pids() { sockets | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u; }

is_helper() {
    local pid="$1"
    [[ -r "/proc/$pid/comm" ]] || return 1
    [[ "$(stat -c '%u' "/proc/$pid")" == "$(id -u)" ]] || return 1
    [[ "$(tr '[:upper:]' '[:lower:]' < "/proc/$pid/comm")" == "dplaysvr.exe" ]] || return 1
}

prefix_of() {
    tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n 's/^WINEPREFIX=//p' | head -1
}

game_running() {
    local pid comm pfx
    for pid in /proc/[0-9]*; do
        pid="${pid##*/}"
        [[ -r "/proc/$pid/comm" ]] || continue
        comm="$(tr '[:upper:]' '[:lower:]' < "/proc/$pid/comm")"
        case "$comm" in
            empires2.exe|age2_x1.exe|age2.exe|voobly.exe) ;;
            *) continue ;;
        esac
        pfx="$(prefix_of "$pid")"
        if [[ -z "$PREFIX" || "$pfx" == "$PREFIX" ]]; then
            return 0
        fi
    done
    return 1
}

if [[ "$MODE" != auto ]]; then
    echo "========== Owners of port $PORT =========="
    sockets
    echo
fi

stopped=0
for pid in $(owner_pids); do
    is_helper "$pid" || continue
    if [[ -n "$PREFIX" && "$(prefix_of "$pid")" != "$PREFIX" ]]; then
        continue
    fi
    if [[ "$MODE" == auto ]]; then
        if game_running; then
            continue
        fi
        kill -TERM "$pid" 2>/dev/null || true
        stopped=1
        continue
    fi
    echo "----------------------------------------"
    ps -p "$pid" -o pid,ppid,user,stat,etime,args
    echo "Prefix recorded in process environment:"
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null |
        grep -E '^(WINEPREFIX|WINEARCH|WINESERVER)=' || true
    echo
    read -r -p "Stop this stale DirectPlay helper, PID $pid? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Kept PID $pid."; continue ;;
    esac
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        read -r -p "PID $pid is still running. Force-stop it? [y/N] " answer
        case "$answer" in
            y|Y|yes|YES) kill -KILL "$pid" 2>/dev/null || true ;;
            *) echo "Not force-stopped." ;;
        esac
    fi
done

if [[ "$MODE" == auto ]]; then
    if (( stopped )); then
        for _ in $(seq 1 10); do
            [[ -z "$(sockets)" ]] && break
            sleep 0.5
        done
        [[ -z "$(sockets)" ]] && echo "Stopped a stale DirectPlay helper holding port $PORT."
    fi
    exit 0
fi

echo
echo "========== Port $PORT after cleanup =========="
if [[ -n "$(sockets)" ]]; then
    sockets
    echo "Port is still occupied. Do not retest yet."
    exit 1
fi
echo "Port $PORT is free."
echo "No game files, DLL overrides, firewall or network settings were changed."
'''


def main():
    if sys.platform != 'linux': raise RuntimeError('This utility supports Linux only.')
    if os.geteuid() == 0: raise RuntimeError('Run as your desktop user, not root or sudo.')
    LOG.parent.mkdir(parents=True, exist_ok=True); CACHE.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=LOG, level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    lock = (DATA / 'installer.lock').open('w')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise RuntimeError('Another installer is already running.')
    say('\n╔══════════════════════════════════════════════════════════════╗\n'
        '║           AGE OF EMPIRES II  ×  VOOBLY                       ║\n'
        '║           Classic games. A dedicated Linux home.             ║\n'
        '╚══════════════════════════════════════════════════════════════╝', '1;33')

    stage(1, 'Choose your installation paths')
    source = path_input('Original AoE II game directory', HOME / 'Games/Age of Empires II', 'dir')
    downloads = sorted((HOME / 'Downloads').glob('*[Vv]oobly*.exe'))
    setup = path_input('Voobly setup executable', downloads[-1] if downloads else HOME / 'Downloads/voobly.exe', 'exe')
    prefix = path_input('Dedicated Wine prefix', DATA / 'prefix', 'new')
    if prefix == HOME or prefix == Path('/') or prefix == source or prefix in source.parents or source in prefix.parents:
        raise RuntimeError('Game source and prefix must be separate, non-nested directories, not HOME or /.')

    # Age of Kings ships as empires2.exe; some repacks rename it to age2.exe.
    aok = find_ci(source, 'age2.exe') or find_ci(source, 'empires2.exe')
    aoc = find_ci(source, 'age2_x1.exe') or find_ci(source, 'age2x1.exe')
    if not aok or not aoc:
        missing = [label for label, found in (('empires2.exe or age2.exe', aok), ('age2_x1.exe or age2x1.exe', aoc)) if not found]
        raise RuntimeError('Game source is missing ' + ' and '.join(missing) +
                           '; it needs the original Age of Kings and Conquerors executables with their data files.')
    if pe_machine(aok[0]) != 0x14c or pe_machine(aoc[0]) != 0x14c:
        raise RuntimeError('Expected original i386 PE32 game executables, not HD/DE or non-x86 files.')
    aoc_rel = aoc[0].relative_to(source)

    machine = platform.machine().lower()
    arch = ('amd64' if machine in ('x86_64', 'amd64') else
            'x86' if machine in ('i386', 'i486', 'i586', 'i686', 'x86') else
            'arm64' if machine in ('aarch64', 'arm64') else None)
    if not arch: raise RuntimeError(f'Unsupported architecture: {machine}.')
    if not os.environ.get('DISPLAY') and not os.environ.get('WAYLAND_DISPLAY'):
        raise RuntimeError('No desktop display found. Run inside your local graphical Linux session.')
    if not os.environ.get('DISPLAY'):
        say('Wayland-only session: Wine may require working XWayland unless its Wayland driver is configured.', '33')

    ident = hashlib.sha256(str(prefix).encode()).hexdigest()[:12]
    statefile = DATA / 'installs' / (ident + '.json')
    state = json.loads(statefile.read_text()) if statefile.exists() else {'id': ident, 'source': str(source)}
    if state['source'] != str(source): raise RuntimeError('This prefix is registered to a different source; select a new prefix.')
    if prefix.exists() and any(prefix.iterdir()) and not statefile.exists():
        raise RuntimeError('Nonempty unmanaged prefix: refusing to mutate it. Choose a new empty prefix.')

    say(f'\nHost: {machine}\nOriginal: {source}\nConquerors: {aoc_rel}\nSetup: {setup}\nPrefix: {prefix}')
    say('Strategy: existing game mapped read-write on a free Wine drive, Wine 10 x86 in a dedicated win32 prefix')
    if not yes('Proceed with this configuration?', True): return
    def save(): atomic(statefile, json.dumps(state, indent=2))

    stage(2, 'Architecture, FEX and helper preflight')
    fex = None
    if arch == 'arm64':
        fex = require_fex()
        say(f'FEX: {fex} (x86 binaries run through FEX; rootfs present)', '32')
    else:
        say('Native x86 CPU: FEX is not used.', '32')
    tools()

    stage(3, 'Install and verify the Wine 10.0 x86 runner')
    say('Runner: Kron4ek wine-10.0-x86 (32-bit only, pinned SHA256)')
    runner = install_runner()
    wine, _ = install_wrappers(runner, fex)
    version = check_wine_version(wine, prefix, fex)
    state.update(wine=str(wine), runner=str(runner), fex=bool(fex), arch=arch, version=version); save()

    stage(4, 'Create a pure win32 prefix and verify 32-bit execution')
    create_prefix(wine, prefix, state, save)
    say('Prefix reports #arch=win32 and executed a 32-bit cmd.exe.', '32')

    stage(5, 'Expose the existing game to Wine')
    drive, game_win = map_drive(wine, prefix, source, aoc_rel)
    say(f'{drive} -> {source}\nConquerors executable: {game_win}', '32')
    state['game_drive'] = drive; save()
    # Voobly's Game Diagnostics may patch this shared directory; keep a backup first.
    have_backup = bool(state.get('game_backup')) and Path(state['game_backup']).is_dir()
    if not have_backup and yes('Back up the original game directory before Voobly can patch it?', True):
        backup = backup_game(source)
        if backup:
            state['game_backup'] = str(backup)
            save()

    stage(6, 'Install native DirectPlay')
    install_components(wine, prefix, state, save)

    stage(7, 'Install Voobly and create runner-pinned launchers')
    client_file = DATA / 'tools' / 'voobly-client-path'
    recorded = state.get('voobly')
    if not recorded and client_file.is_file():
        recorded = client_file.read_text(errors='replace').strip()
    voobly = Path(recorded) if recorded and Path(recorded).is_file() else None
    installed_now = False
    if voobly is None:
        for root in (prefix / 'drive_c', prefix):
            clients = find_ci(root, 'voobly.exe')
            if clients:
                voobly = next((c for c in clients if 'voobly' in str(c.parent).casefold()), clients[0])
                break
    if voobly is None:
        say(f'No installed Voobly was found for this prefix: {prefix}', '33')
        manual = ask('Path to an existing voobly.exe (leave empty to run the installer)').strip()
        if manual:
            candidate = Path(os.path.expandvars(manual)).expanduser().absolute()
            if not candidate.is_file() or pe_machine(candidate) not in (0x14c, 0x8664):
                raise RuntimeError(f'Not a valid Voobly executable: {candidate}')
            voobly = candidate
    if voobly is None:
        say('The Voobly installer will open. Accept its license, keep its default destination,\n'
            'and uncheck "Launch Voobly" at the end. No silent installer switches are assumed.')
        if not yes('Start the Voobly installer now?'): raise RuntimeError('Voobly installation declined.')
        rc, text = run([wine, str(setup)], env=wine_env(prefix), cwd=source, timeout=900, check=False)
        if rc != 0:
            raise RuntimeError(f'Voobly installer exited {rc}.\n{text[-2500:]}')
        installed_now = True
        clients = find_ci(prefix / 'drive_c', 'voobly.exe')
        if not clients:
            raise RuntimeError('Voobly executable not found; the installer may have been cancelled '
                               'or used a destination outside drive_c.')
        voobly = clients[0]
    else:
        say(f'Voobly already installed: {voobly}', '32')
    if pe_machine(voobly) not in (0x14c, 0x8664):
        raise RuntimeError('Installed Voobly is not a valid x86/x64 executable.')
    atomic(client_file, str(voobly) + '\n')
    state['voobly'] = str(voobly); save()

    # Only a fresh install can leave a pending prefix update behind.
    if installed_now:
        run([wine, 'wineboot', '-u'], env=wine_env(prefix), timeout=300, check=False)
    drive, game_win = map_drive(wine, prefix, source, aoc_rel)
    state['game_drive'] = drive; save()
    aok_rel = str(aok[0].relative_to(source)).replace(os.sep, '/')
    aoc_rel_posix = str(aoc_rel).replace(os.sep, '/')
    launchers = {
        'aok': ('play-aok', 'Age of Empires II', '', ''),
        'aoc': ('play-aoe2', 'Age of Empires II: The Conquerors', '', '-nostartup'),
    }
    created = {}
    for slug, (script, title, target, args) in launchers.items():
        rel = aok_rel if slug == 'aok' else aoc_rel_posix
        created[slug] = make_launcher(script, title, target, args, runner, prefix, source, drive, fex, rel)
    created['voobly'] = make_launcher('play-voobly', 'Voobly', str(voobly), '', runner, prefix, source, drive, fex,
                                      marker=str(aoc_rel).replace(os.sep, '\\'))

    entries = []
    for slug, (script, title, target, args) in launchers.items():
        exe = aok[0] if slug == 'aok' else aoc[0]
        icon = make_icon(exe, f'aoe2-voobly-{ident}-{slug}', title)
        entries.append(str(menu_entry(slug, title, created[slug], icon, ident, source)))
    icon = make_icon(voobly, f'aoe2-voobly-{ident}-voobly', 'Voobly')
    entries.append(str(menu_entry('voobly', 'Voobly', created['voobly'], icon, ident, source)))
    if shutil.which('update-desktop-database'):
        run(['update-desktop-database', APPS], check=False)

    helper = DATA / 'tools' / 'clear-directplay-conflict.sh'
    atomic(helper, PORT_HELPER, 0o755)

    stage(8, 'Final checks')
    say('Each application can be opened for a real smoke test; close it normally afterwards.\n'
        'These tests do not time-kill Wine, the game, or DirectPlay helpers.')
    checks = {}
    for slug, (script, title, target, args) in launchers.items():
        checks[slug] = 'NOT TESTED'
        if yes('Open ' + title + ' for visual verification?', True):
            try:
                run([created[slug]], timeout=0)
                checks[slug] = 'USER CONFIRMED' if yes('Did ' + title + ' reach a usable screen?') else 'NOT CONFIRMED'
            except Exception as e:
                checks[slug] = 'FAILED'; logging.exception('Smoke test %s', slug); say(str(e), '31')
    checks['voobly'] = 'NOT TESTED'
    if yes('Open Voobly for visual verification?', True):
        try:
            run([created['voobly']], timeout=0)
            checks['voobly'] = 'USER CONFIRMED' if yes('Did Voobly reach its login/lobby screen?') else 'NOT CONFIRMED'
        except Exception as e:
            checks['voobly'] = 'FAILED'; logging.exception('Smoke test voobly'); say(str(e), '31')

    if helper.is_file():
        run([str(helper), '--auto'], env=wine_env(prefix), check=False)
    port = run(['ss', '-H', '-lntup', 'sport = :47624'], check=False) if shutil.which('ss') else (0, '')
    z_path = 'Z:' + str(source).replace('/', '\\')
    summary = {
        'host_architecture': machine,
        'wine_version': version,
        'wine_binary': str(runner / 'bin/wine'),
        'wine_wrapper': str(wine),
        'execution': f'FEX ({fex})' if fex else 'native x86',
        'prefix': str(prefix),
        'prefix_architecture': prefix_arch(prefix),
        'original_game': str(source),
        'game_drive': f'{drive} (original directory, not a copy)',
        'conquerors_executable': game_win,
        'voobly_z_path': z_path,
        'voobly': str(voobly),
        'launchers': {k: str(v) for k, v in created.items()},
        'desktop_entries': entries,
        'components': 'native DirectPlay',
        'port_47624_owners': (port[1].strip() or 'none') if shutil.which('ss') else 'ss unavailable',
        'application_checks': checks,
        'multiplayer_match': 'NOT AUTOMATICALLY VERIFIED',
        'log': str(LOG),
    }
    state['summary'] = summary; save()
    report = DATA / 'logs' / (STAMP + '-summary.json'); atomic(report, json.dumps(summary, indent=2))

    complete = bool(checks) and all(v == 'USER CONFIRMED' for v in checks.values())
    say('\n' + ('INSTALLATION COMPLETE — application screens confirmed' if complete
                else 'INSTALLATION PREPARED — visual checks incomplete'), '1;32' if complete else '1;33')
    for k, v in summary.items():
        say(f'{k}: {json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v}')
    say('\nRemaining manual steps:\n'
        '• Launch Voobly, run Game Diagnostics, and set Installation directory ' + drive + '\\ and\n'
        '  Executable ' + game_win + '.\n'
        '• If Voobly does not list that drive, use Z: instead: ' + z_path + '\n'
        '• Let Game Diagnostics apply its supported patch (v1.5 RC) instead of importing guessed keys.\n'
        '• In room settings use 32-bit color, window mode, no virtual desktop; pass -nostartup to the game.\n'
        '• If multiplayer drops back to the connection screen, a stale DirectPlay helper may hold\n'
        '  port 47624. The launchers clear it automatically before starting; run ' + str(helper) + '\n'
        '  to do the same manually, and never kill every dplaysvr.exe.\n'
        '• Do not kill every dplaysvr.exe or change DirectPlay repeatedly; a helper owning 47624 during a\n'
        '  match is normal.\n'
        '• Complete a real two-player match, then back up the working prefix and game directory.\n'
        'Original game files and system Wine have not been replaced.')
    say(f'\nMachine-readable report: {report}\nFull command log: {LOG}', '36')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        say('\nCancelled. Existing game files and Wine installation were not removed. Rerun to resume completed stages.', '33')
        sys.exit(130)
    except Exception as exc:
        logging.exception('Installation stopped')
        say(f'\nSTOPPED: {exc}\nLog: {LOG}\nNo global wineserver/process cleanup was performed.', '31')
        sys.exit(1)
