---
title: tmux
description: Terminal multiplexer basics — sessions, windows, panes and the default key bindings
tags: [linux, cli, shell, tmux, cheatsheet]
type: reference
status: complete
---

# tmux

`tmux` is a terminal multiplexer. Sessions keep running after you detach from
them and can be reattached later — including from a different machine over a new
SSH connection, which is the main reason to use it. A single terminal can host
several sessions.

## Terminology

| tmux term | What it is |
| --- | --- |
| session | a collection of windows, detachable and resumable |
| window | a full-screen "tab" inside a session |
| pane | a split region inside a window |

## From a normal shell

```bash
tmux                  # create a session
tmux ls               # list active sessions
tmux attach           # reattach to the most recent session
tmux attach -t 0      # reattach to a specific session
tmux new -s build     # create a named session
```

## Window bindings

All bindings are preceded by the prefix key, **`Ctrl+b`**.

| Key | Action |
| --- | --- |
| `c` | create a new window |
| `n` | next window |
| `p` | previous window |
| *number* | switch to that window number |
| `w` | list available windows |
| `,` | rename the current window |
| `d` | detach from the session |
| `t` | show a clock in the current pane |

## Pane bindings

| Key | Action |
| --- | --- |
| `%` | split into two panes side by side |
| `"` | split into two panes stacked top and bottom |
| `o` | cycle between panes |
| *arrow keys* | move to the pane in that direction |
| `Space` | cycle through the preset pane layouts |
| `Alt` + *arrows* | resize the current pane |
| `!` | promote the current pane into its own window |
| `q` | briefly display pane numbers |
| `z` | zoom the current pane to full screen (and back) |
| `x` | kill the current pane |

## Joining a window back into a pane

`!` breaks a pane out into a window; `join-pane` does the reverse. Enter the
command prompt with `Ctrl+b :` then:

```text
:joinp -h -s 3.0 -l 25%
```

| Flag | Meaning |
| --- | --- |
| `-h` / `-v` | join horizontally or vertically |
| `-s 3.0` | source — window 3, pane 0 |
| `-l 25%` | give the joined pane 25% of the available space |

> [!note] `-l 25%`, not `-p 25`
> Since tmux 3.1, `-l` takes a percentage and `-p` is deprecated. With tmux 3.5a
> (openSUSE Leap 16), `joinp -p 25` fails with `size missing`.

## The command prompt

Every key binding is a shortcut for a command. `Ctrl+b :` opens the prompt and gives
you the full set — which is also how you script tmux, since the same commands work
from a shell.

```bash
tmux new-session -d -s work -n editor
tmux send-keys -t work:editor 'vim .' Enter
tmux split-window -t work:editor -h
tmux send-keys -t work:editor.1 'journalctl -f' Enter
tmux attach -t work
```

That is a reproducible working layout in five lines, and the basis of every
project-specific tmux script.

| Command | Effect |
| --- | --- |
| `list-keys` | Every binding — the definitive reference |
| `list-commands` | Every command, with its arguments |
| `list-sessions`, `list-windows`, `list-panes` | Inventory |
| `rename-window <name>` | Also `Ctrl+b ,` |
| `move-window -t 2` | Renumber |
| `swap-pane -s 1 -t 2` | Exchange two panes |
| `setw synchronize-panes on` | **Type into every pane at once** |
| `capture-pane -p -S -1000` | Print the last 1000 lines of scrollback |
| `pipe-pane -o 'cat >> ~/tmux.log'` | Log everything a pane outputs |
| `source-file ~/.tmux.conf` | Reload configuration without restarting |

> [!tip] `synchronize-panes` for fleet work
> With a pane open on each of several hosts, `setw synchronize-panes on` sends every
> keystroke to all of them — a cheap parallel shell for a handful of machines.
>
> It is also exactly as dangerous as it sounds. Turn it off immediately afterwards,
> and never leave it on in a session where one pane is production. Bind it to a key
> with a visible indicator:
>
> ```text
> bind S setw synchronize-panes \; display "sync #{?pane_synchronized,ON,OFF}"
> ```

`capture-pane` is the other one worth remembering — it recovers output that has
scrolled past, including from a command that has already finished:

```bash
tmux capture-pane -p -S -3000 > output.txt
```

tmux keeps only `history-limit` lines of scrollback per pane, 2000 by default. Older
lines are gone. Raise it in `~/.tmux.conf` with `set -g history-limit 50000`.

Full documentation: `man tmux`, and the [tmux wiki](https://github.com/tmux/tmux/wiki).

<!-- uplink -->
Part of [[linux/shell/index|Shells]].
