#!/usr/bin/env bash
# note: containers/containerd/cli.md
# env: kind
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=containers/containerd/cli
source "$NOTES_ROOT/tests/containers/containerd/containerd-lib.bash"
use_test_namespace

section "The namespace flag"
check_output "$(nline 1 1)" 'k8s.io' on_sh "$(nline 1 1)"
check_output "$(nline 1 2)" 'io.containerd.runc.v2' on_sh "$(nline 1 2)"
check_output "$(nline 1 3): kind nodes run no Docker, so the moby namespace is empty" '^CONTAINER +IMAGE +RUNTIME *$' \
  on_sh "$(nline 1 3)"
assert_eq "the default namespace is empty: not where anything you care about lives" \
  "" "$(on ctr containers list | tail -n +2)"
check_output "$(nline 2 1), then ctr without the flag" 'io.containerd.runc.v2' \
  on_sh "$(nline 2 1); ctr containers list"

section "crictl"
# The control-plane images are distroless (no shell): use a pod of our own.
kubectl run cli-probe --image=busybox:1.37 --restart=Never -- sleep 300 >/dev/null
kubectl wait --for=condition=Ready pod/cli-probe --timeout=180s >/dev/null
CP=$(kubectl get pod cli-probe -o jsonpath='{.spec.nodeName}')   # on_sh now targets that node
ID=$(on crictl ps -q --name cli-probe | head -1)
crictl_line() { nline 3 "$1" | sed "s/<container-id>/$ID/g"; }
check_output "$(nline 3 1)" 'cli-probe' on_sh "$(crictl_line 1)"
check_output "$(nline 3 2)" 'cli-probe' on_sh "$(crictl_line 2)"
check_output "$(nline 3 3)" 'cli-probe' on_sh "$(crictl_line 3)"
check_output "$(nline 3 4)" 'busybox' on_sh "$(crictl_line 4)"
check "$(nline 3 5)" on_sh "$(crictl_line 5)"
# -f follows forever: bound it.
check "$(nline 3 6) (stopped after 3 s)" on_sh "timeout 3 $(crictl_line 6) || [ \$? = 124 ]"
assert_match "the note's exec line opens a shell" 'crictl exec -it <container-id> sh' "$(nline 3 7)"
check_output "crictl exec, without -it and with a command for the shell" '^ok$' \
  on_sh "$(crictl_line 7 | sed "s/ -it / /; s/ sh\$/ sh -c 'echo ok'/")"
check_output "$(nline 3 8)" '"id"' on_sh "$(crictl_line 8)"
check "$(nline 3 9)" on_sh "$(crictl_line 9)"
check "$(nline 4 1)" on_sh "$(nline 4 1)"
check "$(nline 4 2)" on_sh "$(nline 4 2)"
check_output "crictl needs no namespace flag: it always means k8s.io" 'kube-proxy' on crictl ps --name kube-proxy

section "crictl configuration"
assert_match "the note shows /etc/crictl.yaml" 'runtime-endpoint: unix:///run/containerd/containerd.sock' \
  "$(note_block "$NOTE" 5)"
check_output "kind nodes have that file, with the same endpoint" \
  'runtime-endpoint: unix:///run/containerd/containerd.sock' on cat /etc/crictl.yaml

section "nerdctl"
skip "nerdctl run / build / compose (blocks 6 to 8)" \
  "nerdctl is not shipped on kind nodes; it needs its own install and CNI config for a Docker-like UX"

section "ctr"
# The note's ctr lines, in an order where each one has what it needs (the file to
# import is the one export writes). They run in /tmp on the node.
c() { on_sh "cd /tmp; $(nline 9 "$1")"; }
check_output "$(nline 9 2)" 'docker.io/library/alpine:latest' c 2
check_output "$(nline 9 1)" 'docker.io/library/alpine:latest' c 1
check "$(nline 9 4)" c 4
check "$(nline 9 5)" c 5
check "$(nline 9 3)" c 3
check_output "the imported image is back" 'docker.io/library/alpine:latest' c 1
check_output "$(nline 9 6) (default namespace: nothing)" '^CONTAINER' c 6
check_output "$(nline 9 7) (default namespace: no tasks)" '^TASK' c 7
check_output "$(nline 9 8), without -t and with a command" '^ok$' \
  on_sh "$(nline 9 8 | sed "s/ -t / /; s/ sh\$/ sh -c 'echo ok'/")"
check_output "$(nline 9 9) on our pod's container (k8s.io), non-interactive" '^ok$' \
  on_sh "$(nline 9 9 | sed "s/^ctr /ctr -n k8s.io /; s/ -t / /; s/<container-id>/$ID/; s/ sh\$/ sh -c 'echo ok'/")"
check_output "$(nline 9 11)" 'KEY' c 11
check "$(nline 9 12)" c 12
check_output "$(nline 9 13)" 'DIGEST' c 13
check_output "$(nline 9 14), with the CRI plugin ok" 'io.containerd.grpc.v1 +cri +.* +ok' c 14
# Last, as it signals our probe. Its default signal is SIGTERM, which `sleep` as PID 1
# ignores (no handler), so the pod keeps running; the command itself must succeed.
check "$(nline 9 10) on our pod's container (k8s.io)" \
  on_sh "$(nline 9 10 | sed "s/^ctr /ctr -n k8s.io /; s/<container-id>/$ID/")"

section "Importing images without a registry"
CP=$CLUSTER-control-plane
docker pull -q busybox:1.37 >/dev/null
docker tag busybox:1.37 myapp:1.0
cd "$(mktemp -d)"
check "$(nline 10 1) (on this machine)" bash -ec "$(nline 10 1)"
# kind mounts a tmpfs over /tmp after start, which masks docker cp; stream via exec
docker exec -i "$CP" sh -c 'cat >/tmp/myapp.tar' <myapp.tar
check "$(nline 10 2) (on the node)" on_sh "cd /tmp; $(nline 10 2)"
check_output "$(nline 10 3)" 'myapp' on_sh "$(nline 10 3)"
on ctr -n k8s.io images remove docker.io/library/myapp:1.0 >/dev/null
# the wrong-namespace trap: import into default, invisible to the CRI
on ctr images import /tmp/myapp.tar >/dev/null
check_fails "imported into 'default', the CRI cannot see it (ErrImageNeverPull trap)" \
  on_sh "$(nline 10 3)"
on ctr images remove docker.io/library/myapp:1.0 >/dev/null
docker rmi myapp:1.0 >/dev/null
