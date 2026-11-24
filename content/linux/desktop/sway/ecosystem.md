---
title: The Sway ecosystem
description: The tools a bare compositor does not include — bar and Waybar modules, launcher, notifications, lock and idle, screenshots, clipboard, screen sharing, display profiles and login
tags: [linux, desktop, sway, wayland, waybar]
type: reference
status: complete
---

# The Sway ecosystem

Sway tiles windows and nothing more. A usable desktop needs a dozen small tools
around it. This note lists one good default for each job, and the main alternative.

## Overview

| Job | Default choice | Alternatives |
| --- | --- | --- |
| Terminal | `foot` | `alacritty`, `kitty`, `wezterm` |
| Bar | `waybar` | `swaybar` (built in), `i3status-rust` as its status command |
| Launcher | `fuzzel` | `wofi`, `tofi`, `rofi` (2.x), `wmenu` |
| Notifications | `mako` | `swaync` (with a notification centre), `dunst` |
| Lock screen | `swaylock` | `swaylock-effects`, `gtklock` |
| Idle handling | `swayidle` | — |
| Screenshots | `grim` + `slurp` | `grimshot` (wrapper), `satty` (annotation) |
| Clipboard | `wl-clipboard` | `cliphist` for history |
| Display profiles | `kanshi` | `way-displays`; `wdisplays` for a GUI |
| Screen sharing | `xdg-desktop-portal-wlr` | — |
| File chooser portal | `xdg-desktop-portal-gtk` | — |
| Polkit agent | `polkit-gnome` | `lxqt-policykit` |
| Audio control | `pavucontrol` | `pwvucontrol`, `wpctl` on the command line |
| Network | `nm-applet --indicator` | `nmtui` |
| Brightness | `brightnessctl` | `light` |
| Volume / brightness pop-up | `swayosd` | `wob` |
| Night light | `wlsunset` | `gammastep` |
| Login | `greetd` + `tuigreet` | `exec sway` from the tty, `sddm`, `gdm` |

On openSUSE Leap 16.0 all the default choices are packaged, except `cliphist`
and `swayosd`.

## Bar: Waybar

`swaybar` is fine and needs no setup. **Waybar** is what most people end up with:
it has a tray, clickable modules, and CSS styling.

Config in `~/.config/waybar/config.jsonc`, style in `~/.config/waybar/style.css`.

```jsonc
{
  "layer": "top",
  "position": "top",
  "height": 26,
  "modules-left":   ["sway/workspaces", "sway/mode", "sway/scratchpad"],
  "modules-center": ["sway/window"],
  "modules-right":  ["idle_inhibitor", "pulseaudio", "network", "cpu", "memory",
                     "battery", "clock", "tray"],

  "sway/workspaces": { "disable-scroll": true, "all-outputs": false },
  "sway/mode":       { "format": "{}" },
  "clock":           { "format": "{:%a %d %b  %H:%M}", "tooltip-format": "{calendar}" },
  "battery":         { "states": { "warning": 25, "critical": 10 },
                       "format": "{capacity}% {icon}" },
  "network":         { "format-wifi": "{essid} {signalStrength}%",
                       "format-ethernet": "{ipaddr}",
                       "format-disconnected": "offline" },
  "pulseaudio":      { "format": "{volume}%", "on-click": "pavucontrol" },
  "idle_inhibitor":  { "format": "{icon}",
                       "format-icons": { "activated": "awake", "deactivated": "idle" } },
  "tray":            { "spacing": 8 }
}
```

The modules worth knowing:

| Module | Shows |
| --- | --- |
| `sway/workspaces` | Workspace buttons, clickable |
| `sway/mode` | The active binding mode (`resize`, your system mode) — hidden in default mode |
| `sway/window` | Title of the focused window |
| `sway/scratchpad` | How many windows are in the scratchpad |
| `sway/language` | Current keyboard layout |
| `idle_inhibitor` | A toggle that stops `swayidle` — for presentations and video |
| `pulseaudio` / `wireplumber` | Volume; click and scroll to change it |
| `network`, `bluetooth` | Connection state |
| `cpu`, `memory`, `temperature`, `disk` | System load |
| `battery`, `backlight` | Laptop state |
| `clock` | Date and time, with a calendar tooltip |
| `tray` | System tray icons (`nm-applet`, `blueman-applet`) |
| `custom/<name>` | The output of any script |

A custom module runs a script and shows its output. With `"return-type": "json"`
the script can also set the tooltip and a CSS class:

```jsonc
"custom/vpn": {
  "exec": "~/.config/waybar/vpn-status.sh",
  "return-type": "json",
  "interval": 10,
  "on-click": "~/.config/waybar/vpn-toggle.sh"
}
```

