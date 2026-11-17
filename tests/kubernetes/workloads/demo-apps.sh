#!/usr/bin/env bash
# note: kubernetes/workloads/demo-apps.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace
# retry_out N CMD...: like retry, but prints the output of the first run that exits 0 with
# some output. retry discards output, so check_output cannot use it.
retry_out() {
  local n=$1 i out=
  shift
  for ((i = 1; i <= n; i++)); do
    out=$("$@" 2>&1) && [[ -n $out ]] && { printf '%s\n' "$out"; return 0; }
    sleep 1
  done
  printf '%s\n' "$out"
  return 1
}

NOTE=kubernetes/workloads/demo-apps
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
cd "$(mktemp -d)"
export HOME=$PWD
# The runner shares the host network with other tests: no fixed local port.
PORT=$((20000 + RANDOM % 20000))
archs() { docker manifest inspect "$1" | jq -r '.manifests[].platform | "\(.os)/\(.architecture)\(if .variant then "/" + .variant else "" end)"' | sort -u | tr '\n' ' '; }

section "The color app"
for img in jpetazzo/color ghcr.io/jpetazzo/color; do
  a=$(archs "$img" 2>/dev/null || true)
  if [[ -z $a ]]; then
    skip "$img is published for amd64, arm64, arm/v7" "cannot read the manifest (registry rate limit?)"
  else
    check "$img is published for amd64, arm64, arm/v7 ($a)" bash -c "grep -q 'linux/amd64' <<<'$a' && grep -q 'linux/arm64' <<<'$a' && grep -q 'linux/arm/v7' <<<'$a'"
  fi
done

section "The color app in action"
check "create and expose the blue Deployment (from the note)" bash -ec "$(note_block "$NOTE" 'app in action' 1)"
check "deploy/blue becomes available" kubectl rollout status deploy/blue --timeout=300s
check_output "the Service sends traffic to port 80" '^80$' kubectl get svc blue -o jsonpath='{.spec.ports[0].targetPort}'
{ bash -c "$(note_block "$NOTE" 'app in action' 2 | sed "s/8080:/$PORT:/")" >pf.log 2>&1 & } 2>/dev/null
pf=$!
page=$(retry_out 20 bash -c "$(note_block "$NOTE" 'app in action' 3 | sed "s/8080/$PORT/")")
kill "$pf" 2>/dev/null || true
check "curl through the port-forward answers (from the note)" test -n "$page"
assert_match "the page shows the Pod's hostname, blue-..." 'blue-[a-z0-9]+-[a-z0-9]+' "$page"
assert_match "the background is blue" 'background[-a-z]*: *blue|bgcolor="?blue' "$page"
check "the page contains \\r characters to hide the HTML tags" bash -c "grep -q \$'\\r' <<<\"\$1\"" _ "$page"

section "Dockercoins"
compose=$(curl -fsSL "$UPSTREAM/dockercoins/compose.yml")
check_output "the Compose file has 5 services" '^hasher redis rng webui worker $' \
  bash -c "sed -n 's/^  \([a-z]*\):\$/\1/p' <<<\"\$1\" | sort | tr '\n' ' '" _ "$compose"

section "The repository"
check "the repository URL answers" git ls-remote --exit-code https://github.com/jpetazzo/container.training HEAD

section "Cloning the repo"
url=$(note_block "$NOTE" 'Cloning the repo' 1 | awk '{ print $3 }')
check_output "the shortcut $url redirects to the GitHub repository" 'github.com/jpetazzo/container.training' \
  bash -c "git ls-remote --exit-code '$url' HEAD 2>&1"
mkdir -p container.training/k8s
curl -fsSL "$UPSTREAM/k8s/dockercoins.yaml" -o container.training/k8s/dockercoins.yaml
curl -fsSL "$UPSTREAM/k8s/rainbow.yaml" -o container.training/k8s/rainbow.yaml

section "Running Dockercoins"
check "kubectl apply dockercoins.yaml (from the note)" bash -ec "$(note_block "$NOTE" 'Running Dockercoins' 1)"
check_output "webui is a NodePort Service" '^NodePort$' kubectl get svc webui -o jsonpath='{.spec.type}'
for d in hasher redis rng webui worker; do
  check "deploy/$d becomes available" kubectl rollout status "deploy/$d" --timeout=300s
done
check_output "images are dockercoins/<component>:v0.1" '^dockercoins/hasher:v0.1 dockercoins/rng:v0.1 dockercoins/webui:v0.1 dockercoins/worker:v0.1 $' \
  bash -c "kubectl get deploy -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{\"\\n\"}{end}' | grep dockercoins | tr '\n' ' '"
check_output "the worker reaches http://hasher/ through DNS" '[1-9][0-9]* units of work done' \
  retry_out 90 bash -c "kubectl logs deploy/worker | grep -E '[1-9][0-9]* units of work done'"

section "Details"
skip "rng caps the graph at 10 hashes/second" "measured in kubernetes/workloads/scalingdockercoins and kubectlscale"

section "More colors"
check_output "rainbow.yaml creates the namespaces blue, green, red" '^blue green red $' \
  bash -c "kubectl apply --dry-run=client -f container.training/k8s/rainbow.yaml -o jsonpath='{range .items[?(@.kind==\"Namespace\")]}{.metadata.name}{\"\\n\"}{end}' | sort | tr '\n' ' '"
check_output "with a color Deployment in each" '^blue/jpetazzo/color green/jpetazzo/color red/jpetazzo/color $' \
  bash -c "kubectl apply --dry-run=client -f container.training/k8s/rainbow.yaml -o jsonpath='{range .items[?(@.kind==\"Deployment\")]}{.metadata.namespace}/{.spec.template.spec.containers[0].image}{\"\\n\"}{end}' | sort | tr '\n' ' '"
