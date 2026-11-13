---
title: NixOS basics
description: Installing, the rebuild commands and what each does, channels versus flakes, garbage collection, and finding options and packages
tags: [linux, nixos, nix, installation]
type: howto
status: complete
---

# NixOS basics

## Installing

Boot the ISO, partition, and generate a configuration:

```bash
# Partition and format as usual — see linux/storage/partitioning
sudo mount /dev/disk/by-label/nixos /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/disk/by-label/boot /mnt/boot
sudo swapon /dev/disk/by-label/swap

sudo nixos-generate-config --root /mnt
sudo nano /mnt/etc/nixos/configuration.nix
sudo nixos-install
sudo reboot
```

`nixos-generate-config` writes two files:

| File | Purpose |
| --- | --- |
| `hardware-configuration.nix` | Detected hardware, filesystems, kernel modules. **Generated — do not edit** |
| `configuration.nix` | Yours |

## The rebuild commands

```bash
sudo nixos-rebuild switch      # build, activate, make it the boot default
sudo nixos-rebuild boot        # build, set as boot default, do NOT activate now
sudo nixos-rebuild test        # build and activate, but do NOT add to the boot menu
sudo nixos-rebuild build       # just build; produces ./result
sudo nixos-rebuild dry-build   # what would be built or downloaded
sudo nixos-rebuild switch --rollback
```

> [!tip] `test` is the safe way to change networking or SSH remotely
> `nixos-rebuild test` activates the configuration without making it the boot
> default. Lock yourself out with a firewall or SSH change, and a power cycle returns
> you to the previous working system.
>
> Once you have confirmed you can still log in, run `switch` to make it permanent.
> This is the NixOS equivalent of a commit-confirmed on a router, and it costs
> nothing.

Deploying to a remote host:

```bash
nixos-rebuild switch --target-host root@web-01 --flake .#web-01
nixos-rebuild switch --target-host alice@web-01 --sudo --flake .#web-01
```

The build runs on your machine, then the closure is copied to `web-01` over SSH and
activated there. `--sudo` runs the activation with `sudo` when you log in as a normal
user. `--build-host` moves the build to another machine.

> [!warning] Correction
> An earlier version added `--build-host localhost`. That is not "build here": in
> the current `nixos-rebuild`, any `--build-host` is reached over SSH, so it opened an
> SSH session to your own machine. Leave it out to build locally.

## Generations

```bash
nixos-rebuild list-generations
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
sudo nixos-rebuild switch --rollback
```

They appear in the boot menu. Limit how many with:

```nix
boot.loader.systemd-boot.configurationLimit = 20;
```

## Channels or flakes

Both answer one question: **which version of `nixpkgs` does my configuration build
against?** The difference is *where that answer is stored*. Material online rarely
says which model it assumes.

| | Channels | Flakes |
| --- | --- | --- |
| Where the `nixpkgs` version lives | In root's state, outside your config (`/nix/var/nix/profiles/per-user/root/channels`), found through `<nixpkgs>` and `NIX_PATH` | In your repository: `flake.nix` names the input, `flake.lock` records its exact commit and hash |
| Tracked in Git | No — the repository holds only half of the truth | Yes — the repository is the whole truth |
| When it changes | Whenever someone runs `nix-channel --update`, silently | Only when you run `nix flake update` and commit the lockfile |
| Same config on two machines | Can produce two different systems | Produces the same system |
| Undoing an update | Roll back a generation | Roll back a generation, or `git revert` the lockfile change |
| DevOps equivalent | `FROM ubuntu:latest`, an unpinned `apt install` | `go.mod` + `go.sum`, `.terraform.lock.hcl` |

### Channels — the traditional way

A channel is a named URL that points to a recent build of `nixpkgs`. `nix-channel`
downloads it and keeps it in root's profile.

```bash
sudo nix-channel --list
sudo nix-channel --add https://nixos.org/channels/nixos-26.05 nixos
sudo nix-channel --update
sudo nixos-rebuild switch --upgrade
```

`configuration.nix` then refers to `<nixpkgs>` without saying which version it means.
Run `nix-channel --update` and the same file builds a different system. Nothing in
your repository records that it happened.

### Flakes — the de facto standard

A flake is a directory with a `flake.nix`. It declares its **inputs** (where
`nixpkgs` and any other dependency come from) and its **outputs** (what it builds).
The first build writes `flake.lock`, which pins every input to an exact commit.

### From a fresh install to a flake

