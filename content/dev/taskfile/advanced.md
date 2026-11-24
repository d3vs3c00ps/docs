---
title: Task reference
description: Task (go-task) v3.54 reference — variables and their precedence, env and dotenv, includes, sources/generates and status, preconditions, requires, run modes, loops, prompts, defer, templating, watch and the .taskrc.yml config
tags: [dev, tooling, task, build]
type: reference
status: complete
---

# Task reference

This note covers the Taskfile features beyond the basics of [[dev/taskfile/quickstart]].
Everything here was checked with Task v3.54.0. Each example is a complete
`Taskfile.yml` that you can copy and run.

## Variables

### Static, dynamic and typed values

```yaml
version: "3"

vars:
  APP: shop                                   # a string
  PORTS: [8080, 8081]                         # a list
  LIMITS:
    map: { cpu: "2", memory: 1Gi }            # a map needs the `map:` key
  COMMIT:
    sh: git rev-parse --short HEAD 2>/dev/null || echo none

tasks:
  show:
    cmds:
      - echo "{{.APP}} {{.COMMIT}} first-port={{index .PORTS 0}} cpu={{.LIMITS.cpu}}"
```

- `sh:` runs a command once, when Task builds the variables, and keeps its output
  without the last newline. The result is always a string.
- Variables are Go templates: `{{.NAME}}`. A name that does not exist gives an empty
  string, with no error. See [[dev/taskfile/troubleshooting]].
- `{{.NAME | default "x"}}` gives a fallback value.

### Precedence

From weakest to strongest, the last one wins:

| # | Source |
| --- | --- |
| 1 | the process environment (the shell that runs `task`) |
| 2 | special variables: `TASK`, `ROOT_DIR`, `CLI_ARGS`... |
| 3 | the Taskfile's top-level `env:` and `dotenv:` |
| 4 | the top-level `vars:` of every Taskfile in the run |
| 5 | `vars:` given on an `includes:` entry |
| 6 | the included Taskfile's own top-level `vars:` |
| 7 | call variables: `task build MODE=x`, or `vars:` on a `task:` call |
| 8 | the task's own `vars:` |

The trap is line 8: **a variable set on the task wins over the command line.**

```yaml
version: "3"

vars:
  MODE: debug

tasks:
  global-default:
    cmds:
      - echo "MODE={{.MODE}}"

  task-value:
    vars:
      MODE: release
    cmds:
      - echo "MODE={{.MODE}}"

  template-default:
    vars:
      MODE: '{{.MODE | default "release"}}'
    cmds:
      - echo "MODE={{.MODE}}"
```

| Command | Output |
| --- | --- |
| `task global-default MODE=prod` | `MODE=prod` |
| `task task-value MODE=prod` | `MODE=release` (the command line is ignored) |
| `task template-default MODE=prod` | `MODE=prod` |

To give a default that callers can change, put it in the top-level `vars:`, or use
the `default` pattern of `template-default`. Here `task template-default` with no
`MODE=` prints `MODE=debug`: `default` applies only when no other level sets the name.

### Pass a list or a map with `ref`

A template always gives a string. To pass a list to another task without turning it
into text, use `ref:`:

```yaml
version: "3"

tasks:
  default:
    vars:
      SERVICES: [api, worker]
    cmds:
      - task: show
        vars:
          SERVICES:
            ref: .SERVICES

  show:
    cmds:
      - echo "first={{index .SERVICES 0}} count={{len .SERVICES}}"
```

This prints `first=api count=2`.

## Environment: `env` and `dotenv`

`vars:` are only for templates: they are **not** exported to the commands. `env:` is
exported, so the command can read `$NAME`.

```yaml
version: "3"

dotenv: [.env.local, .env]

env:
  REGION: eu-west-1

vars:
  ONLY_VAR: hidden

tasks:
  show:
    env:
      LOG_LEVEL: debug
    cmds:
      - echo "REGION=$REGION DB_HOST=$DB_HOST LOG_LEVEL=$LOG_LEVEL ONLY_VAR=[$ONLY_VAR]"
```

With `.env` containing `DB_HOST=db.example.com` and `REGION=us-east-1`, and
`.env.local` containing `DB_HOST=localhost`:

```text
REGION=eu-west-1 DB_HOST=localhost LOG_LEVEL=debug ONLY_VAR=[]
```

- With several `dotenv` files, the **first** file that sets a name wins. Put local
  overrides first.
