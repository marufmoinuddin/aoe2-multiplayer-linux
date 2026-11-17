#!/data/data/com.termux/files/usr/bin/bash
# Bootstrap for the native Termux AoE II + Voobly installer.
# Installs Python, downloads install_aoe2_voobly_termux.py, and runs it.
#
#   curl -fsSL https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/main/termux/install-aoe2-voobly.sh | bash
#   ... | bash -s -- --renderer=gl -v        (extra args go to the installer)
set -euo pipefail

REF="${AOE2_TERMUX_REF:-main}"
BASE="https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/${REF}/termux"
PY_NAME="install_aoe2_voobly_termux.py"
DEST="${HOME}/.aoe2-termux"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -n "${PREFIX:-}" ] && [ -d "$PREFIX" ] || die "Run inside Termux (F-Droid or GitHub build)."
[ "$(id -u)" -ne 0 ] || die "Run as the Termux user, not root."

command -v python3 >/dev/null 2>&1 || { echo "Installing Python..."; pkg install -y python curl; }
command -v curl >/dev/null 2>&1 || pkg install -y curl

mkdir -p "$DEST"
# Prefer a copy next to this script (cloned repo); otherwise download it.
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$(dirname -- "$SELF")/$PY_NAME" ]; then
    cp -f "$(dirname -- "$SELF")/$PY_NAME" "$DEST/$PY_NAME"
else
    curl -fsSL --retry 3 "$BASE/$PY_NAME" -o "$DEST/$PY_NAME" || die "Could not download $PY_NAME from $BASE"
fi

# `curl | bash` leaves stdin as the pipe; give the installer the terminal for its prompts.
if [ ! -t 0 ] && [ -r /dev/tty ]; then exec </dev/tty; fi
exec python3 "$DEST/$PY_NAME" "$@"