A fresh install uses **channels**, and flakes are **off**. The installer writes only
`configuration.nix` and `hardware-configuration.nix` — there is no `flake.nix`. So on
a new machine both of these fail:

```text
$ nix search nixpkgs vim
error: experimental Nix feature 'nix-command' is disabled

$ sudo nixos-rebuild switch --flake /etc/nixos
error: could not find a flake.nix file
```

Turning the feature on and creating the flake are two separate steps.

**1. Turn flakes on**, with the channel setup you still have. Add these lines
*inside* the `{ ... }` block of `/etc/nixos/configuration.nix` — they are Nix code,
not shell commands:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
environment.systemPackages = with pkgs; [ git vim ];
```

If the file already has an `environment.systemPackages` line, add to that list
instead: a second definition in the same file is an error. Then rebuild, without
`--flake`:

```bash
sudo nixos-rebuild switch
```

**2. Find three values** for the flake:

```bash
nixos-version     # release: 26.05.xxxx → use "nixos-26.05"
hostname          # the output name nixos-rebuild looks for
uname -m          # x86_64 → "x86_64-linux", aarch64 → "aarch64-linux"
```

**3. Create `/etc/nixos/flake.nix`**, next to `configuration.nix`:

```nix
{
  description = "System configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";      # your release
  };

  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {  # "nixos" = your hostname
      system = "x86_64-linux";                             # or "aarch64-linux"
      modules = [ ./configuration.nix ];
    };
  };
}
```

`configuration.nix` already imports `hardware-configuration.nix`, so nothing else is
needed.

**4. Rebuild from the flake:**

```bash
sudo nixos-rebuild switch --flake /etc/nixos     # picks the output named after the hostname
sudo nixos-rebuild switch --flake /etc/nixos#nixos   # the same, with the name explicit
```

The first run downloads `nixpkgs` and writes `flake.lock`. While the flake is in
`/etc/nixos`, a plain `nixos-rebuild switch` uses it too: `nixos-rebuild` (and
`nixos-option`) use `/etc/nixos/flake.nix` when it exists. Once the flake lives
elsewhere, **always** pass `--flake`: without it, and with no `/etc/nixos/flake.nix`,
`nixos-rebuild` silently builds from the old channel.

> [!warning] Correction
> An earlier version said a plain `nixos-rebuild switch` always builds from the
> channel. It does not when `/etc/nixos/flake.nix` exists; `--no-flake` forces the
> channel.

> [!warning] The output name must match the hostname
> Without `#name`, `nixos-rebuild` looks for `nixosConfigurations.<hostname>`. The
> installer's default hostname is `nixos`. If you later set `networking.hostName`,
> rename the output too, or always pass `#name` explicitly.

> [!note] ARM machines: `aarch64-linux`
> On ARM — a NixOS VM on an Apple Silicon Mac, a Raspberry Pi, an ARM cloud instance
> — the system is `aarch64-linux`. With `x86_64-linux` the build tries to produce an
> Intel system and fails. Two more things change:
>
> - Recent installers write `nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";`
>   into `hardware-configuration.nix` (check with
>   `grep hostPlatform /etc/nixos/hardware-configuration.nix`). When it is there, you
>   can drop the `system = ...` line from `flake.nix`, and the same flake works on
>   either architecture.
> - Not every package is built for ARM. Unfree x86-only software (some vendor
>   binaries, Steam, some proprietary drivers) is missing. search.nixos.org shows the
>   supported **Platforms** of each package.
>
> Examples elsewhere in this vault use `x86_64-linux`; replace it on ARM.

Later, move the flake out of `/etc/nixos` into a Git repository in your home
directory (`~/nixos-config`), and build with `--flake ~/nixos-config`. That is where
[[linux/distributions/nixos/testing|testing]] and [[linux/distributions/nixos/gitops|CI]]
start. Once it is in Git, the rule below about tracked files applies.

### Daily flake commands

`nix flake` commands act on the flake in the **current directory**, unless you pass
`--flake <path>`. Files in `/etc/nixos` belong to root, so commands that write
`flake.lock` there need `sudo`.

```bash
sudo nix flake update --flake /etc/nixos           # update every input
sudo nix flake update --flake /etc/nixos nixpkgs   # update one input
sudo nixos-rebuild switch --flake /etc/nixos       # apply it — update alone changes nothing

# in a Git repository you own, e.g. ~/nixos-config
cd ~/nixos-config
nix flake update
sudo nixos-rebuild switch --flake .
git commit flake.lock -m "chore: update nixpkgs"
```

