---
title: Ansible playbooks, tasks and handlers
description: Playbook structure, idempotence, task ordering, blocks, handlers, run_once, serial, delegation, tags and execution control
tags: [automation, ansible, playbooks, tasks, handlers, idempotence]
type: reference
status: complete
---

# Playbooks, tasks and handlers

> [!note] Partly tested
> Tested with `ansible` 15.0.0 (ansible-core 2.22) on openSUSE Leap 16, with stub
> `example.*` roles. The Red Hat tasks (`dnf`, `httpd`) get a syntax check only; the
> handler example ran with `apache2`. The Windows DNS delegation is not tested.

## Playbooks

A playbook orchestrates actions on the targeted servers.

- written in **YAML**
- contains one or more **plays**, each mapping hosts to tasks
- it is specific, unlike a [[automation/ansible/roles|role]], which is reusable

A playbook that installs Apache by including roles:

```yaml
---
- hosts: apache
  become: true
  roles:
    - { role: example.lvm,      tags: lvm }
    - { role: example.firewall, tags: firewall }
    - { role: example.apache,   tags: apache }
```

Or writing the tasks directly:

```yaml
---
- hosts: apache
  become: true
  tasks:
    - name: Install apache
      ansible.builtin.dnf:
        name: httpd
        state: present
```

Either way it runs the same:

```console
$ ansible-playbook install_apache.yml

PLAY [apache] ******************************************************************
TASK [Install apache] **********************************************************
ok: [svr-apache-01]
```

## Tasks

A **task** is a call to an Ansible module. In a task you describe the *expected
state*. If the state does not match, the module performs whatever is needed to
reach it.

### Tasks and idempotence

Worth remembering:

- Ansible guarantees the *state* of a system — that a package is installed, a user
  exists, a file exists.
- "task" is a poor name; think **state**.
- For a given task Ansible checks whether the state is the desired one, and if not
  performs the operations needed to get there.
- During a playbook run a state change is reported as **changed**.

A playbook must be runnable repeatedly without introducing inconsistency. When
there is no error, a playbook run a second time should report **zero** changes.

> [!important] Non-zero changed on a second run means non-idempotent
> If a rerun still reports `changed`, some task is doing work unconditionally —
> almost always `command`, `shell`, `script` or `raw`. Constrain it:
>
> ```yaml
> - name: Extract the archive
>   ansible.builtin.command: tar xzf /tmp/app.tar.gz -C /opt/app
>   args:
>     creates: /opt/app/bin/app     # skip entirely if this exists
> ```
>
> Or tell Ansible how to judge the result:
>
> ```yaml
> - name: Check cluster health
>   ansible.builtin.command: cluster-health
>   register: health
>   changed_when: false            # a read-only command never changes anything
>   failed_when: "'DEGRADED' in health.stdout"
> ```

### Task ordering

Tasks run in these phases:

```yaml
---
- hosts: apache
  become: true
  pre_tasks:
    - name: pre task
      ansible.builtin.debug:
        msg: Runs before everything
  roles:
    - example.apache
  tasks:
    - name: task
      ansible.builtin.debug:
        msg: Runs after the included roles
  post_tasks:
    - name: post task
      ansible.builtin.debug:
        msg: Runs after everything
```

Handlers notified in a phase run at the end of that phase: after `pre_tasks`,
after `roles` and `tasks` together, and after `post_tasks`.

> [!note] Handlers run per phase
> Ansible flushes handlers at the end of each phase, so a handler notified in
> `pre_tasks` runs before the roles start.

### Task execution

Each task in a play runs in parallel across all targeted hosts. By default
execution is synchronised: Ansible waits for a task to complete on every targeted
host before moving to the next one.

