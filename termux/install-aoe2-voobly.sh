#!/data/data/com.termux/files/usr/bin/bash
# AoE II Classic + Voobly - Android/Termux bootstrap.
#
# Companion of ../../install_aoe2_voobly.py. Same architecture and data layout:
# Termux + proot-distro Ubuntu (glibc) + Box64 + Wine 10.0 amd64-wow64 +
# one shared win64 prefix + Winetricks DirectPlay + Voobly + launchers.
# This host script only prepares Android (packages, X11, audio, GPU mode,
# glibc container) and then runs install-inside.sh inside the container.
#
# Run as the Termux user (no root, no sudo):
#   bash termux/install-aoe2-voobly.sh [--gpu=auto|virgl|software] [--ddraw=wine|cnc]
#
# Prerequisites installed by the user: Termux (F-Droid) and the Termux:X11 app
# (https://github.com/termux/termux-x11/releases). Input Bridge is optional.
set -uo pipefail

# `curl ... | bash` makes stdin the script source; interactive prompts
# must read the terminal instead.
if [ ! -t 0 ] && [ -r /dev/tty ]; then exec </dev/tty; fi

# When run via `curl ... | bash` there is no script path; the core installer
# is then downloaded from the same repository instead of copied locally.
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
    SCRIPT_DIR=$(cd -- "$(dirname -- "$SELF")" && pwd)
else
    SCRIPT_DIR=""
fi
REPO_REF="${AOE2_TERMUX_REF:-main}"
REPO_RAW="https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/$REPO_REF/termux"
GPU=auto
DDRaw=wine
for arg in "$@"; do
    case "$arg" in
        --gpu=*)   GPU=${arg#*=} ;;
        --ddraw=*) DDRaw=${arg#*=} ;;
        -h|--help)
            if [ -n "$SCRIPT_DIR" ] && [ -f "${BASH_SOURCE[0]}" ]; then
                sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            else
                echo "usage: install-aoe2-voobly.sh [--gpu=auto|virgl|software] [--ddraw=wine|cnc]"
            fi
            exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done
case "$GPU" in auto|virgl|software) ;; *) echo "--gpu must be auto|virgl|software" >&2; exit 2 ;; esac
case "$DDRaw" in wine|cnc) ;; *) echo "--ddraw must be wine|cnc" >&2; exit 2 ;; esac

say()  { printf '\033[%sm%s\033[0m\n' "${2:-36}" "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
[ -n "${PREFIX:-}" ] && [ -d "$PREFIX" ] || fail "Run inside Termux (com.termux), not a generic shell."
[ "$(uname -m)" = "aarch64" ] || fail "Android/Termux port requires an arm64-v8a device."
[ "$(id -u)" -ne 0 ] || fail "Run as the Termux user, not root."
command -v pkg >/dev/null || fail "Termux 'pkg' not found; install Termux from F-Droid."

ANDROID_REL=$(getprop ro.build.version.release 2>/dev/null || echo "?")
ANDROID_SDK=$(getprop ro.build.version.sdk 2>/dev/null || echo 0)
[ "${ANDROID_SDK:-0}" -ge 26 ] 2>/dev/null || say "Android 8+ is recommended (detected: ${ANDROID_REL})." 33

SOC=$(printf '%s %s %s' "$(getprop ro.board.platform 2>/dev/null)" \
      "$(getprop ro.hardware 2>/dev/null)" "$(getprop ro.soc.model 2>/dev/null)" | tr -s ' ')
GPU_HINT=$(getprop ro.hardware.egl 2>/dev/null || true)
if [ -e /sys/class/kgsl/kgsl-3d0 ]; then
    VENDOR=adreno
else
    case "${SOC}${GPU_HINT}" in
        *[Mm]ali*|*xynos*|*mt[0-9]*) VENDOR=mali ;;
        *) VENDOR="${GPU_HINT:-unknown}" ;;
    esac
fi

say "\n  AoE II + Voobly - Termux bootstrap" 1;33
say "  Android ${ANDROID_REL} (SDK ${ANDROID_SDK})"
say "  SoC: ${SOC:-unknown}"
say "  GPU: ${VENDOR}  (egl=${GPU_HINT:-?})"

if [ "$GPU" = auto ]; then
    # Adreno could use Turnip, but that needs a glibc-built Vulkan ICD this
    # installer does not ship; VirGL is the supported accelerated path here.
    case "$VENDOR" in
        adreno) GPU=virgl ;;
        *)      GPU=software ;;
    esac
fi
say "  Rendering: ${GPU} (software=llvmpipe, virgl=host virglrenderer)"
if [ "$VENDOR" = mali ] && [ "$GPU" = virgl ]; then
    say "  warning: VirGL on Mali is often unreliable; use --gpu=software if it fails." 33
fi

