#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  Age of Empires II + Voobly inside Mobox  (Termux / Android ARM64)
#
#  1. Installs Mobox (official installer, "wow64" build = Wine 9.3 + Box64).
#  2. Makes sure Mobox has created its Wine container (one guided first start).
#  3. Links your AoE II game folder into that container as a Wine drive letter.
#     This is a symlink in <prefix>/dosdevices; nothing is copied.
#  4. Installs native DirectPlay (winetricks), then Voobly.
#  5. Creates the `aoe2-voobly` command. Every launch first frees TCP/UDP 47624
#     (the DirectPlay port) so multiplayer lobbies can open.
#
#  Usage:
#    bash aoe2-mobox-voobly.sh [--game DIR] [--voobly-setup FILE] [--prefix DIR]
#                              [--yes] [--reinstall-mobox]
#
#  Afterwards:  aoe2-voobly voobly | aoe2 | aok | clear-port | stop | status
#
#  Wine is not a sandbox. Use only game files and installers you trust.
# =============================================================================
set -o pipefail

BASE="${AOE2_MOBOX_HOME:-$HOME/.local/share/aoe2-mobox}"
LIB="$BASE/lib"; BIN="$BASE/bin"; LOGS="$BASE/logs"; CACHE="$BASE/cache"; TOOLS="$BASE/tools"
STATE="$BASE/state.env"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGS/install-$STAMP.log"
mkdir -p "$LIB" "$BIN" "$LOGS" "$CACHE" "$TOOLS"

: "${PREFIX:=/data/data/com.termux/files/usr}"
GLIBC="$PREFIX/glibc"
GLIBC_BIN="$GLIBC/bin"

MOBOX_INSTALL_URL='https://raw.githubusercontent.com/olegos2/mobox/main/install'
MOBOX_INSTALL_SHA256="${MOBOX_INSTALL_SHA256:-}"      # optional: pin the installer
TOTAL_STAGES=8
DIRECTPLAY_FILES=(dplayx.dll dpnet.dll dpnhpast.dll dpwsockx.dll)
# winetricks' directplay verb needs this redist and its only upstream URL is a
# flaky web.archive.org snapshot. Pre-seeding the cache from mirrors (same pinned
# SHA256 as winetricks) avoids most failures.
DIRECTX_NAME=directx_feb2010_redist.exe
DIRECTX_SHA256=f6d191e89a963d7cca34f169d30f49eab99c1ed3bb92da73ec43617caaa1e93f
DIRECTX_MIRRORS=(
    'https://proxy.usebottles.com/redistributable/dependencies/directx_feb2010_redist.exe'
    'https://files.holarse-linuxgaming.de/mirrors/microsoft/directx_feb2010_redist.exe'
    'https://web.archive.org/web/20100205000000id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe'
    'https://web.archive.org/web/20101224202650id_/http://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe'
    'https://web.archive.org/web/2016id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe'
)

GAME_DIR_ARG=""; SETUP_ARG=""; PREFIX_ARG=""; ASSUME_YES=0; REINSTALL_MOBOX=0; CMD_EXE=""
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
        printf 'AOE_PREFIX=%q\n'  "${AOE_PREFIX:-}"
        printf 'GAME_DIR=%q\n'    "${GAME_DIR:-}"
        printf 'GAME_DRIVE=%q\n'  "${GAME_DRIVE:-}"
        printf 'GAME_PATH=%q\n'   "${GAME_PATH:-}"
        printf 'AOK_REL=%q\n'     "${AOK_REL:-}"
        printf 'AOC_REL=%q\n'     "${AOC_REL:-}"
        printf 'VOOBLY_EXE=%q\n'  "${VOOBLY_EXE:-}"
    } >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# =============================================================================
