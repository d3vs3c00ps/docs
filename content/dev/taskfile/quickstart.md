---
title: Task quick start
description: Install Task (go-task), write a first Taskfile.yml, list and run tasks, pass variables and arguments, and compare it with a Makefile
tags: [dev, tooling, task, build]
type: howto
status: complete
---

# Task quick start

[Task](https://taskfile.dev) (also called go-task) is a task runner and build tool. It
reads a YAML file, `Taskfile.yml`, and runs the commands of the task you name. It is
one static Go binary with no dependencies. It runs commands with its own embedded
shell, so the same Taskfile works on Linux, macOS and Windows.

This note uses Task v3.54.0. The Taskfile format is version 3.

For the next steps, see [[dev/taskfile/advanced]] (variables, includes, up-to-date
checks), [[dev/taskfile/backup]] (backup tasks) and [[dev/taskfile/troubleshooting]].
For a build tool where the build file is Go code, see mage.

## Install

### Release binary, with its checksum

This works on any Linux, with no root access. It downloads the archive and checks it
against `task_checksums.txt`, which every release publishes:

```bash
TASK_VERSION=v3.54.0
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
TGZ=task_linux_${ARCH}.tar.gz
BASE=https://github.com/go-task/task/releases/download/${TASK_VERSION}
cd "$(mktemp -d)"
curl -fsSLO "$BASE/$TGZ"
curl -fsSL "$BASE/task_checksums.txt" | grep " ${TGZ}\$" | sha256sum -c -
tar -xzf "$TGZ" task
install -D -m 0755 task ~/.local/bin/task
~/.local/bin/task --version
```

`sha256sum -c` prints `task_linux_amd64.tar.gz: OK` and exits non-zero on a mismatch.
Add `~/.local/bin` to your `PATH` if it is not there yet. On macOS, use
`task_darwin_arm64.tar.gz` and `shasum -a 256 -c` instead.

### Release package (rpm, deb, apk)

Each release also ships Linux packages. On an RPM distribution:

```bash
VERSION=3.54.0
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
RPM=task_${VERSION}_linux_${ARCH}.rpm
BASE=https://github.com/go-task/task/releases/download/v${VERSION}
curl -fsSLO "$BASE/$RPM"
curl -fsSL "$BASE/task_checksums.txt" | grep " ${RPM}\$" | sha256sum -c -
sudo rpm -i "$RPM"
task --version
```

The package installs `/usr/bin/task`. Use the `.deb` file with `sudo dpkg -i` on Debian
or Ubuntu, and the `.apk` file on Alpine. A package installed from a file gets no
updates. For updates, use the Cloudsmith repository below.

### Package managers

| Platform | Command | Binary name |
| --- | --- | --- |
| macOS (Homebrew core) | `brew install go-task` | `task` |
| macOS (official tap) | `brew install go-task/tap/go-task` | `task` |
| macOS, one minor version | `brew install go-task/tap/go-task@3.54` | `task` |
| Arch Linux | `pacman -S go-task` | `go-task` |
| Fedora | `dnf install go-task` | `go-task` |
| Nix | `nix-env -iA nixpkgs.go-task` | `task` |
| Snap | `sudo snap install task --classic` | `task` |
| npm | `npm install -g @go-task/cli` | `task` |

The official Task repository on Cloudsmith also serves `apt`, `dnf` and `apk`
packages. Its setup scripts are `setup.deb.sh`, `setup.rpm.sh` and `setup.alpine.sh`,
under `https://dl.cloudsmith.io/public/task/task/` (the folder itself answers 404).

> [!warning] `go-task` versus `task`
> Arch and Fedora install the binary as `go-task`, because `task` is already the
> name of Taskwarrior, a to-do list tool. Use `go-task --list`, or add an alias.
> openSUSE Leap 16 has no Task package in its main repositories: use the release
> binary or the RPM above.

### With Go

Task v3.54.0 needs Go 1.26 or later to build:

```bash
go install github.com/go-task/task/v3/cmd/task@v3.54.0
"$(go env GOPATH)/bin/task" --version
```

Inside a Go project you can also pin Task in `go.mod` with
`go get -tool github.com/go-task/task/v3/cmd/task@v3.54.0`, then run `go tool task`.

## A first Taskfile

`task --init` writes a small `Taskfile.yml` in the current directory. It fails with
exit code `101` if the file already exists.

A Taskfile for a small project with shell scripts in `scripts/`:

```yaml
version: "3"

vars:
  NAME: world

tasks:
  default:
    desc: Check the scripts, then pack them
    cmds:
      - task: lint
      - task: build

  greet:
    desc: Print a greeting
    cmds:
      - echo "Hello, {{.NAME}}"

  lint:
    desc: Check the syntax of every script
    cmds:
      - bash -n scripts/*.sh

  build:
    desc: Pack the scripts into dist/
    deps: [clean]
    cmds:
      - mkdir -p dist
      - tar -czf dist/scripts.tar.gz scripts

  clean:
    silent: true
    cmds:
      - rm -rf dist

  test:
    desc: Run the test script (extra flags after --)
    dir: scripts
    cmds:
      - ./test.sh {{.CLI_ARGS}}
```

- `version: "3"` is required. Without it, Task stops with exit code `107`.
- `vars` at the top are global and can be changed from the command line.
- `desc` is the one-line help that `task --list` shows.
- `{{.NAME}}` is a Go template. Task replaces it before the shell runs the command.

## List the tasks

```bash
task --list
```

```text
task: Available tasks for this project:
* build:         Pack the scripts into dist/
* default:       Check the scripts, then pack them
* greet:         Print a greeting
* lint:          Check the syntax of every script
* test:          Run the test script (extra flags after --)
```

`--list` (`-l`) shows only tasks with a `desc`. `--list-all` (`-a`) shows all of them,
here also `clean`. Use `desc` on the tasks people should call, and leave helpers
without one.

## Run tasks

```bash
task greet
```

```text
task: [greet] echo "Hello, world"
Hello, world
```

Task prints each command, prefixed with `task: [name]`, then its output. Give several
names to run several tasks, one after the other: `task lint build`.

`task` with no name runs the task called `default`. With no `default` task, it fails
with exit code `200` (task not found).

## Variables from the command line

Put `NAME=value` after the task name:

```bash
task greet NAME=Alice
```

```text
task: [greet] echo "Hello, Alice"
Hello, Alice
```

This works because `NAME` is a global variable. A value set in the task's own
`vars:` wins over the command line. [[dev/taskfile/advanced]] shows the full order.

## Arguments after `--`

Everything after `--` goes, as one string, into `{{.CLI_ARGS}}`. This is how you pass
flags to the underlying tool:

```bash
task test -- --verbose --fast
```

```text
task: [test] ./test.sh --verbose --fast
```

## `deps` and calling another task

- **`deps`** run before the task's commands, **in parallel**. Their order in the list
  means nothing. `build` above runs `clean` first.
- **`task:` in `cmds`** calls another task **in order**, like a function call. The
  `default` task above runs `lint`, waits for it, then runs `build`.

If a dependency or a called task fails, the commands after it do not run, and `task`
exits with code `201`.

## `dir` and `silent`

- `dir: scripts` runs the task's commands in `scripts/`, relative to the Taskfile.
  This is why `test` calls `./test.sh` and not `./scripts/test.sh`. Each command
  starts in that directory: a `cd` in one command does not carry to the next.
- `silent: true` hides the `task: [clean] rm -rf dist` line. The command still runs and
  its output is still shown. `task -s NAME` makes every task silent for one run.

## Compared with a Makefile

The same `build` and `clean` targets in Make:

```make
.PHONY: build clean

build: clean
	mkdir -p dist
	tar -czf dist/scripts.tar.gz scripts

clean:
	@rm -rf dist
```

| | Make | Task |
| --- | --- | --- |
| File format | Makefile syntax, recipe lines start with a tab | YAML |
| Shell | `/bin/sh` of the system | built-in shell, same on every OS |
| Targets | files by default, `.PHONY` for commands | tasks are commands; files are opt-in with `sources`/`generates` |
| Up-to-date check | file timestamps | checksum of `sources` (default), or timestamps |
| Help | none built in | `desc` and `task --list` |
| Arguments | `make VAR=x` | `task NAME VAR=x`, and `-- args` for `CLI_ARGS` |
| Installed by default | on most Unix systems | no, one binary to install |

Make is the better choice when everyone already has it and the build is a few
commands. Task is easier to read, gives a task list for free, and behaves the same on
Windows. See mage for a third option.

<!-- uplink -->
Part of [[dev/taskfile/index|Task (Taskfile)]].
