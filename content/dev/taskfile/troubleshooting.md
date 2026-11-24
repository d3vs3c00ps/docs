---
title: Task troubleshooting
description: Debugging Task (go-task) v3.54 — verbose and dry runs, tasks that always or never run, the built-in shell versus bash, YAML and quoting traps, empty variables, paths in included Taskfiles, exit codes, experiments and old Taskfile versions
tags: [dev, tooling, task, build]
type: reference
status: complete
---

# Task troubleshooting

Problems met with Task v3.54.0, and how to find their cause. For the features
themselves, see [[dev/taskfile/quickstart]] and [[dev/taskfile/advanced]].

## See what Task does

| Command | Shows |
| --- | --- |
| `task -v NAME` | when each task starts and ends, the result of each `sh:` variable, each `status` check, and why a task or command was skipped |
| `task -n NAME` | the commands, in order, with the templates filled in. Runs no `cmds` (see below) |
| `task --summary NAME` | the task's description, vars, `requires` and commands. Runs nothing |
| `task --status NAME` | exit code 0 if the task is up to date, 1 if not |
| `task --list-all` | every task Task found, with the namespaces of the includes |

With this Taskfile:

```yaml
version: "3"

vars:
  GIT_REF:
    sh: echo main

tasks:
  deploy:
    if: test -f deploy.conf
    cmds:
      - echo "deploying {{.GIT_REF}}"
```

`task deploy` prints nothing and exits 0, because `deploy.conf` does not exist.
`task -v deploy` says why:

```text
task: dynamic variable: "echo main" result: "main"
task: if condition not met - skipped: "deploy"
```

Once `deploy.conf` exists, `task -n deploy` shows the command as it would run, here
`task: [deploy] echo "deploying main"`. A dry run only skips `cmds`. It still runs the
`sh:` of the variables and the `if`, `status` and `preconditions` checks, so they must
be safe to run.

## A task never runs

Task says `task: Task "build" is up to date` and does nothing.

- **The sources did not change.** With the default `method: checksum`, only a change of
  content counts. `touch` is not enough. Use `task -f build` (`--force`) to run anyway.
- **The checksum is stale.** Checksums are in `.task/checksum/<task>`, next to the root
  Taskfile. `rm -rf .task` makes every task run again.
- **The output changed, not the inputs.** `checksum` only checks that `generates`
  files exist. It does not see an edited or broken output file.
- **The same task runs with other variables.** There is one checksum per task name, so
  `task build MODE=a` then `task build MODE=b` says "up to date" the second time. Give
  each variant its own name with `label: 'build-{{.MODE}}'`, and its own output file.
- **`task --list --json` ran first.** In v3.54.0, the JSON listing saves the checksum
  of every task with `sources`, as if it had run. The next `task build` is skipped
  though it never ran. Use `task --list --json --no-status`.
- **A `status` check passes.** All `status` commands exit 0, so the work looks done.
  `task -v` prints each check and its result.
- **`if:` or `platforms:` skip it.** No message without `-v`, and the exit code is 0.
- **The `sources` glob matches nothing**: the first run saves an empty checksum, then
  the task is up to date for ever. Check the glob from the task's `dir`.

```yaml
version: "3"

tasks:
  build:
    sources: [data.csv]
    generates: [data.csv.gz]
    cmds:
      - gzip -kf data.csv
```

```bash
task build                        # runs
task build                        # task: Task "build" is up to date
touch data.csv && task build      # still up to date: same content
task --force build                # runs
rm -rf .task && task build        # runs: no saved checksum
```

## A task always runs

- **It has no `sources` and no `status`.** This is normal: a task is a command, like
  a `.PHONY` target in Make.
- **A `generates` file is never created**, for example a typo in its path. A missing
  output always means "run again".
- **`method: none`**, or a `status` command that fails.

## The shell is not bash