#  Shared runtime (written to $LIB/env.sh, sourced by the installer AND by the
#  launcher, so there is one implementation of "run Mobox's Wine" and of
#  "free port 47624").
# =============================================================================
write_env_lib() {
    cat >"$LIB/env.sh.tmp" <<'ENVSH'
# shellcheck shell=bash
# Shared runtime for Mobox's Wine. Generated by aoe2-mobox-voobly.sh; rerun the
# installer to regenerate it.
: "${PREFIX:=/data/data/com.termux/files/usr}"
GLIBC="$PREFIX/glibc"
GLIBC_BIN="$GLIBC/bin"
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

# ------------------------------------------------------------ Mobox's Wine ---
mb_find_prefix() {
    local f
    f="$(find "$GLIBC/opt" "$HOME" -maxdepth 4 -name system.reg 2>/dev/null |
         grep -v -e '/opt/prefix/' -e '/backups/' | head -n1)"
    [ -n "$f" ] && dirname "$f"
}

# Same steps Mobox performs before each start: executable bits, patched box64,
# wine/wineserver links in $GLIBC_BIN.
mb_runtime() {
    chmod +x "$GLIBC_BIN/box64" "$WINE_PATH/bin/wine" "$WINE_PATH/bin/wineserver" 2>/dev/null
    if command -v patchelf >/dev/null 2>&1; then
        patchelf --force-rpath --set-rpath "$GLIBC/lib" \
            --set-interpreter "$GLIBC/lib/ld-linux-aarch64.so.1" "$GLIBC_BIN/box64" 2>/dev/null
    fi
    ln -sf "$WINE_PATH/bin/wine"       "$GLIBC_BIN/wine"
    ln -sf "$WINE_PATH/bin/wineserver" "$GLIBC_BIN/wineserver"
}

mb_env() {
    local w
    [ -x "$GLIBC_BIN/box64" ] || { aoe_warn "Box64 not found in $GLIBC_BIN; Mobox is not installed."; return 1; }
    # Reuse Mobox's own settings (dynarec variables, core pinning, renderer ...).
    if [ -r "$GLIBC/opt/scripts/configs" ]; then
        . "$GLIBC/opt/scripts/configs" >/dev/null 2>&1
        if type load_configs >/dev/null 2>&1; then load_configs >/dev/null 2>&1; fi
    fi
    [ -r "$AOE_STATE" ] && . "$AOE_STATE"
    [ -n "${AOE_PREFIX:-}" ] && WINEPREFIX="$AOE_PREFIX"
    if [ ! -x "${WINE_PATH:-/nonexistent}/bin/wine" ]; then
        w="$(find "$GLIBC" -maxdepth 4 -type f -path '*/bin/wine' 2>/dev/null |
             grep -v "^$GLIBC_BIN/" | head -n1)"
        [ -n "$w" ] && WINE_PATH="${w%/bin/wine}"
    fi
    [ -x "${WINE_PATH:-/nonexistent}/bin/wine" ] ||
        { aoe_warn "Cannot locate Mobox's Wine runner (WINE_PATH). Install one in: mobox > Manage packages."; return 1; }
    export WINEPREFIX WINE_PATH GLIBC_BIN
    export WINEARCH="${WINEARCH:-win64}" WINEDEBUG="${WINEDEBUG:--all}" BOX64_NOBANNER=1
    case ";${WINEDLLOVERRIDES:-};" in
        *";winemenubuilder.exe=d;"*) ;;
        *) export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}winemenubuilder.exe=d" ;;
    esac
    if [ -z "${AOE_RUNTIME_READY:-}" ]; then mb_runtime; export AOE_RUNTIME_READY=1; fi
    return 0
}

# Glibc binaries must not inherit Termux's bionic LD_PRELOAD (termux-exec).
mwine() {
    local pre=()
    if [ -n "${PRIMARY_CORES:-}" ] && command -v taskset >/dev/null 2>&1; then pre=(taskset -c "$PRIMARY_CORES"); fi
    env -u LD_PRELOAD "${pre[@]}" "$GLIBC_BIN/box64" "$GLIBC_BIN/wine" "$@"
}
mwineserver() {
    env -u LD_PRELOAD "$GLIBC_BIN/box64" "$GLIBC_BIN/wineserver" "$@"
}

# ---------------------------------------------------------- process control ---
mb_self_chain() {
    local p=${BASHPID:-$$}
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        echo "$p"
        p=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)
    done
    echo "$$"
}

