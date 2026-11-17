#!/usr/bin/env bash
# AoE II Classic + Voobly - installer core for the Termux glibc container.
#
# Runs INSIDE `proot-distro login ubuntu --termux-home` (see the host script).
# It mirrors the Linux installer (../../install_aoe2_voobly.py): same stage
# order, same data layout under ~/.local/share/aoe2-multiplayer-linux, same
# pinned Wine 10.0 amd64-wow64 runner, shared win64 prefix, Winetricks
# DirectPlay, Voobly and play-* launchers. Android specifics live only in the
# host bootstrap (X11, audio, GPU mode) and in the launch environment here.
set -uo pipefail

# `curl ... | bash` makes stdin the script source; interactive prompts
# must read the terminal instead.
if [ ! -t 0 ] && [ -r /dev/tty ]; then exec </dev/tty; fi

DDRaw=wine
for arg in "$@"; do
    case "$arg" in
        --ddraw=*) DDRaw=${arg#*=} ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done
case "$DDRaw" in wine|cnc) ;; *) echo "--ddraw must be wine|cnc" >&2; exit 2 ;; esac

HOME_DIR="${HOME:?}"
DATA="$HOME_DIR/.local/share/aoe2-multiplayer-linux"
CACHE="$HOME_DIR/.cache/aoe2-multiplayer-linux"
TRANSLATOR="$DATA/translator"
RUNNERS="$DATA/runners"
BIN="$DATA/bin"
TOOLS="$DATA/tools"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$DATA/logs/$STAMP.log"
TOTAL_STAGES=8
GPU="${AOE2_GPU:-software}"
VENDOR="${AOE2_VENDOR:-unknown}"
COLOR=$([ -t 1 ] && [ -z "${NO_COLOR:-}" ] && echo 1 || echo 0)

WINE_VERSION=10.0
WINE_ARCHIVE="wine-$WINE_VERSION-amd64-wow64.tar.xz"
WINE_SHA256=aeebbbf239e548f0136f1cd72a2e109dd9a572a8f703da3c09fa40d74d5c255f
WINE_URL="https://github.com/Kron4ek/Wine-Builds/releases/download/$WINE_VERSION/$WINE_ARCHIVE"
BOX64_DEB=box64_0.4.3-3+dfsg-1_arm64.deb
BOX64_URL="http://deb.debian.org/debian/pool/main/b/box64/$BOX64_DEB"
BOX64_SHA256=136cf47a54345d180cdcdb61ac320717d50047d6c0d13ca5e3f6335cd7e1bdbf
X64LIB_RPM=libgcc-11.5.0-17.el9_9.alma.1.x86_64.rpm
X64LIB_URL="https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/Packages/$X64LIB_RPM"
X64LIB_SHA256=1248acf03287807e448174d8753b7b8a9b2cc46f40f237281c91f20fa2339386
CNC_ZIP=cnc-ddraw.zip
CNC_URL="https://github.com/FunkyFr3sh/cnc-ddraw/releases/download/v7.1.0.0/$CNC_ZIP"
CNC_SHA256=0b13ab89a64c9918189b1dadd449ef6ed3cb3b7b19cabd96d8adbd95505bb908
DIRECTPLAY_FILES="dplayx.dll dpnet.dll dpnhpast.dll dpwsockx.dll"
DIRECTX_REDIST_NAME=directx_feb2010_redist.exe
DIRECTX_REDIST_SHA256=f6d191e89a963d7cca34f169d30f49eab99c1ed3bb92da73ec43617caaa1e93f
DIRECTX_REDIST_MIRRORS="
https://files.holarse-linuxgaming.de/mirrors/microsoft/directx_feb2010_redist.exe
https://web.archive.org/web/20100205000000id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe
https://web.archive.org/web/20101224202650id_/http://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe
https://web.archive.org/web/2016id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe
"

# ------------------------------------------------------------------- ui -----
say()  { if [ "$COLOR" = 1 ]; then printf '\033[%sm%s\033[0m\n' "${2:-36}" "$1"; else printf '%s\n' "$1"; fi; }
die()  { say "$1" 31; say "Log: $LOG" 33; exit 1; }
ask()  { local p=$1 d=${2:-} a; [ -n "$d" ] && p="$p [$d]"; printf '\033[1;36m❯\033[0m %s: ' "$p"; read -r a; printf '%s' "${a:-$d}"; }
yes()  { local a d=${2:-n} prompt
    if [ "$d" = y ]; then prompt="$1 [Y/n]"; else prompt="$1 [y/N]"; fi
    a=$(ask "$prompt"); [ -z "$a" ] && a=$d
    case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac; }
