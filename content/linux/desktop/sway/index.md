---
title: "Sway"
description: "A tiling Wayland compositor that reads an i3 configuration — the model, making changes, the tools a bare compositor lacks, theming, and running it on NixOS."
tags: [sway]
type: moc
status: complete
---

<!-- generated-moc -->

# Sway

A tiling Wayland compositor that reads an i3 configuration — the model, making changes, the tools a bare compositor lacks, theming, and running it on NixOS.


| Note | | What it covers |
| --- | --- | --- |
| [[linux/desktop/sway/basics\|Sway basics]] | concept | What Sway is, what changes coming from i3, the container tree and layouts, and inspecting the running session over IPC |
| [[linux/desktop/sway/best-practices\|Sway best practices]] | reference | Keeping a Sway setup healthy — config in Git, the session environment, helpers as systemd user services, safe changes, locking, native Wayland apps, NVIDIA and debugging |
| [[linux/desktop/sway/configuration\|Configuring Sway]] | how-to | Making changes to a Sway config — variables, keybindings on an azerty keyboard, modes, input and output devices, window rules, autostart, and checking a config before reload |
| [[linux/desktop/sway/customization\|Customizing Sway]] | how-to | Gaps, borders, window colors, fonts and wallpaper in Sway, GTK and Qt themes and the cursor on Wayland, styling Waybar, and keeping one color palette across tools |
| [[linux/desktop/sway/ecosystem\|The Sway ecosystem]] | reference | The tools a bare compositor does not include — bar and Waybar modules, launcher, notifications, lock and idle, screenshots, clipboard, screen sharing, display profiles and login |
| [[linux/desktop/sway/nixos\|Sway on NixOS]] | how-to | Running Sway on NixOS — what the system module sets up, a login manager, the full user setup in home-manager (keys, inputs, outputs, Waybar, mako, swayidle, kanshi) and testing changes in a VM |

Part of [[linux/desktop/index|Desktop]].
