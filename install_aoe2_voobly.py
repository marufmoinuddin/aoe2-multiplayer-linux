#!/usr/bin/env python3
"""AoE II Classic + Voobly installer: native x86, ARM64 FEX, or ARM64 Box64.

Prebuilt only. ARM64 users select FEX or Box64; both run Wine 10.0
amd64-wow64 against ONE shared win64 prefix under
XDG_DATA_HOME/aoe2-multiplayer-linux (prefix, runner, tools, state and logs
live directly there, and box64 is kept under translator/), so the emulator can
be switched by rerunning and picking the other route. FEX stays system-provided.
Earlier layouts are adopted in place on first run. Existing game files are
shared read-write.

Package adapters: Debian/Ubuntu (apt), Fedora/RHEL family (dnf/yum),
Arch family (pacman). Repository availability and native library support vary;
missing prebuilt prerequisites cause an actionable stop, never a source build.
FEX RootFS must be configured separately if not already available.

Wine is not a sandbox. Use trusted licensed game files/installers.
Backend runtime compatibility and real multiplayer require user smoke tests.
"""
from __future__ import annotations

import argparse
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
DATA_HOME = Path(os.environ.get('XDG_DATA_HOME', HOME / '.local/share')).expanduser().absolute()
BASE_DATA = DATA_HOME / 'aoe2-multiplayer-linux'
DATA = BASE_DATA
_CACHE_HOME = Path(os.environ.get('XDG_CACHE_HOME', HOME / '.cache')).expanduser().absolute()
BASE_CACHE = _CACHE_HOME / 'aoe2-multiplayer-linux'
CACHE = BASE_CACHE
# Previous layouts are only read to adopt existing files in place.
LEGACY_DATA = DATA_HOME / 'aoe2-voobly'
LEGACY_CACHE = _CACHE_HOME / 'aoe2-voobly'
TRANSLATOR = BASE_DATA / 'translator'
APPS = DATA_HOME / 'applications'
ICONS = DATA_HOME / 'icons/hicolor/256x256/apps'
COLOR = sys.stdout.isatty() and not os.environ.get('NO_COLOR')
SPINNER = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
STAMP = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
LOG = DATA / 'logs' / (STAMP + '.log')

WINE_VERSION = '10.0'
WINE_ARCHIVE = f'wine-{WINE_VERSION}-x86.tar.xz'
WINE_SHA256 = 'c5be273749f5c513b3edf7ad79d8214be558b80c67c6ca343d2f17fdcc30c2d2'
WINE_URL = f'https://github.com/Kron4ek/Wine-Builds/releases/download/{WINE_VERSION}/{WINE_ARCHIVE}'
WINE_FLAVOR = 'x86'
# Box64 does not wrap libgcc_s.so.1 and Fedora ships no x86_64 libraries, so Wine's
# ntdll.so cannot load without an emulated x86_64 copy. Pinned prebuilt, extracted
# user-local under the route workspace; never installed system-wide.
X64LIB_RPM = 'libgcc-11.5.0-17.el9_9.alma.1.x86_64.rpm'
X64LIB_URL = f'https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/Packages/{X64LIB_RPM}'
X64LIB_SHA256 = '1248acf03287807e448174d8753b7b8a9b2cc46f40f237281c91f20fa2339386'
# Box64 wraps these natively ("essential_libs" in src/librarian/library.c); every
# other dependency must exist as an emulated x86_64 library.
BOX64_WRAPPED = frozenset('''libc.so.6 libpthread.so.0 librt.so.1 libGL.so.1 libGL.so libX11.so.6
libasound.so.2 libdl.so.2 libm.so.6 libbsd.so.0 libutil.so.1 libresolv.so.2 libresolv.so
libXxf86vm.so.1 libXinerama.so.1 libXrandr.so.2 libXext.so.6 libXfixes.so.3 libXcursor.so.1
libXrender.so.1 libXft.so.2 libXi.so.6 libXss.so.1 libXpm.so.4 libXau.so.6 libXdmcp.so.6
libX11-xcb.so.1 libxcb.so.1 libxcb-xfixes.so.0 libxcb-shape.so.0 libxcb-shm.so.0 libxcb-randr.so.0
libxcb-image.so.0 libxcb-keysyms.so.1 libxcb-xtest.so.0 libxcb-glx.so.0 libxcb-dri2.so.0 libxcb-dri3.so.0
libXtst.so.6 libXt.so.6 libXcomposite.so.1 libXdamage.so.1 libXmu.so.6 libxkbcommon.so.0
libxkbcommon-x11.so.0 libpulse-simple.so.0 libpulse.so.0 libvulkan.so.1 libvulkan.so
ld-linux-x86-64.so.2 crashhandler.so libtcmalloc_minimal.so.0 libtcmalloc_minimal.so.4 libanl.so.1'''.split())
TOTAL_STAGES = 8
ROUTE = 'native'
PREFIX_ARCH = 'win32'
EMULATOR = None
OPTIONS = None
VERBOSE = False
DIRECTPLAY_FILES = ('dplayx.dll', 'dpnet.dll', 'dpnhpast.dll', 'dpwsockx.dll')
# Winetricks' directplay verb needs the Feb 2010 DirectX redist, which it fetches
# from a single web.archive.org snapshot that often returns 503/404. We seed its
# cache from mirrors first (same pinned SHA256 as winetricks) and retry.
DIRECTX_REDIST_NAME = 'directx_feb2010_redist.exe'
DIRECTX_REDIST_SHA256 = 'f6d191e89a963d7cca34f169d30f49eab99c1ed3bb92da73ec43617caaa1e93f'
DIRECTX_REDIST_MIRRORS = (
    'https://files.holarse-linuxgaming.de/mirrors/microsoft/directx_feb2010_redist.exe',
    'https://web.archive.org/web/20100205000000id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe',
    'https://web.archive.org/web/20101224202650id_/http://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe',
    'https://web.archive.org/web/2016id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe',
)


def say(text, color='36'):
    print(('\033[' + color + 'm' + text + '\033[0m') if COLOR else text, flush=True)


def bar(fraction, width=26, full='█', empty='░'):
    filled = max(0, min(width, int(round(fraction * width))))
    return full * filled + empty * (width - filled)


def human_size(n):
    return f'{n / 1048576:.0f} MiB' if n >= 1024 * 1024 else f'{max(1, round(n / 1024))} KiB'


def ask(text, default=''):
    if COLOR:
        prompt = f'\033[1;36m❯\033[0m {text}'
        if default: prompt += f' \033[2m[{default}]\033[0m'
    else:
        prompt = text + (f' [{default}]' if default else '')
    value = input(prompt + ': ').strip()
    return value or str(default)


def yes(text, default=False):
    return ask(text + (' [Y/n]' if default else ' [y/N]')).lower() in (('y', 'yes', '') if default else ('y', 'yes'))


def stage(n, text):
    dots = ' '.join('●' if i < n else ('▶' if i == n else '○') for i in range(1, TOTAL_STAGES + 1))
    inner = f'[{n}/{TOTAL_STAGES}]  {text}'
    if not COLOR:
        say(f'\n  {inner}')
        say('  ' + '─' * 66)
        return
    width = max(66, len(inner) + len(dots) + 4)
    say('\n  ╭' + '─' * width + '╮', '1;36')
    say('  │ ' + inner + ' ' * (width - len(inner) - len(dots) - 2) + dots + ' │', '1;36')
    say('  ╰' + '─' * width + '╯', '1;36')


