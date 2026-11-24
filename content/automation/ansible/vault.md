---
title: Ansible Vault
description: Encrypting files and individual values with Ansible Vault, managing the master password, and using vault-ids per environment
tags: [automation, ansible, vault, secrets, security]
type: howto
status: complete
---

# Ansible Vault

Ansible Vault encrypts values or whole files. It is a robust safe, using the AES256
cipher.

Vault needs the Python `cryptography` package. pip installs it with `ansible-core`.

> [!note] Tested
> Tested with `ansible` 15.0.0 (ansible-core 2.22) on openSUSE Leap 16.

> [!note] `cryptography` is required
> There is no pure-Python fallback: without `cryptography`, `ansible-vault` stops with
> "requires the cryptography library".

## Managing the master password

To work with secrets you can be prompted for a password every time:

```bash
ansible-vault encrypt secret-vars.yml
```

Or use a file containing the password in clear text:

```bash
ansible-vault encrypt secret-vars.yml --vault-password-file very_secret_password_file
```

> [!warning] A password file is a plaintext secret on disk
> Give it `600` permissions, keep it out of the repository, and add it to
> `.gitignore`. Better still, make it an *executable* script that fetches the
> password from a secret manager and prints it on stdout — Ansible accepts that in
> place of a plain file, which keeps the secret out of the filesystem entirely.

Change the password:

```bash
ansible-vault rekey secret-vars.yml \
  --vault-password-file very_secret_password_file \
  --new-vault-password-file stronger_secret_password_file
```

## Encrypting a file

Create an encrypted file:

```bash
ansible-vault create secret-vars.yml
```

`create` opens your editor (`$EDITOR`), so it needs a terminal. Without one it
stops with "not a tty, editor cannot be opened".

Encrypt an existing file:

```bash
ansible-vault encrypt secret-vars.yml
```

View an encrypted file:

```bash
ansible-vault view secret-vars.yml
```

## Editing and decrypting

Edit an encrypted file in place:

```bash
ansible-vault edit secret-vars.yml
```

Decrypt it permanently:

```bash
ansible-vault decrypt secret-vars.yml
```

> [!important] `edit` rather than `decrypt` then `encrypt`
> `edit` decrypts to a temporary file, opens your editor, and re-encrypts on save.
> The decrypt/encrypt round trip leaves the plaintext on disk in the meantime, and
> is a reliable way to eventually commit a secret by accident.

## Encrypting a single value

```console
$ ansible-vault encrypt_string 'mysql_unbreakable_password' --name 'mysql_admin_password'

mysql_admin_password: !vault |
          $ANSIBLE_VAULT;1.1;AES256
          39313730306330396164303132333234393839363865383630626366396665333464393065373234
          3839616130316364356665313534396237393437633434330a333265656635616436613764346133
          62396434306438646565633361373763643737633834333839373438393661613863393436343462
          3130396632373366620a386564333233623235343435666636383737666332303137663261393565
          37373730313364346430633565396434326365616633366464646463343833643738
```

ansible-core 2.22 prints no `Encryption successful` line.

This lets you build a file of encrypted variables that stays more workable than a
fully encrypted vault — the file remains readable YAML and diffs sensibly, with only
the secret values opaque.

> [!warning] The value appears in your shell history
> Passing the secret as an argument records it in `~/.bash_history` and makes it
> visible in `ps`. Omit the value and `encrypt_string` will read it from stdin
> instead:
> `ansible-vault encrypt_string --stdin-name 'mysql_admin_password'`

## Vault IDs

A useful Vault feature is **vault-ids**. You can share variables across different
environments (dev, prod, int), each with its own password. Use `--vault-id` and
specify how the password is supplied — a password file, or typed in with `@prompt`:

```bash
ansible-vault create --vault-id prod@very_secret_password_file secret-vars-prod.yml
ansible-vault create --vault-id dev@prompt secret-vars-dev.yml
```

## Running playbooks with vaults

```bash
ansible-playbook site.yml --ask-vault-pass
ansible-playbook site.yml --vault-password-file very_secret_password_file
ansible-playbook site.yml --vault-id prod@prompt
```

Several vault-ids can be supplied at once, which is how you run a playbook that
mixes secrets from more than one environment:

```bash
ansible-playbook site.yml --vault-id dev@prompt --vault-id prod@prompt
```

## What Vault does not do

> [!note] Encryption at rest only
> Vault protects secrets in your repository. At runtime, ansible-core 2.22 masks a
> vaulted value in its output: `debug`, `cmd` and `stdout` show `$REDACTED$`. The
> mask matches the exact string only. The same value through a filter
> (`{{ db_password | upper }}`) prints in clear, and a rendered template holds the
> plain value on the target. Mark tasks handling secrets with `no_log: true`.
>
> It also has no rotation, no audit trail and no per-user access control. Where those
> matter, keep the secrets in a dedicated manager — HashiCorp Vault, AWS Secrets
> Manager, or the `community.hashi_vault` lookup — and let Ansible read them at run
> time. See vaultwarden-docker for the unrelated but similarly named
> password manager.

> [!note] Output masking
> Since ansible-core 2.22, the exact decrypted value is masked in task output, but
> changed copies of it are not.

## Where to go next

- [[automation/ansible/best-practices]] — where vault files belong in a project
  layout
- [[security/security-roadmap]] — where secrets management sits among the other
  controls, and why "encrypted at rest in Git" is a starting point rather than an
  answer
- [[kubernetes/configuration/sealed-secrets]] — the same problem one layer up:
  committing an encrypted secret to Git so the cluster, and only the cluster, can
  decrypt it
- [[security/cryptography/openssl/commands]] — Vault is AES-256-CTR with a key derived by PBKDF2;
  this is the toolbox for inspecting what that produced

<!-- uplink -->
Part of [[automation/ansible/index|Ansible]].
