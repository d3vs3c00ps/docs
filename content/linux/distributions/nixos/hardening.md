---
title: NixOS hardening
description: What the declarative model gives you for free, systemd sandboxing, kernel and network hardening, AppArmor, auditing, and where the store's readability bites
tags: [linux, nixos, security, hardening, systemd]
type: reference
status: complete
---

# NixOS hardening

Some hardening is easier on NixOS and some is harder. Both are worth being explicit
about.

## What you get for free

| Property | Why |
| --- | --- |
| **No configuration drift** | Nothing is modified in place; the file is the system |
| **Auditable history** | Every change is a commit, and generations are on disk |
| **Atomic rollback** | A bad security change is undone by a reboot |
| **Minimal by default** | Only what you declare is installed — no recommended packages |
| **Reproducible rebuild** | A compromised machine is replaced with a known-identical one |

That last point is the underrated one. Incident response on a conventional server
means deciding what was tampered with. On NixOS, `nixos-rebuild` from a known-good
commit produces a system whose every binary is bit-identical to the reference.

## What is harder

> [!danger] `/nix/store` is world-readable, and this is a permanent constraint
> Every file in the store is readable by every user on the machine. Anything
> interpolated into a configuration — a password in a generated config file, a token
> in a systemd `Environment=` — is exposed to any local user, and is also in your
> configuration repository's history.
>
> ```nix
> # Both of these leak
> services.myapp.settings.password = "hunter2";
> systemd.services.myapp.serviceConfig.Environment = "TOKEN=${token}";
> ```
>
> Use `sops-nix` or `agenix`, or deploy secrets out of band and reference them by
> path. See [[linux/distributions/nixos/server]].

Two other frictions: hardening guides written for a conventional distribution assume
paths and files that do not exist here, and CIS-style tooling checks for
`/etc/ssh/sshd_config` permissions on a file that is a store symlink.

## SSH and access

```nix
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      KbdInteractiveAuthentication = false;
      X11Forwarding = false;
      MaxAuthTries = 3;
      AllowUsers = [ "alice" ];
    };
    extraConfig = ''
      ClientAliveInterval 300
      ClientAliveCountMax 2
    '';
  };

  users.mutableUsers = false;         # users only exist if declared

  users.users.alice = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... your.name@example.com" ];
  };

  security.sudo = {
    wheelNeedsPassword = true;
    execWheelOnly = true;
  };
}
```

> [!important] `users.mutableUsers = false` is the setting worth understanding
> With it, the user list is exactly what the configuration says. `useradd` and
> `passwd` still run, but every activation undoes them: the next rebuild or reboot
> removes an account added by hand and puts declared passwords back. That is a strong
> control against persistence. It also means you must declare a hashed password or a
> key for every account you need, including in the installer.
>
> Set `users.users.alice.hashedPasswordFile` rather than `hashedPassword`, to keep the
> hash out of the store.

> [!warning] Correction
> An earlier version said that `useradd` and `passwd` "stop working". They do not:
> both succeed, and the change lasts until the next activation.

## systemd sandboxing

The highest-value per-service hardening, and NixOS makes it easy to apply
consistently:

```nix
systemd.services.myapp.serviceConfig = {
  # Filesystem
  ProtectSystem = "strict";
  ProtectHome = true;
  PrivateTmp = true;
  ReadWritePaths = [ "/var/lib/myapp" ];
  StateDirectory = "myapp";

  # Privileges
  NoNewPrivileges = true;
  CapabilityBoundingSet = [ "" ];
  AmbientCapabilities = [ "" ];
  PrivateUsers = true;

  # Kernel
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectKernelLogs = true;
  ProtectControlGroups = true;
  ProtectClock = true;
  ProtectProc = "invisible";

  # Syscalls and address families
  SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
  SystemCallArchitectures = "native";
  RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
  RestrictNamespaces = true;
  RestrictRealtime = true;
  RestrictSUIDSGID = true;
  LockPersonality = true;
  MemoryDenyWriteExecute = true;
};
```

```bash
systemd-analyze security
systemd-analyze security myapp.service
```

`systemd-analyze security` scores every unit from 0 to 10 and lists exactly which
directives would improve it. It is the most actionable hardening tool on a modern
Linux system, and it works the same here as anywhere — see systemd.

## Kernel and network

