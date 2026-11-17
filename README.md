# Age of Empires II × Voobly on Linux

An interactive, single-file installer that sets up the **classic** (original 1999/2000) Age of Empires II and **Voobly** for online multiplayer on Linux — without touching your system Wine, your existing game files, or anything outside your user directory.

It works on both **x86_64** (native) and **ARM64** (x86 code emulated through [FEX-Emu](https://github.com/FEX-Emu/FEX)).

> Use only with game files and installers you trust and are licensed to use. Wine is **not** a security sandbox.

## What it does

The installer walks you through 8 stages:

1. **Choose installation paths** — your existing AoE II directory, the Voobly setup `.exe`, and a dedicated Wine prefix. It verifies the game contains the original i386 `empires2.exe`/`age2.exe` and `age2_x1.exe` (HD/DE versions are rejected).
2. **Preflight** — detects the CPU architecture, checks for FEX on ARM64, and offers to install missing helper packages (`cabextract`, `unzip`, `icoutils`) via your package manager.
3. **Wine runner** — downloads a pinned **Wine 10.0 x86** build (Kron4ek, SHA256-verified) into `~/.local/share/aoe2-voobly/runners/`.
4. **Pure win32 prefix** — creates a fresh 32-bit-only Wine prefix and verifies 32-bit execution works.
5. **Game exposure** — maps your *existing* game directory (not a copy) to the first free Wine drive letter, with an optional full backup before Voobly's Game Diagnostics can patch it.
6. **DirectPlay** — installs native DirectPlay DLLs via a commit-pinned Winetricks (required for multiplayer).
7. **Voobly + launchers** — runs the Voobly installer (or reuses an existing `voobly.exe`) and creates runner-pinned launchers and desktop menu entries with extracted icons.
8. **Final checks** — offers visual smoke tests of AoK, Conquerors, and Voobly, then writes a machine-readable summary.

## Requirements

- Linux with a graphical session (X11 or Wayland/XWayland)
- Python **3.12+**
- Internet access (Wine build, Winetricks, Voobly installer)
- **x86_64** CPU, or **ARM64** with FEX installed (e.g. `sudo dnf install fex-emu fex-emu-rootfs-fedora` — not the unrelated `fex` package)
- 32-bit runtime support (e.g. `glibc.i686` on Fedora / `libc6:i386` on Debian)
- Helper tools: `cabextract`, `unzip`, `icoutils` (`wrestool`, `icotool`), `curl`, `sha256sum`, `sed`, `timeout` — the installer offers to install the first three for you
- **Your own copies of:**
  - the original Age of Empires II: The Age of Kings + The Conquerors (with data files)
  - the Voobly setup executable (e.g. `~/Downloads/voobly.exe`)

## Usage

```bash
./install_aoe2_voobly.py
```

Run it as your normal desktop user — **not** with `root` or `sudo`. It is interactive: it prompts for paths and confirmations at each stage, and resumes safely if you rerun it (completed stages are detected and skipped).

## What you get

| Item | Location |
|---|---|
| Wine prefix (win32) | `~/.local/share/aoe2-voobly/prefix/` |
| Wine 10.0 x86 runner | `~/.local/share/aoe2-voobly/runners/` |
| Launchers (`play-aok`, `play-aoe2`, `play-voobly`) | `~/.local/share/aoe2-voobly/bin32/` |
| Desktop menu entries | `~/.local/share/applications/aoe2-voobly-*.desktop` |
| Port-conflict helper | `~/.local/share/aoe2-voobly/tools/clear-directplay-conflict.sh` |
| Logs & JSON summary | `~/.local/share/aoe2-voobly/logs/` |
| Downloads cache | `~/.cache/aoe2-voobly/` |

Your original game directory and system Wine installation are never replaced.

## After installing — manual Voobly setup

1. Launch **Voobly**, run **Game Diagnostics**, and set:
   - *Installation directory*: the drive letter mapped to your game folder (e.g. `E:\`)
   - *Executable*: the full path to `age2_x1.exe`
2. If Voobly doesn't list that drive, use `Z:` with the Unix path instead (e.g. `Z:/home/you/Games/Age of Empires II`).
3. Let Game Diagnostics apply its supported patch (v1.5 RC) — don't import guessed CD keys.
4. Room settings: **32-bit color, windowed mode, no virtual desktop**; the Conquerors launcher already passes `-nostartup`.
5. Play a real two-player match, then back up the working prefix and game directory.

## Troubleshooting

**Multiplayer drops back to the connection screen.** A stale DirectPlay helper is likely holding port **47624**. The launchers clear it automatically before starting; to do it manually:

```bash
~/.local/share/aoe2-voobly/tools/clear-directplay-conflict.sh
```

Never kill *every* `dplaysvr.exe`, and don't change DirectPlay settings repeatedly — a helper owning port 47624 during a match is normal.

**Where are the logs?** Every run writes a timestamped log plus a `*-summary.json` report to `~/.local/share/aoe2-voobly/logs/`. Failed runs print the log path.

**Wayland-only session.** Wine may need a working XWayland, or its Wayland driver configured.

## Notes

- The installer uses a lock file, so only one run can proceed at a time.
- The Wine archive is SHA256-pinned and verified before extraction; Winetricks is pinned to a specific commit.
- Downloads and state stay in your user's XDG data/cache directories; nothing is installed system-wide except the optional helper packages you approve.
