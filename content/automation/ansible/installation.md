---
title: Installing and configuring Ansible
description: Installing Ansible with pip, the /etc/ansible layout, and the main ansible.cfg settings
tags: [automation, ansible, installation, configuration]
type: howto
status: complete
---

# Installing and configuring Ansible

## Installation

Ansible is written in Python and its behaviour depends heavily on the Python
version in use. Python 3 is required — Python 2 support ended with
ansible-core 2.12. Each ansible-core release also raises the minimum Python on the
control node: ansible-core 2.22 (the `ansible` 15 package) needs Python 3.13 or later.

```console
$ python3 --version
Python 3.13.14
```

> [!note] Partly tested
> Tested with `ansible` 15.0.0 (ansible-core 2.22) on openSUSE Leap 16 (Python 3.13).
> The AWX Operator command at the end is not tested: it needs a Kubernetes cluster.

Install the engine with pip:

```bash
python3 -m pip install ansible
```

> [!note] `ansible` versus `ansible-core`
> `ansible-core` is the engine alone. The `ansible` package is the engine plus a
> curated set of collections — which is what you usually want, since since 2.10
> most modules live in collections rather than the engine. See
> [[automation/ansible/roles#Collections]].

> [!tip] Install into a virtual environment
> Ansible pins its own dependency versions and installing it system-wide with pip
> can conflict with distribution packages. `python3 -m venv ~/.venvs/ansible` first,
> or use `pipx install --include-deps ansible`.

## Directory layout

A distribution package (`zypper install ansible`, `dnf install ansible`) sets up
`/etc/ansible`. This is the layout Ansible looks for there:

```text
/etc/ansible
├── ansible.cfg   # the configuration file
├── hosts         # the default inventory file
└── roles         # the default directory for roles
```

> [!note] pip creates no `/etc/ansible`
> A pip install creates no `/etc/ansible`, and the Leap 16 package creates it
> **empty**. With no `ansible.cfg` anywhere, Ansible runs on built-in defaults
> (`ansible-config dump` shows `CONFIG_FILE() = None`). Generate a full commented file
> with `ansible-config init --disabled > ansible.cfg`.

> [!note] Prefer a per-project configuration
> Ansible looks for `ansible.cfg` in this order: `$ANSIBLE_CONFIG`, `./ansible.cfg`
> in the current directory, `~/.ansible.cfg`, then `/etc/ansible/ansible.cfg`. The
> first one found wins **entirely** — settings are not merged. Keeping an
> `ansible.cfg` in the project repository is far more reproducible than editing
> `/etc/ansible/ansible.cfg`.
>
> Ansible also ignores a `./ansible.cfg` in a world-writable directory, for
> security reasons, which is an occasionally baffling failure.

## Configuring Ansible

There are too many possible settings in `ansible.cfg` to cover exhaustively. The
ones worth knowing:

Number of hosts — and therefore local processes — handled in parallel, 5 by default:

```ini
[defaults]
forks = 10
```

Other settings that repay attention:

```ini
[defaults]
inventory = ./inventory
roles_path = ./roles
# Do not gather facts unless asked; see automation/ansible/inventory
gathering = explicit
# Cache facts so repeated runs do not re-interrogate every host
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 7200
# Readable output instead of one JSON blob per task
callback_result_format = yaml
# Do not prompt on first connection to an unknown host
host_key_checking = False

[ssh_connection]
# Reuse SSH connections; the single biggest speed win on large inventories
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
```

> [!warning] `stdout_callback = yaml` no longer works
> The `yaml` callback came from `community.general` and was removed in version 12: a
> playbook stops with *"The 'community.general.yaml' callback plugin has been
> removed"*. The built-in `default` callback does the same since ansible-core 2.13,
> with `callback_result_format = yaml`.

> [!warning] `host_key_checking = False` trades security for convenience
> It disables verification of host keys, which removes protection against
> man-in-the-middle attacks. Acceptable for ephemeral lab machines; on anything
> persistent, populate `known_hosts` instead.

Show the resolved configuration and where each value came from:

```bash
ansible-config dump --only-changed
ansible-config view
```

## AWX

AWX is the community counterpart to Ansible Automation Platform (formerly Ansible
Tower).

> [!warning] AWX runs on Kubernetes
> **AWX dropped Docker Compose support entirely at version 18.** Guides that install
> it with `docker-compose` on Debian *stretch*, with `apt-key add` and `python-pip`,
> are dead: stretch reached end of life in 2022, `apt-key` is deprecated, and
> `python-pip` was Python 2. AWX is deployed on Kubernetes with the AWX Operator:
>
> ```bash
> kubectl apply -k https://github.com/ansible/awx-operator/config/default
> ```
>
> See [[kubernetes/index|the Kubernetes section]] for the cluster side.

<!-- uplink -->
Part of [[automation/ansible/index|Ansible]].
