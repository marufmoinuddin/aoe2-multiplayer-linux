#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
: "${PREFIX:?Run inside Termux}"
command -v curl >/dev/null || pkg install -y curl
DEST="$HOME/.aoe2-termux"
mkdir -p "$DEST"
SELF="${BASH_SOURCE[0]:-}"
if [[ -f "$(dirname -- "$SELF")/install-mobox-aoe2.sh" ]]; then
    cp -- "$(dirname -- "$SELF")/install-mobox-aoe2.sh" "$DEST/install-mobox-aoe2.sh"
else
    curl -fL --retry 3 "https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/${AOE2_TERMUX_REF:-main}/termux/install-mobox-aoe2.sh" -o "$DEST/install-mobox-aoe2.sh"
fi
bash -n "$DEST/install-mobox-aoe2.sh"
exec bash "$DEST/install-mobox-aoe2.sh" "$@"
