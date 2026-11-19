#!/usr/bin/env bash
# note: kubernetes/observability/healthchecks-more.md
# env: kind
# timeout: 900
# kns is replaced by -n yellow (it would change the shared kubeconfig); httping is not
# installed; ab runs in a pod, because ClusterIPs answer only inside the cluster here.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/observability/healthchecks-more
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
HOME=$(mktemp -d)
export HOME
cd "$HOME"
cleanup() {
  kubectl delete namespace yellow --ignore-not-found --wait=false >/dev/null 2>&1 || true
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
run() { bash -ec "$1" 2>&1; }
ky() { kubectl -n yellow "$@"; }
export -f ky   # also used inside bash -c

section "Do we have HTTP endpoints that we can use?"
for f in hasher/hasher.rb:1 rng/rng.py:2 webui/webui.js:3; do
  src=$(curl -fsSL "$UPSTREAM/dockercoins/${f%:*}")
  while read -r l; do
    [ -n "$l" ] && assert_match "${f%:*} has: $l" "$(printf '%s' "$l" | sed 's/[][\.*^$/(){}|+?]/\\&/g')" "$src"
  done <<<"$(note_block "$NOTE" "${f#*:}")"
done
check_output "rng sleeps 0.1 s per request on /<n> (from the note)" 'time.sleep\(0.1\)' \
  bash -c "curl -fsSL $UPSTREAM/dockercoins/rng/rng.py"

section "Running DockerCoins"
check "create the yellow namespace (from the note)" run "$(note_block "$NOTE" 4)"
check "clone kubercoins (from the note)" run "$(note_block "$NOTE" 6)"
cd kubercoins
check_output "the rng manifest is a Deployment (the note said DaemonSet)" '^kind: Deployment$' grep '^kind:' rng-deployment.yaml

section "Adding the liveness probe"
probe=$(note_block "$NOTE" 8 | sed -n '/^  livenessProbe:/,$p' | sed 's/^/      /')
assert_match "the snippet's probe is indented under the container (the correction)" '^ +livenessProbe:' "$probe"
awk -v p="$probe" '{print} /^        name: rng$/{print p}' rng-deployment.yaml >x && mv x rng-deployment.yaml
check_output "the probe is now in the rng container" '"initialDelaySeconds":30' bash -c \
  "kubectl create --dry-run=client -f rng-deployment.yaml -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}'"
check "kubectl apply -f . (from the note, in yellow)" run "$(note_block "$NOTE" 10) -n yellow"
check "rng runs" ky rollout status deploy/rng --timeout=180s

section "Testing the liveness probe"
check_output "kubectl get svc rng (from the note)" '^rng +ClusterIP' run "$(note_block "$NOTE" 11) -n yellow"
CLUSTERIP=$(ky get svc rng -o jsonpath='{.spec.clusterIP}')
assert_match "the CLUSTERIP line (from the note)" '^ *CLUSTERIP=\$\(kubectl get svc rng' "$(note_block "$NOTE" 12)"
ky rollout status deploy/rng --timeout=180s >/dev/null
check_output "a request to /1 takes about 0.1 s" '^0\.1' bash -c \
  "ky run t --rm -i --restart=Never --image=curlimages/curl:8.17.0 -- curl -s -o /dev/null -w '%{time_total}' http://$CLUSTERIP/1 2>/dev/null"
sleep 30   # past initialDelaySeconds

section "Generating traffic"
ab=$(note_block "$NOTE" 16 | sed "s/\$CLUSTERIP/$CLUSTERIP/")
ky run ab --restart=Never --image=httpd:2.4-alpine -- sh -c "$ab" >/dev/null
check "with ab -c 10 (from the note), the liveness probe fails and rng is restarted" retry 120 bash -c \
  "[ \"\$(ky get pod -l app=rng -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')\" -ge 1 ]"
check_output "(the events say why: Liveness probe failed)" 'Liveness probe failed' bash -c \
  "ky get events --field-selector reason=Unhealthy -o jsonpath='{.items[*].message}'"
