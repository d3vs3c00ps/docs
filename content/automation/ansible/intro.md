---
title: Ansible concepts
description: What Ansible is, its philosophy and vocabulary, and the YAML rules its playbooks follow
tags: [automation, ansible, configuration-management, yaml]
type: concept
status: complete
---

# Ansible concepts

Ansible centralises and automates administration tasks. It is:

- **Agentless** — it uses SSH connections (by password or key) or WinRM.
- **Idempotent** — every run produces the same result.
- **Portable** — no server is required.
- **Declarative** — oriented around the *state to reach*.

## Philosophy

- Complexity harms productivity.
- Ansible is a toolbox, not a language.
- Think declaratively. By design Ansible lets you describe a state to reach. If you
  code *how* to reach that state instead of letting Ansible do it, you have lost.

## Capabilities

- Orchestration
- Provisioning
- Automation
- Configuration management
- Push-based (stateless)

## Vocabulary

| Term | Meaning |
| --- | --- |
| **Inventory** | a file listing the managed servers |
| **Task** | a block defining a procedure to run — a call to an Ansible module |
| **Module** | an abstraction over a task |
| **Playbook** | a YAML file defining the target servers and the tasks to perform |
| **Play** | one mapping of hosts to tasks inside a playbook |
| **Role** | atomic, reusable code performing one coherent job |
| **Facts** | variables holding information gathered about a system |
| **Handler** | a task triggered only when something actually changed |
| **Collection** | a packaged distribution of modules, roles and plugins |

## YAML

YAML is a simple format, but it has rules:

- Indentation is significant and mandatory — spaces only, never tabs.
- A document conventionally begins with `---`.
- Strings containing `{{ }}` must be quoted, or YAML reads them as a dictionary.

> [!note] No `...` needed
> `...` is the optional *end of document* marker in YAML, needed only when several
> documents share one stream. Playbooks almost never use it.

> [!tip] The quoting rule catches everyone once
> `msg: {{ var }}` is invalid YAML, because `{` starts a flow mapping. It has to be
> `msg: "{{ var }}"`.

## Where to go next

- [[automation/ansible/installation]] — installing and configuring Ansible
- [[automation/ansible/inventory]] — describing your hosts, connections and facts
- [[automation/ansible/modules]] — modules and ad-hoc commands
- [[automation/ansible/playbooks]] — tasks, blocks, handlers, execution control
- [[automation/ansible/variables]] — variables, loops, conditions, templates
- [[automation/ansible/roles]] — roles, Galaxy, collections
- [[automation/ansible/vault]] — secrets
- [[automation/ansible/best-practices]] — project layout and naming conventions
- [[automation/ansible/cheatsheet]] — command reference
- [[automation/ansible/molecule]] — testing roles

## Projects

A *project* is not an Ansible concept, but a coherent whole that accomplishes a
defined complex task — for example deploying and maintaining a complex application
across a set of systems.

A project may contain several playbooks, master playbooks, roles and inventories,
and may reference roles, playbooks and files outside itself, held in different
source control repositories.

A project usually corresponds to one repository in source control, and usually to
one application or one type of application.

<!-- uplink -->
Part of [[automation/ansible/index|Ansible]].
