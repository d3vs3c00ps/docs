#!/usr/bin/env bash
# note: kubernetes/observability/healthchecks.md
# env: kind
# timeout: 900
# A concept note: its two example manifests run with real images, and its claims
# about defaults and probe behavior are checked on kind.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
use_test_namespace

NOTE=kubernetes/observability/healthchecks
cd "$(mktemp -d)"
restarts() { kubectl get pod "$1" -o jsonpath='{.status.containerStatuses[0].restartCount}'; }
ready() { kubectl get pod "$1" -o jsonpath='{.status.containerStatuses[0].ready}'; }
# worker NAME DELAY [PROBE_SED]: the note's exec example; the worker creates /tmp/ready after DELAY s.
worker() {
  note_block "$NOTE" 2 | sed "s/name: queueworker/name: $1/; s|image: myregistry.../worker:v1.0|image: busybox:1.37\n    command: [sh, -c, 'sleep $2; touch /tmp/ready; sleep 3600']|; ${3:-}" |
    kubectl apply -f - >/dev/null
}

section "Healthchecks are optional"
kubectl run noprobe --image=busybox:1.37 -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/noprobe --timeout=120s >/dev/null
check_output "no probe: the container is considered healthy (ready)" '^true$' ready noprobe

section "Timing and thresholds: the defaults"
d=$(note_block "$NOTE" 1 | sed 's|myregistry.../frontend:v1.0|nginx:1.29|' |
  kubectl create --dry-run=server -f - -o jsonpath='{.spec.containers[0].readinessProbe}')
for kv in '"periodSeconds":10' '"timeoutSeconds":1' '"successThreshold":1' '"failureThreshold":3'; do
  assert_match "default $kv (from the note)" "$kv" "$d"
done
assert_no_match "initialDelaySeconds defaults to 0 (not set)" 'initialDelaySeconds' "$d"
check_output "a terminating container gets 30 s by default (terminationGracePeriodSeconds)" '^30$' bash -c \
  "kubectl run x --image=busybox:1.37 --dry-run=server -o jsonpath='{.spec.terminationGracePeriodSeconds}'"

section "httpGet example"
note_block "$NOTE" 1 | sed 's|myregistry.../frontend:v1.0|nginx:1.29|' | kubectl apply -f - >/dev/null
sed 's|myregistry.../frontend:v1.0|nginx:1.29|; s/name: frontend$/name: frontend-root/; s|path: /healthz|path: /|' \
  <<<"$(note_block "$NOTE" 1)" | kubectl apply -f - >/dev/null
kubectl wait --for=condition=Ready pod/frontend-root --timeout=120s >/dev/null
check_output "200 on / is a success: Ready" '^true$' ready frontend-root
sleep 15
check_output "nginx answers 404 on /healthz: never Ready (anything else = failure)" '^false$' ready frontend
check_output "(a failing readiness probe does not restart the container)" '^0$' restarts frontend

section "Readiness: removed from the Service endpoints"
kubectl label pod frontend-root app=front >/dev/null
kubectl expose pod frontend-root --port=80 --name=front >/dev/null
retry 30 bash -c "kubectl get endpointslice -l kubernetes.io/service-name=front -o jsonpath='{.items[0].endpoints[0].conditions.ready}' | grep -qx true"
kubectl exec frontend-root -- rm /usr/share/nginx/html/index.html
retry 60 bash -c "kubectl get endpointslice -l kubernetes.io/service-name=front -o jsonpath='{.items[0].endpoints[0].conditions.ready}' | grep -qx false"
check_output "when / fails, the endpoint is not ready any more" '^false$' \
  kubectl get endpointslice -l kubernetes.io/service-name=front -o jsonpath='{.items[0].endpoints[0].conditions.ready}'
check_output "(still listed, but receives no new connections; no restart)" '^0$' restarts frontend-root

section "exec example and the startupProbe gotcha"
worker queueworker 45
worker no-threshold 45 '/failureThreshold: 30/d'
# The startup probe runs first; this liveness probe would fail at once if it ran before.
worker startup-first 20 's|      failureThreshold: 30|      failureThreshold: 30\n    livenessProbe:\n      exec:\n        command: [test, -f, /tmp/ready]\n      periodSeconds: 1\n      failureThreshold: 1|'
check "the note's exec startupProbe (failureThreshold: 30, 5 minutes) starts after 45 s" \
  kubectl wait --for=condition=Ready pod/queueworker --timeout=120s
check_output "(without restarts)" '^0$' restarts queueworker
check "without failureThreshold: 30 s (3 x 10 s) is not enough, the container is restarted" \
  retry 90 bash -c "[ \"\$(kubectl get pod no-threshold -o jsonpath='{.status.containerStatuses[0].restartCount}')\" -ge 1 ]"
check "liveness only starts after the startup probe succeeds" kubectl wait --for=condition=Ready pod/startup-first --timeout=60s
check_output "(no restart in the 20 s before /tmp/ready existed)" '^0$' restarts startup-first

section "Liveness probes restart the container"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: dead}
spec:
  containers:
  - name: c
    image: busybox:1.37
    command: [sh, -c, 'touch /tmp/alive; sleep 5; rm /tmp/alive; sleep 3600']
    livenessProbe:
      exec: {command: [test, -f, /tmp/alive]}
      periodSeconds: 2
      failureThreshold: 2
EOF
check "a failing liveness probe restarts the container" retry 60 bash -c "[ \"\$(kubectl get pod dead -o jsonpath='{.status.containerStatuses[0].restartCount}')\" -ge 1 ]"

section "Using shell constructs; grpc"
check "the sh -c exec snippet is a valid probe" bash -c \
  "printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: shellprobe}\nspec:\n  containers:\n  - name: c\n    image: busybox:1.37\n    livenessProbe:\n%s\n' \"\$(note_block $NOTE 3 | sed 's/^/    /')\" | kubectl create --dry-run=server -f -"
check "a grpc probe is accepted (GA since 1.27)" bash -c \
  "printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: g}\nspec:\n  containers:\n  - {name: c, image: busybox:1.37, readinessProbe: {grpc: {port: 9000}}}\n' | kubectl create --dry-run=server -f -"
