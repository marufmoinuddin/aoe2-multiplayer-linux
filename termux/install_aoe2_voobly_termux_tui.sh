#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  AoE II + Voobly  -  Interactive TUI Installer   (Termux / Android ARM64)
#  Patched x86-64 Wine (Termux glibc build)  +  Box64   --  NATIVE, no proot
#
#  How it works (no proot, no chroot, nothing compiled):
#    * Termux's official glibc repo (glibc-repo) provides box64-glibc and
#      glibc-runner, so glibc programs run natively in Termux.
#    * Stock x86-64 Wine cannot run here (it hardcodes /tmp, which Android does
#      not have, and its memory layout code aborts on Android's address space),
#      so the installer uses Waim908/wine-termux prebuilt Wine, which is patched
#      for Termux glibc + Box64.
#    * Libraries Box64 cannot wrap natively come as x86-64 .deb files from
#      Debian, unpacked in Python into $BASE/x64lib (no root needed).
#
#  Optional overrides:
#    AOE_WINE_TAG=10.15-mfdxgi       release tag of Waim908/wine-termux
#    AOE_WINE_ASSET=<file.tar.xz>    asset name (default derived from the tag)
#    AOE_WINE_URL=<url>              full download URL (wins over the two above)
#    AOE_X64_SUITE=bookworm          Debian suite for the x86-64 helper libraries
#    AOE_X64_MIRROR=https://deb.debian.org/debian
# =============================================================================
set -o pipefail

# ------------------------------------------------------------------ constants
: "${PREFIX:=/data/data/com.termux/files/usr}"
BASE="${AOE2_TUI_HOME:-$HOME/.local/share/aoe2-tui}"
LIB="$BASE/lib"; BIN="$BASE/bin"; LOGS="$BASE/logs"; CACHE="$BASE/cache"; TOOLS="$BASE/tools"
X64_DIR="$BASE/x64lib"
STATE="$BASE/state.env"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGS/install-$STAMP.log"
mkdir -p "$LIB" "$BIN" "$LOGS" "$CACHE" "$TOOLS"

# Wine patched for Termux glibc + Box64 (x86-64, wow64: runs 32-bit games without 32-bit libs)
WINE_TAG="${AOE_WINE_TAG:-10.15-mfdxgi}"
WINE_ASSET="${AOE_WINE_ASSET:-wine-${WINE_TAG}-tkg-stg-ge.tar.xz}"
WINE_URL="${AOE_WINE_URL:-https://github.com/Waim908/wine-termux/releases/download/${WINE_TAG}/${WINE_ASSET}}"
WINE_INSTALL_DIR="$BASE/wine"

WINETRICKS_URL="https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"

X64_MIRROR="${AOE_X64_MIRROR:-https://deb.debian.org/debian}"
X64_SUITE="${AOE_X64_SUITE:-bookworm}"

# x86-64 helper libraries pulled from Debian (dependencies are resolved automatically;
# libc6 is deliberately skipped: Box64 provides libc/libm/libdl/libpthread itself)
X64_ROOTS="libx11-6 libxext6 libxrandr2 libxcursor1 libxi6 libxrender1 libxfixes3 \
libxcomposite1 libxinerama1 libxxf86vm1 libxkbcommon0 libxcb1 libfreetype6 libfontconfig1 \
libpulse0 libasound2 libpng16-16 libjpeg62-turbo zlib1g libunwind8 libgnutls30 libstdc++6 libgcc-s1"

# Native (aarch64, glibc) libraries from Termux's glibc repo that Box64 can wrap
NATIVE_RE='^(libx11|libxcb|libxau|libxdmcp|libxext|libxrandr|libxcursor|libxi|libxrender|libxfixes|libxcomposite|libxinerama|libxxf86vm|libxkbcommon|freetype|fontconfig|pulseaudio|libpulse|alsa-lib|libpng|libjpeg|zlib|gnutls|libunwind)'

# Emulator: Box64 only (native Termux)
EMULATOR="box64"

# Game / Voobly
GAME_DIR=""; GAME_MODE="keep"; GAME_ORIG=""; GAME_SRC=""; GAME_DRIVE=""; GAME_PATH=""
AOK_REL=""; AOC_REL=""; VOOBLY_EXE=""
AOE_PREFIX=""; AOE_RES="none"
WANT_DIRECTPLAY=0

# ------------------------------------------------------------------ TUI helpers
DIALOG=""
pick_dialog() {
    if command -v whiptail >/dev/null 2>&1; then DIALOG=whiptail
    elif command -v dialog  >/dev/null 2>&1; then DIALOG=dialog
    fi
}
pick_dialog
if [ -z "$DIALOG" ] && command -v pkg >/dev/null 2>&1; then
    echo "Installing 'dialog' (needed for the TUI) ..." >&2
    pkg install -y dialog >&2 || true
    pick_dialog
fi
[ -n "$DIALOG" ] || { echo "This script needs whiptail or dialog.  Run: pkg install dialog" >&2; exit 1; }

# Every dialog call goes through this helper: the answer comes back on stdout.
ui() { "$DIALOG" "$@" 3>&1 1>&2 2>&3; }

msg()   { ui --title "$1" --msgbox "$2" 15 70; }
yesno() { ui --title "$1" --yesno "$2" 12 70; }
input() { ui --title "$1" --inputbox "$2" 10 70 "$3"; }
menu()  { ui --title "$1" --menu "$2" 22 78 12 "${@:3}"; }

say()  { printf '\033[36m%s\033[0m\n' "$*"; printf '%s\n' "$*" >>"$LOG"; }
ok()   { printf '\033[32m[ok] %s\033[0m\n' "$*"; printf 'OK: %s\n' "$*" >>"$LOG"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; printf 'WARN: %s\n' "$*" >>"$LOG"; }
# die only leaves the current stage (every stage runs in a subshell, see run_stage)
die()  { printf '\033[31m[fail] %s\033[0m\nLog: %s\n' "$*" "$LOG" >&2; printf 'FATAL: %s\n' "$*" >>"$LOG"; exit 1; }