Task does not start `/bin/sh` or `bash`. It runs each command with
[mvdan/sh](https://github.com/mvdan/sh), a shell interpreter written in Go. It reads
bash syntax, so most commands work, but not all.

Two rules differ from a script:

- **Errors stop the command, as with `set -e`.** In a multi-line command, the first
  failing line stops it. `false || true`, `if`, and `&&` chains behave as with
  `set -e`. Put `set +e` at the top of the command to turn this off.
- **`pipefail` is off.** `false | true` succeeds. Add `set: [pipefail]` on the task, or
  at the top of the Taskfile.

What works and what does not, tested with v3.54.0:

| Feature | Result |
| --- | --- |
| arrays `a=(x y)`, `${a[1]}`, `${#a[@]}`, `declare -A` | works |
| `[[ ]]`, `=~` and `BASH_REMATCH` | works |
| `<(...)`, `<<<`, `mapfile`, `read -ra`, `local`, `trap`, `$RANDOM` | works |
| `${v^^}`, `${v:1:3}`, `${!name}`, `$'\t'` | works |
| `source file`, `pushd`, `set -x` | works |
| `alias ll=...; ll` | fails: `"ll": executable file not found in $PATH` |
| `coproc` | fails: `unhandled command node` |
| `select` | fails |
| `shopt -s autocd`, and other options it does not know | fails: `unsupported option` |
| `printf -v VAR ...` | **wrong, with no error**: prints `-v...` and leaves `VAR` empty |
| `$BASH_VERSION`, `${PIPESTATUS[@]}` | empty |
| `**/*.go` in a command | not recursive unless `shopt: [globstar]` |

Each entry in `cmds` is a new shell. A `cd` or an `export` in one entry is lost in the
next. Use `dir:` and `env:` on the task, or one multi-line command.

When a command needs real bash, call it: `bash -c '...'`, or put the code in a script
with a `#!/usr/bin/env bash` line and run the script.

```yaml
version: "3"

tasks:
  versions:
    cmds:
      - printf -v OUT "%s" ok; echo "OUT=[$OUT]"
      - bash -c 'printf -v OUT "%s" ok; echo "OUT=[$OUT]"'
```

```text
-vOUT=[]
OUT=[ok]
```

## YAML and quoting traps

The Taskfile is YAML first. YAML reads it before the template and the shell do.

| You write | YAML reads | Fix |
| --- | --- | --- |
| `- {{.CMD}} build` | a map: parse error | quote it: `- "{{.CMD}} build"` |
| `cmds: [echo "{{.V}}"]` | a broken flow list: parse error | quote the item, or use a block list |
| `- echo key: value` | a map `{echo key: value}`: `invalid keys in command` | quote it: `- "echo key: value"` |
| `build: echo key: value` | parse error: `mapping values are not allowed` | quote it |
| `- echo "issue #42"` | `echo "issue`: ` #` starts a comment | quote the whole line: `- 'echo "issue #42"'` |

```yaml
version: "3"

vars:
  CMD: echo

tasks:
  ok:
    cmds:
      - "{{.CMD}} build"
      - "echo key: value"
      - 'echo "issue #42"'
      - echo {{.CMD}} works unquoted when it is not first
```

Rules that avoid most problems:

- Quote a command that starts with `{{`, or contains `: ` or ` #`.
- Use single quotes around a command that contains double quotes.
- Use a block scalar for long commands: `|` keeps the line breaks (one shell line per
  line), `>` joins the lines with spaces.
- A template value with quotes or `;` breaks the shell command. Pass it through
  `shellQuote`: `echo {{.MSG | shellQuote}}`.

## A variable is empty

| Symptom | Cause |
| --- | --- |
| `{{.Version}}` is empty, `{{.VERSION}}` is set | names are case-sensitive, and an unknown name gives an empty string, with no error |
| `$NAME` is empty in a command, `{{.NAME}}` works | `vars:` are not exported to the shell. Use `env:`, or the template |
| `task build NAME=x` is ignored | the task sets `NAME` in its own `vars:`, which wins. Use `'{{.NAME \| default "y"}}'` |
| the `env:` value is ignored | the variable is also set in your shell. The process environment wins |
| a `sh:` variable is empty | it can only read variables declared **before** it |
| `{{.CLI_ARGS}}` is empty | the arguments must come after `--`: `task test -- -v` |

To fail early instead of running with an empty value, list the variable in
`requires:` (see [[dev/taskfile/advanced]]).

## Paths in included Taskfiles

```text
project/
├── Taskfile.yml          includes: { docs: ./docs/Taskfile.yml }
└── docs/
    └── Taskfile.yml      tasks: { where: ... }
```

- The path in `includes:` is relative to the file that includes it.
- **Without `dir:`, the included tasks run in the root Taskfile's directory**, not in
  `docs/`. Their relative paths (and `sources`) are then wrong. Add `dir: ./docs`.
- `task` uses the Taskfile of the **current directory**, and goes up through the
  parent directories only if there is none. In `docs/`, `task where` runs
  `docs/Taskfile.yml` alone: the root tasks and the `docs:` namespace do not exist
  there. Run `task -d ..` or go back to the root.

Special variables give absolute paths:

| Variable | Value |
| --- | --- |
| `ROOT_DIR` | directory of the root Taskfile |
| `ROOT_TASKFILE` | path of the root Taskfile |
| `TASKFILE_DIR` | directory of the Taskfile that defines this task (the included one) |
| `TASK_DIR` | directory where the task's commands run (its `dir`) |
| `USER_WORKING_DIR` | directory where you typed `task` |

```yaml
version: "3"

includes:
  docs:
    taskfile: ./docs
    dir: ./docs

tasks:
  here:
    dir: "{{.USER_WORKING_DIR}}"
    cmds:
      - pwd
```

`task here` from `project/src/` prints `project/src`: use `USER_WORKING_DIR` for tasks
that work on the directory the user is in, like a formatter. Without `dir:` it would
print the project root.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | success, or the task was skipped (`if`, `platforms`, up to date) |
| 100 | no Taskfile in this directory or its parents |
| 101 | `task --init`, but a Taskfile already exists |
| 102 | valid YAML, but not a valid Taskfile (for example `invalid keys in command`) |
| 107 | no `version:`, or a version this binary does not support |
| 109 | YAML syntax error |
| 200 | the task does not exist |
| 201 | a command failed, or a precondition failed |
| 205 | cancelled at a `prompt`, or a `prompt` with no terminal and no `--yes` |
| 206 | a variable in `requires` is missing |
| 207 | a variable is not in its `enum` |

A failed command gives `201`, whatever its own code. `task -x` (`--exit-code`) exits
with the command's code instead, which is what a CI script usually wants.

## Experiments: `TASK_X_*`

Some features are behind a flag. Turn one on with an environment variable or in
`.taskrc.yml`:

```bash
task --experiments                         # list them, with on/off
TASK_X_GENTLE_FORCE=1 task --experiments   # GENTLE_FORCE: on (1)
```

- An unknown name, or a typo like `TASK_X_GENTLE_FORECE=1`, is ignored with no
  warning. Check with `task --experiments`.
- v3.54.0 has two: `GENTLE_FORCE` and `ENV_PRECEDENCE`.
- Remote Taskfiles (an `includes:` from a URL) were an experiment. Since v3.53.1 they
  are on by default: `TASK_X_REMOTE_TASKFILES` is no longer needed.
- Experiments can change or disappear in any minor release. Avoid them in shared CI.

## Taskfile versions

```text
task: Invalid schema version in Taskfile "/work/Taskfile.yml":
Schema version (2.0.0) no longer supported. Please use v3 or above
```

- `version: "2"` Taskfiles stopped working in v3.34.0. v3.33.0 is the last release
  that runs them. To migrate, set `version: "3"` and follow the
  [v3 release notes](https://github.com/go-task/task/releases/tag/v3.0.0); a
  `Taskvars.yml` file is no longer read, so move its content to `vars:`.
- A version newer than the binary also fails, with exit code `107`:
  `Schema version (3.99.0) is greater than the current version of Task (3.54.0)`.
  Use this on purpose: `version: "3.47"` tells older Task binaries to upgrade, if the
  Taskfile uses a feature from v3.47, such as `if:`.
- `version: 3` without quotes also works.
- If `task` is not the binary you expect, check `task --version` and `command -v task`.
  On some distributions the package is `go-task` and Taskwarrior owns `task` (see
  [[dev/taskfile/quickstart]]).

<!-- uplink -->
Part of [[dev/taskfile/index|Task (Taskfile)]].