def run(argv, env=None, cwd=None, timeout=180, check=True):
    argv = [str(x) for x in argv]
    logging.info('RUN %s cwd=%s', shlex.join(argv), cwd)
    if VERBOSE:
        say(f'  $ {shlex.join(argv)}', '2')
    with tempfile.TemporaryFile(mode='w+') as output:
        proc = sp.Popen(argv, env=env, cwd=cwd, stdout=output, stderr=sp.STDOUT,
                        start_new_session=True)
        start = time.monotonic()
        label = shlex.join(argv)
        label = '…' + label[-44:] if len(label) > 45 else label
        frames = SPINNER
        i = 0
        try:
            while proc.poll() is None:
                if timeout and time.monotonic() - start > timeout:
                    raise RuntimeError(f'Timed out: {shlex.join(argv)}. Wine children may still be running; inspect the log.')
                if sys.stdout.isatty():
                    spun = frames[i % len(frames)] if COLOR else '|/-\\'[i % 4]
                    print(f'\r\033[K  {spun} {label:<45} {int(time.monotonic()-start):>3}s', end='', flush=True)
                i += 1
                time.sleep(.12)
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
            print('\r\033[K', end='', flush=True)
        output.seek(0)
        text = output.read()
    logging.info('EXIT %s\n%s', proc.returncode, text)
    if VERBOSE:
        lines = text.rstrip('\n').splitlines()
        for line in lines[:400]:
            say(f'    | {line}', '2')
        if len(lines) > 400:
            say(f'    | ... {len(lines) - 400} more line(s), see the log', '2')
        say(f'    exit {proc.returncode}', '2')
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
    if VERBOSE:
        say(f'  GET {url}', '2')
    temp = target.with_suffix(target.suffix + '.part')
    req = urllib.request.Request(url, headers={'User-Agent': 'AoE2-Voobly-Installer/2.0'})
    with urllib.request.urlopen(req, timeout=60) as response, temp.open('wb') as f:
        total = int(response.headers.get('Content-Length', 0))
        done = 0
        while chunk := response.read(1024 * 512):
            f.write(chunk); done += len(chunk)
            if sys.stdout.isatty():
                if total:
                    print(f'\r  {bar(done / total)} {done / total:6.1%}  '
                          f'{human_size(done)}/{human_size(total)}  {target.name[:28]}',
                          end='', flush=True)
                else:
                    print(f'\r  {human_size(done)}  {target.name[:40]}', end='', flush=True)
    if sys.stdout.isatty():
        print('\r\033[K', end='', flush=True)
    actual = checksum(temp)
    logging.info('DOWNLOAD %s sha256=%s', url, actual)
    if digest and actual.lower() != digest.lower():
        temp.unlink()
        raise RuntimeError('SHA256 verification failed; archive was not executed.')
    temp.replace(target)
    say(f'  ✔ {target.name} ({human_size(target.stat().st_size)}, SHA256 verified)', '32')
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
        with Path(path).open('rb') as f:
            b = f.read(20)
        if len(b) < 20 or b[:4] != b'\x7fELF': return None
        return int.from_bytes(b[18:20], 'little' if b[5] == 1 else 'big')
    except OSError:
        return None


def elf_needed(path):
    """DT_NEEDED sonames of a 64-bit little-endian ELF, read from its section headers."""
    try:
        with Path(path).open('rb') as f:
            if f.read(4) != b'\x7fELF': return []
            f.seek(0)
            hdr = f.read(64)
            if len(hdr) < 64 or hdr[4] != 2 or hdr[5] != 1: return []
            shoff = struct.unpack_from('<Q', hdr, 0x28)[0]
            shentsize, shnum, shstrndx = struct.unpack_from('<HHH', hdr, 0x3a)
            if not shoff or shentsize < 64 or not shnum or shstrndx >= shnum: return []
            f.seek(shoff)
            raw = f.read(shentsize * shnum)
            shdrs = [struct.unpack_from('<IIQQQQIIQQ', raw, i * shentsize) for i in range(shnum)]
            strtab = shdrs[shstrndx]
            f.seek(strtab[4])
            names = f.read(strtab[5])

            def sname(offset):
                end = names.find(b'\0', offset)
                return names[offset:end].decode('ascii', 'replace')

            dynamic = dynstr = None
            for sh in shdrs:
                title = sname(sh[0])
                if title == '.dynamic' and sh[1] == 6: dynamic = (sh[4], sh[5])
                elif title == '.dynstr' and sh[1] == 3: dynstr = (sh[4], sh[5])
            if not dynamic or not dynstr: return []
            f.seek(dynstr[0]); strings = f.read(dynstr[1])
            f.seek(dynamic[0]); blob = f.read(dynamic[1])
        needed = []
        for off in range(0, len(blob) - 15, 16):
            tag, val = struct.unpack_from('<QQ', blob, off)
            if tag == 0: break
            if tag == 1:  # DT_NEEDED
                end = strings.find(b'\0', val)
                if end != -1: needed.append(strings[val:end].decode('ascii', 'replace'))
        return needed
    except (OSError, struct.error, IndexError):
        return []


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


def distro_family():
    values = {}
    try:
        for line in Path('/etc/os-release').read_text().splitlines():
            if '=' in line:
                k, v = line.split('=', 1)
                values[k] = v.strip().strip('"\'')
    except OSError:
        pass
    ids = set((values.get('ID', '') + ' ' + values.get('ID_LIKE', '')).split())
    if ids & {'debian', 'ubuntu', 'linuxmint'}: return 'debian'
    if ids & {'fedora', 'rhel', 'centos', 'rocky', 'almalinux'}: return 'redhat'
    if ids & {'arch', 'manjaro', 'endeavouros'}: return 'arch'
    return 'other'


def package_manager():
    family = distro_family()
    if family == 'debian' and shutil.which('apt-get'): return 'apt-get'
    if family == 'redhat' and shutil.which('dnf'): return 'dnf'
    if family == 'redhat' and shutil.which('yum'): return 'yum'
    if family == 'arch' and shutil.which('pacman'): return 'pacman'
    return None


def package_available(manager, package):
    if manager == 'apt-get':
        p = sp.run(['apt-cache', 'policy', package], capture_output=True, text=True, env={**os.environ, 'LC_ALL': 'C'})
        return bool(re.search(r'Candidate:\s+(?!\(none\))\S+', p.stdout))
    args = [manager, '-Si', package] if manager == 'pacman' else [manager, '-q', 'info', package]
    try:
        return sp.run(args, stdout=sp.DEVNULL, stderr=sp.DEVNULL, timeout=90).returncode == 0
    except sp.TimeoutExpired:
        return False


def install_packages(packages, reason):
    manager = package_manager()
    if not manager:
        raise RuntimeError(f'{reason}. Install prebuilt packages manually: {", ".join(packages)}. '
                           'No supported package manager was detected; nothing was compiled.')
    unavailable = [p for p in packages if not package_available(manager, p)]
    if unavailable:
        raise RuntimeError(f'Prebuilt package(s) unavailable in configured repositories: {unavailable}. '
                           'Refresh package metadata or use a trusted distro/upstream prebuilt package. '
                           'No repositories were added and no source build will be attempted.')
    cmd = ([manager, '-S', '--needed', *packages] if manager == 'pacman'
           else [manager, 'install', *packages])
    sudo = shutil.which('sudo')
    if not sudo:
        raise RuntimeError('Administrator must run: ' + shlex.join(cmd) + '; then rerun as desktop user.')
    say(reason + '\n' + shlex.join([sudo, *cmd]), '33')
    say('Review the package manager transaction, including any binfmt integration.\n'
        'Do not approve a transaction that replaces your working emulator setup.', '33')
    if not yes('Run this prebuilt-package installation?'):
        raise RuntimeError('Package installation declined.')
    if sp.call([sudo, *cmd]) != 0:
        raise RuntimeError('Package manager failed or transaction was cancelled.')


