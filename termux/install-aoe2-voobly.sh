#!/usr/bin/env python3
"""AoE II Classic + Voobly installer for Android / Termux -- native, no proot.

Port of install_aoe2_voobly.py. Same data layout and the same Wine 10.0
amd64-wow64 / single shared win64 prefix design, but everything runs directly
inside Termux:

    Termux (bionic)  ->  glibc-packages runtime ($PREFIX/glibc)
                     ->  box64-glibc (native AArch64 emulator)
                     ->  Wine 10.0 amd64-wow64 (Kron4ek prebuilt, SHA256 pinned)
                     ->  Winetricks DirectPlay -> Voobly -> AoE II launchers

No proot-distro, no chroot, no root. Display is Termux:X11, audio is
PulseAudio over loopback TCP.

Emulated x86_64 libraries that Box64 does not wrap (libgcc_s, and freetype /
fontconfig / gnutls with their dependency closure) are fetched as prebuilt
AlmaLinux 9 RPMs. File names and SHA256 sums come from the signed-by-TLS repo
metadata, and the RPMs are unpacked user-locally. Nothing is compiled.

FEX: its maintainers state Wine does not work under FEX on Termux (Android
seccomp). --route fex exists for experimentation only and needs --emulator.

Wine is not a sandbox. Use trusted licensed game files/installers.
Real multiplayer needs a user smoke test.
"""
from __future__ import annotations

import argparse
import bz2
import datetime as dt
import fcntl
import gzip
import hashlib
import json
import logging
import lzma
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
import xml.etree.ElementTree as ET
from pathlib import Path

HOME = Path.home()
TERMUX = Path(os.environ.get('PREFIX') or '/data/data/com.termux/files/usr')
BASH = TERMUX / 'bin/bash'
GLIBC = TERMUX / 'glibc'
GLIBC_LIB = GLIBC / 'lib'
GLIBC_BIN = GLIBC / 'bin'

DATA_HOME = Path(os.environ.get('XDG_DATA_HOME', HOME / '.local/share')).expanduser().absolute()
BASE_DATA = DATA_HOME / 'aoe2-multiplayer-linux'
DATA = BASE_DATA
_CACHE_HOME = Path(os.environ.get('XDG_CACHE_HOME', HOME / '.cache')).expanduser().absolute()
BASE_CACHE = _CACHE_HOME / 'aoe2-multiplayer-linux'
CACHE = BASE_CACHE
TRANSLATOR = BASE_DATA / 'translator'
X64LIBS = TRANSLATOR / 'x64libs'
SHORTCUTS = HOME / '.shortcuts'          # Termux:Widget
COLOR = sys.stdout.isatty() and not os.environ.get('NO_COLOR')
SPINNER = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
STAMP = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
LOG = DATA / 'logs' / (STAMP + '.log')

WINE_VERSION = '10.0'
WINE_FLAVOR = 'amd64-wow64'
WINE_ARCHIVE = f'wine-{WINE_VERSION}-{WINE_FLAVOR}.tar.xz'
WINE_SHA256 = 'aeebbbf239e548f0136f1cd72a2e109dd9a572a8f703da3c09fa40d74d5c255f'
WINE_URL = f'https://github.com/Kron4ek/Wine-Builds/releases/download/{WINE_VERSION}/{WINE_ARCHIVE}'
PREFIX_ARCH = 'win64'

# Prebuilt emulated x86_64 libraries come from this repo's metadata.
ALMA_BASE = 'https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/'
# Not needed to start Wine, but without them text/TLS break. Optional: failure only warns.
X64_EXTRA_LIBS = ('libfreetype.so.6', 'libfontconfig.so.1', 'libgnutls.so.30')

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

# Host-side (glibc, AArch64) packages that Box64's wrappers dlopen. Names are
# discovered from the repo at run time, so naming differences do not matter.
GLIBC_LIB_PATTERN = re.compile(
    r'^(libx|xcb|libxcb|libxkb|libpulse|pulseaudio|alsa|libdrm|libglvnd|mesa|virglrenderer|libepoxy|xorg)')
GLIBC_CRITICAL = ('libX11.so.6', 'libxcb.so.1')

TOTAL_STAGES = 8
ROUTE = 'box64'
OPTIONS = None
VERBOSE = False
RENDERER = 'gdi'
EMU_CMD: list = []      # argv prefix that starts the emulator
EMU_ENV: dict = {}      # extra env the emulator needs (e.g. LD_LIBRARY_PATH)

DIRECTPLAY_FILES = ('dplayx.dll', 'dpnet.dll', 'dpnhpast.dll', 'dpwsockx.dll')
DIRECTX_REDIST_NAME = 'directx_feb2010_redist.exe'
DIRECTX_REDIST_SHA256 = 'f6d191e89a963d7cca34f169d30f49eab99c1ed3bb92da73ec43617caaa1e93f'
DIRECTX_REDIST_MIRRORS = (
    'https://files.holarse-linuxgaming.de/mirrors/microsoft/directx_feb2010_redist.exe',
    'https://web.archive.org/web/20100205000000id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe',
    'https://web.archive.org/web/20101224202650id_/http://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe',
    'https://web.archive.org/web/2016id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe',
)


# ------------------------------------------------------------------- UI -----
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


# ------------------------------------------------------------ subprocess ----
def run(argv, env=None, cwd=None, timeout=180, check=True):
    argv = [str(x) for x in argv]
    logging.info('RUN %s cwd=%s', shlex.join(argv), cwd)
    if VERBOSE:
        say(f'  $ {shlex.join(argv)}', '2')
    with tempfile.TemporaryFile(mode='w+') as output:
        proc = sp.Popen(argv, env=env, cwd=cwd, stdout=output, stderr=sp.STDOUT, start_new_session=True)
        start = time.monotonic()
        label = shlex.join(argv)
        label = '…' + label[-44:] if len(label) > 45 else label
        i = 0
        try:
            while proc.poll() is None:
                if timeout and time.monotonic() - start > timeout:
                    raise RuntimeError(f'Timed out: {shlex.join(argv)}. Wine children may still be running; inspect the log.')
                if sys.stdout.isatty():
                    spun = SPINNER[i % len(SPINNER)] if COLOR else '|/-\\'[i % 4]
                    print(f'\r\033[K  {spun} {label:<45} {int(time.monotonic() - start):>3}s', end='', flush=True)
                i += 1
                time.sleep(.12)
        except BaseException:
            # Ctrl+C and timeouts must not leave the Wine application running.
            if proc.poll() is None:
                try: os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try:
                    proc.wait(8)
                except sp.TimeoutExpired:
                    try: os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
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


# -------------------------------------------------------------- file utils --
def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def download(url, target, digest=None):
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and digest and sha256_file(target) == digest.lower():
        return target
    if VERBOSE:
        say(f'  GET {url}', '2')
    temp = target.with_suffix(target.suffix + '.part')
    req = urllib.request.Request(url, headers={'User-Agent': 'AoE2-Voobly-Termux-Installer/3.0'})
    with urllib.request.urlopen(req, timeout=60) as response, temp.open('wb') as f:
        total = int(response.headers.get('Content-Length', 0))
        done = 0
        while chunk := response.read(1024 * 512):
            f.write(chunk); done += len(chunk)
            if sys.stdout.isatty():
                if total:
                    print(f'\r  {bar(done / total)} {done / total:6.1%}  '
                          f'{human_size(done)}/{human_size(total)}  {target.name[:28]}', end='', flush=True)
                else:
                    print(f'\r  {human_size(done)}  {target.name[:40]}', end='', flush=True)
    if sys.stdout.isatty():
        print('\r\033[K', end='', flush=True)
    actual = sha256_file(temp)
    logging.info('DOWNLOAD %s sha256=%s', url, actual)
    if digest and actual != digest.lower():
        temp.unlink()
        raise RuntimeError(f'SHA256 verification failed for {target.name}; it was not used.')
    temp.replace(target)
    say(f'  ✔ {target.name} ({human_size(target.stat().st_size)}' + (', SHA256 verified)' if digest else ')'), '32')
    return target


def api(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'AoE2-Voobly-Termux-Installer/3.0'})
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.load(r)