The `nixos-26.05` in the URL is a **branch** — it says which release to follow. The
lockfile says which **commit** of that branch you are on. Moving to the next release
means editing the URL; getting security fixes within a release means
`nix flake update`.

Flakes also fix the **shape** of the outputs: `nixosConfigurations.<host>`,
`devShells`, `packages`, `checks`. Every tool reads the same names —
`nixos-rebuild --flake`, `nix develop`, `nix flake check`, deploy-rs, nixos-anywhere.
With channels, each repository invents its own layout.

> [!note] Correction
> An earlier version of this note used `nix flake lock --update-input nixpkgs`. That
> form is deprecated; since Nix 2.19 it is `nix flake update nixpkgs`.

> [!warning] A flake only sees files tracked by Git
> When the flake is in a Git repository, Nix copies only the files Git knows about.
> Create `hosts/web-02.nix`, forget `git add`, and the build fails with an error
> saying the file does not exist. The file does not need to be committed — staged is
> enough.

> [!warning] Flakes are "experimental" and are what everyone uses
> They have been marked experimental for years, require an opt-in flag, and are
> also the default assumed by most current documentation and the only sane way to
> get reproducible builds.
>
> The practical consequence is that any answer you find may assume one model or the
> other, and the two are not interchangeable — `nix-shell` and `nix develop`,
> `nix-env` and `nix profile`, `configuration.nix` alone and a flake. When something
> does not work as documented, check which model it assumed. **Use flakes**, and read
> older material with that in mind.

## Finding packages and options

```bash
nix search nixpkgs firefox
```

`nix search` is a flake-style command: it needs flakes turned on (step 1 above). On
a machine without them, use
`nix --extra-experimental-features 'nix-command flakes' search nixpkgs firefox`.

The web search at [search.nixos.org](https://search.nixos.org) is better, and covers
both packages and the more than 20,000 NixOS options.

```bash
man configuration.nix
nixos-option services.openssh.enable
nixos-option -r services.openssh.settings
```

`nixos-option` reads `/etc/nixos/flake.nix` when it exists, like `nixos-rebuild`.

> [!warning] Correction
> An earlier version showed `nixos-option -r services.nginx`. On NixOS 26.05 it
> stops with `Renaming error: option services.nginx.proxyCachePath."".enable does
> not exist`: `-r` reads every option under the path, including old renamed ones.
> Use `-r` on a smaller part, or look the option up on search.nixos.org.

> [!important] Search options before writing anything by hand
> The commonest beginner mistake is writing `environment.etc."foo.conf".text = ...`
> for a service that already has a full module. Nearly everything in the distribution
> has one, with typed options, sensible defaults, and correct systemd units.
> `services.nginx.virtualHosts` exists; hand-writing an nginx config into `/etc` gives
> up most of what NixOS offers.

## Temporary shells

The feature worth using even on another distribution:

```bash
nix-shell -p python3 jq          # channels
nix shell nixpkgs#python3        # flakes
```

Tools are available in that shell and gone when it exits — nothing installed, nothing
to remove.

Per-project, with `flake.nix`:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = with pkgs; [ go_1_26 golangci-lint ];
      };
    };
}
```

```bash
nix develop
```

Everyone on the project gets byte-identical tool versions, pinned in the lockfile.
See tooling for what that replaces.

## Garbage collection

Old generations and their dependencies are kept until you say otherwise, and `/nix`
grows steadily.

```bash
nix-store --gc                                # unreferenced paths
sudo nix-collect-garbage -d                   # and delete old generations
sudo nix-collect-garbage --delete-older-than 30d
du -sh /nix/store
```

Automatically:

```nix
nix.gc = {
  automatic = true;
  dates = "weekly";
  options = "--delete-older-than 30d";
};

nix.settings.auto-optimise-store = true;      # hardlink identical files
```

> [!warning] `nix-collect-garbage -d` deletes your rollback targets
> It removes every generation but the current one, so the boot menu is left with a
> single entry. On a machine you may need to roll back, prefer
> `--delete-older-than 30d`, which keeps a usable window.

## Where to go next

- [[linux/distributions/nixos/language]] — the Nix language
- [[linux/distributions/nixos/server]] — services and deployment
- [[linux/distributions/nixos/workstation]] — desktop and home-manager
- [[linux/distributions/nixos/derivations]] — what a build actually is
- [[linux/distributions/nixos/testing]] — VMs, VM tests and images before you switch
- [[linux/distributions/nixos/automated-install]] — installing servers with no manual steps

<!-- uplink -->
Part of [[linux/distributions/nixos/index|NixOS]].
