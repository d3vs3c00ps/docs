---
title: lnav
description: The log file navigator — merged timelines, SQL over log files, and reading container logs without extracting them first
tags: [linux, cli, logging, troubleshooting]
type: howto
status: complete
---

# `lnav`

[lnav](https://lnav.org/) is an interactive log file navigator. It beats
`less` on log files because it actually understands them: it detects the format,
parses timestamps, merges multiple files into one chronological view, and colours
fields by meaning.

For the daemons producing these logs, see [[linux/logging/rsyslog]] and
[[linux/cli/journalctl]].

## Installation

```bash
sudo dnf install lnav      # Fedora, RHEL with EPEL
brew install lnav          # macOS
```

openSUSE Leap 16 does not ship `lnav`. The
[release page](https://github.com/tstack/lnav/releases) has static Linux builds
(`linux-musl`) for x86_64 and arm64: unzip and copy `lnav` to `~/.local/bin`.

## Viewing files

```bash
lnav /var/log/nginx/error.log
```

Several at once, merged into a single timeline ordered by timestamp — which is the
feature that justifies the tool:

```bash
lnav /var/log/nginx/access.log /var/log/nginx/error.log
lnav /var/log/syslog*
```

`lnav` decompresses `.gz` and `.bz2` transparently, so rotated logs need no
preparation.

`lnav -n` (headless) prints the result instead of opening the screen, and `-c` runs
a command first. That is handy in scripts and is how the commands below were checked:

```bash
lnav -n -c ':filter-out healthcheck' /var/log/nginx/access.log
```

## Container logs

Pipe them in. `docker logs` writes the container's stderr to its own stderr, so
add `2>&1` or the errors never reach `lnav`:

```bash
docker logs container-id 2>&1 | lnav
docker logs -f app 2>&1 | lnav
```

Or read files inside a container directly, without copying them out:

```bash
lnav docker://app/var/log/nginx/nginx.app.log
lnav docker://app/var/log/
lnav docker://{container_id_or_name}/path/to/log/file
```

## Output of a command

Run a command and follow its output in the navigator:

```bash
lnav -e 'make test'
```

Useful for long builds — the output stays searchable and filterable rather than
scrolling past.

## Keys worth knowing

| Key | Effect |
| --- | --- |
| `?` | Help |
| `q` | Quit |
| `e` / `Shift+E` | Next / previous error |
| `w` / `Shift+W` | Next / previous warning |
| `/` | Search forward, with regex |
| `n` / `Shift+N` | Next / previous match |
| `i` | Histogram view — message volume over time |
| `Shift+I` | Histogram view, keeping the time of the focused line in sync |
| `Shift+T` | Show the elapsed time from a bookmark to each line |
| `:` | Command prompt |
| `;` | SQL prompt |
| `TAB` | Open the files and filters panel |

> [!tip] `i` is the fastest way to find an incident
> The histogram view collapses the whole log into a volume-over-time graph. A spike
> is immediately visible. Move to it and press `Shift+I` to jump back to the
> messages at that time (plain `i` returns to where you were). It answers "when did
> this start?" far quicker than scrolling.

## Filtering

At the `:` prompt:

```text
:filter-in error
:filter-out healthcheck
:hide-lines-before 2026-08-11 09:00:00
:hide-lines-after 2026-08-11 10:00:00
```

`filter-out` is the one you will use most — dropping health checks and readiness
probes usually removes the majority of the noise.

## SQL over log files

`lnav` parses recognised formats into columns and lets you query them at the `;`
prompt:

```sql
;SELECT c_ip, count(*) AS hits FROM access_log GROUP BY c_ip ORDER BY hits DESC LIMIT 10;
```

```sql
;SELECT * FROM access_log WHERE sc_status >= 500;
```

This is genuinely useful for access logs — the kind of question that would otherwise
mean an `awk` pipeline, answered in one line. `.schema` at the SQL prompt lists the
available tables and columns for the formats it recognised.

## multitail — the other approach

Where `lnav` merges several logs into one chronological stream,
[`multitail`](https://vanheusden.com/multitail/) keeps them **side by side**, in split
windows, each scrolling independently.

```bash
sudo dnf install multitail     # EPEL; not in openSUSE Leap 16

multitail /var/log/nginx/access.log /var/log/nginx/error.log
multitail -s 2 /var/log/syslog /var/log/auth.log        # two columns
multitail -i /var/log/messages -I /var/log/secure       # merge into one window
multitail -l "kubectl logs -f deploy/api"               # follow a command
multitail -cS apache /var/log/nginx/access.log          # colour scheme
```

Useful keys: `b` to browse a window's scrollback, `/` to search within one, `w` to
write a window's contents to a file.

> [!tip] Which of the two to reach for
> **`lnav`** when you want one timeline — correlating an application error with what
> the proxy and the kernel were doing at the same moment. Its merged view and SQL
> queries are for *analysis after the fact*.
>
> **`multitail`** when you want to watch several unrelated streams at once during a
> deployment or a test — separate panes make it obvious *which* source produced a
> burst, which a merged view deliberately hides.
>
> `tmux` with a pane per log does much of the same job and is already installed — see
> [[linux/shell/tmux]]. `multitail` earns its place through per-window filtering,
> colour schemes and independent scrollback.

Background: [multitail, and how it can make you a better sysadmin](https://idolinux.com/multitail-what-it-is-and-how-it-can-make-you-a-better-sysadmin/).

## Where to go next

- [[linux/cli/journalctl]] — querying the systemd journal instead
- [[linux/logging/rsyslog]] — shipping logs somewhere central
- [[linux/shell/tmux]] — a pane per log, without another tool
- [[kubernetes/observability/logs-cli]] — the same problem in a cluster

<!-- uplink -->
Part of [[linux/cli/index|Command line tools]].
