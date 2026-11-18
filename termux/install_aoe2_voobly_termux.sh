#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  Age of Empires II + Voobly with Hangover Wine + FEX  (Termux / Android ARM64)
#
#  1. Installs Termux's packaged `hangover-wine` + `hangover-libwow64fex`
#     (Wine ARM64; 32-bit Windows code runs through FEX via HODLL=libwow64fex.dll).
#  2. Creates a Wine prefix and checks that 32-bit Windows programs start.
#  3. Maps your AoE II folder as a Wine drive (symlink in dosdevices). If the folder
#     is outside Termux's private storage (e.g. /sdcard, mounted noexec by Android)
#     you choose: a ROOT bind mount of the raw storage path, or a COPY into ~/aoe2.
#  4. (optional, --directplay) installs native DirectPlay via winetricks.
#  5. Installs Voobly (installer is staged in a private folder first).
#  6. Creates the `aoe2-voobly` command. Every launch first frees TCP/UDP 47624
#     (and, in root mode, re-creates the bind mount if a reboot removed it).
#
#  Usage:
#    bash aoe2-fex-voobly.sh [--game DIR] [--game-mode copy|root|keep]
#                            [--voobly-setup FILE] [--prefix DIR] [--res WxH]
#                            [--directplay] [--reset-prefix] [--reinstall-hangover] [--yes]
#
#  Afterwards:  aoe2-voobly voobly | aoe2 | aok | clear-port | port-test |
#                           stop | status | mount-game | umount-game | wine ARGS...
#
#  Wine is not a sandbox. Use only game files and installers you trust.
# =============================================================================
set -o pipefail

BASE="${AOE2_FEX_HOME:-$HOME/.local/share/aoe2-fex}"
LIB="$BASE/lib"; BIN="$BASE/bin"; LOGS="$BASE/logs"; CACHE="$BASE/cache"; TOOLS="$BASE/tools"
STATE="$BASE/state.env"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGS/install-$STAMP.log"
mkdir -p "$LIB" "$BIN" "$LOGS" "$CACHE" "$TOOLS"

: "${PREFIX:=/data/data/com.termux/files/usr}"
TOTAL_STAGES=8
CMD_EXE='C:\windows\system32\cmd.exe'
DIRECTPLAY_FILES=(dplayx.dll dpnet.dll dpnhpast.dll dpwsockx.dll)
# winetricks' directplay verb needs this redist; its only upstream URL is a flaky
# web.archive.org snapshot. Pre-seeding the cache (same pinned SHA256 as winetricks)
# avoids most failures.
DIRECTX_NAME=directx_feb2010_redist.exe
DIRECTX_SHA256=f6d191e89a963d7cca34f169d30f49eab99c1ed3bb92da73ec43617caaa1e93f
DIRECTX_MIRRORS=(
    'https://proxy.usebottles.com/redistributable/dependencies/directx_feb2010_redist.exe'
    'https://files.holarse-linuxgaming.de/mirrors/microsoft/directx_feb2010_redist.exe'
    'https://web.archive.org/web/20100205000000id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe'
    'https://web.archive.org/web/20101224202650id_/http://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe'
    'https://web.archive.org/web/2016id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe'
)

GAME_DIR_ARG=""; GAME_MODE_ARG=""; SETUP_ARG=""; PREFIX_ARG=""; ASSUME_YES=0
WANT_DIRECTPLAY=0; REINSTALL_HANGOVER=0; RESET_PREFIX=0
C_ON=""; { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; } && C_ON=1

# ------------------------------------------------------------------ UI helpers
_c()   { [ -n "$C_ON" ] && printf '\033[%sm' "$1"; }
say()  { printf '%s%s%s\n' "$(_c 36)" "$*" "$(_c 0)"; printf '%s\n' "$*" >>"$LOG"; }
ok()   { printf '%s✔ %s%s\n' "$(_c 32)" "$*" "$(_c 0)"; printf 'OK: %s\n' "$*" >>"$LOG"; }
warn() { printf '%s! %s%s\n' "$(_c 33)" "$*" "$(_c 0)" >&2; printf 'WARN: %s\n' "$*" >>"$LOG"; }
die()  { printf '%s✘ %s%s\nLog: %s\n' "$(_c 31)" "$*" "$(_c 0)" "$LOG" >&2; printf 'FATAL: %s\n' "$*" >>"$LOG"; exit 1; }

stage() {
    local n=$1; shift
    printf '\n%s[%s/%s] %s%s\n%s\n' "$(_c '1;36')" "$n" "$TOTAL_STAGES" "$*" "$(_c 0)" \
        "──────────────────────────────────────────────────────────────"
    printf '\n[%s/%s] %s\n' "$n" "$TOTAL_STAGES" "$*" >>"$LOG"
}

ask() {   # ask "prompt" [default]  ->  $REPLY
    local p=$1 d=${2:-} a
    if [ "$ASSUME_YES" = 1 ] && [ -n "$d" ]; then REPLY=$d; return 0; fi
    { : </dev/tty; } 2>/dev/null || die "No terminal available for the prompt: $p (use --yes / explicit options)."
    if [ -n "$d" ]; then printf '%s❯%s %s [%s]: ' "$(_c '1;36')" "$(_c 0)" "$p" "$d" >/dev/tty
    else printf '%s❯%s %s: ' "$(_c '1;36')" "$(_c 0)" "$p" >/dev/tty; fi
    IFS= read -r a </dev/tty || a=""
    REPLY=${a:-$d}
}

yes_no() {   # yes_no "question" y|n
    local def=${2:-n} a
    if [ "$ASSUME_YES" = 1 ]; then [ "$def" = y ]; return; fi
    ask "$1 [$([ "$def" = y ] && echo Y/n || echo y/N)]" ""
    a=${REPLY,,}
    [ -z "$a" ] && a=$def
    [ "$a" = y ] || [ "$a" = yes ]
}

clean_path() {   # strip quotes, expand ~
    local p=$1
    p=${p#\"}; p=${p%\"}; p=${p#\'}; p=${p%\'}
    p=${p/#\~/$HOME}
    printf '%s' "$p"
}

# ------------------------------------------------------------ file inspection
pe_machine() {   # prints i386 | x64 for a PE file, fails otherwise
    local f=$1 off sig
    [ -f "$f" ] || return 1
    [ "$(head -c2 "$f" 2>/dev/null)" = MZ ] || return 1
    off=$(od -An -tu4 -j60 -N4 "$f" 2>/dev/null | tr -d ' ')
    [ -n "$off" ] || return 1
    sig=$(od -An -tx1 -j"$off" -N6 "$f" 2>/dev/null | tr -d ' \n')
    case "$sig" in
        504500004c01) echo i386 ;;
        504500006486) echo x64 ;;
        *) return 1 ;;
    esac
}

find_ci() {      # find_ci DIR NAME [DEPTH] -> shallowest case-insensitive match
    find "$1" -maxdepth "${3:-3}" -type f -iname "$2" 2>/dev/null |
        awk '{ print length($0) "\t" $0 }' | sort -n | cut -f2- | head -n1
}

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

