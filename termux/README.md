# AoE II / Voobly on upstream Mobox

Run `bash termux/install-aoe2-voobly.sh` from a clone, or use the repository's existing raw Bash bootstrap URL. The old Python URL is a compatibility entrypoint too.

This replaces the custom Kron4ek Wine 10/AlmaLinux library/Winetricks runtime with upstream [olegos2/mobox](https://github.com/olegos2/mobox), installer commit `24e5611620efbb133e42d4b26191bf2ef7b21768`. Upstream's GitLab component downloads remain mutable. Mobox is archived; no claim of current Android compatibility or successful multiplayer testing is made.

1. Install/open the Termux:X11 Android companion app.
2. Close existing Wine/glibc programs. If prompted, type BACKUP to move the old shared glibc directory aside. Its path is recorded under `~/.aoe2-mobox/runtime-backup.txt`. Other glibc applications may stop working until restored.
3. In the upstream Mobox installer, select **2: WoW64** (Wine 9.3).
4. Wait for the Mobox desktop/prefix/DirectX initialization, then return to Termux and continue.
5. Supply licensed game files and a trusted Voobly setup executable. Complete its GUI installation.
6. Run `play-voobly` and launch the game through its lobby. Standalone commands are `play-aok` and `play-aoe2`.

The launch adapter changes only the application target in Mobox's own `start-tfm` script. It retains upstream display/audio/configuration/prefix behavior. Separate launch commands restart desktop services; do not invoke them concurrently with a live lobby. No automatic port-killing is added: upstream session behavior replaces the previous custom launch pipeline. Old widget shortcuts are not updated; use the commands above.

DirectPlay uses Mobox's bundled DirectX archive and registry templates. The installer does not re-run the failing Winetricks self-registration sequence, and does not claim the multiplayer stack is verified. Test an actual host/join session.

The previous `~/.local/share/aoe2-multiplayer-linux` prefix and all Linux installer files remain untouched. For rollback, close Mobox, move the new `$PREFIX/glibc` aside and restore the recorded backup to `$PREFIX/glibc`; do not overwrite a running runtime. The prior Termux implementation is retained in Git history.
