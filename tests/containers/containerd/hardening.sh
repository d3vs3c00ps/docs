#!/usr/bin/env bash
# note: containers/containerd/hardening.md
# env: kind
# timeout: 1800
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"

NOTE=containers/containerd/hardening
source "$NOTES_ROOT/tests/containers/containerd/containerd-lib.bash"
source "$NOTES_ROOT/tests/kubernetes/security/kyverno-lib.bash"
use_test_namespace
WORK=$(mktemp -d)
cd "$WORK"
W=$CLUSTER-worker2
cleanup() {
  kubectl delete pod --all --wait=false >/dev/null 2>&1 || true
  kubectl delete runtimeclass kata --ignore-not-found >/dev/null 2>&1 || true
  kubectl label node "$W" workload-isolation- >/dev/null 2>&1 || true
  kyverno_cleanup
  _k8s_exit
}
trap '_k8s_rc=$?; cleanup' EXIT
denied() { ! "$@" >"$WORK/out" 2>&1 && grep -q 'denied the request\|blocked due to' "$WORK/out"; }
# pod NAME [EXTRA-SPEC-YAML]: a busybox Pod manifest; EXTRA is indented under spec.
pod() {
  printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: %s}\nspec:\n%s\n  containers: [{name: app, image: busybox:1.37, args: [sleep, "300"]}]\n' \
    "$1" "${2:-}"
}

section "The socket is the whole security boundary"
check_output "$(nline 1 1): root-owned, not world-accessible" '^srw-rw---- +[0-9]+ root root' on_sh "$(nline 1 1)"
check "Kyverno is installed (as in kubernetes/security/kyverno)" kyverno_install
kyverno_wait
note_block "$NOTE" 2 >socket-policy.yaml
check "the note's socket-mount policy loads (Kyverno 1.19)" retry 30 kubectl apply -f socket-policy.yaml
kubectl wait --for=condition=Ready clusterpolicy/block-container-socket-mounts --timeout=120s >/dev/null
hostpath() { pod "$1" "  volumes: [{name: h, hostPath: {path: $2}}]" >"$1.yaml"; }
hostpath sock /run/containerd/containerd.sock
hostpath dsock /var/run/docker.sock
hostpath tmp /tmp
pod plain >plain.yaml
check "a Pod mounting containerd.sock is denied" denied kubectl apply --dry-run=server -f sock.yaml
assert_match "with the policy's message" 'Mounting the container runtime socket is not permitted' "$(cat "$WORK/out")"
check "so is docker.sock" denied kubectl apply --dry-run=server -f dsock.yaml
check "another hostPath is allowed by this policy" kubectl apply --dry-run=server -f tmp.yaml
check "a Pod without volumes is allowed (=(volumes) is optional)" kubectl apply --dry-run=server -f plain.yaml
kubectl delete clusterpolicy block-container-socket-mounts >/dev/null 2>&1

section "Keep the default restrictions on"
# containerd 2.x moved these keys (see containers/containerd/basics): check each key
# the note sets exists in the 2.x runtime section, so it is still a real setting.
on_sh 'containerd config default' >default.toml
runtime=$(awk "/^  \[plugins\.'io\.containerd\.cri\.v1\.runtime'/{p=1} /^  \[plugins\.'io\.containerd\.(cri\.v1\.images|gc|grpc)/{p=0} p" default.toml)
for key in $(note_block "$NOTE" 3 | sed -nE 's/^[[:space:]]*([A-Za-z_]+) = .*/\1/p' | grep -vx NoPivotRoot); do
  assert_match "containerd 2.x still has $key, in io.containerd.cri.v1.runtime" "^ *$key = " "$runtime"
done
assert_no_match "but NoPivotRoot is no longer a runc option (the note's 2.x callout)" '^ *NoPivotRoot = ' "$runtime"

section "Seccomp"
seccomp=$(note_block "$NOTE" 4 | reindent 2)
kubectl apply -f - >/dev/null <<<"$(pod seccomp-default "$seccomp")"
kubectl apply -f - >/dev/null <<<"$(pod seccomp-unset)"
kubectl wait --for=condition=Ready pod/seccomp-default pod/seccomp-unset --timeout=180s >/dev/null
check_output "the note's seccompProfile RuntimeDefault puts the process in filter mode" '^Seccomp:\s+2' \
  kubectl exec seccomp-default -- grep Seccomp /proc/1/status
check_output "without it, no filter is applied — the default is not RuntimeDefault" '^Seccomp:\s+0' \
  kubectl exec seccomp-unset -- grep Seccomp /proc/1/status