```bash
#!/usr/bin/env bash
# vpn-status.sh — prints one JSON line for Waybar
if ip link show wg0 &>/dev/null; then
  echo '{"text": "vpn", "class": "up", "tooltip": "wg0 is up"}'
else
  echo '{"text": "no vpn", "class": "down"}'
fi
```

Remove the `bar { ... }` block from the Sway config, and start Waybar instead — as a systemd user service ideally, see
[[linux/desktop/sway/best-practices]]. Waybar reloads its config on `SIGUSR2`:
`pkill -SIGUSR2 waybar`.

## Lock and idle

`swayidle` watches for inactivity and runs commands. `swaylock` locks.

```text
exec swayidle -w \
    timeout 300  'swaylock -f' \
    timeout 600  'swaymsg "output * power off"' \
         resume  'swaymsg "output * power on"' \
    before-sleep 'swaylock -f'
```

- `-w` waits for each command to finish. Without it, `before-sleep` may suspend the
  machine before the lock screen is drawn, and the unlocked desktop shows for a
  moment on resume.
- `swaylock -f` forks once the screen is locked.
- `output * power off` replaces the older `dpms off`.

> [!warning] Lock before suspend, not after
> The `before-sleep` line is the one that matters for security. Idle timeouts are a
> convenience; a laptop closed in a train must lock **before** it sleeps.

## Screenshots

```bash
grim ~/screenshot.png                         # all outputs
grim -g "$(slurp)" ~/region.png               # select a region
grim -g "$(slurp)" - | wl-copy                # region to clipboard
grim -o "$(swaymsg -t get_outputs | jq -r '.[] | select(.focused) | .name')" - | wl-copy
```

```text
bindsym Print       exec grim -g "$(slurp)" - | wl-copy
bindsym Shift+Print exec grim - | wl-copy
```

## Clipboard

`wl-copy` and `wl-paste` replace `xclip`. On Wayland the clipboard belongs to the
application that copied: close it and the content is gone. `cliphist` keeps a
history:

```text
exec wl-paste --watch cliphist store
bindsym $mod+c exec cliphist list | fuzzel --dmenu | cliphist decode | wl-copy
```

## Screen sharing

Browsers and video-call apps share the screen through **xdg-desktop-portal**. Sway
needs the `wlr` backend for screen capture, and the `gtk` backend for file
choosers:

- `xdg-desktop-portal`
- `xdg-desktop-portal-wlr`
- `xdg-desktop-portal-gtk`

The portal finds Sway through `XDG_CURRENT_DESKTOP=sway`, which must be in the
**systemd user environment**, not just in your shell. Sway does not set this
variable itself: the session launcher does. On openSUSE, the login manager starts
`/usr/bin/sway-run.sh`, which exports it. The `/etc/sway/config.d` snippet then
copies Sway's environment into systemd. If screen sharing shows an empty list, this
is the first thing to check — see [[linux/desktop/sway/best-practices]].

> [!warning] Correction
> The original note said the `/etc/sway/config.d` snippet sets
> `XDG_CURRENT_DESKTOP`. It only copies the environment: when you run `sway` by
> hand, the variable is missing unless you export it first, as in
> [[#Login]].

## Display profiles: kanshi

kanshi applies an output layout when a matching set of screens is connected.
`~/.config/kanshi/config`:

```text
profile laptop {
    output eDP-1 enable scale 1.5
}

profile docked {
    output eDP-1 disable
    output "Dell Inc. DELL U2720Q ABC1234" enable mode 3840x2160 scale 1.5 position 0,0
}
```

Plug or unplug a screen and kanshi switches profile. Remove the matching `output`
lines from the Sway config so the two do not fight.

## Login

Two simple options:

- **From the tty**: log in on the console and run `sway`. Add it to your shell
  profile to start it on tty1 only:

  ```bash
  # ~/.zprofile
  if [ -z "$WAYLAND_DISPLAY" ] && [ "$XDG_VTNR" = 1 ]; then
    export XDG_CURRENT_DESKTOP=sway
    exec sway
  fi
  ```

- **greetd + tuigreet**: a small text-mode login manager that starts `sway`. Lighter
  than GDM or SDDM, and it handles the session setup for you.

## Where to go next

- [[linux/desktop/sway/customization]] — styling Waybar and the rest
- [[linux/desktop/sway/best-practices]] — starting these tools as services
- [[linux/desktop/sway/nixos]] — each of these as a home-manager module

<!-- uplink -->
Part of [[linux/desktop/sway/index|Sway]].
