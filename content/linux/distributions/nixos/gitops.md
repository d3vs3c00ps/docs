---
title: NixOS with GitOps
description: A configuration repository as the source of truth — repository layout, CI that builds every host, staged rollout, and binary caches
tags: [linux, nixos, gitops, cicd, deployment]
type: howto
status: complete
---

# NixOS with GitOps

NixOS is unusually well suited to a Git-driven workflow, because the configuration
already *is* the system. There is no agent reconciling drift — a machine either has
been rebuilt from a commit or it has not.

## Repository layout

```text
nixos-config/
├── flake.nix
├── flake.lock
├── hosts/
│   ├── web-01/
│   │   ├── default.nix
│   │   └── hardware-configuration.nix
│   ├── web-02/
│   └── db-01/
├── modules/
│   ├── common.nix          # applied everywhere
│   ├── hardening.nix
│   ├── monitoring.nix
│   └── services/
│       └── myapp.nix
├── overlays/
├── secrets/                # sops-encrypted
│   ├── web-01.yaml
│   └── .sops.yaml
└── home/
    └── alice.nix
```

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix.url = "github:Mic92/sops-nix";
    deploy-rs.url = "github:serokell/deploy-rs";
  };

  outputs = { self, nixpkgs, sops-nix, deploy-rs, ... }@inputs:
    let
      mkHost = name: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/${name}
          ./modules/common.nix
          ./modules/hardening.nix
          sops-nix.nixosModules.sops
        ];
      };
    in {
      nixosConfigurations = {
        web-01 = mkHost "web-01";
        web-02 = mkHost "web-02";
        db-01  = mkHost "db-01";
      };

      deploy.nodes = {
        web-01 = {
          hostname = "web-01.example.com";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos
                     self.nixosConfigurations.web-01;
          };
        };
      };
    };
}
```

The `mkHost` helper is worth the small abstraction — it guarantees every host gets the
common and hardening modules, which is exactly the kind of thing that is forgotten
when each host is defined by hand.

## CI

The valuable property: **every host is built in CI before anything is deployed**. An
evaluation error, a type error, or a package that no longer builds is caught on the
pull request rather than on the machine.

```yaml
name: build
on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        host: [web-01, web-02, db-01]
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes
      - uses: cachix/cachix-action@v15
        with:
          name: myorg
          authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}
      - run: nix build .#nixosConfigurations.${{ matrix.host }}.config.system.build.toplevel
```

> [!important] Building in CI is a stronger check than a plan or a dry run
> Configuration management tools can only tell you what they intend to change. Nix
> builds the **entire resulting system** — every package, every generated config file,
> every unit — and fails if any part of it cannot be produced.
>
> A pull request that builds is a pull request that will apply. That is a materially
> different guarantee from `ansible --check`.

Also worth adding to CI:

```yaml
      - run: nix flake check
      - run: nix run nixpkgs#nixfmt -- --check $(git ls-files '*.nix')
      - run: nix run nixpkgs#statix -- check
      - run: nix run nixpkgs#deadnix -- --fail
      - run: nix run nixpkgs#vulnix -- --closure ./result