def configure_route():
    global DATA, CACHE, LOG, ROUTE, PREFIX_ARCH, OPTIONS, VERBOSE
    global WINE_ARCHIVE, WINE_SHA256, WINE_URL, WINE_FLAVOR
    parser = argparse.ArgumentParser(description='AoE II / Voobly installer with FEX or Box64 emulation. Prebuilt binaries only.')
    parser.add_argument('--route', choices=('fex', 'box64', 'native'))
    parser.add_argument('--emulator', type=Path, help='Existing native ARM64 FEX or Box64 executable')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Show every command and its output while the stages run')
    OPTIONS = parser.parse_args()
    VERBOSE = OPTIONS.verbose
    machine = platform.machine().lower()
    arm = machine in ('aarch64', 'arm64')
    if machine not in ('aarch64', 'arm64', 'x86_64', 'amd64', 'i386', 'i486', 'i586', 'i686', 'x86'):
        raise RuntimeError(f'Unsupported architecture: {machine}')
    if arm:
        route = OPTIONS.route
        if route == 'native': raise RuntimeError('Native x86 Wine is not an ARM64 route.')
        if not route:
            say('ARM64 execution route (both share one win64 prefix; switch anytime by rerunning):\n'
                '  1. FEX + Wine 10.0 amd64-wow64 / win64 prefix\n'
                '  2. Box64 + Wine 10.0 amd64-wow64 / win64 prefix\n'
                'Only the emulator, wrappers and launchers differ; runner, prefix, Voobly and state are shared.')
            choice = ask('Select 1/FEX or 2/Box64', '1').lower()
            if choice not in ('1', '2', 'fex', 'box64'):
                raise RuntimeError('Invalid route selection.')
            route = 'box64' if choice in ('2', 'box64') else 'fex'
    else:
        route = OPTIONS.route or 'native'
        if route != 'native' or OPTIONS.emulator:
            raise RuntimeError('FEX/Box64 routes require an ARM64 host; use native on x86.')
    ROUTE = route
    if route in ('fex', 'box64'):
        PREFIX_ARCH = 'win64'
        flavor = 'amd64-wow64'
        WINE_SHA256 = ('aeebbbf239e548f0136f1cd72a2e109dd9a572a8f703da3c09fa40d74d5c255f')
    else:
        PREFIX_ARCH = 'win32'
        flavor = 'x86'
        WINE_SHA256 = ('c5be273749f5c513b3edf7ad79d8214be558b80c67c6ca343d2f17fdcc30c2d2')
    WINE_FLAVOR = flavor
    DATA = BASE_DATA
    CACHE = BASE_CACHE

    def adopt(legacy, current):
        """Move a previous workspace in place so nothing has to be re-downloaded."""
        if not legacy.is_dir(): return
        if current.exists() and any(current.iterdir()): return
        current.parent.mkdir(parents=True, exist_ok=True)
        if current.exists():
            for item in legacy.iterdir():
                target = current / item.name
                if not target.exists():
                    shutil.move(str(item), str(target))
            legacy.rmdir()
        else:
            shutil.move(str(legacy), str(current))
        say(f'Adopted previous files: {legacy} -> {current}', '32')

    adopt(LEGACY_DATA / 'routes' / 'wow64', DATA)
    adopt(LEGACY_DATA / 'routes' / 'box64-wow64', DATA)
    adopt(LEGACY_CACHE / 'wow64', CACHE)
    adopt(LEGACY_CACHE / 'box64-wow64', CACHE)
    LOG = DATA / 'logs' / (STAMP + '.log')
    WINE_ARCHIVE = f'wine-{WINE_VERSION}-{flavor}.tar.xz'
    WINE_URL = f'https://github.com/Kron4ek/Wine-Builds/releases/download/{WINE_VERSION}/{WINE_ARCHIVE}'


def require_emulator():
    if ROUTE == 'native': return None
    name = 'FEX' if ROUTE == 'fex' else 'box64'
    local = TRANSLATOR / 'box64' if ROUTE == 'box64' else None
    supplied = OPTIONS.emulator
    if supplied:
        found = supplied
    elif local and local.is_file():
        found = local
    else:
        found = shutil.which(name)
        if not found:
            install_packages(['fex-emu' if ROUTE == 'fex' else 'box64'],
                             f'{name} is required for the selected route.')
            found = shutil.which(name)
    if not found or not Path(found).is_file() or not os.access(found, os.X_OK):
        raise RuntimeError(f'{name} executable missing. Install a prebuilt package or use --emulator /absolute/path.')
    resolved = Path(found).resolve()
    if elf_machine(resolved) != 183:
        raise RuntimeError(f'Expected a native AArch64 ELF emulator, not a script/foreign binary: {resolved}')
    if local is not None and resolved != local.absolute():
        # box64 lives with the rest of the install; FEX stays system-provided.
        if not local.exists() or local.stat().st_mtime < resolved.stat().st_mtime:
            local.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(resolved, local)
            local.chmod(0o755)
            say(f'box64 stored in {local}', '32')
        resolved = local.absolute()
    if ROUTE == 'fex':
        say('FEX RootFS must already be configured. Its location is not assumed.\n'
            'The actual Wine execution probe will verify that configuration.\n'
            'If needed, use your distribution FEX RootFS package or upstream FEXRootFSFetcher.', '33')
    return resolved


def box64_libdir():
    found = next(iter(find_ci(TRANSLATOR / 'x64libs', 'libgcc_s.so.1')), None)
    return found.parent if found else TRANSLATOR / 'x64libs' / 'lib64'


def box64_ld_library_path():
    if ROUTE != 'box64': return ''
    parts = [str(box64_libdir())]
    unix = DATA / 'runners' / f'wine-{WINE_VERSION}-amd64-wow64' / 'lib/wine/x86_64-unix'
    if unix.is_dir(): parts.append(str(unix))
    return ':'.join(parts)


def x64_lib_present(name):
    dirs = [box64_libdir(), Path('/usr/lib/box64-x86_64-linux-gnu'), Path('/lib/box64-x86_64-linux-gnu'),
            Path('/usr/lib/x86_64-linux-gnu'), Path('/lib/x86_64-linux-gnu'),
            Path('/usr/lib64'), Path('/lib64'), Path('/usr/lib'), Path('/lib')]
    for d in dirs:
        p = d / name
        try:
            if p.exists() and elf_machine(p.resolve()) == 62: return True
        except (OSError, RuntimeError):
            continue
    return False


def box64_start_libs(runner):
    """Non-wrapped libraries the Wine startup chain hard-requires as x86_64."""
    root = runner / 'lib/wine'
    internal = {p.name for p in root.rglob('*.so')}
    needed = set()
    for target in (runner / 'bin/wine', runner / 'bin/wineserver',
                   root / 'x86_64-unix/ntdll.so', root / 'x86_64-unix/win32u.so'):
        if not target.is_file(): continue
        for name in elf_needed(target):
            if name not in BOX64_WRAPPED and name not in internal:
                needed.add(name)
    return sorted(needed)


def ensure_box64_x64libs(runner):
    (TRANSLATOR / 'x64libs').mkdir(parents=True, exist_ok=True)
    missing = [n for n in box64_start_libs(runner) if not x64_lib_present(n)]
    if not missing:
        say('Box64 x86_64 startup libraries already available: ' + ', '.join(box64_start_libs(runner)), '32')
    else:
        unsupported = [n for n in missing if n != 'libgcc_s.so.1']
        if unsupported or package_manager() not in ('dnf', 'yum'):
            raise RuntimeError('Box64 needs emulated x86_64 libraries not present here: ' + ', '.join(missing) +
                               '. Provision them with the Box64 x86 library bundle (box64-data provides '
                               'box64-bundle-x86-libs.sh) or as x86_64 packages, then rerun. '
                               'No repositories were added and nothing was compiled.')
        if not shutil.which('rpm2cpio'):
            raise RuntimeError('rpm2cpio is required to extract the prebuilt libgcc package; '
                               'install your rpm package and rerun.')
        if not shutil.which('cpio'):
            install_packages(['cpio'], 'cpio is required to extract the prebuilt libgcc package.')
        say(f'Missing for Box64: {", ".join(missing)} — provisioning a pinned prebuilt x86_64 libgcc.', '33')
        rpm = download(X64LIB_URL, CACHE / X64LIB_RPM, X64LIB_SHA256)
        run(['bash', '-c', 'cd "$1" && rpm2cpio "$2" | cpio -idm --quiet', 'x', str(TRANSLATOR / 'x64libs'), str(rpm)],
            timeout=300)
        still = [n for n in box64_start_libs(runner) if not x64_lib_present(n)]
        if still:
            raise RuntimeError('x86_64 startup libraries still missing after extraction: ' + ', '.join(still))
        say(f'x86_64 {", ".join(box64_start_libs(runner))} ready under {box64_libdir()}.', '32')
    late = sorted({n for p in (runner / 'lib/wine/x86_64-unix').glob('*.so')
                   for n in elf_needed(p) if n not in BOX64_WRAPPED and not x64_lib_present(n)})
    if late:
        say('Not needed for startup, but some Wine drivers may later report "Error loading needed lib X" '
            'for: ' + ', '.join(late) + '. Provision the matching x86_64 libraries with '
            'box64-bundle-x86-libs.sh if that happens.', '33')


