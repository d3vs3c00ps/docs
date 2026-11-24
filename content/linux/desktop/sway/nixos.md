---
title: Sway on NixOS
description: Running Sway on NixOS — what the system module sets up, a login manager, the full user setup in home-manager (keys, inputs, outputs, Waybar, mako, swayidle, kanshi) and testing changes in a VM
tags: [linux, desktop, sway, nixos, home-manager]
type: howto
status: complete
---

# Sway on NixOS

On NixOS, Sway is configured in two layers:

| Layer | Module | Holds |
| --- | --- | --- |
| System | `programs.sway` (NixOS) | The compositor, polkit, portals, PAM for the lock screen, the session target |
| User | `wayland.windowManager.sway` (home-manager) | Keybindings, inputs, outputs, bar, helpers, theme |

Put the system parts in the system config and the rest in home-manager. Then the
whole desktop — packages and config — lives in the same flake. Checked against
NixOS 26.05, home-manager `release-26.05` and Sway 1.12.

## System side

```nix
{ pkgs, ... }:
{
  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;          # GTK apps get the right environment
    extraPackages = with pkgs; [         # replaces the default list
      foot wmenu swaylock swayidle grim slurp wl-clipboard brightnessctl
    ];
  };

  services.greetd = {
    enable = true;
    settings.default_session.command =
      "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd sway";
  };

  services.pipewire = {                  # audio and screen sharing
    enable = true;
    pulse.enable = true;
  };

  fonts.packages = with pkgs; [ jetbrains-mono noto-fonts noto-fonts-color-emoji ];
}
```

Enabling `programs.sway` already does a lot for you:

- turns on polkit and dconf;
- adds the PAM entry that `swaylock` needs to check your password;
- enables `xdg-desktop-portal-wlr` and the GTK portal, configured for Sway;
- sets `XDG_CURRENT_DESKTOP=sway` in its wrapper;
- adds `/etc/sway/config.d/nixos.conf`, which exports the environment to systemd
  and D-Bus;
- provides `sway-session.target`.