clean_path() { local p=$1; p=${p#\"}; p=${p%\"}; p=${p#\'}; p=${p%\'}; p=${p/#\~/$HOME}; printf '%s' "$p"; }

# ------------------------------------------------------------ file inspection
pe_machine() {
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

find_ci() {
    find "$1" -maxdepth "${3:-3}" -type f -iname "$2" 2>/dev/null |
        awk '{ print length($0) "\t" $0 }' | sort -n | cut -f2- | head -n1
}

# ------------------------------------------------------------ state
save_state() {
    {
        printf 'WINE_INSTALL_DIR=%q\n' "${WINE_INSTALL_DIR:-}"
        printf 'EMULATOR=%q\n'        "box64"
        printf 'AOE_PREFIX=%q\n'      "${AOE_PREFIX:-}"
        printf 'AOE_RES=%q\n'         "${AOE_RES:-none}"
        printf 'GAME_DIR=%q\n'        "${GAME_DIR:-}"
        printf 'GAME_MODE=%q\n'       "${GAME_MODE:-keep}"
        printf 'GAME_ORIG=%q\n'       "${GAME_ORIG:-}"
        printf 'GAME_SRC=%q\n'        "${GAME_SRC:-}"
        printf 'GAME_DRIVE=%q\n'      "${GAME_DRIVE:-}"
        printf 'GAME_PATH=%q\n'       "${GAME_PATH:-}"
        printf 'AOK_REL=%q\n'         "${AOK_REL:-}"
        printf 'AOC_REL=%q\n'         "${AOC_REL:-}"
        printf 'VOOBLY_EXE=%q\n'      "${VOOBLY_EXE:-}"
        printf 'WANT_DIRECTPLAY=%q\n' "${WANT_DIRECTPLAY:-0}"
    } >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

load_state() {
    # shellcheck disable=SC1090
    [ -r "$STATE" ] && . "$STATE"
    EMULATOR=box64                       # old states may still say "fex"
    : "${AOE_PREFIX:=$BASE/prefix}"
    : "${WINE_INSTALL_DIR:=$BASE/wine}"
    return 0
}

# =============================================================================
#  Shared runtime (env.sh): runs Wine through native glibc Box64
# =============================================================================
write_env_lib() {
    cat >"$LIB/env.sh.tmp" <<'ENVSH'
: "${PREFIX:=/data/data/com.termux/files/usr}"
PORT=47624
AOE_STATE="${AOE_BASE:?AOE_BASE must be set}/state.env"
AOE_X64="$AOE_BASE/x64lib"
AOE_BOX64_MODE=""; AOE_BOX64_BIN=""

aoe_say()  { printf '%s\n' "$*"; }
aoe_warn() { printf 'warning: %s\n' "$*" >&2; }

bounded() {
    local secs=$1 pid i; shift
    "$@" &
    pid=$!
    for ((i = 0; i < secs * 2; i++)); do
        kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }
        sleep 0.5
    done
    kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124
}

# ---- Box64 (glibc build from Termux's glibc-repo), run natively --------------
# Termux exports LD_PRELOAD=libtermux-exec.so (a bionic library) which breaks
# glibc programs, so the emulator is always started with LD_PRELOAD removed.
# LD_LIBRARY_PATH is removed too: it would leak into the Android tools Box64
# itself starts (for example lscpu) and break them.
# Builds the AOE_EMU array.  Tries the binary directly first, then via grun.
aoe_emu_build() {
    AOE_EMU=()
    [ "${EMULATOR:-box64}" = box64 ] || return 1
    local b
    if [ -z "$AOE_BOX64_MODE" ]; then
        for b in "$PREFIX/glibc/bin/box64" "$(command -v box64 2>/dev/null)"; do
            [ -n "$b" ] && [ -x "$b" ] || continue
            if env -u LD_PRELOAD -u LD_LIBRARY_PATH "$b" --version >/dev/null 2>&1; then
                AOE_BOX64_MODE=direct; AOE_BOX64_BIN=$b; break
            elif command -v grun >/dev/null 2>&1 && grun "$b" --version >/dev/null 2>&1; then
                AOE_BOX64_MODE=grun; AOE_BOX64_BIN=$b; break
            fi
        done
    fi
    case "$AOE_BOX64_MODE" in
        direct) AOE_EMU=(env -u LD_PRELOAD -u LD_LIBRARY_PATH "$AOE_BOX64_BIN") ;;
        grun)   AOE_EMU=(grun "$AOE_BOX64_BIN") ;;
        *) return 1 ;;
    esac
}

aoe_emulator_cmd() { aoe_emu_build 2>/dev/null && printf '%s' "${AOE_EMU[*]}"; }

hf_env() {
    local want_res=${AOE_RES:-} fc="$AOE_BASE/fonts.conf" x64dirs=""
    # shellcheck disable=SC1090
    [ -r "$AOE_STATE" ] && . "$AOE_STATE"
    [ -n "$want_res" ] && AOE_RES=$want_res
    AOE_RES=${AOE_RES:-none}
    EMULATOR=box64
    WINE_INSTALL_DIR="${WINE_INSTALL_DIR:-$AOE_BASE/wine}"
    [ -x "$WINE_INSTALL_DIR/bin/wine" ] || { aoe_warn "Wine not found in $WINE_INSTALL_DIR"; return 1; }
    unset WINEARCH WINELOADER WINESERVER WINEDLLPATH HODLL64
    export WINEPREFIX="${AOE_PREFIX:-$AOE_BASE/prefix}"
    export WINE_INSTALL_DIR
    export USER="${USER:-$(id -un 2>/dev/null)}" LOGNAME="${LOGNAME:-$(id -un 2>/dev/null)}"
    mkdir -p "$PREFIX/tmp"      # the patched Wine keeps its server directory here

    if [ -r "$AOE_X64/libdirs.txt" ]; then
        x64dirs=$(tr '\n' ':' <"$AOE_X64/libdirs.txt"); x64dirs=${x64dirs%:}
    else
        x64dirs="$AOE_X64/usr/lib/x86_64-linux-gnu:$AOE_X64/lib/x86_64-linux-gnu"
    fi
    export BOX64_NOBANNER="${BOX64_NOBANNER:-1}"
    export BOX64_LOG="${BOX64_LOG:-0}"
    export BOX64_PATH="${BOX64_PATH:-$WINE_INSTALL_DIR/bin}"
    export BOX64_LD_LIBRARY_PATH="${BOX64_LD_LIBRARY_PATH:-$WINE_INSTALL_DIR/lib:$WINE_INSTALL_DIR/lib/wine/x86_64-unix:$x64dirs}"
    export BOX64_DYNAREC_BIGBLOCK="${BOX64_DYNAREC_BIGBLOCK:-3}"
    export BOX64_DYNAREC_FORWARD="${BOX64_DYNAREC_FORWARD:-512}"
    export BOX64_DYNAREC_CALLRET="${BOX64_DYNAREC_CALLRET:-1}"

    [ -f "$fc" ] || printf '<?xml version="1.0"?>\n<!DOCTYPE fontconfig SYSTEM "fonts.dtd">\n<fontconfig><dir>%s/share/fonts</dir><cachedir>%s/fc-cache</cachedir></fontconfig>\n' "$PREFIX" "$AOE_BASE" >"$fc"
    export FONTCONFIG_FILE="$fc"

    export DISPLAY=:0 XDG_RUNTIME_DIR="${TMPDIR:-$PREFIX/tmp}"
    export LIBGL_ALWAYS_SOFTWARE=true GALLIUM_DRIVER=llvmpipe
    export WINEDLLOVERRIDES='*ddraw,*d3d9,*d3d10core,*d3d11,*dxgi=b'
    export WINEDEBUG="${AOE_WINEDEBUG:--all,err+all,warn+module}"
    return 0
}

hwine() {
    aoe_emu_build || { aoe_warn "Box64 is not usable (run menu item 2)"; return 1; }
    "${AOE_EMU[@]}" "$WINE_INSTALL_DIR/bin/wine" "$@"
}

# Voobly is a Delphi program and Box64's dynamic recompiler miscompiles it: the
# installer aborts with a Delphi exception (EAbstractError, 0x0EEDFADE) and leaves
# no voobly.exe behind. The interpreter executes the same code correctly, only
# slower. BOX64_RCFILE=/dev/null stops a box64rc from re-enabling dynarec, and the
# subshell keeps the setting away from anything started later (the game runs on
# dynarec, and Wine passes the environment down to its child processes).
hwine_interp() {
    aoe_emu_build || { aoe_warn "Box64 is not usable (run menu item 2)"; return 1; }
    ( export BOX64_DYNAREC=0 BOX64_RCFILE=/dev/null
      "${AOE_EMU[@]}" "$WINE_INSTALL_DIR/bin/wine" "$@" )
}

hwineserver() {
    aoe_emu_build || return 1
    "${AOE_EMU[@]}" "$WINE_INSTALL_DIR/bin/wineserver" "$@"
}

hf_self_chain() {
    local p=${BASHPID:-$$}
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do echo "$p"; p=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null); done
    echo "$$"
}