def reuse_or_replace(prefix, statefile, ident, source):
    """Reuse an existing route installation by default, or replace it on request.

    Returns fresh state when a replacement was performed, else None.
    """
    runner_dir = runner_path()
    existing = [label for label, present in (
        ('prefix', (prefix / 'system.reg').is_file()),
        ('state', statefile.is_file()),
        ('runner', (runner_dir / '.complete').is_file())) if present]
    if not existing: return None
    say('\nExisting installation for this prefix: ' + ', '.join(existing))
    if not yes('Replace the previous prefix/install? The default reuses everything already present.', False):
        say('Reusing the existing installation; completed stages are skipped and '
            'nothing already present is re-downloaded.', '32')
        return None
    stop_route_processes(prefix)
    if prefix.exists():
        shutil.rmtree(prefix); say(f'Removed prefix: {prefix}', '33')
    if statefile.exists():
        statefile.unlink(); say(f'Removed state: {statefile.name}', '33')
    if (DATA / 'tools' / 'voobly-client-path').exists():
        (DATA / 'tools' / 'voobly-client-path').unlink()
    if runner_dir.exists() and not (runner_dir / '.complete').exists():
        shutil.rmtree(runner_dir); say('Removed the incomplete runner; it will be fetched again.', '33')
    say('Replaced. The verified runner and downloads are kept; stages rerun on a clean prefix.', '32')
    return {'id': ident, 'source': str(source), 'route': ROUTE, 'prefix_architecture': PREFIX_ARCH}


def stop_route_processes(prefix):
    needle = ('WINEPREFIX=' + str(prefix)).encode()

    def current():
        hits = []
        for proc in Path('/proc').glob('[0-9]*'):
            try:
                if proc.stat().st_uid != os.getuid(): continue
                if needle not in (proc / 'environ').read_bytes().split(b'\0'): continue
                hits.append((int(proc.name), (proc / 'comm').read_text().strip()))
            except OSError:
                continue
        return hits

    hits = current()
    if not hits: return
    say('Running processes for this prefix: ' + ', '.join(f'{p} ({c})' for p, c in hits), '33')
    server = DATA / 'bin' / 'wineserver'
    if server.is_file():
        run([server, '-k'], env=wine_env(prefix), timeout=30, check=False)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and current():
        time.sleep(0.5)
    for pid, _ in current():
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and current():
        time.sleep(0.5)
    left = current()
    if left:
        raise RuntimeError('Close these running applications and rerun: '
                           + ', '.join(f'{p} ({c})' for p, c in left))


def windows32_dir(prefix):
    return Path(prefix) / 'drive_c/windows' / ('syswow64' if PREFIX_ARCH == 'win64' else 'system32')


def safe_extract(tar, destination):
    if hasattr(tarfile, 'data_filter'):
        tar.extractall(destination, filter='data')
        return
    # Older distro Python: validate regular files/directories/safe links, then extract.
    root = Path(destination).resolve()
    def contained(p):
        p = p.resolve()
        return p == root or root in p.parents
    members = tar.getmembers()
    for m in members:
        dest = root / m.name
        if not contained(dest): raise RuntimeError('Unsafe archive path: ' + m.name)
        if not (m.isfile() or m.isdir() or m.issym() or m.islnk()):
            raise RuntimeError('Unsupported archive member: ' + m.name)
        if (m.issym() or m.islnk()) and (Path(m.linkname).is_absolute() or
                not contained((dest.parent if m.issym() else root) / m.linkname)):
            raise RuntimeError('Unsafe archive link: ' + m.name)
    # Check again as links are materialized, to reject symlink-chain traversal.
    for m in members:
        dest = root / m.name
        if not contained(dest): raise RuntimeError('Unsafe archive traversal: ' + m.name)
        if (m.issym() or m.islnk()) and not contained((dest.parent if m.issym() else root) / m.linkname):
            raise RuntimeError('Unsafe archive link chain: ' + m.name)
        tar.extract(m, destination, set_attrs=False)
        if m.isfile(): dest.chmod(m.mode & 0o777)


def audit_route(prefix, expected):
    conflicts, observed = [], []
    if expected == 'native': return conflicts, observed
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            if proc.stat().st_uid != os.getuid(): continue
            env = (proc / 'environ').read_bytes().split(b'\0')
            if ('WINEPREFIX=' + str(prefix)).encode() not in env: continue
            maps = (proc / 'maps').read_text(errors='replace')
            fex = bool(re.search(r'/FEX(?:Interpreter|Loader)?(?:\s|$)|libFEX', maps, re.M))
            box = bool(re.search(r'/box64(?:\s|$)', maps, re.M))
            if fex or box:
                route = 'fex' if fex else 'box64'
                observed.append((proc.name, route))
                if route != expected: conflicts.append((proc.name, route))
        except (OSError, PermissionError):
            continue
    return conflicts, observed


def tools():
    package_commands = {
        'cabextract': 'cabextract', 'unzip': 'unzip', 'wrestool': 'icoutils',
        'icotool': 'icoutils', 'curl': 'curl', 'sha256sum': 'coreutils',
        'sed': 'sed', 'timeout': 'coreutils', 'ss': 'iproute2',
        'flock': 'util-linux', 'ps': 'procps', 'awk': 'gawk', 'file': 'file',
        'xz': 'xz-utils', 'tar': 'tar', 'grep': 'grep',
    }
    family = distro_family()
    if family == 'redhat':
        package_commands.update(ss='iproute', ps='procps-ng', xz='xz')
    elif family == 'arch':
        package_commands.update(ps='procps-ng', xz='xz')
    if ROUTE == 'box64' and family == 'redhat':
        package_commands.update(cpio='cpio', rpm2cpio='rpm')
    missing = [c for c in package_commands if not shutil.which(c)]
    if missing:
        install_packages(sorted({package_commands[c] for c in missing}),
                         'Missing helper commands: ' + ', '.join(missing))
    missing = [c for c in package_commands if not shutil.which(c)]
    if missing: raise RuntimeError('Commands still unavailable: ' + ', '.join(missing))




def wine_env(prefix, extra=None):
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('WINE', 'BOX64_', 'BOX86_', 'FEX_')) or key in (
                'LD_PRELOAD', 'LD_LIBRARY_PATH', 'STAGING_WRITECOPY', 'VOOBLY_DLLOVERRIDES'):
            env.pop(key, None)
    env.update(WINEPREFIX=str(prefix), WINEARCH=PREFIX_ARCH, WINEDEBUG='-all',
               WINEDLLOVERRIDES='winemenubuilder.exe=d',
               WINE=str(DATA / 'bin' / 'wine'), WINESERVER=str(DATA / 'bin' / 'wineserver'))
    env['PATH'] = str(DATA / 'bin') + ':' + env.get('PATH', '')
    if ROUTE == 'box64':
        env['BOX64_PATH'] = str(DATA / 'bin') + ':' + str(DATA / 'runners' / f'wine-{WINE_VERSION}-amd64-wow64/bin')
        env['BOX64_NOBANNER'] = '1'
        env['BOX64_LD_LIBRARY_PATH'] = box64_ld_library_path()
    if extra: env.update(extra)
    return env


WRAPPER_TEMPLATE = '#!/usr/bin/env bash\nset -uo pipefail\nRUNNER=@RUNNER_Q@\nBIN=@BIN_Q@\nROUTE=@ROUTE_Q@\nEMULATOR=@EMU_Q@\nPREFIX_ARCH=@ARCH_Q@\nPREFIX_DEFAULT=@PREFIX_Q@\nNAME="${0##*/}"\ncase "$NAME" in wine|wineserver) ;; *) exit 2;; esac\nunset WINE64 WINELOADER WINEDLLPATH LD_PRELOAD LD_LIBRARY_PATH\nunset WINE_DISABLE_FULLSCREEN_HACK STAGING_WRITECOPY\nexport WINE="$BIN/wine" WINESERVER="$BIN/wineserver"\nexport WINEPREFIX="${WINEPREFIX:-$PREFIX_DEFAULT}"\nexport WINEARCH="$PREFIX_ARCH"\nexport PATH="$BIN:$RUNNER/bin:$PATH"\nexport WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d}"\nif [[ "$ROUTE" == box64 ]]; then\n    export BOX64_PATH="$BIN:$RUNNER/bin"\n    export BOX64_NOBANNER=1\n    export BOX64_LD_LIBRARY_PATH=@X64LD_Q@\nfi\ncmd=("$RUNNER/bin/$NAME")\n[[ "$ROUTE" == native ]] || cmd=("$EMULATOR" "${cmd[@]}")\nif [[ "$NAME" == wine && "${1:-}" == --version ]]; then\n    tmp="$(mktemp)" || exit 1\n    trap \'rm -f -- "$tmp"\' EXIT\n    "${cmd[@]}" "$@" >"$tmp" 2>&1\n    rc=$?\n    if [[ "$rc" -eq 0 ]] && grep -q \'^wine-\' "$tmp"; then\n        sed -n \'/^wine-/p\' "$tmp"\n    else\n        cat "$tmp" >&2\n        [[ "$rc" -ne 0 ]] || rc=1\n    fi\n    exit "$rc"\nfi\n# No pipe between the emulator and application output.\nexec "${cmd[@]}" "$@"\n'


