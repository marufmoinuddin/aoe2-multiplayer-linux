#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  Age of Empires II + Voobly — Termux uninstaller
#
#  Removes everything the installer created:
#    - the Wine prefix (default: ~/.local/share/aoe2-fex/prefix)
#    - installer data (lib/, bin/, tools/, cache/, logs/, state.env, backups/)
#    - the `aoe2-voobly` command installed in $PREFIX/bin
#    - the root bind mount (--game-mode root), if it is still mounted
#
#  NEVER removed:
#    - your AoE II game folder, including the ~/aoe2 copy made by --game-mode copy
#    - the Voobly setup .exe you downloaded
#    - Termux packages (hangover-wine, termux-x11-nightly, pulseaudio, ...)
#
#  Usage:
#    bash uninstall_aoe2_voobly_termux.sh                 # interactive
#    bash uninstall_aoe2_voobly_termux.sh --dry-run       # show, delete nothing
#    bash uninstall_aoe2_voobly_termux.sh --purge-backups # also remove game-dir backups
#    bash uninstall_aoe2_voobly_termux.sh --yes           # no prompts
# =============================================================================
set -o pipefail

: "${PREFIX:=/data/data/com.termux/files/usr}"
BASE="${AOE2_FEX_HOME:-$HOME/.local/share/aoe2-fex}"
STATE="$BASE/state.env"
CMD_LINK="$PREFIX/bin/aoe2-voobly"

DRY=0; ASSUME_YES=0; PURGE_BACKUPS=0
C_ON=""; { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; } && C_ON=1

# ------------------------------------------------------------------ UI helpers
_c()   { [ -n "$C_ON" ] && printf '\033[%sm' "$1"; }
say()  { printf '%s%s%s\n' "$(_c 36)" "$*" "$(_c 0)"; }
ok()   { printf '%s✔ %s%s\n' "$(_c 32)" "$*" "$(_c 0)"; }
warn() { printf '%s! %s%s\n' "$(_c 33)" "$*" "$(_c 0)" >&2; }
die()  { printf '%s✘ %s%s\n' "$(_c 31)" "$*" "$(_c 0)" >&2; exit 1; }