- `env:` wins over `dotenv`: `REGION` comes from `env:`, not from `.env`.
- A missing dotenv file is skipped, with no error.
- The process environment wins over both: `REGION=x task show` prints `REGION=x`.
  The experiment `TASK_X_ENV_PRECEDENCE=1` reverses this.
- `dotenv:` is not allowed in an included Taskfile. Put it in the root Taskfile.

## Includes

```yaml
version: "3"

includes:
  docs:
    taskfile: ./docs           # a directory: Task looks for docs/Taskfile.yml
    dir: ./docs                # run the included tasks in docs/
    aliases: [d]               # task d:build works too
  backend:
    taskfile: ./taskfiles/Docker.yml
    vars:
      IMAGE: backend
  frontend:
    taskfile: ./taskfiles/Docker.yml
    vars:
      IMAGE: frontend
  local:
    taskfile: ./Taskfile.local.yml
    optional: true             # no error if the file does not exist
  tools:
    taskfile: ./taskfiles/Tools.yml
    flatten: true              # task lint, not task tools:lint
    excludes: [debug]          # do not include this task
  helpers:
    taskfile: ./taskfiles/Helpers.yml
    internal: true             # callable from other tasks only, hidden from --list
```

`taskfiles/Docker.yml`, used twice with a different `IMAGE`:

```yaml
version: "3"

vars:
  IMAGE: '{{.IMAGE | default "app"}}'

tasks:
  build:
    cmds:
      - echo "building {{.IMAGE}}"
```

- Call an included task as `namespace:task`: `task backend:build` prints
  `building backend`, `task frontend:build` prints `building frontend`.
- In the included file, write `IMAGE: '{{.IMAGE | default "app"}}'`, not
  `IMAGE: app`. A plain value in the included file's own `vars:` wins over the value
  given by `includes:` (line 6 of the precedence table).
- Without `dir:`, included tasks run in the directory of the **root** Taskfile, not in
  the directory of the included file.
- `flatten: true` fails if a task name already exists in the root Taskfile.
- Inside an included file, `task: :build` (leading colon) calls a task of the root
  Taskfile.

## Skip work that is done

### `sources` and `generates`

```yaml
version: "3"

tasks:
  bundle:
    sources:
      - src/**/*.js
      - exclude: src/**/*.test.js
    generates:
      - dist/bundle.js
    cmds:
      - mkdir -p dist
      - find src -name '*.js' ! -name '*.test.js' | sort | xargs cat > dist/bundle.js
```

The first `task bundle` runs. The second prints `task: Task "bundle" is up to date` and
runs nothing. It runs again when a source file changes, or when `dist/bundle.js` is
missing.

| `method:` | The task is up to date when |
| --- | --- |
| `checksum` (default) | the content of the sources matches the checksum saved after the last run, and every `generates` file exists |
| `timestamp` | no source is newer than the generated files |
| `none` | never: the task always runs |

- Checksums are saved in `.task/checksum/<task name>`, next to the root Taskfile. Add
  `.task/` to `.gitignore`.
- `checksum` reads the content: `touch` on a source does not trigger a run.
  `timestamp` reads the modification time: `touch` does.
- `checksum` only checks that `generates` files **exist**. It does not see a changed
  output file.
- `{{.CHECKSUM}}` (with `checksum`) or `{{.TIMESTAMP}}` (with `timestamp`) can be used
  in the commands, for example as an image tag.

```bash
task --status bundle     # exit 0 if up to date, non-zero if not; runs nothing
task --force bundle      # run even if up to date (-f)
```

### `status`

`status` is a list of commands. If **all** of them exit 0, the task is up to date and
its commands do not run:

```yaml
version: "3"

tasks:
  install-tool:
    status:
      - test -x bin/tool
    cmds:
      - mkdir -p bin
      - printf '#!/bin/sh\necho tool 1.0\n' > bin/tool
      - chmod +x bin/tool
```

Use `status` when the result is not a file built from local sources: an installed
tool, a created database, a pulled image. With both `sources` and `status`, both must
say "up to date".

## Conditions

| Key | When the check fails |
| --- | --- |
| `status` | the task runs (the work is not done yet) |
| `if` | the task, or the command, is skipped. Exit code 0 |
| `preconditions` | the task fails with exit code `201` and prints `msg` |
| `requires` | the task fails before anything runs: exit code `206` (missing) or `207` (value not in `enum`) |

