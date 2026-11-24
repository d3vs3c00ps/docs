---
title: ConfMap
description: Visualising YAML and JSON configuration as a mind map with ConfMap, and the daemon tools that show the effective nginx, Apache or sshd configuration
tags: [linux, cli, configuration, visualisation, troubleshooting]
type: reference
status: complete
---

# ConfMap

[ConfMap](https://github.com/AKSarav/ConfMap) renders a YAML or JSON file as an
interactive mind map, so nested keys and their relationships are visible at a
glance. It is a web page: use the hosted copy at <https://confmap.com>, or run it
locally from a clone of the repository.

```bash
git clone https://github.com/AKSarav/ConfMap.git
cd ConfMap
npm install
npm run dev
```

> [!warning] ConfMap is a browser tool for YAML and JSON only
> ConfMap has no command-line tool and reads only YAML and JSON. The `confmap` package
> on PyPI is an unrelated project (conformal mapping of images). For nginx and
> Apache, use the daemons' own tools below.

> [!warning] Do not upload secrets
> The hosted version is a third-party site. Remove passwords, tokens and keys from
> a file before you open it there, or run ConfMap locally.

## What it is for

Arriving at an unfamiliar system and needing to answer "what is this actually
configured to do?" — before changing anything. Typical inputs: a Helm
`values.yaml`, a Kubernetes manifest, a Docker Compose file, an Ansible inventory, a
JSON API response.

The map makes three things obvious that reading the file does not:

- **Nesting depth.** A key five levels down, under a list item, inside a map.
- **Repetition.** The same setting in four places, with one differing.
- **Structure versus content.** You see the shape before drowning in values.

> [!important] It shows one file, not the effective configuration
> ConfMap parses what you give it. It knows nothing about how a program merges
> files, defaults and overrides.

## The effective configuration of a daemon

A production nginx configuration is rarely one file. It is a main file, a
`conf.d/*.conf` glob, a `sites-enabled/` directory of symlinks, and several
`include` directives — and the effective configuration is the union, evaluated in an
order that is not obvious from any single file.

For the configuration a daemon is **actually** running, use the daemon's own tools —
which is always the authoritative answer:

```bash
nginx -T                       # full effective config, includes expanded
apachectl -S                   # virtual host resolution
sshd -T                        # every effective sshd option
haproxy -c -f /etc/haproxy/haproxy.cfg
```

`nginx -T` in particular is the command worth remembering. It prints every file that
contributes, in the order nginx read them, each under a `# configuration file`
comment. That answers "where is this setting coming from?" definitively.

## A practical workflow

```bash
# 1. What is the daemon actually running?
sudo nginx -T > effective.conf

# 2. Find where a setting comes from
grep -nE '^# configuration file|server_name|listen' effective.conf

# 3. Confirm a change before applying it
sudo nginx -t
sudo systemctl reload nginx
```

For YAML, the same idea: render the final document first (`helm template`,
`kubectl get -o yaml`, `docker compose config`), then open that in ConfMap.

## Validating without a visualiser

Most of the time, the built-in checks answer the question faster:

```bash
nginx -t                                       # syntax
apachectl configtest
sshd -t
named-checkconf
visudo -c
python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' file.yaml
yq . file.yaml                                 # parse and pretty-print
jq . file.json
```

On openSUSE Leap 16, `apachectl` comes with the `apache2-utils` package. There,
`visudo -c` stops with `/usr/etc/sudoers: bad permissions, should be mode 0440`,
because the package ships that file with mode 0444. Check your own files instead:
`visudo -cf /etc/sudoers.d/<file>`.

See config-validation, which collects these per daemon.

> [!tip] Validate before reloading, always
> `nginx -t && systemctl reload nginx` is the pattern. A reload with a broken
> configuration leaves nginx running the old one — recoverable — but a **restart**
> with a broken configuration leaves you with nothing listening.
>
> The distinction matters most on the machine you are connected to. See
> [[linux/boot/systemd]].

## Where a diagram genuinely helps

Configuration visualisation is most useful when the structure itself is the problem
rather than any individual value:

- Deeply nested YAML, where indentation errors change meaning silently. See
  yaml.
- Large Helm values files and JSON documents, where you need the shape first.
- Firewall rulesets, where traffic-visualisation does the same job for
  iptables.

For nginx and Apache, `nginx -T`, `apachectl -S` and `grep` are faster.

## Where to go next

- [[servers/config-validation]] — per-daemon syntax checking
- [[networking/traffic-visualisation]] — the same idea for firewall rules
- [[dev/yaml]] — the format most likely to bite you
- [[servers/nginx]] · [[servers/apache]] — the configurations in question

<!-- uplink -->
Part of [[linux/cli/index|Command line tools]].