assert_eq "the kubelet setting that changes that default" 'seccompDefault: true' "$(note_block "$NOTE" 5)"
check_output "it is off on these nodes, which is why the unset pod has no filter" '^$' \
  bash -c "docker exec $CP grep -h seccompDefault /var/lib/kubelet/config.yaml || true"

section "SELinux"
for key in $(note_block "$NOTE" 6 | sed -nE 's/^[[:space:]]*([A-Za-z_]+) = .*/\1/p'); do
  assert_match "containerd 2.x still has $key, in io.containerd.cri.v1.runtime" "^ *$key = " "$runtime"
done
skip "enabling SELinux labelling" "kind nodes run on a host without SELinux enforcing"

section "User namespaces"
# The note's Pod, with a name and an image that exists.
note_block "$NOTE" 7 | sed 's/^kind: Pod$/kind: Pod\nmetadata: {name: userns}/; s|image: myapp:1.0|image: busybox:1.37\n      args: [sleep, "300"]|' >userns.yaml
check "the note's hostUsers: false Pod is accepted" kubectl apply -f userns.yaml
if kubectl wait --for=condition=Ready pod/userns --timeout=120s >/dev/null 2>&1; then
  check_output "hostUsers: false remaps container root to an unprivileged host range" \
    '^\s+0\s+[1-9][0-9]+\s+65536' kubectl exec userns -- cat /proc/self/uid_map
else
  skip "hostUsers: false pod" \
    "user namespaces need kubelet, containerd and kernel support on this node: $(kubectl get pod userns -o jsonpath='{.status.phase}')"
fi

section "Restrict which runtimes exist"
pod no-such-runtime '  runtimeClassName: does-not-exist' >no-such-runtime.yaml
check_output "a pod naming an absent RuntimeClass is rejected outright" \
  'RuntimeClass "does-not-exist" not found' bash -c 'kubectl apply -f no-such-runtime.yaml 2>&1 || true'
note_block "$NOTE" 8 >kata.yaml
check "the note's kata RuntimeClass can be created (no node has the handler)" kubectl apply -f kata.yaml
kubectl label node "$W" workload-isolation=strong --overwrite >/dev/null
kubectl apply -f - >/dev/null <<<"$(pod kata-pod '  runtimeClassName: kata')"
check_output "its scheduling.nodeSelector is merged into the pod" '"workload-isolation":"strong"' \
  kubectl get pod kata-pod -o jsonpath='{.spec.nodeSelector}'
check_output "the pod lands on the labelled node, where the sandbox fails: no kata handler" \
  'no runtime for "kata" is configured' bash -c \
  "for i in \$(seq 60); do e=\$(kubectl get events --field-selector involvedObject.name=kata-pod,reason=FailedCreatePodSandBox -o jsonpath='{.items[*].message}'); [ -n \"\$e\" ] && { echo \"\$e\"; exit; }; sleep 2; done"

section "Restrict registries"
{
  printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata: {name: internal-registry}\nspec:\n  rules:\n    - name: internal-registry\n      match: {any: [{resources: {kinds: [Pod]}}]}\n'
  note_block "$NOTE" 9 | reindent 6 | sed 's/^      validate:$/      validate:\n        failureAction: Enforce/'
} >registry-policy.yaml
check "the note's registry rule loads (in a policy, set to Enforce)" kubectl apply -f registry-policy.yaml
kubectl wait --for=condition=Ready clusterpolicy/internal-registry --timeout=120s >/dev/null
check "an image from docker.io is denied" \
  denied kubectl run from-hub --image=busybox:1.37 --restart=Never --dry-run=server
assert_match "with the note's message" 'Images must come from the internal registry' "$(cat "$WORK/out")"
check "an image from registry.example.com is admitted" \
  kubectl run from-internal --image=registry.example.com/team/app:1.0 --restart=Never --dry-run=server

section "Audit it"
skip "auditd watches on the socket and config (block 10)" \
  "no auditd on kind nodes; the rules' syntax and persistence are tested in security/auditd"

section "CIS checks worth knowing"
check "$(nline 11 1) (on a node)" on_sh "$(nline 11 1)"
check "$(nline 11 2) (on a node)" on_sh "$(nline 11 2)"
check_output "the file now matches what kube-bench expects" '^-rw------- .* root root' \
  on ls -l /etc/containerd/config.toml

section "Keep it patched"
check_output "$(nline 12 1)" 'containerd github.com/containerd/containerd/v2' on_sh "$(nline 12 1)"
check_output "$(nline 12 2): a separate package, tracked separately" 'runc version' on_sh "$(nline 12 2)"