# ------------------------------------------------------- Termux packages ----
say "\n  Installing Termux packages" 1;36
pkg install -y x11-repo >/dev/null 2>&1 || true
pkg install -y termux-x11-nightly pulseaudio proot-distro \
    curl tar xz-utils coreutils >/dev/null 2>&1 || fail "pkg install failed."
if [ "$GPU" = virgl ]; then
    pkg install -y virglrenderer-android >/dev/null 2>&1 \
        || say "Could not install virglrenderer-android; falling back to software." 33
    pkg list-installed 2>/dev/null | grep -q '^virglrenderer-android/' || GPU=software
fi

command -v termux-x11 >/dev/null || fail "Install the Termux:X11 app, then re-run (https://github.com/termux/termux-x11/releases)."
command -v proot-distro >/dev/null || fail "proot-distro missing."

if [ ! -d "$HOME/storage/shared" ]; then
    say "\n  Grant storage access so your game directory can be used without copying." 33
    termux-setup-storage || true
    sleep 2
    [ -d "$HOME/storage/shared" ] || say "  (storage unavailable; folders inside Termux home still work)" 33
fi

# ------------------------------------------------ glibc container (Ubuntu) --
say "\n  Preparing proot-distro Ubuntu (glibc is required for Wine amd64-wow64)" 1;36
if ! proot-distro list --installed 2>/dev/null | grep -qi ubuntu; then
    proot-distro install ubuntu || fail "proot-distro install ubuntu failed."
fi

mkdir -p "$HOME/.aoe2-termux"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install-inside.sh" ]; then
    cp -f "$SCRIPT_DIR/install-inside.sh" "$HOME/.aoe2-termux/install-inside.sh"
else
    say "  Fetching the installer core from GitHub (${REPO_REF})" 2
    curl -fsSL "$REPO_RAW/install-inside.sh" -o "$HOME/.aoe2-termux/install-inside.sh" \
        || fail "Could not download install-inside.sh"
fi
chmod +x "$HOME/.aoe2-termux/install-inside.sh"

# ------------------------------------------------------------- run inside ---
say "\n  Running the installer inside Ubuntu" 1;36
proot-distro login ubuntu --termux-home --shared-tmp -- \
    env AOE2_GPU="$GPU" AOE2_VENDOR="$VENDOR" AOE2_SOC="$SOC" \
    bash "$HOME/.aoe2-termux/install-inside.sh" --ddraw="$DDRaw"
RC=$?
[ "$RC" -eq 0 ] || fail "Installer inside the container exited ${RC}."

# ------------------------------------------------------------ host runner ---
DATA_DIR="$HOME/.local/share/aoe2-multiplayer-linux"
RUNNER="$PREFIX/bin/aoe2-termux"
say "\n  Installing Termux launcher: $RUNNER" 1;36
cat > "$RUNNER" <<'EOS'
#!/data/data/com.termux/files/usr/bin/bash
# Launch one AoE II / Voobly action inside Termux:X11 + proot Ubuntu.
set -uo pipefail
DATA_DIR="$HOME/.local/share/aoe2-multiplayer-linux"
GPU="${AOE2_GPU:-software}"
slug="${1:-}"
[ -n "$slug" ] || { echo "usage: aoe2-termux play-aok|play-aoe2|play-voobly" >&2; exit 2; }
[ -x "$DATA_DIR/bin/$slug" ] || { echo "Launcher not found: $DATA_DIR/bin/$slug (run the installer first)." >&2; exit 1; }

start_x11() {
    pgrep -f 'termux.x11' >/dev/null 2>&1 && return 0
    nohup termux-x11 :0 -ac >/dev/null 2>&1 &
    sleep 1
}
start_audio() {
    pgrep -x pulseaudio >/dev/null 2>&1 || pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
    pactl load-module module-native-protocol-tcp auth-anonymous=1 listen=127.0.0.1 >/dev/null 2>&1 || true
}
start_virgl() {
    [ "$GPU" = virgl ] || return 0
    pgrep -f virgl_test_server_android >/dev/null 2>&1 && return 0
    nohup virgl_test_server_android >/dev/null 2>&1 & sleep 1
}

start_x11; start_audio; start_virgl
exec proot-distro login ubuntu --termux-home --shared-tmp -- \
    env DISPLAY=:0 PULSE_SERVER=tcp:127.0.0.1 AOE2_GPU="$GPU" \
    "$DATA_DIR/bin/$slug"
EOS
chmod +x "$RUNNER"

for slug in play-aok play-aoe2 play-voobly; do
    wrapper="$PREFIX/bin/$slug"
    printf '#!/data/data/com.termux/files/usr/bin/bash\nexec aoe2-termux %s "$@"\n' "$slug" > "$wrapper"
    chmod +x "$wrapper"
done

say "\n  Done." 1;32
say "  Launch from Termux:  play-aok | play-aoe2 | play-voobly"
say "  Or:                  aoe2-termux play-aoe2"
say "  Workspace:           ${DATA_DIR}"
say "  GPU mode:            ${GPU}"