stage() {
    local n=$1 t=$2 dots="" i
    for i in $(seq 1 $TOTAL_STAGES); do
        if [ "$i" -lt "$n" ]; then dots="$dots● "; elif [ "$i" -eq "$n" ]; then dots="$dots▶ "; else dots="$dots○ "; fi
    done
    say "" 
    say "  ╭──────────────────────────────────────────────────────────────╮" 1;36
    say "  │ [$n/$TOTAL_STAGES]  $t" 1;36
    say "  │ $dots" 1;36
    say "  ╰──────────────────────────────────────────────────────────────╯" 1;36
}
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

# ------------------------------------------------------------- utilities ----
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

download() { # url dest sha256
    local url=$1 dest=$2 sum=$3 tmp
    if [ -f "$dest" ] && [ -n "$sum" ] && [ "$(sha256_of "$dest")" = "$sum" ]; then
        say "  ✔ $(basename "$dest") (already downloaded)" 32; return 0
    fi
    mkdir -p "$(dirname "$dest")"
    tmp="$dest.part"
    say "  ↓ $(basename "$dest")" 2
    curl -fL --retry 3 --connect-timeout 20 -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    if [ -n "$sum" ]; then
        if [ "$(sha256_of "$tmp")" != "$sum" ]; then
            rm -f "$tmp"; say "  SHA256 mismatch for $(basename "$dest")" 31; return 1
        fi
    fi
    mv -f "$tmp" "$dest"
    say "  ✔ $(basename "$dest") ($(du -h "$dest" | cut -f1), SHA256 verified)" 32
}

pe_machine() { # prints PE machine hex (14c i386, 8664 x86_64) or nothing
    local f=$1 mz off sig
    [ -f "$f" ] || return 1
    mz=$(od -An -tx1 -N2 "$f" | tr -d ' \n')
    [ "$mz" = "4d5a" ] || return 1
    off=$(od -An -tu4 -j60 -N4 "$f" | tr -d ' \n')
    [ "${off:-0}" -gt 0 ] 2>/dev/null || return 1
    sig=$(od -An -tx1 -j"$off" -N4 "$f" | tr -d ' \n')
    [ "$sig" = "50450000" ] || return 1
    od -An -tx2 -j$((off + 4)) -N2 "$f" | tr -d ' \n'
}

find_ci() { # dir name -> paths, shallowest first
    local dir=$1 name=$2
    find "$dir" -maxdepth 6 -type f -iname "$name" 2>/dev/null | awk '{print length($0) " " $0}' | sort -n | cut -d' ' -f2-
}

wine_env() { # sets env for any wine invocation
    export WINEPREFIX="$PREFIX_DIR"
    export WINEARCH=win64
    export WINEDEBUG=-all
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d}"
    export WINE="$BIN/wine" WINESERVER="$BIN/wineserver"
    export PATH="$BIN:$RUNNER/bin:$PATH"
    export BOX64_NOBANNER=1
    export BOX64_PATH="$BIN:$RUNNER/bin"
    export BOX64_LD_LIBRARY_PATH="$X64LIB_DIR:$RUNNER/lib/wine/x86_64-unix:$RUNNER/lib"
    unset LD_PRELOAD LD_LIBRARY_PATH 2>/dev/null || true
}

run() { # description command...
    local desc=$1; shift
    log "RUN: $*"
    if "$@" >>"$LOG" 2>&1; then return 0; fi
    say "  ✖ $desc" 31
    tail -n 40 "$LOG" | sed 's/^/    │ /' >&2
    return 1
}

run_out() { # capture stdout+stderr into OUT (also logged)
    local desc=$1; shift
    log "RUN(out): $*"
    OUT=$("$@" 2>&1); local rc=$?
    log "EXIT $rc: $OUT"
    return $rc
}

# ================================================================= main =====
[ "$(uname -m)" = "aarch64" ] || die "Installer core must run in an aarch64 glibc container."
mkdir -p "$DATA"/{logs,installs,backups,bin,tools,x64libs} "$CACHE" "$TRANSLATOR"

