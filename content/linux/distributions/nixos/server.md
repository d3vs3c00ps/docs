---
title: NixOS as a server
description: Service modules, secrets that must not go in the store, deployment tooling, and building a system image
tags: [linux, nixos, nix, servers, deployment]
type: howto
status: complete
---

# NixOS as a server

On a server, NixOS replaces both the distribution and the configuration management
tool. The configuration *is* the desired state, and there is no drift to reconcile
because nothing is modified in place.

## Services

Most of the distribution's value is its module library — roughly 20,000 typed options
covering the services you would otherwise hand-configure.

```nix
{
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;

    virtualHosts."example.com" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;
      };
    };
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "your.name@example.com";
  };

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;
    ensureDatabases = [ "myapp" ];
    ensureUsers = [{
      name = "myapp";
      ensureDBOwnership = true;
    }];
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
```

That produces nginx with sane TLS settings, certificates issued and renewed
automatically, PostgreSQL with a database and role, and a firewall — with no
configuration files written by hand. Compare nginx and
pki-and-x509 for what is being generated.

## Hardening

```nix
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      KbdInteractiveAuthentication = false;
    };
  };

  users.users.alice = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... your.name@example.com" ];
  };

  security.sudo.wheelNeedsPassword = true;

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 ];
  };

  services.fail2ban.enable = true;

  system.autoUpgrade = {
    enable = true;
    flake = "github:myorg/nixos-config";
    dates = "04:00";
    allowReboot = false;
  };
}
```

See [[linux/distributions/nixos/hardening]] for the fuller treatment.

## Custom services

For software with no module, a systemd unit written declaratively:

```nix
{
  users.users.myapp = { isSystemUser = true; group = "myapp"; };
  users.groups.myapp = {};

  systemd.services.myapp = {
    description = "My application";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "postgresql.service" ];
    requires = [ "postgresql.service" ];

    serviceConfig = {
      ExecStart = "${pkgs.myapp}/bin/myapp --config ${configFile}";
      User = "myapp";
      Restart = "on-failure";
      RestartSec = "5s";

      # systemd sandboxing — cheap and effective
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      StateDirectory = "myapp";
    };
  };
}
```

Everything from systemd applies — NixOS just gives it a typed,
version-controlled front end.

## Secrets

The hard problem, and the one most likely to be got wrong.

> [!danger] The Nix store is world-readable, always
> Anything interpolated into a configuration ends up in `/nix/store`, where every
> file is readable by every user on the machine. This includes a password written
> into a config file through `pkgs.writeText`, or a token in a systemd
> `Environment=`.
>
> ```nix
> # NEVER do this
> services.myapp.settings.password = "hunter2";
> environment.etc."myapp.conf".text = "token=${secret}";
> ```
>
> It is also in the Git history of your configuration repository, and on every machine
> that ever built it.

Correct approaches:

**`systemd` credentials or an out-of-band file**, referenced by path:

```nix
systemd.services.myapp.serviceConfig = {
  EnvironmentFile = "/run/secrets/myapp.env";     # deployed separately, mode 600
  LoadCredential = "db-password:/run/secrets/db-password";
};
```