save_state() {
    {
        printf 'HANGOVER_BIN=%q\n' "${HANGOVER_BIN:-}"
        printf 'AOE_PREFIX=%q\n'   "${AOE_PREFIX:-}"
        printf 'AOE_RES=%q\n'      "${AOE_RES:-1280x720}"
        printf 'GAME_DIR=%q\n'     "${GAME_DIR:-}"
        printf 'GAME_MODE=%q\n'    "${GAME_MODE:-keep}"
        printf 'GAME_ORIG=%q\n'    "${GAME_ORIG:-}"
        printf 'GAME_SRC=%q\n'     "${GAME_SRC:-}"
        printf 'GAME_DRIVE=%q\n'   "${GAME_DRIVE:-}"
        printf 'GAME_PATH=%q\n'    "${GAME_PATH:-}"
        printf 'AOK_REL=%q\n'      "${AOK_REL:-}"
        printf 'AOC_REL=%q\n'      "${AOC_REL:-}"
        printf 'VOOBLY_EXE=%q\n'   "${VOOBLY_EXE:-}"
    } >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# =============================================================================
#  Shared runtime (written to $LIB/env.sh, sourced by the installer AND by the
#  launcher, so there is one implementation of "run Hangover's Wine", of
#  "free port 47624" and of "mount the game folder with root").
# =============================================================================
write_env_lib() {
    cat >"$LIB/env.sh.tmp" <<'ENVSH'
# shellcheck shell=bash
# Shared runtime for Hangover Wine + FEX. Generated by aoe2-fex-voobly.sh; rerun the
# installer to regenerate it.
: "${PREFIX:=/data/data/com.termux/files/usr}"
PORT=47624
AOE_STATE="${AOE_BASE:?AOE_BASE must be set}/state.env"

aoe_say()  { printf '%s\n' "$*"; }
aoe_warn() { printf 'warning: %s\n' "$*" >&2; }

# bounded SECONDS CMD... : run a command or function with a hard time limit.
bounded() {
    local secs=$1 pid i; shift
    "$@" &
    pid=$!
    for ((i = 0; i < secs * 2; i++)); do
        kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }
        sleep 0.5
    done
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
}

# --------------------------------------------------------- Hangover's Wine ---
# Environment that was verified on a fresh Termux: 32-bit code goes through FEX
# (HODLL), Wine's built-in graphics DLLs are used (no DXVK), software GL is
# requested (llvmpipe), and anything left over from older Box64/Mobox/Turnip
# experiments is unset.
hf_env() {
    local want_res=${AOE_RES:-}
    [ -r "$AOE_STATE" ] && . "$AOE_STATE"
    [ -n "$want_res" ] && AOE_RES=$want_res
    AOE_RES=${AOE_RES:-1280x720}
    HANGOVER_BIN="${HANGOVER_BIN:-$PREFIX/opt/hangover-wine/bin}"
    if [ ! -x "$HANGOVER_BIN/wine" ]; then
        aoe_warn "Hangover Wine not found in $HANGOVER_BIN (pkg install x11-repo hangover-wine hangover-libwow64fex)."
        return 1
    fi
    unset WINEARCH WINELOADER WINESERVER WINEDLLPATH HODLL64 LD_LIBRARY_PATH
    unset MESA_LOADER_DRIVER_OVERRIDE VK_ICD_FILENAMES VK_DRIVER_FILES
    case ":$PATH:" in *":$HANGOVER_BIN:"*) ;; *) export PATH="$HANGOVER_BIN:$PATH" ;; esac
    WINEPREFIX="${AOE_PREFIX:-$AOE_BASE/prefix}"
    export WINEPREFIX HANGOVER_BIN
    export HODLL=libwow64fex.dll
    export DISPLAY=:0 XDG_RUNTIME_DIR="${TMPDIR:-$PREFIX/tmp}"
    export LIBGL_ALWAYS_SOFTWARE=true GALLIUM_DRIVER=llvmpipe
    export WINEDLLOVERRIDES='*ddraw,*d3d9,*d3d10core,*d3d11,*dxgi=b'
    export WINEDEBUG="${AOE_WINEDEBUG:--all,err+all,warn+module}"
    return 0
}

hwine()       { "$HANGOVER_BIN/wine" "$@"; }
hwineserver() { "$HANGOVER_BIN/wineserver" "$@"; }

# ---------------------------------------------------------- process control ---
hf_self_chain() {
    local p=${BASHPID:-$$}
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        echo "$p"
        p=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)
    done
    echo "$$"
}

# PIDs (this user) of Wine processes that belong to this prefix.
hf_wine_pids() {
    local d pid cmd skip want="WINEPREFIX=$WINEPREFIX"
    skip=" $(hf_self_chain | tr '\n' ' ') "
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$skip" in *" $pid "*) continue ;; esac
        [ -O "$d" ] || continue
        cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
        case "$cmd" in *[Ww]ine*|*.[Ee][Xx][Ee]*) ;; *) continue ;; esac
        tr '\0' '\n' <"$d/environ" 2>/dev/null | grep -qxF "$want" && echo "$pid"
    done
}

# Normal prefix shutdown first, then TERM/KILL for whatever is left.
aoe_stop_wine() {
    local pid
    bounded 20 hwineserver -k >/dev/null 2>&1
    bounded 25 hwineserver -w >/dev/null 2>&1
    [ -z "$(hf_wine_pids)" ] && return 0
    for pid in $(hf_wine_pids); do kill -TERM "$pid" 2>/dev/null; done
    sleep 2
    for pid in $(hf_wine_pids); do kill -KILL "$pid" 2>/dev/null; done
    sleep 0.5
    [ -z "$(hf_wine_pids)" ]
}

# ------------------------------------------------------------- port 47624 ----
# Android 10+ hides /proc/net from apps, so ss/netstat often see nothing. We
# therefore combine: lsof/ss/fuser (when they can see), a real bind() test
# (python3, authoritative), and a TCP connect probe (plain bash).
port_pids() {
    {
        command -v lsof >/dev/null 2>&1 && lsof -t -i ":$PORT" 2>/dev/null
        command -v ss >/dev/null 2>&1 && ss -H -lntup "sport = :$PORT" 2>/dev/null |
            grep -o 'pid=[0-9]*' | cut -d= -f2
        if command -v fuser >/dev/null 2>&1; then
            fuser -n tcp "$PORT" 2>/dev/null; fuser -n udp "$PORT" 2>/dev/null
        fi
    } | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u
}

port_busy() {    # returns 0 when 47624 (TCP or UDP) is in use
    [ -n "$(port_pids)" ] && return 0
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import socket, sys
p = int(sys.argv[1])
for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
    s = socket.socket(socket.AF_INET, kind)
    if kind == socket.SOCK_STREAM:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", p))
    except OSError:
        sys.exit(1)
    finally:
        s.close()
' "$PORT" 2>/dev/null
        case $? in 0) return 1 ;; 1) return 0 ;; esac
    fi
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 0
    return 1
}

aoe_port_clear() {
    local pid i
    if ! port_busy; then aoe_say "Port $PORT is free."; return 0; fi
    aoe_say "Port $PORT is in use; freeing it ..."
    for pid in $(port_pids); do
        case " $(hf_self_chain | tr '\n' ' ') " in *" $pid "*) continue ;; esac
        [ -O "/proc/$pid" ] || continue
        aoe_say "  stopping pid $pid ($(cat "/proc/$pid/comm" 2>/dev/null || echo '?'))"
        kill -TERM "$pid" 2>/dev/null
    done
    sleep 1
    for pid in $(port_pids); do kill -KILL "$pid" 2>/dev/null; done
    # The owner may be invisible to us (Android hides sockets) or a wineserver
    # child that inherited the socket: stopping this prefix's Wine releases it.
    if port_busy; then
        aoe_say "  owner not visible; stopping all Wine processes of this prefix"
        aoe_stop_wine
    fi
    for i in 1 2 3 4 5 6; do port_busy || break; sleep 0.5; done
    if port_busy; then
        aoe_warn "Port $PORT is still busy (another app or a process of another user?)."
        return 1
    fi
    aoe_say "Port $PORT is free."
}

# ----------------------------------------------------------- display / audio ---
# 0 when an X11 server answers on DISPLAY=:0. With no probe available we assume it is
# fine, so a missing helper never blocks a launch.
x11_ready() {
    local sock
    for sock in "${XDG_RUNTIME_DIR:-$PREFIX/tmp}/.X11-unix/X0" "$PREFIX/tmp/.X11-unix/X0"; do
        [ -S "$sock" ] && return 0
    done
    command -v xrandr >/dev/null 2>&1 || return 0
    bounded 10 xrandr >/dev/null 2>&1
}

