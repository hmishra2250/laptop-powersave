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

The install also copies `powersave` to `~/.local/bin`, copies `system/powersave.conf` to `/etc/powersave.conf` and `system/workloads.example` to `~/.config/powersave/workloads` if those files do not exist, and adds a block to `~/.profile` (used by `go-headless`, see below).

## Warnings

- **`save --aggressive` closes your programs without asking.** It sends SIGTERM to every process you own that uses more than about 20 MB of memory and does not match a short allowlist (terminal, tmux, browsers, the desktop shell and system services, plus `KEEP_EXTRA`). Editors, IDEs, virtual machines, databases and builds are closed. Run `powersave save --dry-run` first to see the list.
- **`save` stops background workloads without asking.** With the built-in defaults that is every running Docker container, the system units in `SYS_UNITS` (Docker, containerd, libvirt log and lock daemons, Bluetooth, fwupd, ModemManager and others), the user units in `USER_UNITS`, and the apps in `APPS`. With a workloads file (see [Choosing what powersave touches](#choosing-what-powersave-touches)) it is everything listed there except items flagged `keep`, plus running containers the file does not list. Run `powersave save --dry-run` to see the list first.
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

    powersave status                  battery, draw, hours left, workloads source, what is still stopped
    powersave limit                   apply tier 0 by hand
    powersave unlimit                 remove tier 0 limits
    powersave perf                    turbo on, no CPU cap
    powersave save                    tier 1
    powersave save --gpu-off          tier 2 (asks you to type YES)
    powersave save --aggressive       tier 1, then close other large programs (no prompt)
    powersave save --dry-run          list what save would stop and keep, and what --aggressive would close; changes nothing
    powersave go-headless             asks YES, then switches to tty3; log in there and tier 3 runs
    powersave headless                tier 3 directly; refuses to run inside a graphical session
    powersave restore                 undo the tiers; restart what was stopped (auto), ask about the rest (ask)
    powersave restore --yes           same, and restart every ask item without prompting
    powersave restore --no            same, and leave every ask item stopped

`save` reads one option at a time: `save --gpu-off --aggressive` runs `--gpu-off` only.

You can go deeper in steps, for example `save` and later `save --gpu-off`. `restore` deals with everything stopped along the way, each item by its on-restore policy. It does not reopen closed apps. If you run `restore` while still on battery, the CPU and screen go back to the tier 0 limits, and the AC hook lifts them when the charger is back.

`go-headless` turns on `loginctl enable-linger` so your user services keep running without a session, and leaves a marker that the `~/.profile` block picks up on the next console login. That block runs `powersave headless` and then opens the tmux session `work`.

## Configure

Edit `/etc/powersave.conf`. The `powersave` command also reads `~/.config/powersave/config` after it, for per-user changes. Each setting is described in `system/powersave.conf`:

- `CAP_PCT`, `CAP_BRIGHT`: tier 0 CPU cap and screen brightness.
- `BACKLIGHT`, `DGPU_PCI`, `WIFI_IF`: hardware names. When `DGPU_PCI` or `WIFI_IF` is empty, the first NVIDIA display device and all wireless interfaces are found in sysfs.
- `SYS_UNITS`, `USER_UNITS`, `HEADLESS_USER_UNITS`, `APPS`: what `save` and `headless` stop when there is no workloads file. A workloads file replaces all four.
- `KEEP_EXTRA`: extra patterns `--aggressive` must not close.
- `POST_RESTORE_HOOK`: an optional command, off by default. `restore` runs it after restarting everything, with `POWERSAVE_STOPPED_AT` and `POWERSAVE_RESTORED_AT` set to the start and end of the time background work was stopped, for example to tell a recorder or sync job to catch up. If it fails, the next `restore` runs it again. When a recorder (a container with the `backfill` flag) was stopped, the window starts when the recorder stopped and the hook waits until a recorder is running again; see below.

## Choosing what powersave touches

`~/.config/powersave/workloads` decides what `save` stops, what it keeps running, and what `restore` does with each thing it stopped. `install.sh` creates it from `system/workloads.example` (written for the laptop this was built on) if it does not exist, and never overwrites it. `POWERSAVE_WORKLOADS` points at another file. Without the file, the lists in `powersave.conf` apply, every running container is stopped, everything is restarted without asking, and containers named `cctv-edge-app-*` or `*frigate*` count as the recorder.

One workload per line, whitespace-separated; `#` starts a comment, and the comment on a workload line is its label at the restore prompt:

    <kind> <name-or-glob> <on-restore> [flags]   # label

    container    cctv-edge-app-1      ask   backfill   # Frigate, CCTV recorder
    container    supabase_*_zoe-auto  ask              # Zoe local Supabase stack
    container    zoe-mailpit          auto             # Zoe dev mail catcher
    user-unit    talkies.service      auto  headless
    system-unit  bluetooth.service    auto
    app          slack                never

- kind: `container`, `user-unit`, `system-unit` or `app`. Only containers take globs. The first matching line wins.
- on-restore: `auto` restarts it, `ask` offers it at the restore prompt, `never` leaves it stopped. Apps are never reopened whatever this says.
- flags (comma list): `keep` (save leaves it running), `backfill` (the recorder: stopping it starts a coverage gap), `headless` (a user unit stopped only by the headless tier).
- settings, one `key value` per line: `ask_timeout` (seconds, default 30), `ask_default` (`yes` or `no`, default yes), `unattended` (`skip` or `restart`, default skip), `backfill_max_age_h` (default 24), `unlisted_container` (`auto`, `ask` or `never`; default `ask` when the file exists).

Unknown or invalid lines are reported and skipped; a bad on-restore value is treated as `ask`.

### Restore

`restore` starts system units first (Docker has to be up before containers), then user units, then containers, after waiting up to about 15 seconds for `docker info`. If Docker is not up it says so and keeps the containers recorded. `auto` items restart, `never` items are reported as left stopped and forgotten, and `ask` items are offered once, as one list. Containers that match the same glob share one entry:

      These were stopped and are set to ask before restarting:
        1) cctv-edge-app-1        Frigate, CCTV recorder
        2) cctv-edge-go2rtc-1     go2rtc, camera stream relay
        3) supabase_*_zoe-auto    Zoe local Supabase stack (11 containers)
      Restart? [Y]es all / [n]one / numbers e.g. "1 3"  (Enter = yes, 30 s):

