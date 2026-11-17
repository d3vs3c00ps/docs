#!/usr/bin/env bash
# note: kubernetes/security/pod-security-admission.md
# env: kind
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/security/pod-security-admission
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
WORK=$(mktemp -d)
cd "$WORK"
# The note labels every namespace and edits the API server manifest: own cluster.
C=psa
CP=$C-control-plane
kind_cluster "$C"
kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" >/dev/null 2>&1
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null

# A harmless pod that baseline forbids (hostNetwork), and one that only
# restricted would flag (runs as root, no securityContext).
hostnet_pod() {
  kubectl -n "$1" run "hostnet-$RANDOM" --image=busybox --restart=Never \
    --overrides='{"spec":{"hostNetwork":true}}' -- sleep 60 2>&1
}
plain_pod() { kubectl -n "$1" run "plain-$RANDOM" --image=nginx:1.29 --restart=Never 2>&1; }
# for the expected rejections: keep the message, ignore kubectl's exit code
rejected() { "$@" || true; }

section "Blocking privileged pods"
check "label all namespaces: enforce baseline, warn/audit restricted (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Blocking privileged pods' 1)"
check_output "the default namespace carries the enforce label" 'enforce=baseline' \
  bash -c "kubectl get ns default --show-labels"
check_output "enforce: a hostNetwork pod is rejected" 'forbidden.*violates PodSecurity "baseline' \
  rejected hostnet_pod default
check_output "warn: a root pod is created, with a restricted warning" \
  'Warning: would violate PodSecurity "restricted' plain_pod default

section "Check before you apply"
kubectl create ns probe-ns >/dev/null
kubectl -n probe-ns run root-pod --image=nginx:1.29 --restart=Never >/dev/null 2>&1
check_output "--dry-run=server shows which existing pods an enforce label would break" \
  'Warning: existing pods in namespace "probe-ns" violate the new PodSecurity enforce level' \
  bash -c "kubectl label ns probe-ns pod-security.kubernetes.io/enforce=restricted --dry-run=server --overwrite 2>&1"
check_output "and the dry run does not apply the label" '^$' \
  kubectl get ns probe-ns -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'

section 'Relaxing `kube-system`'
check "allow privileged pods in kube-system (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Relaxing `kube-system`' 1)"
check_output "kube-system now enforces privileged" 'enforce=privileged' \
  bash -c "kubectl get ns kube-system --show-labels"

section "What about new namespaces?"
kubectl create ns fresh >/dev/null
check_output "a namespace created after the labelling has no PSA label" '^$' \
  kubectl get ns fresh -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'
check "so, without defaults, a hostNetwork pod is accepted there" hostnet_pod fresh

section "Admission configuration"
curl -fsSL "$UPSTREAM/k8s/admission-configuration.yaml" >admission-configuration.yaml
assert_eq "the note shows the upstream file as-is" \
  "$(cat admission-configuration.yaml)" "$(note_block "$NOTE" 'Admission Configuration' 1)"
# Copy it where the note says; /etc/kubernetes/pki is already mounted into the API server pod.
docker exec -i "$CP" sh -c 'cat >/etc/kubernetes/pki/admission-configuration.yaml' <admission-configuration.yaml
docker exec "$CP" cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
assert_match "the note gives the flag and the path" \
  'admission-control-config-file=/etc/kubernetes/pki/admission-configuration.yaml' \
  "$(sed -n '/## Reconfigure the API server/,/## Test/p' "$NOTES_ROOT/content/$NOTE.md")"
docker exec "$CP" sed -i \
  's|^    - kube-apiserver$|    - kube-apiserver\n    - --admission-control-config-file=/etc/kubernetes/pki/admission-configuration.yaml|' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
# The kubelet notices the manifest change and restarts the static pod; that took
# ~40 s here, and the old API server answers until then.
check "the API server comes back with the admission configuration" \
  retry 180 bash -c "kubectl -n kube-system get pod kube-apiserver-$CP \
    -o jsonpath='{.spec.containers[0].command}' | grep -q admission-control-config-file"
check "and is ready" retry 60 kubectl get --raw /readyz

section "Test the new default policy"
kubectl create ns newns >/dev/null
cat >ds.yaml <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: hostpath-ds}
spec:
  selector: {matchLabels: {app: hostpath-ds}}
  template:
    metadata: {labels: {app: hostpath-ds}}
    spec:
      containers:
      - name: c
        image: busybox
        command: [sleep, "3600"]
        volumeMounts: [{name: host, mountPath: /host}]
      volumes:
      - name: host
        hostPath: {path: /tmp}
EOF
check_output "we get a warning when creating the DaemonSet" \
  'Warning: would violate PodSecurity "baseline' \
  bash -c "kubectl -n newns apply -f ds.yaml 2>&1"
check "the DaemonSet is created" kubectl -n newns get ds hostpath-ds
sleep 10
check_output "but its Pods are not: the default enforce level applies" '^0$' \
  kubectl -n newns get ds hostpath-ds -o jsonpath='{.status.currentNumberScheduled}'
retry 30 bash -c "kubectl -n newns get events --field-selector reason=FailedCreate -o name | grep -q ."
check_output "the controller reports the PodSecurity rejection" 'violates PodSecurity "baseline' \
  bash -c "kubectl -n newns get events --field-selector reason=FailedCreate -o jsonpath='{.items[*].message}'"
check "kube-system stays exempt" \
  bash -c "kubectl -n kube-system apply -f ds.yaml >/dev/null && kubectl -n kube-system delete -f ds.yaml >/dev/null"
