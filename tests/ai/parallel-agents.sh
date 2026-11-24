#!/usr/bin/env bash
# note: ai/parallel-agents.md
# env: go
# timeout: 300
# The git worktree pattern runs for real. Zed is a desktop editor and is not run; the
# Ollama parts are checked against the library and the pinned source.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=ai/parallel-agents
block() { note_block "$NOTE" "$@"; }

section "Through Ollama"
for m in $(block 'Through Ollama' 1 | awk '/^ollama pull/ { print $3 }'); do
  check_output "$m exists in the Ollama library (from the note)" '^200$' \
    curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://registry.ollama.ai/v2/library/${m%%:*}/manifests/${m##*:}"
done
cfg=$(curl -sf "https://raw.githubusercontent.com/ollama/ollama/v$OLLAMA_VERSION/envconfig/config.go")
assert_match "OLLAMA_MAX_LOADED_MODELS defaults to 0, automatic: no override needed for two models (the correction)" \
  'Uint\("OLLAMA_MAX_LOADED_MODELS", 0\)' "$cfg"
assert_match "the override block is a valid drop-in: it has a [Service] section" '^\[Service\]' "$(block 'Through Ollama' 2)"

section "Worktrees outside Zed"
git config --global user.email t@example.com && git config --global user.name t
mkdir -p /work/pa/tasks-app && cd /work/pa/tasks-app && git init -q && git commit -q --allow-empty -m init
check "git worktree add, twice (from the note)" bash -c "$(block 'Worktrees outside Zed' 1 | grep 'worktree add')"
check_output "git worktree list shows the three trees (from the note)" '\[feature/api\].*\[feature/tests\]' \
  bash -c 'git worktree list | tr "\n" " "'
check_output "the same branch cannot be checked out twice (the note)" 'already (checked out|used by worktree)' \
  bash -c 'git worktree add ../again feature/api 2>&1; true'

skip "Zed agent panel, threads and settings" "Zed is a desktop editor"
skip "keeping a 27B and a 9B resident" "needs about 22 GB; the default is checked in the source above"
