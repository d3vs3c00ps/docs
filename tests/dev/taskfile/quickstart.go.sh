#!/usr/bin/env bash
# note: dev/taskfile/quickstart.md
# env: go
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=dev/taskfile/quickstart

section "With Go"
check_output "go is 1.26 or later, as the note requires" 'go1\.(2[6-9]|[3-9][0-9])' go version
out=$(bash -ec "$(note_block "$NOTE" 'With Go' 1)" 2>&1) && rc=0 || rc=$?
assert_eq "go install of v3.54.0 succeeds" 0 "$rc"
assert_match "and the binary reports 3.54.0" '3\.54\.0' "$out"
check_output "go get -tool, then go tool task" '3\.54\.0' \
  bash -ec 'cd "$(mktemp -d)" && go mod init example.com/x >/dev/null 2>&1 && go get -tool github.com/go-task/task/v3/cmd/task@v3.54.0 >/dev/null 2>&1 && go tool task --version'