say "\n╔══════════════════════════════════════════════════════════════╗" 1;33
say "║        AGE OF EMPIRES II  ×  VOOBLY   —  Termux               ║" 1;33
say "║        Wine 10.0 amd64-wow64 · Box64 · shared win64 prefix    ║" 1;33
say "╚══════════════════════════════════════════════════════════════╝" 1;33
say "  GPU mode: $GPU   SoC: ${AOE2_SOC:-?}" 2

# ---------------------------------------------------- 1/8 paths -----------
stage 1 "Choose paths"
GAME_DEFAULT="$HOME_DIR/storage/shared/Games/Age of Empires II"
GAME=$(ask "Original AoE II game directory" "$GAME_DEFAULT")
[ -d "$GAME" ] || die "Game directory not found: $GAME"
VOOBLY_CAND=$(find "$HOME_DIR/storage/shared/Download" "$HOME_DIR/Downloads" \
    "$HOME_DIR/storage/shared" -maxdepth 2 -type f -iname '*voobly*.exe' 2>/dev/null | head -n1)
VOOBLY_SETUP=$(ask "Voobly setup executable" "${VOOBLY_CAND:-$HOME_DIR/storage/shared/Download/voobly.exe}")
[ -f "$VOOBLY_SETUP" ] || die "Voobly setup executable not found: $VOOBLY_SETUP"
PREFIX_DIR=$(ask "Wine prefix" "$DATA/prefix")
PREFIX_DIR=$(readlink -m "$PREFIX_DIR")

AOK=$(find_ci "$GAME" empires2.exe | head -n1); [ -n "$AOK" ] || AOK=$(find_ci "$GAME" age2.exe | head -n1)
AOC=$(find_ci "$GAME" age2_x1.exe | head -n1); [ -n "$AOC" ] || AOC=$(find_ci "$GAME" age2x1.exe | head -n1)
[ -n "$AOK" ] && [ -n "$AOC" ] || die "Game directory must contain empires2.exe/age2.exe and age2_x1.exe (classic AoE II + Conquerors)."
[ "$(pe_machine "$AOK")" = "014c" ] && [ "$(pe_machine "$AOC")" = "014c" ] \
    || die "Expected original i386 PE32 executables (HD/DE builds are not supported)."