hf_wine_pids() {
    local d pid cmd skip want="WINEPREFIX=$WINEPREFIX"
    skip=" $(hf_self_chain | tr '\n' ' ') "
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}; case "$skip" in *" $pid "*) continue ;; esac
        [ -O "$d" ] || continue
        cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
        case "$cmd" in *[Ww]ine*|*.[Ee][Xx][Ee]*) ;; *) continue ;; esac
        tr '\0' '\n' <"$d/environ" 2>/dev/null | grep -qxF "$want" && echo "$pid"
    done
}

aoe_stop_wine() {
    local pid
    bounded 20 hwineserver -k >/dev/null 2>&1
    bounded 25 hwineserver -w >/dev/null 2>&1
    pkill -TERM -f "$WINE_INSTALL_DIR/bin/" 2>/dev/null; sleep 1
    [ -z "$(hf_wine_pids)" ] && ! pgrep -f "$WINE_INSTALL_DIR/bin/" >/dev/null 2>&1 && return 0
    for pid in $(hf_wine_pids); do kill -TERM "$pid" 2>/dev/null; done; sleep 2
    for pid in $(hf_wine_pids); do kill -KILL "$pid" 2>/dev/null; done
    pkill -KILL -f "$WINE_INSTALL_DIR/bin/" 2>/dev/null; sleep 0.5
    [ -z "$(hf_wine_pids)" ] && ! pgrep -f "$WINE_INSTALL_DIR/bin/" >/dev/null 2>&1
}

port_pids() {
    { command -v lsof >/dev/null 2>&1 && lsof -t -i ":$PORT" 2>/dev/null
      command -v ss >/dev/null 2>&1 && ss -H -lntup "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2
      if command -v fuser >/dev/null 2>&1; then fuser -n tcp "$PORT" 2>/dev/null; fuser -n udp "$PORT" 2>/dev/null; fi
    } | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u
}

port_busy() {
    [ -n "$(port_pids)" ] && return 0
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import socket,sys; p=int(sys.argv[1]); [ (lambda s: (s.bind(("0.0.0.0",p)), s.close()))(socket.socket(socket.AF_INET,k)) for k in (socket.SOCK_STREAM,socket.SOCK_DGRAM) ]' "$PORT" 2>/dev/null
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
        kill -TERM "$pid" 2>/dev/null
    done; sleep 1
    for pid in $(port_pids); do kill -KILL "$pid" 2>/dev/null; done
    if port_busy; then aoe_say "  stopping all Wine processes of this prefix"; aoe_stop_wine; fi
    for i in 1 2 3 4 5 6; do port_busy || break; sleep 0.5; done
    if port_busy; then aoe_warn "Port $PORT still busy."; return 1; fi
    aoe_say "Port $PORT is free."
}

x11_ready() {
    local sock
    for sock in "${XDG_RUNTIME_DIR:-$PREFIX/tmp}/.X11-unix/X0" "$PREFIX/tmp/.X11-unix/X0"; do [ -S "$sock" ] && return 0; done
    command -v xrandr >/dev/null 2>&1 || return 0
    bounded 10 xrandr >/dev/null 2>&1
}

aoe_display() {
    export XDG_RUNTIME_DIR="${TMPDIR:-$PREFIX/tmp}" DISPLAY=:0
    if ! pgrep -f 'app_process / com.termux.x11' >/dev/null 2>&1; then
        command -v termux-x11 >/dev/null 2>&1 || { aoe_warn "termux-x11 missing (pkg install x11-repo termux-x11-nightly)"; return 1; }
        (termux-x11 :0 >/dev/null 2>&1 &)
    fi
    am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || aoe_warn "Could not open Termux:X11 (is the Termux:X11 app installed?)"
    local i; for i in $(seq 1 30); do x11_ready && return 0; sleep 1; done
    return 1
}

aoe_audio() {
    command -v pulseaudio >/dev/null 2>&1 || return 0
    pgrep -x pulseaudio >/dev/null 2>&1 || pulseaudio --start --exit-idle-time=-1 --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" >/dev/null 2>&1
    export PULSE_SERVER="${PULSE_SERVER:-127.0.0.1}"
}

aoe_desktop_arg() { case "${AOE_RES:-none}" in none|off|windowed|"") return 0;; *) printf '/desktop=%s,%s' "$1" "$AOE_RES";; esac; }

AOE_SU_OPT=""; AOE_SU_PROBED=""
aoe_have_su() { command -v su >/dev/null 2>&1; }
aoe_su_detect() { [ -n "$AOE_SU_PROBED" ] && return 0; AOE_SU_PROBED=1
    if bounded 60 su --mount-master -c true >/dev/null 2>&1; then AOE_SU_OPT=--mount-master
    elif bounded 60 su -M -c true >/dev/null 2>&1; then AOE_SU_OPT=-M; fi; return 0; }
aoe_root() { local cmd="" a; aoe_su_detect; for a in "$@"; do cmd+="${cmd:+ }$(printf '%q' "$a")"; done; su $AOE_SU_OPT -c "$cmd"; }
aoe_game_mounted() { mount 2>/dev/null | grep -qF " on $1 type "; }
aoe_bind_mount() { local src=$1 dst=$2; aoe_game_mounted "$dst" && return 0; mkdir -p "$dst" || return 1; aoe_root mount --bind "$src" "$dst" || return 1; aoe_root mount -o remount,bind,rw,exec "$dst" >/dev/null 2>&1 || true; aoe_game_mounted "$dst"; }
aoe_bind_umount() { aoe_game_mounted "$1" || return 0; aoe_root umount "$1" || aoe_root umount -l "$1"; }
aoe_game_ensure() {
    [ "${GAME_MODE:-keep}" = bind ] || return 0
    aoe_game_mounted "$GAME_DIR" && return 0
    aoe_say "Mounting the game folder with root: $GAME_SRC -> $GAME_DIR"
    aoe_have_su || { aoe_warn "No 'su' command."; return 1; }
    aoe_bind_mount "$GAME_SRC" "$GAME_DIR" || { aoe_warn "Could not mount."; return 1; }
    aoe_say "Mounted."
}
ENVSH
    mv "$LIB/env.sh.tmp" "$LIB/env.sh"
}

