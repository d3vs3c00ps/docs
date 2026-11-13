---
title: "Secrets with sops-nix"
description: "Encrypted secrets in the configuration repository — age keys derived from SSH keys, decryption at activation into /run/secrets, and what the host key being the root of trust implies"
tags: [linux, nixos, sops, secrets, security, age]
type: howto
status: complete
---

# Secrets with sops-nix

## The problem

Everything the Nix store builds is world-readable, forever. A password written into
`configuration.nix` ends up in `/nix/store`, in the Git history, and on every
machine that ever built or cached that configuration — see
[[linux/distributions/nixos/server#Secrets|the server note]] for the failure mode.
So secrets must live *outside* the evaluated configuration, yet a declarative
system wants them versioned and deployed together with everything else.

[sops-nix](https://github.com/Mic92/sops-nix) resolves the tension with three
pieces:

- **[sops](https://github.com/getsops/sops)** encrypts the *values* of a
  YAML/JSON/ini/dotenv file while keeping the keys readable, so an encrypted file
  still diffs and reviews sensibly in Git.
- **[age](https://github.com/FiloSottile/age)** is the encryption backend — small,
  modern, no GPG ceremony. Its killer feature here:
  [ssh-to-age](https://github.com/Mic92/ssh-to-age) converts Ed25519 SSH keys to
  age keys, so **existing SSH keys are the identities**. Your admin key encrypts;
  each host's `/etc/ssh/ssh_host_ed25519_key` decrypts. Nothing new to generate,
  distribute, or back up.
- **The sops-nix NixOS module** decrypts the declared secrets at activation time
  into `/run/secrets/` (a tmpfs — never on disk) with the owner and mode you
  declare, and gives you `config.sops.secrets.<name>.path` to hand to services.

The encrypted files are committed; the repository can be public. A machine can
decrypt exactly the secrets encrypted to its host key, and nobody else's.

[agenix](https://github.com/ryantm/agenix) is the lighter alternative with the
same model (one opaque encrypted file per secret, no partial-file encryption, no
templates). This note covers sops-nix; the concepts transfer.

## Implementation

### Keys

Derive an age recipient from your own SSH key and from each host's key:

```bash
# You (the editor) — needs the *private* key to also derive the decryption half
nix run nixpkgs#ssh-to-age -- -private-key \
  -i ~/.ssh/id_ed25519 > ~/.config/sops/age/keys.txt

# Your public recipient (what goes into .sops.yaml)
ssh-to-age < ~/.ssh/id_ed25519.pub

# A host's recipient, without logging in
ssh-keyscan -t ed25519 web-01 | ssh-to-age
```

`~/.config/sops/age/keys.txt` is where the `sops` CLI looks for decryption keys by
default. The hosts need nothing: their SSH host key already exists.

### `.sops.yaml`

This file tells the `sops` CLI which recipients encrypt which files:

```yaml
keys:
  - &admin age1admin...
  - &web-01 age1web01...
  - &db-01 age1db01...

creation_rules:
  - path_regex: secrets/common\.yaml$
    key_groups:
      - age: [*admin, *web-01, *db-01]
  - path_regex: secrets/web-01\.yaml$
    key_groups:
      - age: [*admin, *web-01]
```

One file per host plus a `common.yaml` is the layout that keeps the blast radius
small — see [[#A compromised host decrypts everything it was ever sent|below]] for
why per-host files matter.

```bash
sops secrets/web-01.yaml       # opens $EDITOR on the decrypted content
```

On save, sops encrypts every value and leaves the keys readable:

```yaml
db:
  password: ENC[AES256_GCM,data:kV7...,tag:Hqw...,type:str]
sops:
  age: [...]
  lastmodified: "2026-11-13T..."
  mac: ENC[AES256_GCM,...]
```

### The NixOS side

```nix
# flake.nix
inputs.sops-nix = {
  url = "github:Mic92/sops-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
# ...and sops-nix.nixosModules.sops in the host's module list
```

```nix
# configuration.nix
{
  sops = {
    defaultSopsFile = ./secrets/web-01.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    secrets."db/password" = {
      owner = "myapp";
      mode = "0400";
      restartUnits = [ "myapp.service" ];
    };
  };
}
```

`"db/password"` addresses the nested YAML key. After a rebuild the plaintext is at
`/run/secrets/db/password`, owned `myapp`, mode `0400`, and `myapp.service`
restarts whenever the secret's content changes — without `restartUnits`, a rotated
secret is silently not picked up until the service restarts for some other reason.

### Consuming secrets

Services take the *path*, never the value — the value must not pass through the
Nix evaluation:

```nix
services.grafana.settings.database.password = "$__file{${config.sops.secrets."db/password".path}}";

# Or for your own units — LoadCredential is the cleanest primitive:
systemd.services.myapp.serviceConfig.LoadCredential =
  "db-password:${config.sops.secrets."db/password".path}";
```

> [!warning] `EnvironmentFile` expects `NAME=value` lines
> A file containing a bare password sets no variable. Either store the secret as
> `DB_PASSWORD=...` in the sops file, or use `LoadCredential` and read
> `$CREDENTIALS_DIRECTORY/db-password`.

When a config file mixes secrets with non-secret settings, **templates** render
the whole file at activation instead of forcing you to encrypt all of it:

```nix
sops.templates."myapp.conf".content = ''
  listen = 0.0.0.0:8080
  db_password = ${config.sops.placeholder."db/password"}
'';
# reference config.sops.templates."myapp.conf".path from the service
```

The placeholder is an inert token at evaluation time; substitution happens on the
host, so the plaintext still never enters the store.

### Secrets needed before activation

User password hashes are consumed by the activation script itself, earlier than
normal secrets exist:

```nix
sops.secrets."alice-password".neededForUsers = true;
users.users.alice.hashedPasswordFile = config.sops.secrets."alice-password".path;
```

`neededForUsers` secrets land in a separate, earlier phase (under
`/run/secrets-for-users/`) and are readable only by root.

## Deep dive: what activation actually does

The module wires `sops-install-secrets` into system activation. On every
`nixos-rebuild switch` and every boot it:

1. Reads the host's SSH private key and converts it to an age identity in memory
   (`ssh-to-age` logic built in).
2. Decrypts each declared secret from the (store-resident, encrypted) sops file
   and verifies the file's MAC — a tampered encrypted file fails activation
   rather than installing garbage.
3. Writes the plaintexts into a **new generation directory**
   `/run/secrets.d/<n>/`, applies owner and mode, then atomically flips the
   `/run/secrets` symlink to it. Readers see either the old set or the new set,
   never a half-written file — the same generation-and-symlink trick as
   `/nix/var/nix/profiles`.
4. Compares content hashes against the previous generation and restarts or
   reloads the units listed in `restartUnits` / `reloadUnits` for the secrets
   that changed.

Two consequences worth internalizing:

- `/run` is a tmpfs: plaintext secrets exist **only in RAM** and vanish at
  power-off. Nothing to wipe on disk.
- The *encrypted* sops file is copied into the Nix store (it is part of the
  configuration). That is fine — it is ciphertext — but it means old encrypted
  versions linger in the store and in Git history for as long as those exist.

### Rotation and rekeying are different operations

```bash
# New machine, or a removed admin: recipients changed → re-encrypt the data key
sops updatekeys secrets/web-01.yaml
```

`updatekeys` re-wraps the file's data key for the current recipient set. It does
**not** change the secrets, and it does not rewrite history: a recipient you
removed could still decrypt every version they were ever able to read from Git.
Removing a person or a compromised host therefore means **rotating the secret
values themselves**, not just rekeying the file.

## Security concerns and hardening

### The host key is the root of trust

Whoever reads `/etc/ssh/ssh_host_ed25519_key` decrypts everything encrypted to
that host — including every historical version in Git. That key is readable only
by root, so the honest statement is: **sops-nix protects secrets at rest and in
the repository, not against root on the target host**. Root can read
`/run/secrets` directly anyway; that is the wrong threat to defend against here.

What follows from it:

- **Protect the host key like the secret it is.** With
  [[linux/distributions/nixos/disk-encryption|full-disk encryption]], the host key
  — and therefore the ability to decrypt the repo's secrets — is protected at
  rest. Without it, stealing the disk yields both.
- **Regenerating the host key bricks decryption.** Reinstalling a machine without
  preserving `/etc/ssh/ssh_host_ed25519_key` means the new install cannot decrypt
  until you add its new recipient and `sops updatekeys`. With impermanence, the
  host key must be on the persistent volume. The
  [[linux/distributions/nixos/automated-install#Host keys and secrets before the first boot|automated-install note]]
  covers injecting the key at install time with nixos-anywhere.

### A compromised host decrypts everything it was ever sent

Per-host secret files are the containment mechanism. If every host decrypts one
shared `secrets.yaml`, one compromised machine exposes the whole fleet's secrets.
With `path_regex` rules per host, it exposes its own — then rotate those.

### Exposure after decryption

- **Never pass a secret as a command-line argument** — `argv` is visible to every
  user in `ps`. Flags like `--password` need a wrapper script that reads the file,
  or better, a service that accepts a file/credential option.
- **Environment variables leak more readily than credentials** — they are
  inherited by child processes and visible in `/proc/<pid>/environ` to the unit's
  user. Prefer `LoadCredential`: the file appears only inside the unit's mount
  namespace, and systemd handles ownership even for `DynamicUser` services.
- **Keep the default `mode = "0400"` and a real `owner`.** A secret readable by
  `users` group defeats the point.
- **Swap and hibernation** can write RAM — including tmpfs — to disk. Encrypted
  swap (see [[linux/distributions/nixos/disk-encryption|disk encryption]]) closes
  this.

### The editor's key

The admin age key derived from `~/.ssh/id_ed25519` decrypts *every* file it is a
recipient of. Keep a passphrase on the SSH key (`ssh-to-age` supports encrypted
keys via `SSH_TO_AGE_PASSPHRASE`), and treat laptop disk encryption as mandatory.
For more than one admin, give each their own recipient instead of sharing a key —
removal then is `updatekeys` plus rotation, not a fleet-wide re-key.

### Multiple administrators: a flat trust model, not a PKI

There is no hierarchy here — no root CA, no intermediates, no certificates,
nothing signed. sops wraps each file's random data key once **per recipient**
listed in `.sops.yaml`; every recipient is equal and can decrypt the whole file.
Adding an admin is adding their `age1...` line and running `sops updatekeys`;
nobody's key derives from or vouches for anyone else's.

Two refinements exist within that flat model:

- **An offline recovery recipient.** An age key generated with `age-keygen`,
  stored offline, and added to every rule — escrow against all admins losing
  their laptops at once. It is a recipient like any other, not a root of a
  hierarchy.
- **Shamir thresholds.** `key_groups` with `shamir_threshold: 2` splits the data
  key so that decryption needs members of *two* groups (say, an admin key *and*
  an HSM-backed key). This is the only multi-party ceremony sops offers, and few
  setups need it.

If you want real hierarchy — short-lived credentials, delegation, audit of each
read — that is a secrets *server* (Vault/OpenBao), a different tool for a
different threat model. sops is deliberately just multi-recipient file
encryption.

### Verify in CI

An encrypted file that no expected key can decrypt, or whose recipients drifted
from `.sops.yaml`, should fail before deploy, not at activation on the host:

```bash
# decryption smoke test with the CI's own age key
sops -d secrets/common.yaml > /dev/null
```

[[linux/distributions/nixos/gitops|The GitOps note]] shows where this fits in a
pipeline.

---

Related: [[linux/distributions/nixos/server|NixOS as a server]] ·
[[linux/distributions/nixos/gitops|GitOps]] ·
[[linux/distributions/nixos/hardening|Hardening]]

<!-- uplink -->
Part of [[linux/distributions/nixos/index|NixOS]].