def install_wrappers(runner, fex, prefix=None):
    if ROUTE != 'native' and not fex:
        raise RuntimeError(f'No {ROUTE} emulator configured for the wrappers.')
    bin_dir = DATA / 'bin'
    bin_dir.mkdir(parents=True, exist_ok=True)
    replacements = {
        '@RUNNER_Q@': shlex.quote(str(runner)), '@BIN_Q@': shlex.quote(str(bin_dir)),
        '@ROUTE_Q@': shlex.quote(ROUTE), '@EMU_Q@': shlex.quote(str(fex or '')),
        '@ARCH_Q@': shlex.quote(PREFIX_ARCH), '@PREFIX_Q@': shlex.quote(str(prefix or DATA / 'prefix')),
        '@X64LD_Q@': shlex.quote(box64_ld_library_path()),
    }
    text = WRAPPER_TEMPLATE
    for key, value in replacements.items(): text = text.replace(key, value)
    for name in ('wine', 'wineserver'):
        atomic(bin_dir / name, text, 0o755)
        run(['bash', '-n', bin_dir / name])
    return bin_dir / 'wine', bin_dir / 'wineserver'


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def cached_wine_archive():
    """Reuse a previously downloaded, checksum-verified archive from any layout."""
    for candidate in (CACHE / WINE_ARCHIVE, LEGACY_CACHE / 'wow64' / WINE_ARCHIVE,
                      LEGACY_CACHE / 'box64-wow64' / WINE_ARCHIVE, LEGACY_CACHE / WINE_ARCHIVE):
        if candidate.is_file() and sha256_file(candidate) == WINE_SHA256:
            if candidate != CACHE / WINE_ARCHIVE:
                CACHE.mkdir(parents=True, exist_ok=True)
                shutil.copy2(candidate, CACHE / WINE_ARCHIVE)
                say(f'Reusing previously downloaded {WINE_ARCHIVE} from {candidate.parent}.', '32')
            return CACHE / WINE_ARCHIVE
    return None


def runner_path():
    return DATA / 'runners' / f'wine-{WINE_VERSION}-{WINE_FLAVOR}'


def install_runner():
    runner = runner_path()
    wine = runner / 'bin/wine'
    if not (runner / '.complete').exists():
        archive = cached_wine_archive() or download(WINE_URL, CACHE / WINE_ARCHIVE, WINE_SHA256)
        runner.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=runner.parent) as t:
            tmp = Path(t)
            with tarfile.open(archive) as tar: safe_extract(tar, tmp)
            candidates = list(tmp.glob('*/bin/wine')) or list(tmp.glob('bin/wine'))
            if len(candidates) != 1: raise RuntimeError('Runner must contain exactly one bin/wine.')
            if runner.exists(): raise RuntimeError(f'Incomplete runner exists: {runner}; inspect it first.')
            shutil.move(str(candidates[0].parent.parent), runner)
        atomic(runner / '.complete', json.dumps({'version': WINE_VERSION, 'sha256': WINE_SHA256}))
    expected = 62 if WINE_FLAVOR == 'amd64-wow64' else 3
    for name in ('wine', 'wineserver'):
        target = runner / 'bin' / name
        if not target.is_file() or elf_machine(target.resolve()) != expected:
            raise RuntimeError(f'Wrong ELF architecture or missing runner component: {target}')
    return runner


def check_wine_version(wine, prefix, fex):
    rc, text = run([wine, '--version'], env=wine_env(prefix), timeout=120, check=False)
    match = re.search(r'^wine-\S+.*$', text, re.M)
    version = match.group(0).strip() if match else ''
    say(f'Wine: {version or "(no output)"} | route={ROUTE} | {wine}')
    if rc != 0 or not version:
        detail = text
        if ROUTE == 'box64':
            _, logged = run([wine, '--version'], env=wine_env(prefix, {'BOX64_LOG': '1'}),
                            timeout=120, check=False)
            reasons = [ln for ln in logged.splitlines()
                       if re.search(r'Error loading|Cannot dlopen|needed lib', ln)]
            if reasons:
                detail += '\nBox64 log:\n' + '\n'.join(dict.fromkeys(reasons))
        hints = {
            'fex': 'Verify configured FEX RootFS and that the selected FEX can execute x86 Linux binaries.',
            'box64': 'Verify the native ARM64 Box64 package. "Error loading needed lib X" means the emulated '
                     'x86_64 library X is missing; the installer provisions libgcc_s automatically on the next '
                     'run, or provision x86_64 libraries with box64-bundle-x86-libs.sh. Do not reuse the FEX prefix.',
            'native': 'Install your distro prebuilt 32-bit Linux runtime support (including graphics/audio).',
        }
        raise RuntimeError(hints[ROUTE] + '\n' + detail[-2500:])
    if not re.match(r'^wine-10\.0(?:\s|$)', version):
        raise RuntimeError('Unexpected runner version: ' + version)
    return version


def create_prefix(wine, prefix, state, save):
    fresh = not (prefix / 'system.reg').exists()
    if fresh and prefix.exists() and any(prefix.iterdir()):
        raise RuntimeError('Prefix directory is nonempty and is not a managed Wine prefix.')
    prefix.mkdir(parents=True, exist_ok=True)
    if fresh:
        run([wine, 'wineboot', '--init'], env=wine_env(prefix), timeout=300)
        state['prefix_created'] = True; save()
    arch = prefix_arch(prefix)
    if arch != PREFIX_ARCH:
        raise RuntimeError(f'Expected {PREFIX_ARCH} prefix for {ROUTE}, found {arch!r}; no conversion is attempted.')
    for name in ('cmd.exe', 'ntdll.dll', 'kernel32.dll'):
        target = windows32_dir(prefix) / name
        if not target.is_file() or pe_machine(target) != 0x14c:
            raise RuntimeError(f'Missing or non-i386 Windows component: {target}')
    probe = windows32_dir(prefix) / 'cmd.exe'
    rc, text = run([wine, str(probe), '/d', '/c', 'echo WIN32_APP_OK'],
                   env=wine_env(prefix), timeout=120, check=False)
    if rc or 'WIN32_APP_OK' not in text:
        raise RuntimeError('32-bit Windows execution failed in this prefix.\n' + text[-2000:])
    run([wine, 'reg', 'add', r'HKCU\Software\Wine', '/v', 'Version', '/d', 'win10', '/f'],
        env=wine_env(prefix))
    say('32-bit Windows cmd.exe executed successfully.', '32')
    conflicts, observed = audit_route(prefix, ROUTE)
    logging.info('Route audit expected=%s observed=%s', ROUTE, observed)
    if conflicts: raise RuntimeError(f'Wrong emulator detected for this prefix: {conflicts}')


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


def drive_visible(wine, prefix, drive):
    """Ask Wine whether it lists a drive letter.

    The check must stay quote-free: Wine's argv quoting and cmd.exe's quote
    parsing disagree, so `if exist "path"` silently evaluates false.
    """
    rc, text = run([wine, 'cmd', '/d', '/c', f'if exist {drive}\\ echo AOE_DRIVE_OK'],
                   env=wine_env(prefix), timeout=120, check=False)
    return rc == 0 and 'AOE_DRIVE_OK' in text, text


def map_drive(wine, prefix, source, aoc_rel):
    rel_win = str(aoc_rel).replace('/', '\\')
    server = DATA / 'bin' / 'wineserver'
    try:
        letter = choose_drive(prefix, source)
        drive = letter.upper() + ':'
        for attempt in range(3):
            visible, text = drive_visible(wine, prefix, drive)
            if visible:
                return drive, drive + '\\' + rel_win
            # A running wineserver keeps the drive list it started with; restart it.
            if attempt < 2 and server.is_file():
                run([server, '-k'], env=wine_env(prefix), timeout=30, check=False)
                run([server, '-w'], env=wine_env(prefix), timeout=45, check=False)
        say(f'Drive {drive} exists on disk but Wine does not list it. Using Z: for diagnostics.', '33')
    except RuntimeError as exc:
        say(str(exc), '33')
    win_path = ('Z:' + str(Path(source).resolve())).replace('/', '\\') + '\\' + rel_win
    visible, text = drive_visible(wine, prefix, 'Z:')
    if not visible:
        raise RuntimeError('Game is not accessible through the selected Wine route.\n' + text[-1500:])
    return 'Z:', win_path