# Source the runtime into THIS shell and prepare the environment.
# Always saves state first: hf_env re-reads state.env and would otherwise
# overwrite in-memory values (e.g. AOE_PREFIX) with stale ones.
load_runtime() {
    write_env_lib
    export AOE_BASE=$BASE
    # shellcheck disable=SC1091
    . "$LIB/env.sh" || return 1
    : "${AOE_PREFIX:=$BASE/prefix}"
    save_state
    hf_env
}

# =============================================================================
#  Launcher
# =============================================================================
write_launcher() {
    cat >"$BIN/aoe2-voobly.tmp" <<'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
AOE_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
export AOE_BASE
. "$AOE_BASE/lib/env.sh" || exit 1
hf_env || exit 1
GAME_PATH="${GAME_PATH:-${GAME_DRIVE^^}:}"
usage() { cat <<EOF
Usage: aoe2-voobly <command> [args]
  voobly | voobly-interp | aoe2 | aok | clear-port | port-test | stop | status
  mount-game | umount-game | wine ARGS | wineserver ARGS
  voobly-interp starts Voobly with Box64's interpreter; use it if Voobly crashes
  under the dynarec (the game still runs on the dynarec either way).
EOF
}
win_of() { local rel=${1#"$WINEPREFIX/drive_c/"}; printf 'C:\\%s' "${rel//\//\\}"; }
launch() {
    local runner=$1 label=$2 workdir=$3 logf rc; shift 3
    [ -d "$workdir" ] || { aoe_warn "Missing folder: $workdir"; exit 1; }
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
    aoe_port_clear || aoe_warn "Continuing with port $PORT busy."
    aoe_display || aoe_warn "No X11 display. Open the Termux:X11 app."
    aoe_audio
    mkdir -p "$AOE_BASE/logs"
    logf="$AOE_BASE/logs/$label-$(date +%Y%m%d-%H%M%S).log"
    cd "$workdir" || exit 1
    aoe_say "Starting $label (Box64, native). Log: $logf"
    trap 'aoe_stop_wine; command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock; exit 130' INT TERM
    "$runner" "$@" 9>&- >"$logf" 2>&1 & wait $!; rc=$?
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
    aoe_say "$label exited with status $rc"
    [ "$rc" -eq 0 ] || tail -n 40 "$logf"
    exit "$rc"
}
game_launch() {
    local label=$1 rel=$2 relw win cmdline da; shift 2
    [ -f "$GAME_DIR/$rel" ] || { aoe_warn "Missing executable: $GAME_DIR/$rel"; exit 1; }
    relw=${rel//\//\\}; win="$GAME_PATH\\$relw"
    cmdline="cd /d $GAME_PATH\\ && start \"\" /wait $win${*:+ $*}"
    da=$(aoe_desktop_arg aoe2)
    launch hwine "$label" "$GAME_DIR" explorer ${da:+"$da"} 'C:\windows\system32\cmd.exe' /d /c "$cmdline"
}
cmd=${1:-help}; [ $# -gt 0 ] && shift
case "$cmd" in voobly|voobly-interp|aoe2|aoc|aok|mount-game) aoe_game_ensure || exit 1 ;; esac
case "$cmd" in
    voobly|voobly-interp)
        [ -f "${VOOBLY_EXE:-}" ] || { aoe_warn "Voobly not installed."; exit 1; }
        da=$(aoe_desktop_arg voobly)
        runner=hwine; [ "$cmd" = voobly-interp ] && runner=hwine_interp
        launch "$runner" voobly "$(dirname "$VOOBLY_EXE")" explorer ${da:+"$da"} "$(win_of "$VOOBLY_EXE")" "$@" ;;
    aoe2|aoc) game_launch aoe2 "$AOC_REL" "$@" ;;
    aok)      game_launch aok "$AOK_REL" "$@" ;;
    mount-game) [ "${GAME_MODE:-keep}" = bind ] && aoe_say "Mounted: $GAME_DIR" || aoe_say "Nothing to mount." ;;
    umount-game) if [ "${GAME_MODE:-keep}" = bind ]; then aoe_stop_wine; aoe_bind_umount "$GAME_DIR" && aoe_say "Unmounted."; else aoe_say "Nothing to unmount."; fi ;;
    clear-port) aoe_port_clear ;;
    port-test)
        port_busy && b=busy || b=available; aoe_say "Before: $b"
        aoe_stop_wine || aoe_warn "Could not stop Wine."
        port_busy && a=busy || a=available; aoe_say "After : $a"
        case "$b/$a" in busy/available) aoe_say "Verified: port released.";; available/available) aoe_say "Port was free.";; *) aoe_say "Still busy.";; esac ;;
    stop) aoe_stop_wine && aoe_say "Wine stopped." ;;
    status)
        aoe_say "Prefix: $WINEPREFIX"
        aoe_say "Wine  : $WINE_INSTALL_DIR"
        aoe_emu_build >/dev/null 2>&1
        aoe_say "Box64 : ${AOE_BOX64_BIN:-not usable} (${AOE_BOX64_MODE:-n/a})"
        aoe_say "x64lib: $AOE_X64"
        aoe_say "Game  : ${GAME_DIR:-?} -> ${GAME_PATH:-?}"
        aoe_say "Voobly: ${VOOBLY_EXE:-not installed}"
        port_busy && aoe_say "Port $PORT: IN USE" || aoe_say "Port $PORT: free" ;;
    wine) hwine "$@" ;;
    wineserver) hwineserver "$@" ;;
    *) usage ;;
esac
LAUNCH
    chmod 755 "$BIN/aoe2-voobly.tmp"; mv "$BIN/aoe2-voobly.tmp" "$BIN/aoe2-voobly"
    ln -sf "$BIN/aoe2-voobly" "$PREFIX/bin/aoe2-voobly"
}

# Tiny wrappers so winetricks can call Wine through Box64.
write_wrappers() {
    cat >"$BIN/wine-wrap" <<'W1'
#!/data/data/com.termux/files/usr/bin/bash
exec "$(dirname "$(readlink -f "$0")")/aoe2-voobly" wine "$@"
W1
    cat >"$BIN/wineserver-wrap" <<'W2'
#!/data/data/com.termux/files/usr/bin/bash
exec "$(dirname "$(readlink -f "$0")")/aoe2-voobly" wineserver "$@"
W2
    chmod 755 "$BIN/wine-wrap" "$BIN/wineserver-wrap"
}

# =============================================================================
#  x86-64 helper libraries (Debian .deb files unpacked in pure Python, no root)
# =============================================================================
write_x64_fetcher() {
    cat >"$BASE/x64fetch.py" <<'PY'
#!/usr/bin/env python3
"""Resolve x86-64 Debian packages (plus dependencies) and unpack them into a folder.
Unpacks the .deb itself (ar + tar) so it does not depend on Termux's dpkg-deb."""
import io, lzma, os, re, sys, tarfile, urllib.request

mirror, suite, dest, cache = sys.argv[1:5]
roots = sys.argv[5:]
# Box64 provides libc itself; never pull these in.
SKIP = {"libc6", "libc-bin", "libc6-dev", "gcc-12-base", "gcc-13-base", "gcc-14-base",
        "debconf", "dpkg", "perl-base", "tzdata", "base-files", "dash", "bash", "coreutils"}
NEED = ("Package", "Depends", "Pre-Depends", "Filename", "Provides")


def get(url, tries=3):
    last = None
    for _ in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "aoe2-tui"})
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.read()
        except Exception as e:
            last = e
    raise last


