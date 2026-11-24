---
title: Configuring Sway
description: Making changes to a Sway config — variables, keybindings on an azerty keyboard, modes, input and output devices, window rules, autostart, and checking a config before reload
tags: [linux, desktop, sway, wayland, configuration]
type: howto
status: complete
---

# Configuring Sway

Every line in the Sway config is a command. The same command typed into `swaymsg`
applies right away, so try a change live first, then write it down. See
[[linux/desktop/sway/basics]] for the model behind the commands.

## Variables

```text
set $mod   Mod4
set $left  h
set $down  j
set $up    k
set $right l
set $term  foot
set $menu  fuzzel
```

`Mod4` is the Super (Windows) key and `Mod1` is Alt. Use `Mod4` on a workstation:
Alt is used by too many applications.

> [!warning] Comments go on their own line
> Sway reads `#` as a comment only at the start of a line. After a command, `#` and
> the words after it are arguments. `set $mod Mod4  # Super key` makes `$mod` the
> whole text `Mod4 # Super key`, so every `$mod` binding breaks with no error.
> `pos 0 0  # comment` is an error. A comma in a trailing comment even starts a new
> command.

> [!warning] No comments at the end of a line
> Put comments on their own line. `sway -C` reports most end-of-line comments as
> errors, but not a broken `set $mod` line.

## Keybindings

```text
bindsym $mod+Return exec $term
bindsym $mod+d      exec $menu
bindsym $mod+Shift+q kill
bindsym $mod+Shift+c reload

bindsym $mod+$left  focus left
bindsym $mod+Shift+$left move left
```

Useful flags:

| Flag | Effect |
| --- | --- |
| `--locked` | Also works while the screen is locked — for volume and brightness keys |
| `--release` | Runs on key release, not press |
| `--to-code` | Binds the physical key position, so the binding survives a layout switch |
| `--no-repeat` | Ignores key repeat while held |

Media keys, with PipeWire and `brightnessctl`:

```text
bindsym --locked XF86AudioRaiseVolume  exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
bindsym --locked XF86AudioLowerVolume  exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindsym --locked XF86AudioMute         exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindsym --locked XF86MonBrightnessUp   exec brightnessctl set 5%+
bindsym --locked XF86MonBrightnessDown exec brightnessctl set 5%-
```

### Workspaces on an azerty keyboard

The default config binds `$mod+1` … `$mod+0`. On a French azerty keyboard, the
number row without Shift produces `& é " ' ( - è _ ç à`, so those bindings never
fire. Two fixes.

Use the azerty key names:

```text
bindsym $mod+ampersand  workspace number 1
bindsym $mod+eacute     workspace number 2
bindsym $mod+quotedbl   workspace number 3
bindsym $mod+apostrophe workspace number 4
bindsym $mod+parenleft  workspace number 5
bindsym $mod+minus      workspace number 6
bindsym $mod+egrave     workspace number 7
bindsym $mod+underscore workspace number 8
bindsym $mod+ccedilla   workspace number 9
bindsym $mod+agrave     workspace number 10
```

Or bind the key codes, which do not depend on the layout at all:

```text
bindcode $mod+10       workspace number 1
bindcode $mod+Shift+10 move container to workspace number 1
# ... up to 19 for workspace 10
```

> [!warning] `$mod+minus` is already the scratchpad
> The default config binds `$mod+minus` to `scratchpad show`. On azerty, `minus` is
> also the key for workspace 6. Move the scratchpad to another key, or use
> `bindcode` for workspaces.

Find the name of any key with `wev`: run it, press the key, read the `sym` field.
`bindcode` uses XKB key codes; 10 to 19 are the number row on a standard PC
keyboard.

## Modes

A mode is a separate set of bindings. The default config has a `resize` mode. A
"system" mode is the common second one:

```text
set $mode_system "(l)ock  (e)xit  (s)uspend  (r)eboot  (p)oweroff"
mode $mode_system {
    bindsym l exec swaylock -f,          mode "default"
    bindsym e exit
    bindsym s exec systemctl suspend,    mode "default"
    bindsym r exec systemctl reboot
    bindsym p exec systemctl poweroff
    bindsym Escape mode "default"
    bindsym Return mode "default"
}
bindsym $mod+Shift+e mode $mode_system
```

Always give a mode an `Escape` binding. A mode without a way out leaves you with a
keyboard that does nothing.

## Input devices

List devices and their identifiers with `swaymsg -t get_inputs`. Then configure by
type or by identifier:

```text
input type:keyboard {
    xkb_layout  fr
    xkb_options caps:escape
    repeat_delay 300
    repeat_rate  40
}

input type:touchpad {
    tap            enabled
    natural_scroll enabled
    dwt            enabled
    middle_emulation enabled
}

input "1133:49291:Logitech_G502" {
    accel_profile flat
    pointer_accel 0
}
```

`dwt` disables the touchpad while you type.

`xkb_layout "fr,us"` with `xkb_options grp:alt_shift_toggle` gives two layouts and a
key combination to switch between them.

## Outputs

Names come from `swaymsg -t get_outputs`:

```text
output eDP-1 {
    mode  2560x1600@60Hz
    scale 1.5
    pos   0 0
}

output DP-2 {
    mode 3840x2160@60Hz
    scale 1.5
    pos  1706 0
}
```

Positions are in **logical** pixels — after scaling. That is the usual mistake: a
2560 px screen at scale 1.5 is 2560 / 1.5 = 1706.67 logical pixels wide. Sway rounds
down to 1706, so the next screen starts at `1706`, not at `2560`.
`swaymsg -t get_outputs` shows the logical size in `rect.width`.

> [!note] Why 1706
> Sway rounds the logical width down, to 1706, so `pos 1707 0` leaves a one-pixel gap
> between the screens.

Connector names (`DP-2`) change when you plug into a different dock port. Use the
full description from `get_outputs` instead to match one specific monitor:

```text
output "Dell Inc. DELL U2720Q ABC1234" scale 1.5
```

For a laptop that docks and undocks, use **kanshi**: it applies a profile when a
given set of screens is connected. See [[linux/desktop/sway/ecosystem]].

## Window rules

`for_window` runs commands on every new window that matches. `assign` sends it to a
workspace.

```text
for_window [app_id="pavucontrol"]     floating enable
for_window [app_id="org.keepassxc.KeePassXC"] floating enable, move scratchpad
for_window [window_role="pop-up"]     floating enable
for_window [title="Picture-in-Picture"] floating enable, sticky enable

assign [app_id="firefox"]   workspace number 2
assign [class="Slack"]      workspace number 9
```

Native Wayland windows have an `app_id`. X11 windows running under XWayland have a
`class` instead and no `app_id`. Match the wrong one and the rule does nothing.
Check which one a window has with the `jq` command in
[[linux/desktop/sway/basics#Inspecting the session with IPC]].

Mark XWayland windows so you can see them:

```text
for_window [shell="xwayland"] title_format "[X] %title"
```

## Autostart

```text
exec        mako
exec_always "pkill kanshi; exec kanshi"
```

The `exec_always` line restarts kanshi at each reload, so it never runs twice.

| Command | Runs |
| --- | --- |
| `exec` | Once, when Sway starts |
| `exec_always` | At start **and on every reload** |

`exec_always` on a daemon starts a second copy at each reload. Use it only for
commands that are safe to run twice. For long-running helpers, prefer systemd user
services — see [[linux/desktop/sway/best-practices]].

## Splitting the config

```text
# at the end of ~/.config/sway/config
include ~/.config/sway/config.d/*
include /etc/sway/config.d/*
```

```text
~/.config/sway/
├── config            # variables, core keys, includes
└── config.d/
    ├── 10-input.conf
    ├── 20-output.conf
    ├── 30-rules.conf
    ├── 40-theme.conf
    └── 50-autostart.conf
```

Files are read in alphabetical order. Variables must be `set` before the files that
use them.

## Checking before reload

```bash
sway -C                         # parse the config, report errors, exit
sway -C -c ~/.config/sway/config.new
```

A reload with errors does not keep the old config. Sway applies every line it can
parse, skips the bad ones, and shows the errors in a `swaynag` bar. So a typo can
lose a binding or a block. A *wrong but valid* config is worse: a bad `input` block
can leave you with no keyboard layout, a bad `output` block with a black screen.
Run `sway -C` first, keep a terminal open, and test such changes live with
`swaymsg`.

> [!note] A failed reload
> Sway 1.10 applies the new config without the lines that have errors. It does not keep
> the old config.

## Where to go next

- [[linux/desktop/sway/customization]] — gaps, colors, fonts, themes
- [[linux/desktop/sway/best-practices]] — keeping the config healthy
- [[linux/desktop/sway/nixos]] — the same settings written in Nix

<!-- uplink -->
Part of [[linux/desktop/sway/index|Sway]].