aoe_display() {
    export XDG_RUNTIME_DIR="${TMPDIR:-$PREFIX/tmp}"
    export DISPLAY=:0
    if ! pgrep -f 'app_process / com.termux.x11' >/dev/null 2>&1; then
        aoe_say "Starting Termux:X11 ..."
        command -v termux-x11 >/dev/null 2>&1 || { aoe_warn "termux-x11 command missing (pkg install termux-x11-nightly)."; return 1; }
        (termux-x11 :0 >/dev/null 2>&1 &)
    fi
    am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 ||
        aoe_warn "Could not open the Termux:X11 app (is it installed?)."
    # Wine GUI programs fail immediately when the server is not up yet.
    local i
    for i in $(seq 1 30); do
        x11_ready && return 0
        sleep 1
    done
    return 1
}

aoe_audio() {
    command -v pulseaudio >/dev/null 2>&1 || return 0
    pgrep -x pulseaudio >/dev/null 2>&1 ||
        pulseaudio --start --exit-idle-time=-1 \
            --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" >/dev/null 2>&1
    export PULSE_SERVER="${PULSE_SERVER:-127.0.0.1}"
}

# ------------------------------------------- root bind mount (root game mode) ---
# Android mounts /sdcard (a FUSE layer) noexec, so Wine cannot map game executables
# there. In root mode the RAW storage path (/data/media/0/...) is bind-mounted onto a
# folder in Termux's private storage. The mount is lost on reboot, so the launcher
# calls aoe_game_ensure before every start.
AOE_SU_OPT=""
AOE_SU_PROBED=""

aoe_have_su() { command -v su >/dev/null 2>&1; }

# Pick the su flag that puts the mount in the global namespace (visible to Termux).
aoe_su_detect() {
    [ -n "$AOE_SU_PROBED" ] && return 0
    AOE_SU_PROBED=1
    if bounded 60 su --mount-master -c true >/dev/null 2>&1; then AOE_SU_OPT=--mount-master
    elif bounded 60 su -M -c true >/dev/null 2>&1; then AOE_SU_OPT=-M
    fi
    return 0
}

# aoe_root CMD ARGS... : run one command as root with every argument safely quoted.
aoe_root() {
    local cmd="" a
    aoe_su_detect
    for a in "$@"; do cmd+="${cmd:+ }$(printf '%q' "$a")"; done
    # shellcheck disable=SC2086
    su $AOE_SU_OPT -c "$cmd"
}

aoe_game_mounted() { mount 2>/dev/null | grep -qF " on $1 type "; }

aoe_bind_mount() {   # aoe_bind_mount SRC DST
    local src=$1 dst=$2
    aoe_game_mounted "$dst" && return 0
    mkdir -p "$dst" || return 1
    aoe_root mount --bind "$src" "$dst" || return 1
    # Best effort: a bind mount can inherit ro/noexec from its source.
    aoe_root mount -o remount,bind,rw,exec "$dst" >/dev/null 2>&1 || true
    aoe_game_mounted "$dst"
}

aoe_bind_umount() {  # aoe_bind_umount DST
    aoe_game_mounted "$1" || return 0
    aoe_root umount "$1" || aoe_root umount -l "$1"
}

# Called before every launch: re-creates the bind mount after a reboot.
aoe_game_ensure() {
    [ "${GAME_MODE:-keep}" = bind ] || return 0
    aoe_game_mounted "$GAME_DIR" && return 0
    aoe_say "Mounting the game folder with root: $GAME_SRC -> $GAME_DIR"
    if ! aoe_have_su; then aoe_warn "No 'su' command: cannot mount the game folder."; return 1; fi
    if ! aoe_bind_mount "$GAME_SRC" "$GAME_DIR"; then
        aoe_warn "Could not mount the game folder. Grant root to Termux, or rerun the installer with --game-mode copy."
        return 1
    fi
    aoe_say "Mounted."
}
ENVSH
    mv "$LIB/env.sh.tmp" "$LIB/env.sh"
}

# =============================================================================
#  Launcher
# =============================================================================
write_launcher() {
    cat >"$BIN/aoe2-voobly.tmp" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
# aoe2-voobly - start AoE II / Voobly in Hangover Wine (FEX).
# Every start first frees TCP/UDP 47624 so DirectPlay can host/join games.
AOE_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$AOE_BASE/lib/env.sh" || exit 1
hf_env || exit 1
GAME_PATH="${GAME_PATH:-${GAME_DRIVE^^}:}"

usage() {
    cat <<EOF
Usage: aoe2-voobly <command> [game arguments]
  voobly       start Voobly (log in, pick the patch, launch games from Voobly)
  aoe2         start the game launcher in <game>\\$AOC_REL directly
  aok          start the Age of Kings executable directly
  clear-port   free TCP/UDP $PORT now
  port-test    check $PORT, stop this prefix's Wine, check again
  stop         stop every Wine process of this prefix
  status       show drive link, port and running processes
  mount-game   (root mode) bind-mount the game folder now
  umount-game  (root mode) stop Wine and unmount the game folder
  wine ARGS    run Hangover's wine with this prefix (e.g. wine winecfg)
EOF
}

win_of() {   # Windows path of a Unix path inside drive_c
    local rel=${1#"$WINEPREFIX/drive_c/"}
    printf 'C:\\%s' "${rel//\//\\}"
}

launch() {   # launch LABEL WORKDIR wine-args...
    local label=$1 workdir=$2 logf rc; shift 2
    [ -d "$workdir" ] || { aoe_warn "Missing folder: $workdir  (rerun the installer)"; exit 1; }
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$AOE_BASE/launch.lock"
        flock -n 9 || { aoe_warn "Another aoe2-voobly launch is still running. Close it, or run: aoe2-voobly stop"; exit 1; }
    fi
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
    aoe_port_clear || aoe_warn "Continuing with port $PORT busy; multiplayer may fail."
    aoe_display || aoe_warn "No X11 display answered; open the Termux:X11 app and keep it in front."
    aoe_audio
    mkdir -p "$AOE_BASE/logs"
    logf="$AOE_BASE/logs/$label-$(date +%Y%m%d-%H%M%S).log"
    cd "$workdir" || exit 1
    aoe_say "Starting $label. Log: $logf"
    aoe_say "Open the Termux:X11 app to see the window."
    trap 'aoe_stop_wine; command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock; exit 130' INT TERM
    hwine "$@" 9>&- >"$logf" 2>&1 &
    wait $!
    rc=$?
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
    aoe_say "$label exited with status $rc"
    [ "$rc" -eq 0 ] || tail -n 40 "$logf"
    exit "$rc"
}

# The game launcher lives in a subfolder but loads DLLs from the game root, so it is
# started from <drive>:\ (Windows working directory) via cmd's `start /wait`.
game_launch() {   # game_launch LABEL REL_EXE [args...]
    local label=$1 rel=$2 relw win cmdline; shift 2
    [ -f "$GAME_DIR/$rel" ] || { aoe_warn "Missing executable: $GAME_DIR/$rel  (rerun the installer)"; exit 1; }
    relw=${rel//\//\\}
    win="$GAME_PATH\\$relw"
    cmdline="cd /d $GAME_PATH\\ && start \"\" /wait $win${*:+ $*}"
    launch "$label" "$GAME_DIR" explorer "/desktop=aoe2fex,$AOE_RES" 'C:\windows\system32\cmd.exe' /d /c "$cmdline"
}

cmd=${1:-help}; [ $# -gt 0 ] && shift

# Root mode: the bind mount is lost on reboot, so make sure it is there first.
case "$cmd" in
    voobly|aoe2|aoc|aok|mount-game) aoe_game_ensure || exit 1 ;;
esac

case "$cmd" in
    voobly)
        [ -f "${VOOBLY_EXE:-}" ] || { aoe_warn "Voobly is not installed (rerun the installer)."; exit 1; }
        launch voobly "$(dirname "$VOOBLY_EXE")" explorer "/desktop=voobly,$AOE_RES" "$(win_of "$VOOBLY_EXE")" "$@" ;;
    aoe2|aoc)     game_launch aoe2 "$AOC_REL" "$@" ;;
    aok)          game_launch aok "$AOK_REL" "$@" ;;
    mount-game)
        if [ "${GAME_MODE:-keep}" = bind ]; then aoe_say "Game folder is mounted: $GAME_DIR"
        else aoe_say "Game mode is '${GAME_MODE:-keep}': nothing to mount."; fi ;;
    umount-game)
        if [ "${GAME_MODE:-keep}" = bind ]; then
            aoe_stop_wine
            aoe_bind_umount "$GAME_DIR" && aoe_say "Unmounted $GAME_DIR."
        else aoe_say "Game mode is '${GAME_MODE:-keep}': nothing to unmount."; fi ;;
    clear-port)   aoe_port_clear ;;
    port-test)
        port_busy && b=busy || b=available
        aoe_say "Before shutdown: $b"
        aoe_stop_wine || aoe_warn "Could not verify prefix shutdown."
        port_busy && a=busy || a=available
        aoe_say "After shutdown : $a"
        case "$b/$a" in
            busy/available)      aoe_say "Verified: stopping this prefix released port $PORT." ;;
            available/available) aoe_say "Port $PORT was not held; nothing to clear." ;;
            *)                   aoe_say "Still busy: the owner is not this prefix's Wine (or Android hides it)." ;;
        esac ;;
    stop)         aoe_stop_wine && aoe_say "Wine processes of this prefix stopped." ;;
    status)
        aoe_say "Prefix    : $WINEPREFIX"
        aoe_say "Wine      : $("$HANGOVER_BIN/wine" --version 2>/dev/null)"
        aoe_say "Game      : ${GAME_DIR:-?}  ->  ${GAME_PATH:-?}"
        case "${GAME_MODE:-keep}" in
            bind) aoe_game_mounted "$GAME_DIR" && m=mounted || m="NOT mounted (starts automatically)"
                  aoe_say "Game mode : root bind mount of ${GAME_SRC:-?} ($m)" ;;
            copy) aoe_say "Game mode : copy in Termux storage (original: ${GAME_ORIG:-?})" ;;
            *)    aoe_say "Game mode : in place" ;;
        esac
        aoe_say "Voobly    : ${VOOBLY_EXE:-not installed}"
        if port_busy; then aoe_say "Port $PORT : IN USE ($(port_pids | tr '\n' ' ')owner may be hidden by Android)"
        else aoe_say "Port $PORT : free"; fi
        aoe_say "Wine pids : $(hf_wine_pids | tr '\n' ' ')" ;;
    wine)         hwine "$@" ;;
    *)            usage ;;
