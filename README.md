# laptop-powersave

Battery modes for a Linux laptop that doubles as a home server: caps the CPU when the charger is unplugged and powers down the idle NVIDIA GPU without a reboot.

laptop-powersave keeps a Linux laptop that also runs as a home server going for longer when the power goes out. When the charger is unplugged, a udev hook caps the CPU, turns off turbo, dims the screen and turns on device power saving; nothing is stopped. For more time, `powersave save` stops background containers and services, and `powersave save --gpu-off` logs you out once so the desktop comes back on the Intel GPU and the NVIDIA card can power down. `powersave restore` puts everything back. On the laptop it was built for (Intel i7 Raptor Lake, RTX 4070 Laptop GPU, 48 Wh battery, Ubuntu with GNOME on Xorg), the idle NVIDIA GPU drew about 10 W, more than the whole desktop session at about 9 W, so freeing it took the estimated runtime from about 2.4 hours to about 4.5 hours.

## Requirements

This was written for one laptop and has only been run there. It expects:

- An Intel CPU using the `intel_pstate` driver (`/sys/devices/system/cpu/intel_pstate`). On other CPUs the CPU cap does nothing.
- An NVIDIA GPU next to the Intel GPU (Optimus), with the proprietary NVIDIA driver.
- Ubuntu with GNOME, the `gdm` display manager and `prime-select` (package `nvidia-prime`).
- `sudo` rights.
- Packages: `upower`, `bc`, `iw`, `psmisc` (`fuser`), `kbd` (`chvt`, `fgconsole`), `tmux`, `libnotify-bin` (`notify-send`). Docker is optional.

### What the install does as root

`install.sh` uses `sudo` to install a udev rule, a systemd service and `/usr/local/sbin/powersave-ac`. That hook runs as root on every AC unplug and replug, for every user on the machine. On unplug it:

- turns off turbo and caps the CPU at `CAP_PCT` percent (default 50);
- sets the screen to `CAP_BRIGHT` percent (default 40);
- sets runtime power management to `auto` on every PCI and USB device, and turns on SATA link power saving, audio power saving and Wi-Fi power saving;
- unloads the NVIDIA driver if no process has it open (it never kills anything to get there).

On replug it puts back the CPU and brightness values it saved. It does not undo the device power saving or reload the NVIDIA driver. Runtime power management can cause dropouts on some USB devices (docks, network adapters, disks).

The install also copies `powersave` to `~/.local/bin`, copies `system/powersave.conf` to `/etc/powersave.conf` if that file does not exist, and adds a block to `~/.profile` (used by `go-headless`, see below).

## Warnings

- **`save --aggressive` closes your programs without asking.** It sends SIGTERM to every process you own that uses more than about 20 MB of memory and does not match a short allowlist (terminal, tmux, browsers, the desktop shell and system services, plus `KEEP_EXTRA`). Editors, IDEs, virtual machines, databases and builds are closed. Run `powersave save --dry-run` first to see the list.
- **`save` stops every running Docker container**, the system units in `SYS_UNITS` (Docker, containerd, libvirt log and lock daemons, Bluetooth, fwupd, ModemManager and others), the user units in `USER_UNITS`, and closes the apps in `APPS`, without asking.
- **`save --gpu-off` can leave a black screen.** It runs `sudo prime-select intel` and restarts gdm. On a laptop whose screen or external ports are wired only to the NVIDIA card (or whose firmware is set to discrete-only graphics), the desktop may not come back. The PRIME mode stays on Intel across reboots until you run `powersave restore`. It asks you to type YES first; `FORCE=1` skips that.
- **`save --gpu-off`, `go-headless` and `headless` end the graphical session.** Unsaved work in GUI apps is lost. Work inside tmux survives.
- **Settings can stay changed.** `restore` does not turn device power saving back off, does not restart `nvidia-persistenced`, and does not turn off `loginctl enable-linger`. If you skip `restore`, the CPU cap, PRIME mode and stopped services also stay as they are. A reboot resets everything except the PRIME mode, linger and the installed files.

### If something goes wrong

Switch to a text console with Ctrl+Alt+F3, log in, and run `powersave restore`. If the screen stays black after `--gpu-off`, run `sudo prime-select on-demand` (or the mode you used before) and reboot.

## Tiers

| Tier | Command | Draw | Runtime | What it costs |
|---|---|---|---|---|
| 0 | automatic on AC loss | ~19 W | ~2.4 h | nothing is stopped; CPU capped, screen dimmed |
| 1 | `powersave save` | depends on what you run | | background containers, services and apps stop |
| 2 | `powersave save --gpu-off` | ~10 W | ~4.5 h | one logout of about 20 s; desktop and browser come back |
| 3 | `powersave go-headless` | ~8 W | ~5.5 h | no desktop; console and tmux only |

