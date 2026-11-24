---
title: Ansible variables, loops, conditions and templates
description: Declaring and using variables, precedence, lists and dictionaries, loops, conditions, filters, inclusion and Jinja2 templates
tags: [automation, ansible, variables, jinja2, templates, loops]
type: reference
status: complete
---

# Variables, loops, conditions and templates

> [!note] Partly tested
> Tested with `ansible` 15.0.0 (ansible-core 2.22) on openSUSE Leap 16. The Red Hat
> package tasks ran against a stub module in place of `dnf`. That file tests run on
> the control node is not tested: there, the control node and the target were the
> same machine.

## Declaring variables

As key/value pairs in a playbook:

```yaml
---
- hosts: apache
  vars:
    http_port: 80
    https_port: 443
```

Or as a list:

```yaml
---
- hosts: apache
  vars:
    apache_ports:
      - protocol: http
        port: 80
      - protocol: https
        port: 443
```

Dictionaries are preferable when the code requires them, but note you cannot change
a value inside a dictionary mid-run. If you must, read the whole dictionary and
rewrite it:

```yaml
package:
  name: httpd
  state: present
  enablerepo: testing
```

A list of dictionaries containing a list:

```yaml
- apache:
    name: httpd
    state: latest
    modules:
      - mod_expires
      - mod_http2
      - mod_ssl
```

A dictionary driving a loop:

```yaml
vars:
  required_package:
    apache:
      package: httpd
      state: latest
    mysql:
      package: mysql-server
      state: latest

tasks:
  - name: Install required packages
    ansible.builtin.dnf:
      name: "{{ item.value.package }}"
      state: "{{ item.value.state }}"
    loop: "{{ required_package | dict2items }}"
```

To reuse the dictionary key — `apache` or `mysql` here — use `{{ item.key }}`.

### Variables in the inventory

Variables can be defined in the inventory file, as *hostvars*:

```ini
[apache_pub]
svr-apache-01       http_port=80

[apache_pub:vars]
protocol=http

[apache_admin]
svr-apache-02       http_port=443 protocol=https
```

> [!warning] Avoid this
> Inline inventory variables are hard to read, impossible to comment usefully, and
> mix "which hosts exist" with "how they are configured". Put them in `group_vars/`
> and `host_vars/` files instead, which are YAML, reviewable, and can be encrypted
> with [[automation/ansible/vault|Vault]]:
>
> ```text
> inventory/
> ├── hosts
> ├── group_vars/
> │   ├── all.yml
> │   └── apache_pub.yml
> └── host_vars/
>     └── svr-apache-01.yml
> ```
>
> See [[automation/ansible/best-practices]].

## Using variables

The syntax is `"{{ http_port }}"`.

For a value indexed in a list, say which element: `"{{ apache_ports[0] }}"` —
which returns the whole entry, `{ protocol: http, port: 80 }`. For just one field:
`"{{ apache_ports[0].protocol }}"`.

To check you are using the right value, use the `debug` module, ad-hoc or in a
playbook:

```bash
ansible apache -m debug -a 'msg="var={{ http_port }}"'
```

```yaml
---
- hosts: apache
  tasks:
    - name: Debug the http port
      ansible.builtin.debug:
        msg: "The listening port is {{ http_port }}"
```

### Variable precedence

Lowest to highest — later entries win:

1. command line values (for example `-u user`)
2. role defaults (`role/defaults/main.yml`)
3. inventory file or script group vars
4. inventory `group_vars/all`
5. playbook `group_vars/all`
6. inventory `group_vars/*`
7. playbook `group_vars/*`
8. inventory file or script host vars
9. inventory `host_vars/*`
10. playbook `host_vars/*`
11. host facts and cached `set_fact`
12. play vars
13. play `vars_prompt`
14. play `vars_files`
15. role vars (`role/vars/main.yml`)
16. block vars (for tasks in the block only)
17. task vars (for that task only)
18. `include_vars`
19. `set_fact` / registered vars
20. role and `include_role` params
21. `include` params
22. extra vars (`-e`) — **always wins**

> [!tip] The two ends are the ones to remember
> `defaults/` is the lowest precedence, which is exactly why role defaults belong
> there — they are meant to be overridden. `-e` beats everything, which makes it the
> right tool for a one-off override and the wrong one for anything permanent.

## Lists and dictionaries

### Lists

A list is a structured data type, writable two ways:

```yaml
fruit: [apple, banana, orange, grapes]

fruit:
  - apple
  - banana
  - orange
  - grapes
```

Each element is reachable by index:

```yaml
---
- name: Lists demo
  hosts: localhost
  tasks:
    - name: Create list
      ansible.builtin.set_fact:
        fruit: [apple, banana, orange, grapes]

    - name: Show first element
      ansible.builtin.debug:
        msg: "{{ fruit[0] }}"

    - name: Show second element
      ansible.builtin.debug:
        msg: "{{ fruit[1] }}"
```

```text
TASK [Show first element] ******************************************************
ok: [localhost] =>
    msg: apple

TASK [Show second element] *****************************************************
ok: [localhost] =>
    msg: banana
```

A more complex list:

```yaml
---
- hosts: apache
  become: true
  tasks:
    - name: Install packages
      ansible.builtin.dnf:
        name: "{{ item.name }}"
        state: "{{ item.state }}"
      loop:
        - { name: 'httpd', state: 'present' }
        - { name: 'php',   state: 'present' }
```

### Dictionaries

Also writable two ways:

```yaml
shopping: { name: "tomato", fruit: true }

shopping:
  name: "tomato"
  fruit: true
```

Driving a loop from one:

```yaml
---
- hosts: apache
  become: true
  vars:
    packages:
      - name: httpd
        state: present
      - name: php
        state: present
  tasks:
    - name: Install packages
      ansible.builtin.dnf:
        name: "{{ item.name }}"
        state: "{{ item.state }}"
      loop: "{{ packages }}"
```

And reading an attribute:

```yaml
---
- name: Dict demo
  hosts: localhost
  tasks:
    - name: Create dict
      ansible.builtin.set_fact:
        shopping:
          name: "tomato"
          fruit: true

    - name: Show shopping
      ansible.builtin.debug:
        msg: "{{ shopping.name }}"
```

```text
TASK [Show shopping] ***********************************************************
ok: [localhost] =>
    msg: tomato
```

## Loops

Ansible 2.5 added `loop`, and the documentation now recommends it over `with_*`.

> [!note] `with_*` still works
> `with_items` and the other `with_*` loops still run in ansible-core 2.22, with no
> deprecation warning. Prefer `loop` in new code.

Installing Apache and PHP from a simple list:

```yaml
- hosts: apache
  become: true
  tasks:
    - name: Install packages
      ansible.builtin.dnf:
        name: "{{ item }}"
        state: present
      loop:
        - httpd
        - php
```

Because `item` is not descriptive when loops nest, `loop_control` can rename it:

```yaml
- hosts: apache
  become: true
  tasks:
    - name: Install packages
      ansible.builtin.dnf:
        name: "{{ package_name }}"
        state: present
      loop:
        - httpd
        - php
      loop_control:
        loop_var: package_name
```

This is what makes it possible to loop inside a loop with `include_tasks`.

> [!tip] Most package modules take a list directly
> `name: "{{ packages }}"` installs everything in one transaction, where a `loop`
> runs the module once per package. For `dnf`, `apt` and `zypper` the list form is
> dramatically faster and resolves dependencies as a set.

## Conditions

Conditioning a task, here on a fact:

```yaml
- name: Install required packages
  ansible.builtin.dnf:
    name: httpd
    state: present
  when: ansible_os_family == 'RedHat'
```

```yaml
- name: Install required packages
  ansible.builtin.dnf:
    name: httpd
    state: present
  when:
    - ansible_python.version.major >= 3
    - ansible_python.version.minor >= 2
```

> [!note] Comparing versions
> Compare these to integers, not to the *strings* `'3'` and `'2'`. Version components
> are integers, and string comparison gives wrong answers — `'10' < '9'`. For
> full version comparison use the `version` test:
> `when: ansible_distribution_version is version('8.0', '>=')`
>
> A `when:` given a **list** ANDs the conditions, which is more readable than
> `and`.

### Operators

| Symbol | Word form |
| --- | --- |
| `<` | `lt` |
| `<=` | `le` |
| `>` | `gt` |
| `>=` | `ge` |
| `==` | `eq` |
| `!=` | `ne` |

### Conditions with search and match

`match` anchors at the start of the string; `search` matches anywhere. Both take
regular expressions:

```yaml
- name: Install required packages
  ansible.builtin.dnf:
    name: httpd
    state: present
  when: ansible_os_family is match("RedHat")
```

```yaml
  when: ansible_os_family is search("Hat")
```

```yaml
  when: ansible_os_family is search("Red.*t")
```

### Conditions testing files

```yaml
- name: Install required packages
  ansible.builtin.dnf:
    name: httpd
    state: present
  when: "'/opt/nfs' is mount"
```

Available tests: `directory`, `file`, `link`, `exists`, `mount`.

