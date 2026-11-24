---
title: SSH
description: Key-based authentication, testing sshd configuration, and per-host client config
tags: [linux, ssh, security, networking]
type: howto
status: complete
---

# SSH tips

## Passwordless login with a key pair

Generate a key pair. `ed25519` is the default type since OpenSSH 9.5, and is
preferred over RSA: shorter keys, faster, and no key-size decision to get wrong:

```bash
ssh-keygen -t ed25519 -C "your.name@example.com"
```

If you need RSA for an old server that does not support Ed25519:

```bash
ssh-keygen -t rsa -b 4096
```

Copy the public key to the target server:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub your.name@192.168.1.100
```

This appends it to `~/.ssh/authorized_keys` on the remote host. Without `-i`,
`ssh-copy-id` copies the newest `~/.ssh/id*.pub` file, which is not always the key
you mean when you have several. If `ssh-copy-id`
is not available, do it by hand:

```bash
cat ~/.ssh/id_ed25519.pub | ssh your.name@192.168.1.100 \
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

> [!note] The account must already exist on the server
> Key-based login replaces the password prompt; it does not create the user. The
> account has to exist on every host you want to reach this way.

## Testing the sshd configuration

Check the config file for syntax errors — do this **before** restarting `sshd`,
or you can lock yourself out:

```bash
sshd -t
```

Dump the full effective configuration, with every default resolved:

```bash
sshd -T
```

On openSUSE Leap 16 the default file is `/usr/etc/ssh/sshd_config`, and
`/etc/ssh/sshd_config` does not exist. Put your changes in a drop-in file such as
`/etc/ssh/sshd_config.d/50-local.conf`; `sshd -t` checks those too.

See config-validation for the equivalent check on other daemons.

## Client configuration

`~/.ssh/config` lets you name a host once and stop repeating its parameters:

```text
Host webserver
    HostName web-01.example.com
    User your.name
    Port 2222
    IdentityFile ~/.ssh/id_ed25519_webserver
```

Then simply:

```bash
ssh webserver
```

Patterns and defaults work too — this applies to every host, and must come last
because the first matching value wins:

```text
Host *
    ServerAliveInterval 60
    AddKeysToAgent yes
```

<!-- uplink -->
Part of [[linux/index|Linux]].