def atomic(path, text, mode=0o644):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    tmp.write_text(text); tmp.chmod(mode); tmp.replace(path)


def find_ci(root, name):
    return sorted((p for p in Path(root).rglob('*') if p.is_file() and p.name.casefold() == name.casefold()),
                  key=lambda p: (len(p.relative_to(root).parts), str(p)))


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


def elf_interp(path):
    """PT_INTERP of a 64-bit little-endian ELF ('' if static or unreadable)."""
    try:
        with Path(path).open('rb') as f:
            h = f.read(64)
            if len(h) < 64 or h[:4] != b'\x7fELF' or h[4] != 2 or h[5] != 1: return ''
            phoff = struct.unpack_from('<Q', h, 0x20)[0]
            phentsize, phnum = struct.unpack_from('<HH', h, 0x36)
            for i in range(phnum):
                f.seek(phoff + i * phentsize)
                ph = f.read(phentsize)
                if struct.unpack_from('<I', ph, 0)[0] == 3:
                    off, size = struct.unpack_from('<Q', ph, 8)[0], struct.unpack_from('<Q', ph, 32)[0]
                    f.seek(off)
                    return f.read(size).split(b'\0')[0].decode('ascii', 'replace')
    except (OSError, struct.error):
        pass
    return ''


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


def safe_extract(tar, destination):
    if hasattr(tarfile, 'data_filter'):
        tar.extractall(destination, filter='data')
        return
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
    for m in members:
        dest = root / m.name
        if not contained(dest): raise RuntimeError('Unsafe archive traversal: ' + m.name)
        tar.extract(m, destination, set_attrs=False)
        if m.isfile(): dest.chmod(m.mode & 0o777)


def path_input(label, default, kind):
    while True:
        p = Path(os.path.expandvars(ask(label, default).strip().strip('"\''))).expanduser().absolute()
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


def attach_terminal():
    """With `curl ... | python3` stdin is the script itself; reopen the terminal for prompts."""
    try:
        if sys.stdin is None or not sys.stdin.isatty():
            sys.stdin = open('/dev/tty', 'r', encoding='utf-8', errors='replace')
    except OSError:
        pass


# --------------------------------------------------------------- Android ----
def android_sdk():
    try:
        out = sp.run(['getprop', 'ro.build.version.sdk'], capture_output=True, text=True, timeout=10).stdout
        return int(out.strip() or 0)
    except (OSError, ValueError, sp.SubprocessError):
        return 0


def preflight():
    if sys.version_info < (3, 9): raise RuntimeError('Python 3.9+ is required (pkg install python).')
    if sys.platform != 'linux' or not (TERMUX / 'bin/pkg').exists():
        raise RuntimeError('Run this inside Termux (F-Droid or GitHub build), not a generic shell.')
    if os.geteuid() == 0: raise RuntimeError('Run as the Termux user, not root.')
    if platform.machine().lower() not in ('aarch64', 'arm64'):
        raise RuntimeError('This port needs an arm64-v8a device (Box64 emulates x86_64 on AArch64).')
    if 'PLAY' in os.environ.get('TERMUX_APK_RELEASE', '').upper():
        raise RuntimeError('The Google Play build of Termux cannot execute downloaded binaries. '
                           'Install Termux from F-Droid or GitHub instead.')
    sdk = android_sdk()
    if 0 < sdk < 26: say(f'Android 8+ is recommended (detected SDK {sdk}).', '33')
    if sdk >= 31:
        say('Android 12+ can kill Wine as a "phantom process" mid-game. If that happens, run once from a PC:\n'
            '  adb shell "settings put global settings_enable_monitor_phantom_procs false"\n'
            '  (or set Developer options > "Disable child process restrictions").', '33')
    free = shutil.disk_usage(HOME).free
    if free < 3 * 1024 ** 3:
        raise RuntimeError(f'Only {human_size(free)} free in Termux storage; about 5 GiB is needed.')
    if free < 5 * 1024 ** 3:
        say(f'Low free space: {human_size(free)}. About 5 GiB is recommended.', '33')


def on_shared_storage(path):
    real = str(Path(path).resolve())
    return real.startswith(('/storage/', '/sdcard')) or real.startswith(str((HOME / 'storage').resolve()))


# ------------------------------------------------------------ Termux pkgs ---
BASE_PACKAGES = ['termux-x11-nightly', 'pulseaudio', 'curl', 'tar', 'xz-utils', 'zstd', 'coreutils',
                 'cabextract', 'unzip', 'file', 'gawk', 'grep', 'sed', 'util-linux', 'procps',
                 'libarchive', 'findutils']


def pkg_install(names):
    cmd = ['pkg', 'install', '-y', '-o', 'Dpkg::Options::=--force-confold', *names]
    rc, text = run(cmd, timeout=3600, check=False)
    if rc:
        run(['pkg', 'update', '-y'], timeout=900, check=False)
        rc, text = run(cmd, timeout=3600, check=False)
    return rc == 0, text


def install_termux_packages():
    ok, text = pkg_install(['x11-repo', 'glibc-repo'])
    if not ok: raise RuntimeError('Could not enable the x11 and glibc repositories.\n' + text[-1500:])
    names = BASE_PACKAGES + ['glibc-runner']
    if ROUTE == 'box64': names.append('box64-glibc')
    if RENDERER == 'gl': names.append('virglrenderer-android')
    ok, text = pkg_install(names)
    if not ok: raise RuntimeError('pkg install failed.\n' + text[-2500:])
    if not shutil.which('termux-x11'):
        raise RuntimeError('termux-x11 is missing. Install the Termux:X11 app too: '
                           'https://github.com/termux/termux-x11/releases')

    # Host-side glibc libraries that Box64's native wrappers dlopen (X11, audio, GL).
    _, out = run(['apt-cache', 'pkgnames'], check=False)
    avail = sorted(n for n in out.split() if n.endswith('-glibc')
                   and GLIBC_LIB_PATTERN.match(n[:-6]) and not re.search(r'(-dev|-doc)-glibc$', n))
    if avail:
        say(f'  glibc libraries: {len(avail)} package(s) for X11/audio/GL', '2')
        ok, text = pkg_install(avail)
        if not ok:
            say('  Some glibc library packages failed to install; continuing. See the log.', '33')
    missing = [n for n in GLIBC_CRITICAL if not (GLIBC_LIB / n).exists()]
    if missing:
        raise RuntimeError('Host glibc libraries missing: ' + ', '.join(missing) +
                           f'\nLooked in {GLIBC_LIB}. List what the repo offers with:\n'
                           '  apt-cache pkgnames | grep -- -glibc')
    for soft, what in (('libpulse.so.0', 'audio'), ('libGL.so.1', 'OpenGL (only for --renderer gl)')):
        if not (GLIBC_LIB / soft).exists():
            say(f'  note: host {soft} not found; {what} may be unavailable.', '33')


def tools():
    need = {'cabextract': 'cabextract', 'unzip': 'unzip', 'curl': 'curl', 'sha256sum': 'coreutils',
            'flock': 'util-linux', 'file': 'file', 'awk': 'gawk', 'bsdtar': 'libarchive',
            'xz': 'xz-utils', 'tar': 'tar', 'grep': 'grep', 'sed': 'sed', 'ps': 'procps', 'timeout': 'coreutils'}
    missing = [c for c in need if not shutil.which(c)]
    if missing:
        pkg_install(sorted({need[c] for c in missing}))
    missing = [c for c in need if not shutil.which(c)]
    if missing: raise RuntimeError('Commands still unavailable: ' + ', '.join(missing))