```nix
{
  boot.kernel.sysctl = {
    "kernel.dmesg_restrict" = 1;
    "kernel.kptr_restrict" = 2;
    "kernel.yama.ptrace_scope" = 1;
    "kernel.unprivileged_bpf_disabled" = 1;
    "net.core.bpf_jit_harden" = 2;

    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv6.conf.all.accept_ra" = 0;
  };

  boot.blacklistedKernelModules = [
    "dccp" "sctp" "rds" "tipc"          # rarely used, historically buggy
    "cramfs" "freevxfs" "jffs2" "hfs" "hfsplus" "udf"
  ];

  security.protectKernelImage = true;
  security.lockKernelModules = true;     # no module loading after boot
  security.forcePageTableIsolation = true;
}
```

> [!warning] Correction: `linuxPackages_hardened` is gone
> This note used to set `boot.kernelPackages = pkgs.linuxPackages_hardened`. NixOS 26.05
> removed the hardened kernel packages "due to lack of maintenance", and the line now
> stops the build with that error. The sysctls and module settings above do most of
> what is still practical. Stay on the default kernel, which gets security fixes first.

> [!warning] `lockKernelModules` has a real cost
> `security.lockKernelModules = true` blocks all module loading after boot. That breaks
> anything that loads modules on demand, including some filesystems, VPN clients and
> `virtualbox`. It is right for a server with a fixed role and wrong for a workstation.
> Test it before you roll it out to a fleet.

## AppArmor

```nix
{
  security.apparmor = {
    enable = true;
    killUnconfinedConfinables = true;
  };
}
```

SELinux support exists but is not well maintained on NixOS; AppArmor is the
practical choice here. On other distributions, see selinux.

## Auditing

```nix
{
  security.auditd.enable = true;
  security.audit = {
    enable = true;
    rules = [
      "-w /etc/shadow -p wa -k identity"
      "-w /nix/var/nix/profiles/system -p wa -k system_generation"
      "-a always,exit -F arch=b64 -S execve -F euid=0 -k root_commands"
    ];
  };
}
```

The middle rule is NixOS-specific and useful: it records every generation switch, so
the audit log shows when the system's definition changed. See auditd.

## Firewall

```nix
{
  networking.nftables.enable = true;    # nftables backend

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 ];
    allowPing = false;
    logRefusedConnections = true;

    # nftables syntax: port 8080 only from 10.0.0.0/8
    extraInputRules = ''
      ip saddr 10.0.0.0/8 tcp dport 8080 accept
    '';
  };
}
```

> [!warning] Correction: `extraCommands` is for the iptables backend only
> An earlier version of this block used `extraCommands` with an `iptables` rule next to
> `networking.nftables.enable = true`. NixOS refuses that combination: "extraCommands
> is incompatible with the nftables based firewall". With nftables, use
> `extraInputRules` (and `extraForwardRules`), in nftables syntax. `extraCommands`
> works only with the iptables backend (`networking.nftables.enable = false`).

See nftables.

## Automatic updates

```nix
{
  system.autoUpgrade = {
    enable = true;
    flake = "github:myorg/nixos-config";   # builds the committed flake.lock
    dates = "04:00";
    randomizedDelaySec = "30min";
    allowReboot = false;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
}
```

> [!note] Correction
> An earlier version passed `flags = [ "--update-input" "nixpkgs" "--no-write-lock-file" ]`,
> so each machine updated `nixpkgs` on its own and ran a lockfile nobody had built
> or reviewed. `--update-input` is also deprecated since Nix 2.19. Update
> `flake.lock` in CI instead, where every host is built first — see
> [[linux/distributions/nixos/gitops#Updating dependencies]].

`allowReboot = false` means kernel updates are staged but not activated until you
reboot deliberately. Setting it to `true` with a `rebootWindow` is reasonable for a
machine behind a load balancer, and unwise otherwise.

## Checking your work

```bash
systemd-analyze security
nix-shell -p vulnix --run "vulnix --system"
sysctl -a | grep -E 'kptr_restrict|dmesg_restrict|ptrace_scope'
```

[`vulnix`](https://github.com/nix-community/vulnix) is the NixOS-specific one — it
scans the system closure against NVD, and because the closure is exact, it produces
far less noise than a scanner guessing at installed versions. That is the same
advantage described in sbom, available without generating
anything.

## Where to go next

- [[linux/distributions/nixos/disk-encryption]] — encryption at rest
- [[linux/distributions/nixos/server]] — secrets handling in detail
- systemd — the sandboxing directives above
- auditd — reading what the audit rules produce

<!-- uplink -->
Part of [[linux/distributions/nixos/index|NixOS]].
