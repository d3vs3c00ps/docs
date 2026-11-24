---
title: Sway basics
description: What Sway is, what changes coming from i3, the container tree and layouts, and inspecting the running session over IPC
tags: [linux, desktop, sway, wayland, tiling]
type: concept
status: complete
---

# Sway basics

Sway is a tiling **Wayland compositor** that reads an i3 configuration file. If you
know i3, you already know most of Sway: the same keybindings, the same tree of
containers, the same commands.

## Compositor, not window manager

On X11, the X server draws the screen and the window manager is just one client
among others. i3 asks the X server to move windows; other programs (`xrandr`,
`xinput`, `picom`, `xdotool`) talk to the X server directly.

On Wayland there is no X server. The compositor *is* the display server. Sway owns
the screens, the keyboard, the mouse and every window. So everything that used to be
a separate X tool is now either a Sway command or a Wayland-specific tool.

| On i3 / X11 | On Sway / Wayland |
| --- | --- |
| `xrandr` | `output` command, `kanshi`, `wdisplays` |
| `xinput`, `setxkbmap`, `xmodmap` | `input` command |
| `i3-msg` | `swaymsg` |
| `i3bar` + `i3status` | `swaybar` (built in) or `waybar` |
| `i3lock`, `xss-lock` | `swaylock`, `swayidle` |
| `feh --bg-fill` | `output * bg`, `swaybg` |
| `dmenu`, `rofi` | `fuzzel`, `wofi`, `wmenu`, `rofi` (Wayland support in 2.x) |
| `scrot`, `maim` | `grim` + `slurp` |
| `xclip`, `xsel` | `wl-copy`, `wl-paste` |
| `picom` | nothing — Sway does not need a separate compositor |
| `xdotool` | `wtype`, `ydotool` (partial) |

X11-only applications still run through **XWayland**, a small X server that Sway
starts on demand. See [[linux/desktop/sway/ecosystem]] for each replacement.

> [!note] What does not come across from i3
> Sway has no `restart` command. Reload is enough, because Sway re-reads the config
> in place. Most i3 configs work once you remove the `exec` lines that start X11
> tools (`xrandr`, `feh`, `picom`, `xss-lock`) and use the Sway equivalents above.

## Configuration file

Sway uses the first config file it finds, in this order:

1. `~/.sway/config`
2. `~/.config/sway/config` (`$XDG_CONFIG_HOME/sway/config`) — the usual place
3. `~/.i3/config`, then `~/.config/i3/config` — an existing i3 config
4. `/etc/sway/config` — the distribution default
5. `/etc/i3/config`

`sway -c FILE` uses FILE instead.

Start from the default, not from an empty file:

```bash
mkdir -p ~/.config/sway
cp /etc/sway/config ~/.config/sway/config
```

The default ends with an `include /etc/sway/config.d/*` line (on openSUSE,
`include /etc/sway/config.d/*.conf`, then `include ~/.config/sway/config.d/*`). Keep
it. On many distributions that folder holds a snippet that exports the session environment to
systemd and D-Bus — without it, screen sharing and some tray icons break. See
[[linux/desktop/sway/best-practices]].

Reload after each change with `$mod+Shift+c`, or `swaymsg reload`. A line with an
error shows a red bar (`swaynag`) at the top of the screen. Sway still applies the
rest of the new config, so check it first with `sway -C`.

> [!warning] Correction
> This note said that after a syntax error the previous config stays active. Sway
> applies the new config and skips only the lines with errors.

## The container tree

Everything Sway shows is a tree:

```text
root
└── output (eDP-1, DP-2, ...)          a physical screen
    └── workspace (1, 2, "web", ...)   lives on one output at a time
        └── container                  has a layout
            ├── window (view)
            └── container
                ├── window
                └── window
```

Each container has one **layout** that arranges its children:

| Layout | Default key | Effect |
| --- | --- | --- |
| `splith` | `$mod+b` | Children side by side |
| `splitv` | `$mod+v` | Children stacked top to bottom |
| `stacking` | `$mod+s` | One child visible, titles listed above |
| `tabbed` | `$mod+w` | One child visible, titles as tabs |
| toggle split | `$mod+e` | Switch between `splith` and `splitv` |

The key idea from i3: you choose the split **before** you open the next window.
`$mod+v` then `$mod+Enter` puts the new terminal below the current one.

`$mod+a` moves focus to the parent container. Then a layout change or a move applies
to the whole group, not to a single window.

## Floating and scratchpad

| Action | Default key |
| --- | --- |
| Toggle floating for the focused window | `$mod+Shift+space` |
| Switch focus between tiled and floating | `$mod+space` |
| Send window to the scratchpad | `$mod+Shift+minus` |
| Show / hide the scratchpad | `$mod+minus` |

The scratchpad is a hidden workspace. It is good for a terminal or a password
manager you open often and hide again.

## Workspaces and outputs

A workspace belongs to one output. With two screens, workspace 1 can be on the
laptop and workspace 2 on the external screen. Pin them in the config so they do
not move around:

```text
workspace 1 output eDP-1
workspace 2 output DP-2 eDP-1
```

With several outputs listed, the first one that is connected wins. Keep comments on
their own line: Sway does not allow them at the end of a command (see
[[linux/desktop/sway/configuration#Variables]]).

## Inspecting the session with IPC

Sway exposes everything over an IPC socket (`$SWAYSOCK`), with the same protocol as
i3. `swaymsg` talks to it. Its output is JSON, so `jq` is the natural partner.

```bash
swaymsg -t get_outputs            # screens: names, modes, scale
swaymsg -t get_inputs             # keyboards, touchpads, identifiers
swaymsg -t get_workspaces
swaymsg -t get_tree               # the full container tree

# app_id or X11 class of the focused window — needed for window rules
swaymsg -t get_tree | jq -r '.. | select(.focused? == true) | .app_id // .window_properties.class'

swaymsg -m -t subscribe '["window"]'  # stream window events live (-m: keep listening)
```

Any command you can write in the config also works through `swaymsg`:

```bash
swaymsg 'output eDP-1 scale 1.25'
swaymsg '[app_id="foot"] floating enable'
```

This is the fastest way to try a setting before you write it into the config.

> [!tip] i3ipc libraries work unchanged
> Python `i3ipc`, `i3ipc-rs` and similar libraries connect to Sway as if it were
> i3. Scripts you wrote for i3 IPC (autotiling, workspace renamers) usually run as is.

## Where to go next

- [[linux/desktop/sway/configuration]] — making changes: keys, inputs, outputs, rules
- [[linux/desktop/sway/ecosystem]] — the bar, launcher, lock and other tools
- [[linux/desktop/sway/nixos]] — running Sway on NixOS

<!-- uplink -->
Part of [[linux/desktop/sway/index|Sway]].
