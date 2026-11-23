---
title: kill
description: Sending signals to processes, process groups and sessions with kill, pkill and pgrep
tags: [linux, cli, processes, signals]
type: reference
status: complete
---

# `kill` cheat sheet

## SIGHUP

Many Linux and Unix-like daemons use `SIGHUP` as a "reload" signal — most often
to re-read their configuration files without restarting. So a config reload is
usually just:

```bash
kill -HUP $(cat /run/service.pid)
pkill -HUP -F /run/service.pid      # same, pkill reads the PID file itself
```

> [!tip] For a systemd service, use `systemctl reload`
> `systemctl reload service` runs the unit's own `ExecReload=`, which often sends
> `SIGHUP` too, and reports an error if the unit cannot reload. `/var/run` in older
> examples is a link to `/run`. See [[linux/boot/systemd]].

## Killing a process

Killing a parent process does not necessarily kill its children, and every
process has a parent.

Create two processes:

```bash
sleep 3600 &
sleep 3601 &
```

Look at the resulting tree (output shortened):

```console
$ pstree -p $$
bash(2104)─┬─pstree(2131)
           ├─sleep(2120)
           └─sleep(2121)

$ ps j -A
   PPID     PID    PGID     SID TTY        TPGID STAT   UID   TIME COMMAND
   2103    2104    2104    2104 pts/0       2132 Ss       0   0:00 -bash
   2104    2120    2120    2104 pts/0       2132 S        0   0:00 sleep 3600
   2104    2121    2121    2104 pts/0       2132 S        0   0:00 sleep 3601
   2104    2132    2132    2104 pts/0       2132 R+       0   0:00 ps j -A
```

`ps` shows the **PID** (process ID) alongside the **PPID** (parent process ID).
If you kill the parent, the child becomes *orphaned*: it keeps running, and PID 1
(or a "subreaper" such as `systemd --user`) becomes its new parent.

There are two further groupings:

- **PGID** — process group ID
- **SID** — session ID

**Process groups** are easy to observe under an interactive `bash`: with job
control on, it creates one process group per command pipeline. Above, each `sleep`
is its own group (PGID = PID). A process group is a collection of processes that
can be signalled together. A **session** is in turn a collection of process
groups. Here the session is the login shell's: SID `2104`.

## Killing every process in a process group

Pass the PGID as a *negative* number:

```bash
kill -SIGTERM -- -2121
```

> [!warning] The sign is what selects group-versus-process
> A negative number signals the whole process group. The same number as a
> positive value would signal only the single process with that PID. The `--`
> matters when the group comes first: `kill -- -2121` sends `SIGTERM` to the group,
> while `kill -2121` is read as signal number 2121 and fails.

## Killing every process in a session

List the processes in a session:

```console
$ pgrep -s 2104 -a
2104 -bash
2120 sleep 3600
```

Then signal them:

```bash
pkill -s 2104
```

> [!note] The list includes your own shell
> The session leader is usually your login shell. An interactive `bash` ignores
> `SIGTERM`, so `pkill -s` leaves it running. `pkill -KILL -s` would close your
> session.

## Why is this running at all?

`ps` and `pgrep` answer *what* is running. They do not answer *why* — which service,
container or shell caused it to exist.

[`witr`](https://github.com/pranshuparmar/witr) — "why is this running" — walks a
process's ancestry back to PID 1 and reports the systemd unit responsible:

```bash
go install github.com/pranshuparmar/witr@latest   # not packaged for Leap
brew install witr                                 # macOS, Linuxbrew
```

```bash
witr auditd
```

```text
Why It Exists :
  systemd (pid 1) → auditd (pid 1096)

Source      : auditd.service (systemd)
Unit File   : /usr/lib/systemd/system/auditd.service
```

The genuinely useful invocation is by port, which collapses several steps into one:

```bash
witr --port 8080
witr --file /var/log/nginx/access.log
witr --container redis
```

> [!tip] It replaces a three-command sequence
> Working out what owns a port normally means `ss -tlnp` for the PID, then
> `ps -o ppid=` to walk upward, then `systemctl status` to find the unit. `witr
> --port` does all three and prints the unit file path.
>
> The equivalent without it:
>
> ```bash
> ss -tlnp 'sport = :8080'
> systemctl status "$(ps -o unit= -p <pid>)"
> ```
>
> Worth knowing both — the manual form works everywhere, and on a machine where you
> cannot install anything it is what you will use.

It also flags conditions worth noticing, under `Warnings`: a process running as
root, listening on a public interface, or started from `/tmp`.

Background:
[witr — retrouver l'origine d'un processus](https://blog.stephane-robert.info/docs/admin-serveurs/linux/exploiter/processus/witr/)
(in French).

<!-- uplink -->
Part of [[linux/cli/index|Command line tools]].