# -------------------------------------------------- display / audio session -
SESSION_TEMPLATE = r'''# Sourced by the installer and every launcher: Termux:X11, PulseAudio, optional VirGL.
TERMUX_PREFIX=@TERMUX_Q@
X_SOCKET="$TERMUX_PREFIX/tmp/.X11-unix/X0"

aoe2_session_start() {
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock || true
    if ! pgrep -f 'termux.x11' >/dev/null 2>&1; then
        nohup termux-x11 :0 -ac >/dev/null 2>&1 &
    fi
    local i
    for i in $(seq 1 40); do [[ -S "$X_SOCKET" ]] && break; sleep 0.5; done
    [[ -S "$X_SOCKET" ]] || echo 'Termux:X11 did not start; is the Termux:X11 app installed?' >&2
    am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true
    export DISPLAY=:0 PULSE_SERVER=tcp:127.0.0.1
    pgrep -x pulseaudio >/dev/null 2>&1 \
        || pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
    pactl list short modules 2>/dev/null | grep -q module-native-protocol-tcp \
        || pactl load-module module-native-protocol-tcp auth-anonymous=1 listen=127.0.0.1 >/dev/null 2>&1 \
        || true
    if [[ "${AOE2_RENDERER:-gdi}" == gl ]] && command -v virgl_test_server_android >/dev/null 2>&1; then
        pgrep -f virgl_test_server_android >/dev/null 2>&1 \
            || { nohup virgl_test_server_android >/dev/null 2>&1 & sleep 1; }
        export GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.0
    fi
}
'''


def install_session():
    path = DATA / 'tools' / 'session.sh'
    atomic(path, SESSION_TEMPLATE.replace('@TERMUX_Q@', shlex.quote(str(TERMUX))), 0o644)
    run([BASH, '-n', path])
    return path


def start_session():
    session = install_session()
    run([BASH, '-c', f'AOE2_RENDERER={shlex.quote(RENDERER)}; . {shlex.quote(str(session))}; aoe2_session_start'],
        timeout=120, check=False)


# -------------------------------------------------------------- emulator ----
def require_emulator():
    name = 'FEX' if ROUTE == 'fex' else 'box64'
    if OPTIONS.emulator:
        found = OPTIONS.emulator
    elif ROUTE == 'box64':
        found = GLIBC_BIN / 'box64' if (GLIBC_BIN / 'box64').is_file() else shutil.which('box64')
    else:
        raise RuntimeError('--route fex needs --emulator /path/to/FEX (nothing in Termux ships it).')
    if not found or not Path(found).is_file() or not os.access(found, os.X_OK):
        raise RuntimeError(f'{name} executable missing. Run: pkg install glibc-repo && pkg install box64-glibc')
    resolved = Path(found).resolve()
    if elf_machine(resolved) != 183:
        raise RuntimeError(f'Expected a native AArch64 ELF emulator, not a script/foreign binary: {resolved}')
    if ROUTE == 'box64' and 'ld-linux' not in elf_interp(resolved):
        raise RuntimeError(f'{resolved} is a bionic build and cannot run glibc Wine. Install box64-glibc.')
    if ROUTE == 'fex':
        say('FEX maintainers state that Wine does not work under FEX in Termux (Android seccomp).\n'
            'This route is experimental; expect failures.', '33')
        if not yes('Continue with FEX anyway?', False): raise RuntimeError('FEX route declined.')
    return resolved


def probe_emulator(emu):
    """Find a way to start the emulator: directly, with LD_LIBRARY_PATH, or through grun."""
    grun = TERMUX / 'bin/grun'
    variants = [([], {}), ([], {'LD_LIBRARY_PATH': str(GLIBC_LIB)})]
    if grun.is_file(): variants.append(([str(grun)], {}))
    last = ''
    for pre, extra in variants:
        env = os.environ.copy(); env.pop('LD_PRELOAD', None); env.update(extra)
        rc, text = run([*pre, emu, '--version'], env=env, timeout=60, check=False)
        last = text
        if rc == 0 and text.strip():
            return [*pre, str(emu)], extra
    raise RuntimeError('The emulator cannot start in Termux.\n' + last[-1500:])


# ------------------------------------------------- emulated x86_64 libraries -
def x64_libdir():
    return X64LIBS / 'usr/lib64'


def x64_lib_present(name):
    dirs = [x64_libdir()] + [Path(p) for p in os.environ.get('AOE2_X64LIB_DIRS', '').split(':') if p]
    for d in dirs:
        p = d / name
        try:
            if p.exists() and elf_machine(p.resolve()) == 62: return True
        except (OSError, RuntimeError):
            continue
    return False


def x64_lib_files():
    seen, files = set(), []
    for p in x64_libdir().rglob('*.so*') if x64_libdir().is_dir() else ():
        try: real = p.resolve()
        except (OSError, RuntimeError): continue
        if real.is_file() and real not in seen:
            seen.add(real); files.append(real)
    return files


def box64_ld_library_path(runner=None):
    if ROUTE != 'box64': return ''
    parts = [str(x64_libdir())]
    unix = (runner or runner_path()) / 'lib/wine/x86_64-unix'
    if unix.is_dir(): parts.append(str(unix))
    return ':'.join(parts)


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


XML_C = '{http://linux.duke.edu/metadata/common}'
XML_R = '{http://linux.duke.edu/metadata/rpm}'
XML_REPO = '{http://linux.duke.edu/metadata/repo}'


def open_metadata(path):
    suffix = Path(path).suffix
    if suffix == '.gz': return gzip.open(path, 'rb')
    if suffix == '.xz': return lzma.open(path, 'rb')
    if suffix == '.bz2': return bz2.open(path, 'rb')
    if suffix == '.zst':
        if not shutil.which('zstd'): raise RuntimeError('zstd is required: pkg install zstd')
        return sp.Popen(['zstd', '-dc', str(path)], stdout=sp.PIPE).stdout
    return Path(path).open('rb')


def repo_index():
    """{soname: [package, rpm_href, sha256]} from the AlmaLinux 9 BaseOS metadata (cached a week)."""
    cache = CACHE / 'x64-index.json'
    if cache.is_file() and time.time() - cache.stat().st_mtime < 7 * 86400:
        try: return json.loads(cache.read_text())
        except ValueError: pass
    repomd = download(ALMA_BASE + 'repodata/repomd.xml', CACHE / 'repomd.xml')
    root = ET.parse(repomd).getroot()
    primary = next((d for d in root.findall(XML_REPO + 'data') if d.get('type') == 'primary'), None)
    if primary is None: raise RuntimeError('Repository metadata has no primary index.')
    href = primary.find(XML_REPO + 'location').get('href')
    ck = primary.find(XML_REPO + 'checksum')
    digest = ck.text if ck is not None and ck.get('type') == 'sha256' else None
    path = download(ALMA_BASE + href, CACHE / Path(href).name, digest)
    index = {}
    with open_metadata(path) as fh:
        for _, el in ET.iterparse(fh, events=('end',)):
            if el.tag != XML_C + 'package': continue
            name, arch = el.findtext(XML_C + 'name'), el.findtext(XML_C + 'arch')
            if name and arch in ('x86_64', 'noarch') and not name.startswith('glibc'):
                loc = el.find(XML_C + 'location')
                sumel = el.find(XML_C + 'checksum')
                sha = sumel.text if sumel is not None and sumel.get('type') == 'sha256' else ''
                fmt = el.find(XML_C + 'format')
                prov = fmt.find(XML_R + 'provides') if fmt is not None else None
                if loc is not None and prov is not None:
                    for entry in prov.findall(XML_R + 'entry'):
                        m = re.match(r'^(.+\.so[^()]*)\(\)\(64bit\)$', entry.get('name', ''))
                        if m: index[m.group(1)] = [name, loc.get('href'), sha]
            el.clear()
    if not index: raise RuntimeError('Repository metadata yielded no library providers.')
    atomic(cache, json.dumps(index))
    return index


def extract_rpm(rpm, dest):
    Path(dest).mkdir(parents=True, exist_ok=True)
    if shutil.which('bsdtar'):
        run(['bsdtar', '-xf', rpm, '-C', dest], timeout=300)
    elif shutil.which('rpm2cpio') and shutil.which('cpio'):
        run(['bash', '-c', 'cd "$1" && rpm2cpio "$2" | cpio -idm --quiet', 'x', str(dest), str(rpm)], timeout=300)
    else:
        raise RuntimeError('Need bsdtar to unpack RPMs: pkg install libarchive')