def backup_game(source):
    source = Path(source)
    target = source.with_name(source.name + f'.backup-{STAMP}')
    needed = sum(p.stat().st_size for p in source.rglob('*') if p.is_file() and not p.is_symlink())
    free = shutil.disk_usage(source.parent).free
    say(f'Game backup: {target}\nSize: {needed // 1048576} MiB | free: {free // 1048576} MiB')
    if free < needed + 512 * 1024 * 1024:
        raise RuntimeError('Not enough space for requested game backup; free space or explicitly decline it on rerun.')
    shutil.copytree(source, target, symlinks=True)
    return target


def backup_prefix(prefix, label):
    target = DATA / 'backups' / f'{Path(prefix).name}-{label}-{STAMP}'
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(prefix, target, symlinks=True)
    return target


def install_winetricks():
    wt = DATA / 'tools' / 'winetricks'
    if wt.is_file():
        run(['bash', '-n', wt])
        return wt
    legacy = LEGACY_DATA / 'tools' / 'winetricks'
    if legacy.is_file():
        atomic(wt, legacy.read_text(errors='replace'), 0o755)
        run(['bash', '-n', wt])
        say(f'Reusing winetricks already present at {legacy}.', '32')
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
    # Winetricks stores native overrides under a wildcard value name, e.g. "*dplayx".
    return rc == 0 and bool(re.search(r'"?\*?dplayx"?\s+REG_SZ\s+(?:native|n)\b', text, re.I))


def winetricks_cache_dirs():
    # Winetricks uses $WINETRICKS_CACHE when set, else $XDG_CACHE_HOME/winetricks.
    return (CACHE / 'xdg' / 'winetricks', CACHE / 'winetricks')


def seed_directplay_redist():
    """Pre-seed winetricks' DirectX cache.

    The directplay verb downloads directx_feb2010_redist.exe from a single
    web.archive.org snapshot that regularly returns 503/404. Winetricks accepts
    a cached file when its SHA256 matches, so fetch it from mirrors first.
    """
    targets = [d / 'directx9' / DIRECTX_REDIST_NAME for d in winetricks_cache_dirs()]
    if any(t.is_file() and sha256_file(t) == DIRECTX_REDIST_SHA256 for t in targets):
        return True
    for url in DIRECTX_REDIST_MIRRORS:
        try:
            download(url, targets[0], DIRECTX_REDIST_SHA256)
        except Exception as exc:
            logging.warning('DirectX redist mirror failed: %s (%s)', url, exc)
            say(f'  mirror unavailable ({url.split("/")[2]}); trying next', '33')
            continue
        for extra in targets[1:]:
            extra.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(targets[0], extra)
        return True
    return False


def install_components(wine, prefix, state, save):
    directory = windows32_dir(prefix)
    wt = install_winetricks()
    # Winetricks inspects $WINE/$WINESERVER to detect arch and the WoW64 type.
    # Our wrappers are shell scripts, which it cannot read; without the real
    # binaries it assumes a nonexistent "wine64", and its %AppData% probe fails.
    runner = runner_path()
    env = wine_env(prefix, {'WINETRICKS_CACHE': str(CACHE / 'winetricks'),
                            'XDG_CACHE_HOME': str(CACHE / 'xdg'),
                            'WINE_BIN': str(runner / 'bin' / 'wine'),
                            'WINESERVER_BIN': str(runner / 'bin' / 'wineserver')})
    rc, installed = run([wt, 'list-installed'], env=env, check=False)
    have = all((directory / n).is_file() and pe_machine(directory / n) == 0x14c for n in DIRECTPLAY_FILES)
    ready = have and rc == 0 and 'directplay' in installed.splitlines() and directplay_registered(wine, prefix)
    if not ready:
        if not yes("Close this route's Wine applications and install/repair native DirectPlay?", True):
            raise RuntimeError('DirectPlay setup declined.')
        server = DATA / 'bin/wineserver'
        run([server, '-k'], env=env, timeout=30, check=False)
        run([server, '-w'], env=env, timeout=45)
        if yes('Back up the prefix before installing DirectPlay? (optional)', False):
            backup = backup_prefix(prefix, 'before-directplay')
            say(f'Prefix backup: {backup}', '33')
        if not seed_directplay_redist():
            say('  DirectX redist could not be pre-fetched; winetricks will try '
                'archive.org itself (this often 503s).', '33')
        last = ''
        for attempt in range(1, 4):
            rc, text = run([wt, '-q', 'directplay'], env=env, timeout=1800, check=False)
            if rc == 0:
                break
            last = text[-1500:]
            if attempt < 3:
                say(f'  winetricks attempt {attempt}/3 failed; retrying in {5 * attempt}s', '33')
                time.sleep(5 * attempt)
        else:
            cache = winetricks_cache_dirs()[0] / 'directx9'
            raise RuntimeError(
                'winetricks directplay failed after 3 attempts. Download\n'
                f'  {DIRECTX_REDIST_NAME}\n'
                f'(SHA256 {DIRECTX_REDIST_SHA256}) into\n'
                f'  {cache}\n'
                'and rerun, or retry later when archive.org is reachable.\n'
                + last)
    missing = [n for n in DIRECTPLAY_FILES if not (directory / n).is_file()
               or pe_machine(directory / n) != 0x14c]
    if missing or not directplay_registered(wine, prefix):
        raise RuntimeError(f'32-bit DirectPlay verification failed in {directory}; files={missing}')
    for value in ('dpnlobby', '*dpnlobby'):
        run([wine, 'reg', 'delete', r'HKCU\Software\Wine\DllOverrides', '/v', value, '/f'],
            env=env, check=False)
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


LAUNCHER_TEMPLATE = '#!/usr/bin/env bash\nset -uo pipefail\numask 077\nBASE=@BASE_Q@\nRUNNER=@RUNNER_Q@\nPREFIX=@PREFIX_Q@\nGAME=@GAME_Q@\nDRIVE_PREF=@DRIVE_Q@\nGAME_REL=@REL_Q@\nMARKER=@MARKER_Q@\nFIXED_TARGET=@TARGET_Q@\nPREFIX_ARCH=@ARCH_Q@\nROUTE=@ROUTE_Q@\nTITLE=@TITLE_Q@\nBIN="$BASE/bin"\nLOG="$BASE/logs/@SLUG@-$(date +%Y%m%d-%H%M%S)-$$.log"\n[[ -x "$BIN/wine" && -x "$RUNNER/bin/wine" ]] || { echo \'Wine runner/wrapper missing.\' >&2; exit 1; }\n[[ -f "$PREFIX/system.reg" ]] || { echo \'Prefix missing.\' >&2; exit 1; }\ngrep -q "^#arch=$PREFIX_ARCH\\$" "$PREFIX/system.reg" || { echo \'Wrong prefix architecture.\' >&2; exit 1; }\nfor var in ${!WINE@} ${!BOX64_@} ${!BOX86_@} ${!FEX_@}; do\n    unset "$var"\ndone\nunset LD_PRELOAD LD_LIBRARY_PATH STAGING_WRITECOPY VOOBLY_DLLOVERRIDES\nexport WINE="$BIN/wine" WINESERVER="$BIN/wineserver"\nexport WINEPREFIX="$PREFIX" WINEARCH="$PREFIX_ARCH"\nexport PATH="$BIN:$RUNNER/bin:$PATH"\nexport WINEDLLOVERRIDES=\'winemenubuilder.exe=d\'\nexport WINEDEBUG=\'-all,err+all\'\nif [[ "$ROUTE" == box64 ]]; then\n    export BOX64_NOBANNER=1 BOX64_LD_LIBRARY_PATH=@X64LD_Q@\nfi\nmkdir -p "$BASE/logs"\n# Locks are per shared game directory, not per emulator/prefix.\nLOCKFILE=@LOCK_Q@\nmkdir -p "$(dirname "$LOCKFILE")"\nexec 9>"$LOCKFILE"\nflock -n 9 || { echo \'Another managed game/Voobly launcher is using this game directory.\' >&2; exit 1; }\nHELPER="$BASE/tools/clear-directplay-conflict.sh"\nif [[ -x "$HELPER" ]]; then\n    # Force-start: always free port 47624 before launching.\n    "$HELPER" --force || echo "warning: port 47624 is still in use; continuing anyway." >&2\nfi\nensure_drive() {\n    local letter link\n    for letter in "$DRIVE_PREF" y x w v u t s r q p o n m l k j i h g f e d; do\n        link="$PREFIX/dosdevices/$letter:"\n        if [[ "$(readlink -f "$link" 2>/dev/null)" == "$(readlink -f "$GAME")" ]]; then\n            printf \'%s:\' "${letter^^}"; return\n        fi\n    done\n    for letter in "$DRIVE_PREF" y x w v u t s r q p o n m l k j i h g f e d; do\n        link="$PREFIX/dosdevices/$letter:"\n        if [[ ! -e "$link" && ! -L "$link" ]]; then\n            ln -s -- "$GAME" "$link" || return 1\n            printf \'%s:\' "${letter^^}"; return\n        fi\n    done\n    return 1\n}\nif [[ -n "$GAME_REL" ]]; then\n    TARGET="$GAME/$GAME_REL"\nelse\n    TARGET="$FIXED_TARGET"\n    DRIVE="$(ensure_drive || true)"\n    if [[ -n "$DRIVE" ]]; then\n        printf \'Game mapping: %s -> %s\\n\' "$DRIVE" "$GAME"\n    else\n        echo \'No spare drive letter; select the game through Z: in Voobly.\' >&2\n    fi\nfi\n[[ -f "$TARGET" ]] || { echo "Missing executable: $TARGET" >&2; exit 1; }\ncd "$GAME" || exit 1\nprintf \'Starting %s via %s without a time limit.\\nLog: %s\\n\' "$TITLE" "$ROUTE" "$LOG"\n"$WINE" "$TARGET" @ARGS@ "$@" 9>&- >"$LOG" 2>&1 &\nchild=$!\n# Sample process mappings to flag accidental fallback to the other emulator.\nsleep 1\nif ! python3 "$BASE/tools/audit-route.py" "$PREFIX" "$ROUTE" >>"$LOG" 2>&1; then\n    echo "Wrong emulator detected. Close the application; inspect $LOG" >&2\nfi\nwait "$child"\nrc=$?\nprintf \'@SLUG@_EXIT=%s\\nLog: %s\\n\' "$rc" "$LOG"\n[[ "$rc" -eq 0 ]] || tail -n 80 "$LOG"\nexit "$rc"\n'


