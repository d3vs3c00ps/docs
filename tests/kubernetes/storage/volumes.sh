#!/usr/bin/env bash
# note: kubernetes/storage/volumes.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=kubernetes/storage/volumes
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
use_test_namespace
# The note's commands read ~/container.training/k8s/...: a fake HOME holds those files.
HOME=$(mktemp -d)
export HOME
cd "$HOME"
mkdir -p container.training/k8s
for f in nginx-1-without-volume nginx-2-with-volume nginx-3-with-git nginx-4-with-init; do
  curl -fsSL "$UPSTREAM/k8s/$f.yaml" >"container.training/k8s/$f.yaml"
done
CP=$CLUSTER-control-plane
run() { bash -ec "$1" 2>&1; }
# on_node CMD: run CMD on a node, where pod IPs are reachable; IPADDR and IP are passed.
on_node() { docker exec -e IPADDR="${IPADDR:-}" -e IP="${IP:-}" "$CP" bash -c "$1" 2>&1; }
ready() { kubectl wait --for=condition=Ready "pod/$1" --timeout=180s >/dev/null; }
# init_status: the STATUS column of nginx-with-init, polled until it shows the init phase.
init_status() {
  local i s=
  for i in $(seq 1 100); do
    s=$(kubectl get pod nginx-with-init --no-headers 2>/dev/null | awk '{print $3}')
    case $s in Init:* | PodInitializing) echo "$s"; return 0 ;; esac
    sleep 0.3
  done
  echo "never saw the init phase, last status: $s"
  return 1
}

section "Volumes ≠ Persistent Volumes"
check_fails "volumes are not an API resource" kubectl get volumes
check "persistentvolumes are" kubectl get persistentvolumes

section "Our basic Pod"
assert_eq "the inline YAML is the upstream file" "$(cat container.training/k8s/nginx-1-without-volume.yaml)" \
  "$(note_block "$NOTE" 2)"
check "create the Pod (from the note)" run "$(note_block "$NOTE" 3)"
ready nginx-without-volume
eval "$(note_block "$NOTE" 4)"
check_output "curl shows the Welcome page (from the note, on a node)" 'Welcome to nginx' on_node "$(note_block "$NOTE" 5)"

section "The Pod with a volume"
assert_eq "the inline YAML is the upstream file" "$(cat container.training/k8s/nginx-2-with-volume.yaml)" \
  "$(note_block "$NOTE" 6)"
check "create the Pod (from the note)" run "$(note_block "$NOTE" 7)"
ready nginx-with-volume
eval "$(note_block "$NOTE" 8)"
check_output "the empty volume shadows the html directory: 403 Forbidden (from the note)" '403 Forbidden' \
  on_node "$(note_block "$NOTE" 9)"
check_output "with no type, the volume is an emptyDir" '^\{\}$' \
  kubectl get pod nginx-with-volume -o jsonpath='{.spec.volumes[0].emptyDir}'

section "Sharing a volume between two containers"
assert_eq "the inline YAML is the upstream file" "$(cat container.training/k8s/nginx-3-with-git.yaml)" \
  "$(note_block "$NOTE" 10)"
check "create the pod (from the note)" run "$(note_block "$NOTE" 12)"
retry 120 bash -c '[ -n "$(kubectl get pod nginx-with-git -o jsonpath={.status.podIP})" ]'
IP=$(kubectl get pod nginx-with-git -o jsonpath='{.status.podIP}')
# The first request races the git container: 403 if we are fast enough, the site if not.
first=$(on_node "$(note_block "$NOTE" 13) || true")
assert_match "the first request: 403 Forbidden, or already the site" '403 Forbidden|Spoon-Knife|<html' "$first"
retry 120 bash -c "docker exec $CP curl -s $IP | grep -q Spoon-Knife"
check_output "a few seconds later: the Spoon-Knife page (from the note)" 'Spoon-Knife' on_node "$(note_block "$NOTE" 14)"
retry 60 bash -c '[ "$(kubectl get pod nginx-with-git -o jsonpath="{.status.containerStatuses[?(@.name==\"git\")].state.terminated.reason}")" = Completed ]'
check_output "restartPolicy: OnFailure: git completed and is not restarted" '^0$' \
  kubectl get pod nginx-with-git -o jsonpath='{.status.containerStatuses[?(@.name=="git")].restartCount}'

section "Init Containers"
assert_eq "the inline YAML is the upstream file" "$(cat container.training/k8s/nginx-4-with-init.yaml)" \
  "$(note_block "$NOTE" 15)"
check "create the pod (from the note)" run "$(note_block "$NOTE" 16)"
check_output "nginx does not start while the init container runs" 'PodInitializing|Init:0/1' \
  init_status
ready nginx-with-init
IP=$(kubectl get pod nginx-with-init -o jsonpath='{.status.podIP}')
check_output "once up, it serves the site at once: never 403" 'Spoon-Knife' on_node 'curl -s $IP'
check "nginx started after git finished" bash -c '
  f=$(kubectl get pod nginx-with-init -o jsonpath="{.status.initContainerStatuses[0].state.terminated.finishedAt}")
  s=$(kubectl get pod nginx-with-init -o jsonpath="{.status.containerStatuses[0].state.running.startedAt}")
  [[ $(date -d "$s" +%s) -ge $(date -d "$f" +%s) ]]'

section "Volume lifecycle"
on_node "curl -s $IP >/dev/null"
kubectl exec nginx-with-init -c nginx -- sh -c 'echo survived >/usr/share/nginx/html/mark.txt'
kubectl exec nginx-with-init -c nginx -- sh -c 'kill 1'
retry 60 bash -c '[ "$(kubectl get pod nginx-with-init -o jsonpath="{.status.containerStatuses[0].restartCount}")" -ge 1 ]'
ready nginx-with-init
check_output "the volume survives a container restart" 'survived' \
  kubectl exec nginx-with-init -c nginx -- cat /usr/share/nginx/html/mark.txt

section "Sidecars"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: batch/v1
kind: Job
metadata: {name: with-sidecar}
spec:
  template:
    spec:
      restartPolicy: Never
      initContainers:
      - name: sidecar
        image: alpine
        restartPolicy: Always
        command: [sh, -c, 'while true; do sleep 1; done']
      containers:
      - name: main
        image: alpine
        command: [sh, -c, 'sleep 5']
EOF
check "a sidecar (an initContainer with restartPolicy: Always) does not prevent the Job from completing" \
  kubectl wait --for=condition=complete job/with-sidecar --timeout=180s
check_output "the sidecar was started before main" '^sidecar$' \
  kubectl get pod -l job-name=with-sidecar -o jsonpath='{.items[0].spec.initContainers[0].name}'