esac
LAUNCH
    chmod 755 "$BIN/aoe2-voobly.tmp"; mv "$BIN/aoe2-voobly.tmp" "$BIN/aoe2-voobly"
    ln -sf "$BIN/aoe2-voobly" "$PREFIX/bin/aoe2-voobly"
}

# =============================================================================
#  Stages
# =============================================================================
stage_preflight() {
    stage 1 "Checks and helper packages"
    [ "$(id -u)" != 0 ] || die "Run as the normal Termux user, not root."
    case "$PREFIX" in */com.termux/*) ;; *) die "This script is for Termux on Android (PREFIX=$PREFIX)." ;; esac
    case "$(uname -m)" in aarch64|arm64) ;; *) die "Hangover/FEX needs an ARM64 device (found $(uname -m))." ;; esac
    command -v pkg >/dev/null 2>&1 || die "Termux 'pkg' not found."

    if [ ! -d "$HOME/storage/shared" ]; then
        say "Android storage access is needed for the game folder. Accept the permission dialog."
        termux-setup-storage
        local i
        for i in $(seq 1 60); do [ -d "$HOME/storage/shared" ] && break; sleep 1; done
        [ -d "$HOME/storage/shared" ] || die "Storage permission was not granted."
    fi

    local need=() c
    for c in curl:curl cabextract:cabextract pgrep:procps lsof:lsof flock:util-linux; do
        command -v "${c%%:*}" >/dev/null 2>&1 || need+=("${c##*:}")
    done
    if [ ${#need[@]} -gt 0 ]; then
        say "Installing: $(printf '%s\n' "${need[@]}" | sort -u | tr '\n' ' ')"
        # shellcheck disable=SC2046
        pkg install -y $(printf '%s\n' "${need[@]}" | sort -u) 2>&1 | tee -a "$LOG"
    fi
    command -v curl >/dev/null 2>&1 || pkg install -y curl 2>&1 | tee -a "$LOG"
    if ! curl --version >/dev/null 2>&1; then
        # A partial `pkg upgrade` leaves the new libcurl next to an old OpenSSL, so the
        # binary is present but cannot link (e.g. "cannot locate symbol SSL_set_...").
        warn "curl is installed but cannot run (usually a partial Termux upgrade: new libcurl + old OpenSSL)."
        yes_no "Upgrade OpenSSL and curl now to fix it?" y || die "Run 'pkg update && pkg upgrade -y', then rerun this installer."
        pkg update -y 2>&1 | tee -a "$LOG" || warn "'pkg update' reported an error; still trying the upgrade."
        pkg install -y openssl curl 2>&1 | tee -a "$LOG" || warn "'pkg install openssl curl' reported an error."
        hash -r
    fi
    curl --version >/dev/null 2>&1 ||
        die "curl still cannot run. Run 'pkg update && pkg upgrade -y', restart Termux, then rerun this installer."
    command -v python3 >/dev/null 2>&1 ||
        warn "python3 not installed: port checks and the executable-storage test are less exact (pkg install python)."
    ok "Termux, ARM64 and storage access look fine."
}

stage_hangover() {
    stage 2 "Install Hangover (Wine ARM64 + FEX wow64 module)"
    local runner="${HANGOVER_BIN:-$PREFIX/opt/hangover-wine/bin}" opt=() fex
    [ "$REINSTALL_HANGOVER" = 1 ] && opt=(--reinstall)
    if [ -x "$runner/wine" ] && [ "$REINSTALL_HANGOVER" != 1 ] &&
       command -v termux-x11 >/dev/null 2>&1 && command -v pulseaudio >/dev/null 2>&1; then
        ok "Hangover already installed in $runner; reusing it."
    else
        say "Packages: x11-repo, hangover-wine, hangover-libwow64fex, termux-x11-nightly, pulseaudio"
        say "You also need the Termux:X11 Android app (separate APK) to see windows."
        yes_no "Install these packages now?" y || die "Cancelled."
        pkg install -y x11-repo 2>&1 | tee -a "$LOG" || die "Could not add the Termux x11 repository."
        pkg install -y "${opt[@]}" hangover-wine hangover-libwow64fex termux-x11-nightly pulseaudio 2>&1 | tee -a "$LOG" ||
            die "Package installation failed. If it says 'Unable to locate package', run 'pkg update' or 'termux-change-repo' and rerun."
        hash -r
    fi
    [ -x "$runner/wine" ] || die "Hangover's wine is not at $runner/wine after installation."
    fex="$(find "$PREFIX/opt" "$PREFIX/lib" -name 'libwow64fex.dll' 2>/dev/null | head -n1)"
    if [ -n "$fex" ]; then ok "FEX module: $fex"
    else warn "libwow64fex.dll not found under $PREFIX; 32-bit programs will probably fail (hangover-libwow64fex missing?)."; fi
    HANGOVER_BIN=$runner; save_state
    ok "Hangover runner: $HANGOVER_BIN"
}

stage_prefix() {
    stage 3 "Create the Wine prefix and test 32-bit support"
    write_env_lib
    AOE_BASE=$BASE; export AOE_BASE
    # shellcheck disable=SC1091
    . "$LIB/env.sh"
    if [ -n "$PREFIX_ARG" ]; then AOE_PREFIX=$(clean_path "$PREFIX_ARG"); fi
    AOE_PREFIX="${AOE_PREFIX:-$BASE/prefix}"
    if [ "$RESET_PREFIX" = 1 ] && [ -e "$AOE_PREFIX" ]; then
        warn "Moving the old prefix away: $AOE_PREFIX.old-$STAMP"
        mv "$AOE_PREFIX" "$AOE_PREFIX.old-$STAMP" || die "Could not move the old prefix."
        GAME_DRIVE=""; GAME_PATH=""; VOOBLY_EXE=""
    fi
    save_state
    hf_env || die "Hangover runtime not usable."

    local ver out
    ver="$(bounded 120 hwine --version 2>/dev/null | grep -m1 '^wine-')"
    [ -n "$ver" ] || die "Wine does not start. Check the packages, then rerun with --reinstall-hangover."
    ok "Wine runs: $ver"
    case "$ver" in *[Hh]angover*) ;; *) warn "This does not look like a Hangover build ($ver)." ;; esac

    aoe_display || warn "No X11 display yet; open the Termux:X11 app (needed from the Voobly step on)."
    if [ ! -f "$WINEPREFIX/system.reg" ]; then
        say "Creating the Wine prefix at $WINEPREFIX (first start, can take a few minutes) ..."
        bounded 900 hwine wineboot -u >>"$LOG" 2>&1
        bounded 90 hwineserver -w >>"$LOG" 2>&1
    fi
    [ -f "$WINEPREFIX/system.reg" ] || die "Wine did not create a prefix. See the log."
    ok "Prefix: $WINEPREFIX"

    out="$(bounded 300 hwine 'C:\windows\syswow64\cmd.exe' /d /c 'echo WIN32_APP_OK' 2>&1)"
    printf '%s\n' "$out" >>"$LOG"
    [[ "$out" == *WIN32_APP_OK* ]] ||
        die "A 32-bit Windows program did not run (FEX/HODLL problem). See the log."
    ok "32-bit Windows programs run (needed for AoE II and Voobly)."
    if [[ "$out" == *FEX* ]]; then ok "The log confirms FEX is emulating the 32-bit code."
    else warn "No FEX line in the output, so FEX use is not confirmed (32-bit code still ran)."; fi
}

pick_drive() {   # echo free-or-existing drive letter pointing at $GAME_DIR
    local dev="$WINEPREFIX/dosdevices" l link game
    game="$(readlink -f "$GAME_DIR")"
    mkdir -p "$dev"
    for l in g h i j k l m n o p q r s t u v w x y; do
        link="$dev/$l:"
        if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$game" ]; then echo "$l"; return 0; fi
    done
    # The game moved (e.g. /sdcard -> copy or bind mount): keep the drive letter this
    # script created earlier so Voobly's saved G:\ paths stay valid.
    if [ -n "${GAME_DRIVE:-}" ] && [ -L "$dev/${GAME_DRIVE}:" ]; then
        ln -sfn "$game" "$dev/${GAME_DRIVE}:" && { echo "$GAME_DRIVE"; return 0; }
    fi
    for l in g h i j k l m n o p q r s t u v w x y; do
        link="$dev/$l:"
        if [ ! -e "$link" ] && [ ! -L "$link" ]; then
            ln -s "$game" "$link" && { echo "$l"; return 0; }
        fi
    done
    return 1
}

drive_visible() {   # drive_visible "G:"  - can Wine cd to the root of that drive?
    local out rc first
    out="$(bounded 120 hwine "$CMD_EXE" /d /c "cd /d $1\\ && echo AOE_DRIVE_OK" 2>&1)"; rc=$?
    printf 'drive probe %s (rc=%s): %s\n' "$1" "$rc" "$out" >>"$LOG"
    [[ "$out" == *AOE_DRIVE_OK* ]] && return 0
    first="$(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-200)"
    say "  probe $1 -> ${first:-no output} (status $rc)"
    return 1
}

# ------------------------------------------ where does the game folder live? ---
# Android mounts shared storage (/sdcard) noexec through FUSE. Wine then cannot map the
# game's exe/DLL sections as executable, and patched executables (UserPatch 1.5/1.6)
# can fail to start even though the plain 1.0c game runs. Two ways around it:
#   root : bind-mount the raw storage path (/data/media/0/...) into Termux's home
#   copy : copy the folder into Termux's private storage (~/aoe2)

in_private_storage() {   # 0 when the path is inside Termux's own (exec-capable) storage
    local p=$1 home_real
    home_real="$(readlink -f "$HOME" 2>/dev/null)"; home_real=${home_real:-$HOME}
    case "$p/" in
        "$HOME"/*|"$home_real"/*|"$PREFIX"/*) return 0 ;;
        /data/data/com.termux/*|/data/user/*/com.termux/*) return 0 ;;
    esac
    return 1
}

exec_mappable() {   # exec_mappable FILE: 0 = can be mapped executable, 1 = cannot, 2 = unknown
    command -v python3 >/dev/null 2>&1 || return 2
    python3 -c 'import mmap, sys
f = open(sys.argv[1], "rb")
mmap.mmap(f.fileno(), 0, flags=mmap.MAP_PRIVATE, prot=mmap.PROT_READ | mmap.PROT_EXEC)' "$1" 2>/dev/null
}

raw_media_path() {   # map an Android storage path to the underlying (non-FUSE) path
    local p=$1
    case "$p" in
        /storage/emulated/*)       printf '/data/media/%s' "${p#/storage/emulated/}" ;;
        /storage/self/primary/*)   printf '/data/media/0/%s' "${p#/storage/self/primary/}" ;;
        /sdcard/*)                 printf '/data/media/0/%s' "${p#/sdcard/}" ;;
        /storage/????-????/*)      local rest=${p#/storage/}; printf '/mnt/media_rw/%s' "$rest" ;;
        *)                         printf '%s' "$p" ;;
    esac
}

location_root() {   # try the root bind mount; 0 = success (sets GAME_DIR/GAME_SRC/GAME_ORIG/GAME_MODE)
    local raw mp line bad=""
    aoe_have_su || { warn "No 'su' command: this device does not look rooted."; return 1; }
    say "Requesting root: grant the prompt in your root manager ..."
    aoe_su_detect
    # shellcheck disable=SC2086
    bounded 60 su $AOE_SU_OPT -c id 2>/dev/null | grep -q 'uid=0' ||
        { warn "Root access was not granted to Termux."; return 1; }

    raw="$(raw_media_path "$GAME_DIR")"
    aoe_root test -d "$raw" || { warn "Root cannot see $raw (is the game on internal storage?)."; return 1; }
    mp="$BASE/game"
    aoe_stop_wine >/dev/null 2>&1
    aoe_bind_umount "$mp" >/dev/null 2>&1
    say "Bind-mounting $raw  ->  $mp"
    if ! aoe_bind_mount "$raw" "$mp"; then
        warn "The bind mount failed, or it is not visible from Termux."
        aoe_bind_umount "$mp" >/dev/null 2>&1
        return 1
    fi

    line="$(mount 2>/dev/null | grep -F " on $mp type " | tail -n1)"
    printf 'game mount: %s\n' "$line" >>"$LOG"
    say "  $line"
    case "$line" in *" type fuse"*|*" type sdcardfs"*|*" type esdfs"*) bad="still a FUSE/sdcardfs mount" ;; esac
    case "$line" in *noexec*) bad="${bad:+$bad; }mounted noexec" ;; esac
    case "$line" in *"(ro,"*|*"(ro)"*) bad="${bad:+$bad; }mounted read-only" ;; esac
    if [ -n "$bad" ]; then
        warn "The mount does not help: $bad."
        aoe_bind_umount "$mp" >/dev/null 2>&1
        return 1
    fi

    if [ ! -r "$mp/$AOC_REL" ]; then
        warn "Mounted, but Termux cannot read the files (SELinux or file ownership)."
        if yes_no "Run 'setenforce 0' (SELinux permissive until reboot; weakens Android security)?" n &&
           aoe_root setenforce 0 && [ -r "$mp/$AOC_REL" ]; then
            ok "Readable now (SELinux is permissive until the next reboot)."
        else
            aoe_bind_umount "$mp" >/dev/null 2>&1
            return 1
        fi
    fi

    exec_mappable "$mp/$AOC_REL"
    case $? in
        1) warn "Files there still cannot be mapped executable."; aoe_bind_umount "$mp" >/dev/null 2>&1; return 1 ;;
        2) warn "python3 missing: could not test executable mapping; continuing." ;;
    esac

    GAME_ORIG=$GAME_DIR; GAME_SRC=$raw; GAME_DIR=$mp; GAME_MODE=bind
    ok "Root mode: $raw is mounted at $mp (the launcher remounts it after a reboot)."
    return 0
}

location_copy() {   # copy the game into Termux storage; 0 = success
    local src=$GAME_DIR dest need free
    ask "Copy the game folder to" "$HOME/aoe2"; dest=$(clean_path "$REPLY")
    case "$dest/" in "$src"/*) warn "The copy cannot be inside the original folder."; return 1 ;; esac
    case "$src/" in "$dest"/*) warn "The copy cannot contain the original folder."; return 1 ;; esac
    case "$dest/" in "$WINEPREFIX"/*) warn "The copy cannot be inside the Wine prefix."; return 1 ;; esac
    in_private_storage "$dest" || warn "$dest is not in Termux's private storage; executables may not work there."

    if [ -n "$(find_ci "$dest" age2_x1.exe 3)" ] || [ -n "$(find_ci "$dest" age2x1.exe 3)" ]; then
        if yes_no "A game copy already exists in $dest. Use it as it is (no copying)?" y; then
            GAME_ORIG=$src; GAME_SRC=""; GAME_DIR=$dest; GAME_MODE=copy
            ok "Using the existing copy: $dest"
            return 0
        fi
    elif [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        yes_no "$dest is not empty. Copy into it anyway (existing files are overwritten)?" n || return 1
    fi

    mkdir -p "$dest" || { warn "Cannot create $dest."; return 1; }
    need=$(du -sk "$src" 2>/dev/null | cut -f1)
    free=$(df -Pk "$dest" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$need" ] && [ -n "$free" ] && [ "$free" -lt $((need + 262144)) ]; then
        warn "Not enough free space: need about $((need / 1024)) MB plus 256 MB spare, have $((free / 1024)) MB."
        return 1
    fi
    say "Copying $src  ->  $dest  (this can take a while) ..."
    cp -a "$src/." "$dest/" 2>>"$LOG" || { warn "Copy failed; see the log."; return 1; }
    [ -f "$dest/$AOC_REL" ] || { warn "Copy finished but $AOC_REL is missing in $dest."; return 1; }
    GAME_ORIG=$src; GAME_SRC=""; GAME_DIR=$dest; GAME_MODE=copy
    ok "Copied. The original stays untouched as your backup: $src"
    return 0
}

prepare_game_location() {
    local prev_mode=${GAME_MODE:-keep} prev_orig=${GAME_ORIG:-} choice rc
    GAME_MODE=keep; GAME_ORIG=""; GAME_SRC=""

    if in_private_storage "$GAME_DIR"; then
        [ "$prev_mode" = copy ] && { GAME_MODE=copy; GAME_ORIG=$prev_orig; }
        ok "The game folder is in Termux's private storage; executables map fine there."
        return 0
    fi

    exec_mappable "$GAME_DIR/$AOC_REL"; rc=$?
    if [ "$rc" = 0 ]; then
        ok "Executables in $GAME_DIR can be mapped executable; using the folder in place."
        return 0
    fi

    warn "The game folder is outside Termux's private storage: $GAME_DIR"
    say "  Android mounts shared storage (/sdcard) noexec. Wine then cannot map the game's"
    say "  executables there, and the patched 1.5/1.6 versions may refuse to start."
    choice="$GAME_MODE_ARG"
    if [ -z "$choice" ]; then
        say ""
        say "  1) Root: bind-mount the raw storage path into Termux's home (experimental)."
        say "     The game stays on /sdcard (survives clearing Termux data). Needs root;"
        say "     the mount is lost on reboot and the launcher redoes it automatically."
        say "  2) Copy: copy the game folder to ~/aoe2 (reliable, uses extra space)."
        say "     Your /sdcard copy stays untouched as a backup. Updates made by Voobly"
        say "     only go into the copy."
        ask "Choose 1 or 2" "2"
        case "$REPLY" in 1|root|r) choice=root ;; *) choice=copy ;; esac
    fi

    case "$choice" in
        keep)
            warn "Keeping the folder in place (--game-mode keep); UserPatch 1.5/1.6 may not start."
            ;;
        root)
            if ! location_root; then
                warn "The root option did not work on this device."
                yes_no "Copy the game to the Termux home folder instead?" y ||
                    die "Cancelled. Rerun with --game-mode copy, or move the game into Termux's home."
                location_copy || die "Copying the game failed; see the messages above and the log."
            fi
            ;;
        copy)
            location_copy || die "Copying the game failed; see the messages above and the log."
            ;;
    esac
}

stage_game() {
    stage 4 "Map the AoE II game folder as a Wine drive"
    local default d aok aoc
    default="${GAME_DIR:-$HOME/storage/shared/Games/Age of Empires II}"
    # Remembered root/copy setups: offer the ORIGINAL folder again, not the mount/copy.
    case "${GAME_MODE:-keep}" in bind|copy) [ -n "${GAME_ORIG:-}" ] && default=$GAME_ORIG ;; esac
    if [ -n "$GAME_DIR_ARG" ]; then d=$(clean_path "$GAME_DIR_ARG")
    else
        say "Folder with the ORIGINAL AoE II + The Conquerors (age2_x1.exe) files."
        say "Shared storage lives under ~/storage/shared (that is /sdcard)."
        ask "AoE II game directory" "$default"; d=$(clean_path "$REPLY")
    fi
    while [ ! -d "$d" ]; do
        warn "Not a directory: $d"
        [ -z "$GAME_DIR_ARG" ] || die "Game directory does not exist."
        ask "AoE II game directory" "$default"; d=$(clean_path "$REPLY")
    done
    GAME_DIR="$(readlink -f "$d")"
    case "$GAME_DIR/" in "$WINEPREFIX"/*) die "The game folder must not be inside the Wine prefix." ;; esac
    case "$WINEPREFIX/" in "$GAME_DIR"/*) die "The Wine prefix must not be inside the game folder." ;; esac

    aok="$(find_ci "$GAME_DIR" age2.exe 3)"; [ -n "$aok" ] || aok="$(find_ci "$GAME_DIR" empires2.exe 3)"
    aoc="$(find_ci "$GAME_DIR" age2_x1.exe 3)"; [ -n "$aoc" ] || aoc="$(find_ci "$GAME_DIR" age2x1.exe 3)"
    [ -n "$aok" ] && [ -n "$aoc" ] ||
        die "Need empires2.exe (or age2.exe) AND age2_x1.exe (or age2x1.exe) in $GAME_DIR (original Age of Kings + Conquerors)."
    [ "$(pe_machine "$aok")" = i386 ] && [ "$(pe_machine "$aoc")" = i386 ] ||
        die "Expected the original 32-bit game executables (not HD/Definitive Edition)."
    AOK_REL="${aok#"$GAME_DIR"/}"; AOC_REL="${aoc#"$GAME_DIR"/}"

    # Outside Termux's private storage? Offer the root bind mount or a copy.
    prepare_game_location
    save_state

    local letter drive attempt visible=0
    letter="$(pick_drive)" || die "No free Wine drive letter (g: to y:)."
    drive="${letter^^}:"
    # wineserver reads dosdevices at start-up: make sure it restarts to see the new link.
    bounded 30 hwineserver -k >/dev/null 2>&1; bounded 45 hwineserver -w >/dev/null 2>&1
    for attempt in 1 2 3; do
        if drive_visible "$drive"; then visible=1; break; fi
        bounded 30 hwineserver -k >/dev/null 2>&1; bounded 45 hwineserver -w >/dev/null 2>&1
    done
    [ "$visible" = 1 ] ||
        die "Wine cannot reach $GAME_DIR as $drive. Check that the folder is readable (termux-setup-storage) and rerun; see $LOG."
    GAME_DRIVE=$letter; GAME_PATH="$drive"
    save_state
    ok "$drive  ->  $GAME_DIR"
    say "Launcher: ${GAME_PATH}\\${AOC_REL//\//\\}   (started with $GAME_PATH\\ as working directory)"

    # A copy already has the untouched original as its backup.
    if [ "$GAME_MODE" != copy ] &&
       yes_no "Back up the game folder before Voobly can patch it? (optional, needs free space)" n; then
        local need free target="$GAME_DIR.backup-$STAMP"
        [ "$GAME_MODE" = bind ] && target="$GAME_ORIG.backup-$STAMP"
        need=$(du -sk "$GAME_DIR" 2>/dev/null | cut -f1)
        free=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
        if [ -n "$need" ] && [ -n "$free" ] && [ "$free" -gt $((need + 524288)) ]; then
            cp -a "$GAME_DIR" "$target" && ok "Backup: $target"
        else
            warn "Not enough free space for a backup; skipped."
        fi
    fi
}

# ------------------------------------------------- DirectPlay (opt-in stage) ---
# Not part of the verified setup: Wine's built-in DirectPlay is used by default.
# Enable with --directplay only if a lobby reports a specific DirectPlay failure.
directplay_ready() {
    local sys="$WINEPREFIX/drive_c/windows/syswow64" f out
    for f in "${DIRECTPLAY_FILES[@]}"; do [ "$(pe_machine "$sys/$f")" = i386 ] || return 1; done
    # Wine's builtin DLLs are PE files too, so also require the native override.
    out="$(bounded 60 hwine reg query 'HKCU\Software\Wine\DllOverrides' 2>/dev/null)"
    printf '%s\n' "$out" | grep -Eiq '"?\*?dplayx"?[[:space:]]+REG_SZ[[:space:]]+(native|n)\b'
}

install_winetricks() {
    WT="$TOOLS/winetricks"
    [ -s "$WT" ] && { bash -n "$WT" && return 0; }
    local sha url
    sha="$(curl -fsSL https://api.github.com/repos/Winetricks/winetricks/commits/master 2>/dev/null |
           sed -n 's/^[[:space:]]*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)"
    if [ -n "$sha" ]; then
        url="https://raw.githubusercontent.com/Winetricks/winetricks/$sha/src/winetricks"
    else
        warn "Could not resolve a winetricks commit; using the master branch."
        url="https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
    fi
    curl -fsSL "$url" -o "$WT.part" || die "Could not download winetricks."
    bash -n "$WT.part" || die "Downloaded winetricks is not valid shell."
    chmod 755 "$WT.part"; mv "$WT.part" "$WT"
    printf 'winetricks commit: %s\n' "${sha:-master}" >>"$LOG"
}

seed_redist() {
    local t1="$CACHE/winetricks/directx9/$DIRECTX_NAME" t2="$CACHE/xdg/winetricks/directx9/$DIRECTX_NAME" u
    mkdir -p "$(dirname "$t1")" "$(dirname "$t2")"
    if [ "$(sha_of "$t1")" != "$DIRECTX_SHA256" ]; then
        for u in "${DIRECTX_MIRRORS[@]}"; do
            say "  fetching DirectX redist from $(printf '%s' "$u" | cut -d/ -f3)"
            if curl -fL -# --retry 2 --connect-timeout 20 -o "$t1.part" "$u" &&
               [ "$(sha_of "$t1.part")" = "$DIRECTX_SHA256" ]; then
                mv "$t1.part" "$t1"; break
            fi
            rm -f "$t1.part"; warn "mirror failed, trying the next one"
        done
    fi
    [ "$(sha_of "$t1")" = "$DIRECTX_SHA256" ] || return 1
    cp -f "$t1" "$t2"
    ok "$DIRECTX_NAME (SHA256 verified)"
}

stage_directplay() {
    stage 5 "Native DirectPlay (optional)"
    if [ "$WANT_DIRECTPLAY" != 1 ]; then
        say "Skipped: Wine's built-in DirectPlay is used (the verified setup)."
        say "If a Voobly lobby reports a DirectPlay error, rerun with --directplay."
        return 0
    fi
    if directplay_ready; then ok "Native DirectPlay is already installed."; return 0; fi
    warn "Native DirectPlay under FEX is untested. Back up the prefix if you want a way back."
    yes_no "Close this prefix's Wine apps and install native DirectPlay now?" y || die "DirectPlay installation declined."
    install_winetricks
    aoe_stop_wine
    if yes_no "Back up the Wine prefix first? (optional, can be large)" n; then
        local target="$BASE/backups/$(basename "$WINEPREFIX")-before-directplay-$STAMP"
        mkdir -p "$BASE/backups"; cp -a "$WINEPREFIX" "$target" && ok "Backup: $target"
    fi
    seed_redist || warn "DirectX redist not pre-fetched; winetricks will try archive.org itself (often 503)."
    local attempt rc=1
    for attempt in 1 2 3; do
        say "winetricks directplay (attempt $attempt/3, several minutes; output goes to the log) ..."
        timeout 1800 env WINE="$HANGOVER_BIN/wine" WINESERVER="$HANGOVER_BIN/wineserver" WINEPREFIX="$WINEPREFIX" \
            WINETRICKS_CACHE="$CACHE/winetricks" XDG_CACHE_HOME="$CACHE/xdg" \
            bash "$WT" -q directplay >>"$LOG" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] && break
        [ "$attempt" -lt 3 ] && { warn "attempt $attempt failed; retrying in $((5 * attempt))s"; sleep $((5 * attempt)); }
    done
    if [ "$rc" -ne 0 ] || ! directplay_ready; then
        die "DirectPlay installation failed. Check the log for the winetricks error. If the DirectX download was the problem, put $DIRECTX_NAME (SHA256 $DIRECTX_SHA256) into $CACHE/winetricks/directx9/ and rerun."
    fi
    local v
    for v in dpnlobby '*dpnlobby'; do
        bounded 60 hwine reg delete 'HKCU\Software\Wine\DllOverrides' /v "$v" /f >/dev/null 2>&1
    done
    ok "Native DirectPlay installed and registered."
}

stage_voobly() {
    stage 6 "Install Voobly"
    local found="" setup="" g
    if [ -n "${VOOBLY_EXE:-}" ] && [ -f "$VOOBLY_EXE" ]; then found=$VOOBLY_EXE
    else found="$(find_ci "$WINEPREFIX/drive_c" voobly.exe 8)"; fi

    if [ -z "$found" ]; then
        if [ -n "$SETUP_ARG" ]; then setup=$(clean_path "$SETUP_ARG")
        else
            for g in "$HOME"/storage/downloads/*[Vv]oobly*.exe "$HOME"/storage/shared/Download/*[Vv]oobly*.exe; do
                [ -f "$g" ] && setup=$g
            done
            ask "Path to the Voobly setup .exe" "${setup:-$HOME/storage/downloads/voobly.exe}"; setup=$(clean_path "$REPLY")
        fi
        [ -f "$setup" ] || die "Voobly setup not found: $setup"
        pe_machine "$setup" >/dev/null || die "That file is not a Windows executable."
        say "The Voobly installer will open in Termux:X11: accept the license, keep the default"
        say "destination, and UNCHECK 'Launch Voobly' at the end."
        yes_no "Start the Voobly installer now?" y || die "Voobly installation declined."
        aoe_display; aoe_audio
        if ! x11_ready; then
            warn "No X11 display answers on DISPLAY=:0, so Wine cannot open windows."
            say  "Open the Termux:X11 app and leave its window in front, then answer y."
            yes_no "Start the Voobly installer anyway?" y || die "Cancelled; rerun once Termux:X11 shows a window."
        fi

        # Stage the installer in a private folder; the prefix and installer then never
        # depend on Android shared-storage behaviour.
        local stagedir="$CACHE/voobly-setup" staged win
        rm -rf "$stagedir"; mkdir -p "$stagedir"
        cp -f "$setup" "$stagedir/" || die "Could not stage the installer in $stagedir."
        staged="$stagedir/$(basename "$setup")"
        win="$(cd "$stagedir" && bounded 60 hwine winepath -w "$staged" 2>/dev/null | tr -d '\r' | grep -m1 -E '^[A-Za-z]:')"

        local ilog="$LOGS/voobly-setup-$STAMP.log" rc=1 attempt
        for attempt in 1 2; do
            say "Running the Voobly installer (attempt $attempt/2) ..."
            : >"$ilog"
            if [ -n "$win" ]; then
                ( cd "$stagedir" && hwine explorer "/desktop=voobly-setup,$AOE_RES" "$win" ) >>"$ilog" 2>&1; rc=$?
            else
                ( cd "$stagedir" && hwine "$staged" ) >>"$ilog" 2>&1; rc=$?
            fi
            bounded 60 hwineserver -w >>"$LOG" 2>&1
            found="$(find_ci "$WINEPREFIX/drive_c" voobly.exe 8)"
            [ -n "$found" ] && break
            [ "$rc" -eq 0 ] && break
            [ "$attempt" -lt 2 ] && { warn "Installer stopped early (status $rc); retrying once."; sleep 5; }
        done
        rm -rf "$stagedir"
        if [ -z "$found" ]; then
            say "The installer log ($ilog) ends with:"
            tail -n 30 "$ilog" | sed 's/^/  /'
            grep -Eqi 'x11drv|open display|connect.*display' "$ilog" &&
                say "  Wine could not reach Termux:X11: open its app and keep it in front, then rerun."
            die "Voobly was not installed (installer status $rc). Post the lines above, or check $LOG."
        fi
    else
        ok "Voobly is already installed."
    fi
    pe_machine "$found" >/dev/null || die "Installed Voobly is not a valid executable: $found"
    VOOBLY_EXE=$found; save_state
    ok "Voobly: $VOOBLY_EXE"
}

stage_launchers() {
    stage 7 "Create launchers"
    write_env_lib
    write_launcher
    save_state
    ok "Command installed: aoe2-voobly  ($PREFIX/bin/aoe2-voobly)"
}

stage_final() {
    stage 8 "Final checks"
    hf_env
    say "Port check (the launcher repeats this before every start) ..."
    aoe_port_clear || warn "Port $PORT is busy and its owner could not be stopped."
    if yes_no "Open Voobly now for a smoke test?" y; then
        "$BIN/aoe2-voobly" voobly
    fi

    local gp="${GAME_PATH:-${GAME_DRIVE^^}:}" aoc_dir="" inst_dir mode_line
    case "$AOC_REL" in */*) aoc_dir="${AOC_REL%/*}" ;; esac
    inst_dir="$gp"; [ -n "$aoc_dir" ] && inst_dir="$gp\\${aoc_dir//\//\\}"
    case "${GAME_MODE:-keep}" in
        bind) mode_line="root bind mount of $GAME_SRC (original path: $GAME_ORIG)" ;;
        copy) mode_line="copy in Termux storage (original untouched: $GAME_ORIG)" ;;
        *)    mode_line="in place" ;;
    esac
    cat <<EOF