def ensure_x64_libs(runner):
    """Provision emulated x86_64 libraries (and their dependency closure) for Box64."""
    required = set(box64_start_libs(runner))
    wanted = required | set(X64_EXTRA_LIBS)
    fetched, unresolved, index = set(), set(), None
    while True:
        missing = sorted(n for n in wanted if n not in unresolved and not x64_lib_present(n))
        if not missing: break
        if index is None:
            say('Missing emulated x86_64 libraries: ' + ', '.join(missing), '33')
            index = repo_index()
        for name in missing:
            info = index.get(name)
            if not info or info[0] in fetched:
                unresolved.add(name); continue
            pkg, href, sha = info
            rpm = download(ALMA_BASE + href, CACHE / 'x64rpms' / Path(href).name, sha or None)
            extract_rpm(rpm, X64LIBS)
            fetched.add(pkg)
        for lib in x64_lib_files():        # new libraries bring their own dependencies
            for dep in elf_needed(lib):
                if dep not in BOX64_WRAPPED: wanted.add(dep)
    broken = sorted(n for n in required if not x64_lib_present(n))
    if broken:
        raise RuntimeError('Box64 cannot start Wine; x86_64 libraries unavailable: ' + ', '.join(broken) +
                           '\nProvide them yourself and set AOE2_X64LIB_DIRS=dir1:dir2, then rerun.')
    soft = sorted(n for n in unresolved if n in X64_EXTRA_LIBS or n in wanted)
    if soft:
        say('Optional x86_64 libraries unavailable (fonts/TLS may be degraded): ' + ', '.join(soft), '33')
    if fetched:
        say(f'x86_64 libraries ready in {x64_libdir()} ({len(fetched)} package(s)).', '32')
    else:
        say('x86_64 libraries already available.', '32')


# ----------------------------------------------------------------- wine -----
def runner_path():
    return DATA / 'runners' / f'wine-{WINE_VERSION}-{WINE_FLAVOR}'


def windows32_dir(prefix):
    return Path(prefix) / 'drive_c/windows/syswow64'


def clean_env():
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('WINE', 'BOX64_', 'BOX86_', 'FEX_')) or key in (
                'LD_LIBRARY_PATH', 'STAGING_WRITECOPY', 'VOOBLY_DLLOVERRIDES'):
            env.pop(key, None)
    return env


def wine_env(prefix, extra=None):
    env = clean_env()
    env.update(WINEPREFIX=str(prefix), WINEARCH=PREFIX_ARCH, WINEDEBUG='-all',
               WINEDLLOVERRIDES='winemenubuilder.exe=d',
               WINE=str(DATA / 'bin' / 'wine'), WINESERVER=str(DATA / 'bin' / 'wineserver'),
               DISPLAY=':0', PULSE_SERVER='tcp:127.0.0.1', TMPDIR=str(TERMUX / 'tmp'))
    env['PATH'] = str(DATA / 'bin') + ':' + env.get('PATH', '')
    if ROUTE == 'box64':
        env['BOX64_PATH'] = str(DATA / 'bin') + ':' + str(runner_path() / 'bin')
        env['BOX64_NOBANNER'] = '1'
        env['BOX64_LD_LIBRARY_PATH'] = box64_ld_library_path()
    if extra: env.update(extra)
    return env


WRAPPER_TEMPLATE = r'''#!@BASH@
set -uo pipefail
RUNNER=@RUNNER_Q@
BIN=@BIN_Q@
BASE="${BIN%/bin}"
ROUTE=@ROUTE_Q@
PREFIX_ARCH=@ARCH_Q@
PREFIX_DEFAULT=@PREFIX_Q@
EMU=( @EMU@ )
EMU_ENV=( @EMU_ENV@ )
NAME="${0##*/}"
case "$NAME" in wine|wineserver) ;; *) exit 2;; esac
unset WINE64 WINELOADER WINEDLLPATH LD_LIBRARY_PATH
unset WINE_DISABLE_FULLSCREEN_HACK STAGING_WRITECOPY
export WINE="$BIN/wine" WINESERVER="$BIN/wineserver"
export WINEPREFIX="${WINEPREFIX:-$PREFIX_DEFAULT}"
export WINEARCH="$PREFIX_ARCH"
export PATH="$BIN:$RUNNER/bin:$PATH"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d}"
export DISPLAY="${DISPLAY:-:0}"
export PULSE_SERVER="${PULSE_SERVER:-tcp:127.0.0.1}"
export TMPDIR="${TMPDIR:-@TMPDIR_Q@}"
if [[ "$ROUTE" == box64 ]]; then
    export BOX64_PATH="$BIN:$RUNNER/bin"
    export BOX64_NOBANNER=1
    export BOX64_LD_LIBRARY_PATH=@X64LD_Q@
    if [[ -r "$BASE/box64.env" ]]; then set -a; . "$BASE/box64.env"; set +a; fi
fi
cmd=("${EMU[@]}" "$RUNNER/bin/$NAME")
# glibc processes must not inherit Termux's bionic LD_PRELOAD (libtermux-exec).
launch() { env -u LD_PRELOAD "${EMU_ENV[@]}" "${cmd[@]}" "$@"; }
if [[ "$NAME" == wine && "${1:-}" == --version ]]; then
    tmp="$(mktemp)" || exit 1
    trap 'rm -f -- "$tmp"' EXIT
    launch "$@" >"$tmp" 2>&1
    rc=$?
    if [[ "$rc" -eq 0 ]] && grep -q '^wine-' "$tmp"; then
        sed -n '/^wine-/p' "$tmp"
    else
        cat "$tmp" >&2
        [[ "$rc" -ne 0 ]] || rc=1
    fi
    exit "$rc"
fi
# No pipe between the emulator and application output.
exec env -u LD_PRELOAD "${EMU_ENV[@]}" "${cmd[@]}" "$@"
'''

BOX64_ENV_TEMPLATE = '''# Optional Box64 tuning, sourced by the wine wrappers. Examples (uncomment to try):
#BOX64_LOG=0
#BOX64_DYNAREC_BIGBLOCK=1
#BOX64_DYNAREC_STRONGMEM=1
#BOX64_MMAP32=1
'''


def install_wrappers(runner, prefix=None):
    if not EMU_CMD: raise RuntimeError('No emulator configured for the wrappers.')
    bin_dir = DATA / 'bin'
    bin_dir.mkdir(parents=True, exist_ok=True)
    env_items = [f'{k}={v}' for k, v in EMU_ENV.items()]
    replacements = {
        '@BASH@': str(BASH), '@RUNNER_Q@': shlex.quote(str(runner)), '@BIN_Q@': shlex.quote(str(bin_dir)),
        '@ROUTE_Q@': shlex.quote(ROUTE), '@ARCH_Q@': shlex.quote(PREFIX_ARCH),
        '@PREFIX_Q@': shlex.quote(str(prefix or DATA / 'prefix')),
        '@EMU@': shlex.join(EMU_CMD), '@EMU_ENV@': shlex.join(env_items),
        '@TMPDIR_Q@': shlex.quote(str(TERMUX / 'tmp')),
        '@X64LD_Q@': shlex.quote(box64_ld_library_path(runner)),
    }
    text = WRAPPER_TEMPLATE
    for key, value in replacements.items(): text = text.replace(key, value)
    for name in ('wine', 'wineserver'):
        atomic(bin_dir / name, text, 0o755)
        run([BASH, '-n', bin_dir / name])
    if not (DATA / 'box64.env').exists():
        atomic(DATA / 'box64.env', BOX64_ENV_TEMPLATE)
    return bin_dir / 'wine', bin_dir / 'wineserver'


def cached_wine_archive():
    candidate = CACHE / WINE_ARCHIVE
    if candidate.is_file() and sha256_file(candidate) == WINE_SHA256:
        return candidate
    return None


def install_runner():
    runner = runner_path()
    if not (runner / '.complete').exists():
        archive = cached_wine_archive() or download(WINE_URL, CACHE / WINE_ARCHIVE, WINE_SHA256)
        runner.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=runner.parent) as t:
            tmp = Path(t)
            say('  Unpacking Wine (this takes a while on a phone)...', '2')
            with tarfile.open(archive) as tar: safe_extract(tar, tmp)
            candidates = list(tmp.glob('*/bin/wine')) or list(tmp.glob('bin/wine'))
            if len(candidates) != 1: raise RuntimeError('Runner must contain exactly one bin/wine.')
            if runner.exists(): raise RuntimeError(f'Incomplete runner exists: {runner}; inspect it first.')
            shutil.move(str(candidates[0].parent.parent), runner)
        atomic(runner / '.complete', json.dumps({'version': WINE_VERSION, 'sha256': WINE_SHA256}))
    for name in ('wine', 'wineserver'):
        target = runner / 'bin' / name
        if not target.is_file() or elf_machine(target.resolve()) != 62:
            raise RuntimeError(f'Wrong ELF architecture or missing runner component: {target}')
    return runner