The draw and runtime figures were measured on the laptop described above. Tier 1 has no figure because its saving is whatever your containers and services were drawing. Note that tier 1 sets the CPU cap to 60% and the screen to 30%, while tier 0 uses 50% and 40% by default.

Tier 2 is the one to reach for first: it saves about 9 W for one logout. Tier 3 saves about 2 W more and costs you the browser.

### How each tier treats the NVIDIA card

The NVIDIA driver cannot be unloaded while Xorg, gnome-shell or mutter hold it open. Tiers 0 and 1 unload it only if nothing holds it, so on a normal desktop the card stays on. Tier 2 runs `prime-select intel` and restarts gdm, so the new session starts on the Intel GPU and the driver can be unloaded. Tier 3 does not use `prime-select`; it stops gdm, which releases the driver. Nothing here runs `fuser -k /dev/nvidia*`, because that logs you out.

## Use

    powersave status                  battery, draw, hours left, what was stopped
    powersave limit                   apply tier 0 by hand
    powersave unlimit                 remove tier 0 limits
    powersave perf                    turbo on, no CPU cap
    powersave save                    tier 1
    powersave save --gpu-off          tier 2 (asks you to type YES)
    powersave save --aggressive       tier 1, then close other large programs (no prompt)
    powersave save --dry-run          list what --aggressive would close; changes nothing
    powersave go-headless             asks YES, then switches to tty3; log in there and tier 3 runs
    powersave headless                tier 3 directly; refuses to run inside a graphical session
    powersave restore                 undo the tiers and restart what was stopped

`save` reads one option at a time: `save --gpu-off --aggressive` runs `--gpu-off` only.

You can go deeper in steps, for example `save` and later `save --gpu-off`. `restore` restarts everything stopped along the way. It does not reopen closed apps. If you run `restore` while still on battery, the CPU and screen go back to the tier 0 limits, and the AC hook lifts them when the charger is back.

`go-headless` turns on `loginctl enable-linger` so your user services keep running without a session, and leaves a marker that the `~/.profile` block picks up on the next console login. That block runs `powersave headless` and then opens the tmux session `work`.

## Configure

Edit `/etc/powersave.conf`. The `powersave` command also reads `~/.config/powersave/config` after it, for per-user changes. Each setting is described in `system/powersave.conf`:

- `CAP_PCT`, `CAP_BRIGHT`: tier 0 CPU cap and screen brightness.
- `BACKLIGHT`, `DGPU_PCI`, `WIFI_IF`: hardware names. When `DGPU_PCI` or `WIFI_IF` is empty, the first NVIDIA display device and all wireless interfaces are found in sysfs.
- `SYS_UNITS`, `USER_UNITS`, `HEADLESS_USER_UNITS`, `APPS`: what `save` and `headless` stop.
- `KEEP_EXTRA`: extra patterns `--aggressive` must not close.
- `POST_RESTORE_HOOK`: an optional command, off by default. `restore` runs it after restarting everything, with `POWERSAVE_STOPPED_AT` and `POWERSAVE_RESTORED_AT` set to the start and end of the time background work was stopped, for example to tell a recorder or sync job to catch up. If it fails, the next `restore` runs it again.

## Install

    git clone https://github.com/hmishra2250/laptop-powersave
    cd laptop-powersave
    ./install.sh

Running `./install.sh` again updates the installed files and replaces the `~/.profile` block; it does not overwrite an existing `/etc/powersave.conf`.

## Restore

    powersave restore

Then log out and back in if `--gpu-off` was used, so the session starts with the previous PRIME mode.

## Uninstall

    powersave restore
    ./install.sh --uninstall

This removes the installed scripts, the udev rule, the systemd service and the `~/.profile` block. It keeps `/etc/powersave.conf`, `~/.local/state/powersave` and `/var/lib/powersave`; delete them by hand if you want them gone.

## Design notes

- Never `fuser -k /dev/nvidia*`, and never load `nvidia_modeset` into a running X session that started on the Intel GPU. Both log you out. `restore` leaves the driver unloaded while gdm is running and says so.
- Never kill `gsd-*`. `gsd-power` handles battery management and `gsd-media-keys` owns the brightness keys.
- `--dry-run` must not change anything.
- `restore` only restarts what this tool stopped. The lists live in `~/.local/state/powersave/`.
- The console autorun checks three things (the marker file, an empty `$DISPLAY`, and a real text console) so it cannot run inside a graphical session.

## License

MIT. See [LICENSE](LICENSE).