def ar_members(data):
    if data[:8] != b"!<arch>\n":
        raise ValueError("not an ar archive")
    pos = 8
    while pos + 60 <= len(data):
        hdr = data[pos:pos + 60]
        name = hdr[:16].decode("ascii", "replace").strip().rstrip("/")
        size = int(hdr[48:58].decode("ascii", "replace").strip())
        pos += 60
        yield name, data[pos:pos + size]
        pos += size + (size & 1)


def extract_deb(path):
    with open(path, "rb") as f:
        data = f.read()
    for name, body in ar_members(data):
        if not name.startswith("data.tar"):
            continue
        if name.endswith(".zst"):
            raise RuntimeError("zstd-compressed package (try AOE_X64_SUITE=bookworm)")
        mode = {"": "r:", ".xz": "r:xz", ".gz": "r:gz", ".bz2": "r:bz2"}.get(name[len("data.tar"):])
        if mode is None:
            raise RuntimeError("unknown data member " + name)
        kw = {"filter": "fully_trusted"} if hasattr(tarfile, "fully_trusted_filter") else {}
        with tarfile.open(fileobj=io.BytesIO(body), mode=mode) as tf:
            for m in tf:
                if m.isdev() or m.isfifo():
                    continue
                if m.isdir():
                    m.mode |= 0o700
                elif m.isfile():
                    m.mode |= 0o600
                target = os.path.join(dest, os.path.normpath(m.name).lstrip("/"))
                if (m.issym() or m.islnk()) and os.path.lexists(target) and not os.path.isdir(target):
                    os.remove(target)
                try:
                    tf.extract(m, dest, **kw)
                except Exception as e:
                    print("   skip %s: %s" % (m.name, e), flush=True)
        return
    raise RuntimeError("no data.tar member in package")


os.makedirs(dest, exist_ok=True)
os.makedirs(cache, exist_ok=True)

print("Downloading package index (%s, amd64) ..." % suite, flush=True)
raw = get("%s/dists/%s/main/binary-amd64/Packages.xz" % (mirror, suite))
text = lzma.decompress(raw).decode("utf-8", "replace")
del raw

pk, prov = {}, {}
cur, key = {}, None


def flush():
    n = cur.get("Package")
    if not n:
        return
    pk[n] = cur
    for p in cur.get("Provides", "").split(","):
        p = p.strip().split(" ")[0]
        if p:
            prov.setdefault(p, n)


for line in text.split("\n"):
    if not line:
        flush(); cur, key = {}, None
        continue
    if line[0] in " \t":
        if key in NEED:
            cur[key] += " " + line.strip()
        continue
    k, _, v = line.partition(":")
    if k in NEED:
        cur[k] = v.strip(); key = k
    else:
        key = None
flush()
del text


def deps_of(name):
    out = []
    fields = pk[name].get("Depends", "") + "," + pk[name].get("Pre-Depends", "")
    for grp in fields.split(","):
        grp = grp.strip()
        if not grp:
            continue
        for alt in grp.split("|"):
            n = re.split(r"[ (\[<:]", alt.strip(), maxsplit=1)[0]
            if n in pk:
                out.append(n); break
            if n in prov:
                out.append(prov[n]); break
    return out


order, seen, queue, missing = [], set(), [], []
for r in roots:
    if r in pk:
        queue.append(r)
    else:
        missing.append(r)
while queue:
    n = queue.pop(0)
    if n in seen or n in SKIP:
        continue
    seen.add(n); order.append(n)
    queue.extend(deps_of(n))

print("Packages to unpack: %d" % len(order), flush=True)
if missing:
    print("Not found in the index (skipped): " + " ".join(missing), flush=True)

done = fail = 0
for i, n in enumerate(order, 1):
    fn = pk[n].get("Filename")
    if not fn:
        continue
    path = os.path.join(cache, os.path.basename(fn))
    try:
        if not os.path.exists(path):
            with open(path + ".part", "wb") as f:
                f.write(get("%s/%s" % (mirror, fn)))
            os.replace(path + ".part", path)
        extract_deb(path)
        done += 1
        print("[%d/%d] %s" % (i, len(order), n), flush=True)
    except Exception as e:
        fail += 1
        print("[%d/%d] FAILED %s: %s" % (i, len(order), n, e), flush=True)

# Record every folder that holds shared libraries; Box64 gets them as its library path.
dirs = set()
for root, _, files in os.walk(dest):
    if any(".so" in f for f in files):
        dirs.add(root)
with open(os.path.join(dest, "libdirs.txt"), "w") as f:
    f.write("\n".join(sorted(dirs)) + "\n")

print("Unpacked %d, failed %d, library folders %d" % (done, fail, len(dirs)), flush=True)
sys.exit(0 if done > 0 else 1)
PY
    chmod 755 "$BASE/x64fetch.py"
}

x64_ready() { [ -n "$(find "$X64_DIR" -name 'libfreetype.so*' -print -quit 2>/dev/null)" ]; }

# =============================================================================
#  STAGES  (each one runs in a subshell via run_stage; die() just ends the stage)
# =============================================================================

emu_ready() {
    [ -x "$PREFIX/glibc/bin/box64" ] || command -v box64 >/dev/null 2>&1
}