AOK_REL=${AOK#"$GAME"/}; AOC_REL=${AOC#"$GAME"/}

IDENT=$(printf '%s' "$PREFIX_DIR" | sha256sum | cut -c1-12)
STATEFILE="$DATA/installs/$IDENT.json"

say "" 
say "  Game:    $GAME"
say "  AoK:     $AOK_REL"
say "  Conq:    $AOC_REL"
say "  Setup:   $VOOBLY_SETUP"
say "  Prefix:  $PREFIX_DIR"
yes "Proceed with this configuration?" y || { say "Cancelled." 33; exit 0; }

if [ -f "$PREFIX_DIR/system.reg" ] || [ -f "$RUNNERS/${WINE_ARCHIVE%.tar.xz}/.complete" ]; then
    say "\n  Existing installation detected (prefix/runner)." 33
    if yes "Replace the previous prefix/install? (default keeps and reuses everything)"; then
        if [ -f "$BIN/wineserver" ]; then WINEPREFIX="$PREFIX_DIR" "$BIN/wineserver" -k >>"$LOG" 2>&1 || true; fi
        rm -rf "$PREFIX_DIR" "$STATEFILE" "$TOOLS/voobly-client-path"
        say "  Replaced; downloads and the verified runner are kept." 33
    else
        say "  Reusing the existing installation." 32
    fi
fi

# ------------------------------------------------- 2/8 preflight ----------
stage 2 "Container preflight and helper packages"
export DEBIAN_FRONTEND=noninteractive
run "apt update" apt-get update -qq || die "apt update failed"
run "install dependencies" apt-get install -y -qq \
    ca-certificates curl xz-utils cabextract unzip icoutils cpio rpm file procps \
    libasound2t64 libpulse0 libfreetype6 libgl1-mesa-dri libglx-mesa0 libgl1 libegl1 \
    libx11-6 libxext6 libxrender1 libxrandr2 libxi6 libxcursor1 libxfixes3 \
    libxinerama1 libxcomposite1 libxdamage1 libsm6 libice6 libxkbcommon0 libxkbcommon-x11-0 \
    mesa-utils >/dev/null 2>&1 \
  || run "install dependencies (fallback names)" apt-get install -y -qq \
    ca-certificates curl xz-utils cabextract unzip icoutils cpio rpm file procps \
    libasound2 libpulse0 libfreetype6 libgl1-mesa-dri libglx-mesa0 libgl1 libegl1 \
    libx11-6 libxext6 libxrender1 libxrandr2 libxi6 libxcursor1 libxfixes3 \
    libxinerama1 libxcomposite1 libxdamage1 libsm6 libice6 libxkbcommon0 libxkbcommon-x11-0 \
    mesa-utils >/dev/null 2>&1 || die "Dependency installation failed."

for cmd in curl cabextract unzip wrestool icotool xz tar cpio file; do
    command -v "$cmd" >/dev/null || die "Required command missing: $cmd"
done

# box64: use a container package if present, else a pinned prebuilt .deb (no build).
BOX64=""
if command -v box64 >/dev/null 2>&1; then
    BOX64=$(command -v box64)
    say "  box64: $BOX64 (container-provided)" 32
else
    mkdir -p "$TRANSLATOR"
    BOX64="$TRANSLATOR/box64"
    if [ ! -x "$BOX64" ]; then
        download "$BOX64_URL" "$CACHE/$BOX64_DEB" "$BOX64_SHA256" || die "box64 download failed"
        rm -rf "$TRANSLATOR/.deb" && mkdir -p "$TRANSLATOR/.deb"
        dpkg-deb -x "$CACHE/$BOX64_DEB" "$TRANSLATOR/.deb" || die "box64 extraction failed"
        cp -f "$TRANSLATOR/.deb/usr/bin/box64" "$BOX64" || die "box64 binary missing in package"
        chmod +x "$BOX64"; rm -rf "$TRANSLATOR/.deb"
    fi
    say "  box64: $BOX64 (pinned 0.4.3)" 32
fi
BOX64_ABS=$(readlink -f "$BOX64")

# ---------------------------------------------- 3/8 wine runner ----------
stage 3 "Install and verify the prebuilt Wine runner"
RUNNER="$RUNNERS/${WINE_ARCHIVE%.tar.xz}"
if [ ! -f "$RUNNER/.complete" ]; then
    ARCHIVE="$CACHE/$WINE_ARCHIVE"
    [ -f "$ARCHIVE" ] || download "$WINE_URL" "$ARCHIVE" "$WINE_SHA256" || die "Wine download failed"
    [ "$(sha256_of "$ARCHIVE")" = "$WINE_SHA256" ] || die "Wine archive checksum mismatch"
    tmp=$(mktemp -d "$RUNNERS/.tmp.XXXXXX") || die "mktemp failed"
    tar -xJf "$ARCHIVE" -C "$tmp" || die "Wine archive extraction failed"
    src=$(find "$tmp" -maxdepth 2 -type f -path '*/bin/wine' | head -n1)
    [ -n "$src" ] || die "Archive does not contain bin/wine"
    mv "$(dirname "$(dirname "$src")")" "$RUNNER" || die "Could not place runner"
    rm -rf "$tmp"
    printf '%s\n' "$WINE_SHA256" > "$RUNNER/.complete"
fi
for f in wine wineserver; do
    [ -x "$RUNNER/bin/$f" ] || die "Runner component missing: $RUNNER/bin/$f"
done
say "  runner: $RUNNER (Wine $WINE_VERSION amd64-wow64)" 32

# Emulated x86_64 libgcc_s: box64 does not wrap libgcc_s and arm64 containers
# ship no x86_64 libraries, so Wine's ntdll.so cannot load without it.
X64LIB_DIR="$TRANSLATOR/x64libs/lib64"
if ! find "$TRANSLATOR/x64libs" -name libgcc_s.so.1 -print -quit 2>/dev/null | grep -q .; then
    download "$X64LIB_URL" "$CACHE/$X64LIB_RPM" "$X64LIB_SHA256" || die "libgcc download failed"
    mkdir -p "$TRANSLATOR/x64libs"
    ( cd "$TRANSLATOR/x64libs" && rpm2cpio "$CACHE/$X64LIB_RPM" | cpio -idm --quiet ) \
        || die "libgcc extraction failed"
    found=$(find "$TRANSLATOR/x64libs" -name libgcc_s.so.1 -print -quit)
    [ -n "$found" ] || die "libgcc_s.so.1 not found after extraction"
    X64LIB_DIR=$(dirname "$found")
    say "  x86_64 libgcc_s.so.1 ready in $X64LIB_DIR" 32
fi

mkdir -p "$BIN"
cat > "$BIN/wine" <<EOS
#!/usr/bin/env bash
set -uo pipefail
export PATH="$BIN:$RUNNER/bin:\$PATH"
export WINEPREFIX="\${WINEPREFIX:-$PREFIX_DIR}"
export WINEARCH=win64
export WINEDLLOVERRIDES="\${WINEDLLOVERRIDES:-winemenubuilder.exe=d}"
export BOX64_NOBANNER=1
export BOX64_PATH="$BIN:$RUNNER/bin"
export BOX64_LD_LIBRARY_PATH="$X64LIB_DIR:$RUNNER/lib/wine/x86_64-unix:$RUNNER/lib"
exec "$BOX64_ABS" "$RUNNER/bin/wine" "\$@"
EOS
sed 's#bin/wine#bin/wineserver#g; s#RUNNER/bin/wineserver#RUNNER/bin/wineserver#' "$BIN/wine" > "$BIN/wineserver"
chmod +x "$BIN/wine" "$BIN/wineserver"

wine_env
run_out "wine version" "$BIN/wine" --version || die "Wine could not execute via box64"
case "$OUT" in wine-10*) say "  Wine: $OUT" 32 ;; *) die "Unexpected Wine version output: $OUT" ;; esac