> [!warning] These test the control node, not the target
> Jinja2 file tests are evaluated where the template is rendered — on the machine
> running Ansible. To test a path on the managed host, use the `stat` module and
> register the result:
>
> ```yaml
> - name: Check for the mount
>   ansible.builtin.stat:
>     path: /opt/nfs
>   register: nfs
>
> - name: Do the thing
>   ansible.builtin.dnf:
>     name: httpd
>   when: nfs.stat.exists
> ```
>
> The test is `exists`, not `exist`.

## Filters

Filters transform variables and are introduced by a pipe `|`:

`| bool` · `| lower` · `| upper` · `| int` · `| float` · `| trim` ·
`| length` · `| unique` · `| join(',') ` · `| to_json` · `| from_json` ·
`| b64encode` · `| basename` · `| dirname`

Some filters act on the variable's presence rather than its value — `default`:

```yaml
"{{ package.state | default('present') }}"
```

If the variable is not defined, a default value or another variable is used.
`default(omit)` is the special case worth knowing: it drops the parameter entirely,
letting the module apply its own default.

## Inclusion

Files can be included to avoid repeating information or tasks. You can include:

- playbooks
- tasks
- vars

Two forms exist, and the difference is subtle: one is static, the other dynamic.

| Form | Timing | Behaviour |
| --- | --- | --- |
| `import_*` | static, at playbook parse time | the parent task's options are copied to every child task |
| `include_*` | dynamic, at task execution time | the parent's options apply only to the dynamic task |

Dynamic inclusion is therefore the interesting one for loops: the included item is
processed once per loop element.

> [!note] The practical consequences
> Because `import_*` is resolved at parse time it cannot be used with `loop`, and
> tags apply to every imported task. Because `include_*` is resolved at runtime,
> `--list-tasks` cannot see inside it, and neither can `--start-at-task`.

Splitting the work up also lets you run and test each small playbook individually.
And some playbooks can be run by particular users — playbooks installing
infrastructure software or middleware run as a user able to obtain root, while
purely application playbooks run as application service accounts.

## Templates

Templates are files written in **Jinja2** that build files from variables:

```jinja
<VirtualHost *:{{ http_port }}>
  ServerAdmin webmaster@localhost
  ServerName {{ http_site_name }}
  DocumentRoot {{ http_site_path }}
  ErrorLog ${APACHE_LOG_DIR}/error.log
  CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
```

Use one in a playbook:

```yaml
---
- name: Configure the apache vhost
  ansible.builtin.template:
    src: vhost.conf.j2
    dest: /etc/httpd/sites-available/vhosts.conf
    validate: 'apachectl -t -f %s'
  notify: restart apache
```

`validate:` runs a check on the rendered file *before* installing it, so a broken
template cannot take the service down.

> [!warning] `apachectl -t -f` needs a whole config
> `apachectl -t -f %s` reads the file as the full server configuration. A file with
> only a `<VirtualHost>` block fails that check, so this `validate:` rejects the vhost
> above. Use `validate: 'apachectl -t -f %s'` for the main `httpd.conf`. For a vhost
> file, run `apachectl -t` in a task after the copy, or in the handler before the
> restart. On openSUSE, `apachectl` is in the `apache2-utils` package.
> `${APACHE_LOG_DIR}` and `sites-available/` are Debian conventions; Red Hat uses
> `/var/log/httpd` and `/etc/httpd/conf.d/`. See [[servers/config-validation]].

### Loops in templates

Given a list of sites:

```yaml
sites: [blog.lab, wiki.lab, chat.lab]
```

The template:

```jinja
{% for website in sites %}
<VirtualHost *:80>
  ServerName {{ website }}
  ServerAdmin webmaster@localhost
  DocumentRoot /var/www/html/{{ website }}
  ErrorLog ${APACHE_LOG_DIR}/error-{{ website }}.log
  CustomLog ${APACHE_LOG_DIR}/access-{{ website }}.log combined
</VirtualHost>
{% endfor %}
```

The `VirtualHost` block is repeated for each entry in the list.

> [!tip] Control whitespace
> The `template` module turns on Jinja's `trim_blocks`, so the newline after a
> `{% %}` tag is removed and no blank line is left. Spaces *before* an indented tag
> stay. `{%- for ... -%}` strips the whitespace around the tag, newlines included,
> which matters for config file formats that care.

> [!note] No blank lines in Ansible templates
> Plain Jinja leaves a blank line where a tag stood, but Ansible's `template` module
> sets `trim_blocks`, so it does not happen there.

<!-- uplink -->
Part of [[automation/ansible/index|Ansible]].