def make_launcher(slug, title, target, args, runner, prefix, source, drive, fex, rel='', marker=''):
    gameid = hashlib.sha256(str(Path(source).resolve()).encode()).hexdigest()[:24]
    values = {
        '@BASE_Q@': DATA, '@RUNNER_Q@': runner, '@PREFIX_Q@': prefix,
        '@GAME_Q@': source, '@DRIVE_Q@': 'y' if drive.upper().startswith('Z') else drive[0].lower(),
        '@REL_Q@': rel, '@MARKER_Q@': marker, '@TARGET_Q@': target,
        '@ARCH_Q@': PREFIX_ARCH, '@ROUTE_Q@': ROUTE, '@TITLE_Q@': title,
        '@LOCK_Q@': BASE_DATA / 'locks' / (gameid + '.lock'),
        '@X64LD_Q@': shlex.quote(box64_ld_library_path()),
    }
    text = LAUNCHER_TEMPLATE
    for key, value in values.items(): text = text.replace(key, shlex.quote(str(value)))
    text = text.replace('@SLUG@', slug).replace('@ARGS@', shlex.join(shlex.split(args)))
    path = DATA / 'bin' / slug
    atomic(path, text, 0o755)
    run(['bash', '-n', path])
    return path


def menu_entry(slug, title, launcher, icon, ident, source):
    key = f'aoe2-voobly-{ident}-{slug}'
    file = APPS / (key + '.desktop')
    text = '[Desktop Entry]\nType=Application\nVersion=1.0\n'
    text += f'Name={title} ({ROUTE})\nComment=AoE II through the isolated {ROUTE} Wine prefix\n'
    text += 'Exec=' + exec_quote(launcher) + '\n'
    text += f'Path={desktop_escape(source)}\nIcon={desktop_escape(icon)}\nTerminal=false\n'
    text += 'Categories=Game;StrategyGame;\nStartupNotify=false\n'
    if file.exists() and file.read_text() != text:
        shutil.copy2(file, file.with_suffix('.desktop.bak-' + STAMP))
    atomic(file, text, 0o755)
    if shutil.which('desktop-file-validate'): run(['desktop-file-validate', file], check=False)
    return file


PORT_HELPER = r'''#!/usr/bin/env bash
# Free TCP/UDP 47624 for DirectPlay before launching. Launchers call --force,
# which terminates every process of this user holding the port and restarts the
# prefix's wineserver if it still shares an inherited socket.
set -uo pipefail
MODE="${1:---force}"
case "$MODE" in --check|--force|interactive) ;; *) echo 'Usage: helper [--check|--force|interactive]' >&2; exit 2;; esac
DEFAULT_PREFIX=@PREFIX_Q@
WINESERVER_BIN=@WINESERVER_Q@
PREFIX="${WINEPREFIX:-$DEFAULT_PREFIX}"
command -v ss >/dev/null || { echo 'ss is required (iproute2/iproute).' >&2; exit 1; }
sockets() { ss -H -lntup 'sport = :47624'; }
current="$(sockets)"
[[ -n "$current" ]] || exit 0
printf 'Port 47624 is occupied:
%s
' "$current"
[[ "$MODE" == --check ]] && exit 1
pids() { printf '%s
' "$1" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u; }
stop_pid() {
    local pid=$1 state
    [[ -O "/proc/$pid" ]] || return 0
    kill -TERM "$pid" 2>/dev/null || return 0
    for _ in {1..20}; do [[ -d "/proc/$pid" ]] || return 0; sleep 0.25; done
    state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)"
    [[ "$state" == Z ]] || kill -KILL "$pid" 2>/dev/null || true
}
for pid in $(pids "$current"); do
    if [[ "$MODE" == interactive ]]; then
        ps -p "$pid" -o pid,ppid,user,stat,etime,args || true
        read -r -p "Stop PID $pid? [y/N] " a </dev/tty || true
        case "$a" in y|Y|yes|YES) ;; *) continue;; esac
    else
        printf '  stopping pid %s (%s)
' "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null || echo '?')"
    fi
    stop_pid "$pid"
done
sleep 0.5
left="$(sockets)"
if [[ -n "$left" && -x "$WINESERVER_BIN" ]]; then
    # wineserver keeps inherited socket fds; restart this prefix's server.
    WINEPREFIX="$PREFIX" "$WINESERVER_BIN" -k >/dev/null 2>&1 || true
    for _ in {1..20}; do [[ -n "$(sockets)" ]] || break; sleep 0.5; done
fi
left="$(sockets)"
if [[ -n "$left" ]]; then
    printf 'Port 47624 still in use:
%s
' "$left"; exit 1
fi
echo 'Port 47624 is free.'
'''


def attach_terminal():
    """Interactive prompts must not read the piped script source.

    With `curl ... | python3` stdin is the script itself; reopen the controlling
    terminal so ask()/yes() keep working.
    """
    try:
        if sys.stdin is None or not sys.stdin.isatty():
            sys.stdin = open('/dev/tty', 'r', encoding='utf-8', errors='replace')
    except OSError:
        pass