# ------------------------------------------------- 4/8 win64 prefix -------
stage 4 "Create a win64 prefix and verify 32-bit Windows execution"
if [ ! -f "$PREFIX_DIR/system.reg" ]; then
    [ -d "$PREFIX_DIR" ] && [ -n "$(ls -A "$PREFIX_DIR" 2>/dev/null)" ] \
        && die "Prefix directory is non-empty and unmanaged: $PREFIX_DIR"
    run "wineboot --init" "$BIN/wine" wineboot --init || die "wineboot failed"
fi
grep -q '^#arch=win64' "$PREFIX_DIR/system.reg" || die "Expected a win64 prefix (#arch mismatch)."
for f in cmd.exe ntdll.dll kernel32.dll; do
    [ -f "$PREFIX_DIR/drive_c/windows/syswow64/$f" ] || die "Missing 32-bit component: $f"
done
run_out "32-bit cmd.exe" "$BIN/wine" "$PREFIX_DIR/drive_c/windows/syswow64/cmd.exe" /d /c "echo WIN32_APP_OK"
case "$OUT" in *WIN32_APP_OK*) say "  32-bit Windows cmd.exe executed successfully." 32 ;;
    *) die "32-bit Windows execution failed in this prefix." ;; esac
run "set Windows version" "$BIN/wine" reg add 'HKCU\Software\Wine' /v Version /d win10 /f || true

# ------------------------------------------------- 5/8 game mapping -------
stage 5 "Expose the existing game to Wine"
drive_visible() { # drive e.g. Y:  (quote-free: cmd.exe cannot parse \" escapes)
    run_out "" "$BIN/wine" cmd /d /c "if exist $1\\ echo AOE_DRIVE_OK" || true
    case "$OUT" in *AOE_DRIVE_OK*) return 0;; *) return 1;; esac
}
GAME_ABS=$(readlink -f "$GAME")
chosen=""
for letter in y x w v u t s r q p o n m l k j i h g f e d; do
    link="$PREFIX_DIR/dosdevices/$letter:"
    if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$GAME_ABS" ]; then chosen=$letter; break; fi
done
if [ -z "$chosen" ]; then
    for letter in y x w v u t s r q p o n m l k j i h g f e d; do
        link="$PREFIX_DIR/dosdevices/$letter:"
        if [ ! -e "$link" ] && [ ! -L "$link" ]; then ln -s "$GAME_ABS" "$link" && chosen=$letter; break; fi
    done