```yaml
version: "3"

tasks:
  deploy:
    requires:
      vars:
        - name: ENV
          enum: [dev, staging, prod]
        - VERSION
    preconditions:
      - sh: test -f release.txt
        msg: "release.txt is missing. Run 'task release' first."
    cmds:
      - echo "deploying {{.VERSION}} to {{.ENV}}"
      - cmd: echo "sending a notification"
        if: '{{eq .ENV "prod"}}'
```

- `task deploy ENV=prod VERSION=1.2` runs, if `release.txt` exists.
- `task deploy ENV=test VERSION=1.2` fails with exit code `207`:
  `ENV has an invalid value : 'test' (allowed values : [dev staging prod])`.
- Without `release.txt`, it prints the `msg` and fails with exit code `201`.
- The notification line runs only for `prod`. `if:` takes a shell command, and
  `{{eq ...}}` renders to `true` or `false`, which are also commands.
- A variable set to an empty string counts as present for `requires`.

`task --interactive deploy` asks for the missing variables in a terminal (a menu for
`enum`). With no terminal, it fails with exit code `206` as before.

## Run a task once

When several tasks depend on the same task, it runs once **per call** by default.
`run:` changes this, inside one `task` invocation:

```yaml
version: "3"

tasks:
  check:
    deps: [lint, test]

  lint:
    deps: [setup]
    cmds: [echo lint]

  test:
    deps: [setup]
    cmds: [echo test]

  setup:
    run: once
    cmds: [echo setup]
```

| `run:` | Behaviour |
| --- | --- |
| `always` (default) | run on every call |
| `once` | run once, whatever the variables |
| `when_changed` | run once for each different set of variables |

`task check` prints `setup` once. Without `run: once`, it prints it twice. This does
not persist between runs: for that, use `sources` or `status`.

## Loops

```yaml
version: "3"

tasks:
  loops:
    vars:
      FILES: [a.txt, b.txt]
      CSV: x,y
    cmds:
      - for: [one, two]
        cmd: echo "list {{.ITEM}}"
      - for: { var: FILES, as: FILE }
        cmd: echo "var {{.FILE}}"
      - for: { var: CSV, split: "," }
        cmd: echo "split {{.ITEM}}"
      - for:
          matrix:
            OS: [linux, darwin]
            ARCH: [amd64, arm64]
        cmd: echo "matrix {{.ITEM.OS}}/{{.ITEM.ARCH}}"
      - for: [api, worker]
        task: ping
        vars: { SERVICE: "{{.ITEM}}" }

  ping:
    cmds:
      - echo "ping {{.SERVICE}}"
```

- A string variable is split on spaces, unless you give `split:`.
- `for: sources` and `for: generates` loop over the task's files.
- Loops in `cmds` run in order. A loop in `deps` runs the calls in parallel.

## Platforms

```yaml
version: "3"

tasks:
  open-docs:
    cmds:
      - cmd: xdg-open docs/index.html
        platforms: [linux]
      - cmd: open docs/index.html
        platforms: [darwin]
      - cmd: start docs/index.html
        platforms: [windows]

  linux-only:
    platforms: [linux/amd64, linux/arm64]
    cmds:
      - echo "on {{OS}}/{{ARCH}}"
```

A command or a task for another platform is skipped, with exit code 0 and no message.
The names are Go's `GOOS` and `GOARCH` values.

## Prompts, defer and errors

```yaml
version: "3"

tasks:
  reset-db:
    prompt: This deletes the local database. Continue?
    cmds:
      - echo "database reset"

  work:
    cmds:
      - mkdir -p tmp-work
      - defer: rm -rf tmp-work
      - defer: echo "exit code was {{.EXIT_CODE}}"
      - cmd: ls missing-file
        ignore_error: true
      - echo "still running"
```

- `prompt:` asks `[y/N]` in a terminal. Any answer but `y` or `yes` cancels the task
  with exit code `205`. `task --yes reset-db` (`-y`) answers yes. With no terminal (CI,
  cron) and no `--yes`, the task fails with exit code `205` and does not run.
- `defer:` registers a command that runs when the task ends, even when a later
  command fails. Deferred commands run in reverse order. `{{.EXIT_CODE}}` is the exit
  code of the failed command, or empty on success.
- `ignore_error: true` on a command keeps going after it fails. On a whole task, it
  applies to each of its commands. A task it calls does not inherit it: that task
  still stops at its first error, then the caller goes on.

