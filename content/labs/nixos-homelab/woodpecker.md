---
title: Woodpecker CI with sops-nix
description: CI for the lab flake on vfkit — Woodpecker server and a local-backend agent on one NixOS VM, secrets with sops-nix, a host key generated before the install, Gitea OAuth, and the bootstrap script that does it all
tags: [homelab, nixos, woodpecker, cicd, sops-nix, secrets, vfkit]
type: lab
status: draft
---

# Woodpecker CI with sops-nix

> [!note] Not tested locally
> The lab runs on a Mac with vfkit. The test harness cannot run it. On vfkit, the
> server and the agent start with decrypted secrets and reach Gitea. A real login and
> a real pipeline run are not re-tested.

Woodpecker should check every push to the lab repository and build every host before
anything is deployed. This is the CI from [[linux/distributions/nixos/gitops#CI]],
self-hosted. It is also the first host with secrets. See
[[labs/nixos-homelab/overview]].

## Design

| Choice | Why |
| --- | --- |
| Server and agent on one VM | A lab needs one agent; fewer machines to feed |
| **Local** backend | Steps are shell commands on the host, so they call `nix` directly. No container images, no Docker |
| Login through Gitea (OAuth) | No separate accounts |
| Secrets with **sops-nix** | Encrypted in Git, decrypted on the host at boot |
| Host key generated **before** the install | The secrets can be encrypted for a machine that does not exist yet |

## One script

After `lab/lab.sh up gitea`:

```bash
lab/ci-bootstrap.sh          # --regen replaces keys, OAuth app and secrets
```

It does, in order:

1. Creates the Gitea admin `lab_admin` with the Gitea CLI (email
   `lab_admin@lab.home.arpa`). The password goes to `secrets/gitea/admin-password`.
2. Registers `secrets/ssh/id_nix_lab.pub` as an SSH key of `lab_admin`, creates the
   empty repository `lab_admin/nix-lab`, and sets the git remote `gitea`
   (`gitea@192.168.64.10:lab_admin/nix-lab.git`) and `core.sshCommand`. Then
   `git push -u gitea main` works (the login and a test-branch push were checked).
3. Creates the Woodpecker OAuth2 app through the Gitea API. The redirect URI is
   `http://woodpecker.lab.home.arpa:8000/authorize`.
4. Creates a host SSH key and a sops age admin key (see below).
5. Writes `.sops.yaml` and the encrypted `secrets/woodpecker.yaml`, in a container,
   so the plain text never touches the Mac's disk. It checks that the host key can
   decrypt the file.
6. Installs `woodpecker` with the host key, and runs `lab.sh smoke woodpecker`.

Afterwards, add to `/etc/hosts` on the Mac. The login redirects between the two
names, so the browser must resolve both:

```text
192.168.64.10  gitea gitea.lab.home.arpa
192.168.64.11  woodpecker woodpecker.lab.home.arpa
```

Commit `.sops.yaml` and `secrets/woodpecker.yaml`.

## Secrets: who can decrypt what

Two age keys can read `secrets/woodpecker.yaml`:

| Key | Where | Role |
| --- | --- | --- |
| admin | `secrets/sops-age/keys.txt` | Edit secrets |
| woodpecker | Derived from the host's SSH key with `ssh-to-age` | Decrypt at boot |

The gitignored `secrets/` folder (or `LAB_SECRETS`) holds these files. Only
`secrets/woodpecker.yaml` (encrypted) is tracked:

| File | Lost means |
| --- | --- |
| `secrets/woodpecker/etc/ssh/ssh_host_ed25519_key` | A reinstall gets a new identity; re-encrypt for it |
| `secrets/sops-age/keys.txt` | No one can edit the secrets again |
| `secrets/gitea/admin-password` | The Gitea admin password is lost |

Back up `secrets/`: git does not save it.

```yaml
# .sops.yaml — public recipients only, safe to commit
keys:
  - &admin age1...
  - &woodpecker age1...
creation_rules:
  - path_regex: secrets/woodpecker\.yaml$
    key_groups:
      - age: [ *admin, *woodpecker ]
```

The decrypted file has this shape:

```yaml
server_env: |
  WOODPECKER_AGENT_SECRET=<random>
  WOODPECKER_GITEA_CLIENT=<oauth client id>
  WOODPECKER_GITEA_SECRET=<oauth client secret>
agent_env: |
  WOODPECKER_AGENT_SECRET=<same random>
```

## The host

```nix
{ config, pkgs, inputs, ... }:
let
  domain = "woodpecker.lab.home.arpa";
  giteaUrl = "http://gitea.lab.home.arpa:3000";
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/server.nix
    ../../modules/disk-vm.nix
    inputs.sops-nix.nixosModules.sops
  ];

  networking.hostName = "woodpecker";
  lab.server.address = "192.168.64.11";

  # Decrypted at activation with this host's SSH key, into /run/secrets (tmpfs).
  sops = {
    defaultSopsFile = ../../secrets/woodpecker.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets.server_env = { };
    secrets.agent_env = { };
  };

  services.woodpecker-server = {
    enable = true;
    environment = {
      WOODPECKER_HOST = "http://${domain}:8000";
      WOODPECKER_SERVER_ADDR = ":8000";
      WOODPECKER_GRPC_ADDR = "127.0.0.1:9000";
      WOODPECKER_OPEN = "false";
      WOODPECKER_ADMIN = "lab_admin";
      WOODPECKER_GITEA = "true";
      WOODPECKER_GITEA_URL = giteaUrl;
    };
    environmentFile = [ config.sops.secrets.server_env.path ];
  };

  services.woodpecker-agents.agents.local = {
    enable = true;
    environment = {
      WOODPECKER_SERVER = "127.0.0.1:9000";
      WOODPECKER_BACKEND = "local";
      WOODPECKER_MAX_WORKFLOWS = "1";
      # Keeps the agent ID across restarts; the default /etc path is read-only.
      WOODPECKER_AGENT_CONFIG_FILE = "/var/lib/woodpecker-agent-local/agent.conf";
    };
    environmentFile = [ config.sops.secrets.agent_env.path ];
    path = with pkgs; [ git git-lfs woodpecker-plugin-git bash coreutils nix ];
  };

  systemd.services.woodpecker-agent-local.serviceConfig.StateDirectory =
    "woodpecker-agent-local";

  networking.firewall.allowedTCPPorts = [ 8000 ];
  system.stateVersion = "26.05";
}
```

`environmentFile` is read by systemd as root before the service starts, so the
`0400 root` files in `/run/secrets` work even though both services run as
throwaway `DynamicUser` accounts.

sops-nix checks at **build time** that the file exists and contains every
declared key. A missing secret fails `nix build`, not the boot.

## Install with the pre-generated key

`lab.sh install` does this when the folder `secrets/<host>` exists. It passes
`--extra-files` to nixos-anywhere:

```text
--extra-files secrets/woodpecker --chown /etc/ssh 0:0
```

`--extra-files` copies the directory tree onto the new root, so the key lands in
`/etc/ssh/`. `--chown` gives it to root; otherwise it would keep the user ID it had
on the Mac. The proof it worked:

```bash
lab/lab.sh ssh woodpecker ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf secrets/woodpecker/etc/ssh/ssh_host_ed25519_key.pub   # same fingerprint
lab/lab.sh ssh woodpecker ls -l /run/secrets/                              # agent_env, server_env
```

## Gitea side

- The **OAuth2 application**, the SSH key and the repository are created by the script
  (see above). No manual web-UI steps.
- **Webhooks to private addresses** are blocked by Gitea by default. Without this,
  enabling a repository in Woodpecker works but pushes never trigger anything. It is
  set in `hosts/gitea/default.nix`:

  ```nix
  services.gitea.settings.security.ALLOWED_HOST_LIST = "private";
  ```

## The pipeline

> [!note] Not re-tested on vfkit
> No pipeline was run on vfkit. The file below is the design.

```yaml
# .woodpecker.yaml
when:
  - event: [push, pull_request, manual]

steps:
  - name: check
    image: bash                 # with the local backend: the shell to use
    commands:
      - export HOME="$CI_WORKSPACE/.ci-home"
      - nix flake check

  - name: build
    image: bash
    commands:
      - export HOME="$CI_WORKSPACE/.ci-home"
      - |
        for host in gitea woodpecker k8s-01 k8s-02 k8s-03; do
          nix build ".#nixosConfigurations.$host.config.system.build.toplevel" --no-link
        done
```

The agent runs in a tight systemd sandbox: read-only system, private `/tmp`, no
home directory. `nix` should still work because the **daemon** does the builds; the
client only needs a writable `HOME` for its fetch cache.

## What went wrong

The hardware clock of a vfkit VM holds UTC, the NixOS default. No clock setting is needed.

### The agent forgets its identity

```text
could not persist agent config at '/etc/woodpecker/agent.conf'
```

`/etc` is read-only in the sandbox, so each restart registered a new agent.
A `StateDirectory` and `WOODPECKER_AGENT_CONFIG_FILE` fix it.

### Smaller ones

- `sops secrets/woodpecker.yaml` failed with `no such file or directory`: Git does
  not carry empty folders, so create `secrets/` first. The script does.

## Next

[[labs/nixos-homelab/kubernetes]] — the cluster.

<!-- uplink -->
Part of [[labs/nixos-homelab/index|NixOS home lab]].
