---
title: Testing Ansible roles with Molecule
description: Scaffolding a Molecule scenario for a role, the molecule.yml configuration, scenarios and the test lifecycle
tags: [automation, ansible, molecule, testing, containers]
type: howto
status: complete
---

# Testing roles with Molecule

Molecule helps you write Ansible roles. It runs a role against test instances
(containers, virtual machines, or hosts you already have), checks that a second
run changes nothing, and runs your assertions.

> [!note] Partly tested
> Tested with Molecule 26.11.0 and `ansible` 15.0.0 (ansible-core 2.22) on openSUSE
> Leap 16, against an existing host over SSH. The Docker driver example is not
> tested: the test environment has no Docker and no `molecule-plugins`.

> [!note] Molecule 26
> `molecule init role` does not exist: create the role with `ansible-galaxy role init`,
> then add a scenario with `molecule init scenario`. A new scenario has no `driver`,
> `platforms`, `provisioner` or `verifier` section: it has an `ansible:` section, and
> you write `create.yml` and `destroy.yml` yourself, or use a driver plugin. There is
> no `lint:` (run `ansible-lint` yourself), the verifier is an Ansible playbook
> (`verify.yml`), and the playbook is `converge.yml`. Check `molecule --version` and
> the current [documentation](https://ansible.readthedocs.io/projects/molecule/).

## Creating a role and a scenario

Create the role with `ansible-galaxy`, then add a Molecule scenario from inside it:

```bash
ansible-galaxy role init my_first_role
cd my_first_role
molecule init scenario
```

Which adds:

```text
molecule
└── default
    ├── converge.yml
    ├── create.yml
    ├── destroy.yml
    ├── molecule.yml
    └── verify.yml
```

`default` is the name of your **scenario**. It contains:

- **molecule.yml** — the configuration of the scenario
- **create.yml** and **destroy.yml** — the playbooks that start and remove the test
  instances. The generated ones are empty templates.
- **converge.yml** — the playbook that runs your role on the instances
- **verify.yml** — the assertions to check afterwards

Compare with the plain role layout in
[[automation/ansible/roles#Creating a role]].

> [!warning] Molecule needs a namespace for the role
> Without one, Molecule stops with "Computed fully qualified role name of
> my_first_role does not follow current galaxy requirements". Add it to
> `meta/main.yml`, and call the role as `example.my_first_role` in `converge.yml`:
>
> ```yaml
> galaxy_info:
>   namespace: example
>   role_name: my_first_role
> ```

## The molecule.yml file

The generated file has these top-level sections:

| Key | Purpose |
| --- | --- |
| `dependency` | how dependencies are resolved — Ansible Galaxy, from `requirements.yml` |
| `ansible` | `ansible.cfg` settings, environment, the executor and its arguments, and which playbook runs at each step |
| `scenario` | the name and the `test_sequence` |

The simplest working setup uses a host you already have. Put it in an inventory
next to `molecule.yml`:

```yaml
# molecule/default/inventory.yml
all:
  hosts:
    instance:
      ansible_host: 192.0.2.10
      ansible_user: ansible
```

And point the executor at it, in place of the generated `/path/to/inventory.yml`:

```yaml
ansible:
  executor:
    backend: ansible-playbook
    args:
      ansible_playbook:
        - --diff
        - --force-handlers
        - --inventory=${MOLECULE_SCENARIO_DIRECTORY}/inventory.yml
```

The empty `create.yml` and `destroy.yml` then do nothing, and the tests run on that
host. The host name `instance` matters: the generated `verify.yml` targets
`hosts: instance`.

### Containers with the Docker driver

To create containers instead, install the driver plugin
(`pip install 'molecule-plugins[docker]'`) and describe the instances. This is the
older shape, still used with driver plugins. It is not tested here:

```yaml
---
driver:
  name: docker
platforms:
  - name: rocky9
    image: geerlingguy/docker-rockylinux9-ansible:latest
    pre_build_image: true
    command: /usr/lib/systemd/systemd
    cgroupns_mode: host
    privileged: true
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
    groups:
      - apache
```

> [!note] Why the systemd gymnastics
> If your role manages services — and most do — the container needs a running init
> system, or every `service` task fails. `command: systemd` plus the cgroup mount is
> the conventional way to get that. Images such as `geerlingguy/docker-*-ansible`
> ship pre-configured for exactly this. That family has no openSUSE image: for Leap,
> build an image with `systemd`, `python3` and `sudo` yourself.

Creating an extra scenario works the same way:

```bash
molecule init scenario opensuse
```

## Usage

### converge

From inside the role:

```bash
molecule converge
```

This runs the `default` scenario. These are equivalent:

```bash
molecule converge
molecule converge --scenario-name default
```

A scenario is an execution context for testing your role. Each one can carry
different variables — for example an `apache` role deploying a site for production
and pre-production:

```bash
molecule converge --scenario-name prod
```

`molecule test` runs the whole sequence from `molecule.yml`. With the role
installing one file, the output reads (shortened):

```text
INFO     [default > discovery] scenario test matrix: dependency, cleanup, destroy, syntax, create, prepare, converge, idempotence, side_effect, verify, cleanup, destroy
INFO     [default > converge] Executing
instance                   : ok=3    changed=1    unreachable=0    failed=0
INFO     [default > idempotence] Executing
instance                   : ok=3    changed=0    unreachable=0    failed=0
INFO     [default > idempotence] Executed: Successful
INFO     [default > verify] Executed: Successful
```

Scenario configuration reference:
[Molecule configuration](https://ansible.readthedocs.io/projects/molecule/configuration/).

### The other important commands

| Command | Purpose |
| --- | --- |
| `check` | dry-run of the role (`--check`) |
| `cleanup` | run the `cleanup.yml` playbook, if there is one |
| `converge` | run your role against the instances |
| `create` | start the instances |
| `dependency` | resolve the role's dependencies |
| `destroy` | tear the instances down |
| `idempotence` | run the role again and fail if anything changes |
| `init` | add a scenario |
| `list` | show instance status |
| `login` | shell into an instance |
| `prepare` | run `prepare.yml`, to set up instances before the role |
| `side-effect` | run `side_effect.yml`, for example to restart a service between converge and verify |
| `syntax` | check the role's syntax |
| `verify` | run the verifier's assertions |
| `test` | run the full sequence |

`molecule test` is the one that matters in CI: it creates, converges, **converges a
second time to prove idempotence**, verifies, and destroys. `molecule converge` is
what you use while iterating, because it leaves the instance running.

> [!tip] Keep the instance when something fails
> `molecule test` destroys everything at the end, which makes debugging hard. Use
> `molecule test --destroy=never`, or `molecule converge` followed by
> `molecule login`, to inspect the broken state.

## Verifying with the ansible verifier

`verify.yml` is an ordinary playbook using `assert`:

```yaml
---
- name: Verify
  hosts: all
  gather_facts: false
  tasks:
    - name: Check that httpd is installed
      ansible.builtin.package_facts:

    - name: Assert httpd present
      ansible.builtin.assert:
        that:
          - "'httpd' in ansible_facts.packages"
        fail_msg: httpd was not installed

    - name: Check the service is running
      ansible.builtin.service_facts:

    - name: Assert httpd running
      ansible.builtin.assert:
        that:
          - ansible_facts.services['httpd.service'].state == 'running'
```

On openSUSE the package and the service are both `apache2`.

See [[automation/ansible/best-practices]] for where Molecule fits into a project
layout.

<!-- uplink -->
Part of [[automation/ansible/index|Ansible]].
