---
title: Ansible cheat sheet
description: Recipes for excluding a host from its own group, per-distribution task files, extracting registered variables across hosts, and passing values between plays
tags: [automation, ansible, cheatsheet, jinja2]
type: reference
status: complete
---

# Ansible cheat sheet

> [!note] Tested
> Tested with `ansible` 15.0.0 (ansible-core 2.22) on openSUSE Leap 16, with real
> `chronyc keygen`.

Recipes that are hard to remember and hard to search for. For the reference material
see [[automation/ansible/variables]] and
[[automation/ansible/playbooks]]; for YAML block-scalar syntax see yaml.

## Excluding a host from its own group

When deploying clusters you usually do not want a server to appear in its own list
of peers:

```yaml
chrony_ntp_peers: "{{ groups['servers'] | reject('equalto', inventory_hostname) | list }}"
```

See chrony for what consumes this.

## Including a task file per distribution

```yaml
- name: Include OS family / distribution specific task file
  ansible.builtin.include_tasks: "{{ item }}"
  with_first_found:
    - "{{ ansible_os_family | lower }}/{{ ansible_distribution | lower }}_{{ ansible_distribution_version | lower }}.yml"
    - "{{ ansible_os_family | lower }}/{{ ansible_distribution | lower }}.yml"
    - "{{ ansible_os_family | lower }}.yml"
```

`with_first_found` takes the first path that exists, so the list runs from most
specific to least. A matching `tasks` layout:

```text
└── tasks
    ├── main.yml
    ├── suse.yml
    └── redhat.yml
```

