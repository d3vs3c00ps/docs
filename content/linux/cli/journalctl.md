---
title: journalctl
description: Querying the systemd journal — filtering by boot, time, unit, PID, user, priority and transport
tags: [linux, cli, logging, systemd, cheatsheet]
type: reference
status: complete
---

# `journalctl`

Log data is collected, stored and indexed by the **systemd** journal.
`journalctl` is the utility for reading everything gathered by
**systemd-journald**.

See also [[linux/boot/systemd]] for unit management, and
[[linux/logging/syslog]] if you need to forward these logs off the host.

## View all logs

```bash
journalctl
```

The output is every log entry the system has generated, structured similarly to
what you would historically find in `/var/log/messages`.

## Follow logs in real time

```bash
journalctl -f
```

## Logs from a specific boot

List the boots the journal still holds:

```bash
journalctl --list-boots
```

Then select one — `0` is the current boot, `-1` the previous one. Older boots are
only there if the journal is persistent (stored in `/var/log/journal`):

```bash
journalctl -b 0
```

## Filter by time

```bash
journalctl --since today
journalctl --since "2020-01-01 12:00:00"
journalctl --since "2020-01-01 12:00:00" --until "2020-01-01 14:00:00"
journalctl --since yesterday --until now
```

## Filter by unit

`-u` selects a *unit*. A path to a program selects the entries that program wrote:

```bash
journalctl -u systemd-journald
journalctl -u sshd.service
journalctl /usr/sbin/sshd
```

## Add explanatory text

`-x` appends *explanation* text to log messages where systemd has one:

```bash
journalctl -u sshd.service -x
```

## Filter by PID

```bash
journalctl _PID=42
```

## Filter by user

```bash
journalctl _UID=1042
```

## Filter by priority

`-p` selects a *priority*:

| Priority | Level |
| --- | --- |
| 0 | `emerg` |
| 1 | `alert` |
| 2 | `crit` |
| 3 | `err` |
| 4 | `warning` |
| 5 | `notice` |
| 6 | `info` |
| 7 | `debug` |

A single priority, by number or by name, includes everything more severe than it.
This shows `err`, `crit`, `alert` and `emerg`:

```bash
journalctl -p err
```

A range is also accepted:

```bash
journalctl -p 2..4
```

## Kernel logs

```bash
journalctl -k
```

## Filter by transport

How the entry reached the journal — one of `audit`, `driver`, `syslog`, `journal`,
`stdout`, `kernel`:

```bash
journalctl _TRANSPORT=syslog
```

## Managing journal disk usage

Check current usage:

```bash
journalctl --disk-usage
```

Shrink the journal to a target size — suffixes `K`, `M`, `G`, `T`:

```bash
journalctl --vacuum-size=100M
```

Shrink the journal by age — suffixes `s`, `min`, `h`, `days`, `weeks`, `months`,
`years`:

```bash
journalctl --vacuum-time=1months
```

> [!note] Vacuuming is not a retention policy
> Both `--vacuum-*` flags act once, immediately. For permanent limits set
> `SystemMaxUse=` or `MaxRetentionSec=` in a drop-in file, then restart
> `systemd-journald`. On openSUSE Leap 16 the defaults live in
> `/usr/lib/systemd/journald.conf` and `/etc/systemd/journald.conf` does not exist.
>
> ```bash
> mkdir -p /etc/systemd/journald.conf.d
> cat > /etc/systemd/journald.conf.d/size.conf <<'EOF'
> [Journal]
> SystemMaxUse=500M
> MaxRetentionSec=1month
> EOF
> systemctl restart systemd-journald
> ```
>
> `SystemMaxUse=` applies to a persistent journal in `/var/log/journal`. A volatile
> journal in `/run/log/journal` uses `RuntimeMaxUse=` instead.

<!-- uplink -->
Part of [[linux/cli/index|Command line tools]].