fi
DRIVE="Z:"; GAME_WIN="Z:$(printf '\\%s' "$GAME_ABS" | sed 's#/#\\#g')"
if [ -n "$chosen" ]; then
    DRIVE="${chosen^^}:"
    GAME_WIN="$DRIVE\\$(printf '%s' "$AOC_REL" | sed 's#/#\\#g')"
    ok=0
    for attempt in 1 2 3; do
        if drive_visible "$DRIVE"; then ok=1; break; fi
        [ "$attempt" -lt 3 ] && { "$BIN/wineserver" -k >>"$LOG" 2>&1 || true
                                  "$BIN/wineserver" -w >>"$LOG" 2>&1 || true; }
    done
    [ "$ok" = 1 ] || { say "  Drive $DRIVE not listed by Wine; using Z: instead." 33; DRIVE="Z:"
                       GAME_WIN="Z:$(printf '\\%s' "$GAME_ABS" | sed 's#/#\\#g')\\$(printf '%s' "$AOC_REL" | sed 's#/#\\#g')"
                       drive_visible Z: || die "Game is not accessible through Wine."; }
fi
say "  $DRIVE -> $GAME_ABS" 32
say "  Conquerors: $GAME_WIN" 32

if ! yes "Back up the original game directory before Voobly patches it? (optional)"; then
    say "  Backup skipped." 2
else
    BACKUP="$GAME.backup-$STAMP"
    say "  Copying to $BACKUP ..." 33
    cp -a "$GAME" "$BACKUP" || say "  Backup failed (continuing)." 33
fi

# ------------------------------------------------- 6/8 DirectPlay ---------
seed_directplay_redist() {
    # Winetricks fetches the Feb 2010 DirectX redist from one archive.org
    # snapshot that often 503s; winetricks accepts a cached file whose SHA256
    # matches, so pre-seed it from mirrors (same pin as winetricks itself).
    local dir="$CACHE/winetricks/directx9" f="$dir/$DIRECTX_REDIST_NAME" url
    [ -f "$f" ] && [ "$(sha256_of "$f")" = "$DIRECTX_REDIST_SHA256" ] && return 0
    mkdir -p "$dir"
    for url in $DIRECTX_REDIST_MIRRORS; do
        say "  trying DirectX redist mirror: $(printf '%s' "$url" | cut -d/ -f3)" 2
        if curl -fL --retry 2 --connect-timeout 15 -o "$f.part" "$url" 2>/dev/null; then
            if [ "$(sha256_of "$f.part")" = "$DIRECTX_REDIST_SHA256" ]; then
                mv -f "$f.part" "$f"; say "  ✔ DirectX redist cached" 32; return 0
            fi
        fi
        rm -f "$f.part"
    done
    return 1
}

stage 6 "Install native DirectPlay"
WT="$TOOLS/winetricks"
if [ ! -f "$WT" ]; then
    commit=$(curl -s --max-time 30 https://api.github.com/repos/Winetricks/winetricks/commits/master \
        | grep -m1 '"sha"' | cut -d'"' -f4)
    [ -n "$commit" ] || die "Could not resolve a Winetricks commit"
    download "https://raw.githubusercontent.com/Winetricks/winetricks/$commit/src/winetricks" "$WT" "" \
        || die "Winetricks download failed"
    chmod +x "$WT"
fi
bash -n "$WT" || die "Winetricks script failed syntax check"

have_dp=1
for f in $DIRECTPLAY_FILES; do
    [ "$(pe_machine "$PREFIX_DIR/drive_c/windows/syswow64/$f")" = "014c" ] || have_dp=0
done
registered=0
run_out "reg query DllOverrides" "$BIN/wine" reg query 'HKCU\Software\Wine\DllOverrides' || true
printf '%s\n' "$OUT" | grep -Eqi '"?\*?dplayx"?[[:space:]]+REG_SZ[[:space:]]+n(ative)?' && registered=1

if [ "$have_dp" = 1 ] && [ "$registered" = 1 ]; then
    say "  Native DirectPlay already installed and registered." 32