stage_preflight() {
    ui --title "Preflight" --infobox "Checking Termux, storage access and helper packages..." 8 60
    [ "$(id -u)" != 0 ] || die "Run as the normal Termux user."
    case "$PREFIX" in */com.termux/*) ;; *) die "This script is for Termux on Android.";; esac
    case "$(uname -m)" in aarch64|arm64) ;; *) die "Needs ARM64.";; esac
    command -v pkg >/dev/null 2>&1 || die "pkg not found."
    [ "$PREFIX" = /data/data/com.termux/files/usr ] || warn "Unusual Termux prefix: the patched Wine expects /data/data/com.termux/files/usr."

    if [ ! -d "$HOME/storage/shared" ]; then
        ui --title "Storage" --msgbox "Android storage access is needed. Accept the permission dialog next." 10 60
        termux-setup-storage
        local i; for i in $(seq 1 60); do [ -d "$HOME/storage/shared" ] && break; sleep 1; done
        [ -d "$HOME/storage/shared" ] || die "Storage permission not granted."
    fi

    local need=() c
    for c in curl:curl cabextract:cabextract pgrep:procps lsof:lsof flock:util-linux \
             xz:xz-utils python3:python pulseaudio:pulseaudio; do
        command -v "${c%%:*}" >/dev/null 2>&1 || need+=("${c##*:}")
    done
    clear
    if [ ${#need[@]} -gt 0 ]; then
        say "Installing: ${need[*]}"
        pkg install -y "${need[@]}" 2>&1 | tee -a "$LOG" || warn "Some packages failed to install."
    fi
    if ! command -v termux-x11 >/dev/null 2>&1; then
        say "Installing Termux:X11 server package ..."
        { pkg install -y x11-repo && pkg install -y termux-x11-nightly xorg-xrandr; } 2>&1 | tee -a "$LOG" ||
            warn "Could not install termux-x11-nightly."
    fi
    command -v curl >/dev/null 2>&1    || die "curl missing."
    command -v python3 >/dev/null 2>&1 || die "python missing (pkg install python)."
    command -v termux-x11 >/dev/null 2>&1 || warn "termux-x11 missing; you also need the Termux:X11 Android app."
    ok "Preflight passed."
}

stage_emulator() {
    EMULATOR=box64
    yesno "Emulator (native)" "Install Box64 natively in Termux?\n\n1. Enable Termux's glibc repo (glibc-repo)\n2. Install box64-glibc + glibc-runner\n3. Install native glibc X11/audio libraries (if available)\n4. Fetch x86-64 helper libraries from Debian\n\nNo proot and no compiling. Needs a few hundred MB." || return 0
    clear

    say "Enabling Termux glibc repository ..."
    pkg install -y glibc-repo 2>&1 | tee -a "$LOG"
    [ "${PIPESTATUS[0]}" = 0 ] || die "Could not install glibc-repo."
    pkg update -y 2>&1 | tee -a "$LOG"

    say "Installing Box64 (glibc build) and glibc-runner ..."
    pkg install -y box64-glibc glibc-runner 2>&1 | tee -a "$LOG"
    [ "${PIPESTATUS[0]}" = 0 ] || die "Could not install box64-glibc / glibc-runner. Run 'pkg update' and retry."

    say "Looking for native glibc libraries (X11, audio, fonts) ..."
    local names n got=0
    names=$(apt-cache pkgnames 2>/dev/null | grep -E -- '-glibc$' | grep -E "$NATIVE_RE" | sort -u)
    for n in $names; do
        if pkg install -y "$n" >>"$LOG" 2>&1; then say "  native: $n"; got=$((got+1)); else warn "  skipped $n"; fi
    done
    [ "$got" -gt 0 ] || warn "No native *-glibc libraries were installed; relying on the x86-64 Debian libraries only."

    # glibc programs look for /etc-style files under the glibc prefix; make sure DNS has a resolver.
    mkdir -p "$PREFIX/glibc/etc"
    [ -s "$PREFIX/glibc/etc/resolv.conf" ] || printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"$PREFIX/glibc/etc/resolv.conf"

    # Does Box64 actually start?
    write_env_lib
    export AOE_BASE=$BASE
    # shellcheck disable=SC1091
    . "$LIB/env.sh" || die "Runtime not usable."
    aoe_emu_build || die "Box64 does not start (tried direct and via grun). See $LOG"
    "${AOE_EMU[@]}" --version 2>&1 | tee -a "$LOG"
    say "Box64 mode: $AOE_BOX64_MODE ($AOE_BOX64_BIN)"

    say "Fetching x86-64 helper libraries from Debian ($X64_SUITE) ..."
    write_x64_fetcher
    # shellcheck disable=SC2086
    python3 "$BASE/x64fetch.py" "$X64_MIRROR" "$X64_SUITE" "$X64_DIR" "$CACHE/debs" $X64_ROOTS 2>&1 | tee -a "$LOG"
    [ "${PIPESTATUS[0]}" = 0 ] || die "Could not fetch the x86-64 libraries (check your connection, or set AOE_X64_MIRROR / AOE_X64_SUITE)."
    x64_ready || warn "libfreetype not found under $X64_DIR; Wine text rendering may fail."

    save_state
    ok "Emulator ready: native Box64 + x86-64 helper libraries"
}

stage_wine() {
    load_runtime >/dev/null 2>&1 || true       # hf_env fails until Wine exists; that is fine here
    local marker="$WINE_INSTALL_DIR/.aoe-wine-source"
    if [ -x "$WINE_INSTALL_DIR/bin/wine" ] && [ "$(cat "$marker" 2>/dev/null)" = "$WINE_URL" ]; then
        ok "Termux-patched Wine already present."
        return 0
    fi
    if [ -n "$(ls -A "$WINE_INSTALL_DIR" 2>/dev/null)" ]; then
        # An earlier (unpatched) Wine cannot run natively in Termux; replace it.
        warn "Replacing the previously installed Wine with the Termux-patched build."
        pkill -f "$WINE_INSTALL_DIR/bin/" 2>/dev/null
        sleep 1
        rm -rf "$WINE_INSTALL_DIR"
        [ -f "$AOE_PREFIX/system.reg" ] || rm -rf "$AOE_PREFIX"   # drop a half-created prefix
    fi
    mkdir -p "$WINE_INSTALL_DIR"
    ui --title "Wine (Termux build)" --infobox "Downloading ${WINE_ASSET}..." 8 60
    clear
    if ! curl -fL --retry 3 --connect-timeout 30 -o "$CACHE/$WINE_ASSET.part" "$WINE_URL"; then
        rm -f "$CACHE/$WINE_ASSET.part"
        die "Download failed: $WINE_URL  (try AOE_WINE_TAG=11.2-mfdxgi, or set AOE_WINE_URL; releases: github.com/Waim908/wine-termux/releases)"
    fi
    mv "$CACHE/$WINE_ASSET.part" "$CACHE/$WINE_ASSET"
    say "Extracting ..."
    tar -xJf "$CACHE/$WINE_ASSET" -C "$WINE_INSTALL_DIR" --strip-components=1 || die "Extraction failed."
    rm -f "$CACHE/$WINE_ASSET"
    [ -x "$WINE_INSTALL_DIR/bin/wine" ] || die "bin/wine missing after extraction."
    printf '%s\n' "$WINE_URL" >"$marker"
    save_state
    ok "Wine installed: $WINE_INSTALL_DIR"
}

stage_prefix() {
    emu_ready || die "Box64 is not installed (menu item 2)."
    [ -x "$WINE_INSTALL_DIR/bin/wine" ] || die "Download Wine first (menu item 3)."
    load_runtime || die "Runtime not usable."
    aoe_emu_build || die "Box64 does not start (menu item 2)."
    local ps
    ps=$(python3 -c 'import os; print(os.sysconf("SC_PAGE_SIZE"))' 2>/dev/null)
    printf 'Kernel page size: %s  Kernel: %s\n' "${ps:-?}" "$(uname -r)" >>"$LOG"
    [ -z "$ps" ] || [ "$ps" = 4096 ] || warn "This device uses ${ps}-byte memory pages; Wine under Box64 is known to be unreliable there."
    if [ ! -f "$AOE_PREFIX/system.reg" ]; then
        ui --title "Wine prefix" --infobox "Creating prefix at $AOE_PREFIX (first run can take many minutes)..." 10 60
        mkdir -p "$AOE_PREFIX"
        bounded 1500 hwine wineboot -u >>"$LOG" 2>&1
        bounded 90 hwineserver -w >>"$LOG" 2>&1
    fi
    [ -f "$AOE_PREFIX/system.reg" ] || die "Wine did not create a prefix. See the end of the log for the Wine/Box64 error."
    save_state
    ok "Prefix ready: $AOE_PREFIX"
}

pick_drive() {
    local dev="$WINEPREFIX/dosdevices" l link game
    game="$(readlink -f "$GAME_DIR")"; mkdir -p "$dev"
    for l in g h i j k l m n o p q r s t u v w x y; do
        link="$dev/$l:"
        [ -L "$link" ] && [ "$(readlink -f "$link")" = "$game" ] && { echo "$l"; return 0; }
    done
    [ -n "${GAME_DRIVE:-}" ] && [ -L "$dev/${GAME_DRIVE}:" ] && ln -sfn "$game" "$dev/${GAME_DRIVE}:" && { echo "$GAME_DRIVE"; return 0; }
    for l in g h i j k l m n o p q r s t u v w x y; do
        link="$dev/$l:"
        [ ! -e "$link" ] && [ ! -L "$link" ] && ln -s "$game" "$link" && { echo "$l"; return 0; }
    done
    return 1
}

in_private_storage() {
    local p=$1 home_real; home_real="$(readlink -f "$HOME" 2>/dev/null)"; home_real=${home_real:-$HOME}
    case "$p/" in "$HOME"/*|"$home_real"/*|"$PREFIX"/*) return 0;; /data/data/com.termux/*|/data/user/*/com.termux/*) return 0;; esac
    return 1
}

raw_media_path() {
    local p=$1
    case "$p" in
        /storage/emulated/*) printf '/data/media/%s' "${p#/storage/emulated/}";;
        /storage/self/primary/*) printf '/data/media/0/%s' "${p#/storage/self/primary/}";;
        /sdcard/*) printf '/data/media/0/%s' "${p#/sdcard/}";;
        *) printf '%s' "$p";;
    esac
}

drive_visible() {
    local out; out=$(bounded 180 hwine "C:\\windows\\system32\\cmd.exe" /d /c "cd /d $1\\ && echo AOE_DRIVE_OK" 2>&1)
    [[ "$out" == *AOE_DRIVE_OK* ]]
}

location_copy() {
    local dest; dest=$(input "Copy location" "Copy game folder to:" "$HOME/aoe2") || return 1
    dest=$(clean_path "$dest")
    mkdir -p "$dest" || return 1
    ui --title "Copying" --infobox "Copying game files (this can take a while)..." 8 60
    cp -a "$GAME_DIR/." "$dest/" 2>>"$LOG" || { warn "Copy failed."; return 1; }
    [ -f "$dest/$AOC_REL" ] || { warn "Copy incomplete."; return 1; }
    GAME_ORIG=$GAME_DIR; GAME_DIR=$dest; GAME_MODE=copy
    ok "Copied to $dest (original untouched: $GAME_ORIG)"
}

location_root() {
    aoe_have_su || { warn "No su command."; return 1; }
    local raw mp="$BASE/game"
    raw=$(raw_media_path "$GAME_DIR")
    aoe_bind_umount "$mp" >/dev/null 2>&1
    ui --title "Root mount" --infobox "Bind-mounting $raw -> $mp..." 8 60
    aoe_bind_mount "$raw" "$mp" || { warn "Mount failed."; return 1; }
    [ -r "$mp/$AOC_REL" ] || { warn "Cannot read mounted files."; aoe_bind_umount "$mp"; return 1; }
    GAME_ORIG=$GAME_DIR; GAME_SRC=$raw; GAME_DIR=$mp; GAME_MODE=bind
    ok "Root mount active."
}

stage_game() {
    [ -f "$AOE_PREFIX/system.reg" ] || [ -f "$BASE/prefix/system.reg" ] || die "Create the Wine prefix first (menu item 4)."
    load_runtime || die "Runtime not usable."

    local default d aok aoc
    default="${GAME_DIR:-$HOME/storage/shared/Games/Age of Empires II}"
    case "${GAME_MODE:-keep}" in bind|copy) [ -n "${GAME_ORIG:-}" ] && default=$GAME_ORIG ;; esac
    d=$(input "Game folder" "Path to the original AoE II + The Conquerors files:" "$default") || return 0
    d=$(clean_path "$d")
    while [ ! -d "$d" ]; do
        msg "Game folder" "Not a directory:\n$d"
        d=$(input "Game folder" "Try again:" "$default") || return 0
        d=$(clean_path "$d")
    done
    GAME_DIR="$(readlink -f "$d")"
    case "$GAME_DIR/" in "$AOE_PREFIX"/*) die "Game folder must not be inside the prefix.";; esac

    aok=$(find_ci "$GAME_DIR" age2.exe 3); [ -n "$aok" ] || aok=$(find_ci "$GAME_DIR" empires2.exe 3)
    aoc=$(find_ci "$GAME_DIR" age2_x1.exe 3); [ -n "$aoc" ] || aoc=$(find_ci "$GAME_DIR" age2x1.exe 3)
    [ -n "$aok" ] && [ -n "$aoc" ] || die "Need empires2.exe/age2.exe AND age2_x1.exe/age2x1.exe."
    [ "$(pe_machine "$aok")" = i386 ] && [ "$(pe_machine "$aoc")" = i386 ] || die "Expected original 32-bit executables."
    AOK_REL="${aok#"$GAME_DIR"/}"; AOC_REL="${aoc#"$GAME_DIR"/}"

    if in_private_storage "$GAME_DIR"; then
        GAME_MODE=keep; ok "Game folder is in private storage."
    else
        local mode
        mode=$(menu "Game location" "The game folder is outside Termux's private storage. How should Wine access it?" \
            "keep" "Use in place (may fail for 1.5/1.6 patches)" \
            "copy" "Copy to ~/aoe2 (reliable, needs extra space)" \
            "root" "Root bind-mount (experimental)") || return 0
        GAME_MODE=$mode
        case "$GAME_MODE" in
            copy) location_copy || die "Copy failed." ;;
            root) location_root || { warn "Root mode failed; falling back to copy."; location_copy || die "Copy failed."; } ;;
        esac
    fi
    save_state
    load_runtime || die "Runtime not usable."

    local letter drive visible=0 _
    letter=$(pick_drive) || die "No free drive letter."
    drive="${letter^^}:"
    ui --title "Game" --infobox "Checking that Wine can see $drive (slow under emulation)..." 8 60
    bounded 30 hwineserver -k >/dev/null 2>&1; bounded 45 hwineserver -w >/dev/null 2>&1
    for _ in 1 2 3; do
        if drive_visible "$drive"; then visible=1; break; fi
        bounded 30 hwineserver -k >/dev/null 2>&1; bounded 45 hwineserver -w >/dev/null 2>&1
    done
    [ "$visible" = 1 ] || die "Wine cannot reach $GAME_DIR as $drive."
    GAME_DRIVE=$letter; GAME_PATH="$drive"
    save_state
    ok "$drive -> $GAME_DIR"
}

stage_directplay() {
    load_runtime || die "Runtime not usable (finish menu items 2-4 first)."
    yesno "DirectPlay" "Install native DirectPlay via winetricks?\n\nOptional and experimental: only try it if a Voobly lobby reports a DirectPlay error." || return 0
    local wt="$TOOLS/winetricks"
    clear
    if [ ! -s "$wt" ]; then
        curl -fL --retry 2 -o "$wt.part" "$WINETRICKS_URL" && mv "$wt.part" "$wt" || { rm -f "$wt.part"; die "Could not download winetricks."; }
    fi
    write_launcher; write_wrappers
    say "Running winetricks directplay (can take a long time) ..."
    bounded 3600 env WINE="$BIN/wine-wrap" WINESERVER="$BIN/wineserver-wrap" WINEPREFIX="$WINEPREFIX" \
        bash "$wt" -q directplay 2>&1 | tee -a "$LOG"
    if [ "${PIPESTATUS[0]}" = 0 ]; then
        WANT_DIRECTPLAY=1; save_state; ok "DirectPlay installed."
    else
        die "winetricks directplay failed (see log). The game may still work with Wine's built-in DirectPlay."
    fi
}

stage_voobly() {
    [ -f "$AOE_PREFIX/system.reg" ] || [ -f "$BASE/prefix/system.reg" ] || die "Create the Wine prefix first (menu item 4)."
    load_runtime || die "Runtime not usable."
    local found setup
    if [ -n "${VOOBLY_EXE:-}" ] && [ -f "$VOOBLY_EXE" ]; then found=$VOOBLY_EXE
    else found=$(find_ci "$AOE_PREFIX/drive_c" voobly.exe 8); fi
    if [ -z "$found" ]; then
        setup=$(input "Voobly setup" "Path to the Voobly installer (.exe):" "$HOME/storage/downloads/voobly.exe") || return 0
        setup=$(clean_path "$setup")
        [ -f "$setup" ] || die "File not found: $setup"
        # Run it from private storage (shared storage is mounted noexec/FUSE on many devices).
        cp -f "$setup" "$CACHE/voobly-setup.exe" || die "Could not copy installer."
        ui --title "Voobly" --msgbox "The installer will open in Termux:X11 (switch to that app).\n\nAccept the license, keep defaults, and UNCHECK 'Launch Voobly' at the end." 12 62
        aoe_display || warn "No X11 display; open the Termux:X11 app."
        aoe_audio
        clear; say "Running Voobly installer (Box64 interpreter: its dynarec crashes Delphi installers) ..."
        hwine_interp "$CACHE/voobly-setup.exe" >>"$LOG" 2>&1
        found=$(find_ci "$AOE_PREFIX/drive_c" voobly.exe 8)
        [ -n "$found" ] || die "Voobly.exe not found in the prefix after install (see $LOG)."
    fi
    VOOBLY_EXE=$found; save_state
    ok "Voobly ready: $VOOBLY_EXE"
}

stage_launchers() {
    write_env_lib; write_launcher; write_wrappers; save_state
    ok "Command installed: aoe2-voobly"
}

stage_final() {
    [ -x "$BIN/aoe2-voobly" ] || stage_launchers
    load_runtime || die "Runtime not usable."
    ui --title "Final checks" --infobox "Checking port $PORT and stopping leftover Wine processes..." 8 60
    aoe_port_clear || warn "Port busy."
    if yesno "Smoke test" "Open Voobly now?\n\n(Switch to the Termux:X11 app to see it.)"; then
        clear
        "$BIN/aoe2-voobly" voobly
    fi
}

# =============================================================================
#  MAIN MENU
# =============================================================================
run_stage() {
    local name=$1 rc; shift
    ( "$@" ); rc=$?
    load_state
    if [ $rc -ne 0 ]; then
        ui --title "Stage failed: $name" --msgbox "Exit code $rc.\n\n$(tail -n 8 "$LOG" | tr -d '\\' | cut -c1-66)\n\nFull log: $LOG" 20 74
    fi
    return $rc
}

status_line() {
    local wine="no" emu="no" prefix="no" game="no" voobly="no"
    [ -x "$WINE_INSTALL_DIR/bin/wine" ] && wine="ok"
    emu_ready && x64_ready && emu="ok"
    [ -f "$AOE_PREFIX/system.reg" ] && prefix="ok"
    [ -n "$GAME_DIR" ] && [ -d "$GAME_DIR" ] && [ -n "$GAME_DRIVE" ] && game="ok"
    [ -n "$VOOBLY_EXE" ] && [ -f "$VOOBLY_EXE" ] && voobly="ok"
    printf 'Wine:%s Box64:%s Prefix:%s Game:%s Voobly:%s' "$wine" "$emu" "$prefix" "$game" "$voobly"
}

run_all() {
    run_stage "Preflight"  stage_preflight  || return 1
    run_stage "Emulator"   stage_emulator   || return 1
    run_stage "Wine"       stage_wine       || return 1
    run_stage "Prefix"     stage_prefix     || return 1
    run_stage "Game"       stage_game       || return 1
    run_stage "Voobly"     stage_voobly     || return 1
    run_stage "Launchers"  stage_launchers  || return 1
}

main_menu() {
    local choice
    while true; do
        choice=$(menu "AoE II + Voobly  -  Termux-patched Wine + native Box64" \
            "$(status_line)" \
            "0" "Run steps 1-7 in order" \
            "1" "Preflight & helper packages" \
            "2" "Box64 (native glibc) + x86-64 libraries" \
            "3" "Download Wine (Termux-patched build)" \
            "4" "Create Wine prefix" \
            "5" "Map game folder" \
            "6" "Install Voobly" \
            "7" "Create launcher command" \
            "8" "Final checks / smoke test" \
            "9" "Optional: DirectPlay (winetricks)" \
            "q" "Exit") || break
        case "$choice" in
            0) run_all ;;
            1) run_stage "Preflight" stage_preflight ;;
            2) run_stage "Emulator" stage_emulator ;;
            3) run_stage "Wine" stage_wine ;;
            4) run_stage "Prefix" stage_prefix ;;
            5) run_stage "Game" stage_game ;;
            6) run_stage "Voobly" stage_voobly ;;
            7) run_stage "Launchers" stage_launchers ;;
            8) run_stage "Final" stage_final ;;
            9) run_stage "DirectPlay" stage_directplay ;;
            q) break ;;
        esac
    done
}

main() {
    : >"$LOG"
    load_state
    if [ ! -f "$STATE" ]; then
        ui --title "Welcome" --msgbox "This wizard sets up AoE II + Voobly using a Termux-patched x86-64 Wine through Box64, running natively in Termux (glibc-repo). No proot, nothing is compiled.\n\nEasiest: choose '0' to run steps 1-7 in order. You also need the Termux:X11 Android app installed." 14 64
    fi
    main_menu
    clear
    printf 'You can now run:\n\n  aoe2-voobly voobly\n  aoe2-voobly aoe2\n  aoe2-voobly status\n\nLogs: %s\n' "$LOGS"
}

main "$@"