So the environment problems in [[linux/desktop/sway/best-practices#Export the session environment]]
do not happen on NixOS, as long as the config keeps including `/etc/sway/config.d/*`.
A config from home-manager does not include it, but `systemd.enable = true` (below)
adds the same export line itself.

> [!note] No `include` line
> The config home-manager writes has no `include /etc/sway/config.d/*` line. The export
> still happens, through the `exec dbus-update-activation-environment --systemd …`
> line that its `systemd.enable` adds. If you turn that off, add the `include` line in
> `extraConfig`.

> [!note] Package names that moved
> The greeter is now top-level `pkgs.tuigreet`. The old `pkgs.greetd.tuigreet`
> still works but prints a rename warning.

## User side with home-manager

Install Sway from the NixOS module and let home-manager write only the config:
set `package = null`, or you get two copies.

```nix
{ config, lib, pkgs, ... }:
let
  mod = "Mod4";
in
{
  wayland.windowManager.sway = {
    enable = true;
    package = null;                      # installed by programs.sway
    checkConfig = false;                 # sway -C needs a package; see below
    systemd.enable = true;               # sway-session.target

    config = {
      modifier = mod;
      terminal = "foot";
      menu = "fuzzel";
      bars = [ ];                        # Waybar runs as a service instead

      input = {
        "type:keyboard" = {
          xkb_layout = "fr";
          xkb_options = "caps:escape";
          repeat_delay = "300";
          repeat_rate = "40";
        };
        "type:touchpad" = {
          tap = "enabled";
          natural_scroll = "enabled";
          dwt = "enabled";
        };
      };

      output = {
        "eDP-1" = { scale = "1.5"; };
        "*" = { bg = "${./wallpaper.jpg} fill"; };
      };

      gaps = { inner = 6; smartGaps = true; };
      window.border = 2;

      window.commands = [
        { criteria.app_id = "pavucontrol"; command = "floating enable"; }
      ];
      assigns."2" = [ { app_id = "firefox"; } ];

      keybindings = lib.mkOptionDefault {
        "${mod}+Shift+e" = ''mode "system"'';
        "Print" = ''exec grim -g "$(slurp)" - | wl-copy'';
        "XF86AudioRaiseVolume" = "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+";
        "XF86AudioLowerVolume" = "exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";
        "XF86AudioMute" = "exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
      };

      modes = lib.mkOptionDefault {
        system = {
          l = ''exec swaylock -f, mode "default"'';
          e = "exit";
          s = ''exec systemctl suspend, mode "default"'';
          r = "exec systemctl reboot";
          p = "exec systemctl poweroff";
          Escape = ''mode "default"'';
        };
      };
    };

    extraConfig = ''
      bindsym --locked XF86MonBrightnessUp   exec brightnessctl set 5%+
      bindsym --locked XF86MonBrightnessDown exec brightnessctl set 5%-
    '';
  };
}
```

> [!warning] `checkConfig` needs a package
> `checkConfig = true` next to `package = null` does not build: home-manager stops with
> `programs.sway.checkConfig requires non-null programs.sway.package`. With the package
> from the NixOS module, turn the check off and run `sway -C` yourself after a rebuild.

> [!tip] `sway -C` outside a session
> Sway 1.12 creates a backend even for `-C`. From a TTY or over SSH it stops with
> `Unable to create backend`. Use the headless backend for the check:
> `WLR_BACKENDS=headless WLR_RENDERER=pixman sway -C -c ~/.config/sway/config`.

> [!tip] `lib.mkOptionDefault` keeps the default bindings
> home-manager ships the standard i3/Sway bindings as the default value of
> `keybindings`. Assigning a plain attribute set **replaces** all of them, and you
> lose focus, move and workspace keys. `lib.mkOptionDefault` merges your keys into
> the defaults instead. The same applies to `modes`, so the `resize` mode stays.
>
> To **change** a key that already has a default, such as `$mod+Shift+e`, just set
> it. home-manager gives each default key the lowest priority, so your value wins.

> [!note] No `lib.mkForce` needed
> With home-manager 26.05, a plain value overrides the default. `lib.mkForce` still
> works, but it is not needed.

The default workspace keys are `$mod+1` … `$mod+0`, which do not work on azerty.
Generate the azerty names from
[[linux/desktop/sway/configuration#Workspaces on an azerty keyboard]] in the `let`
block, and merge them into your `keybindings`:

```nix
let
  mod = "Mod4";
  azerty = [ "ampersand" "eacute" "quotedbl" "apostrophe" "parenleft"
             "minus" "egrave" "underscore" "ccedilla" "agrave" ];
  workspaceKeys = builtins.listToAttrs (lib.concatLists (lib.imap1 (i: key: [
    { name = "${mod}+${key}";       value = "workspace number ${toString i}"; }
    { name = "${mod}+Shift+${key}"; value = "move container to workspace number ${toString i}"; }
  ]) azerty));
in
{
  wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault ({
    "${mod}+Shift+e" = ''mode "system"'';
    # ... the other keys from above
  } // workspaceKeys);
}
```

`$mod+minus` is also the default scratchpad key, and workspace 6 replaces it.
Rebind `scratchpad show` to another key.

## Helpers as home-manager services

Each helper from [[linux/desktop/sway/ecosystem]] has a module. Those with a
`systemd` option run as user services bound to the graphical session — the setup
[[linux/desktop/sway/best-practices#Run helpers as systemd user services]] builds by
hand.

```nix
{
  programs.waybar = {
    enable = true;
    systemd.enable = true;
    settings.main = {
      layer = "top";
      modules-left = [ "sway/workspaces" "sway/mode" "sway/scratchpad" ];
      modules-center = [ "sway/window" ];
      modules-right = [ "idle_inhibitor" "pulseaudio" "network" "battery" "clock" "tray" ];
      clock.format = "{:%a %d %b  %H:%M}";
    };
    style = ./waybar.css;
  };

  services.mako = {
    enable = true;
    settings = {
      default-timeout = 5000;
      border-radius = 4;
    };
  };

  programs.swaylock = {
    enable = true;
    settings = { color = "1e1e2e"; show-failed-attempts = true; };
  };

  services.swayidle = {
    enable = true;
    timeouts = [
      { timeout = 300; command = "${pkgs.swaylock}/bin/swaylock -f"; }
      { timeout = 600;
        command = ''${pkgs.sway}/bin/swaymsg "output * power off"'';
        resumeCommand = ''${pkgs.sway}/bin/swaymsg "output * power on"''; }
    ];
    events = {
      before-sleep = "${pkgs.swaylock}/bin/swaylock -f";
      lock = "${pkgs.swaylock}/bin/swaylock -f";
    };
  };

  services.kanshi = {
    enable = true;
    settings = [
      { profile.name = "laptop";
        profile.outputs = [ { criteria = "eDP-1"; status = "enable"; scale = 1.5; } ]; }
      { profile.name = "docked";
        profile.outputs = [
          { criteria = "eDP-1"; status = "disable"; }
          { criteria = "Dell Inc. DELL U2720Q ABC1234"; scale = 1.5; position = "0,0"; }
        ]; }
    ];
  };

  services.cliphist.enable = true;
  programs.fuzzel.enable = true;
  programs.foot.enable = true;
}
```

> [!warning] Option shapes that changed recently
> Older examples online will not evaluate, or will warn:
>
> - `services.mako` options moved under `services.mako.settings` (home-manager 25.05).
> - `services.swayidle.events` is an attribute set since 26.05; the old list form
>   still works with a warning.
> - `services.kanshi.profiles` is deprecated in favour of `settings`.
> - Waybar's `systemd.target` became `systemd.targets`, a list, in 26.05.

## One palette with Stylix

[Stylix](https://github.com/nix-community/stylix) takes one color scheme, font set
and wallpaper and themes Sway, Waybar, foot, fuzzel, mako, swaylock, GTK and Qt from
them. It replaces the per-tool colors of [[linux/desktop/sway/customization]]. Add
it once the setup works, not on day one — it touches every module above and makes
the first errors harder to read.

## Trying changes safely

A desktop change is a system rebuild like any other:

```bash
nixos-rebuild build-vm --flake .#workstation   # a VM with your whole desktop
./result/bin/run-workstation-vm

sudo nixos-rebuild switch --flake .#workstation
```

Sway runs in the QEMU window, so you can test keybindings, Waybar and the theme
without touching the running session. A broken result is one rollback away. See
[[linux/distributions/nixos/testing]].

## Where to go next

- [[linux/distributions/nixos/workstation]] — the rest of the workstation config
- [[linux/distributions/nixos/testing]] — build-vm and VM tests
- [[linux/desktop/sway/configuration]] — what each Sway setting means

<!-- uplink -->
Part of [[linux/desktop/sway/index|Sway]].