$(_c '1;32')INSTALLATION PREPARED$(_c 0)
  Prefix    : $WINEPREFIX
  Wine      : $HANGOVER_BIN  (HODLL=libwow64fex.dll)
  Game      : $GAME_DIR  ->  $gp
  Game mode : $mode_line
  Voobly    : $VOOBLY_EXE
  Log       : $LOG

Commands
  aoe2-voobly voobly      start Voobly
  aoe2-voobly aoe2        start the game launcher directly (does not force a patch)
  aoe2-voobly clear-port  free TCP/UDP $PORT
  aoe2-voobly port-test   port state before/after stopping this prefix's Wine
  aoe2-voobly stop        stop all Wine processes of this prefix
  aoe2-voobly mount-game / umount-game   (root mode) mount or unmount the game folder
  aoe2-voobly status

In Voobly (Game Diagnostics / settings)
  Installation directory : $inst_dir
  Executable             : $gp\\${AOC_REL//\//\\}
  If Voobly does not list ${gp:0:1}: its Browse dialog shows every drive Wine knows about.

What has and has not been verified with this setup
  - Verified: packaged Hangover + FEX starts 32-bit programs, AoE II reaches its launcher,
    Voobly installs and its client opens.
  - Verified (by a user report): a copy of the game inside Termux's home lets Voobly start
    the patched versions, which failed from /sdcard.
  - NOT verified: the root bind-mount mode. It depends on your Android version, root
    manager and SELinux, and the script falls back to the copy option when its own checks fail.
  - Not verified: native DirectPlay (off by default), and that stopping Wine frees $PORT. Test:
      1. aoe2-voobly voobly, pick the patch (try v1.5 first, then v1.6 RC), launch from a lobby
      2. after leaving the lobby: aoe2-voobly port-test
         (busy -> available = cleanup verified; available -> available = nothing was stuck)
  - Graphics use Wine's built-in DLLs in a virtual desktop ($AOE_RES) with software GL requested
    (llvmpipe); it is not confirmed that software GL alone is what makes it work.
  - Let Voobly launch the game for lobby tests; do not start 'aoe2-voobly aoe2' alongside it.
  - Keep Termux awake (the launcher takes a wake lock) and disable battery optimisation for
    Termux and Termux:X11, otherwise Android may kill them mid-match.
EOF
}

