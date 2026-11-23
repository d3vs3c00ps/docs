---
title: Ansible roles, Galaxy and collections
description: Role anatomy, meta/main.yml, Ansible Galaxy, using roles from playbooks, and collections
tags: [automation, ansible, roles, galaxy, collections]
type: reference
status: complete
---

# Roles, Galaxy and collections

> [!note] Partly tested
> Tested with `ansible` 15.0.0 (ansible-core 2.22) on openSUSE Leap 16, against
> galaxy.ansible.com. The `lvg` example needs a spare disk and is checked only if
> the test can make a loop device.

## Roles

Roles are the equivalent of **cookbooks** in Chef or **modules** in Puppet: reusable
containers of actions.

Roles are comparable to parameterised playbooks — reusable, and producing the same
result on every run. They are powerful tools that let you:

- group related tasks, variables and files into one structure
- simplify deployment, since you only supply values for variables
- standardise installations
- avoid depending on local expertise — domain experts define how a piece of
  middleware should be installed, express it as a role, and everyone benefits
- keep code reusable

A role should be the atomic implementation of one particular need, specifying all
the tasks, variables and files that lead to it. A role is invoked by a playbook.

### Creating a role

Go to a `roles/` directory next to your playbook and initialise the role there.
Ansible looks in that directory first. Taking a `syslog-ng` role as the example —
see [[linux/logging/syslog-ng]]:

```bash
mkdir -p roles && cd roles
ansible-galaxy init syslog-ng --offline
```

> [!warning] Correction: no `/etc/ansible/roles` by default
> The original used `cd /etc/ansible/roles`. A pip install creates no
> `/etc/ansible` (see [[automation/ansible/installation]]). The default
> `roles_path` is `~/.ansible/roles`, then `/usr/share/ansible/roles`, then
> `/etc/ansible/roles`, and a `roles/` directory next to the playbook comes first.

Which produces:

```text
syslog-ng/
├── defaults
│   └── main.yml  # default variables
├── files         # static files (optional)
├── handlers
│   └── main.yml  # predefined actions (optional)
├── meta
│   └── main.yml  # role declaration
├── README.md     # documentation
├── tasks
│   └── main.yml  # the tasks to run
├── templates     # dynamic files (optional)
├── tests         # unit tests
│   ├── inventory
│   └── test.yml
└── vars
    └── main.yml  # variables you do not want overridden
```

### The directories

| Directory | Contents |
| --- | --- |
| `defaults` | the role's data — its default variables, lowest precedence so callers can override |
| `files` | static files copied to the client server |
| `handlers` | lists of tasks referenced by a unique name and triggered by `notify`. However many tasks notify a handler, it runs once, at the end of the phase (see [[automation/ansible/playbooks#Task ordering]]) |
| `meta` | information about the role: maintainer, supported OSes, dependencies |
| `tasks` | the actions |
| `templates` | dynamic files — see [[automation/ansible/variables#Templates]] |
| `vars` | variables you do not want overridden — high precedence |

> [!tip] `defaults/` versus `vars/`
> This is the distinction that trips people up. Both hold variables, but
> `defaults/main.yml` is the *lowest* precedence in Ansible and `vars/main.yml` is
> near the top. So anything a user of the role should be able to configure belongs in
> `defaults/`; only internal constants belong in `vars/`. See
> [[automation/ansible/variables#Variable precedence]].

### meta/main.yml

The meta file holds the role's metadata:

- the description
- author and licence information
- the minimum Ansible version
- supported platforms (OS, or network device)
- dependencies

```yaml
---
galaxy_info:
  author: your.name
  description: Install and configure syslog-ng
  license: MIT
  min_ansible_version: "2.14"
  platforms:
    - name: EL
      versions: ["8", "9"]
    - name: opensuse
      versions: ["all"]
  galaxy_tags:
    - logging
    - syslog

dependencies: []
```

> [!warning] Correction: Galaxy's platform list is old
> The original listed `name: openSUSE` with versions `"15.6"` and `"16.0"`.
> ansible-lint checks `platforms` against Galaxy's fixed list and reported
> `schema[meta]` for both. The name there is lowercase `opensuse`, and its only
> versions are `6.1`, `7.1`, `7.2` and `all`. Use `all` where your version is
> missing.

> [!warning] Dependencies run before the role, once per play
> A role listed in `dependencies:` is executed before the role that declares it —
> and by default only once per play, even if several roles depend on it. If a
> dependency needs to run more than once, set `allow_duplicates: true` in its meta.

## Ansible Galaxy

Roles published by companies and the community are available at
[galaxy.ansible.com](https://galaxy.ansible.com).

```bash
ansible-galaxy search apache
ansible-galaxy install geerlingguy.apache
ansible-galaxy remove geerlingguy.apache
ansible-galaxy list
```

For anything reproducible, declare requirements in a file rather than installing by
hand:

```yaml
# requirements.yml
roles:
  - name: geerlingguy.apache
    version: "3.2.0"

collections:
  - name: community.general
    version: ">=7.0.0"
```

```bash
ansible-galaxy install -r requirements.yml
```

> [!warning] Pin versions
> `ansible-galaxy install` without a version takes the latest at that moment, so two
> people running it on different days get different code. Pin in `requirements.yml`
> and commit it.

## Using roles

Roles can be included at play level or from a task:

```yaml
---
- hosts: apache
  become: true
  roles:
    - { role: example.apache, tags: apache }
  tasks:
    - name: Configure storage
      ansible.builtin.include_role:
        name: example.lvm
```

Mind the execution order:

- each role in the list runs in the order it appears
- all dependencies declared in `meta/main.yml` run **before** the role itself

> [!note] `roles:` versus `include_role` versus `import_role`
> `roles:` at play level runs before `tasks:`, which surprises people who expect
> ordering to follow the file. If you need a role to run *between* two tasks, call it
> with `include_role` (dynamic) or `import_role` (static) from the task list — see
> [[automation/ansible/variables#Inclusion]].

## Collections

A **collection** is a distribution format introduced in Ansible 2.9 and now the
primary way content is shipped. The idea behind it is to separate development of the
Ansible engine from its many and varied modules.

Since ansible-core 2.10 that separation is complete: the engine ships only
`ansible.builtin`, and everything else — `community.general`, `ansible.posix`,
`community.docker`, vendor collections — is a collection.

A collection can contain modules, roles, plugins, filters and playbooks.

Collections are managed with `ansible-galaxy`:

```bash
ansible-galaxy collection install community.general
ansible-galaxy collection install -r requirements.yml
ansible-galaxy collection list
```

Reference content by its fully qualified collection name:

```yaml
- name: Create a volume group
  community.general.lvg:
    vg: data
    pvs: /dev/sdb1
```

Further reading:

- [Using collections](https://docs.ansible.com/ansible/latest/collections_guide/index.html)
- [Developing collections](https://docs.ansible.com/ansible/devel/dev_guide/developing_collections.html)

<!-- uplink -->
Part of [[automation/ansible/index|Ansible]].