**[sops-nix](https://github.com/Mic92/sops-nix)** — encrypted secrets in Git,
decrypted at activation with an age or GPG key held by the host:

```nix
sops = {
  defaultSopsFile = ./secrets/web-01.yaml;
  age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  secrets."db/password" = {
    owner = "myapp";
    mode = "0400";
  };
};

systemd.services.myapp.serviceConfig.LoadCredential =
  "db-password:${config.sops.secrets."db/password".path}";
```

> [!warning] Correction
> The original example passed the secret as `EnvironmentFile`. That file must hold
> `NAME=value` lines; a bare password is not one, so systemd sets no variable. Use
> `LoadCredential`, as above, and read the file from `$CREDENTIALS_DIRECTORY`. For
> `EnvironmentFile`, store the secret as `DB_PASSWORD=...` in sops.

Using the host's SSH key as the decryption key is elegant — a machine can decrypt
exactly the secrets encrypted to it, with nothing extra to distribute.

**[agenix](https://github.com/ryantm/agenix)** is the lighter-weight alternative with
the same model.

## Deployment

| Tool | Notes |
| --- | --- |
| `nixos-rebuild --target-host` | Built in, no dependencies. Fine for a handful of machines |
| [deploy-rs](https://github.com/serokell/deploy-rs) | Rollback on failed health check — the safety feature that matters |
| [colmena](https://github.com/zhaofengli/colmena) | Parallel, good for many machines |
| [nixops](https://github.com/NixOS/nixops) | Also provisions infrastructure. Has had a turbulent history |

```bash
nixos-rebuild switch --flake .#web-01 --target-host root@web-01
```

With only `--target-host`, the build runs on your machine and the closure is copied
to the server, so the server needs no compiler and no build resources.

> [!warning] Correction
> The original command also had `--build-host localhost`. In the current
> `nixos-rebuild`, any `--build-host` is reached over SSH, even `localhost`. Leave it
> out to build locally. See [[linux/distributions/nixos/basics]].

> [!important] `deploy-rs` gives you the network equivalent of `nixos-rebuild test`
> It activates the new configuration, runs a health check, and **automatically rolls
> back** if the check fails or the connection drops. Deploying an SSH or firewall
> change to a remote machine without that is how people lock themselves out — and
> `nixos-rebuild` alone has no such protection over the network.

Managing a fleet from one flake:

```nix
{
  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations = {
      web-01 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./hosts/web-01 ./modules/common.nix ];
      };
      db-01 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./hosts/db-01 ./modules/common.nix ];
      };
    };
  };
}
```

Shared configuration goes in `modules/common.nix`, and per-host differences stay
small. This is the structure that makes a fleet manageable.

## Building images

```bash
nixos-rebuild build-image --image-variant qemu-efi --flake .#web-01   # qcow2, for KVM
nixos-rebuild build-image --image-variant amazon   --flake .#web-01
nixos-rebuild build-image --image-variant iso      --flake .#web-01
```

That qcow2 drops straight into basics as a golden image, built
from the same configuration as everything else. The full list of variants is in
[[linux/distributions/nixos/testing#Building images]].

> [!note] Correction
> An earlier version used the separate `nixos-generators` tool
> (`nixos-generate -f qcow2`). It was merged into nixpkgs in 25.05 as
> `nixos-rebuild build-image` and is now archived. The variant names differ: there is
> no `qcow2` (use `qemu-efi` or `qemu`) and no `docker` — build OCI images with
> `dockerTools`, below.

To install a new server from the flake, rather than from an image, see
[[linux/distributions/nixos/automated-install]].

## Containers

NixOS can build OCI images without a Dockerfile, and the result is minimal by
construction — the closure contains exactly what is needed and nothing else:

```nix
pkgs.dockerTools.buildLayeredImage {
  name = "myapp";
  tag = "1.0";
  contents = [ pkgs.myapp pkgs.cacert ];
  config = {
    Cmd = [ "/bin/myapp" ];
    ExposedPorts = { "8080/tcp" = {}; };
  };
}
```

This is a third option alongside hand-written
Dockerfiles and buildpacks, with the strongest
reproducibility guarantee of the three.

It also runs system containers natively:

```nix
containers.mycontainer = {
  autoStart = true;
  privateNetwork = true;
  hostAddress = "192.168.100.1";
  localAddress = "192.168.100.2";
  config = { config, pkgs, ... }: {
    services.nginx.enable = true;
    system.stateVersion = "26.05";
  };
};
```

Those are `systemd-nspawn` containers, each a full NixOS system — closer to an LXC
container than to Docker.

## Where to go next

- [[linux/distributions/nixos/hardening]] — security configuration
- [[linux/distributions/nixos/gitops]] — CI and automated deployment
- [[linux/distributions/nixos/automated-install]] — installing a new server from the flake
- [[linux/distributions/nixos/testing]] — VM tests for your modules
- [[linux/distributions/nixos/disk-encryption]] — encrypted root
- systemd — the units being generated

<!-- uplink -->
Part of [[linux/distributions/nixos/index|NixOS]].
