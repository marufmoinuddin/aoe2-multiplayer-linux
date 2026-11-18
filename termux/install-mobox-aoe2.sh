#!/data/data/com.termux/files/usr/bin/bash
# AoE II / Voobly integration using upstream olegos2/mobox, not a custom Wine stack.
set -euo pipefail
[[ -t 0 ]] || exec </dev/tty
: "${PREFIX:?Run inside Termux}"
[[ $(id -u) != 0 && $(uname -m) == aarch64 ]] || { echo 'Requires non-root arm64 Termux.' >&2; exit 1; }
unset LD_LIBRARY_PATH LD_PRELOAD WINEPREFIX WINEARCH WINEDLLOVERRIDES
BASE="$HOME/.aoe2-mobox"
mkdir -p "$BASE"
exec 9>"$BASE/install.lock"
flock -n 9 || { echo 'Another Mobox AoE installer is running.' >&2; exit 1; }
pkg install -y curl python
if [[ ! -f "$PREFIX/glibc/opt/scripts/start-tfm" ]]; then
    if [[ -e "$PREFIX/glibc" ]]; then
        echo 'Mobox replaces the shared glibc runtime. Close ALL Wine/glibc applications first.'
        echo 'The old AoE prefix is NOT migrated or deleted. Other glibc applications may require rollback.'
        read -r -p 'Type BACKUP to move existing glibc aside and install Mobox: ' answer
        [[ $answer == BACKUP ]] || exit 1
        backup="$PREFIX/glibc.before-mobox-$(date +%Y%m%d-%H%M%S)-$$"
        mv -- "$PREFIX/glibc" "$backup"
        printf 'Previous runtime preserved at: %s\n' "$backup" | tee "$BASE/runtime-backup.txt"
    fi
    curl -fL --retry 3 'https://raw.githubusercontent.com/olegos2/mobox/24e5611620efbb133e42d4b26191bf2ef7b21768/install' -o "$BASE/mobox-install"
    bash -n "$BASE/mobox-install"
    echo 'In the upstream installer select option 2 (Mobox WoW64). Install/open the Termux:X11 companion APK too.'
    # Upstream uses return at top level; sourcing inside a child shell preserves its intended exit behavior.
    bash -c '. "$1"' _ "$BASE/mobox-install" 9>&-
fi
[[ -f "$PREFIX/glibc/opt/scripts/start-tfm" && -x "$PREFIX/glibc/wine-9.3-vanilla-wow64/bin/wine" ]] || {
    echo 'Mobox WoW64 installation incomplete. Run mobox and install/select wine-9.3-vanilla-wow64, then rerun.' >&2; exit 1;
}
echo 'Starting the real Mobox desktop to initialize its own prefix and bundled DirectX.'
echo 'Wait until the desktop is ready. Keep it open, return to Termux, then press Enter.'
bash "$PREFIX/glibc/opt/scripts/start-tfm" >"$BASE/mobox-first-start.log" 2>&1 9>&- &
read -r -p 'Desktop ready? Press Enter to continue: ' _
[[ -f "$PREFIX/glibc/opt/conf/wine_path.conf" ]] || { echo 'Mobox configuration not initialized. See first-start log.' >&2; exit 1; }
# Use Mobox configuration, never the old installer prefix.
. "$PREFIX/glibc/opt/conf/wine_path.conf"
[[ -f "$WINEPREFIX/system.reg" && -f "$WINEPREFIX/moboxmeta/dxdlls-fix-applied" ]] || {
    echo 'Mobox prefix/DirectX setup has not finished. Finish Mobox startup and rerun.' >&2; exit 1;
}
read -r -p 'Existing licensed AoE II game directory (absolute path): ' game
read -r -p 'Voobly setup .exe (absolute path): ' setup
[[ -d "$game" && -f "$setup" && "$game" == /* && "$setup" == /* ]] || { echo 'Invalid game/setup path.' >&2; exit 1; }
export AOE2_MOBOX_BASE="$BASE" AOE2_GAME="$game" AOE2_SETUP="$setup"
python - <<'PY'
import os, shlex
from pathlib import Path
base=Path(os.environ['AOE2_MOBOX_BASE']); game=Path(os.environ['AOE2_GAME']).resolve()
prefix=Path(os.environ['PREFIX'])
def find(names):
    hits=sorted(p for p in game.rglob('*') if p.is_file() and p.name.lower() in names)
    if not hits: raise SystemExit('Missing game executable: '+', '.join(names))
    return hits[0]
targets={'play-aok':find({'empires2.exe','age2.exe'}),
         'play-aoe2':find({'age2_x1.exe','age2x1.exe'}),
         'install-voobly':Path(os.environ['AOE2_SETUP']).resolve()}
original=(prefix/'glibc/opt/scripts/start-tfm').read_text()
needle='$PREFIX/glibc/opt/apps/tfm.exe'
if original.count(needle)!=1: raise SystemExit('Unsupported Mobox start-tfm version; no launch commands changed.')
adapter=base/'start-app'
adapter.write_text(original.replace(needle,'"${AOE2_MOBOX_TARGET:?Missing application target}"'))
for name,target in targets.items():
    body='#!'+str(prefix/'bin/bash')+'\n'
    body+='export AOE2_MOBOX_TARGET='+shlex.quote(str(target))+'\n'
    body+='cd -- '+shlex.quote(str(game))+' || exit 1\n'
    body+='exec '+shlex.quote(str(prefix/'bin/bash'))+' '+shlex.quote(str(adapter))+'\n'
    output=prefix/'bin'/name; output.write_text(body); output.chmod(0o755)
(base/'voobly-search-root').write_text(os.environ['WINEPREFIX'])
PY
echo 'Launching the Voobly installer through Mobox. Complete it in Termux:X11.'
install-voobly
read -r -p 'After Voobly setup finishes, press Enter: ' _
python - <<'PY'
import os,shlex
from pathlib import Path
base=Path(os.environ['AOE2_MOBOX_BASE']); root=Path((base/'voobly-search-root').read_text())
hits=sorted(p for p in (root/'drive_c').rglob('*') if p.is_file() and p.name.lower()=='voobly.exe')
if not hits: raise SystemExit('Voobly not found. Run install-voobly, finish setup, then rerun this installer.')
prefix=Path(os.environ['PREFIX']); target=hits[0]
body='#!'+str(prefix/'bin/bash')+'\nexport AOE2_MOBOX_TARGET='+shlex.quote(str(target))+'\n'
body+='exec '+shlex.quote(str(prefix/'bin/bash'))+' '+shlex.quote(str(base/'start-app'))+'\n'
output=prefix/'bin/play-voobly'; output.write_text(body); output.chmod(0o755)
PY
echo 'Installed commands: play-aok, play-aoe2, play-voobly, install-voobly.'
echo 'For multiplayer, launch play-voobly and start AoE from the Voobly lobby.'
echo 'Separate commands restart the Mobox desktop; do not use them to start a second concurrent session.'
echo 'No Winetricks DirectPlay registration was run. Mobox supplied the prefix/DirectX configuration.'