ask() {   # ask "prompt" [default]  ->  $REPLY
    local p=$1 d=${2:-} a
    if [ "$ASSUME_YES" = 1 ] && [ -n "$d" ]; then REPLY=$d; return 0; fi
    { : </dev/tty; } 2>/dev/null || die "No terminal available for the prompt: $p (use --yes)."
    if [ -n "$d" ]; then
        printf '%s❯%s %s [%s]: ' "$(_c '1;36')" "$(_c 0)" "$p" "$d" >/dev/tty
    else
        printf '%s❯%s %s: ' "$(_c '1;36')" "$(_c 0)" "$p" >/dev/tty
    fi
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

size_of() { du -sh "$1" 2>/dev/null | cut -f1; }

# ------------------------------------------------------------ path safety ----
within() {   # within PARENT CHILD -> CHILD is PARENT or below it
    local p=${1%/} c=${2%/}
    [ -z "$p" ] && return 0          # PARENT is /
    [ "$p" = "$c" ] && return 0
    case "$c/" in "$p"/*) return 0 ;; esac
    return 1
}

mounts_under() {   # mounts_under DIR -> mountpoints at or below DIR
    local mp
    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        within "$1" "$mp" && printf '%s\n' "$mp"
    done < <(mount 2>/dev/null | sed -n 's/^.* on \(.*\) type .*$/\1/p')
}

guard_removal() {   # guard_removal PATH LABEL -> 0 safe, 1 refuse (prints why)
    local p=${1%/} label=$2 g
    if [ -z "$p" ]; then warn "Refusing to remove $label: empty path."; return 1; fi
    case "$p" in
        /|"$HOME"|"$PREFIX"|"$HOME/storage"|"$HOME/storage/"*)
            warn "Refusing to remove $label at $p (protected path)."; return 1 ;;
    esac
    for g in "${KEEP_PATHS[@]}"; do
        [ -n "$g" ] || continue
        if within "$p" "$g"; then
            warn "Refusing to remove $label: the game folder $g is inside $p."; return 1
        fi
        if within "$g" "$p"; then
            warn "Refusing to remove $label: $p is inside the game folder $g."; return 1
        fi
    done
    return 0
}

remove_tree() {   # remove_tree PATH LABEL
    local p=$1 label=$2 sz
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then return 0; fi
    guard_removal "$p" "$label" || return 1
    # rm -rf would happily descend into a bind mount, so refuse while one exists
    # (a dry run only reports it).
    local mounted
    mounted=$(mounts_under "$p")
    if [ -n "$mounted" ] && [ "$DRY" != 1 ]; then
        die "Refusing to remove $label: still mounted at $mounted. Unmount it and rerun."
    fi
    sz=""
    if [ -d "$p" ] && [ ! -L "$p" ]; then sz=$(size_of "$p"); fi
    if [ "$DRY" = 1 ]; then
        say "  would remove $label: $p${sz:+ ($sz)}${mounted:+ [mounted at $mounted]}"
        return 0
    fi
    if rm -rf -- "$p"; then ok "removed $label: $p"
    else warn "could not remove $label: $p"; fi
}

precheck() {   # validate every target before anything is deleted
    local p bad=0
    if [ -e "$CMD_LINK" ] || [ -L "$CMD_LINK" ]; then
        guard_removal "$CMD_LINK" "the aoe2-voobly command" || bad=1
    fi
    if [ "$WINEPREFIX" != "$BASE" ] && { [ -e "$WINEPREFIX" ] || [ -L "$WINEPREFIX" ]; }; then
        guard_removal "$WINEPREFIX" "the Wine prefix" || bad=1
    fi
    if [ -e "$BASE" ] || [ -L "$BASE" ]; then
        guard_removal "$BASE" "the installer data" || bad=1
    fi
    for p in "${BACKUPS[@]}"; do guard_removal "$p" "a game backup" || bad=1; done
    return "$bad"
}

# ------------------------------------------------------------ wine / mounts ---
wine_pids() {   # pids belonging to this WINEPREFIX
    local d pid cmd
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        [ -O "$d" ] || continue
        cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
        case "$cmd" in *[Ww]ine*|*.[Ee][Xx][Ee]*) ;; *) continue ;; esac
        tr '\0' '\n' <"$d/environ" 2>/dev/null | grep -qxF "WINEPREFIX=$WINEPREFIX" && echo "$pid"
    done
}

stop_wine() {
    local pid ws="$HANGOVER_BIN/wineserver"
    say "Stopping Wine processes for $WINEPREFIX ..."
    if [ -x "$ws" ]; then
        WINEPREFIX="$WINEPREFIX" timeout 20 "$ws" -k >/dev/null 2>&1
        WINEPREFIX="$WINEPREFIX" timeout 25 "$ws" -w >/dev/null 2>&1
    fi
    local pids; pids=$(wine_pids)
    if [ -n "$pids" ]; then
        for pid in $pids; do kill -TERM "$pid" 2>/dev/null; done
        sleep 2
        for pid in $(wine_pids); do kill -KILL "$pid" 2>/dev/null; done
    fi
    ok "Wine stopped."
}

AOE_SU_OPT=""; AOE_SU_STATE=""
su_detect() {
    case "$AOE_SU_STATE" in ok) return 0 ;; no) return 1 ;; esac
    command -v su >/dev/null 2>&1 || { AOE_SU_STATE=no; return 1; }
    if timeout 15 su --mount-master -c true >/dev/null 2>&1; then AOE_SU_OPT=--mount-master
    elif timeout 15 su -M -c true >/dev/null 2>&1; then AOE_SU_OPT=-M
    elif timeout 15 su -c true >/dev/null 2>&1; then AOE_SU_OPT=""
    else AOE_SU_STATE=no; return 1
    fi
    AOE_SU_STATE=ok; return 0
}

as_root() {   # as_root CMD ARGS...  (every argument safely quoted)
    local cmd="" a
    for a in "$@"; do cmd+="${cmd:+ }$(printf '%q' "$a")"; done
    # shellcheck disable=SC2086
    timeout 90 su $AOE_SU_OPT -c "$cmd"
}

unmount_all() {
    local mp
    local -a mps=()
    while IFS= read -r mp; do [ -n "$mp" ] && mps+=("$mp"); done < <(mounts_under "$BASE")
    [ ${#mps[@]} -gt 0 ] || { say "No bind mount under $BASE."; return 0; }
    su_detect || die "Root is needed to unmount ${mps[*]}; grant root or unmount manually."
    for mp in "${mps[@]}"; do
        say "Unmounting $mp ..."
        as_root umount "$mp" || as_root umount -l "$mp" || warn "Could not unmount $mp."
    done
}

# --------------------------------------------------------------------- args ---
show_help() {
    local src="${BASH_SOURCE[0]:-}"
    if [ -n "$src" ] && [ -f "$src" ]; then
        sed -n '3,/^# =====/p' "$src" | sed '$d' | sed 's/^# \{0,1\}//'
    else
        printf '%s\n' \
            "Usage: bash uninstall_aoe2_voobly_termux.sh [--dry-run] [--purge-backups] [--yes]" \
            "Removes the Wine prefix, installer data and the aoe2-voobly command." \
            "Never removes the game folder (e.g. ~/aoe2) or the Voobly setup .exe."
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)       DRY=1; shift ;;
            --purge-backups) PURGE_BACKUPS=1; shift ;;
            --yes|-y)        ASSUME_YES=1; shift ;;
            -h|--help)       show_help; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

# --------------------------------------------------------------------- main ---
main() {
    parse_args "$@"

    [ "$(id -u)" != 0 ] || die "Run as the normal Termux user, not root."
    case "$PREFIX" in */com.termux/*) ;; *) die "This script is for Termux on Android (PREFIX=$PREFIX)." ;; esac
    command -v mount >/dev/null 2>&1 || die "'mount' not found."

    # State is optional: a half-finished install still leaves $BASE behind.
    AOE_PREFIX=""; GAME_DIR=""; GAME_ORIG=""; GAME_MODE=""; GAME_SRC=""; VOOBLY_EXE=""
    [ -r "$STATE" ] && . "$STATE"
    WINEPREFIX="${AOE_PREFIX:-$BASE/prefix}"
    HANGOVER_BIN="${HANGOVER_BIN:-$PREFIX/opt/hangover-wine/bin}"

    # Protect the real game data. In bind mode GAME_DIR is only the mountpoint
    # ($BASE/game); the bytes live at GAME_ORIG.
    KEEP_PATHS=()
    [ -n "${GAME_ORIG:-}" ] && KEEP_PATHS+=("$GAME_ORIG")
    if [ "${GAME_MODE:-keep}" != bind ] && [ -n "${GAME_DIR:-}" ]; then
        KEEP_PATHS+=("$GAME_DIR")
    fi

    # Game-dir backups sit next to the game, outside $BASE.
    BACKUPS=()
    local b
    for b in "${GAME_DIR:-/nonexistent}".backup-* "${GAME_ORIG:-/nonexistent}".backup-*; do
        [ -e "$b" ] && BACKUPS+=("$b")
    done

    printf '%s\n' \
        "╔══════════════════════════════════════════════════════════════╗" \
        "║     AoE II × Voobly — Termux uninstaller                     ║" \
        "║     Game directory and Voobly setup are never removed.       ║" \
        "╚══════════════════════════════════════════════════════════════╝"

    say ""
    say "Inventory of installer-managed files:"
    local any=0
    show_one() { [ -e "$1" ] || [ -L "$1" ] || return 1; any=1; printf '  - %-22s %s%s\n' "$2" "$1" "${3:+ ($3)}"; }
    show_one "$WINEPREFIX" "Wine prefix" "$(size_of "$WINEPREFIX")"
    show_one "$BASE" "Installer data" "$(size_of "$BASE")"
    show_one "$CMD_LINK" "aoe2-voobly command"
    local mp
    while IFS= read -r mp; do
        [ -n "$mp" ] && { any=1; printf '  - %-22s %s\n' "bind mount" "$mp"; }
    done < <(mounts_under "$BASE")
    if [ ${#BACKUPS[@]} -gt 0 ]; then
        any=1
        for b in "${BACKUPS[@]}"; do printf '  - %-22s %s\n' "game backup" "$b"; done
    fi

    say ""
    say "Never removed:"
    if [ "${GAME_MODE:-keep}" = bind ]; then
        [ -n "${GAME_ORIG:-}" ] && say "  - game folder: ${GAME_ORIG}${GAME_DIR:+ (bind-mounted at $GAME_DIR)}"
    else
        [ -n "${GAME_DIR:-}" ] && say "  - game folder: $GAME_DIR"
        [ -n "${GAME_ORIG:-}" ] && [ "${GAME_ORIG:-}" != "${GAME_DIR:-}" ] &&
            say "  - original game folder: $GAME_ORIG"
    fi
    say "  - the Voobly setup .exe you downloaded"
    say "  - Termux packages (hangover-wine, termux-x11-nightly, pulseaudio, ...)"

    if [ "$any" = 0 ] && [ ${#BACKUPS[@]} -eq 0 ]; then
        say ""
        say "Nothing to remove. The installation is already gone."
        return 0
    fi

    # Refuse before deleting anything if a target overlaps the game folder.
    if ! precheck; then
        if [ "$DRY" = 1 ]; then
            warn "A real run would abort: some targets cannot be removed safely."
        else
            die "Aborting: nothing was removed (see above)."
        fi
    fi

    if [ "$DRY" = 1 ]; then
        say ""
        say "Dry run — nothing will be deleted."
    elif [ "$ASSUME_YES" != 1 ]; then
        say ""
        yes_no "Remove the files listed above?" n || { say "Cancelled. Nothing was removed."; return 0; }
    fi

    if [ "$DRY" != 1 ]; then
        stop_wine
        unmount_all
    fi

    # Remove the command before $BASE disappears, so its link target is readable.
    if [ -L "$CMD_LINK" ]; then
        local target; target=$(readlink "$CMD_LINK" 2>/dev/null || true)
        case "$target" in
            "$BASE"/*) remove_tree "$CMD_LINK" "aoe2-voobly command" ;;
            *) warn "Not removing $CMD_LINK: it points to ${target:-?}, not this install." ;;
        esac
    elif [ -e "$CMD_LINK" ]; then
        warn "Not removing $CMD_LINK: it is not a symlink created by this installer."
    fi

    [ "$WINEPREFIX" = "$BASE" ] || remove_tree "$WINEPREFIX" "Wine prefix"
    remove_tree "$BASE" "installer data"

    if [ ${#BACKUPS[@]} -gt 0 ]; then
        local purge=$PURGE_BACKUPS
        if [ "$purge" != 1 ] && [ "$DRY" != 1 ] && [ "$ASSUME_YES" != 1 ]; then
            yes_no "Also remove the game-folder backups listed above?" n && purge=1
        fi
        if [ "$purge" = 1 ]; then
            for b in "${BACKUPS[@]}"; do remove_tree "$b" "game backup"; done
        else
            say "Kept ${#BACKUPS[@]} game-folder backup(s); rerun with --purge-backups to remove them."
        fi
    fi

    say ""
    if [ "$DRY" = 1 ]; then say "Dry run complete. Nothing was deleted."; else ok "Uninstall complete."; fi
    [ -n "${GAME_ORIG:-}" ] && say "Kept: $GAME_ORIG"
    if [ "${GAME_MODE:-keep}" != bind ] && [ -n "${GAME_DIR:-}" ] && [ "${GAME_DIR:-}" != "${GAME_ORIG:-}" ]; then
        say "Kept: $GAME_DIR"
    fi
    say "Kept: Voobly setup executable and Termux packages."
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${BASH_SOURCE[0]:-}" ]; then main "$@"; fi
