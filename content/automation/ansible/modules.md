---
title: Ansible modules and ad-hoc commands
description: Finding and reading module documentation, the command/shell/script/raw modules, and running ad-hoc commands
tags: [automation, ansible, modules, cli]
type: reference
status: complete
---

# Modules and ad-hoc commands

> [!note] Partly tested
> Tested with `ansible` 15.0.0 (ansible-core 2.22) on openSUSE Leap 16. Running
> PowerShell with `script` is not tested: it needs a Windows host.

## Modules

A module is written in Python and performs a task at a high level of abstraction.
Documentation for every module is on the
[official site](https://docs.ansible.com/ansible/latest/collections/index_module.html),
or offline:

```bash
ansible-doc <module_name>
ansible-doc -l              # list every available module
ansible-doc -s <module>     # just the playbook snippet
```

> [!note] Module counts move fast
> Since ansible-core 2.10, the engine ships only a small set of `ansible.builtin` modules and everything else
> lives in collections. Use `ansible-doc -l` on your own installation rather than
> any published figure.

> [!warning] `ansible-doc -l` crashes in Ansible 15.0.0
> With no argument, `ansible-doc -l` stops with
> `'_AnsibleTaggedDict' object has no attribute 'strip'`. The cause is the
> `google.cloud` collection that the `ansible` package bundles. List one collection
> at a time instead:
>
> ```bash
> ansible-doc -l ansible.builtin       # under 100 modules
> ansible-doc -l community.general
> ```

> [!tip] Use fully qualified collection names
> `ansible.builtin.dnf` rather than `dnf`. Short names still resolve, but FQCNs
> remove the ambiguity when two collections provide the same short name — and
> `ansible-lint` will require them (rule `fqcn[action-core]`).

> [!warning] `ansible.builtin.yum` is gone
> ansible-core 2.17 removed the `yum` module, and `ansible-doc ansible.builtin.yum`
> says it was not found. A task that uses the name still runs, as a redirect to
> `ansible.builtin.dnf`. Write `ansible.builtin.dnf`.

### command and shell

| Module | Behaviour |
| --- | --- |
| `command` | runs a command directly, whatever shell is installed |
| `shell` | runs the command through the target's default shell, so redirections and pipes work |

`command` is the safer of the two — no shell means no pipes, redirections or
globs, so less risk of injection. Use `shell` only when you genuinely need shell
features.

> [!note] `command` still expands environment variables
> `-a 'echo "$HOME > /tmp/x"'` prints `/home/ansible > /tmp/x`: the variable is
> expanded, but the `>` stays plain text, so no file is written. The option
> `expand_argument_vars` controls this, and it is on by default.

### script and raw

| Module | Behaviour |
| --- | --- |
| `script` | transfers a local script to the target and runs it — useful for PowerShell |
| `raw` | runs a command without going through Ansible's module system |

`raw` needs no Python on the target, which makes it the tool for bootstrapping a
host that does not yet have an interpreter — or for network appliances that never
will.

> [!warning] These four modules are not idempotent
> They run every time and always report `changed`. Reach for a purpose-built module
> first; when you cannot, constrain them with `creates:`, `removes:` or
> `changed_when:` so reruns behave. `raw` has no `creates:` or `removes:`, so use
> `changed_when:` with it. See
> [[automation/ansible/playbooks#Tasks and idempotence]].

### Reading module documentation

```console
$ ANSIBLE_NOCOLOR=1 ansible-doc lvg
> MODULE community.general.lvg (.../ansible_collections/community/general/plugins/modules/lvg.py)

  This module creates, removes or resizes volume groups.

OPTIONS (= indicates it is required):

- force   If `true', allows to remove volume group with logical
           volumes.
        default: false
        type: bool

- pvs     List of comma-separated devices to use as physical devices
           in this volume group.
           Required when creating or resizing volume group.
           The module runs `pvcreate' if needed.
[...]
= vg      The name of the volume group.
        type: str
```

Note the `=` prefix: it marks a mandatory option. With colour on (the default in
a terminal), `ansible-doc` shows required options in red instead of the `=`. See [[linux/storage/lvm]] for
what this particular module manages.

## Ad-hoc commands

The first thing you can do with Ansible is run *ad-hoc* commands — executing
directly against the target servers using the supplied modules.

Run a command with `-a` alone. With no `-m`, Ansible uses the `command` module
(this is not a raw command: it does not use the `raw` module):

```bash
ansible all -a "echo ansible FTW"
```

Run a module with arguments:

```bash
# install Apache on svr-apache-01 (-b: as root)
ansible svr-apache-01 -b -m zypper -a "name=apache2 state=present"

# restart Apache
ansible svr-apache-01 -b -m service -a "name=apache2 state=restarted"

# run a shell command
ansible svr-apache-01 -m shell -a "du -hs /opt"
```

> [!note] `-b`, and `apache2` on openSUSE
> Without `-b` (`--become`), zypper stops with "Root privileges are required". On
> openSUSE the package and the service are both called `apache2`; `httpd` is the Red
> Hat name.

Test connectivity against everything, a group, or one host:

```bash
ansible all -m ping
ansible apache -m ping
ansible svr-apache-01 -m ping
```

Use a different inventory:

```bash
ansible -i /etc/ansible/hosts all -m ping
ansible -i /etc/ansible/hosts apache -m ping
```

List a host's facts:

```bash
ansible -i /etc/ansible/hosts svr-apache-01 -m setup
```

## Connection options

These apply equally to `ansible` and `ansible-playbook`:

```bash
# connect as a specific user
ansible all -m ping -u deploy
ansible-playbook site.yml -u deploy

# use an alternative SSH key
ansible all -m ping --private-key=~/.ssh/backup_id
ansible-playbook site.yml --private-key=~/.ssh/backup_id

# prompt for the connection password
ansible all -m ping --ask-pass

# prompt for the sudo password
ansible all -m ping --ask-become-pass
```

See [[automation/ansible/cheatsheet]] for the full command reference.

<!-- uplink -->
Part of [[automation/ansible/index|Ansible]].