## Templating functions

Task templates have the Go template built-ins, most of the
[slim-sprig](https://go-task.github.io/slim-sprig/) functions, and some of its own:

```yaml
version: "3"

tasks:
  functions:
    vars:
      WORDS: b a c
      MSG: "it's done; really"
    cmds:
      - echo "{{now | date "2006-01-02"}}"
      - echo "{{OS}} {{ARCH}} {{numCPU}} bin/app{{exeExt}}"
      - echo "{{.WORDS | splitList " " | sortAlpha | join ","}}"
      - echo "{{"Hello" | upper}} {{"  x  " | trim}} {{.MISSING | default "fallback"}}"
      - echo "{{joinPath "dist" "linux" "app"}} {{base "/a/b/c.txt"}} {{ext "c.tar.gz"}}"
      - echo {{.MSG | shellQuote}}
      - echo "{{.TASK}} {{.TASK_VERSION}}"
```

`shellQuote` (alias `q`) quotes a value for the shell. Without it, the `'` and `;` in
`MSG` would break the command. Other useful functions: `toJson`, `fromJson`, `toYaml`,
`splitLines`, `catLines`, `uuid`, `absPath`, `relPath`. The special variables
`ROOT_DIR`, `TASKFILE_DIR`, `USER_WORKING_DIR` and `TASK_DIR` are described in
[[dev/taskfile/troubleshooting]].

## Command-line flags

| Flag | What it does |
| --- | --- |
| `-l`, `--list` / `-a`, `--list-all` | list tasks with a `desc` / all tasks |
| `-j`, `--json` | with `--list` or `--list-all`, print JSON |
| `--summary NAME` | show the task's `summary` (or `desc`), vars, requires and commands. Runs nothing |
| `-n`, `--dry` | print the commands in order, run nothing |
| `-v`, `--verbose` | also print when each task starts and ends, and why it is skipped |
| `-p`, `--parallel` | run the tasks named on the command line in parallel |
| `-C N`, `--concurrency N` | at most N tasks at the same time |
| `-F`, `--failfast` | stop the other dependencies when one fails |
| `-w`, `--watch` | run the task, then run it again each time one of its `sources` changes |
| `-f`, `--force` | run even if up to date |
| `--status` | exit non-zero if a task is not up to date |
| `-x`, `--exit-code` | exit with the failed command's own code, not `201` |
| `-y`, `--yes` | answer yes to every `prompt` |
| `-s`, `--silent` | do not print the commands |
| `-t FILE`, `-d DIR` | use another Taskfile / directory |
| `-g`, `--global` | use `$HOME/Taskfile.yml` |

```bash
task --list --json --no-status | jq -r '.tasks[] | "\(.name)\t\(.desc)"'
task --parallel lint test
task --watch build
```

> [!warning] `--list --json` marks tasks as up to date
> In v3.54.0, `task --list --json` (and `--list-all --json`) saves the checksum of every
> task with `sources`, as if it had run. The next `task build` then says "up to date"
> and runs nothing. Add `--no-status` when a script reads the JSON. See
> [[dev/taskfile/troubleshooting]].

`--watch` runs until you press Ctrl+C. It watches the task's `sources`: without
`sources`, the task runs once and Task then waits for nothing. After a change, Task
waits 100 ms for more changes before it runs again (`--interval` changes this).

## Configuration: `.taskrc.yml`

Task reads settings from these files. Later files win:

1. `$XDG_CONFIG_HOME/task/taskrc.yml` (default `~/.config/task/taskrc.yml`, no dot)
2. `~/.taskrc.yml`
3. `.taskrc.yml` in each parent directory, then in the project directory

```yaml
# .taskrc.yml
silent: true
failfast: true
concurrency: 4
experiments:
  GENTLE_FORCE: 1
```

Each setting can also be set with a `TASK_` environment variable, which wins over the
files: `TASK_SILENT=false task build`. Command-line flags win over both.

Experiments are features that may change or be removed. Turn one on with
`experiments:` here, or with an environment variable such as `TASK_X_GENTLE_FORCE=1`.
`task --experiments` lists them and shows which are on. In v3.54.0 there are two:
`GENTLE_FORCE` (`--force` forces only the named task, not its dependencies) and
`ENV_PRECEDENCE` (the Taskfile's `env:` wins over the process environment).

<!-- uplink -->
Part of [[dev/taskfile/index|Task (Taskfile)]].