# PIDs of Box64/Wine processes (this user) belonging to this container.
mb_wine_pids() {
    local d pid cmd pfx skip
    skip=" $(mb_self_chain | tr '\n' ' ') "
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$skip" in *" $pid "*) continue ;; esac
        [ -O "$d" ] || continue
        cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
        case "$cmd" in *box64*|*wineserver*) ;; *) continue ;; esac
        pfx=$(tr '\0' '\n' <"$d/environ" 2>/dev/null | grep -m1 '^WINEPREFIX=')
        if [ -n "$pfx" ] && [ "$pfx" != "WINEPREFIX=$WINEPREFIX" ]; then continue; fi
        echo "$pid"
    done
}

aoe_stop_wine() {
    local pid i
    bounded 20 mwineserver -k >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -z "$(mb_wine_pids)" ] && return 0
        sleep 0.5
    done
    for pid in $(mb_wine_pids); do kill -TERM "$pid" 2>/dev/null; done
    sleep 2
    for pid in $(mb_wine_pids); do kill -KILL "$pid" 2>/dev/null; done
    sleep 0.5
    [ -z "$(mb_wine_pids)" ]
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
        case " $(mb_self_chain | tr '\n' ' ') " in *" $pid "*) continue ;; esac
        [ -O "/proc/$pid" ] || continue
        aoe_say "  stopping pid $pid ($(cat "/proc/$pid/comm" 2>/dev/null || echo '?'))"
        kill -TERM "$pid" 2>/dev/null
    done
    sleep 1
    for pid in $(port_pids); do kill -KILL "$pid" 2>/dev/null; done
    # The owner may be invisible to us (Android hides sockets) or a wineserver
    # that inherited the socket: stopping this container's Wine always releases it.
    if port_busy; then
        aoe_say "  owner not visible; stopping all Wine processes of this container"
        aoe_stop_wine
    fi
    for i in 1 2 3 4 5 6; do port_busy || break; sleep 0.5; done
    if port_busy; then
        aoe_warn "Port $PORT is still busy (another app or a process of another user?)."
        return 1
    fi
    aoe_say "Port $PORT is free."
}

# ----------------------------------------------------- display / audio / GL ---
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

# Only relevant when Mobox is configured for VirGL (its config exports GALLIUM_DRIVER=virpipe).
aoe_virgl() {
    [ "${GALLIUM_DRIVER:-}" = virpipe ] || return 0
    command -v virgl_test_server_android >/dev/null 2>&1 || return 0
    pgrep -f virgl_test_server >/dev/null 2>&1 && return 0
    rm -f "$PREFIX/tmp/.virgl_test" 2>/dev/null
    (virgl_test_server_android >/dev/null 2>&1 &)
    sleep 1
}
ENVSH
    mv "$LIB/env.sh.tmp" "$LIB/env.sh"
}

