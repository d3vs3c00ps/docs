---
title: tar
description: Creating, listing, extracting and changing tar archives with GNU tar, and the traps
tags: [linux, cli, backup, cheatsheet]
type: reference
status: complete
---

# `tar` cheat sheet

This is GNU tar, the `tar` of Linux distributions. macOS and the BSDs ship `bsdtar`,
which accepts most of the same options. The differences are at the end.

## Options

| Option | Meaning |
| --- | --- |
| `-c` | create an archive |
| `-x` | extract |
| `-t` | list the contents of the archive |
| `-r` | append files to the end of the archive |
| `-f FILE` | archive file name. Put it last in a group: `-cvf out.tar`, not `-cfv` |
| `-v` | verbose: list the files as they go |
| `-z` / `-j` / `-J` / `--zstd` | gzip / bzip2 / xz / zstd compression |
| `-a` | with `-c`: choose the compression from the file name |
| `-C DIR` | change to DIR first |
| `--delete` | remove a file from the archive |

## Listing

```bash
tar -tvf backup.tar.gz
```

When reading, GNU tar detects the compression by itself. `-z` is not needed to list or
extract a `.tar.gz`, and the same command works for `.tar.xz` or `.tar.zst`.

## Extracting

Extract an archive into the current directory:

```bash
tar -xvf backup.tar.gz
```

Extract a single file from the archive. Give the name as `tar -t` shows it:

```bash
tar -xvf backup.tar.gz dump.sql
```

Extract somewhere else, and drop the top directory of the archive:

```bash
mkdir -p /opt/app
tar -xf app-1.2.tar.gz -C /opt/app --strip-components=1
```

> [!warning] Look before you extract
> An archive can contain hundreds of files with no top directory (a "tarbomb"), or
> overwrite files you already have. List it first with `tar -tf`. Extracting into an
> empty directory with `-C` keeps it contained.

## Creating

Uncompressed archive:

```bash
tar -cvf backup.tar dump.sql my.cnf
```

Compressed archive. `-a` picks gzip, xz or zstd from the name:

```bash
tar -cvzf backup.tar.gz dump.sql my.cnf
tar -cavf backup.tar.zst dump.sql my.cnf
```

Archive a directory by its relative name, from its parent, so the archive does not
depend on where it was made:

```bash
tar -czf etc-backup.tar.gz -C / etc/ssh
```

Leave files out:

```bash
tar -czf project.tar.gz --exclude='*.log' --exclude='.git' project/
```

> [!note] Leading `/` is removed
> `tar -czf x.tar.gz /etc/ssh` works, but prints
> "Removing leading `/' from member names" and stores `etc/ssh/...`. Extracting then
> writes to `./etc/ssh`, not `/etc/ssh`. That is a safety feature. Use `-C /` as above
> to get the same archive without the message.

## Owners and permissions

As root, `tar -x` restores the owners and permissions stored in the archive. As a
normal user, the files belong to you and your umask applies. `-p` keeps the stored
permissions for a normal user too. `--numeric-owner` stores and restores user IDs
instead of names, which matters when the names differ between the two machines.

## Incremental backups

GNU tar can archive only what changed since the last run. It keeps the state in a
snapshot file:

```bash
tar -czf full.tar.gz -g backup.snar data/       # first run: everything
tar -czf incr-1.tar.gz -g backup.snar data/     # later: only the changes
```

Restore the full archive, then each incremental one in order, each with
`-g /dev/null`. This also replays deletions.

## Modifying an existing archive

> [!note] Compressed archives cannot be modified in place
> `-r` and `--delete` only work on uncompressed archives. On a `.tar.gz`, GNU tar
> stops with "Cannot update compressed archives". Decompress it, change it, then
> compress it again.

Append a file:

```bash
tar -rf backup.tar dump_complete.sql
```

Remove a file:

```bash
tar -f backup.tar --delete dump_complete.sql
```

## bsdtar (macOS, BSD)

- `--delete` and `-g` (incremental) are GNU only.
- bsdtar also detects the compression when reading, and has `-a` and `--zstd`.
- An archive made on macOS can carry `._name` files with extended attributes. Create
  it with `COPYFILE_DISABLE=1 tar -czf ...` to leave them out. (macOS only: this one
  is not tested here.)

<!-- uplink -->
Part of [[linux/cli/index|Command line tools]].