```

`nixfmt` is the official Nix formatter, `statix` finds antipatterns, `deadnix` finds
unused bindings, and `vulnix` scans the built closure for known vulnerabilities — a
security gate on the exact system that would be deployed.

> [!warning] Correction
> The original list ran `vulnix --system ./result`. `--system` scans the machine
> that runs the command, here the CI runner, not the built host. `--closure` scans
> everything `./result` depends on. It also used `nixpkgs-fmt`, which still works
> but is replaced by `nixfmt`.

## A binary cache

Without one, every machine compiles everything itself, which is slow and wasteful.
With one, CI builds once and every host downloads.

```nix
nix.settings = {
  substituters = [ "https://cache.nixos.org" "https://myorg.cachix.org" ];
  trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "myorg.cachix.org-1:AAAA..."
  ];
};
```

Self-hosted alternatives are [attic](https://github.com/zhaofengli/attic) and
`nix-serve`. This is close to essential for a fleet — the first `nixos-rebuild` after
a `nixpkgs` bump can otherwise be an hour of compilation on every machine.

## Deployment

```bash
nix run github:serokell/deploy-rs -- .#web-01
nix run github:serokell/deploy-rs -- .            # everything
```

`deploy-rs` activates, health-checks, and **rolls back automatically** if the check
fails or the connection drops.

> [!danger] Automated deployment without automatic rollback will lock you out
> Sooner or later a change breaks SSH, the firewall, or networking — and with a
> pipeline applying it to every host in parallel, it breaks all of them at once.
>
> `deploy-rs` provides `magicRollback`, which requires the deployer to confirm
> connectivity after activation and reverts otherwise. It is on by default: keep
> it on, set the timeout, and stage rollouts so one host proves the change before
> the rest follow:
>
> ```nix
> deploy.nodes.web-01.profiles.system = {
>   magicRollback = true;
>   confirmTimeout = 30;
> };
> ```

A staged pipeline:

```yaml
  deploy-canary:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix run github:serokell/deploy-rs -- .#web-01

  deploy-rest:
    needs: deploy-canary
    runs-on: ubuntu-latest
    environment: production        # requires manual approval
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix run github:serokell/deploy-rs -- --targets .#web-02 .#db-01
```

> [!warning] Correction
> The original pipeline passed two flakes as plain arguments
> (`deploy-rs -- .#web-02 .#db-01`). `deploy` takes one target; use `--targets` for
> several. The jobs also lacked `runs-on`, which GitHub Actions requires, and a
> checkout. The SSH key the deployer needs is left out here.

## Pull-based updates

The alternative to pushing: each machine periodically rebuilds from the repository.

```nix
system.autoUpgrade = {
  enable = true;
  flake = "github:myorg/nixos-config";
  dates = "04:00";
  randomizedDelaySec = "45min";
  allowReboot = false;
};
```

Simple and requires no inbound access — but the machine applies whatever is on the
branch, so a broken commit reaches every host with no canary and no rollback. Pin it
to a tag rather than `main`, and let CI move the tag only after the canary succeeds.

## Updating dependencies

```bash
nix flake update                             # all inputs
nix flake update nixpkgs                     # just one
```

Automate it, so the lockfile bump is a reviewable pull request that CI has already
built:

```yaml
name: update-flake
on:
  schedule: [{ cron: "0 3 * * 1" }]
permissions:
  contents: write
  pull-requests: write
jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - uses: DeterminateSystems/update-flake-lock@main
        with:
          pr-title: "chore: update flake.lock"
```

That is the NixOS analogue of Dependabot, and it composes with the build matrix above
— the PR only merges if every host still builds.

## Secrets

Encrypted in the repository, decrypted on the host at activation:

```yaml
# .sops.yaml
creation_rules:
  - path_regex: secrets/web-01\.yaml$
    age: age1xxxxx...          # web-01's host key, converted from its SSH key
```

```bash
ssh-keyscan -t ed25519 web-01.example.com | nix run nixpkgs#ssh-to-age
sops secrets/web-01.yaml
```

> [!warning] Correction
> The original command was `nix shell nixpkgs#ssh-to-age --command ssh-keyscan
> web-01.example.com | ssh-to-age`. The pipe is outside `nix shell`, so the shell
> looks for `ssh-to-age` on your own `PATH` and fails when it is not installed.

Each host can decrypt only what was encrypted to it, and nothing sensitive enters the
Nix store. See [[linux/distributions/nixos/server]].

## Where to go next

- [[linux/distributions/nixos/server]] — the deployment tooling and secrets in detail
- [[linux/distributions/nixos/hardening]] — the module CI should be enforcing
- [[linux/distributions/nixos/testing]] — VM tests to run in that CI
- [[linux/distributions/nixos/automated-install]] — bringing a new host into the fleet
- git-conventions — commit conventions for the repository
- argocd — the same idea, for clusters

<!-- uplink -->
Part of [[linux/distributions/nixos/index|NixOS]].
