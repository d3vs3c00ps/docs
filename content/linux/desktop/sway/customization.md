---
title: Customizing Sway
description: Gaps, borders, window colors, fonts and wallpaper in Sway, GTK and Qt themes and the cursor on Wayland, styling Waybar, and keeping one color palette across tools
tags: [linux, desktop, sway, wayland, theming]
type: howto
status: complete
---

# Customizing Sway

Sway draws only borders, title bars and gaps. Everything else — the bar, the
launcher, the applications — has its own theme. A consistent look means setting the
same few values in several places.

## Gaps and borders

```text
default_border          pixel 2
default_floating_border normal
titlebar_padding        6 2

gaps inner 6
gaps outer 2
smart_gaps on
smart_borders on
```

- `pixel 2`: tiled windows get a 2-pixel border and no title bar.
- `normal`: windows that open floating, such as dialogs, get a title bar. A window
  you make floating later, or with a `for_window` rule, keeps its tiled border.
- `smart_gaps on`: no gaps when a workspace has only one window.
- `smart_borders on`: no border either in that case.

> [!warning] Correction
> The comments in this block were at the end of the lines. Sway does not allow that,
> and `sway -C` reports errors for these lines. See
> [[linux/desktop/sway/configuration#Variables]].

With `pixel` borders, tabbed and stacking containers still show their tab titles.
That is the only place titles remain, which is usually what you want.

## Window colors

```text
#                       border  background text    indicator child_border
client.focused          #89b4fa #89b4fa    #1e1e2e #f5c2e7   #89b4fa
client.focused_inactive #45475a #45475a    #cdd6f4 #45475a   #45475a
client.unfocused        #313244 #313244    #a6adc8 #313244   #313244
client.urgent           #f38ba8 #f38ba8    #1e1e2e #f38ba8   #f38ba8
```

- `border`, `background`, `text` apply to the title bar.
- `child_border` is the border around the window — the one you see with `pixel`.
- `indicator` is the edge where the **next** window will open. It shows the current
  split direction, so give it a distinct color.

## Fonts

```text
font pango:JetBrains Mono 10
```

This sets title bars and `swaybar`. Each other tool has its own font setting —
Waybar in CSS, `foot` in `foot.ini`, `fuzzel` in `fuzzel.ini`.

## Wallpaper

```text
output * bg ~/Pictures/wallpaper.jpg fill
output * bg #1e1e2e solid_color
output DP-2 bg ~/Pictures/wide.jpg fill
```

Sway starts `swaybg` for you. Modes are `fill`, `fit`, `stretch`, `center`, `tile`
and `solid_color`.

## GTK theme, dark mode and cursor

On Wayland, GTK applications read most theme settings from **gsettings**, not from
`~/.config/gtk-3.0/settings.ini`. Set them with:

```bash
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface gtk-theme    'Adwaita-dark'
gsettings set org.gnome.desktop.interface icon-theme   'Adwaita'
gsettings set org.gnome.desktop.interface cursor-theme 'Adwaita'
gsettings set org.gnome.desktop.interface font-name    'Inter 10'
```

`color-scheme` is the setting that matters most today: GTK4/libadwaita apps and
Firefox follow it, and they ignore `gtk-theme`.

The cursor is set in two places — Sway for its own surfaces and XWayland, gsettings
for GTK:

```text
seat seat0 xcursor_theme Adwaita 24
```

## Qt applications

Qt picks its platform and theme from environment variables. They must be set
**before** Sway starts, so every application inherits them — in the shell profile
that runs `exec sway`, for example:

```bash
# ~/.zprofile, before exec sway
export QT_QPA_PLATFORM="wayland;xcb"
export QT_QPA_PLATFORMTHEME=qt6ct
```

`wayland;xcb` tries Wayland first and falls back to XWayland. `qt6ct` (and `qt5ct`
for older apps) is a small GUI to pick the Qt style and colors. Kvantum is the
option for a theme closer to your GTK one.

## Styling Waybar

Waybar is styled with GTK CSS in `~/.config/waybar/style.css`. Each module gets an
id (`#clock`, `#battery`, `#custom-vpn`) and state classes.

```css
* {
  font-family: "JetBrains Mono", monospace;
  font-size: 12px;
  min-height: 0;
}

window#waybar {
  background: #1e1e2e;
  color: #cdd6f4;
}

#workspaces button {
  padding: 0 6px;
  color: #a6adc8;
  border-radius: 0;
}
#workspaces button.focused { background: #89b4fa; color: #1e1e2e; }
#workspaces button.urgent  { background: #f38ba8; color: #1e1e2e; }

#mode { background: #f9e2af; color: #1e1e2e; padding: 0 8px; }

#clock, #battery, #network, #pulseaudio, #cpu, #memory, #tray {
  padding: 0 8px;
}

#battery.warning  { color: #f9e2af; }
#battery.critical { color: #f38ba8; }
#custom-vpn.down  { color: #f38ba8; }
```

Run `GTK_DEBUG=interactive waybar` to open the GTK inspector on the bar and find the
selector for any element.

## One palette for every tool

The colors above appear in the Sway config, Waybar CSS, the terminal, the launcher,
`mako` and `swaylock`. Keep them in one place:

- In a plain config, define them once as Sway variables in
  `config.d/00-colors.conf` (`set $blue #89b4fa`), and keep the other files short
  enough to update by hand.
- Use a published palette that already ships themes for each tool — Catppuccin,
  Gruvbox, Nord, Tokyo Night all provide Sway, Waybar, foot, fuzzel and mako themes.
- On NixOS, generate every file from one Nix attribute set, or use **Stylix**, which
  themes the whole set of applications from one palette. See
  [[linux/desktop/sway/nixos]].

## Where to go next

- [[linux/desktop/sway/ecosystem]] — the tools being themed
- [[linux/desktop/sway/best-practices]] — keeping the config in Git
- [[linux/desktop/sway/nixos]] — the same theme declared in Nix

<!-- uplink -->
Part of [[linux/desktop/sway/index|Sway]].