# =============================================================================
#  Wrapper scripts + launcher
# =============================================================================
write_wrappers() {
    local name
    for name in wine wineserver; do
        cat >"$BIN/$name.tmp" <<'WRAP'
#!/data/data/com.termux/files/usr/bin/bash
# Wine/wineserver front-end for Mobox's Box64+Wine (used by winetricks).
AOE_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$AOE_BASE/lib/env.sh" || exit 1
mb_env || exit 1
name=${0##*/}
if [ "$name" = wineserver ]; then mwineserver "$@"; exit $?; fi
if [ "${1:-}" = --version ]; then
    out="$(mwine "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^wine-'; then printf '%s\n' "$out" | sed -n '/^wine-/p'; exit 0; fi
    printf '%s\n' "$out" >&2; exit "${rc:-1}"
fi
mwine "$@"
WRAP
        chmod 755 "$BIN/$name.tmp"; mv "$BIN/$name.tmp" "$BIN/$name"
    done
}

write_launcher() {
    cat >"$BIN/aoe2-voobly.tmp" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
# aoe2-voobly - start AoE II / Voobly in Mobox's Wine container.
# Every start first frees TCP/UDP 47624 so DirectPlay can host/join games.
AOE_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$AOE_BASE/lib/env.sh" || exit 1
mb_env || exit 1
GAME_PATH="${GAME_PATH:-${GAME_DRIVE^^}:}"

usage() {
    cat <<EOF
Usage: aoe2-voobly <command> [game arguments]
  voobly       start Voobly (log in, then launch games from Voobly)
  aoe2         start The Conquerors directly (-nostartup)
  aok          start the Age of Kings executable directly
  clear-port   free TCP/UDP $PORT now
  stop         stop every Wine process of this container
  status       show drive link, port and running processes
EOF
}

launch() {   # launch LABEL UNIX_EXE WIN_EXE [args...]
    local label=$1 exe=$2 winexe=$3 logf rc; shift 3
    [ -f "$exe" ] || { aoe_warn "Missing executable: $exe  (rerun the installer)"; exit 1; }
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$AOE_BASE/launch.lock"
        flock -n 9 || { aoe_warn "Another aoe2-voobly launch is still running. Close it, or run: aoe2-voobly stop"; exit 1; }
    fi
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
    aoe_port_clear || aoe_warn "Continuing with port $PORT busy; multiplayer may fail."
    aoe_display; aoe_audio; aoe_virgl
    mkdir -p "$AOE_BASE/logs"
    logf="$AOE_BASE/logs/$label-$(date +%Y%m%d-%H%M%S).log"
    cd "$(dirname "$exe")" || exit 1
    aoe_say "Starting $label. Log: $logf"
    aoe_say "Open the Termux:X11 app to see the window."
    trap 'aoe_stop_wine; command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock; exit 130' INT TERM
    mwine "$winexe" "$@" 9>&- >"$logf" 2>&1 &
    wait $!
    rc=$?
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
    aoe_say "$label exited with status $rc"
    [ "$rc" -eq 0 ] || tail -n 40 "$logf"
    exit "$rc"
}

cmd=${1:-help}; [ $# -gt 0 ] && shift
case "$cmd" in
    voobly)       launch voobly "$VOOBLY_EXE" "$VOOBLY_EXE" "$@" ;;
    aoe2|aoc)     launch aoe2 "$GAME_DIR/$AOC_REL" "$GAME_PATH\\${AOC_REL//\//\\}" -nostartup "$@" ;;
    aok)          launch aok "$GAME_DIR/$AOK_REL" "$GAME_PATH\\${AOK_REL//\//\\}" "$@" ;;
    clear-port)   aoe_port_clear ;;
    stop)         aoe_stop_wine && aoe_say "Wine processes of this container stopped." ;;
    status)
        aoe_say "Container : $WINEPREFIX"
        aoe_say "Game      : ${GAME_DIR:-?}  ->  ${GAME_PATH:-${GAME_DRIVE:-?}:}"
        aoe_say "Voobly    : ${VOOBLY_EXE:-not installed}"
        if port_busy; then aoe_say "Port $PORT : IN USE ($(port_pids | tr '\n' ' ')owner may be hidden by Android)"
        else aoe_say "Port $PORT : free"; fi
        aoe_say "Wine pids : $(mb_wine_pids | tr '\n' ' ')"
        ;;
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
    case "$(uname -m)" in aarch64|arm64) ;; *) die "Mobox needs an ARM64 device (found $(uname -m))." ;; esac
    command -v pkg >/dev/null 2>&1 || die "Termux 'pkg' not found."

    if [ ! -d "$HOME/storage/shared" ]; then
        say "Android storage access is needed for the game folder. Accept the permission dialog."
        termux-setup-storage
        local i
        for i in $(seq 1 60); do [ -d "$HOME/storage/shared" ] && break; sleep 1; done
        [ -d "$HOME/storage/shared" ] || die "Storage permission was not granted."
    fi

    local need=() c
    for c in curl:curl cabextract:cabextract pgrep:procps lsof:lsof taskset:util-linux flock:util-linux; do
        command -v "${c%%:*}" >/dev/null 2>&1 || need+=("${c##*:}")
    done
    if [ ${#need[@]} -gt 0 ]; then
        say "Installing: $(printf '%s\n' "${need[@]}" | sort -u | tr '\n' ' ')"
        # shellcheck disable=SC2046
        pkg install -y $(printf '%s\n' "${need[@]}" | sort -u) 2>&1 | tee -a "$LOG"
    fi
    command -v curl >/dev/null 2>&1 || die "curl is required."
    command -v python3 >/dev/null 2>&1 ||
        warn "python3 not installed: port checks fall back to lsof/TCP probing (pkg install python makes them exact)."
    ok "Termux, ARM64 and storage access look fine."
}

mobox_present() { [ -f "$GLIBC/opt/scripts/mobox" ] && [ -x "$GLIBC_BIN/box64" ]; }

stage_mobox() {
    stage 2 "Install Mobox (Box64 + Wine 9.3 wow64)"
    if mobox_present && [ "$REINSTALL_MOBOX" != 1 ]; then
        ok "Mobox already installed in $GLIBC; reusing it."
        return 0
    fi
    local f="$CACHE/mobox-install" wipe=0
    say "Downloading the official Mobox installer (archived upstream project)."
    curl -fsSL "$MOBOX_INSTALL_URL" -o "$f.part" || die "Could not download $MOBOX_INSTALL_URL"
    mv "$f.part" "$f"
    local sum; sum="$(sha_of "$f")"
    say "Installer SHA256: $sum"
    if [ -n "$MOBOX_INSTALL_SHA256" ] && [ "$sum" != "$MOBOX_INSTALL_SHA256" ]; then
        die "Installer checksum differs from MOBOX_INSTALL_SHA256; refusing to run it."
    fi
    bash -n "$f" || die "Downloaded installer is not valid shell."
    if [ -e "$GLIBC" ]; then
        warn "$GLIBC exists. Mobox's installer deletes it, INCLUDING all Wine containers inside."
        say  "Back up first if needed: run 'mobox' > Backup and restore."
        yes_no "Delete $GLIBC and reinstall Mobox?" n || die "Cancelled."
        wipe=1
    fi
    warn "Mobox's installer downloads scripts and binaries from GitLab and cannot be verified here."
    yes_no "Run the Mobox installer now (it upgrades Termux packages; can take several minutes)?" y || die "Cancelled."
    # The installer asks "Removing previous glibc" and "Selected number" on stdin, but its
    # package commands read stdin as well and can swallow an answer before the question is
    # asked (leaving the prompt at EOF). Do the removal here - the same delete, after the
    # same confirmation - and answer the one remaining question with a tape of choices.
    if [ "$wipe" = 1 ]; then
        say "Removing $GLIBC ..."
        rm -rf "$GLIBC" || die "Could not remove $GLIBC."
    fi
    say "Selecting option 2 (wow64 build) automatically ..."
    { ( cd "$HOME" && export DEBIAN_FRONTEND=noninteractive && . "$f" ) < <(printf '2\n%.0s' {1..64}); } 2>&1 | tee -a "$LOG"
    hash -r
    mobox_present ||
        die "Mobox did not install correctly (no $GLIBC_BIN/box64); the log shows where its installer stopped."
    ok "Mobox installed."
}

stage_runtime() {
    stage 3 "Locate Mobox's Wine and its container"
    write_env_lib
    AOE_BASE=$BASE; export AOE_BASE
    # shellcheck disable=SC1091
    . "$LIB/env.sh"
    if [ -n "$PREFIX_ARG" ]; then AOE_PREFIX=$(clean_path "$PREFIX_ARG"); save_state; fi
    mb_env || die "Mobox runtime not usable."

    local tries=0 p
    while [ ! -f "${WINEPREFIX:-/nonexistent}/system.reg" ]; do
        p="$(mb_find_prefix)"
        if [ -n "$p" ]; then WINEPREFIX=$p; export WINEPREFIX; break; fi
        tries=$((tries + 1))
        [ "$tries" -le 3 ] || die "Mobox's Wine container still does not exist."
        warn "Mobox has not created its Wine container yet."
        cat <<'MSG'
  One-time step (Mobox sets up fonts, services and DirectX files on first start):
    1. Open another Termux session and type:  mobox
    2. Start Wine (open the Termux:X11 app); wait until the Wine desktop appears.
    3. Close Wine / return to Termux, then come back here.
MSG
        ask "Press Enter when the Wine desktop has appeared and was closed" ""
        mb_env || die "Mobox runtime not usable."
    done
    AOE_PREFIX=$WINEPREFIX; save_state
    say "Container : $WINEPREFIX"
    say "Wine      : $WINE_PATH"

    local arch; arch="$(grep -m1 '^#arch=' "$WINEPREFIX/system.reg" | cut -d= -f2)"
    [ "$arch" = win64 ] || die "Container is '$arch'. The wow64 build needs a win64 prefix: rerun with --reinstall-mobox and pick the wow64 build."

    local ver; ver="$(bounded 180 mwine --version 2>&1 | grep -m1 '^wine-')"
    [ -n "$ver" ] || die "Wine does not start through Box64. Try 'mobox' once, then rerun. See the log."
    ok "Wine runs: $ver"
    local out
    out="$(bounded 300 mwine "$WINEPREFIX/drive_c/windows/syswow64/cmd.exe" /d /c 'echo WIN32_APP_OK' 2>&1)"
    printf '%s\n' "$out" >>"$LOG"
    [[ "$out" == *WIN32_APP_OK* ]] || die "A 32-bit Windows program did not run in this container."
    ok "32-bit Windows programs run (needed for AoE II and Voobly)."
}

pick_drive() {   # echo free-or-existing drive letter pointing at $GAME_DIR
    local dev="$WINEPREFIX/dosdevices" l link game
    game="$(readlink -f "$GAME_DIR")"
    mkdir -p "$dev"
    for l in g h i j k l m n o p q r s t u v w x y; do
        link="$dev/$l:"
        if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$game" ]; then echo "$l"; return 0; fi
    done
    for l in g h i j k l m n o p q r s t u v w x y; do
        link="$dev/$l:"
        if [ ! -e "$link" ] && [ ! -L "$link" ]; then
            ln -s "$game" "$link" && { echo "$l"; return 0; }
        fi
    done
    return 1
}

wine_cmd_exe() {   # absolute cmd.exe: bare 'wine cmd' does not resolve in every container
    local c
    for c in "$WINEPREFIX/drive_c/windows/system32/cmd.exe" \
             "$WINEPREFIX/drive_c/windows/syswow64/cmd.exe"; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

drive_visible() {   # drive_visible "G:"   (quote-free on purpose: Wine/cmd quoting disagree)
    local out rc first
    out="$(bounded 120 mwine "$CMD_EXE" /d /c cd /d "$1" '&&' echo AOE_DRIVE_OK 2>&1)"; rc=$?
    printf 'drive probe %s (rc=%s): %s\n' "$1" "$rc" "$out" >>"$LOG"
    [[ "$out" == *AOE_DRIVE_OK* ]] && return 0
    first="$(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-200)"
    say "  probe $1 -> ${first:-no output} (status $rc)"
    return 1
}

wine_win_path() {   # echo the Windows path Wine gives the Unix directory $1 (e.g. Y:\)
    local out
    out="$( cd "$1" 2>/dev/null && bounded 120 mwine "$CMD_EXE" /d /c cd 2>&1 )"
    printf 'windows path of %s: %s\n' "$1" "$out" >>"$LOG"
    printf '%s\n' "$out" | tr -d '\r' | grep -m1 -E '^[A-Za-z]:' || true
}

stage_game() {
    stage 4 "Link the AoE II game folder into the container"
    local default d aok aoc
    default="${GAME_DIR:-$HOME/storage/shared/Games/Age of Empires II}"
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
    case "$GAME_DIR/" in "$WINEPREFIX"/*) die "The game folder must not be inside the Wine container." ;; esac
    case "$WINEPREFIX/" in "$GAME_DIR"/*) die "The Wine container must not be inside the game folder." ;; esac

    aok="$(find_ci "$GAME_DIR" age2.exe 3)"; [ -n "$aok" ] || aok="$(find_ci "$GAME_DIR" empires2.exe 3)"
    aoc="$(find_ci "$GAME_DIR" age2_x1.exe 3)"; [ -n "$aoc" ] || aoc="$(find_ci "$GAME_DIR" age2x1.exe 3)"
    [ -n "$aok" ] && [ -n "$aoc" ] ||
        die "Need empires2.exe (or age2.exe) AND age2_x1.exe (or age2x1.exe) in $GAME_DIR (original Age of Kings + Conquerors)."
    [ "$(pe_machine "$aok")" = i386 ] && [ "$(pe_machine "$aoc")" = i386 ] ||
        die "Expected the original 32-bit game executables (not HD/Definitive Edition)."
    AOK_REL="${aok#"$GAME_DIR"/}"; AOC_REL="${aoc#"$GAME_DIR"/}"

    local letter drive attempt visible=0
    CMD_EXE="$(wine_cmd_exe)" || die "No cmd.exe in $WINEPREFIX/drive_c/windows; the container looks incomplete."
    letter="$(pick_drive)" || die "No free Wine drive letter (g: to y:)."
    drive="${letter^^}:"
    for attempt in 1 2 3; do
        if drive_visible "$drive"; then visible=1; break; fi
        # A running wineserver keeps the drive list it started with.
        bounded 30 mwineserver -k >/dev/null 2>&1; bounded 45 mwineserver -w >/dev/null 2>&1
    done
    if [ "$visible" = 1 ]; then
        GAME_DRIVE=$letter; GAME_PATH="$drive"
        ok "$drive  ->  $GAME_DIR"
    else
        # Do not stop here: Wine itself decides how the folder is addressed.
        warn "Wine did not accept $drive; asking Wine how it sees the folder instead."
        GAME_PATH="$(wine_win_path "$GAME_DIR")"
        [ -n "$GAME_PATH" ] ||
            die "Wine cannot reach $GAME_DIR. Check that the folder is readable (termux-setup-storage) and rerun; see $LOG."
        GAME_DRIVE="${GAME_PATH:0:1}"; GAME_DRIVE="${GAME_DRIVE,,}"
        warn "Using $GAME_PATH for the game folder (same files, different drive letter)."
    fi
    save_state
    say "Conquerors: ${GAME_PATH}\\${AOC_REL//\//\\}"

    if yes_no "Back up the game folder before Voobly can patch it? (optional, needs free space)" n; then
        local need free target="$GAME_DIR.backup-$STAMP"
        need=$(du -sk "$GAME_DIR" 2>/dev/null | cut -f1)
        free=$(df -Pk "$(dirname "$GAME_DIR")" 2>/dev/null | awk 'NR==2{print $4}')
        if [ -n "$need" ] && [ -n "$free" ] && [ "$free" -gt $((need + 524288)) ]; then
            cp -a "$GAME_DIR" "$target" && ok "Backup: $target"
        else
            warn "Not enough free space for a backup; skipped."
        fi
    fi
}

directplay_ready() {
    local sys="$WINEPREFIX/drive_c/windows/syswow64" f out
    for f in "${DIRECTPLAY_FILES[@]}"; do [ "$(pe_machine "$sys/$f")" = i386 ] || return 1; done
    out="$(bounded 60 mwine reg query 'HKCU\Software\Wine\DllOverrides' 2>/dev/null)"
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
    stage 5 "Install native DirectPlay"
    if directplay_ready; then ok "Native DirectPlay is already installed."; return 0; fi
    yes_no "Close this container's Wine apps and install native DirectPlay now?" y || die "DirectPlay is required for multiplayer."
    install_winetricks
    aoe_stop_wine
    if yes_no "Back up the Wine container first? (optional, can be large)" n; then
        local target="$BASE/backups/$(basename "$WINEPREFIX")-before-directplay-$STAMP"
        mkdir -p "$BASE/backups"; cp -a "$WINEPREFIX" "$target" && ok "Backup: $target"
    fi
    write_wrappers
    seed_redist || warn "DirectX redist not pre-fetched; winetricks will try archive.org itself (often 503)."
    local attempt rc=1
    for attempt in 1 2 3; do
        say "winetricks directplay (attempt $attempt/3, several minutes; output goes to the log) ..."
        timeout 1800 env WINE="$BIN/wine" WINESERVER="$BIN/wineserver" WINEPREFIX="$WINEPREFIX" \
            WINEARCH=win64 WINE_BIN="$WINE_PATH/bin/wine" WINESERVER_BIN="$WINE_PATH/bin/wineserver" \
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
        bounded 60 mwine reg delete 'HKCU\Software\Wine\DllOverrides' /v "$v" /f >/dev/null 2>&1
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
        aoe_display; aoe_audio; aoe_virgl
        if ! x11_ready; then
            warn "No X11 display answers on DISPLAY=:0, so Wine cannot open windows."
            say  "Open the Termux:X11 app and leave its window in front, then answer y."
            yes_no "Start the Voobly installer anyway?" y || die "Cancelled; rerun once Termux:X11 shows a window."
        fi
        local ilog="$LOGS/voobly-setup-$STAMP.log" rc=1 attempt
        for attempt in 1 2; do
            say "Running the Voobly installer (attempt $attempt/2) ..."
            : >"$ilog"
            ( cd "$(dirname "$setup")" && mwine "$setup" ) >>"$ilog" 2>&1; rc=$?
            bounded 300 mwine wineboot -u >>"$LOG" 2>&1
            found="$(find_ci "$WINEPREFIX/drive_c" voobly.exe 8)"
            [ -n "$found" ] && break
            [ "$rc" -eq 0 ] && break
            [ "$attempt" -lt 2 ] && { warn "Installer stopped early (status $rc); retrying once."; sleep 5; }
        done
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
    write_wrappers
    write_launcher
    save_state
    ok "Command installed: aoe2-voobly  ($PREFIX/bin/aoe2-voobly)"
}

stage_final() {
    stage 8 "Final checks"
    mb_env
    say "Port check (the launcher repeats this before every start) ..."
    aoe_port_clear || warn "Port $PORT is busy and its owner could not be stopped."
    if yes_no "Open Voobly now for a smoke test?" y; then
        "$BIN/aoe2-voobly" voobly
    fi

    local gp="${GAME_PATH:-${GAME_DRIVE^^}:}" aoc_dir="" inst_dir
    case "$AOC_REL" in */*) aoc_dir="${AOC_REL%/*}" ;; esac
    inst_dir="$gp"; [ -n "$aoc_dir" ] && inst_dir="$gp\\${aoc_dir//\//\\}"
    cat <<EOF

$(_c '1;32')INSTALLATION PREPARED$(_c 0)
  Container : $WINEPREFIX
  Game      : $GAME_DIR  ->  $gp
  Voobly    : $VOOBLY_EXE
  Log       : $LOG

Commands
  aoe2-voobly voobly      start Voobly
  aoe2-voobly aoe2        start The Conquerors directly
  aoe2-voobly clear-port  free TCP/UDP $PORT
  aoe2-voobly stop        stop all Wine processes of this container
  aoe2-voobly status

In Voobly (Game Diagnostics / settings)
  Installation directory : $inst_dir
  Executable             : $gp\\${AOC_REL//\//\\}
  If Voobly does not list ${gp:0:1}: its Browse dialog shows every drive Wine knows about.

Tips for multiplayer
  - Always start through 'aoe2-voobly ...'; it frees port $PORT first. Never open a second
    copy while one runs (a DirectPlay helper owning $PORT during a match is normal).
  - Keep Termux awake (the launcher takes a wake lock) and disable battery optimisation for
    Termux and Termux:X11, otherwise Android may kill them mid-match.
  - Test v1.5 first, then the matching v1.6 RC + game data separately.
  - Back up the container and game folder once a real two-player match works.
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --game)            [ $# -ge 2 ] || die "--game needs a directory"; GAME_DIR_ARG=$2; shift 2 ;;
            --voobly-setup)    [ $# -ge 2 ] || die "--voobly-setup needs a file"; SETUP_ARG=$2; shift 2 ;;
            --prefix)          [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX_ARG=$2; shift 2 ;;
            --yes|-y)          ASSUME_YES=1; shift ;;
            --reinstall-mobox) REINSTALL_MOBOX=1; shift ;;
            -h|--help)         sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

main() {
    parse_args "$@"
    : >"$LOG"
    trap 'printf "\nCancelled. Completed stages are skipped on the next run.\n"; exit 130' INT
    printf '%s\n' "Age of Empires II  x  Voobly  ->  Mobox (Termux)"
    stage_preflight
    stage_mobox
    stage_runtime
    stage_game
    stage_directplay
    stage_voobly
    stage_launchers
    stage_final
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi