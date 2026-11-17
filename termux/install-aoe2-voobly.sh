#!/data/data/com.termux/files/usr/bin/bash
# AoE II Classic + Voobly - Android/Termux bootstrap.
#
# Stack: Termux + proot-distro Ubuntu (glibc) + Box64 + Wine 10.0 amd64-wow64
#        + one shared win64 prefix + Winetricks DirectPlay + Voobly + launchers.
# This host script prepares Android (packages, X11, audio, GPU mode, glibc
# container), then runs install-inside.sh inside the container.
#
# Usage (as the Termux user; no root, no sudo):
#   bash install-aoe2-voobly.sh [--gpu=auto|virgl|software] [--ddraw=wine|cnc]
#
# Prerequisites: Termux (F-Droid) and the Termux:X11 app
# (https://github.com/termux/termux-x11/releases).

set -Eeuo pipefail

# ------------------------------------------------------------------ config --
readonly REPO_REF="${AOE2_TERMUX_REF:-main}"
readonly REPO_RAW="https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/${REPO_REF}/termux"
readonly CONF_DIR="$HOME/.aoe2-termux"
readonly CONF_FILE="$CONF_DIR/config"
readonly LOG_FILE="$CONF_DIR/install.log"
readonly INSIDE_SCRIPT="$CONF_DIR/install-inside.sh"
readonly DATA_DIR="$HOME/.local/share/aoe2-multiplayer-linux"
readonly RUNNER="${PREFIX:-}/bin/aoe2-termux"
readonly SLUGS=(play-aok play-aoe2 play-voobly)

GPU=auto
DDRAW=wine

# ----------------------------------------------------------------- output ---
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

step() { printf '\n%s%s%s%s\n' "$C_BOLD" "$C_CYAN" "  $*" "$C_RESET"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '%s  warning: %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
ok()   { printf '\n%s%s  %s%s\n' "$C_BOLD" "$C_GREEN" "$*" "$C_RESET"; }
die()  { printf '%s  error: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

trap 'die "Unexpected failure at line ${LINENO} (details: ${LOG_FILE})"' ERR

# Run a command with its output appended to the log instead of the screen.
quiet() { "$@" >>"$LOG_FILE" 2>&1; }
prop()  { getprop "$1" 2>/dev/null || true; }

usage() {
    cat <<'EOF'
Usage: install-aoe2-voobly.sh [options]

  --gpu=auto|virgl|software   Rendering mode (default: auto)
  --ddraw=wine|cnc            DirectDraw backend (default: wine)
  -h, --help                  Show this help
EOF
}

# ------------------------------------------------------------- arguments ----
parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --gpu=*)   GPU=${arg#*=} ;;
            --ddraw=*) DDRAW=${arg#*=} ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "Unknown argument: $arg" ;;
        esac
    done
    case "$GPU"   in auto|virgl|software) ;; *) die "--gpu must be auto|virgl|software" ;; esac
    case "$DDRAW" in wine|cnc) ;;            *) die "--ddraw must be wine|cnc" ;; esac
}

# ------------------------------------------------------------- preflight ----
preflight() {
    [ -n "${PREFIX:-}" ] && [ -d "$PREFIX" ] || die "Run inside Termux (com.termux), not a generic shell."
    [ "$(uname -m)" = aarch64 ]             || die "This port requires an arm64-v8a device."
    [ "$(id -u)" -ne 0 ]                    || die "Run as the Termux user, not root."
    command -v pkg >/dev/null               || die "Termux 'pkg' not found; install Termux from F-Droid."

    ANDROID_REL=$(prop ro.build.version.release); ANDROID_REL=${ANDROID_REL:-?}
    ANDROID_SDK=$(prop ro.build.version.sdk);     ANDROID_SDK=${ANDROID_SDK:-0}
    if [ "$ANDROID_SDK" -lt 26 ] 2>/dev/null; then
        warn "Android 8+ is recommended (detected: ${ANDROID_REL})."
    fi
}

detect_hardware() {
    local board hw model
    board=$(prop ro.board.platform); hw=$(prop ro.hardware); model=$(prop ro.soc.model)
    SOC=$(printf '%s %s %s' "$board" "$hw" "$model" | tr -s ' ')
    GPU_HINT=$(prop ro.hardware.egl)

    local probe="${SOC}${GPU_HINT}"
    probe=${probe,,}
    if [ -e /sys/class/kgsl/kgsl-3d0 ]; then
        VENDOR=adreno
    else
        case "$probe" in
            *mali*|*exynos*|*mediatek*|*mt[0-9]*) VENDOR=mali ;;
            *) VENDOR=${GPU_HINT:-unknown} ;;
        esac
    fi
}

choose_gpu_mode() {
    if [ "$GPU" = auto ]; then
        # Adreno could use Turnip, but that needs a glibc-built Vulkan ICD this
        # installer does not ship; VirGL is the supported accelerated path.
        case "$VENDOR" in
            adreno) GPU=virgl ;;
            *)      GPU=software ;;
        esac
    fi
    if [ "$VENDOR" = mali ] && [ "$GPU" = virgl ]; then
        warn "VirGL on Mali is often unreliable; use --gpu=software if it fails."
    fi
}

print_banner() {
    printf '\n%s  AoE II + Voobly - Termux bootstrap%s\n' "$C_BOLD$C_YELLOW" "$C_RESET"
    info "Android ${ANDROID_REL} (SDK ${ANDROID_SDK})"
    info "SoC:  ${SOC:-unknown}"
    info "GPU:  ${VENDOR} (egl=${GPU_HINT:-?})"
    info "Mode: ${GPU} (software=llvmpipe, virgl=host virglrenderer)"
    info "Log:  ${LOG_FILE}"
}

# -------------------------------------------------------- Termux packages ---
pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

# Install packages; on failure refresh the package index once and retry.
pkg_install() {
    quiet pkg install -y "$@" && return 0
    quiet pkg update -y || true
    quiet pkg install -y "$@"
}

install_termux_packages() {
    step "Installing Termux packages"
    pkg_install x11-repo || true
    pkg_install termux-x11-nightly pulseaudio proot-distro curl tar xz-utils coreutils \
        || die "pkg install failed (see ${LOG_FILE})."

    if [ "$GPU" = virgl ]; then
        if ! pkg_install virglrenderer-android || ! pkg_installed virglrenderer-android; then
            warn "Could not install virglrenderer-android; falling back to software."
            GPU=software
        fi
    fi

    command -v termux-x11 >/dev/null \
        || die "termux-x11 missing. Install the Termux:X11 app (https://github.com/termux/termux-x11/releases) and re-run."
    command -v proot-distro >/dev/null || die "proot-distro missing."
}

setup_storage() {
    [ -d "$HOME/storage/shared" ] && return 0
    warn "Grant storage access so your game directory can be used without copying."
    termux-setup-storage || true
    sleep 2
    [ -d "$HOME/storage/shared" ] || warn "Storage unavailable; folders inside the Termux home still work."
}

# ------------------------------------------------- glibc container (Ubuntu) -
ubuntu_installed() {
    [ -d "$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu" ] \
        || proot-distro list 2>/dev/null | grep -qi 'ubuntu.*installed'
}

prepare_container() {
    step "Preparing proot-distro Ubuntu (glibc is required for Wine amd64-wow64)"
    if ! ubuntu_installed; then
        proot-distro install ubuntu || die "proot-distro install ubuntu failed."
    fi
}

stage_inside_script() {
    local self="${BASH_SOURCE[0]:-}" script_dir=""
    # Empty when piped via `curl ... | bash`.
    [ -n "$self" ] && [ -f "$self" ] && script_dir=$(cd -- "$(dirname -- "$self")" && pwd)

    if [ -n "$script_dir" ] && [ -f "$script_dir/install-inside.sh" ]; then
        cp -f "$script_dir/install-inside.sh" "$INSIDE_SCRIPT"
    else
        info "Fetching the installer core from GitHub (${REPO_REF})"
        curl -fsSL --retry 3 --connect-timeout 15 "$REPO_RAW/install-inside.sh" -o "$INSIDE_SCRIPT" \
            || die "Could not download install-inside.sh"
    fi
    chmod +x "$INSIDE_SCRIPT"
}

run_inside() {
    step "Running the installer inside Ubuntu"
    local rc=0
    proot-distro login ubuntu --termux-home --shared-tmp -- \
        env AOE2_GPU="$GPU" AOE2_VENDOR="$VENDOR" AOE2_SOC="$SOC" \
        bash "$INSIDE_SCRIPT" --ddraw="$DDRAW" || rc=$?
    [ "$rc" -eq 0 ] || die "Installer inside the container exited with code ${rc}."
}

# ----------------------------------------------------------- host launcher --
save_config() {
    cat > "$CONF_FILE" <<EOF
# Written by install-aoe2-voobly.sh; edit or override with env vars.
AOE2_GPU=${GPU}
EOF
}

install_runner() {
    step "Installing Termux launcher: $RUNNER"
    cat > "$RUNNER" <<'EOS'
#!/data/data/com.termux/files/usr/bin/bash
# Launch one AoE II / Voobly action inside Termux:X11 + proot Ubuntu.
set -uo pipefail

CONF="$HOME/.aoe2-termux/config"
DATA_DIR="$HOME/.local/share/aoe2-multiplayer-linux"
X_SOCKET="${TMPDIR:-$PREFIX/tmp}/.X11-unix/X0"

# Precedence: environment variable > saved config > software.
env_gpu="${AOE2_GPU:-}"
[ -r "$CONF" ] && . "$CONF"
GPU="${env_gpu:-${AOE2_GPU:-software}}"

usage() { echo "usage: aoe2-termux play-aok|play-aoe2|play-voobly|stop" >&2; exit 2; }

start_x11() {
    if ! pgrep -f 'termux.x11' >/dev/null 2>&1; then
        nohup termux-x11 :0 -ac >/dev/null 2>&1 &
    fi
    # Wait for the X socket instead of sleeping blindly.
    local i
    for i in $(seq 1 20); do [ -S "$X_SOCKET" ] && break; sleep 0.5; done
    # Bring the Termux:X11 app to the foreground.
    am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true
}

start_audio() {
    pgrep -x pulseaudio >/dev/null 2>&1 \
        || pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
    pactl list short modules 2>/dev/null | grep -q module-native-protocol-tcp \
        || pactl load-module module-native-protocol-tcp auth-anonymous=1 listen=127.0.0.1 >/dev/null 2>&1 \
        || true
}

start_virgl() {
    [ "$GPU" = virgl ] || return 0
    pgrep -f virgl_test_server_android >/dev/null 2>&1 && return 0
    nohup virgl_test_server_android >/dev/null 2>&1 &
    sleep 1
}

stop_all() {
    pkill -f virgl_test_server_android 2>/dev/null
    pulseaudio --kill 2>/dev/null
    pkill -f 'termux.x11' 2>/dev/null
    termux-wake-unlock 2>/dev/null
    echo "Stopped X11, audio and VirGL helpers."
    exit 0
}

slug="${1:-}"
[ -n "$slug" ] || usage
[ "$slug" = stop ] && stop_all
[ -x "$DATA_DIR/bin/$slug" ] || {
    echo "Launcher not found: $DATA_DIR/bin/$slug (run the installer first)." >&2
    exit 1
}

termux-wake-lock 2>/dev/null || true
start_x11
start_audio
start_virgl

exec proot-distro login ubuntu --termux-home --shared-tmp -- \
    env DISPLAY=:0 PULSE_SERVER=tcp:127.0.0.1 AOE2_GPU="$GPU" \
    "$DATA_DIR/bin/$slug"
EOS
    chmod +x "$RUNNER"

    local slug wrapper
    for slug in "${SLUGS[@]}"; do
        wrapper="$PREFIX/bin/$slug"
        printf '#!/data/data/com.termux/files/usr/bin/bash\nexec aoe2-termux %s "$@"\n' "$slug" > "$wrapper"
        chmod +x "$wrapper"
    done
}

print_summary() {
    ok "Done."
    info "Launch from Termux:  ${SLUGS[*]// / | }"
    info "Or:                  aoe2-termux play-aoe2"
    info "Stop helpers:        aoe2-termux stop"
    info "Workspace:           ${DATA_DIR}"
    info "GPU mode:            ${GPU} (saved in ${CONF_FILE})"
}

# ------------------------------------------------------------------ main ----
main() {
    # `curl ... | bash` makes stdin the script source; prompts need the terminal.
    if [ ! -t 0 ] && [ -r /dev/tty ]; then exec </dev/tty; fi

    parse_args "$@"
    preflight
    mkdir -p "$CONF_DIR"
    : >> "$LOG_FILE"

    detect_hardware
    choose_gpu_mode
    print_banner

    install_termux_packages   # may downgrade GPU to software
    setup_storage
    prepare_container
    stage_inside_script
    run_inside
    save_config
    install_runner
    print_summary
}

main "$@"