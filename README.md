# Age of Empires II × Voobly on Linux

An interactive, single-file installer that sets up the **classic** (original 1999/2000) Age of Empires II and **Voobly** for online multiplayer on Linux — without touching your system Wine, your existing game files, or anything outside your user directory.

It works on both **x86_64** (native) and **ARM64**. On ARM64 you choose the emulator at startup — **FEX** or **Box64** — but both drive the same **Wine 10.0 amd64-wow64** runner against **one shared `win64` prefix** under `~/.local/share/aoe2-multiplayer-linux/`. That means one game setup, one Voobly install, one DirectPlay install, one state file — and you can switch emulators at any time just by rerunning the installer and picking the other route. Only the wrappers, launchers and the route audit are re-pinned to the selected emulator.

> Use only with game files and installers you trust and are licensed to use. Wine is **not** a security sandbox.

## Quick install

**Linux** (any distro; no clone needed):

```bash
curl -fsSL https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/main/install_aoe2_voobly.py | python3
```

**Android / Termux** (after installing the [Termux:X11](https://github.com/termux/termux-x11/releases) app):

```bash
pkg install -y curl && curl -fsSL https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/main/termux/install-aoe2-voobly.sh | bash
```

Both are interactive and resumable; prompts work even though the script arrives via a pipe.
More options (verbose mode, emulator route, GPU mode, DirectDraw renderer) are below.

## What it does

The installer walks you through 8 stages:

1. **Choose installation paths** — your existing AoE II directory, the Voobly setup `.exe`, and a dedicated Wine prefix. It verifies the game contains the original i386 `empires2.exe`/`age2.exe` and `age2_x1.exe` (HD/DE versions are rejected).
2. **Preflight** — detects the CPU architecture, checks for FEX/Box64 on ARM64 (offering to install the emulator package), and offers to install missing helper packages (`cabextract`, `unzip`, `icoutils`, …) via your package manager.
3. **Wine runner** — downloads a pinned **Wine 10.0 amd64-wow64** build (Kron4ek, SHA256-verified) into the shared workspace. Previously downloaded archives (including from older layouts) are reused, never re-downloaded. The emulated **x86_64 `libgcc_s.so.1`** that Wine's `ntdll.so` requires (Box64 does not wrap it and Fedora ships no x86_64 libraries) is provisioned from a pinned AlmaLinux 9 `libgcc` RPM, SHA256-verified and extracted user-locally into `x64libs/` — no sudo, no system changes. If compatible libraries are already present (e.g. from `box64-bundle-x86-libs.sh`), nothing is downloaded.
4. **Shared win64 prefix** — creates (or reuses) the `win64` prefix used by both emulators and verifies 32-bit Windows execution works.
5. **Game exposure** — maps your *existing* game directory (not a copy) to the first free Wine drive letter, with an optional full backup before Voobly's Game Diagnostics can patch it.
6. **DirectPlay** — installs native DirectPlay DLLs via a commit-pinned Winetricks (required for multiplayer).
7. **Voobly + launchers** — runs the Voobly installer (or reuses an existing `voobly.exe`) and creates runner-pinned launchers and desktop menu entries with extracted icons.
8. **Final checks** — offers visual smoke tests of AoK, Conquerors, and Voobly, then writes a machine-readable summary.

## Requirements

- Linux with a graphical session (X11 or Wayland/XWayland)
- Python **3.12+**
- Internet access (Wine build, Winetricks, Voobly installer)
- **x86_64** CPU, or **ARM64** with either [FEX-Emu](https://github.com/FEX-Emu/FEX) (`sudo dnf install fex-emu fex-emu-rootfs-fedora` — not the unrelated `fex` package) or [Box64](https://github.com/ptitSeb/box64) (`sudo dnf install box64`) installed
- 32-bit runtime support (e.g. `glibc.i686` on Fedora / `libc6:i386` on Debian)
- Helper tools: `cabextract`, `unzip`, `icoutils` (`wrestool`, `icotool`), `curl`, `sha256sum`, `sed`, `timeout` — the installer offers to install the first three for you
- **Your own copies of:**
  - the original Age of Empires II: The Age of Kings + The Conquerors (with data files)
  - the Voobly setup executable (e.g. `~/Downloads/voobly.exe`)

## Usage

Local checkout:

```bash
./install_aoe2_voobly.py            # interactive
./install_aoe2_voobly.py --verbose  # also print every command and its output
```

Direct from GitHub (see **Quick install** above) with options:

```bash
curl -fsSL https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/main/install_aoe2_voobly.py | python3 - --route box64 --verbose
```

When run this way the installer reopens `/dev/tty` for its prompts, so the interactive questions keep working. The same one-liner works for the uninstaller (`…/uninstall_aoe2_voobly.py | python3`).

Run it as your normal desktop user — **not** with `root` or `sudo`. It is interactive: it prompts for paths and confirmations at each stage, and resumes safely if you rerun it (completed stages are detected and skipped). Add `-v`/`--verbose` to echo each command and its captured output on the console as the stages run (everything is always written to the log file as well).

**Re-running over an existing installation:** nothing that is already present is re-downloaded or recreated — the verified runner, cached archives, DirectPlay setup, and installed Voobly are all reused. If an existing installation is detected (prefix, state, or runner), the installer lists it and asks whether to **replace** it; the default is to keep and reuse it. Replacing stops any running processes for that prefix, removes the prefix and its state (offering to close apps first if any are running), and keeps the verified runner and downloads so only the missing pieces are fetched again.

**Switching between FEX and Box64:** just rerun and pick the other emulator. The prefix, runner, Voobly, DirectPlay and state are shared, so nothing is reinstalled; the installer reports the switch, stops the previous emulator's processes on that prefix, re-pins the wrappers and launchers, and removes stale menu entries. Previous layouts (`aoe2-voobly`, `routes/wow64`) are adopted in place on first run, so the runner and prefix are not re-downloaded or recreated.

**Backups are opt-in:** neither the game directory nor the Wine prefix is copied unless you answer yes to the backup question (default: no).

## What you get

Everything lives directly under `~/.local/share/aoe2-multiplayer-linux/`:

| Item | Location |
|---|---|
| Wine prefix (win64, shared by FEX and Box64) | `~/.local/share/aoe2-multiplayer-linux/prefix/` |
| Wine runner | `~/.local/share/aoe2-multiplayer-linux/runners/wine-10.0-amd64-wow64/` |
| box64 (FEX stays system-provided) | `~/.local/share/aoe2-multiplayer-linux/translator/box64` |
| Box64 x86_64 startup libraries | `~/.local/share/aoe2-multiplayer-linux/translator/x64libs/` |
| Launchers (`play-aok`, `play-aoe2`, `play-voobly`) | `~/.local/share/aoe2-multiplayer-linux/bin/` |
| Desktop menu entries | `~/.local/share/applications/aoe2-voobly-*.desktop` |
| Port-conflict helper | `~/.local/share/aoe2-multiplayer-linux/tools/clear-directplay-conflict.sh` |
| Logs & JSON summary | `~/.local/share/aoe2-multiplayer-linux/logs/` |
| Downloads cache | `~/.cache/aoe2-multiplayer-linux/` |

Your original game directory and system Wine installation are never replaced.

## After installing — manual Voobly setup

1. Launch **Voobly**, run **Game Diagnostics**, and set:
   - *Installation directory*: the drive letter mapped to your game folder (e.g. `E:\`)
   - *Executable*: the full path to `age2_x1.exe`
2. If Voobly doesn't list that drive, use `Z:` with the Unix path instead (e.g. `Z:/home/you/Games/Age of Empires II`).
3. Let Game Diagnostics apply its supported patch (v1.5 RC) — don't import guessed CD keys.
4. Room settings: **32-bit color, windowed mode, no virtual desktop**; the Conquerors launcher already passes `-nostartup`.
5. Play a real two-player match, then back up the working prefix and game directory.

## Android (Termux)

An Android port lives in [termux/](termux/) — a Bash installer for Termux +
Termux:X11 that keeps the same architecture (Wine 10.0 amd64-wow64, one shared
`win64` prefix, Winetricks DirectPlay, Voobly, `play-*` launchers) inside a
proot-distro Ubuntu glibc container with Box64.
Install it with the one-liner in **Quick install** above; passed options:

```bash
pkg install -y curl && curl -fsSL https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/main/termux/install-aoe2-voobly.sh | bash -s -- --gpu=virgl --ddraw=cnc
```

Local checkout: `bash termux/install-aoe2-voobly.sh`.

See [termux/README.md](termux/README.md) for requirements (Termux:X11 APK),
the GPU matrix (VirGL on Adreno, llvmpipe fallback elsewhere, no DXVK — classic
AoE II is a DirectDraw game) and what still needs on-device verification.

## Uninstalling

```bash
./uninstall_aoe2_voobly.py                  # interactive
./uninstall_aoe2_voobly.py --dry-run        # show what would be removed, delete nothing
./uninstall_aoe2_voobly.py --purge-backups  # also remove the game directory backups
./uninstall_aoe2_voobly.py --purge-legacy   # also remove the previous aoe2-voobly data
```

Or straight from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/main/uninstall_aoe2_voobly.py | python3
```

The uninstaller shows a full inventory (prefix, runner, `translator/box64`, launchers, desktop entries, icons, state, logs, caches, backups) with sizes and asks for confirmation before removing anything. It also offers to stop any running Wine processes belonging to the prefix first — it never kills them silently.

**Removed:** everything the installer created, all of it under `~/.local/share/aoe2-multiplayer-linux/`, `~/.cache/aoe2-multiplayer-linux/`, plus the `aoe2-voobly-*` desktop entries and icons.

**Never removed:**
- your original game directory
- the Voobly setup executable (and any `voobly.exe` outside the prefix)
- system Wine, shared `~/.local/share/applications` and icon directories (only `aoe2-voobly-*` files are deleted)

Game directory backups (`<game dir>.backup-<timestamp>`) and any leftover `~/.local/share/aoe2-voobly` data from the previous layout are **kept by default** — confirm the extra prompts or pass `--purge-backups` / `--purge-legacy` to remove them. Re-running the installer afterwards starts from scratch.

## Troubleshooting

**Multiplayer drops back to the connection screen.** A stale DirectPlay helper is likely holding port **47624**. The launchers clear it automatically before starting; to do it manually:

```bash
~/.local/share/aoe2-multiplayer-linux/tools/clear-directplay-conflict.sh
```

Never kill *every* `dplaysvr.exe`, and don't change DirectPlay settings repeatedly — a helper owning port 47624 during a match is normal.

**Where are the logs?** Every run writes a timestamped log plus a `*-summary.json` report to `~/.local/share/aoe2-multiplayer-linux/logs/`. Failed runs print the log path.

**Wayland-only session.** Wine may need a working XWayland, or its Wayland driver configured.

**Launcher and port 47624.** Launching always force-frees the port first: the
launcher terminates whatever of yours is holding TCP/UDP 47624 (a leftover
`dplaysvr.exe` and, if the socket survives, this prefix's `wineserver`) and then
starts — no prompts. Inspect only with
`~/.local/share/aoe2-multiplayer-linux/tools/clear-directplay-conflict.sh --check`.

**DirectPlay install fails with an archive.org error.** Winetricks fetches the
Feb 2010 DirectX redist from a single web.archive.org snapshot that often returns
503/404. The installer pre-seeds that file from mirrors (same SHA256 as
winetricks) and retries 3 times. If it still fails, place
`directx_feb2010_redist.exe` (SHA256 `f6d191e8…caaa1e93f`) into
`~/.cache/aoe2-multiplayer-linux/xdg/winetricks/directx9/` and rerun.

## Notes

- The installer uses a lock file, so only one run can proceed at a time.
- The Wine archive and the Box64 route's `libgcc` RPM are SHA256-pinned and verified before use; Winetricks is pinned to a specific commit.
- Downloads and state stay in your user's XDG data/cache directories; nothing is installed system-wide except the optional helper packages you approve.