The width of that parallelism is `forks` — see
[[automation/ansible/installation#Configuring Ansible]].

### Blocks

When working with conditions it is useful to group tasks sharing the same
condition. That is what **blocks** are for:

```yaml
- block:
    - name: Install apache
      ansible.builtin.dnf:
        name: httpd
        state: present
    - name: Enable the apache service
      ansible.builtin.service:
        name: httpd
        enabled: true
  when: ansible_os_family == 'RedHat'
```

Blocks also provide error handling, which is their other main use:

```yaml
- block:
    - name: Attempt the upgrade
      ansible.builtin.command: /opt/app/upgrade.sh
  rescue:
    - name: Roll back
      ansible.builtin.command: /opt/app/rollback.sh
  always:
    - name: Always report
      ansible.builtin.debug:
        msg: Upgrade attempted
```

### run_once

`run_once` makes a task run only once. If several servers are targeted, only the
first executes the action:

```yaml
- hosts: apache
  tasks:
    - name: Initialise the shared database schema
      ansible.builtin.command: /opt/app/migrate.sh
      run_once: true
```

Useful for anything that must happen exactly once per play — a schema migration, a
cluster initialisation — rather than once per host.

### serial

`serial` paces execution, which is how you do a rolling update:

```yaml
- hosts: apache
  serial: 1
  tasks:
    - name: Restart apache
      ansible.builtin.service:
        name: httpd
        state: restarted
```

Here the play runs server by server. More precise pacing is possible:

| Value | Behaviour |
| --- | --- |
| `serial: 1` | one host at a time |
| `serial: 30%` | 30% of hosts, then the next 30% |
| `serial: [1, 10]` | the first host, then batches of 10 |
| `serial: [1, 100%]` | the first host, then all the rest |

> [!note] `serial` is a play keyword
> `serial` controls how the **play** batches its hosts and must sit at play level.
> Under a task it does not work. `run_once` is a task keyword.

### Delegation

A task can be made to run on a server other than the one being configured — for
example an infrastructure server, to register DNS:

```yaml
- name: Add the host to DNS
  ansible.windows.win_command: >
    Add-DnsServerResourceRecordA
    -Name {{ inventory_hostname }}
    -ZoneName "test.lab"
    -IPv4Address {{ ansible_default_ipv4.address }}
  delegate_to: winrm_server
```

`delegate_to: localhost` is the common case — calling an API or updating a load
balancer from the control node while iterating over remote hosts.

## Handlers

Some applications need an action triggered by another action. A **handler** is
useful for restarting a service after a configuration change. It is a task that:

- is referenced by a unique name
- is triggered by `notify`
- runs only if needed — only if the notifying task reported a *change*
- runs once at the end of the play, however many tasks notified it
- can be forced early with the `meta: flush_handlers` task

`handlers/main.yml`:

```yaml
- name: restart apache
  become: true
  ansible.builtin.service:
    name: httpd
    state: restarted
```

And the task that notifies it:

```yaml
- name: Deploy the apache configuration
  ansible.builtin.template:
    src: httpd.conf.j2
    dest: /etc/httpd/conf/httpd.conf
  notify: restart apache
```

> [!warning] Handlers do not run if the play fails
> If a later task fails, the play aborts and pending handlers never fire — leaving a
> new configuration on disk and the old one still running. `--force-handlers`, or
> `force_handlers: true` on the play, runs them anyway.

## Tags

Actions can be tagged in order to run only those, or to exclude them.

Some tags have special behaviour:

| Tag | Behaviour |
| --- | --- |
| `always` | always runs, unless explicitly skipped with `--skip-tags always` |
| `never` | never runs unless explicitly requested by name |

## Controlling execution

Check the syntax without running anything:

```bash
ansible-playbook site.yml --syntax-check
```

Simulate the run — a dry run:

```bash
ansible-playbook site.yml --check
```

Show what would change, as a diff:

```bash
ansible-playbook site.yml --diff
```

`--check --diff` together is the combination worth remembering.

> [!note] `--check` is only as honest as your tasks
> Modules that do not support check mode are skipped rather than simulated, and
> `command`/`shell` tasks do nothing at all — so a clean `--check` does not prove a
> clean run.

Override the playbook's `hosts` with `-l`:

```bash
ansible-playbook -l svr-apache-01 site.yml
```

List what would be affected, without running:

```bash
ansible-playbook site.yml --list-hosts
ansible-playbook site.yml --list-tasks
ansible-playbook site.yml --list-tags
```

Run only certain tags, or skip some:

```bash
ansible-playbook site.yml --tags=configrepos,installapache
ansible-playbook site.yml --skip-tags="secure-os"
```

Start partway through:

```bash
ansible-playbook site.yml --start-at-task="Config repos"
```

Step through interactively, confirming each task:

```bash
ansible-playbook site.yml --step
```

Increase verbosity — up to `-vvvvv`, where `-vvv` shows the SSH commands and is
usually the level you want when debugging a connection:

```bash
ansible-playbook site.yml -vvv
```

<!-- uplink -->
Part of [[automation/ansible/index|Ansible]].