else
    export WINETRICKS_CACHE="$CACHE/winetricks"
    # Winetricks inspects $WINE/$WINESERVER for arch/WoW64 detection; wrappers
    # are shell scripts, so point it at the real runner binaries.
    export WINE_BIN="$RUNNER/bin/wine" WINESERVER_BIN="$RUNNER/bin/wineserver"
    WINE="$BIN/wine" WINESERVER="$BIN/wineserver" WINEPREFIX="$PREFIX_DIR" WINEARCH=win64
    export WINE WINESERVER WINEPREFIX WINEARCH
    if [ "$have_dp" = 0 ] || [ "$registered" = 0 ]; then
        seed_directplay_redist || say "  DirectX redist not pre-cached; winetricks will try archive.org." 33
        "$BIN/wineserver" -k >>"$LOG" 2>&1 || true
        "$BIN/wineserver" -w >>"$LOG" 2>&1 || true
        ok=0
        for attempt in 1 2 3; do
            say "  Running winetricks -q directplay (attempt $attempt/3)..." 33
            if "$WT" -q directplay >>"$LOG" 2>&1; then ok=1; break; fi
            [ "$attempt" -lt 3 ] && { say "  attempt $attempt failed; retrying" 33; sleep $((attempt * 5)); }
        done
        [ "$ok" = 1 ] || die "winetricks directplay failed after 3 attempts. Put $DIRECTX_REDIST_NAME (sha256 $DIRECTX_REDIST_SHA256) into $CACHE/winetricks/directx9/ and rerun."
    fi
    bad=""
    for f in $DIRECTPLAY_FILES; do
        [ "$(pe_machine "$PREFIX_DIR/drive_c/windows/syswow64/$f")" = "014c" ] || bad="$bad $f"
    done
    [ -z "$bad" ] || die "DirectPlay files missing in syswow64:$bad"
    run_out "reg query DllOverrides" "$BIN/wine" reg query 'HKCU\Software\Wine\DllOverrides' || true
    printf '%s\n' "$OUT" | grep -Eqi '"?\*?dplayx"?[[:space:]]+REG_SZ[[:space:]]+n(ative)?' \
        || die "DirectPlay DLL overrides are not registered."
    say "  DirectPlay installed and registered." 32
fi
unset WINE_BIN WINESERVER_BIN WINETRICKS_CACHE 2>/dev/null || true

# ------------------------------------------------- 7/8 Voobly -------------
stage 7 "Install Voobly and create launchers"
VOOBLY=""
if [ -f "$TOOLS/voobly-client-path" ]; then
    VOOBLY=$(head -n1 "$TOOLS/voobly-client-path" 2>/dev/null || true)
    [ -f "$VOOBLY" ] || VOOBLY=""
fi
[ -n "$VOOBLY" ] || VOOBLY=$(find_ci "$PREFIX_DIR/drive_c" voobly.exe | grep -i voobly | head -n1)
if [ -z "$VOOBLY" ]; then
    say "  The Voobly installer will open inside Termux:X11." 33
    yes "Start the Voobly installer now?" y || die "Voobly installation declined."
    run "Voobly installer" "$BIN/wine" "$VOOBLY_SETUP" || die "Voobly installer failed"
    run "wineboot -u" "$BIN/wine" wineboot -u || true
    VOOBLY=$(find_ci "$PREFIX_DIR/drive_c" voobly.exe | grep -i voobly | head -n1)
    [ -n "$VOOBLY" ] || die "Voobly executable not found after installation."
else
    say "  Voobly already installed: $VOOBLY" 32
fi
printf '%s\n' "$VOOBLY" > "$TOOLS/voobly-client-path"

DDRAW_ENV=''
if [ "$DDRaw" = cnc ]; then
    say "  Installing cnc-ddraw (legacy DirectDraw renderer) into the game directory" 33
    if [ -f "$GAME/ddraw.dll" ] && ! yes "Game already has ddraw.dll; replace with cnc-ddraw?"; then
        DDRAW_ENV=''
    else
        download "$CNC_URL" "$CACHE/$CNC_ZIP" "$CNC_SHA256" || die "cnc-ddraw download failed"
        mkdir -p "$TOOLS/cnc-ddraw"
        unzip -oq "$CACHE/$CNC_ZIP" -d "$TOOLS/cnc-ddraw" || die "cnc-ddraw extraction failed"
        cp -f "$TOOLS/cnc-ddraw/ddraw.dll" "$GAME/ddraw.dll" || die "Could not copy ddraw.dll"
        [ -f "$TOOLS/cnc-ddraw/ddraw.ini" ] && cp -f "$TOOLS/cnc-ddraw/ddraw.ini" "$GAME/ddraw.ini"
        DDRAW_ENV='WINEDLLOVERRIDES="winemenubuilder.exe=d;ddraw=n,b"'
        say "  cnc-ddraw installed (remove ddraw.dll/ddraw.ini from the game dir to revert)." 32
    fi
fi