> [!note] `include` is deprecated
> The bare `ansible.builtin.include` module was deprecated
> in 2.4 and removed in 2.16 because it was ambiguous between static and dynamic
> behaviour. Use `include_tasks` (dynamic) or `import_tasks` (static) — see
> [[automation/ansible/variables#Inclusion]].

## Extracting a registered variable across hosts

Inside a role you cannot use `group_vars`, so retrieving a *hostvar* generated
during a task takes some work.

Playing with filters — an extract from a `chrony` installation role:

```yaml
- name: Generate chrony key
  ansible.builtin.command: chronyc keygen 10 SHA512 2048
  register: __generated_chrony_key
  when: chrony_generate_keys
  # The command runs on a single host, and register puts the value in that host's
  # hostvars, where the other hosts cannot see it.

- name: Check the registered value
  ansible.builtin.debug:
    var: __generated_chrony_key.stdout
    verbosity: 2
  when: chrony_generate_keys

- name: Get the generated key
  ansible.builtin.set_fact:
    __chrony_key: >-
      {{ ansible_play_hosts | map('extract', hostvars, '__generated_chrony_key')
         | selectattr('stdout', 'defined') | list }}
  # Take the registered result from every host in the play, and keep the one that
  # ran (it has stdout). If unsure of the resulting type, swap the `list` filter
  # for `type_debug`.

- name: Show the extracted structure
  ansible.builtin.debug:
    var: __chrony_key
    verbosity: 2
  # A list containing one dictionary

- name: Show the value itself
  ansible.builtin.debug:
    var: __chrony_key.0.stdout
    verbosity: 2
  # So take the first entry (0), which holds the data wanted
```

> [!warning] Use `ansible_play_hosts`, not `groups['all']`
> `groups['all']` also holds hosts outside the play. They have no
> `__generated_chrony_key`, and `map('extract', hostvars)` then stops with "object of
> type 'HostVarsVars' has no attribute".

Another approach — loop over all hosts and keep only the correct result:

```yaml
- name: Generate and get chrony key
  block:
    - name: Generate chrony key
      ansible.builtin.command: chronyc keygen 10 SHA512 2048
      register: __generated_chrony_key
      loop: "{{ ansible_play_hosts }}"
      delegate_to: "{{ item }}"
      when: hostvars[item].chrony_generate_keys is defined

    - name: Keep the generated key
      ansible.builtin.set_fact:
        __chrony_key: "{{ item.stdout }}"
      loop: "{{ __generated_chrony_key.results }}"
      when: item.stdout is defined
      no_log: true
  run_once: true

- name: Debug the chrony key
  ansible.builtin.debug:
    var: __chrony_key
    verbosity: 2
```

`no_log: true` matters here — without it the generated key is printed in the task
output. See [[automation/ansible/vault#What Vault does not do]].

## Sharing a variable between plays and hosts

A variable's value cannot cross hosts if it is defined in that host's hostvars.
Take this play:

```yaml
---
- hosts: localhost
  gather_facts: false
  tasks:
    - name: Register a new value
      ansible.builtin.shell: echo "/etc/resolv.conf"
      register: resolv

    - ansible.builtin.debug:
        msg: "{{ resolv.stdout }}"
```

`resolv` is only available to the host that ran the task.

To make it persist across plays and hosts, create an ephemeral host to hang it on:

```yaml
---
- hosts: host-01
  gather_facts: false
  tasks:
    - name: Register a new value
      ansible.builtin.shell: echo "/etc/resolv.conf"
      register: resolv

    - name: Register a dummy host carrying the variable
      ansible.builtin.add_host:
        name: "DUMMY_HOST"
        __resolv: "{{ resolv.stdout }}"
```

Then read it from another play:

```yaml
---
- hosts: host-02
  gather_facts: false
  tasks:
    - name: Use the __resolv value from the dummy host
      ansible.builtin.shell: "cat {{ hostvars['DUMMY_HOST']['__resolv'] }} | tail -1"
      register: resolv

    - ansible.builtin.debug:
        msg: "{{ resolv.stdout }}"
```

`add_host` hosts are in-memory only and vanish at the end of the run, which is
exactly what makes this work as a scratch namespace.

## Dumping all variables and facts for a host

Useful when you cannot work out where a value is coming from:

```yaml
---
- name: Dump everything
  hosts: apache-01
  gather_facts: true
  tasks:
    - name: Dump vars
      ansible.builtin.copy:
        content: "{{ hostvars[inventory_hostname] | to_nice_yaml }}"
        dest: "/tmp/{{ inventory_hostname }}_vars.txt"
        mode: "0644"
      delegate_to: localhost

    - name: Dump facts
      ansible.builtin.copy:
        content: "{{ ansible_facts | to_nice_yaml }}"
        dest: "/tmp/{{ inventory_hostname }}_facts.txt"
        mode: "0644"
      delegate_to: localhost
```

> [!note] Two traps
> With `gather_facts: false`, `ansible_facts` is empty, so there is nothing to dump.
> And `owner: root` / `group: root` on a task with `delegate_to: localhost` and no
> `become` fails, unless you run as root locally.

## Determining a variable's type

```yaml
- name: What type is this
  ansible.builtin.debug:
    msg: "{{ myvar | type_debug }}"
```

Invaluable when a comparison is not matching: a value that looks like a number is
often the string `"3"`.

## Lists

### Appending a value to a list

```yaml
---
- name: Lists demo
  hosts: localhost
  tasks:
    - name: Create list
      ansible.builtin.set_fact:
        fruit: [apple, banana, orange, grapes]

    - name: Append 'citrus' to the fruit list
      ansible.builtin.set_fact:
        fruit: "{{ fruit + ['citrus'] }}"

    - name: Show list
      ansible.builtin.debug:
        msg: "{{ fruit }}"
```

These outputs use `callback_result_format = yaml` (see
[[automation/ansible/installation#Configuring Ansible]]). The default format is JSON.

```text
ok: [localhost] =>
    msg:
    - apple
    - banana
    - orange
    - grapes
    - citrus
```

Note the appended element must itself be a list — `fruit + ['citrus']`, not
`fruit + 'citrus'`, which fails: a list and a string cannot be added.

### Appending one list to another

```yaml
---
- name: Lists demo
  hosts: localhost
  tasks:
    - name: Create lists
      ansible.builtin.set_fact:
        fruit: [apple, banana, orange, grapes]
        vegetables: [tomato, potato, beans]

    - name: Combine them
      ansible.builtin.set_fact:
        shopping: "{{ fruit + vegetables }}"

    - name: Show list
      ansible.builtin.debug:
        msg: "{{ shopping }}"
```

```text
ok: [localhost] =>
    msg:
    - apple
    - banana
    - orange
    - grapes
    - tomato
    - potato
    - beans
```

`union` deduplicates where `+` does not: `{{ fruit | union(vegetables) }}`.

## Dictionaries

### Adding entries to a dictionary

`combine` merges dictionaries, returning a new one:

```yaml
---
- name: Dict demo
  hosts: localhost
  tasks:
    - name: Create dict
      ansible.builtin.set_fact:
        config:
          port: 80
          host: localhost

    - name: Add an entry
      ansible.builtin.set_fact:
        config: "{{ config | combine({'tls': true}) }}"

    - name: Show it
      ansible.builtin.debug:
        var: config
```

```text
ok: [localhost] =>
    config:
        host: localhost
        port: 80
        tls: true
```

For nested dictionaries, `combine` replaces a whole sub-dictionary by default. Pass
`recursive=true` to merge instead:

```yaml
config: "{{ config | combine({'db': {'port': 5432}}, recursive=true) }}"
```

## Troubleshooting

Increase verbosity with `-v`, adding more `v` for more detail:

| Level | Shows |
| --- | --- |
| `-v` | task results |
| `-vv` | plus task and play details, and `verbosity: 2` debug messages |
| `-vvv` | plus the SSH commands being run — the level for connection problems |
| `-vvvv` | plus which plugins load from where, and the command-line options |

Other things worth reaching for:

```bash
# where is this variable coming from
ansible -m debug -a 'var=hostvars[inventory_hostname]' <host>

# which config file and settings are actually in effect
ansible-config dump --only-changed

# time each task, to find the slow one
# (set callbacks_enabled = profile_tasks in ansible.cfg)
```

<!-- uplink -->
Part of [[automation/ansible/index|Ansible]].
