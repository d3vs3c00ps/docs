---
title: NixOS as a workstation
description: Desktop environments, home-manager for user configuration, per-project dev shells, and running binaries that expect a normal filesystem
tags: [linux, nixos, nix, desktop, workstation]
type: howto
status: complete
---

# NixOS as a workstation

A workstation is where NixOS is most rewarding and most frustrating: a machine you can
rebuild identically is genuinely valuable, and a desktop is also where you most often
want to run some binary that was never packaged.

## Desktop environment

```nix
{
  # GNOME — Wayland only since 25.11, no services.xserver.enable needed
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  services.xserver.xkb = {
    layout = "fr";
    variant = "azerty";
  };
  console.keyMap = "fr";
}
```

Or KDE Plasma 6, instead of GNOME:

```nix
{
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;
}
```

> [!warning] Correction
> An earlier version put GNOME and Plasma in one block, with "or" in a comment.
> Copied as is, that enables two display managers, and the build stops. Pick one.

Wayland is the default in current GNOME and Plasma.

For a tiling desktop, **Sway** is the stable choice: it reads an i3 config, changes
slowly, and has mature NixOS and home-manager modules. Hyprland moves fast and has
broken configs between releases; niri (scrolling tiling) is good but younger. The
full setup is in nixos.

```nix
programs.sway = {
  enable = true;
  wrapperFeatures.gtk = true;
};
```

## Audio, printing, Bluetooth

```nix
{
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    jack.enable = true;
  };

  services.printing = {
    enable = true;
    drivers = [ pkgs.gutenprint pkgs.hplip ];
  };
  services.avahi = {
    enable = true;
    nssmdns4 = true;              # network printer discovery
  };

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;
}
```

A few lines replace what is usually an afternoon of PulseAudio and CUPS
configuration.

## Graphics and firmware

```nix
{
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;     # for Steam and Wine

  # NVIDIA proprietary
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    open = true;                  # Turing (RTX 20xx) and newer; false for older cards
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  hardware.enableRedistributableFirmware = true;
}
```

Unfree packages need an explicit opt-in, or they refuse to build:

```nix
nixpkgs.config.allowUnfree = true;

# or selectively
nixpkgs.config.allowUnfreePredicate = pkg:
  builtins.elem (lib.getName pkg) [ "nvidia-x11" "nvidia-settings" "vscode" ];
```

The list holds package names, and a feature can need more than one. The NVIDIA block
above needs both `nvidia-x11` and `nvidia-settings`. When a name is missing, the
build stops and the error names the package to add.

## Laptop concerns

```nix
{
  services.tlp.enable = true;
  services.thermald.enable = true;
  powerManagement.enable = true;

  networking.networkmanager.enable = true;

  services.fwupd.enable = true;               # firmware updates
  services.fprintd.enable = true;             # fingerprint reader
}
```

> [!warning] TLP or power-profiles-daemon, not both
> GNOME and Plasma turn on `services.power-profiles-daemon`, and NixOS refuses to
> build with both it and TLP. On those desktops, drop `services.tlp`, or set
> `services.power-profiles-daemon.enable = false`.

`services.fwupd` matters more than it looks — it is how you get the Secure Boot
`db` updates discussed in secure-boot.

## home-manager

System configuration handles the machine. **home-manager** does the same for a user's
dotfiles and applications, declaratively.

```nix
# in flake.nix inputs
home-manager = {
  url = "github:nix-community/home-manager/release-26.05";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

```nix
{
  home-manager.users.alice = { pkgs, ... }: {
    home.stateVersion = "26.05";    # first install, never bump

    home.packages = with pkgs; [ ripgrep fd bat jq ];

    programs.git = {
      enable = true;
      settings = {
        user.name = "Your Name";
        user.email = "your.name@example.com";
        init.defaultBranch = "main";
        pull.rebase = true;
      };
    };

    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      shellAliases = { ll = "ls -lah"; };
    };

    programs.starship.enable = true;

    programs.neovim = {
      enable = true;
      defaultEditor = true;
      plugins = with pkgs.vimPlugins; [ telescope-nvim nvim-treesitter ];
    };
  };
}
```

See git-conventions and zsh for what those settings mean —
including why this configuration deliberately uses individual plugins and a standalone
prompt rather than a framework like Oh My Zsh.

> [!tip] Move to home-manager gradually
> Converting an entire dotfiles collection at once is miserable. Start with one
> program — git is a good first — and add others as you touch them. Anything not yet
> converted keeps working from `~/.config` exactly as before.
>
> Where a program has no home-manager module, `home.file` still gets you declarative
> dotfiles:
>
> ```nix
> home.file.".config/foo/config.yaml".source = ./dotfiles/foo.yaml;
> ```

## Development shells

The feature that most justifies the whole exercise. Per project, in `flake.nix`:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          go_1_26
          golangci-lint
          postgresql_16
          kubectl
        ];

        shellHook = ''
          export DATABASE_URL="postgres://localhost/dev"
          echo "Go $(go version | cut -d' ' -f3)"
        '';
      };
    };
}
```

```bash
nix develop
```

Every contributor gets identical tool versions, pinned by the lockfile, with nothing
installed globally.

With [direnv](https://direnv.net/), it happens on `cd`:

```nix
programs.direnv = {
  enable = true;
  nix-direnv.enable = true;
};
```

```bash
echo "use flake" > .envrc && direnv allow
```

## Running binaries that expect a normal filesystem

The workstation pain point. There is no `/usr/lib`, so a downloaded binary fails
immediately.

**`nix-ld`** is the general answer — it provides the dynamic loader that
unpackaged binaries look for:

```nix
programs.nix-ld = {
  enable = true;
  libraries = with pkgs; [ stdenv.cc.cc.lib zlib openssl curl ];
};
```

This is what makes VS Code remote extensions, language-server binaries and
`pip install`ed wheels with native extensions work.

**Flatpak**, for desktop applications:

```nix
services.flatpak.enable = true;
xdg.portal.enable = true;
xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];   # GNOME and Plasma add their own
```

`xdg.portal.enable` alone does not build: NixOS asks for at least one portal in
`xdg.portal.extraPortals`. GNOME, Plasma and `programs.sway` already add one.

**`steam-run`**, an FHS environment on demand:

```bash
steam-run ./some-random-binary
```

**Distrobox or a container**, when you want a conventional distribution for one
purpose:

```nix
virtualisation.podman.enable = true;
environment.systemPackages = [ pkgs.distrobox ];
```

> [!warning] This is the friction that makes people give up
> Every one of these works, and every one is a decision you have to make each time
> something is not packaged. If your work involves a lot of vendor binaries, SDK
> installers or language toolchains that install their own runtimes, that tax is real
> and recurring.
>
> Enable `nix-ld` on day one — it removes the majority of the cases before you hit
> them.

## Where to go next

- [[linux/distributions/nixos/basics]] — rebuilding and generations
- nixos — a tiling desktop with Sway
- [[linux/distributions/nixos/testing]] — trying desktop changes in a VM
- [[linux/distributions/nixos/language]] — the syntax used above
- [[linux/distributions/nixos/disk-encryption]] — encrypting a laptop
- zsh — the shell being configured here

<!-- uplink -->
Part of [[linux/distributions/nixos/index|NixOS]].
