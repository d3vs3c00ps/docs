---
title: Red Hat Enterprise Linux
description: Managing RHEL subscriptions, repositories and enabling EPEL
tags: [linux, rhel, subscription-manager, packaging]
type: howto
status: complete
---

# Red Hat Enterprise Linux

Notes for managing a RHEL server. See [[linux/distributions/opensuse-leap]] for
the openSUSE Leap equivalents.

## Subscriptions and repositories

Clear out stale subscription state:

```bash
subscription-manager unregister
subscription-manager clean
```

Register the host and pull its subscription data:

```bash
subscription-manager register
subscription-manager refresh
```

List and enable repositories:

```bash
subscription-manager repos --list-enabled
subscription-manager repos --list
subscription-manager repos --enable <repo-id>
```

> [!warning] Correction: no more `attach` and `remove`
> The original note also ran `subscription-manager remove --all` and
> `subscription-manager attach --auto`. They belong to the old entitlement mode.
> With Simple Content Access, a registered host can use every repository of the
> account, so there is nothing to attach. RHEL 10's `subscription-manager` no
> longer has the `attach` and `remove` commands: they fail and print the list of
> commands. On RHEL 8 and 9 they still exist, and do nothing under Simple Content
> Access. `subscription-manager repos` remains the way to toggle repositories.

> [!note] Registration is not tested
> `register`, `refresh` and `repos` need a Red Hat account. The test checks that
> the commands and options exist in RHEL 10's `subscription-manager` (from Rocky
> Linux 10), and runs the EPEL part on Rocky Linux 10.

## Enabling EPEL

EPEL (Extra Packages for Enterprise Linux) is a community repository maintained by
the Fedora project, carrying packages Red Hat does not ship.

Install the release package matching your major version — `$(rpm -E %rhel)`
expands to it, so the same command works on 8, 9 and 10:

```bash
dnf install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm"
```

Several EPEL packages depend on the `CodeReady Builder` repository, so enable it
too:

```bash
subscription-manager repos --enable "codeready-builder-for-rhel-$(rpm -E %rhel)-$(arch)-rpms"
```

On a rebuild such as Rocky Linux or AlmaLinux, the same repository is called
`crb`. The `crb` script from `epel-release` enables it:

```bash
crb enable
```

> [!warning] EPEL is not supported by Red Hat
> Packages from EPEL fall outside your support contract, and EPEL can update a
> package in ways that conflict with the base OS. Pin or exclude what matters.

<!-- uplink -->
Part of [[linux/distributions/index|Distributions]].
