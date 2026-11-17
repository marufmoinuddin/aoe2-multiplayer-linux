# Age of Empires II + Voobly on Android (Termux)

A Termux/Termux:X11 port of the Linux installer in this repository. It keeps the
same design: **Wine 10.0 amd64-wow64**, a **shared `win64` prefix**, native
DirectPlay via Winetricks, the existing game directory used in place, Voobly +
Game Diagnostics, and `play-aok` / `play-aoe2` / `play-voobly` launchers.

Only the Android-specific parts differ: Termux:X11 for the display, PulseAudio
over TCP for sound, a glibc container (proot-distro Ubuntu) because Wine
amd64-wow64 needs glibc, and Box64 invoked explicitly instead of via binfmt.

## Requirements

- Termux from F-Droid (Play Store builds are outdated)
- [Termux:X11](https://github.com/termux/termux-x11/releases) APK installed
- Android 8+, arm64-v8a device, ~4 GB free, no root
- Your own classic AoE II (AoK + The Conquerors) files and the Voobly setup
  executable, e.g. in `~/storage/shared/Games/Age of Empires II`

## Install

One line, straight from GitHub (no clone needed):

```bash
pkg install -y curl && curl -fsSL https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/main/termux/install-aoe2-voobly.sh | bash
```

Options are passed with `bash -s --`:

```bash
# default: virgl on Adreno, software elsewhere
pkg install -y curl && curl -fsSL https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/main/termux/install-aoe2-voobly.sh | bash -s -- --gpu=software
pkg install -y curl && curl -fsSL https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/main/termux/install-aoe2-voobly.sh | bash -s -- --gpu=virgl
pkg install -y curl && curl -fsSL https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/main/termux/install-aoe2-voobly.sh | bash -s -- --ddraw=cnc
```

| Option | Meaning |
|---|---|
| `--gpu=auto` | virgl on Adreno, software elsewhere (default) |
| `--gpu=software` | Mesa llvmpipe; always works, CPU rendering |
| `--gpu=virgl` | host virglrenderer (Adreno; unreliable on Mali) |
| `--ddraw=cnc` | use cnc-ddraw instead of Wine's ddraw |

From a local clone: `bash termux/install-aoe2-voobly.sh [--gpu=…] [--ddraw=…]`.
Piped or local, prompts are read from `/dev/tty`, and when piped the core
installer is fetched from the same repository.

Then launch from Termux: `play-aok`, `play-aoe2` or `play-voobly`
(equivalently `aoe2-termux play-aoe2`). The launcher starts Termux:X11,
PulseAudio and, in VirGL mode, the host GPU server, then runs the game inside
the glibc container.

## What it does (same stages as the Linux installer)

1. **Paths** – game directory, Voobly setup `.exe`, prefix; validates the
   original i386 `empires2.exe`/`age2.exe` + `age2_x1.exe` (HD/DE rejected).
2. **Preflight** – apt dependencies inside Ubuntu; Box64 from a pinned Debian
   `.deb` (0.4.3, SHA256-verified), used only if the container has none.
3. **Wine runner** – the same pinned Kron4ek **wine-10.0-amd64-wow64** archive
   as the Linux installer, plus the x86_64 `libgcc_s.so.1` that Wine's
   `ntdll.so` needs (Box64 does not wrap it): pinned AlmaLinux 9 RPM.
4. **Prefix** – one shared `win64` prefix, 32-bit `cmd.exe` verified.
5. **Game mapping** – a spare Wine drive letter pointing at your existing game
   folder (no copy); `Z:` fallback verified through Wine.
6. **DirectPlay** – commit-pinned Winetricks with `WINE_BIN`/`WINESERVER_BIN`
   so arch/WoW64 detection works through the wrappers; verifies the `*dplayx`
   override.
7. **Voobly** – reuses an installed `voobly.exe` or runs the setup inside
   Termux:X11; writes `play-*` launchers with GPU/audio/X11 environment.
8. **Verification** – Wine version, launchers, Voobly, and a `glxinfo` report
   of the actual GL renderer.

Data layout is identical to Linux, inside Termux home:

```
~/.local/share/aoe2-multiplayer-linux/
├── prefix/  runners/  translator/box64  translator/x64libs/
├── bin/     tools/    installs/  logs/  backups/
~/.cache/aoe2-multiplayer-linux/
```

## Graphics

Classic AoE II is a DirectDraw (2D) game, so **DXVK is not used** — it only
affects D3D9. Rendering options:

| Device | Default | Notes |
|---|---|---|
| Snapdragon / Adreno | `virgl` | Host `virglrenderer-android` + Mesa `virpipe` inside Ubuntu. Turnip would be faster, but it needs a glibc-built Vulkan ICD that this installer does not ship (mobox/Winlator bundle one). |
| Mali / Exynos / MediaTek | `software` | Mesa llvmpipe. Fine for a 2D game at 800×600–1280×720. VirGL on Mali is often broken. |
| Any | `--gpu=software` | Always works; verify with the `glxinfo` line printed at the end. |

`--ddraw=cnc` installs [cnc-ddraw](https://github.com/FunkyFr3sh/cnc-ddraw)
(pinned v7.1.0.0) into the game directory and enables `ddraw=n,b` — the
approach Winlator itself recommends for legacy DirectDraw titles. Revert by
deleting `ddraw.dll`/`ddraw.ini` from the game folder.

## What was verified here, and what was not

Verified in this repository: shell syntax (`bash -n`), pinned checksums
(Wine 10.0 archive, Box64 0.4.3 `.deb`, libgcc RPM, cnc-ddraw), and that the
installer mirrors the Linux stage logic and data layout.

**Not verifiable without an Android device** — please treat these as test
items: Termux:X11 startup, Box64 executing the Wine runner on-device,
hardware-accelerated GL (VirGL), AoK/Conquerors launch, Voobly launch and Game
Diagnostics, and a real two-player DirectPlay match.

## Notes / scope

- FEX: [Fex-Android](https://github.com/AllPlatform/Fex-Android) exists, but it
  ships Wine 8.15 and Turnip only on Adreno; this port keeps Wine 10.0 and the
  shared-prefix design on Box64, matching the Linux installer. (`--emu` is not
  offered for that reason.)
- Voobly Game Diagnostics will patch shared game files; cancel the optional
  backup prompt only if you have your own copy.
- To remove: delete `~/.local/share/aoe2-multiplayer-linux`,
  `~/.cache/aoe2-multiplayer-linux`, the `$PREFIX/bin/{play-aok,play-aoe2,play-voobly,aoe2-termux}`
  wrappers, and (optionally) `proot-distro remove ubuntu`.