# The header comment doubles as --help text. When the script arrives via a pipe
# there is no file to re-read, so fall back to a short usage line.
show_help() {
    local src="${BASH_SOURCE[0]:-}"
    if [ -n "$src" ] && [ -f "$src" ]; then
        sed -n '3,/^# =====/p' "$src" | sed '$d' | sed 's/^# \{0,1\}//'
    else
        printf '%s\n' \
            "Usage: bash install.sh [--game DIR] [--game-mode copy|root|keep]" \
            "                       [--voobly-setup FILE] [--prefix DIR] [--res WxH]" \
            "                       [--directplay] [--reset-prefix] [--reinstall-hangover] [--yes]" \
            "Run the downloaded file directly for the full description."
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --game)               [ $# -ge 2 ] || die "--game needs a directory"; GAME_DIR_ARG=$2; shift 2 ;;
            --game-mode)          [ $# -ge 2 ] || die "--game-mode needs copy, root or keep"; GAME_MODE_ARG=$2; shift 2
                                  case "$GAME_MODE_ARG" in copy|root|keep) ;; *) die "--game-mode must be copy, root or keep" ;; esac ;;
            --voobly-setup)       [ $# -ge 2 ] || die "--voobly-setup needs a file"; SETUP_ARG=$2; shift 2 ;;
            --prefix)             [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX_ARG=$2; shift 2 ;;
            --res)                [ $# -ge 2 ] || die "--res needs WIDTHxHEIGHT"; AOE_RES=$2; shift 2
                                  [[ "$AOE_RES" =~ ^[0-9]+x[0-9]+$ ]] || die "--res must look like 1280x720" ;;
            --directplay)         WANT_DIRECTPLAY=1; shift ;;
            --reset-prefix)       RESET_PREFIX=1; shift ;;
            --reinstall-hangover) REINSTALL_HANGOVER=1; shift ;;
            --yes|-y)             ASSUME_YES=1; shift ;;
            -h|--help)            show_help; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

main() {
    parse_args "$@"
    : >"$LOG"
    [ -r "$STATE" ] && . "$STATE"
    [ -n "${AOE_RES:-}" ] || AOE_RES=1280x720
    trap 'printf "\nCancelled. Completed stages are skipped on the next run.\n"; exit 130' INT
    printf '%s\n' "Age of Empires II  x  Voobly  ->  Hangover Wine + FEX (Termux)"
    stage_preflight
    stage_hangover
    stage_prefix
    stage_game
    stage_directplay
    stage_voobly
    stage_launchers
    stage_final
}

# Run when executed as a file ($0 == BASH_SOURCE) or piped in (BASH_SOURCE empty);
# stay quiet when sourced from another script.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
