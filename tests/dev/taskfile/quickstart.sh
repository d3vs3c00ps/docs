#!/usr/bin/env bash
# note: dev/taskfile/quickstart.md
# env: task
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=dev/taskfile/quickstart
block() { note_block "$NOTE" "$@"; }

section "Install: release binary, with its checksum"
out=$(HOME=$(mktemp -d) bash -ec "$(block 'Release binary, with its checksum')" 2>&1) && rc=0 || rc=$?
assert_eq "the download, checksum and install block succeeds" 0 "$rc"
assert_match "sha256sum -c prints OK" 'task_linux_(amd64|arm64)\.tar\.gz: OK' "$out"
assert_match "the installed binary is v3.54.0" '^3\.54\.0$' "$(tail -1 <<<"$out")"
check_fails "sha256sum -c fails on a wrong checksum" \
  bash -c 'echo x >f.tar.gz && echo "0000000000000000000000000000000000000000000000000000000000000000  f.tar.gz" | sha256sum -c -'

section "Install: release package"
# The container runs as root and has no sudo.
out=$(cd "$(mktemp -d)" && bash -ec "$(block 'Release package' | sed 's/^sudo //')" 2>&1) && rc=0 || rc=$?
assert_eq "the rpm block installs the package" 0 "$rc"
assert_match "the rpm checksum is checked" 'task_3\.54\.0_linux_(amd64|arm64)\.rpm: OK' "$out"
check_output "the package installs /usr/bin/task" '^3\.54\.0$' /usr/bin/task --version
check_output "rpm owns /usr/bin/task" '^task-3\.54\.0' rpm -qf /usr/bin/task

section "Install: package managers"
check_output "Leap 16 has no go-task package in its main repositories" 'No matching items found' \
  bash -c 'zypper -n search -x go-task 2>&1; true'
skip "Homebrew, pacman, dnf, Nix, Snap and npm commands" "each needs its own OS or package manager; names checked against the official installation page and the Arch/Fedora package file lists"
skip "go install" "covered by quickstart.go.sh, in the go environment"

section "A first Taskfile"
P=$(mktemp -d) && cd "$P"
check "task --init writes a Taskfile" task --init
check_output "the generated Taskfile runs" 'Hello, world!' task
out=$(task --init 2>&1) && rc=0 || rc=$?
assert_eq "a second --init fails with 101" 101 "$rc"
rm -f Taskfile.yml
block 'A first Taskfile' 1 >Taskfile.yml
mkdir scripts
printf '#!/bin/sh\necho hello\n' >scripts/hello.sh
printf '#!/bin/sh\necho "test.sh args: $*"\necho "test.sh cwd: $(pwd)"\n' >scripts/test.sh
chmod +x scripts/*.sh
check "the note's Taskfile parses" task --list
sed '/^version:/d' Taskfile.yml >noversion.yml
out=$(task -t noversion.yml greet 2>&1) && rc=0 || rc=$?
assert_eq "a Taskfile without version: fails with 107" 107 "$rc"

section "List the tasks"
expected=$(block 'List the tasks' 2)
assert_eq "task --list prints exactly the note's output" "$expected" "$(bash -c "$(block 'List the tasks' 1)" 2>&1)"
check_output "--list-all also shows clean" '^\* clean: *$' task --list-all
check_fails "--list hides clean" bash -c 'task --list | grep -q clean'

section "Run tasks"
assert_eq "task greet prints the note's output" "$(block 'Run tasks' 2)" "$(bash -c "$(block 'Run tasks' 1)" 2>&1)"
check_output "task lint build runs both" 'task: \[lint\].*' task lint build
assert_file "build wrote the archive" dist/scripts.tar.gz
check_output "task with no name runs default (lint, then build)" \
  '\[lint\][^$]*\[build\]' bash -c 'task 2>&1 | tr "\n" " "'
printf 'version: "3"\ntasks:\n  other: echo x\n' >nodefault.yml
out=$(task -t nodefault.yml 2>&1) && rc=0 || rc=$?
assert_eq "no default task: exit code 200" 200 "$rc"

section "Variables from the command line"
assert_eq "NAME=Alice prints the note's output" "$(block 'Variables from the command line' 2)" \
  "$(bash -c "$(block 'Variables from the command line' 1)" 2>&1)"
cat >taskvar.yml <<'EOF'
version: "3"
tasks:
  greet:
    vars:
      NAME: from-task
    cmds:
      - echo "Hello, {{.NAME}}"
EOF
check_output "a task's own vars win over the command line" 'Hello, from-task' task -t taskvar.yml greet NAME=Alice

section "Arguments after --"
out=$(bash -c "$(block 'Arguments after' 1)" 2>&1)
assert_match "the command line shown in the note" "$(block 'Arguments after' 2 | sed 's/[][]/\\&/g')" "$out"
assert_match "the script got the arguments" 'test.sh args: --verbose --fast' "$out"

section "deps and calling another task"
cat >order.yml <<'EOF'
version: "3"
tasks:
  slow: sleep 1; echo slow-done
  fast: echo fast-done
  par:
    deps: [slow, fast]
    cmds: [echo par-cmd]
  seq:
    cmds:
      - task: slow
      - task: fast
  bad: exit 3
  needs-bad:
    deps: [bad]
    cmds: [echo never]
EOF
check_output "deps run in parallel: fast finishes before slow" 'fast-done.*slow-done.*par-cmd' \
  bash -c 'task -s -t order.yml par 2>&1 | tr "\n" " "'
check_output "task: calls run in order: slow, then fast" 'slow-done.*fast-done' \
  bash -c 'task -s -t order.yml seq 2>&1 | tr "\n" " "'
out=$(task -t order.yml needs-bad 2>&1) && rc=0 || rc=$?
assert_eq "a failed dependency: exit code 201" 201 "$rc"
assert_no_match "and the task's commands do not run" 'never' "$out"
check_output "build runs clean first (deps)" 'tar -czf' task build

section "dir and silent"
check_output "dir: the test task runs in scripts/" "test.sh cwd: $P/scripts\$" task test
check_fails "silent: true hides the clean command line" bash -c 'task clean 2>&1 | grep -q "rm -rf"'
assert_no_file "but the command ran" dist
check_fails "task -s hides the command lines of every task" bash -c 'task -s greet 2>&1 | grep -q "task: \["'
cat >cd.yml <<'EOF'
version: "3"
tasks:
  cd:
    cmds:
      - cd /tmp
      - pwd
EOF
check_output "a cd does not carry to the next command" "^$P\$" task -s -t cd.yml cd

section "Compared with a Makefile"
zypper -n -q install --no-recommends make >/dev/null
block 'Compared with a Makefile' 1 >Makefile
check "the note's Makefile runs" make build
assert_file "and builds the same archive" dist/scripts.tar.gz
check_fails "make hides the @ line, like silent: true" bash -c 'make clean | grep -q "rm -rf"'
