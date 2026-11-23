---
title: Sway best practices
description: Keeping a Sway setup healthy — config in Git, the session environment, helpers as systemd user services, safe changes, locking, native Wayland apps, NVIDIA and debugging
tags: [linux, desktop, sway, wayland, systemd]
type: reference
status: complete
---

# Sway best practices

A Sway setup grows one line at a time. These habits keep it working after a year of
small changes, and make it easy to rebuild on a new machine.

## Keep the config in Git

`~/.config/sway`, `~/.config/waybar`, `~/.config/kanshi`, `~/.config/mako`,
`~/.config/foot` — put them in one dotfiles repository. A setup you cannot rebuild
is a setup you are afraid to change.

On NixOS, home-manager does this for you and goes further: the packages and the
config are declared together. See [[linux/desktop/sway/nixos]].

## Start from the default, change in small steps

- Copy `/etc/sway/config` and edit it. Do not start from an empty file or from
  someone else's full dotfiles.
- Split the config into `config.d/` files by topic. See
  [[linux/desktop/sway/configuration#Splitting the config]].
- Try each change with `swaymsg` first, then write it down.
- Run `sway -C` before reloading.

## Never lose the escape keys

Whatever you change, keep these working:

| Key | Command |
| --- | --- |
| `$mod+Return` | Open a terminal |
| `$mod+Shift+c` | Reload |
| `$mod+Shift+e` | Exit, or your system mode |

If the session is unusable, switch to a text console with `Ctrl+Alt+F2`, log in, and
fix the file there. Sway keeps running on its own virtual terminal.

## Export the session environment

Programs started by systemd or D-Bus — portals, notification daemons, tray
applets — do not inherit the variables of your Sway process. They need at least
`WAYLAND_DISPLAY`, `SWAYSOCK` and `XDG_CURRENT_DESKTOP`.

Many distributions ship a snippet in `/etc/sway/config.d/` that does this, similar to:

```text
exec systemctl --user import-environment DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP
exec dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP
```

That is why the default config ends with `include /etc/sway/config.d/*`. Check the
result:

```bash
systemctl --user show-environment | grep -E 'WAYLAND|SWAYSOCK|XDG_CURRENT'
```

> [!tip] Empty screen-sharing list, missing tray icons, slow app start
> These three symptoms usually have the same cause: the environment did not reach
> systemd and D-Bus. Check `XDG_CURRENT_DESKTOP=sway` first — the portal uses it to
> pick the `wlr` backend.
>
> Sway does not set `XDG_CURRENT_DESKTOP` itself. The session launcher does (on
> openSUSE, `/usr/bin/sway-run.sh`). If you start `sway` by hand, export it first.

## Run helpers as systemd user services

`exec waybar` in the config works, but:

- if Waybar crashes, nothing restarts it;
- its output goes nowhere;
- `exec_always` starts a second copy at each reload.

A systemd user service fixes all three. Sway does not start a systemd target by
itself, so create one and start it from the config:

```ini
# ~/.config/systemd/user/sway-session.target
[Unit]
Description=Sway session
BindsTo=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target
```

```text
# last line of the Sway config
exec "systemctl --user import-environment DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP; systemctl --user start sway-session.target"
```

Each helper is then a small unit bound to the graphical session:

```ini
# ~/.config/systemd/user/waybar.service
[Unit]
Description=Waybar
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=/usr/bin/waybar
ExecReload=/bin/kill -SIGUSR2 $MAINPID
Restart=on-failure

[Install]
WantedBy=graphical-session.target
```

```bash
systemctl --user enable --now waybar.service
journalctl --user -u waybar -f
```

When you exit Sway, stop the target so the helpers stop too. Sway can do it itself:
this line waits for Sway's `shutdown` event, then stops the target. The NixOS
`programs.sway` module uses the same line.

```text
exec swaymsg -t subscribe '["shutdown"]' && systemctl --user stop sway-session.target
```

You can also run `systemctl --user stop sway-session.target` in your system mode,
before `exit`.

home-manager generates this target, named `sway-session.target`, and starts it from
the Sway config. Its Waybar, mako, kanshi and swayidle services follow
`graphical-session.target`, which the Sway target pulls in. The NixOS
`programs.sway` module ships the same target. **uwsm** (Universal Wayland
Session Manager) is the alternative outside home-manager: it starts the compositor
itself as a systemd unit and handles the environment and targets.

## Lock before sleep

- `swayidle` with a `before-sleep` command, and `-w`. See
  [[linux/desktop/sway/ecosystem#Lock and idle]].
- A lock key in your system mode.
- The Waybar `idle_inhibitor` for presentations, so you never have to disable
  `swayidle` and forget to turn it back on.

## Prefer native Wayland applications

XWayland works, but XWayland windows are blurry on scaled outputs, and any X11
client can read the keystrokes of other X11 windows.

- Firefox runs natively on Wayland by default.
- Chromium and Electron apps (VS Code, Slack, Obsidian) may still start under
  XWayland, depending on their version. If they do, pass
  `--ozone-platform-hint=auto` (or `--ozone-platform=wayland`).
- Find what still runs under XWayland: `for_window [shell="xwayland"] title_format "[X] %title"`.

## NVIDIA

Sway supports the proprietary NVIDIA driver only on a best-effort basis. Before
1.12 it refused to start with it unless you passed `--unsupported-gpu`. Since 1.12
it starts and shows a warning bar instead; the flag (or `SWAY_UNSUPPORTED_GPU`)
now only hides the warning. Bugs reported with this driver are still not a priority
upstream. If you can choose the hardware for a Sway workstation, choose AMD or Intel
graphics.

## Debugging

```bash
sway -d 2> ~/sway.log            # from a tty: full debug log
swaymsg -t get_version
journalctl --user -b             # helpers started as services
WAYLAND_DEBUG=1 foot             # protocol trace for one client
```

Start with the log. Most "Sway is broken" problems are a helper that failed to
start, or a variable missing from the environment.

## Where to go next

- [[linux/desktop/sway/configuration]] — the commands referred to above
- [[linux/desktop/sway/nixos]] — the declarative version of all of this
- [[linux/boot/systemd]] — units and targets

<!-- uplink -->
Part of [[linux/desktop/sway/index|Sway]].