def main():
    if sys.version_info < (3, 9): raise RuntimeError('Python 3.9 or newer is required; install a prebuilt distro Python.')
    if sys.platform != 'linux': raise RuntimeError('This utility supports Linux only.')
    attach_terminal()
    configure_route()
    if os.geteuid() == 0: raise RuntimeError('Run as your desktop user, not root or sudo.')
    LOG.parent.mkdir(parents=True, exist_ok=True); CACHE.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=LOG, level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    lock = (BASE_DATA / 'installer.lock').open('w')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise RuntimeError('Another installer is already running.')
    say('\n╔══════════════════════════════════════════════════════════════╗\n'
        '║           AGE OF EMPIRES II  ×  VOOBLY                       ║\n'
        '║           Classic games. A dedicated Linux home.             ║\n'
        '╚══════════════════════════════════════════════════════════════╝', '1;33')
    if VERBOSE:
        say('Verbose mode: every command and its output is printed as it runs.', '2')

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
    if (prefix.exists() and any(prefix.iterdir()) and not statefile.exists()
            and not str(prefix).startswith(str(DATA) + os.sep)):
        raise RuntimeError('Nonempty unmanaged prefix: refusing to mutate it. Choose a new empty prefix.')

    state.update(route=ROUTE, prefix_architecture=PREFIX_ARCH)
    say(f'\nHost: {machine}\nOriginal: {source}\nConquerors: {aoc_rel}\nSetup: {setup}\nPrefix: {prefix}')
    say(f'Route: {ROUTE} | Wine archive: {WINE_ARCHIVE} | prefix: {PREFIX_ARCH}\n'
        f'Workspace: {DATA}\nExisting game is shared read-write; nothing outside this workspace is modified.')
    if not yes('Proceed with this configuration?', True): return
    def save(): atomic(statefile, json.dumps(state, indent=2))

    previous = state.get('route')
    if previous and previous != ROUTE:
        say(f'Switching the emulator for this prefix: {previous} -> {ROUTE}; '
            f'stopping {previous} processes on it first.', '33')
        stop_route_processes(prefix)

    # Already present for this prefix is reused by default; replacing is explicit.
    fresh = reuse_or_replace(prefix, statefile, ident, source)
    if fresh is not None:
        state = fresh

    if prefix_arch(prefix) not in (None, PREFIX_ARCH):
        raise RuntimeError('Prefix architecture does not match this route; select a new prefix.')

    stage(2, 'Distribution, prebuilt emulator and helper preflight')
    fex = None
    if arch == 'arm64':
        fex = require_emulator()
        say(f'{ROUTE}: {fex} (explicit native ARM64 emulator)', '32')
    else:
        say('Native x86 CPU: no emulator is used.', '32')
    tools()

    stage(3, 'Install and verify the prebuilt Wine runner')
    say(f'Runner: Kron4ek {WINE_ARCHIVE} (pinned SHA256)')
    runner = install_runner()
    if ROUTE == 'box64':
        ensure_box64_x64libs(runner)
    wine, _ = install_wrappers(runner, fex, prefix)
    version = check_wine_version(wine, prefix, fex)
    state.update(wine=str(wine), runner=str(runner), route=ROUTE, emulator=str(fex or ''), arch=arch, version=version); save()
    atomic(DATA / 'tools/audit-route.py', "#!/usr/bin/env python3\nimport os, re, sys\nfrom pathlib import Path\nprefix, expected = sys.argv[1:3]\nseen = []\nwrong = []\nfor p in Path('/proc').glob('[0-9]*'):\n    try:\n        if p.stat().st_uid != os.getuid(): continue\n        if ('WINEPREFIX=' + prefix).encode() not in (p/'environ').read_bytes().split(b'\\0'): continue\n        maps = (p/'maps').read_text(errors='replace')\n        fex = bool(re.search(r'/FEX(?:Interpreter|Loader)?(?:\\s|$)|libFEX', maps, re.M))\n        box = bool(re.search(r'/box64(?:\\s|$)', maps, re.M))\n        actual = 'fex' if fex else 'box64' if box else None\n        if actual:\n            seen.append((p.name, actual))\n            if actual != expected: wrong.append((p.name, actual))\n    except OSError: pass\nprint('Route audit: expected=', expected, 'observed=', seen, 'conflicts=', wrong)\nif not seen: print('No emulator mapping visible at this instant; route was not independently verified.')\nsys.exit(1 if wrong else 0)\n", 0o755)

    stage(4, f'Create a {PREFIX_ARCH} prefix and verify 32-bit Windows execution')
    create_prefix(wine, prefix, state, save)
    say(f'Prefix reports #arch={PREFIX_ARCH} and executed a 32-bit cmd.exe.', '32')

    stage(5, 'Expose the existing game to Wine')
    drive, game_win = map_drive(wine, prefix, source, aoc_rel)
    say(f'{drive} -> {source}\nConquerors executable: {game_win}', '32')
    state['game_drive'] = drive; save()
    # Voobly's Game Diagnostics may patch this shared directory; keep a backup first.
    have_backup = bool(state.get('game_backup')) and Path(state['game_backup']).is_dir()
    if not have_backup and yes('Back up the original game directory before Voobly can patch it? (optional)', False):
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

    entries, icons_used = [], []
    for slug, (script, title, target, args) in launchers.items():
        exe = aok[0] if slug == 'aok' else aoc[0]
        icon = make_icon(exe, f'aoe2-voobly-{ident}-{slug}', title)
        icons_used.append(str(icon))
        entries.append(str(menu_entry(slug, title, created[slug], icon, ident, source)))
    icon = make_icon(voobly, f'aoe2-voobly-{ident}-voobly', 'Voobly')
    icons_used.append(str(icon))
    entries.append(str(menu_entry('voobly', 'Voobly', created['voobly'], icon, ident, source)))
    # Drop menu entries/icons left behind by an earlier workspace or ident so
    # switching never duplicates the menu. Entries of other layouts are kept.
    owned = (str(DATA), str(LEGACY_DATA / 'routes' / 'wow64'),
             str(LEGACY_DATA / 'routes' / 'box64-wow64'))
    stale_icons = set()
    for stale in sorted(APPS.glob('aoe2-voobly-*')):
        if '.bak-' in stale.name or str(stale) in entries:
            continue
        stale_text = stale.read_text(errors='replace')
        if any(path in stale_text for path in owned):
            stale.unlink()
            for line in stale_text.splitlines():
                if line.startswith('Icon='):
                    stale_icons.add(line[5:])
            say(f'Removed stale desktop entry: {stale.name}', '33')
    for icon_path in sorted(stale_icons):
        target_icon = Path(icon_path)
        if target_icon.is_file() and str(target_icon) not in icons_used:
            target_icon.unlink()
    for icon_dir in (ICONS, ICONS.parent.parent / 'scalable/apps'):
        if icon_dir.is_dir():
            for stale in sorted(icon_dir.glob('aoe2-voobly-*')):
                if str(stale) not in icons_used:
                    stale.unlink()
    if shutil.which('update-desktop-database'):
        run(['update-desktop-database', APPS], check=False)

    helper = DATA / 'tools' / 'clear-directplay-conflict.sh'
    atomic(helper, PORT_HELPER.replace('@PREFIX_Q@', shlex.quote(str(prefix)))
           .replace('@WINESERVER_Q@', shlex.quote(str(DATA / 'bin' / 'wineserver'))), 0o755)

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
        run([str(helper), '--check'], env=wine_env(prefix), check=False)
    port = run(['ss', '-H', '-lntup', 'sport = :47624'], check=False) if shutil.which('ss') else (0, '')
    z_path = 'Z:' + str(source).replace('/', '\\')
    summary = {
        'host_architecture': machine,
        'wine_version': version,
        'wine_binary': str(runner / 'bin/wine'),
        'wine_wrapper': str(wine),
        'execution': f'{ROUTE} ({fex})' if fex else 'native x86',
        'wine_archive_sha256': WINE_SHA256,
        'distribution_family': distro_family(),
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
    title = ('INSTALLATION COMPLETE — application screens confirmed' if complete
             else 'INSTALLATION PREPARED — visual checks incomplete')
    colour = '1;32' if complete else '1;33'
    if COLOR:
        say('', colour)
        say('  ╔' + '═' * 70 + '╗', colour)
        say('  ║  ' + ('✔ ' if complete else '▶ ') + title.ljust(67) + '║', colour)
        say('  ╚' + '═' * 70 + '╝', colour)
    else:
        say('\n' + title)
    for k, v in summary.items():
        say(f'{k}: {json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v}')
    say('\nRemaining manual steps:\n'
        '• Launch Voobly, run Game Diagnostics, and set Installation directory ' + drive + '\\ and\n'
        '  Executable ' + game_win + '.\n'
        '• If Voobly does not list that drive, use Z: instead: ' + z_path + '\n'
        '• Validate v1.5 RC first; then test the matched v1.6 RC + v1.6 Game Data pair separately.\n'
        '• Preserve working graphics/media settings; pass -nostartup to the game if needed.\n'
        '• If multiplayer drops back to the connection screen, a stale DirectPlay helper may hold\n'
        '  port 47624. The launchers report occupied ports without killing processes; run ' + str(helper) + '\n'
        '  to inspect and explicitly terminate a confirmed leftover helper.\n'
        '• Do not kill every dplaysvr.exe or change DirectPlay repeatedly; a helper owning 47624 during a\n'
        '  match is normal.\n'
        '• Complete a real two-player match, then back up the working prefix and game directory.\n'
        'No game reinstall or global Wine replacement was performed; Voobly may update shared game files.')
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
