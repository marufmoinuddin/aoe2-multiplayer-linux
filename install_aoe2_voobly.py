#!/usr/bin/env python3
"""AoE II Classic + Voobly installer: native x86, ARM64 FEX, or ARM64 Box64.

Prebuilt only. ARM64 users select FEX + Wine 10.0 x86/win32 or
Box64 + Wine 10.0 amd64-wow64/win64. Each route has separate state,
runners, prefixes, wrappers and logs below XDG_DATA_HOME/aoe2-voobly/routes.
No existing environment is migrated. Existing game files are shared read-write.

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
BASE_DATA = DATA_HOME / 'aoe2-voobly'
DATA = BASE_DATA
BASE_CACHE = Path(os.environ.get('XDG_CACHE_HOME', HOME / '.cache')).expanduser().absolute() / 'aoe2-voobly'
CACHE = BASE_CACHE
APPS = DATA_HOME / 'applications'
ICONS = DATA_HOME / 'icons/hicolor/256x256/apps'
COLOR = sys.stdout.isatty() and not os.environ.get('NO_COLOR')
STAMP = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
LOG = DATA / 'logs' / (STAMP + '.log')

WINE_VERSION = '10.0'
WINE_ARCHIVE = f'wine-{WINE_VERSION}-x86.tar.xz'
WINE_SHA256 = 'c5be273749f5c513b3edf7ad79d8214be558b80c67c6ca343d2f17fdcc30c2d2'
WINE_URL = f'https://github.com/Kron4ek/Wine-Builds/releases/download/{WINE_VERSION}/{WINE_ARCHIVE}'
TOTAL_STAGES = 8
ROUTE = 'native'
PREFIX_ARCH = 'win32'
EMULATOR = None
OPTIONS = None
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
        with Path(path).open('rb') as f:
            b = f.read(20)
        if len(b) < 20 or b[:4] != b'\x7fELF': return None
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
    global DATA, CACHE, LOG, ROUTE, PREFIX_ARCH, OPTIONS
    global WINE_ARCHIVE, WINE_SHA256, WINE_URL
    parser = argparse.ArgumentParser(description='AoE II / Voobly: isolated native, FEX, or Box64 Wine routes. Prebuilt binaries only.')
    parser.add_argument('--route', choices=('fex', 'box64', 'native'))
    parser.add_argument('--emulator', type=Path, help='Existing native ARM64 FEX or Box64 executable')
    OPTIONS = parser.parse_args()
    machine = platform.machine().lower()
    arm = machine in ('aarch64', 'arm64')
    if machine not in ('aarch64', 'arm64', 'x86_64', 'amd64', 'i386', 'i486', 'i586', 'i686', 'x86'):
        raise RuntimeError(f'Unsupported architecture: {machine}')
    if arm:
        route = OPTIONS.route
        if route == 'native': raise RuntimeError('Native x86 Wine is not an ARM64 route.')
        if not route:
            say('ARM64 execution route:\n  1. FEX + Wine 10.0 x86 / win32 prefix\n'
                '  2. Box64 + Wine 10.0 amd64-wow64 / win64 prefix\n'
                'Routes use separate runners, prefixes, wrappers, logs, and state.')
            choice = ask('Select 1/FEX or 2/Box64', '1').lower()
            if choice not in ('1', '2', 'fex', 'box64'):
                raise RuntimeError('Invalid route selection.')
            route = 'box64' if choice in ('2', 'box64') else 'fex'
    else:
        route = OPTIONS.route or 'native'
        if route != 'native' or OPTIONS.emulator:
            raise RuntimeError('FEX/Box64 routes require an ARM64 host; use native on x86.')
    ROUTE = route
    PREFIX_ARCH = 'win64' if route == 'box64' else 'win32'
    label = route + ('-wow64' if route == 'box64' else '-win32')
    DATA = BASE_DATA / 'routes' / label
    CACHE = BASE_CACHE / label
    LOG = DATA / 'logs' / (STAMP + '.log')
    flavor = 'amd64-wow64' if route == 'box64' else 'x86'
    WINE_ARCHIVE = f'wine-{WINE_VERSION}-{flavor}.tar.xz'
    WINE_SHA256 = ('aeebbbf239e548f0136f1cd72a2e109dd9a572a8f703da3c09fa40d74d5c255f'
                   if route == 'box64' else
                   'c5be273749f5c513b3edf7ad79d8214be558b80c67c6ca343d2f17fdcc30c2d2')
    WINE_URL = f'https://github.com/Kron4ek/Wine-Builds/releases/download/{WINE_VERSION}/{WINE_ARCHIVE}'


def require_emulator():
    if ROUTE == 'native': return None
    name = 'FEX' if ROUTE == 'fex' else 'box64'
    supplied = OPTIONS.emulator
    found = supplied if supplied else shutil.which(name)
    if not found:
        install_packages(['fex-emu' if ROUTE == 'fex' else 'box64'], f'{name} is required for the selected route.')
        found = shutil.which(name)
    if not found or not Path(found).is_file() or not os.access(found, os.X_OK):
        raise RuntimeError(f'{name} executable missing. Install a prebuilt package or use --emulator /absolute/path.')
    resolved = Path(found).resolve()
    if elf_machine(resolved) != 183:
        raise RuntimeError(f'Expected a native AArch64 ELF emulator, not a script/foreign binary: {resolved}')
    if ROUTE == 'fex':
        say('FEX RootFS must already be configured. Its location is not assumed.\n'
            'The actual Wine execution probe will verify that configuration.\n'
            'If needed, use your distribution FEX RootFS package or upstream FEXRootFSFetcher.', '33')
    return resolved


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
    if extra: env.update(extra)
    return env


WRAPPER_TEMPLATE = '#!/usr/bin/env bash\nset -uo pipefail\nRUNNER=@RUNNER_Q@\nBIN=@BIN_Q@\nROUTE=@ROUTE_Q@\nEMULATOR=@EMU_Q@\nPREFIX_ARCH=@ARCH_Q@\nPREFIX_DEFAULT=@PREFIX_Q@\nNAME="${0##*/}"\ncase "$NAME" in wine|wineserver) ;; *) exit 2;; esac\nunset WINE64 WINELOADER WINEDLLPATH LD_PRELOAD LD_LIBRARY_PATH\nunset WINE_DISABLE_FULLSCREEN_HACK STAGING_WRITECOPY\nexport WINE="$BIN/wine" WINESERVER="$BIN/wineserver"\nexport WINEPREFIX="${WINEPREFIX:-$PREFIX_DEFAULT}"\nexport WINEARCH="$PREFIX_ARCH"\nexport PATH="$BIN:$RUNNER/bin:$PATH"\nexport WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d}"\nif [[ "$ROUTE" == box64 ]]; then\n    export BOX64_PATH="$BIN:$RUNNER/bin"\n    export BOX64_NOBANNER=1\nfi\ncmd=("$RUNNER/bin/$NAME")\n[[ "$ROUTE" == native ]] || cmd=("$EMULATOR" "${cmd[@]}")\nif [[ "$NAME" == wine && "${1:-}" == --version ]]; then\n    tmp="$(mktemp)" || exit 1\n    trap \'rm -f -- "$tmp"\' EXIT\n    "${cmd[@]}" "$@" >"$tmp" 2>&1\n    rc=$?\n    if [[ "$rc" -eq 0 ]] && grep -q \'^wine-\' "$tmp"; then\n        sed -n \'/^wine-/p\' "$tmp"\n    else\n        cat "$tmp" >&2\n        [[ "$rc" -ne 0 ]] || rc=1\n    fi\n    exit "$rc"\nfi\n# No pipe between the emulator and application output.\nexec "${cmd[@]}" "$@"\n'


def install_wrappers(runner, fex, prefix=None):
    bin_dir = DATA / 'bin'
    bin_dir.mkdir(parents=True, exist_ok=True)
    replacements = {
        '@RUNNER_Q@': shlex.quote(str(runner)), '@BIN_Q@': shlex.quote(str(bin_dir)),
        '@ROUTE_Q@': shlex.quote(ROUTE), '@EMU_Q@': shlex.quote(str(fex or '')),
        '@ARCH_Q@': shlex.quote(PREFIX_ARCH), '@PREFIX_Q@': shlex.quote(str(prefix or DATA / 'prefix')),
    }
    text = WRAPPER_TEMPLATE
    for key, value in replacements.items(): text = text.replace(key, value)
    for name in ('wine', 'wineserver'):
        atomic(bin_dir / name, text, 0o755)
        run(['bash', '-n', bin_dir / name])
    return bin_dir / 'wine', bin_dir / 'wineserver'


def install_runner():
    flavor = 'amd64-wow64' if ROUTE == 'box64' else 'x86'
    runner = DATA / 'runners' / f'wine-{WINE_VERSION}-{flavor}'
    wine = runner / 'bin/wine'
    if not (runner / '.complete').exists():
        archive = download(WINE_URL, CACHE / WINE_ARCHIVE, WINE_SHA256)
        runner.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=runner.parent) as t:
            tmp = Path(t)
            with tarfile.open(archive) as tar: safe_extract(tar, tmp)
            candidates = list(tmp.glob('*/bin/wine')) or list(tmp.glob('bin/wine'))
            if len(candidates) != 1: raise RuntimeError('Runner must contain exactly one bin/wine.')
            if runner.exists(): raise RuntimeError(f'Incomplete runner exists: {runner}; inspect it first.')
            shutil.move(str(candidates[0].parent.parent), runner)
        atomic(runner / '.complete', json.dumps({'version': WINE_VERSION, 'sha256': WINE_SHA256}))
    expected = 62 if ROUTE == 'box64' else 3
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
        hints = {
            'fex': 'Verify configured FEX RootFS and that the selected FEX can execute x86 Linux binaries.',
            'box64': 'Verify the native ARM64 Box64 package and its native library dependencies. '
                     'Do not use the x86 Wine runner or reuse the FEX prefix.',
            'native': 'Install your distro prebuilt 32-bit Linux runtime support (including graphics/audio).',
        }
        raise RuntimeError(hints[ROUTE] + '\n' + text[-2500:])
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


def map_drive(wine, prefix, source, aoc_rel):
    rel_win = str(aoc_rel).replace('/', '\\')
    try:
        letter = choose_drive(prefix, source)
        drive = letter.upper() + ':'
        win_path = drive + '\\' + rel_win
        rc, text = run([wine, 'cmd', '/d', '/c', f'if exist "{win_path}" echo AOE_DRIVE_OK'],
                       env=wine_env(prefix), timeout=120, check=False)
        if rc == 0 and 'AOE_DRIVE_OK' in text:
            return drive, win_path
        say('Drive mapping is on disk but not visible to the running Wine server. Using Z: for diagnostics.', '33')
    except RuntimeError as exc:
        say(str(exc), '33')
    win_path = ('Z:' + str(Path(source).resolve())).replace('/', '\\') + '\\' + rel_win
    rc, text = run([wine, 'cmd', '/d', '/c', f'if exist "{win_path}" echo AOE_DRIVE_OK'],
                   env=wine_env(prefix), timeout=120, check=False)
    if rc or 'AOE_DRIVE_OK' not in text:
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
    commit = api('https://api.github.com/repos/Winetricks/winetricks/commits/master')['sha']
    download(f'https://raw.githubusercontent.com/Winetricks/winetricks/{commit}/src/winetricks', wt)
    run(['bash', '-n', str(wt)])
    wt.chmod(0o755)
    logging.info('Winetricks pinned at commit %s', commit)
    return wt


def directplay_registered(wine, prefix):
    rc, text = run([wine, 'reg', 'query', r'HKCU\Software\Wine\DllOverrides', '/v', 'dplayx'],
                   env=wine_env(prefix), check=False)
    return rc == 0 and bool(re.search(r'REG_SZ\s+(?:native|n)(?:\s|,|$)', text, re.I))


def install_components(wine, prefix, state, save):
    directory = windows32_dir(prefix)
    wt = install_winetricks()
    env = wine_env(prefix, {'WINETRICKS_CACHE': str(CACHE / 'winetricks'),
                            'XDG_CACHE_HOME': str(CACHE / 'xdg')})
    rc, installed = run([wt, 'list-installed'], env=env, check=False)
    have = all((directory / n).is_file() and pe_machine(directory / n) == 0x14c for n in DIRECTPLAY_FILES)
    ready = have and rc == 0 and 'directplay' in installed.splitlines() and directplay_registered(wine, prefix)
    if not ready:
        if not yes("Close this route's Wine applications and install/repair native DirectPlay?", True):
            raise RuntimeError('DirectPlay setup declined.')
        server = DATA / 'bin/wineserver'
        run([server, '-k'], env=env, timeout=30, check=False)
        run([server, '-w'], env=env, timeout=45)
        backup = backup_prefix(prefix, 'before-directplay')
        say(f'Prefix backup: {backup}')
        run([wt, '-q', 'directplay'], env=env, timeout=1200)
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


LAUNCHER_TEMPLATE = '#!/usr/bin/env bash\nset -uo pipefail\numask 077\nBASE=@BASE_Q@\nRUNNER=@RUNNER_Q@\nPREFIX=@PREFIX_Q@\nGAME=@GAME_Q@\nDRIVE_PREF=@DRIVE_Q@\nGAME_REL=@REL_Q@\nMARKER=@MARKER_Q@\nFIXED_TARGET=@TARGET_Q@\nPREFIX_ARCH=@ARCH_Q@\nROUTE=@ROUTE_Q@\nTITLE=@TITLE_Q@\nBIN="$BASE/bin"\nLOG="$BASE/logs/@SLUG@-$(date +%Y%m%d-%H%M%S)-$$.log"\n[[ -x "$BIN/wine" && -x "$RUNNER/bin/wine" ]] || { echo \'Wine runner/wrapper missing.\' >&2; exit 1; }\n[[ -f "$PREFIX/system.reg" ]] || { echo \'Prefix missing.\' >&2; exit 1; }\ngrep -q "^#arch=$PREFIX_ARCH\\$" "$PREFIX/system.reg" || { echo \'Wrong prefix architecture.\' >&2; exit 1; }\nfor var in ${!WINE@} ${!BOX64_@} ${!BOX86_@} ${!FEX_@}; do\n    unset "$var"\ndone\nunset LD_PRELOAD LD_LIBRARY_PATH STAGING_WRITECOPY VOOBLY_DLLOVERRIDES\nexport WINE="$BIN/wine" WINESERVER="$BIN/wineserver"\nexport WINEPREFIX="$PREFIX" WINEARCH="$PREFIX_ARCH"\nexport PATH="$BIN:$RUNNER/bin:$PATH"\nexport WINEDLLOVERRIDES=\'winemenubuilder.exe=d\'\nexport WINEDEBUG=\'-all,err+all\'\nmkdir -p "$BASE/logs"\n# Locks are per shared game directory, not per emulator/prefix.\nLOCKFILE=@LOCK_Q@\nmkdir -p "$(dirname "$LOCKFILE")"\nexec 9>"$LOCKFILE"\nflock -n 9 || { echo \'Another managed game/Voobly launcher is using this game directory.\' >&2; exit 1; }\nHELPER="$BASE/tools/clear-directplay-conflict.sh"\nif [[ -x "$HELPER" ]]; then\n    "$HELPER" --check || {\n        echo "Inspect/close existing games first. For confirmed stale helpers run: $HELPER" >&2\n        exit 1\n    }\nfi\nensure_drive() {\n    local letter link\n    for letter in "$DRIVE_PREF" y x w v u t s r q p o n m l k j i h g f e d; do\n        link="$PREFIX/dosdevices/$letter:"\n        if [[ "$(readlink -f "$link" 2>/dev/null)" == "$(readlink -f "$GAME")" ]]; then\n            printf \'%s:\' "${letter^^}"; return\n        fi\n    done\n    for letter in "$DRIVE_PREF" y x w v u t s r q p o n m l k j i h g f e d; do\n        link="$PREFIX/dosdevices/$letter:"\n        if [[ ! -e "$link" && ! -L "$link" ]]; then\n            ln -s -- "$GAME" "$link" || return 1\n            printf \'%s:\' "${letter^^}"; return\n        fi\n    done\n    return 1\n}\nif [[ -n "$GAME_REL" ]]; then\n    TARGET="$GAME/$GAME_REL"\nelse\n    TARGET="$FIXED_TARGET"\n    DRIVE="$(ensure_drive || true)"\n    if [[ -n "$DRIVE" ]]; then\n        printf \'Game mapping: %s -> %s\\n\' "$DRIVE" "$GAME"\n    else\n        echo \'No spare drive letter; select the game through Z: in Voobly.\' >&2\n    fi\nfi\n[[ -f "$TARGET" ]] || { echo "Missing executable: $TARGET" >&2; exit 1; }\ncd "$GAME" || exit 1\nprintf \'Starting %s via %s without a time limit.\\nLog: %s\\n\' "$TITLE" "$ROUTE" "$LOG"\n"$WINE" "$TARGET" @ARGS@ "$@" 9>&- >"$LOG" 2>&1 &\nchild=$!\n# Sample process mappings to flag accidental fallback to the other emulator.\nsleep 1\nif ! python3 "$BASE/tools/audit-route.py" "$PREFIX" "$ROUTE" >>"$LOG" 2>&1; then\n    echo "Wrong emulator detected. Close the application; inspect $LOG" >&2\nfi\nwait "$child"\nrc=$?\nprintf \'@SLUG@_EXIT=%s\\nLog: %s\\n\' "$rc" "$LOG"\n[[ "$rc" -eq 0 ]] || tail -n 80 "$LOG"\nexit "$rc"\n'


def make_launcher(slug, title, target, args, runner, prefix, source, drive, fex, rel='', marker=''):
    gameid = hashlib.sha256(str(Path(source).resolve()).encode()).hexdigest()[:24]
    values = {
        '@BASE_Q@': DATA, '@RUNNER_Q@': runner, '@PREFIX_Q@': prefix,
        '@GAME_Q@': source, '@DRIVE_Q@': 'y' if drive.upper().startswith('Z') else drive[0].lower(),
        '@REL_Q@': rel, '@MARKER_Q@': marker, '@TARGET_Q@': target,
        '@ARCH_Q@': PREFIX_ARCH, '@ROUTE_Q@': ROUTE, '@TITLE_Q@': title,
        '@LOCK_Q@': BASE_DATA / 'locks' / (gameid + '.lock'),
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


PORT_HELPER = '#!/usr/bin/env bash\nset -euo pipefail\nMODE="${1:-interactive}"\ncase "$MODE" in --check|--auto|interactive) ;; *) echo \'Usage: helper [--check]\' >&2; exit 2;; esac\nDEFAULT_PREFIX=@PREFIX_Q@\nPREFIX="${WINEPREFIX:-$DEFAULT_PREFIX}"\ncommand -v ss >/dev/null || { echo \'ss is required (iproute2/iproute).\' >&2; exit 1; }\nsockets() { ss -H -lntup \'sport = :47624\'; }\ncurrent="$(sockets)"\n[[ -n "$current" ]] || exit 0\nprintf \'Port 47624 is occupied; an owner is not automatically stale:\\n%s\\n\' "$current"\nif [[ "$MODE" != interactive ]]; then\n    echo \'No process was stopped. Close active applications and inspect the helper manually.\' >&2\n    exit 1\nfi\nprefix_of() { tr \'\\0\' \'\\n\' <"/proc/$1/environ" 2>/dev/null | sed -n \'s/^WINEPREFIX=//p\'; }\nstart_of() { sed \'s/^.*) //\' "/proc/$1/stat" | awk \'{print $20}\'; }\nvalid() {\n    local pid="$1"\n    [[ -O "/proc/$pid" && -r "/proc/$pid/comm" ]] || return 1\n    [[ "$(tr \'[:upper:]\' \'[:lower:]\' <"/proc/$pid/comm")" == dplaysvr.exe ]] || return 1\n    [[ "$(prefix_of "$pid")" == "$PREFIX" ]] || return 1\n}\n# Never terminate a helper while a recognized live game or Voobly client exists, in any prefix.\nfor p in /proc/[0-9]*; do\n    [[ -O "$p" && -r "$p/comm" ]] || continue\n    name="$(tr \'[:upper:]\' \'[:lower:]\' <"$p/comm" 2>/dev/null || true)"\n    case "$name" in\n        empires2.exe|age2_x1.exe|age2.exe|age2x1.exe|voobly.exe)\n            state="$(awk \'{print $3}\' "$p/stat" 2>/dev/null || true)"\n            if [[ "$state" != Z ]]; then\n                echo \'Close all games and Voobly clients before terminating helpers.\' >&2; exit 1\n            fi;;\n    esac\ndone\nfor pid in $(printf \'%s\\n\' "$current" | grep -o \'pid=[0-9]*\' | cut -d= -f2 | sort -u); do\n    valid "$pid" || continue\n    start="$(start_of "$pid")"\n    ps -p "$pid" -o pid,ppid,user,stat,etime,args\n    read -r -p "Stop this confirmed leftover helper in $PREFIX? [y/N] " answer </dev/tty\n    case "$answer" in y|Y|yes|YES) ;; *) continue;; esac\n    valid "$pid" && [[ "$(start_of "$pid")" == "$start" ]] || continue\n    kill -TERM "$pid" 2>/dev/null || true\n    for _ in {1..10}; do\n        [[ -d "/proc/$pid" ]] || break\n        sleep 1\n    done\n    if valid "$pid" && [[ "$(start_of "$pid")" == "$start" ]]; then\n        state="$(awk \'{print $3}\' "/proc/$pid/stat" 2>/dev/null || true)"\n        if [[ "$state" != Z ]]; then\n            read -r -p "Same helper remains. Force-stop PID $pid? [y/N] " answer </dev/tty\n            case "$answer" in\n                y|Y|yes|YES)\n                    valid "$pid" && [[ "$(start_of "$pid")" == "$start" ]] && kill -KILL "$pid" || true;;\n            esac\n        fi\n    fi\ndone\nsleep 1\nleft="$(sockets)"\n[[ -z "$left" ]] || { printf \'Port remains occupied:\\n%s\\n\' "$left"; exit 1; }\necho \'Port 47624 is free. No game files or network configuration were changed.\'\n'


def main():
    if sys.version_info < (3, 9): raise RuntimeError('Python 3.9 or newer is required; install a prebuilt distro Python.')
    if sys.platform != 'linux': raise RuntimeError('This utility supports Linux only.')
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

    ident = ROUTE + '-' + hashlib.sha256(str(prefix).encode()).hexdigest()[:12]
    statefile = DATA / 'installs' / (ident + '.json')
    state = json.loads(statefile.read_text()) if statefile.exists() else {'id': ident, 'source': str(source)}
    if state['source'] != str(source): raise RuntimeError('This prefix is registered to a different source; select a new prefix.')
    if prefix.exists() and any(prefix.iterdir()) and not statefile.exists():
        raise RuntimeError('Nonempty unmanaged prefix: refusing to mutate it. Choose a new empty prefix.')

    if state.get('route', ROUTE) != ROUTE:
        raise RuntimeError('Prefix belongs to another execution route.')
    if prefix_arch(prefix) not in (None, PREFIX_ARCH):
        raise RuntimeError('Prefix architecture does not match this route; select a new prefix.')
    state.update(route=ROUTE, prefix_architecture=PREFIX_ARCH)
    say(f'\nHost: {machine}\nOriginal: {source}\nConquerors: {aoc_rel}\nSetup: {setup}\nPrefix: {prefix}')
    say(f'Route: {ROUTE} | Wine archive: {WINE_ARCHIVE} | prefix: {PREFIX_ARCH}\n'
        f'Workspace: {DATA}\nExisting game is shared read-write; other routes are not modified.')
    if not yes('Proceed with this configuration?', True): return
    def save(): atomic(statefile, json.dumps(state, indent=2))

    stage(2, 'Distribution, prebuilt emulator and helper preflight')
    fex = None
    if arch == 'arm64':
        fex = require_emulator()
        say(f'{ROUTE}: {fex} (explicit native ARM64 emulator)', '32')
    else:
        say('Native x86 CPU: no emulator is used.', '32')
    tools()

    stage(3, 'Install and verify the route-specific prebuilt Wine runner')
    say(f'Runner: Kron4ek {WINE_ARCHIVE} (pinned SHA256)')
    runner = install_runner()
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
    atomic(helper, PORT_HELPER.replace('@PREFIX_Q@', shlex.quote(str(prefix))), 0o755)

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
    say('\n' + ('INSTALLATION COMPLETE — application screens confirmed' if complete
                else 'INSTALLATION PREPARED — visual checks incomplete'), '1;32' if complete else '1;33')
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