def check_wine_version(wine, prefix):
    rc, text = run([wine, '--version'], env=wine_env(prefix), timeout=180, check=False)
    match = re.search(r'^wine-\S+.*$', text, re.M)
    version = match.group(0).strip() if match else ''
    say(f'Wine: {version or "(no output)"} | route={ROUTE} | {wine}')
    if rc != 0 or not version:
        detail = text
        if ROUTE == 'box64':
            _, logged = run([wine, '--version'], env=wine_env(prefix, {'BOX64_LOG': '1'}), timeout=180, check=False)
            reasons = [ln for ln in logged.splitlines() if re.search(r'Error loading|Cannot dlopen|needed lib', ln)]
            if reasons: detail += '\nBox64 log:\n' + '\n'.join(dict.fromkeys(reasons))
        hints = {
            'box64': 'Verify box64-glibc is installed. "Error loading needed lib X" means the emulated x86_64 '
                     'library X is missing: rerun the installer, or set AOE2_X64LIB_DIRS to a directory that has it.',
            'fex': 'FEX does not support Wine under Termux (Android seccomp); use --route box64.',
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
        run([wine, 'wineboot', '--init'], env=wine_env(prefix), timeout=900)
        state['prefix_created'] = True; save()
    arch = prefix_arch(prefix)
    if arch != PREFIX_ARCH:
        raise RuntimeError(f'Expected {PREFIX_ARCH} prefix, found {arch!r}; no conversion is attempted.')
    for name in ('cmd.exe', 'ntdll.dll', 'kernel32.dll'):
        target = windows32_dir(prefix) / name
        if not target.is_file() or pe_machine(target) != 0x14c:
            raise RuntimeError(f'Missing or non-i386 Windows component: {target}')
    probe = windows32_dir(prefix) / 'cmd.exe'
    rc, text = run([wine, str(probe), '/d', '/c', 'echo WIN32_APP_OK'], env=wine_env(prefix), timeout=180, check=False)
    if rc or 'WIN32_APP_OK' not in text:
        raise RuntimeError('32-bit Windows execution failed in this prefix.\n' + text[-2000:])
    run([wine, 'reg', 'add', r'HKCU\Software\Wine', '/v', 'Version', '/d', 'win10', '/f'], env=wine_env(prefix))
    # AoE II is a 2D DirectDraw game. The GDI renderer avoids needing any OpenGL stack on Android.
    key = r'HKCU\Software\Wine\Direct3D'
    if RENDERER == 'gdi':
        run([wine, 'reg', 'add', key, '/v', 'renderer', '/d', 'gdi', '/f'], env=wine_env(prefix))
    else:
        run([wine, 'reg', 'delete', key, '/v', 'renderer', '/f'], env=wine_env(prefix), check=False)
    say('32-bit Windows cmd.exe executed successfully.', '32')


# ------------------------------------------------------------ game / drive --
DRIVE_ORDER = 'yxwvutsrqponmlkjihgfed'


def choose_drive(prefix, source):
    """Reuse an existing mapping to the game, else claim the first free letter."""
    dev = Path(prefix) / 'dosdevices'
    if not dev.is_dir():
        raise RuntimeError(f'Missing Wine dosdevices directory: {dev}')
    game = Path(source).resolve()

    def linked(letter):
        link = dev / f'{letter}:'
        return Path(os.path.realpath(link)) if (link.is_symlink() or link.exists()) else None

    for letter in DRIVE_ORDER:
        if linked(letter) == game: return letter
    for letter in DRIVE_ORDER:
        if linked(letter) is None:
            (dev / f'{letter}:').symlink_to(game)
            return letter
    raise RuntimeError('No free Wine drive letter available to expose the game directory.')


def drive_visible(wine, prefix, drive):
    # Quote-free on purpose: Wine's argv quoting and cmd.exe's quote parsing disagree.
    rc, text = run([wine, 'cmd', '/d', '/c', f'if exist {drive}\\ echo AOE_DRIVE_OK'],
                   env=wine_env(prefix), timeout=180, check=False)
    return rc == 0 and 'AOE_DRIVE_OK' in text, text


def map_drive(wine, prefix, source, aoc_rel):
    rel_win = str(aoc_rel).replace('/', '\\')
    server = DATA / 'bin' / 'wineserver'
    try:
        letter = choose_drive(prefix, source)
        drive = letter.upper() + ':'
        for attempt in range(3):
            visible, _ = drive_visible(wine, prefix, drive)
            if visible: return drive, drive + '\\' + rel_win
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
        raise RuntimeError('Game is not accessible from Wine.\n' + text[-1500:])
    return 'Z:', win_path


def backup_game(source):
    source = Path(source)
    target = source.with_name(source.name + f'.backup-{STAMP}')
    needed = sum(p.stat().st_size for p in source.rglob('*') if p.is_file() and not p.is_symlink())
    free = shutil.disk_usage(source.parent).free
    say(f'Game backup: {target}\nSize: {needed // 1048576} MiB | free: {free // 1048576} MiB')
    if free < needed + 512 * 1024 * 1024:
        raise RuntimeError('Not enough space for the game backup; free space or decline it on rerun.')
    shutil.copytree(source, target, symlinks=True)
    return target


def backup_prefix(prefix, label):
    target = DATA / 'backups' / f'{Path(prefix).name}-{label}-{STAMP}'
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(prefix, target, symlinks=True)
    return target


# ---------------------------------------------------------- process control -
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
        raise RuntimeError('Close these running applications and rerun: ' + ', '.join(f'{p} ({c})' for p, c in left))


def reuse_or_replace(prefix, statefile, ident, source):
    """Reuse an existing installation by default, or replace it on request."""
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


# ------------------------------------------------------ winetricks / dplay --
def install_winetricks():
    wt = DATA / 'tools' / 'winetricks'
    if wt.is_file():
        run([BASH, '-n', wt])
        return wt
    commit = api('https://api.github.com/repos/Winetricks/winetricks/commits/master')['sha']
    download(f'https://raw.githubusercontent.com/Winetricks/winetricks/{commit}/src/winetricks', wt)
    run([BASH, '-n', wt])
    wt.chmod(0o755)
    logging.info('Winetricks pinned at commit %s', commit)
    return wt


def directplay_registered(wine, prefix):
    rc, text = run([wine, 'reg', 'query', r'HKCU\Software\Wine\DllOverrides'], env=wine_env(prefix), check=False)
    # Winetricks stores native overrides under a wildcard value name, e.g. "*dplayx".
    return rc == 0 and bool(re.search(r'"?\*?dplayx"?\s+REG_SZ\s+(?:native|n)\b', text, re.I))


def winetricks_cache_dirs():
    return (CACHE / 'xdg' / 'winetricks', CACHE / 'winetricks')


def seed_directplay_redist():
    """Pre-seed winetricks' DirectX cache; its own archive.org snapshot often returns 503/404."""
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
    runner = runner_path()
    # Winetricks inspects $WINE/$WINESERVER to detect arch and WoW64 type; give it the real binaries.
    env = wine_env(prefix, {'WINETRICKS_CACHE': str(CACHE / 'winetricks'), 'XDG_CACHE_HOME': str(CACHE / 'xdg'),
                            'WINE_BIN': str(runner / 'bin' / 'wine'),
                            'WINESERVER_BIN': str(runner / 'bin' / 'wineserver')})
    rc, installed = run([BASH, wt, 'list-installed'], env=env, check=False)
    have = all((directory / n).is_file() and pe_machine(directory / n) == 0x14c for n in DIRECTPLAY_FILES)
    ready = have and rc == 0 and 'directplay' in installed.splitlines() and directplay_registered(wine, prefix)
    if not ready:
        if not yes("Close this prefix's Wine applications and install/repair native DirectPlay?", True):
            raise RuntimeError('DirectPlay setup declined.')
        server = DATA / 'bin/wineserver'
        run([server, '-k'], env=env, timeout=30, check=False)
        run([server, '-w'], env=env, timeout=45, check=False)
        if yes('Back up the prefix before installing DirectPlay? (optional)', False):
            say(f'Prefix backup: {backup_prefix(prefix, "before-directplay")}', '33')
        if not seed_directplay_redist():
            say('  DirectX redist could not be pre-fetched; winetricks will try archive.org itself '
                '(this often 503s).', '33')
        last = ''
        for attempt in range(1, 4):
            rc, text = run([BASH, wt, '-q', 'directplay'], env=env, timeout=3600, check=False)
            if rc == 0: break
            last = text[-1500:]
            if attempt < 3:
                say(f'  winetricks attempt {attempt}/3 failed; retrying in {5 * attempt}s', '33')
                time.sleep(5 * attempt)
        else:
            raise RuntimeError('winetricks directplay failed after 3 attempts. Download\n'
                               f'  {DIRECTX_REDIST_NAME}\n(SHA256 {DIRECTX_REDIST_SHA256}) into\n'
                               f'  {winetricks_cache_dirs()[0] / "directx9"}\n'
                               'and rerun, or retry later when archive.org is reachable.\n' + last)
    missing = [n for n in DIRECTPLAY_FILES if not (directory / n).is_file() or pe_machine(directory / n) != 0x14c]
    if missing or not directplay_registered(wine, prefix):
        raise RuntimeError(f'32-bit DirectPlay verification failed in {directory}; files={missing}')
    for value in ('dpnlobby', '*dpnlobby'):
        run([wine, 'reg', 'delete', r'HKCU\Software\Wine\DllOverrides', '/v', value, '/f'], env=env, check=False)
    state['components'] = True; save()


# ------------------------------------------------------------ launchers -----
LAUNCHER_TEMPLATE = r'''#!@BASH@
set -uo pipefail
umask 077
BASE=@BASE_Q@
RUNNER=@RUNNER_Q@
PREFIX=@PREFIX_Q@
GAME=@GAME_Q@
DRIVE_PREF=@DRIVE_Q@
GAME_REL=@REL_Q@
FIXED_TARGET=@TARGET_Q@
PREFIX_ARCH=@ARCH_Q@
ROUTE=@ROUTE_Q@
TITLE=@TITLE_Q@
RENDERER=@RENDERER_Q@
BIN="$BASE/bin"
LOG="$BASE/logs/@SLUG@-$(date +%Y%m%d-%H%M%S)-$$.log"
[[ -x "$BIN/wine" && -x "$RUNNER/bin/wine" ]] || { echo 'Wine runner/wrapper missing.' >&2; exit 1; }
[[ -f "$PREFIX/system.reg" ]] || { echo 'Prefix missing.' >&2; exit 1; }
grep -q "^#arch=$PREFIX_ARCH\$" "$PREFIX/system.reg" || { echo 'Wrong prefix architecture.' >&2; exit 1; }
for var in ${!WINE@} ${!BOX64_@} ${!BOX86_@} ${!FEX_@}; do
    unset "$var"
done
unset LD_LIBRARY_PATH STAGING_WRITECOPY VOOBLY_DLLOVERRIDES
export WINE="$BIN/wine" WINESERVER="$BIN/wineserver"
export WINEPREFIX="$PREFIX" WINEARCH="$PREFIX_ARCH"
export PATH="$BIN:$RUNNER/bin:$PATH"
export WINEDLLOVERRIDES='winemenubuilder.exe=d'
export WINEDEBUG='-all,err+all'
export AOE2_RENDERER="$RENDERER"
mkdir -p "$BASE/logs"
# shellcheck disable=SC1091
. "$BASE/tools/session.sh"
aoe2_session_start
# Locks are per shared game directory, not per prefix.
LOCKFILE=@LOCK_Q@
mkdir -p "$(dirname "$LOCKFILE")"
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCKFILE"
    flock -n 9 || { echo 'Another managed game/Voobly launcher is using this game directory.' >&2; exit 1; }
fi
HELPER="$BASE/tools/clear-directplay-conflict.sh"
if [[ -x "$HELPER" ]]; then
    "$HELPER" --check || {
        echo "Inspect/close existing games first. For confirmed stale helpers run: $HELPER" >&2
        exit 1
    }
fi
ensure_drive() {
    local letter link
    for letter in "$DRIVE_PREF" y x w v u t s r q p o n m l k j i h g f e d; do
        link="$PREFIX/dosdevices/$letter:"
        if [[ "$(readlink -f "$link" 2>/dev/null)" == "$(readlink -f "$GAME")" ]]; then
            printf '%s:' "${letter^^}"; return
        fi
    done
    for letter in "$DRIVE_PREF" y x w v u t s r q p o n m l k j i h g f e d; do
        link="$PREFIX/dosdevices/$letter:"
        if [[ ! -e "$link" && ! -L "$link" ]]; then
            ln -s -- "$GAME" "$link" || return 1
            printf '%s:' "${letter^^}"; return
        fi
    done
    return 1
}
if [[ -n "$GAME_REL" ]]; then
    TARGET="$GAME/$GAME_REL"
else
    TARGET="$FIXED_TARGET"
    DRIVE="$(ensure_drive || true)"
    if [[ -n "$DRIVE" ]]; then
        printf 'Game mapping: %s -> %s\n' "$DRIVE" "$GAME"
    else
        echo 'No spare drive letter; select the game through Z: in Voobly.' >&2
    fi
fi
[[ -f "$TARGET" ]] || { echo "Missing executable: $TARGET" >&2; exit 1; }
cd "$GAME" || exit 1
printf 'Starting %s via %s without a time limit.\nLog: %s\n' "$TITLE" "$ROUTE" "$LOG"
"$WINE" "$TARGET" @ARGS@ "$@" 9>&- >"$LOG" 2>&1 &
child=$!
wait "$child"
rc=$?
printf '@SLUG@_EXIT=%s\nLog: %s\n' "$rc" "$LOG"
[[ "$rc" -eq 0 ]] || tail -n 80 "$LOG"
exit "$rc"
'''


def make_launcher(slug, title, target, args, runner, prefix, source, drive, rel=''):
    gameid = hashlib.sha256(str(Path(source).resolve()).encode()).hexdigest()[:24]
    values = {
        '@BASE_Q@': DATA, '@RUNNER_Q@': runner, '@PREFIX_Q@': prefix,
        '@GAME_Q@': source, '@DRIVE_Q@': 'y' if drive.upper().startswith('Z') else drive[0].lower(),
        '@REL_Q@': rel, '@TARGET_Q@': target, '@ARCH_Q@': PREFIX_ARCH, '@ROUTE_Q@': ROUTE,
        '@TITLE_Q@': title, '@RENDERER_Q@': RENDERER, '@LOCK_Q@': BASE_DATA / 'locks' / (gameid + '.lock'),
    }
    text = LAUNCHER_TEMPLATE.replace('@BASH@', str(BASH))
    for key, value in values.items(): text = text.replace(key, shlex.quote(str(value)))
    text = text.replace('@SLUG@', slug).replace('@ARGS@', shlex.join(shlex.split(args)))
    path = DATA / 'bin' / slug
    atomic(path, text, 0o755)
    run([BASH, '-n', path])
    return path


def install_shortcuts(created):
    """Commands on PATH plus Termux:Widget entries (~/.shortcuts)."""
    labels = {'play-aok': 'AoE II', 'play-aoe2': 'AoE II Conquerors', 'play-voobly': 'Voobly'}
    SHORTCUTS.mkdir(parents=True, exist_ok=True)
    made = []
    for slug, launcher in created.items():
        body = f'#!{BASH}\nexec {shlex.quote(str(launcher))} "$@"\n'
        atomic(TERMUX / 'bin' / slug, body, 0o755)
        atomic(SHORTCUTS / labels[slug], body, 0o755)
        made.append(slug)
    stop = DATA / 'bin' / 'aoe2-stop'
    atomic(stop, STOP_TEMPLATE.replace('@BASH@', str(BASH)), 0o755)
    atomic(TERMUX / 'bin' / 'aoe2-stop', f'#!{BASH}\nexec {shlex.quote(str(stop))} "$@"\n', 0o755)
    return made


STOP_TEMPLATE = r'''#!@BASH@
# Stop Wine and helper services. Pass --all to also stop Termux:X11 and PulseAudio.
BASE="$(cd "$(dirname "$0")/.." && pwd)"
"$BASE/bin/wineserver" -k 2>/dev/null
pkill -f virgl_test_server_android 2>/dev/null
if [[ "${1:-}" == --all ]]; then
    pulseaudio --kill 2>/dev/null
    pkill -f 'termux.x11' 2>/dev/null
    termux-wake-unlock 2>/dev/null
fi
echo 'Stopped.'
'''

PORT_HELPER = r'''#!@BASH@
set -uo pipefail
MODE="${1:-interactive}"
case "$MODE" in --check|--auto|interactive) ;; *) echo 'Usage: helper [--check]' >&2; exit 2;; esac
DEFAULT_PREFIX=@PREFIX_Q@
PREFIX="${WINEPREFIX:-$DEFAULT_PREFIX}"
HEXPORT="$(printf '%04X' 47624)"
# Android 10+ hides /proc/net from apps; when unreadable this reports "free".
port_busy() {
    awk -v p=":$HEXPORT" 'NR>1 && $4=="0A" && toupper($2) ~ (p "$") {f=1} END {exit !f}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}
prefix_of() { tr '\0' '\n' <"/proc/$1/environ" 2>/dev/null | sed -n 's/^WINEPREFIX=//p'; }
comm_of() { tr '[:upper:]' '[:lower:]' <"/proc/$1/comm" 2>/dev/null; }
helpers() {
    local p pid
    for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        [[ -O "$p" && -r "$p/comm" ]] || continue
        [[ "$(comm_of "$pid")" == dplaysvr.exe ]] || continue
        if [[ "$(prefix_of "$pid")" == "$PREFIX" ]]; then echo "$pid"; fi
    done
}
if [[ "$MODE" != interactive ]]; then
    if port_busy; then
        echo 'Port 47624 is occupied; nothing was stopped. Close active applications, then inspect with:' >&2
        echo "  $0" >&2
        exit 1
    fi
    exit 0
fi
pids="$(helpers)"
[[ -n "$pids" ]] || { echo 'No leftover dplaysvr.exe helper found for this prefix.'; exit 0; }
# Never stop a helper while a recognized game or Voobly client is alive.
for p in /proc/[0-9]*; do
    [[ -O "$p" && -r "$p/comm" ]] || continue
    case "$(comm_of "${p#/proc/}")" in
        empires2.exe|age2_x1.exe|age2.exe|age2x1.exe|voobly.exe)
            state="$(awk '{print $3}' "$p/stat" 2>/dev/null)"
            if [[ "$state" != Z ]]; then
                echo 'Close all games and Voobly clients before terminating helpers.' >&2; exit 1
            fi;;
    esac
done
for pid in $pids; do
    [[ "$(comm_of "$pid")" == dplaysvr.exe ]] || continue
    ps -p "$pid" -o pid,ppid,stat,etime,args 2>/dev/null
    read -r -p "Stop this confirmed leftover helper? [y/N] " answer </dev/tty
    case "$answer" in y|Y|yes|YES) kill -TERM "$pid" 2>/dev/null;; esac
done
echo 'Done. No game files or network configuration were changed.'
'''


# ---------------------------------------------------------------- main ------
def configure():
    global OPTIONS, VERBOSE, ROUTE, RENDERER
    parser = argparse.ArgumentParser(
        description='AoE II / Voobly installer for Android/Termux (native Box64, no proot).')
    parser.add_argument('--route', choices=('box64', 'fex'), default='box64')
    parser.add_argument('--emulator', type=Path, help='Existing glibc AArch64 box64 (or FEX) executable')
    parser.add_argument('--renderer', choices=('gdi', 'gl'), default='gdi',
                        help='gdi (default): software DirectDraw, no GL needed. gl: Mesa/VirGL (experimental)')
    parser.add_argument('--verbose', '-v', action='store_true', help='Show every command and its output')
    OPTIONS = parser.parse_args()
    VERBOSE, ROUTE, RENDERER = OPTIONS.verbose, OPTIONS.route, OPTIONS.renderer


def main():
    configure()
    preflight()
    attach_terminal()
    LOG.parent.mkdir(parents=True, exist_ok=True); CACHE.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=LOG, level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    lock = (BASE_DATA / 'installer.lock').open('w')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise RuntimeError('Another installer is already running.')
    say('\n╔══════════════════════════════════════════════════════════════╗\n'
        '║           AGE OF EMPIRES II  ×  VOOBLY                       ║\n'
        '║           Native on Android: Termux + Box64 + Wine.          ║\n'
        '╚══════════════════════════════════════════════════════════════╝', '1;33')
    if VERBOSE: say('Verbose mode: every command and its output is printed as it runs.', '2')

    stage(1, 'Choose your installation paths')
    if not (HOME / 'storage/shared').is_dir():
        say('Shared storage is not granted. Allow it to use a game folder on /sdcard.', '33')
        run(['termux-setup-storage'], check=False, timeout=120); time.sleep(2)
    games = HOME / 'storage/shared/Games/Age of Empires II'
    default_game = games if games.is_dir() else HOME / 'Games/Age of Empires II'
    source = path_input('Original AoE II game directory', default_game, 'dir')
    found = []
    for folder in (HOME / 'storage/downloads', HOME / 'storage/shared/Download', HOME / 'Downloads'):
        found += sorted(folder.glob('*[Vv]oobly*.exe')) if folder.is_dir() else []
    setup = path_input('Voobly setup executable', found[-1] if found else HOME / 'Downloads/voobly.exe', 'exe')
    prefix = path_input('Dedicated Wine prefix', DATA / 'prefix', 'new')
    if prefix == HOME or prefix == Path('/') or prefix == source or prefix in source.parents or source in prefix.parents:
        raise RuntimeError('Game source and prefix must be separate, non-nested directories, not HOME or /.')
    if on_shared_storage(prefix):
        raise RuntimeError('The Wine prefix must live in Termux private storage (symlinks and permissions '
                           'do not work on /sdcard). Choose a path under ' + str(HOME))
    if on_shared_storage(source):
        say('The game is on shared storage: it works, but loads slower than a copy inside Termux home.', '33')

    # Age of Kings ships as empires2.exe; some repacks rename it to age2.exe.
    aok = find_ci(source, 'age2.exe') or find_ci(source, 'empires2.exe')
    aoc = find_ci(source, 'age2_x1.exe') or find_ci(source, 'age2x1.exe')
    if not aok or not aoc:
        missing = [label for label, hit in (('empires2.exe or age2.exe', aok), ('age2_x1.exe or age2x1.exe', aoc)) if not hit]
        raise RuntimeError('Game source is missing ' + ' and '.join(missing) +
                           '; it needs the original Age of Kings and Conquerors executables with their data files.')
    if pe_machine(aok[0]) != 0x14c or pe_machine(aoc[0]) != 0x14c:
        raise RuntimeError('Expected original i386 PE32 game executables, not HD/DE or non-x86 files.')
    aoc_rel = aoc[0].relative_to(source)

    ident = hashlib.sha256(str(prefix).encode()).hexdigest()[:12]
    statefile = DATA / 'installs' / (ident + '.json')
    state = json.loads(statefile.read_text()) if statefile.exists() else {'id': ident, 'source': str(source)}
    if state['source'] != str(source): raise RuntimeError('This prefix is registered to a different source; select a new prefix.')
    if (prefix.exists() and any(prefix.iterdir()) and not statefile.exists()
            and not str(prefix).startswith(str(DATA) + os.sep)):
        raise RuntimeError('Nonempty unmanaged prefix: refusing to mutate it. Choose a new empty prefix.')
    state.update(route=ROUTE, prefix_architecture=PREFIX_ARCH, renderer=RENDERER)
    say(f'\nHost: android/{platform.machine().lower()} (Termux, native)\nOriginal: {source}\n'
        f'Conquerors: {aoc_rel}\nSetup: {setup}\nPrefix: {prefix}')
    say(f'Route: {ROUTE} | Wine archive: {WINE_ARCHIVE} | prefix: {PREFIX_ARCH} | renderer: {RENDERER}\n'
        f'Workspace: {DATA}\nExisting game is shared read-write; nothing outside this workspace is modified.')
    if not yes('Proceed with this configuration?', True): return

    def save(): atomic(statefile, json.dumps(state, indent=2))

    fresh = reuse_or_replace(prefix, statefile, ident, source)
    if fresh is not None: state = fresh
    if prefix_arch(prefix) not in (None, PREFIX_ARCH):
        raise RuntimeError('Prefix architecture does not match; select a new prefix.')

    stage(2, 'Termux packages, glibc runtime, emulator, display and audio')
    install_termux_packages()
    tools()
    emu = require_emulator()
    global EMU_CMD, EMU_ENV
    EMU_CMD, EMU_ENV = probe_emulator(emu)
    say(f'{ROUTE}: {" ".join(EMU_CMD)}' + (f'  env={EMU_ENV}' if EMU_ENV else ''), '32')
    start_session()
    say('Termux:X11 and PulseAudio are running. Keep the Termux:X11 app open for GUI steps.', '32')

    stage(3, 'Install and verify the prebuilt Wine runner')
    say(f'Runner: Kron4ek {WINE_ARCHIVE} (pinned SHA256)')
    runner = install_runner()
    if ROUTE == 'box64': ensure_x64_libs(runner)
    wine, _ = install_wrappers(runner, prefix)
    version = check_wine_version(wine, prefix)
    state.update(wine=str(wine), runner=str(runner), emulator=' '.join(EMU_CMD), version=version); save()

    stage(4, f'Create a {PREFIX_ARCH} prefix and verify 32-bit Windows execution')
    create_prefix(wine, prefix, state, save)
    say(f'Prefix reports #arch={PREFIX_ARCH} and executed a 32-bit cmd.exe.', '32')

    stage(5, 'Expose the existing game to Wine')
    drive, game_win = map_drive(wine, prefix, source, aoc_rel)
    say(f'{drive} -> {source}\nConquerors executable: {game_win}', '32')
    state['game_drive'] = drive; save()
    have_backup = bool(state.get('game_backup')) and Path(state['game_backup']).is_dir()
    if not have_backup and yes('Back up the original game directory before Voobly can patch it? (optional)', False):
        backup = backup_game(source)
        state['game_backup'] = str(backup); save()

    stage(6, 'Install native DirectPlay')
    install_components(wine, prefix, state, save)

    stage(7, 'Install Voobly and create launchers')
    client_file = DATA / 'tools' / 'voobly-client-path'
    recorded = state.get('voobly')
    if not recorded and client_file.is_file(): recorded = client_file.read_text(errors='replace').strip()
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
        say('The Voobly installer will open in Termux:X11. Switch to that app, accept the license,\n'
            'keep the default destination, and uncheck "Launch Voobly" at the end.')
        if not yes('Start the Voobly installer now?'): raise RuntimeError('Voobly installation declined.')
        rc, text = run([wine, str(setup)], env=wine_env(prefix), cwd=source, timeout=1800, check=False)
        if rc != 0: raise RuntimeError(f'Voobly installer exited {rc}.\n{text[-2500:]}')
        installed_now = True
        clients = find_ci(prefix / 'drive_c', 'voobly.exe')
        if not clients:
            raise RuntimeError('Voobly executable not found; the installer may have been cancelled '
                               'or used a destination outside drive_c.')
        voobly = clients[0]
    else:
        say(f'Voobly already installed: {voobly}', '32')
    if pe_machine(voobly) not in (0x14c, 0x8664): raise RuntimeError('Installed Voobly is not a valid x86/x64 executable.')
    atomic(client_file, str(voobly) + '\n')
    state['voobly'] = str(voobly); save()
    if installed_now: run([wine, 'wineboot', '-u'], env=wine_env(prefix), timeout=600, check=False)
    drive, game_win = map_drive(wine, prefix, source, aoc_rel)
    state['game_drive'] = drive; save()

    aok_rel = str(aok[0].relative_to(source)).replace(os.sep, '/')
    aoc_rel_posix = str(aoc_rel).replace(os.sep, '/')
    launchers = {
        'aok': ('play-aok', 'Age of Empires II', aok_rel, ''),
        'aoc': ('play-aoe2', 'Age of Empires II: The Conquerors', aoc_rel_posix, '-nostartup'),
    }
    created = {}
    for key, (script, title, rel, args) in launchers.items():
        created[script] = make_launcher(script, title, '', args, runner, prefix, source, drive, rel)
    created['play-voobly'] = make_launcher('play-voobly', 'Voobly', str(voobly), '', runner, prefix, source, drive)
    helper = DATA / 'tools' / 'clear-directplay-conflict.sh'
    atomic(helper, PORT_HELPER.replace('@BASH@', str(BASH)).replace('@PREFIX_Q@', shlex.quote(str(prefix))), 0o755)
    run([BASH, '-n', helper])
    shortcut_names = install_shortcuts(created)
    say('Commands: ' + ', '.join(shortcut_names) + ', aoe2-stop | Termux:Widget entries in ~/.shortcuts', '32')

    stage(8, 'Final checks')
    say('Each application can be opened for a real smoke test; close it normally afterwards.\n'
        'Switch to the Termux:X11 app to see it. These tests do not time-kill Wine or DirectPlay helpers.')
    checks = {}
    for script, title in (('play-aok', 'Age of Empires II'), ('play-aoe2', 'Age of Empires II: The Conquerors'),
                          ('play-voobly', 'Voobly')):
        checks[script] = 'NOT TESTED'
        if yes('Open ' + title + ' for visual verification?', True):
            try:
                run([created[script]], timeout=0, check=False)
                checks[script] = 'USER CONFIRMED' if yes(f'Did {title} reach a usable screen?') else 'NOT CONFIRMED'
            except Exception as e:
                checks[script] = 'FAILED'; logging.exception('Smoke test %s', script); say(str(e), '31')
    run([helper, '--check'], env=wine_env(prefix), check=False)

    z_path = 'Z:' + str(source).replace('/', '\\')
    summary = {
        'host': f'android/{platform.machine().lower()} (Termux native, no proot)',
        'wine_version': version, 'wine_binary': str(runner / 'bin/wine'), 'wine_wrapper': str(wine),
        'execution': f'{ROUTE} ({" ".join(EMU_CMD)})', 'wine_archive_sha256': WINE_SHA256,
        'x86_64_libraries': str(x64_libdir()), 'renderer': RENDERER,
        'prefix': str(prefix), 'prefix_architecture': prefix_arch(prefix),
        'original_game': str(source), 'game_drive': f'{drive} (original directory, not a copy)',
        'conquerors_executable': game_win, 'voobly_z_path': z_path, 'voobly': str(voobly),
        'launchers': {k: str(v) for k, v in created.items()}, 'components': 'native DirectPlay',
        'application_checks': checks, 'multiplayer_match': 'NOT AUTOMATICALLY VERIFIED', 'log': str(LOG),
    }
    state['summary'] = summary; save()
    report = DATA / 'logs' / (STAMP + '-summary.json'); atomic(report, json.dumps(summary, indent=2))

    complete = all(v == 'USER CONFIRMED' for v in checks.values())
    title = 'INSTALLATION COMPLETE — application screens confirmed' if complete \
        else 'INSTALLATION PREPARED — visual checks incomplete'
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
        '• Launch with  play-voobly  (or a Termux:Widget shortcut). Keep the Termux:X11 app in front.\n'
        '• In Voobly run Game Diagnostics, set Installation directory ' + drive + '\\ and Executable ' + game_win + '.\n'
        '• If Voobly does not list that drive, use Z: instead: ' + z_path + '\n'
        '• Validate v1.5 RC first; then test the matched v1.6 RC + v1.6 Game Data pair separately.\n'
        '• If multiplayer drops back to the connection screen, a stale DirectPlay helper may hold port 47624;\n'
        '  run ' + str(helper) + ' to inspect and explicitly stop a confirmed leftover helper.\n'
        '• Tune Box64 in ' + str(DATA / 'box64.env') + '. Stop everything with  aoe2-stop  (or  aoe2-stop --all).\n'
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