Enter or no answer within `ask_timeout` uses `ask_default`. An invalid answer is asked again once, then nothing is restarted. `--yes` restarts every ask item and `--no` none. Without a terminal, `unattended` decides: `skip` leaves them stopped, `restart` restarts them. Anything left stopped stays recorded: `status` lists it under "still stopped" and the next `restore` offers it again.

### Coverage gap

When `save` stops a container with the `backfill` flag it records `outage_start` in the state directory. After containers start, if a recorder is running, `restore` runs `POST_RESTORE_HOOK` with that window; if no recorder is running it keeps the gap and offers it on the next `restore`. A gap older than `backfill_max_age_h` hours needs an explicit `y` at `Coverage gap started <date> (<N> h ago). Backfill all of it? [y/N]`; `--yes` does not approve it. Declined, the marker is renamed `outage_start.skipped-<time>` and nothing is queued. Without a terminal the marker is left as it is. Without a `POST_RESTORE_HOOK`, nothing is queued and the marker is set aside the same way.

When the charger comes back, the AC hook's notification adds "Some workloads are still stopped - run: powersave restore" if anything is still recorded. The hook never starts anything itself.

## Tests

    tests/run.sh

Sources `bin/powersave` into a temporary home with `docker`, `systemctl`, `sudo` and friends stubbed, and checks config parsing, save state, the restore prompt and the coverage gap guard. It never touches real services or `~/.local/state/powersave`.

## Install

    git clone https://github.com/hmishra2250/laptop-powersave
    cd laptop-powersave
    ./install.sh

Running `./install.sh` again updates the installed files and replaces the `~/.profile` block; it does not overwrite an existing `/etc/powersave.conf` or `~/.config/powersave/workloads`.

## Restore

    powersave restore

Then log out and back in if `--gpu-off` was used, so the session starts with the previous PRIME mode.

## Uninstall

    powersave restore
    ./install.sh --uninstall

This removes the installed scripts, the udev rule, the systemd service and the `~/.profile` block. It keeps `/etc/powersave.conf`, `~/.config/powersave/workloads`, `~/.local/state/powersave` and `/var/lib/powersave`; delete them by hand if you want them gone.

## Design notes

- Never `fuser -k /dev/nvidia*`, and never load `nvidia_modeset` into a running X session that started on the Intel GPU. Both log you out. `restore` leaves the driver unloaded while gdm is running and says so.
- Never kill `gsd-*`. `gsd-power` handles battery management and `gsd-media-keys` owns the brightness keys.
- `--dry-run` must not change anything.
- `restore` only restarts what this tool stopped. The lists live in `~/.local/state/powersave/`.
- The console autorun checks three things (the marker file, an empty `$DISPLAY`, and a real text console) so it cannot run inside a graphical session.

## License

MIT. See [LICENSE](LICENSE).
