#!/usr/bin/env bash
# note: security/offensive/ai-assisted-scanning.md
# env: compose
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=security/offensive/ai-assisted-scanning
IMAGE=j3ssie/vigolium:v0.5.6
block() { note_block "$NOTE" "$@"; }
# The target is an nginx on the project's private network. The scanner's payload lists
# stay inside its container: nothing is written to the host.
cat >compose.yaml <<EOF2
services:
  web:
    image: mirror.gcr.io/library/nginx:1.29-alpine
    networks: {default: {aliases: [staging.test]}}
  vigolium:
    image: $IMAGE
    entrypoint: ["sh", "-c"]
    profiles: [tools]
EOF2
docker compose up -d --quiet-pull web 2>/dev/null
vig() { docker compose --progress quiet run --rm -T vigolium "$1"; }
retry 30 docker compose exec -T web wget -qO /dev/null http://localhost/

section "Vigolium"
check_output "the pinned image is v0.5.6, as the note names it" 'Version: v0\.5\.6' vig 'vigolium version'
check_output "native and agentic modes are scan and agent" 'agent .*agentic scan' vig 'vigolium --help'
check_output "OAST is on by default, with oast.pro (as the note warns)" 'oast.server_url = oast\.pro' vig 'vigolium config ls oast'
off=$(block 'Vigolium' 2)
check_output "the note's command turns it off" 'oast.enabled = false' vig "$off >/dev/null && vigolium config ls oast"
scan=$(block 'Vigolium' 1 | sed -e 's|^docker run --rm j3ssie/vigolium:v0.5.6 |vigolium |' -e 's|https://staging.example.com|http://staging.test|')
# OAST off and no external-harvest phase (it queries internet archives about the target).
out=$(vig "$off >/dev/null && $scan --strategy lite --skip external-harvest -S 2>&1" 2>&1) && rc=0 || rc=$?
assert_eq "scan -t runs a native scan to the end (from the note)" 0 "$rc"
assert_match "and reports on the target" 'staging\.test' "$out"

section "Pointing it at a local model"
check_output "the provider and endpoint settings (from the note)" \
  'agent.olium.custom_provider.base_url = http://localhost:8080/v1' \
  vig "$(block 'Pointing it at a local model' 1) >/dev/null && vigolium config ls agent.olium"
check_output "the default endpoint is Ollama's" 'custom_provider.base_url = http://localhost:11434/v1' vig 'vigolium config ls agent.olium'
check_output "and the model" 'custom_provider.model_id = qwen-27b' \
  vig "$(block 'Pointing it at a local model' 1) >/dev/null && vigolium config ls agent.olium"
skip "an agentic scan" "needs a model of about 27B behind the endpoint"

section "Lyrie"
skip "Lyrie" "no release to run; the facts are checked against the announcement"
