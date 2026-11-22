#!/usr/bin/env bash
# note: kubernetes/mlops/ollama-intro.md
# env: kind
# timeout: 3600
# The "Quick demo" commands need Ollama on a local machine: they run in the Ollama pod
# instead. kubectl run -it becomes -i (no terminal here). Big downloads: ~2 GB image, ~1 GB model.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/mlops/ollama-intro
HOME=$(mktemp -d)
export HOME
cd "$HOME"
run() { kubectl wait --for=delete pod/httpclient --timeout=120s >/dev/null 2>&1 || true; bash -ec "${1// -it / -i }" 2>&1 </dev/null; }
case $(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}') in
amd64) HEY=nixery.dev/hey ;;
*) HEY=nixery.dev/arm64/hey ;;
esac

section "Ollama on Kubernetes: kubectl run"
assert_match "the note pins the tested image" "ollama/ollama:$OLLAMA_VERSION" "$(note_block "$NOTE" 8)"
check "kubectl run ollama (from the note)" run "$(note_block "$NOTE" 8)"
check "wait for the pod (from the note)" run "$(note_block "$NOTE" 9)"
check_output "ollama run pulls the model, and answers (from the note)" '[A-Za-z]{3,}' run "$(note_block "$NOTE" 10)"
section "Other useful commands, in the pod"
check_output "ollama show (from the note)" 'architecture +qwen2' run "kubectl exec ollama -- $(note_block "$NOTE" 4)"
check_output "ollama list: the model is on disk (from the note)" '^qwen2:1.5b ' run "kubectl exec ollama -- $(note_block "$NOTE" 5)"
check_output "ollama ps: and in memory (from the note)" '^qwen2:1.5b .*minutes? from now' run "kubectl exec ollama -- $(note_block "$NOTE" 6)"
check_output "(unloaded after 5 minutes by default, from the note)" '^qwen2:1.5b .*(4|5) minutes from now' run "kubectl exec ollama -- $(note_block "$NOTE" 6)"
check "ollama stop unloads it (from the note)" run "kubectl exec ollama -- $(note_block "$NOTE" 7)"
check_output "(ollama ps is empty)" '^NAME +ID +SIZE +PROCESSOR +' run "kubectl exec ollama -- $(note_block "$NOTE" 6) | tail -1"
check "delete the pod (from the note)" run "$(note_block "$NOTE" 11) --wait=true"

section "Deployment + Service"
check "kubectl create deployment (from the note)" run "$(note_block "$NOTE" 12)"
check "kubectl create service on port 11434 (from the note)" run "$(note_block "$NOTE" 13)"
check_output "(the original port 11343 is not the port Ollama listens on: the correction)" 'Listening on .*:11434' bash -c \
  "kubectl rollout status deploy/ollama --timeout=600s >/dev/null; kubectl logs deploy/ollama"
check "wait for the Service Endpoints (from the note)" run "$(note_block "$NOTE" 14) --timeout=120s"
check_output "/api/generate before the pull: the model is not found (from the note)" 'model .{0,2}qwen2:1.5b.{0,2} not found' run "$(note_block "$NOTE" 15)"
check "pull, method 1 (from the note)" run "$(note_block "$NOTE" 16)"
check_output "pull, method 2, through the API (from the note)" '"status": ?"success"' run "$(note_block "$NOTE" 17)"
check_output "now /api/generate answers, streaming one JSON object per token" '"done": ?false' run "$(note_block "$NOTE" 15)"
kubectl delete deployment,service ollama --wait=true >/dev/null

section "Helm chart"
check_output "the original --set ollama.models={...} does not fit the current chart (the correction)" 'Error|error' bash -c \
  "helm template x ollama --repo https://otwld.github.io/ollama-helm/ --version $OLLAMA_CHART --set ollama.models={qwen2:1.5b} 2>&1 | head -3; true"
assert_match "the note pins the tested chart" "--version $OLLAMA_CHART" "$(note_block "$NOTE" 19)"
check "helm upgrade --install, pre-pulling the model (from the note)" run "$(note_block "$NOTE" 19) --wait --timeout 20m"
check "and again: it is idempotent (from the note)" run "$(note_block "$NOTE" 19) --wait --timeout 20m"
check_output "the model was pre-pulled" '^qwen2:1.5b ' kubectl exec deploy/ollama -- ollama list
check_output "/api/generate with stream:=false: one JSON answer (from the note)" '"done": ?true' run "$(note_block "$NOTE" 20)"
check_output "top: ollama, and the LLM subprocess llama-server, over 1 GB (from the note)" ' ollama .* [0-9.]+g +[0-9]+ +[A-Z] .* llama-s' bash -c \
  "kubectl exec deploy/ollama -- ollama run qwen2:1.5b 'Say hi' >/dev/null; kubectl exec deploy/ollama -- top -b -n1 | grep -E ' (ollama|llama-s.*)$' | tr '\n' ' '"

section "Sending some load"
# docker pull --platform accepts a single-arch image without complaint: read the image's architecture.
check_output "nixery.dev/hey is an amd64 image only (the note's remark)" '^amd64$' bash -c \
  "docker pull -q nixery.dev/hey >/dev/null && docker image inspect nixery.dev/hey --format '{{.Architecture}}'"
check_output "hey -c 10 -n 10 (from the note, image for this architecture)" 'Status code distribution:' \
  run "$(note_block "$NOTE" 23 | sed "s|nixery.dev/hey|$HEY|")"