make_launcher() { # slug title rel|exe args
    local slug=$1 title=$2 target=$3 extra=$4
    cat > "$BIN/$slug" <<EOS
#!/usr/bin/env bash
set -uo pipefail
export DISPLAY="\${DISPLAY:-:0}"
export PULSE_SERVER="\${PULSE_SERVER:-tcp:127.0.0.1}"
case "\${AOE2_GPU:-$GPU}" in
    virgl) export GALLIUM_DRIVER=virpipe MESA_LOADER_DRIVER_OVERRIDE=virpipe ;;
    *)     export GALLIUM_DRIVER=llvmpipe ;;
esac
export WINEPREFIX="$PREFIX_DIR"
export WINEARCH=win64
export WINE="$BIN/wine"
export WINESERVER="$BIN/wineserver"
export PATH="$BIN:$RUNNER/bin:\$PATH"
export WINEDLLOVERRIDES="$([ -n "$DDRAW_ENV" ] && printf 'winemenubuilder.exe=d;ddraw=n,b' || printf 'winemenubuilder.exe=d')"
export WINEDEBUG=-all,err+all
export BOX64_NOBANNER=1
export BOX64_PATH="$BIN:$RUNNER/bin"
export BOX64_LD_LIBRARY_PATH="$X64LIB_DIR:$RUNNER/lib/wine/x86_64-unix:$RUNNER/lib"
mkdir -p "$DATA/logs"
LOG="$DATA/logs/$slug-\$(date +%Y%m%d-%H%M%S).log"
cd "$GAME" || exit 1
printf 'Starting $title via box64... \nLog: %s\n' "\$LOG"
exec "$BIN/wine" "$target" $extra 9>&- >"\$LOG" 2>&1
EOS
    chmod +x "$BIN/$slug"
    say "  launcher: $BIN/$slug" 32
}
make_launcher play-aok  "Age of Empires II"                      "$GAME/$AOK_REL" ""
make_launcher play-aoe2 "Age of Empires II: The Conquerors"     "$GAME/$AOC_REL" "-nostartup"
make_launcher play-voobly "Voobly"                              "$VOOBLY" ""

# ------------------------------------------------- 8/8 checks ------------
stage 8 "Verification"
say "  ✔ Termux:X11 display target: ${DISPLAY:-:0}" 32
run_out "wine --version" "$BIN/wine" --version || die "Wine verification failed"
say "  ✔ $OUT" 32
if command -v glxinfo >/dev/null 2>&1; then
    run_out "glxinfo" glxinfo -B || true
    renderer=$(printf '%s\n' "$OUT" | grep -i 'OpenGL renderer' | head -n1)
    [ -n "$renderer" ] && say "  $renderer" 2
    case "$renderer" in
        *llvmpipe*) say "  GL: software rasteriser (functional, no GPU acceleration)." 33 ;;
        *virgl*|*VIRGL*) say "  GL: VirGL (host GPU acceleration)." 32 ;;
        "") say "  GL renderer could not be probed." 33 ;;
        *) say "  GL: $renderer" 2 ;;
    esac
fi
[ -x "$BIN/wine" ] && [ -x "$BIN/wineserver" ] && [ -n "$VOOBLY" ] \
    && say "  ✔ wrappers, prefix and Voobly present" 32

cat > "$DATA/installs/$IDENT.json" <<JSON
{
  "id": "$IDENT",
  "source": "$GAME",
  "prefix": "$PREFIX_DIR",
  "wine": "$BIN/wine",
  "runner": "$RUNNER",
  "box64": "$BOX64_ABS",
  "voobly": "$VOOBLY",
  "gpu_mode": "$GPU",
  "vendor": "$VENDOR",
  "ddraw": "$DDRaw",
  "game_drive": "$DRIVE",
  "launchers": "$BIN/play-aok $BIN/play-aoe2 $BIN/play-voobly",
  "log": "$LOG"
}
JSON

say "" 
say "  ╔══════════════════════════════════════════════════════════════╗" 1;32
say "  ║  INSTALLATION PREPARED — launch from Termux                 ║" 1;32
say "  ╚══════════════════════════════════════════════════════════════╝" 1;32
say "  play-aok | play-aoe2 | play-voobly"
say "  Voobly: Game Diagnostics → Installation $DRIVE\\, executable $GAME_WIN" 2
say "  Voobly: if the drive is not listed use Z: and the host path." 2
say "  Log: $LOG" 2
say "  Not verified here: actual GPU acceleration and a real two-player match." 33
exit 0
