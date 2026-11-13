# Note tests

Each note that makes claims you can run has a test here. The test runs the note's
commands in a throwaway container or a kind cluster, and checks that the note is
right: exit codes, output, files, and the failures the note warns about.

`tests/<path>.sh` tests `content/<path>.md`. `tests/<path>.<variant>.sh` (for example
`hardening.vm.sh`) is an extra test for the same note, when part of it needs another
environment. A note that cannot run locally is listed
in `untested.txt` with the reason, and shows a `> [!note] Not tested locally` callout.
`scripts/test-coverage.mjs` enforces both rules.

## Run

You need [Task](https://taskfile.dev) and Docker. Nothing else: checks and tests run
in the runner container (`tests/runner/Dockerfile`), the same way on macOS arm64 and
Linux amd64. `task` with no name lists every task.

```bash
task test                          # everything
task test NOTE=linux/cli/stow      # one note (or: task test -- linux/cli/stow)
task test ENV=leap-systemd         # one environment
task tests:changed                 # notes changed on this branch
task tests:k8s                     # kind tests, then the k3d test
task check                         # fast checks: lint, MOCs, coverage, shellcheck, prettier
task runner:shell                  # a shell in the runner, to debug a test by hand
```

Logs go to `.test-results/<path>.tap`. The kind and k3d clusters (`notes-test`) stay up
between runs to save time. `task k8s:kind-down` / `task k8s:k3d-down` delete them.
`CLUSTER=other task test …` uses another cluster, so two runs can test Kubernetes notes
at the same time. `task k8s:kubeconfig` prints a `KUBECONFIG` to use the kind cluster
from your own shell.

### The runner

`scripts/runner.sh` builds the image on first use (and again when `versions.env` or the
Dockerfile changes), then runs the command in it with:

- the host Docker socket: test containers and clusters are siblings of the runner;
- `--network host`: published ports and kind/k3d API servers on `127.0.0.1` work as on
  a Linux host. This works on Docker Desktop for macOS too;
- the repository mounted **at the same path** as on the host, so a test can pass a path
  under the repository to `docker run -v`. For that reason a Kubernetes test's
  `TMPDIR` is under `.test-results/`, not `/tmp`.

In CI and in the devcontainer, `runner.sh` runs the command directly. `RUNNER=native`
does the same anywhere; it then needs bash 4.3+ and the tools from
`scripts/install-test-tools.sh` (Linux).

## Write a test

```bash
#!/usr/bin/env bash
# note: linux/cli/tar.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

section "Create an archive"              # the note heading being checked
check "tar -czf creates the archive" tar -czf out.tgz /etc/hostname
check_output "tar -tzf lists the file" '^etc/hostname$' tar -tzf out.tgz
```

The header lines are read by `scripts/test-notes.sh`:

| Header | Values |
| --- | --- |
| `# note:` | the note path under `content/`, must match the test's own path |
| `# env:` | `leap`, `rocky`, `nix`, `go` — a plain container from `envs/` |
| | `priv:<env>` — the same, with `--privileged` (iptables, LVM, namespaces) |
| | `leap-systemd`, `rocky-systemd` — systemd as PID 1, privileged |
| | `nixos` — a NixOS 26.05 system, systemd as PID 1. See "NixOS" below |
| | `kind`, `k3d` — runs on the host against the shared cluster, in `$TEST_NS` |
| | `task` — Leap 16 with [Task](https://taskfile.dev) at `TASK_VERSION` |
| | `compose` — runs on the host (in the runner) with Docker Compose, one test at a time, in its own `$COMPOSE_PROJECT_NAME`, removed with its volumes after. Source `lib/compose.sh` |
| `# nixos:` | `nixos` only: a module next to the test, built into the system |
| `# timeout:` | seconds, default 600 |

Helpers, from `lib/assert.sh`:

| Helper | Passes when |
| --- | --- |
| `check DESC CMD...` | CMD exits 0 |
| `check_fails DESC CMD...` | CMD exits non-zero |
| `check_output DESC REGEX CMD...` | CMD exits 0 and its output matches REGEX |
| `assert_eq DESC EXPECTED ACTUAL` | the strings are equal |
| `assert_match` / `assert_no_match DESC REGEX STRING` | REGEX matches / does not match |
| `assert_file` / `assert_no_file` / `assert_link DESC PATH [TARGET]` | the path exists / does not / is a link to TARGET |
| `skip DESC REASON` | always; prints the reason. Never skip silently |
| `retry N CMD...` | (not a check) runs CMD up to N times, one second apart |
| `note_block NOTE HEADING [N]` | (not a check) prints the Nth code block under HEADING |

Commands outside a helper are setup. They run under `set -e`: if one fails, the test
stops and is reported as aborted.

For Kubernetes tests, also `source "$NOTES_ROOT/tests/lib/k8s.sh"` and call
`use_test_namespace`, so plain `kubectl` commands from the note land in `$TEST_NS`.
The cluster is `$CLUSTER` (default `notes-test`): name nodes as `"$CLUSTER-worker"`.
`start_cloud_provider_kind` gives LoadBalancer Services and class-less Ingresses an IP,
and stops on exit. In the runner it uses the cloud-provider-kind image on the `kind`
network: the binary there cannot resolve `<cluster>-control-plane`, falls back to random
published ports, and Docker Desktop does not expose those to the host network.

For Docker Compose tests, `source "$NOTES_ROOT/tests/lib/compose.sh"`. The test starts
in an empty work directory under `.test-results/`. `wait_http URL [TIMEOUT]` polls a
URL until it answers; `compose_logs SERVICE` prints a service's last log lines.

An env Dockerfile gets every `tests/versions.env` value as a build argument: declare
`ARG TASK_VERSION` (for example) to use one.

### Rules

- **Test the note's own code.** Use `note_block` to run a block from the note rather
  than a copy. When the note changes, the test follows or fails.
- **Test what the note claims,** including warnings: if a note says "this fails", use
  `check_fails`.
- **When a test shows the note is wrong, fix the note,** with a
  `> [!warning] Correction` callout if the original claim changes.
- **Never mark a claim as tested if it did not run.** Use `skip` with the real reason,
  or list the note in `untested.txt`.
- Tests must pass on amd64 (CI) and arm64 (Apple Silicon devcontainers). Use
  multi-arch images.

## NixOS

NixOS notes are tested on real NixOS systems, built from the note's own code. No Nix
is needed on your machine: builds run in the `nix` image, with the Nix store in the
`notes-nix-store` Docker volume, so nixpkgs is downloaded once.

| Kind of claim | How | Where |
| --- | --- | --- |
| Services, users, files, firewall, systemd units | `# env: nixos`: the system boots in Docker, the test runs inside | here, CI |
| What an option does, or that a block fails to build | `nixos_eval` from a `nixos` test | here, CI |
| Kernel, sysctls, initrd, boot, disks | a NixOS VM test (`runNixOSTest`) from a `# env: nix` test | CI only: needs KVM |

A test's module takes the note's blocks with `notes.module "Heading" N`, the same
selection as `note_block`:

```nix
# tests/linux/distributions/nixos/hardening.nix, used with `# nixos: hardening.nix`
{ notes, lib, ... }:
{
  imports = [
    (notes.module "SSH and access" 1)
    (notes.module "Firewall" 1)
  ];
  networking.firewall.enable = lib.mkForce true;   # the container profile turns it off
}
```

A block that is a fragment (`services.x = { ... };`) or uses `pkgs` with no function
header is wrapped into a module for you.

Helpers, from `lib/nixos.sh` (in `nixos` tests) and `lib/nixos-vm.sh`:

| Helper | Does |
| --- | --- |
| `nixos_eval [--host] [--block HEADING N] ATTR` | prints `config.ATTR` as JSON. `--host` evaluates a normal machine, without the Docker profile. Fails with Nix's error when the configuration does not evaluate |
| `nixos_vm_check DESC NOTE TEST.nix` | a check: builds and runs a VM test. Skipped, with the reason, when there is no `/dev/kvm` |

> [!warning] Never boot what changes the kernel
> The container shares the Docker host's kernel. Kernel sysctls, `lockKernelModules`,
> AppArmor profiles and audit rules would apply to that shared kernel. Evaluate those
> blocks with `nixos_eval --host`, and boot them in a VM test.

By hand:

```bash
task nixos:shell                                   # a root shell on the base system
task nixos:shell NOTE=linux/distributions/nixos/hardening \
  MODULE=tests/linux/distributions/nixos/hardening.nix
task nixos:update                                  # move tests/nixos/flake.lock forward
task nixos:gc                                      # remove the images and unused store paths
```

Each image is 2 to 3 GB. There is at most one per test: a changed configuration
replaces the old image. The first build takes about two minutes, an unchanged one
about fifteen seconds.

### The installer ISO

`nixos/autoinstall/` builds a NixOS ISO that installs itself with no questions, like
Kickstart or preseed. See `content/linux/distributions/nixos/automated-install.md`.

```bash
task nixos:iso          # dist/nixos-autoinstall-<system>.iso
task nixos:iso-test     # install it into an empty QEMU disk, boot the result, check
                        # that booting the ISO again leaves the used disk alone
```

The test needs QEMU (`scripts/install-vm-tools.sh`, run by the devcontainer). With KVM
it takes a few minutes; emulated, much longer. CI runs it weekly, or on a pull request
labelled `nixos-iso`.

## Versions

Tool and image versions live in `versions.env`, one file for the devcontainer, the
Taskfile, the runner image and CI. `scripts/install-test-tools.sh` installs the tools at those versions.
